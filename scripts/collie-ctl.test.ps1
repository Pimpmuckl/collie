$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) { throw "$Message - expected '$Expected', got '$Actual'" }
}

function Assert-Contains([string]$Actual, [string]$Expected, [string]$Message) {
  if (-not $Actual.Contains($Expected)) { throw "$Message - '$Expected' not found in '$Actual'" }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) "collie-ctl-$([guid]::NewGuid().ToString('N'))"
$savedConfigDir = $env:HERDR_PLUGIN_CONFIG_DIR
$savedTaskName = $env:COLLIE_TASK_NAME
$savedPort = $env:COLLIE_PORT
$savedRunLevel = $env:COLLIE_TASK_RUN_LEVEL
$savedSocketPath = $env:HERDR_SOCKET_PATH

try {
  New-Item -ItemType Directory -Path $temp | Out-Null
  @'
COLLIE_PORT=9123
COLLIE_HOST="127.0.0.1"
'@ | Set-Content -LiteralPath (Join-Path $temp ".env") -Encoding Ascii
  $env:HERDR_PLUGIN_CONFIG_DIR = $temp
  $env:COLLIE_TASK_NAME = "herdr.collie-test"
  Remove-Item Env:COLLIE_PORT -ErrorAction SilentlyContinue
  Remove-Item Env:COLLIE_TASK_RUN_LEVEL -ErrorAction SilentlyContinue
  $env:HERDR_SOCKET_PATH = "\\.\pipe\collie-test"

  . (Join-Path $PSScriptRoot "collie-ctl.ps1")
  Assert-Equal $script:Port 9123 ".env port"
  Assert-Equal $env:COLLIE_HOST "127.0.0.1" ".env quoted value"

  Write-CollieActionLauncher
  $launcher = Join-Path $script:PluginRoot "build\collie-action.exe"
  $launcherVersion = (& $launcher version | Out-String).Trim()
  Assert-Equal $launcherVersion (Get-CollieVersion) "action launcher execution"
  $pendingLauncher = Join-Path $script:PluginRoot "build\collie-action.pending.exe"
  Copy-Item -LiteralPath $launcher -Destination $pendingLauncher
  $exitingProcess = Start-Process -FilePath $env:ComSpec -ArgumentList "/c exit 0" -PassThru -WindowStyle Hidden
  Install-CollieActionLauncher $exitingProcess.Id
  Assert-Equal (Test-Path -LiteralPath $pendingLauncher) $false "pending launcher installation"

  $originalPluginRoot = $script:PluginRoot
  $script:PluginRoot = Join-Path $temp "lazy-plugin"
  New-Item -ItemType Directory -Path (Join-Path $script:PluginRoot "web") -Force | Out-Null
  $script:lazyApplicationBuilds = 0
  $script:lazyLauncherWrites = 0
  function Resolve-Bun { "C:\fake\bun.exe" }
  function Invoke-CollieApplicationBuild([string]$Bun) { $script:lazyApplicationBuilds++ }
  function Write-CollieActionLauncher([string]$OutputPath) { $script:lazyLauncherWrites++ }
  Ensure-CollieBuild | Out-Null
  Assert-Equal $script:lazyApplicationBuilds 1 "lazy start builds the application"
  Assert-Equal $script:lazyLauncherWrites 0 "lazy start preserves the running launcher"
  $script:PluginRoot = $originalPluginRoot

  "crashed stdout" | Set-Content -LiteralPath $script:LogFile
  "crashed stderr" | Set-Content -LiteralPath $script:ErrorLogFile
  Preserve-CollieCrashLogs
  Assert-Contains (Get-Content -LiteralPath $script:PreviousLogFile -Raw) "crashed stdout" "crash stdout preservation"
  Assert-Contains (Get-Content -LiteralPath $script:PreviousErrorLogFile -Raw) "crashed stderr" "crash stderr preservation"

  $swapRoot = Join-Path $temp "web"
  New-Item -ItemType Directory -Path (Join-Path $swapRoot "dist"), (Join-Path $swapRoot "dist-staging") | Out-Null
  "live" | Set-Content -LiteralPath (Join-Path $swapRoot "dist\index.html")
  "staged" | Set-Content -LiteralPath (Join-Path $swapRoot "dist-staging\index.html")
  function Move-Item {
    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
    if ((Split-Path -Leaf $LiteralPath) -eq "dist-staging") { throw "simulated staged move failure" }
    Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
  }
  try {
    Install-CollieWebDist $swapRoot
    throw "failed web swap was accepted"
  } catch {
    Assert-Contains $_.Exception.Message "simulated staged move failure" "web swap failure"
  }
  Remove-Item Function:\Move-Item
  Assert-Contains (Get-Content -LiteralPath (Join-Path $swapRoot "dist\index.html") -Raw) "live" "failed web swap preserves live dist"

  "not valid" | Set-Content -LiteralPath (Join-Path $temp "invalid.env") -Encoding Ascii
  try {
    Import-CollieEnv (Join-Path $temp "invalid.env")
    throw "invalid .env line was accepted"
  } catch {
    Assert-Contains $_.Exception.Message "invalid .env line" ".env validation"
  }

  "$PID|0" | Set-Content -LiteralPath $script:PidFile -NoNewline
  Stop-RecordedCollieProcesses
  Assert-Equal (Test-Path -LiteralPath $script:PidFile) $false "stale launcher PID record is cleared"

  $pushArgsFile = Join-Path $temp "push-args.txt"
  $fakeBun = Join-Path $temp "bun.cmd"
  "@echo off`r`necho %* > `"$pushArgsFile`"`r`n" | Set-Content -LiteralPath $fakeBun -Encoding Ascii
  function Resolve-Bun { $fakeBun }
  Invoke-ColliePushTest @("Test title", "Test body", "pane-1")
  $pushArgs = Get-Content -LiteralPath $pushArgsFile -Raw
  Assert-Contains $pushArgs "push-test.ts" "push test script"
  Assert-Contains $pushArgs "Test title" "push test arguments"
  Assert-Contains $pushArgs "pane-1" "push test pane"

  $script:registered = $null
  $script:enabled = @()
  $script:disabled = @()
  $script:started = @()
  $script:stopped = @()
  function Test-Administrator { $false }
  function New-ScheduledTaskAction($Execute, $Argument, $WorkingDirectory) {
    [pscustomobject]@{ Execute = $Execute; Argument = $Argument; WorkingDirectory = $WorkingDirectory }
  }
  function New-ScheduledTaskTrigger([switch]$AtLogOn, $User) {
    [pscustomobject]@{ AtLogOn = $AtLogOn; User = $User }
  }
  function New-ScheduledTaskPrincipal($UserId, $LogonType, $RunLevel) {
    [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel }
  }
  function New-ScheduledTaskSettingsSet {
    param(
      [switch]$AllowStartIfOnBatteries,
      [switch]$DontStopIfGoingOnBatteries,
      $ExecutionTimeLimit,
      $MultipleInstances,
      $RestartCount,
      $RestartInterval,
      [switch]$StartWhenAvailable
    )
    [pscustomobject]@{
      ExecutionTimeLimit = $ExecutionTimeLimit
      RestartCount = $RestartCount
      RestartInterval = $RestartInterval
    }
  }
  function Register-ScheduledTask {
    param($TaskName, $Action, $Trigger, $Principal, $Settings, $Description, [switch]$Force)
    $script:registered = [pscustomobject]@{
      TaskName = $TaskName
      Action = $Action
      Trigger = $Trigger
      Principal = $Principal
      Settings = $Settings
    }
  }
  function Enable-ScheduledTask($TaskName) { $script:enabled += $TaskName }
  function Get-ScheduledTask($TaskName) { [pscustomobject]@{ TaskName = $TaskName; State = "Ready" } }
  function Disable-ScheduledTask($TaskName) { $script:disabled += $TaskName }
  function Start-ScheduledTask($TaskName) { $script:started += $TaskName }
  function Stop-ScheduledTask($TaskName) { $script:stopped += $TaskName }
  function Unregister-ScheduledTask($TaskName, [switch]$Confirm) { $script:unregistered += $TaskName }

  Register-CollieTask | Out-Null
  Assert-Equal $script:registered.TaskName "herdr.collie-test" "task ownership"
  Assert-Contains $script:registered.Action.Argument "_exec-bridge" "task action"
  Assert-Contains $script:registered.Action.Argument $temp "task preserves resolved config dir"
  Assert-Contains $script:registered.Action.Argument "\\.\pipe\collie-test" "task preserves resolved socket path"
  Assert-Equal $script:registered.Trigger.User ([Security.Principal.WindowsIdentity]::GetCurrent().Name) "logon trigger user"
  Assert-Equal $script:registered.Principal.RunLevel "Limited" "task privilege"
  Assert-Equal $script:registered.Settings.ExecutionTimeLimit ([TimeSpan]::Zero) "task execution limit"
  Assert-Equal $script:registered.Settings.RestartCount 999 "task restart policy"

  $env:COLLIE_TASK_RUN_LEVEL = "highest"
  function Test-Administrator { $false }
  try {
    Get-CollieTaskRunLevel | Out-Null
    throw "a non-admin highest task was accepted"
  } catch {
    Assert-Contains $_.Exception.Message "requires an Administrator" "highest task privilege guard"
  }
  function Test-Administrator { $true }
  Register-CollieTask | Out-Null
  Assert-Equal $script:registered.Principal.RunLevel "Highest" "elevated Herdr task privilege"

  Stop-Collie | Out-Null
  Assert-Equal ($script:disabled -join ",") "herdr.collie-test" "stop disables only Collie's task"
  Assert-Equal ($script:stopped -join ",") "herdr.collie-test" "stop stops only Collie's task"

  $script:unregistered = @()
  function Remove-ManagedServe { throw "Tailscale Serve changes require Administrator PowerShell" }
  try {
    Uninstall-Collie | Out-Null
    throw "uninstall accepted incomplete Tailscale cleanup"
  } catch {
    Assert-Contains $_.Exception.Message "Administrator PowerShell" "uninstall reports Tailscale cleanup"
  }
  Assert-Equal ($script:unregistered -join ",") "herdr.collie-test" "uninstall always removes Collie's task"

  $fakeTailscale = Join-Path $temp "tailscale.cmd"
  "@echo off`r`nif `%1`==serve if `%2`==status echo https://host.example.ts.net`r`n" |
    Set-Content -LiteralPath $fakeTailscale -Encoding Ascii
  function Resolve-Tailscale { $fakeTailscale }
  function Test-HerdrReady { $true }
  function Get-CollieUrl { "https://host.example.ts.net" }
  $statusOutput = Show-CollieStatus | Out-String
  Assert-Contains $statusOutput "serve config:" "status includes Tailscale configuration"
  Assert-Contains $statusOutput "https://host.example.ts.net" "status includes Tailscale mapping"

  function Get-TailscaleDnsName { "host.example.ts.net" }
  function Remove-ManagedServe {}
  function Get-TailscaleStatus {
    param([switch]$Serve)
    return '{"TCP":{"443":{"HTTPS":true}},"Web":{"host.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9123"}}}}}' | ConvertFrom-Json
  }
  'https:443|host.example.ts.net:443|http://127.0.0.1:9123' | Set-Content -LiteralPath $script:ManagedHandlerFile -NoNewline
  $serveOutput = Invoke-CollieServe | Out-String
  Assert-Contains $serveOutput "already configured" "existing Tailscale mapping"

  function Get-TailscaleStatus {
    param([switch]$Serve)
    return '{"TCP":{"443":{"HTTPS":true}},"Web":{"host.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9999"}}}}}' | ConvertFrom-Json
  }
  try {
    Invoke-CollieServe
    throw "unowned Tailscale root was accepted"
  } catch {
    Assert-Contains $_.Exception.Message "unowned root" "Tailscale ownership guard"
  }

  function Get-TailscaleStatus {
    param([switch]$Serve)
    return '{"TCP":{"443":{"HTTP":true}},"Web":{"host.example.ts.net:443":{"Handlers":{"/other":{"Text":"occupied"}}}}}' | ConvertFrom-Json
  }
  try {
    Invoke-CollieServe
    throw "an opposite-protocol listener without a root handler was accepted"
  } catch {
    Assert-Contains $_.Exception.Message "opposite listener protocol" "Tailscale listener protocol guard"
  }

  function Get-TailscaleStatus {
    param([switch]$Serve)
    return '{"TCP":{"443":{"TCPForward":"127.0.0.1:9999"}}}' | ConvertFrom-Json
  }
  try {
    Invoke-CollieServe
    throw "a raw TCP listener was accepted"
  } catch {
    Assert-Contains $_.Exception.Message "opposite listener protocol" "raw Tailscale listener guard"
  }

  $env:COLLIE_TASK_RUN_LEVEL = "limited"
  $script:disabled = @()
  function Ensure-CollieBuild {}
  function Test-HerdrReady([int]$Attempts = 1) { $false }
  function Test-BridgeReady([int]$Attempts = 25) { $true }
  function Invoke-CollieServe {}
  function Show-CollieStatus {}
  $startOutput = Start-Collie 3>&1 | Out-String
  Assert-Contains $startOutput "temporarily unavailable" "temporary Herdr outage warning"
  Assert-Equal ($script:started -join ",") "herdr.collie-test" "start launches Collie's task"
  Assert-Equal ($script:disabled -join ",") "" "temporary Herdr outage keeps Collie's task enabled"

  Write-Output "OK Windows lifecycle tests"
} finally {
  if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
  [Environment]::SetEnvironmentVariable("HERDR_PLUGIN_CONFIG_DIR", $savedConfigDir, "Process")
  [Environment]::SetEnvironmentVariable("COLLIE_TASK_NAME", $savedTaskName, "Process")
  [Environment]::SetEnvironmentVariable("COLLIE_PORT", $savedPort, "Process")
  [Environment]::SetEnvironmentVariable("COLLIE_TASK_RUN_LEVEL", $savedRunLevel, "Process")
  [Environment]::SetEnvironmentVariable("HERDR_SOCKET_PATH", $savedSocketPath, "Process")
}
