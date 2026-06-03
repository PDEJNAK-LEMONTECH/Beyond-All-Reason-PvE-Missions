<#
  Opens the BAR Scenario Designer in a real browser.
  Use this instead of double-clicking designer.html if that opens in an editor
  or behaves oddly.  Prefers Chrome, then Edge, then the system default.
#>
$ErrorActionPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$html = Join-Path $here 'designer.html'
if (-not (Test-Path $html)) { Write-Error "designer.html not found next to this script."; exit 1 }
if (-not (Test-Path (Join-Path $here 'data.js'))) {
    Write-Warning "data.js is missing - run prepare_assets.ps1 first (maps/units won't load)."
}

# file:/// URL
$url = 'file:///' + ($html -replace '\\','/')

$chrome = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
$edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"

if ($chrome) {
    Write-Host "Opening in Chrome..."
    Start-Process $chrome $url
} elseif (Test-Path $edge) {
    Write-Host "Opening in Edge..."
    Start-Process $edge $url
} else {
    Write-Host "Opening in default browser..."
    Start-Process $url
}
