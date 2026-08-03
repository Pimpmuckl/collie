[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

$manifest = Get-Content -LiteralPath (Join-Path $root "herdr-plugin.toml") -Raw
$package = Get-Content -LiteralPath (Join-Path $root "package.json") -Raw | ConvertFrom-Json
$webPackage = Get-Content -LiteralPath (Join-Path $root "web\package.json") -Raw | ConvertFrom-Json
$changelog = Get-Content -LiteralPath (Join-Path $root "CHANGELOG.md") -Raw

$manifestVersion = [regex]::Match($manifest, '(?m)^\s*version\s*=\s*"([^"]+)"').Groups[1].Value
$changelogVersion = [regex]::Match($changelog, '(?m)^##\s*\[([^]]+)\]').Groups[1].Value

if (-not $manifestVersion) {
  throw "could not read version from herdr-plugin.toml"
}

$versions = [ordered]@{
  "herdr-plugin.toml" = $manifestVersion
  "package.json" = [string]$package.version
  "web/package.json" = [string]$webPackage.version
  "CHANGELOG.md" = $changelogVersion
}

if ($versions.Values | Where-Object { $_ -ne $manifestVersion }) {
  Write-Error "version mismatch - all four must equal herdr-plugin.toml ($manifestVersion):`n$($versions.GetEnumerator() | ForEach-Object { "  $($_.Key): $($_.Value)" } | Out-String)"
}

Write-Output "OK version $manifestVersion consistent across manifest, package.json, web/package.json, CHANGELOG"
