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

  "crashed stdout" | Set-Content -LiteralPath $script:LogFile
  "crashed stderr" | Set-Content -LiteralPath $script:ErrorLogFile
  Preserve-CollieCrashLogs
  Assert-Contains (Get-Content -LiteralPath $script:PreviousLogFile -Raw) "crashed stdout" "crash stdout preservation"
  Assert-Contains (Get-Content -LiteralPath $script:PreviousErrorLogFile -Raw) "crashed stderr" "crash stderr preservation"

  "not valid" | Set-Content -LiteralPath (Join-Path $temp "invalid.env") -Encoding Ascii
  try {
    Import-CollieEnv (Join-Path $temp "invalid.env")
    throw "invalid .env line was accepted"
  } catch {
    Assert-Contains $_.Exception.Message "invalid .env line" ".env validation"
  }

  "$PID|0" | Set-Content -LiteralPath $script:PidFile -NoNewline
  try {
    Stop-RecordedCollieProcesses
    throw "an unrelated recorded process was stopped"
  } catch {
    Assert-Contains $_.Exception.Message "no longer belongs to Collie" "process ownership guard"
  }
  Remove-Item -LiteralPath $script:PidFile

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
  function Stop-ScheduledTask($TaskName) { $script:stopped += $TaskName }
  function Unregister-ScheduledTask($TaskName, [switch]$Confirm) { $script:unregistered += $TaskName }

  Register-CollieTask | Out-Null
  Assert-Equal $script:registered.TaskName "herdr.collie-test" "task ownership"
  Assert-Contains $script:registered.Action.Argument "_exec-bridge" "task action"
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

  Write-Output "OK Windows lifecycle tests"
} finally {
  if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
  [Environment]::SetEnvironmentVariable("HERDR_PLUGIN_CONFIG_DIR", $savedConfigDir, "Process")
  [Environment]::SetEnvironmentVariable("COLLIE_TASK_NAME", $savedTaskName, "Process")
  [Environment]::SetEnvironmentVariable("COLLIE_PORT", $savedPort, "Process")
  [Environment]::SetEnvironmentVariable("COLLIE_TASK_RUN_LEVEL", $savedRunLevel, "Process")
}
