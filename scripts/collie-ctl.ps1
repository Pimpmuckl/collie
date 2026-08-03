[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Command,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$CommandArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:PluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$script:PluginId = "herdr.collie"
$script:TaskName = if ($env:COLLIE_TASK_NAME) { $env:COLLIE_TASK_NAME } else { "herdr.collie" }

function Resolve-CollieConfigDir {
  if ($env:HERDR_PLUGIN_CONFIG_DIR) {
    return $env:HERDR_PLUGIN_CONFIG_DIR
  }

  $herdr = Get-Command herdr.exe -ErrorAction SilentlyContinue
  if ($herdr) {
    try {
      $resolved = (& $herdr.Source plugin config-dir $script:PluginId 2>$null | Select-Object -First 1).Trim()
      if ($resolved) { return $resolved }
    } catch {
      # Herdr may not be running during login. Fall through to its conventional Windows path.
    }
  }

  $roaming = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $env:USERPROFILE "AppData\Roaming" }
  return Join-Path $roaming "herdr\plugins\config\$($script:PluginId)"
}

$script:ConfigDir = Resolve-CollieConfigDir
$script:EnvFile = Join-Path $script:ConfigDir ".env"
$script:LogFile = Join-Path $script:ConfigDir "collie.log"
$script:ErrorLogFile = Join-Path $script:ConfigDir "collie-error.log"
$script:PreviousLogFile = Join-Path $script:ConfigDir "collie-previous.log"
$script:PreviousErrorLogFile = Join-Path $script:ConfigDir "collie-error-previous.log"
$script:PidFile = Join-Path $script:ConfigDir "collie-processes"
$script:ManagedHandlerFile = Join-Path $script:ConfigDir "tailscale-managed-handler"

function Import-CollieEnv([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }

  foreach ($line in Get-Content -LiteralPath $Path) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
    $match = [regex]::Match($trimmed, '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$')
    if (-not $match.Success) {
      throw "invalid .env line: $line"
    }
    $name = $match.Groups[1].Value
    $value = $match.Groups[2].Value.Trim()
    if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    [Environment]::SetEnvironmentVariable($name, $value, "Process")
  }
}

Import-CollieEnv $script:EnvFile

function Get-ColliePort {
  $port = 8787
  if ($env:COLLIE_PORT) {
    $parsed = 0
    if (-not [int]::TryParse($env:COLLIE_PORT, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 65535) {
      Write-Warning "COLLIE_PORT=$($env:COLLIE_PORT) is invalid - using 8787"
    } else {
      $port = $parsed
    }
  }
  return $port
}

$script:Port = Get-ColliePort
$script:ServeMode = if ($env:COLLIE_SERVE_MODE -eq "http") { "http" } else { "https" }
$script:SkipServe = $env:COLLIE_SKIP_SERVE -eq "1"
$script:RoamingDir = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $env:USERPROFILE "AppData\Roaming" }
$script:SocketPath = if ($env:HERDR_SOCKET_PATH) {
  $env:HERDR_SOCKET_PATH
} else {
  Join-Path $script:RoamingDir "herdr\herdr.sock"
}

function Resolve-Bun {
  $command = Get-Command bun.exe -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }

  $candidates = @(
    (Join-Path $env:USERPROFILE ".bun\bin\bun.exe"),
    (Join-Path $env:ProgramData "chocolatey\bin\bun.exe"),
    (Join-Path $env:LOCALAPPDATA "bun\bin\bun.exe")
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
  }
  throw "bun not found - install Bun and make bun.exe available on PATH"
}

function Resolve-Tailscale {
  $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  foreach ($candidate in @(
      (Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"),
      (Join-Path ${env:ProgramFiles(x86)} "Tailscale\tailscale.exe"),
      (Join-Path $env:LOCALAPPDATA "Tailscale\tailscale.exe")
    )) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
  }
  return $null
}

function Invoke-InDirectory([string]$Path, [scriptblock]$Body) {
  Push-Location -LiteralPath $Path
  try { & $Body } finally { Pop-Location }
}

function Assert-LastExit([string]$What) {
  if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" }
}

function Write-CollieActionLauncher([string]$OutputPath) {
  $launcherDir = Join-Path $script:PluginRoot "build"
  New-Item -ItemType Directory -Force -Path $launcherDir | Out-Null
  $launcher = if ($OutputPath) { $OutputPath } else { Join-Path $launcherDir "collie-action.exe" }
  Remove-Item -LiteralPath $launcher -ErrorAction SilentlyContinue
  Add-Type `
    -Path (Join-Path $PSScriptRoot "collie-action.cs") `
    -OutputAssembly $launcher `
    -OutputType ConsoleApplication
}

function Invoke-CollieBuild([string]$LauncherOutput) {
  $bun = Resolve-Bun
  New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null
  Write-CollieActionLauncher $LauncherOutput
  if ($env:SKIP_VERSION_CHECK -ne "1") {
    & (Join-Path $PSScriptRoot "check-version.ps1")
  }

  Invoke-InDirectory $script:PluginRoot {
    & $bun install
    Assert-LastExit "root bun install"
    & $bun run typecheck
    Assert-LastExit "root typecheck"
  }

  $webRoot = Join-Path $script:PluginRoot "web"
  $staging = Join-Path $webRoot "dist-staging"
  $dist = Join-Path $webRoot "dist"
  if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
  Invoke-InDirectory $webRoot {
    & $bun install
    Assert-LastExit "web bun install"
    & $bun run typecheck
    Assert-LastExit "web typecheck"
    & $bun run build -- --outDir dist-staging --emptyOutDir
    Assert-LastExit "web build"
  }
  if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
  Move-Item -LiteralPath $staging -Destination $dist
}

function Ensure-CollieBuild {
  if (Test-Path -LiteralPath (Join-Path $script:PluginRoot "web\dist\index.html")) { return }
  Write-Output "building web UI (first run)..."
  Invoke-CollieBuild
}

function Register-CollieTask {
  $bun = Resolve-Bun
  $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
  $ctl = Join-Path $PSScriptRoot "collie-ctl.ps1"
  $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" _exec-bridge' -f $ctl
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $runLevel = Get-CollieTaskRunLevel

  $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $script:PluginRoot
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
  $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel $runLevel
  $settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable

  Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Collie mobile bridge for Herdr" -Force | Out-Null
  Enable-ScheduledTask -TaskName $script:TaskName | Out-Null
  return $bun
}

function Test-BridgeReady([int]$Attempts = 25) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
      $connect = $client.ConnectAsync("127.0.0.1", $script:Port)
      if ($connect.Wait(200) -and $client.Connected) { return $true }
    } catch {
      # The bridge may still be starting.
    } finally {
      $client.Dispose()
    }
    Start-Sleep -Milliseconds 200
  }
  return $false
}

function Test-HerdrReady([int]$Attempts = 1) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    try {
      $snapshot = Invoke-RestMethod -Uri "http://127.0.0.1:$($script:Port)/api/snapshot" -TimeoutSec 1
      if ($snapshot.bridge -eq "connected") { return $true }
    } catch {
      # The bridge or Herdr endpoint may still be starting.
    }
    if ($i + 1 -lt $Attempts) { Start-Sleep -Milliseconds 250 }
  }
  return $false
}

function Get-CollieVersion {
  $buildInfo = Join-Path $script:PluginRoot "web\dist\build-info.json"
  if (Test-Path -LiteralPath $buildInfo) {
    $info = Get-Content -LiteralPath $buildInfo -Raw | ConvertFrom-Json
    if ($info.sha) { return "$($info.version)+$($info.sha)" }
    return [string]$info.version
  }
  $manifest = Get-Content -LiteralPath (Join-Path $script:PluginRoot "herdr-plugin.toml") -Raw
  $version = [regex]::Match($manifest, '(?m)^\s*version\s*=\s*"([^"]+)"').Groups[1].Value
  return "$version (manifest; web not built)"
}

function Get-TailscaleStatus([switch]$Serve) {
  $tailscale = Resolve-Tailscale
  if (-not $tailscale) { throw "tailscale not found" }
  $raw = if ($Serve) { & $tailscale serve status --json 2>$null | Out-String } else { & $tailscale status --json 2>$null | Out-String }
  Assert-LastExit "tailscale status"
  return $raw | ConvertFrom-Json
}

function Get-ObjectProperty($Object, [string]$Name) {
  if ($null -eq $Object) { return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($property) { return $property.Value }
  return $null
}

function Get-ServeEntries($Config, [int]$ListenerPort, [bool]$Foreground = $false) {
  $entries = @()
  $listener = Get-ObjectProperty (Get-ObjectProperty $Config "TCP") ([string]$ListenerPort)
  $protocol = if ((Get-ObjectProperty $listener "HTTP") -eq $true) { "http" } elseif ((Get-ObjectProperty $listener "HTTPS") -eq $true) { "https" } else { "other" }
  $web = Get-ObjectProperty $Config "Web"
  if ($web) {
    foreach ($serverProperty in $web.PSObject.Properties) {
      if ($serverProperty.Name -notmatch ":$ListenerPort$") { continue }
      $handlers = Get-ObjectProperty $serverProperty.Value "Handlers"
      $root = Get-ObjectProperty $handlers "/"
      if ($root) {
        $entries += [pscustomobject]@{
          HostPort = $serverProperty.Name
          Protocol = $protocol
          Proxy = Get-ObjectProperty $root "Proxy"
          Foreground = $Foreground
        }
      }
    }
  }
  $foregroundConfigs = Get-ObjectProperty $Config "Foreground"
  if ($foregroundConfigs) {
    foreach ($property in $foregroundConfigs.PSObject.Properties) {
      $entries += Get-ServeEntries $property.Value $ListenerPort $true
    }
  }
  return $entries
}

function Test-Administrator {
  $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CollieTaskRunLevel {
  $requested = if ($env:COLLIE_TASK_RUN_LEVEL) { $env:COLLIE_TASK_RUN_LEVEL.Trim() } else { "limited" }
  if ($requested -ieq "limited") { return "Limited" }
  if ($requested -ine "highest") {
    throw "COLLIE_TASK_RUN_LEVEL must be 'limited' or 'highest'"
  }
  if (-not (Test-Administrator)) {
    throw "COLLIE_TASK_RUN_LEVEL=highest requires an Administrator Herdr process"
  }
  return "Highest"
}

function Assert-ServeAdministrator {
  if (Test-Administrator) { return }
  $ctl = Join-Path $PSScriptRoot "collie-ctl.ps1"
  throw "Tailscale Serve changes require Administrator PowerShell. Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ctl`" serve"
}

function Get-TailscaleDnsName {
  try {
    $status = Get-TailscaleStatus
    return ([string]$status.Self.DNSName).TrimEnd(".")
  } catch {
    return ""
  }
}

function Remove-ManagedServe {
  if (-not (Test-Path -LiteralPath $script:ManagedHandlerFile)) {
    Write-Output "tailscale serve: no Collie-managed mapping recorded"
    return
  }

  $state = (Get-Content -LiteralPath $script:ManagedHandlerFile -Raw).Trim()
  $match = [regex]::Match($state, '^(http|https):(\d+)\|([^|]+)\|(http://127\.0\.0\.1:\d+)$')
  if (-not $match.Success) { throw "invalid managed Tailscale handler state: $state" }
  $mode = $match.Groups[1].Value
  $listenerPort = [int]$match.Groups[2].Value
  $hostPort = $match.Groups[3].Value
  $proxy = $match.Groups[4].Value
  if (($mode -eq "https" -and $listenerPort -ne 443) -or -not $hostPort.EndsWith(":$listenerPort")) {
    throw "invalid managed Tailscale handler state: $state"
  }

  $config = Get-TailscaleStatus -Serve
  $current = @(Get-ServeEntries $config $listenerPort | Where-Object { $_.HostPort -eq $hostPort -and -not $_.Foreground })
  if ($current.Count -eq 0) {
    Remove-Item -LiteralPath $script:ManagedHandlerFile
    Write-Output "tailscale serve: managed root is already absent; cleared stale ownership state"
    return
  }
  if ($current.Count -ne 1 -or $current[0].Protocol -ne $mode -or $current[0].Proxy -ne $proxy) {
    throw "managed Tailscale root was replaced; refusing to remove the current handler"
  }

  Assert-ServeAdministrator
  $tailscale = Resolve-Tailscale
  $listenerArg = if ($mode -eq "http") { "--http=$listenerPort" } else { "--https=443" }
  & $tailscale serve $listenerArg --set-path=/ off
  Assert-LastExit "remove Tailscale Serve handler"
  Remove-Item -LiteralPath $script:ManagedHandlerFile
  Write-Output "tailscale serve: removed Collie's managed $mode`:$listenerPort mapping"
}

function Invoke-CollieServe {
  if ($script:SkipServe) {
    Remove-ManagedServe
    Write-Output "tailscale serve skipped (COLLIE_SKIP_SERVE=1) - bridge is on 127.0.0.1:$($script:Port) only"
    return
  }

  $tailscale = Resolve-Tailscale
  if (-not $tailscale) { throw "tailscale not found; cannot publish the tailnet front door" }
  $dnsName = Get-TailscaleDnsName
  if (-not $dnsName) { throw "cannot determine Tailscale hostname; is this machine logged in?" }
  $listenerPort = if ($script:ServeMode -eq "http") { $script:Port } else { 443 }
  $expectedProxy = "http://127.0.0.1:$($script:Port)"

  if (Test-Path -LiteralPath $script:ManagedHandlerFile) {
    $expectedHostPort = "$dnsName`:$listenerPort"
    $expectedState = "$($script:ServeMode):$listenerPort|$expectedHostPort|$expectedProxy"
    $managedState = (Get-Content -LiteralPath $script:ManagedHandlerFile -Raw).Trim()
    if ($managedState -eq $expectedState) {
      $currentConfig = Get-TailscaleStatus -Serve
      $currentEntries = @(Get-ServeEntries $currentConfig $listenerPort | Where-Object {
          $_.HostPort -eq $expectedHostPort -and -not $_.Foreground
        })
      if ($currentEntries.Count -eq 1 -and $currentEntries[0].Protocol -eq $script:ServeMode -and $currentEntries[0].Proxy -eq $expectedProxy) {
        Write-Output "tailscale serve: Collie's mapping is already configured"
        return
      }
    }
  }

  Remove-ManagedServe
  $config = Get-TailscaleStatus -Serve
  $entries = @(Get-ServeEntries $config $listenerPort)
  if ($entries | Where-Object { $_.Foreground }) {
    throw "Tailscale Serve already has a foreground root on :$listenerPort; refusing to overwrite it"
  }
  if ($entries | Where-Object { $_.Protocol -ne $script:ServeMode }) {
    throw "Tailscale Serve :$listenerPort already uses the opposite listener protocol"
  }
  if ($entries.Count -gt 0 -and ($entries | Where-Object { $_.Proxy -ne $expectedProxy })) {
    throw "Tailscale Serve already has an unowned root on :$listenerPort; refusing to overwrite it"
  }

  if ($entries.Count -eq 0) {
    Assert-ServeAdministrator
  } else {
    Write-Output "tailscale serve: adopting the existing Collie root mount on :$listenerPort"
  }

  New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null
  $hostPort = "$dnsName`:$listenerPort"
  "$($script:ServeMode):$listenerPort|$hostPort|$expectedProxy" | Set-Content -LiteralPath $script:ManagedHandlerFile -NoNewline
  if ($entries.Count -eq 0) {
    $listenerArg = if ($script:ServeMode -eq "http") { "--http=$listenerPort" } else { "--https=443" }
    & $tailscale serve --yes --bg $listenerArg --set-path=/ $script:Port
    if ($LASTEXITCODE -ne 0) {
      Remove-Item -LiteralPath $script:ManagedHandlerFile -ErrorAction SilentlyContinue
      throw "tailscale serve failed with exit code $LASTEXITCODE"
    }
  }
  Write-Output "tailscale serve ($($script:ServeMode)) -> tailnet :$listenerPort -> 127.0.0.1:$($script:Port)"
}

function Get-CollieUrl {
  if ($script:SkipServe) {
    if ($env:COLLIE_PUBLIC_URL) { return $env:COLLIE_PUBLIC_URL }
    return "http://127.0.0.1:$($script:Port) (COLLIE_SKIP_SERVE=1; public URL unset)"
  }
  $dnsName = Get-TailscaleDnsName
  if (-not $dnsName) { return "http://127.0.0.1:$($script:Port) (Tailscale name unavailable)" }
  if ($script:ServeMode -eq "http") { return "http://$dnsName`:$($script:Port)" }
  return "https://$dnsName"
}

function Show-CollieStatus {
  $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
  $service = if ($task) { "Task Scheduler ($($script:TaskName)) - $($task.State)" } else { "not supervised" }
  Write-Output ""
  if (Test-HerdrReady) {
    Write-Output "  OK Collie is running - v$(Get-CollieVersion)"
  } elseif (Test-BridgeReady 1) {
    Write-Output "  WARN Collie is running but cannot reach Herdr - check logs"
  } else {
    Write-Output "  WARN Collie is not answering on :$($script:Port) - check logs"
  }
  Write-Output "    service   $service"
  Write-Output "    local     http://127.0.0.1:$($script:Port)"
  Write-Output "    remote    $(Get-CollieUrl)"
  Write-Output ""
}

function Start-Collie {
  Ensure-CollieBuild
  Register-CollieTask | Out-Null
  Start-ScheduledTask -TaskName $script:TaskName
  Write-Output "bridge started (Task Scheduler: $($script:TaskName))"
  [void](Test-BridgeReady)
  $herdrReady = Test-HerdrReady 30
  if (-not $herdrReady -and (Test-Administrator) -and (Get-CollieTaskRunLevel) -eq "Limited") {
    Stop-Collie | Out-Null
    throw "Herdr is elevated, but Collie's task is limited and cannot reach its named pipe. Restart Herdr without Administrator rights, or set COLLIE_TASK_RUN_LEVEL=highest in Collie's .env to give phone actions the same elevated access."
  }
  try {
    Invoke-CollieServe
  } catch {
    Write-Warning "$($_.Exception.Message); the bridge remains on 127.0.0.1:$($script:Port)"
  }
  Show-CollieStatus
}

function Stop-RecordedCollieProcesses {
  if (-not (Test-Path -LiteralPath $script:PidFile)) { return }
  $record = (Get-Content -LiteralPath $script:PidFile -Raw).Trim()
  $match = [regex]::Match($record, '^(\d+)\|(\d+)$')
  if (-not $match.Success) { throw "invalid Collie process ownership state: $record" }

  $launcherId = [int]$match.Groups[1].Value
  $bridgeId = [int]$match.Groups[2].Value
  $launcher = Get-CimInstance Win32_Process -Filter "ProcessId = $launcherId" -ErrorAction SilentlyContinue
  if ($launcher) {
    $controlScript = Join-Path $PSScriptRoot "collie-ctl.ps1"
    if (-not $launcher.CommandLine.Contains($controlScript) -or -not $launcher.CommandLine.Contains("_exec-bridge")) {
      throw "recorded launcher PID $launcherId no longer belongs to Collie"
    }
    & (Join-Path $env:SystemRoot "System32\taskkill.exe") /PID $launcherId /T /F | Out-Null
  }

  $bridge = if ($bridgeId -gt 0) {
    Get-CimInstance Win32_Process -Filter "ProcessId = $bridgeId" -ErrorAction SilentlyContinue
  }
  if ($bridge) {
    $bridgeScript = Join-Path $script:PluginRoot "bridge\index.ts"
    if (-not $bridge.CommandLine.Contains($bridgeScript)) {
      throw "recorded bridge PID $bridgeId no longer belongs to Collie"
    }
    Stop-Process -Id $bridgeId -Force
  }
  Remove-Item -LiteralPath $script:PidFile -ErrorAction SilentlyContinue
}

function Stop-Collie {
  $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
  if ($task) {
    Disable-ScheduledTask -TaskName $script:TaskName | Out-Null
  }
  Stop-RecordedCollieProcesses
  if ($task) { Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue }
  Write-Output "bridge stopped"
}

function Uninstall-Collie {
  Stop-Collie
  try {
    Remove-ManagedServe
  } finally {
    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
      Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
    }
  }
  Write-Output "OK uninstalled: task stopped and removed; Collie's Tailscale mapping removed"
  Write-Output "  kept: $($script:EnvFile) and the checkout"
}

function Get-CollieActionPid {
  if (-not $env:COLLIE_ACTION_PID) { return 0 }
  $launcherPid = 0
  if (-not [int]::TryParse($env:COLLIE_ACTION_PID, [ref]$launcherPid) -or $launcherPid -le 0) {
    throw "invalid COLLIE_ACTION_PID"
  }
  return $launcherPid
}

function Install-CollieActionLauncher([int]$LauncherPid) {
  Wait-Process -Id $LauncherPid -ErrorAction SilentlyContinue
  $launcherDir = Join-Path $script:PluginRoot "build"
  Move-Item `
    -LiteralPath (Join-Path $launcherDir "collie-action.pending.exe") `
    -Destination (Join-Path $launcherDir "collie-action.exe") `
    -Force
}

function Apply-CollieUpdate {
  $launcherPid = Get-CollieActionPid
  $launcherOutput = if ($launcherPid) { Join-Path $script:PluginRoot "build\collie-action.pending.exe" } else { $null }
  Invoke-CollieBuild $launcherOutput
  Stop-Collie
  Start-Collie
  try {
    & herdr plugin link $script:PluginRoot | Out-Null
    Assert-LastExit "herdr plugin link"
    Write-Output "herdr registry refreshed (re-linked)"
  } catch {
    Write-Warning "could not refresh the Herdr registry; run: herdr plugin link `"$($script:PluginRoot)`""
  }
  if ($launcherPid) {
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" _install-launcher {1}' -f (Join-Path $PSScriptRoot "collie-ctl.ps1"), $launcherPid
    Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden
  }
  Write-Output "OK update complete"
}

function Update-Collie {
  & git -C $script:PluginRoot pull --ff-only
  Assert-LastExit "git pull"
  $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
  & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "collie-ctl.ps1") _apply-update
  Assert-LastExit "apply update"
}

function Preserve-CollieCrashLogs {
  if (Test-Path -LiteralPath $script:LogFile) {
    Move-Item -LiteralPath $script:LogFile -Destination $script:PreviousLogFile -Force
  }
  if (Test-Path -LiteralPath $script:ErrorLogFile) {
    Move-Item -LiteralPath $script:ErrorLogFile -Destination $script:PreviousErrorLogFile -Force
  }
}

function Invoke-CollieBridge {
  $bun = Resolve-Bun
  New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null
  $env:HERDR_SOCKET_PATH = $script:SocketPath
  $env:COLLIE_PORT = [string]$script:Port
  $env:HERDR_PLUGIN_CONFIG_DIR = $script:ConfigDir
  if (-not $env:HERDR_PLUGIN_STATE_DIR) {
    $localData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE "AppData\Local" }
    $env:HERDR_PLUGIN_STATE_DIR = Join-Path $localData "herdr\plugins\$($script:PluginId)"
  }
  $bridge = Join-Path $script:PluginRoot "bridge\index.ts"
  Stop-RecordedCollieProcesses
  while ($true) {
    "$PID|0" | Set-Content -LiteralPath $script:PidFile -NoNewline
    $process = Start-Process `
      -FilePath $bun `
      -ArgumentList @("run", "`"$bridge`"") `
      -WorkingDirectory $script:PluginRoot `
      -NoNewWindow `
      -PassThru `
      -RedirectStandardOutput $script:LogFile `
      -RedirectStandardError $script:ErrorLogFile
    "$PID|$($process.Id)" | Set-Content -LiteralPath $script:PidFile -NoNewline
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    "$PID|0" | Set-Content -LiteralPath $script:PidFile -NoNewline
    if ($exitCode -eq 0) { exit 0 }
    Preserve-CollieCrashLogs
    Start-Sleep -Seconds 5
  }
}

if ($MyInvocation.InvocationName -eq ".") { return }

switch ($Command) {
  "build" { Invoke-CollieBuild }
  "start" { Start-Collie }
  "stop" { Stop-Collie }
  "restart" { Stop-Collie; Start-Collie }
  "uninstall" { Uninstall-Collie }
  "update" { Update-Collie }
  "_apply-update" { Apply-CollieUpdate }
  "_install-launcher" { Install-CollieActionLauncher ([int]$CommandArgs[0]) }
  "serve" { Invoke-CollieServe }
  "unserve" { Remove-ManagedServe }
  "status" { Show-CollieStatus }
  "url" { Get-CollieUrl }
  "version" { Get-CollieVersion }
  "logs" {
    $lines = if ($CommandArgs -and $CommandArgs.Count -gt 0) { [int]$CommandArgs[0] } else { 50 }
    if (Test-Path -LiteralPath $script:PreviousLogFile) { Write-Output "previous bridge crash (stdout):"; Get-Content -LiteralPath $script:PreviousLogFile -Tail $lines -Encoding UTF8 }
    if (Test-Path -LiteralPath $script:PreviousErrorLogFile) { Write-Output "previous bridge crash (stderr):"; Get-Content -LiteralPath $script:PreviousErrorLogFile -Tail $lines -Encoding UTF8 }
    if (Test-Path -LiteralPath $script:LogFile) { Get-Content -LiteralPath $script:LogFile -Tail $lines -Encoding UTF8 } else { "(no log)" }
    if (Test-Path -LiteralPath $script:ErrorLogFile) { Get-Content -LiteralPath $script:ErrorLogFile -Tail $lines -Encoding UTF8 }
  }
  "_exec-bridge" { Invoke-CollieBridge }
  default {
    Write-Error "usage: collie-ctl.ps1 {start|stop|restart|uninstall|update|version|build|serve|unserve|status|url|logs}"
  }
}
