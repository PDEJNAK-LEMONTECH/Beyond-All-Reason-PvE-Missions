<#
.SYNOPSIS
    Local launcher server for the BAR Scenario Designer.

.DESCRIPTION
    Serves the designer over http://localhost so the in-app "Test Play" button can
    write your mission file and launch the game in one click (a file:// page can't
    start a program; this tiny local server can).

    Endpoints:
      GET  /<file>   - serve the designer's static files (designer.html, data.js, maps/, icons/, ...)
      POST /play     - write the mission .lua into the repo, build a start script, launch spring.exe
      POST /save     - write a mission/scenario file into the repo (Save buttons)

    Uses a raw TcpListener (not HttpListener) so it needs no admin / netsh urlacl.
    Localhost only. Ctrl+C to stop.

.NOTES  Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [int]$Port = 8777,
    [string]$DataDir,                 # BAR data dir (auto-detected)
    [string]$EngineExe,               # spring.exe (auto: newest engine)
    [switch]$NoOpen,                  # don't auto-open the browser
    [switch]$DryRun                   # /play writes files but does NOT launch (for testing)
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$toolDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $toolDir '..\..')).Path
if (-not $DataDir) { $DataDir = Join-Path $env:LOCALAPPDATA 'Programs\Beyond-All-Reason\data' }

# Resolve the engine executable (newest recoil_* folder)
if (-not $EngineExe) {
    $eng = Get-ChildItem (Join-Path $DataDir 'engine') -Directory -ErrorAction SilentlyContinue |
           Sort-Object Name -Descending | Select-Object -First 1
    if ($eng) { $EngineExe = Join-Path $eng.FullName 'spring.exe' }
}
# gametype = the dev game's archive name; read from the last dev launch if available
$gametype = 'Beyond All Reason $VERSION'
$scriptTxt = Join-Path $DataDir '_script.txt'
if (Test-Path $scriptTxt) {
    $m = [regex]::Match((Get-Content $scriptTxt -Raw), 'gametype\s*=\s*([^;\r\n]+)')
    if ($m.Success) { $gametype = $m.Groups[1].Value.Trim() }
}

Write-Host "Scenario Designer server"
Write-Host "  tool dir : $toolDir"
Write-Host "  repo     : $repoRoot"
Write-Host "  data     : $DataDir"
Write-Host "  engine   : $EngineExe"
Write-Host "  gametype : $gametype"
Write-Host "  URL      : http://localhost:$Port/designer.html"
if ($DryRun) { Write-Host "  (DryRun: /play will NOT launch the game)" -ForegroundColor Yellow }
Write-Host ""

$mime = @{ '.html'='text/html; charset=utf-8'; '.js'='application/javascript; charset=utf-8';
  '.css'='text/css; charset=utf-8'; '.json'='application/json'; '.png'='image/png';
  '.jpg'='image/jpeg'; '.jpeg'='image/jpeg'; '.svg'='image/svg+xml'; '.ico'='image/x-icon' }

function Send-Response($stream, [string]$status, [string]$ctype, [byte[]]$bytes) {
    if (-not $bytes) { $bytes = New-Object byte[] 0 }
    $head = "HTTP/1.1 $status`r`nContent-Type: $ctype`r`nContent-Length: $($bytes.Length)`r`n" +
            "Cache-Control: no-store`r`nConnection: close`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($hb, 0, $hb.Length)
    if ($bytes.Length) { $stream.Write($bytes, 0, $bytes.Length) }
    $stream.Flush()
}
function Send-Json($stream, [string]$status, $obj) {
    Send-Response $stream $status 'application/json' ([Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress)))
}
function Read-Request($stream) {
    $hbytes = New-Object System.Collections.Generic.List[byte]
    $one = New-Object byte[] 1; $a=0;$b=0;$c=0;$d=0
    while ($true) {
        $n = $stream.Read($one, 0, 1); if ($n -le 0) { break }
        $hbytes.Add($one[0]); $a=$b;$b=$c;$c=$d;$d=$one[0]
        if ($a -eq 13 -and $b -eq 10 -and $c -eq 13 -and $d -eq 10) { break }
    }
    $headerText = [Text.Encoding]::ASCII.GetString($hbytes.ToArray())
    $cl = 0; if ($headerText -match '(?im)^Content-Length:\s*(\d+)') { $cl = [int]$Matches[1] }
    $body = New-Object byte[] $cl; $read = 0
    while ($read -lt $cl) { $r = $stream.Read($body, $read, $cl - $read); if ($r -le 0) { break }; $read += $r }
    return @{ header = $headerText; body = $body }
}

function Handle-Play($json) {
    $name = ($json.missionFile -replace '[^A-Za-z0-9_]', ''); if (-not $name) { $name = 'scenario' }
    $missionsDir = Join-Path $repoRoot 'singleplayer\missions'
    New-Item -ItemType Directory -Force -Path $missionsDir | Out-Null
    $missionPath = Join-Path $missionsDir "$name.lua"
    [IO.File]::WriteAllText($missionPath, [string]$json.mission, (New-Object Text.UTF8Encoding($false)))

    $script = ([string]$json.startscript).Replace('__GAMETYPE__', $gametype)
    $tmp = Join-Path $env:TEMP "bar_play_$name.txt"
    [IO.File]::WriteAllText($tmp, $script, (New-Object Text.UTF8Encoding($false)))

    Write-Host ("[play] mission -> {0}" -f $missionPath) -ForegroundColor Cyan
    Write-Host ("[play] script  -> {0}" -f $tmp) -ForegroundColor Cyan
    if ($DryRun) { return @{ ok = $true; detail = 'DryRun (not launched)'; mission = $missionPath; launch = $false } }
    if (-not (Test-Path $EngineExe)) { return @{ ok = $false; error = "spring.exe not found at $EngineExe"; launch = $false } }
    # launch is done by the caller AFTER the HTTP reply is sent, so the browser
    # always gets its response (avoids a false "Launch failed" if the client drops)
    return @{ ok = $true; detail = "launching ($name)"; mission = $missionPath; script = $tmp; launch = $true }
}

function Handle-Save($json) {
    $name = ($json.name -replace '[^A-Za-z0-9_]', ''); if (-not $name) { return @{ ok=$false; error='bad name' } }
    $sub = if ($json.kind -eq 'scenario') { 'singleplayer\scenarios' } else { 'singleplayer\missions' }
    $dir = Join-Path $repoRoot $sub; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Join-Path $dir "$name.lua"
    [IO.File]::WriteAllText($path, [string]$json.text, (New-Object Text.UTF8Encoding($false)))
    Write-Host ("[save] -> {0}" -f $path) -ForegroundColor Cyan
    return @{ ok = $true; path = $path }
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
try { $listener.Start() }
catch { Write-Error "Could not bind port $Port. Is the server already running? ($_)"; exit 1 }

$openUrl = "http://localhost:$Port/designer.html"
function Open-Designer {
    $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") |
              Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($chrome) { Start-Process $chrome $script:openUrl } else { Start-Process $script:openUrl }
}
if (-not $NoOpen) { Open-Designer }

# ---- system-tray icon so the running server is visible & stoppable ----------
$script:stop = $false
$trayIcon = $null
try { if (Test-Path $EngineExe) { $trayIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($EngineExe) } } catch {}
if (-not $trayIcon) { $trayIcon = [System.Drawing.SystemIcons]::Application }

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $trayIcon
$tray.Text = "BAR Scenario Designer - localhost:$Port"   # tooltip (<=63 chars)
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miTitle = $menu.Items.Add("BAR Scenario Designer server"); $miTitle.Enabled = $false
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miOpen = $menu.Items.Add("Open designer  (localhost:$Port)"); $miOpen.add_Click({ Open-Designer })
$miMiss = $menu.Items.Add("Open missions folder"); $miMiss.add_Click({ Start-Process (Join-Path $script:repoRoot 'singleplayer\missions') })
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miStop = $menu.Items.Add("Stop server"); $miStop.add_Click({ $script:stop = $true })
$tray.ContextMenuStrip = $menu
$tray.add_MouseDoubleClick({ Open-Designer })
$tray.ShowBalloonTip(3000, "Scenario Designer running", "Serving localhost:$Port. Right-click this tray icon to open or stop.", [System.Windows.Forms.ToolTipIcon]::Info)

Write-Host "Listening... (tray icon active; right-click it to stop, or Ctrl+C)`n"

while (-not $script:stop) {
    if (-not $listener.Pending()) {
        [System.Windows.Forms.Application]::DoEvents()   # keep the tray menu responsive
        Start-Sleep -Milliseconds 40
        continue
    }
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $req = Read-Request $stream
        $line = ($req.header -split "`r`n")[0]
        $parts = $line -split ' '
        $method = $parts[0]; $rawPath = $parts[1]
        $path = ($rawPath -split '\?')[0]
        if ($method -eq 'POST') {
            $json = $null
            try { $json = [Text.Encoding]::UTF8.GetString($req.body) | ConvertFrom-Json } catch {}
            if ($null -eq $json) { Send-Json $stream '400 Bad Request' @{ ok=$false; error='bad json' } }
            elseif ($path -eq '/play') {
                $res = Handle-Play $json
                Send-Json $stream '200 OK' $res
                if ($res.launch) {
                    try { Start-Process -FilePath $EngineExe -ArgumentList @('--write-dir', $DataDir, $res.script) | Out-Null
                          Write-Host "[play] launched spring.exe" -ForegroundColor Green }
                    catch { Write-Warning "launch failed: $_" }
                }
            }
            elseif ($path -eq '/save') { Send-Json $stream '200 OK' (Handle-Save $json) }
            else { Send-Json $stream '404 Not Found' @{ ok=$false; error='no route' } }
        }
        else {  # GET - serve static files from the tool dir
            if ($path -eq '/' -or $path -eq '') { $path = '/designer.html' }
            $rel = $path.TrimStart('/') -replace '/', '\'
            $full = Join-Path $toolDir $rel
            $resolved = $null
            try { $resolved = (Resolve-Path $full -ErrorAction Stop).Path } catch {}
            if ($resolved -and $resolved.StartsWith($toolDir, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path $resolved -PathType Leaf)) {
                $ext = [IO.Path]::GetExtension($resolved).ToLower()
                $ct = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
                Send-Response $stream '200 OK' $ct ([IO.File]::ReadAllBytes($resolved))
            } else {
                Send-Response $stream '404 Not Found' 'text/plain' ([Text.Encoding]::ASCII.GetBytes('404'))
            }
        }
    } catch { Write-Warning "request error: $_" }
    finally { $client.Close() }
}

# cleanup on "Stop server"
$tray.Visible = $false; $tray.Dispose()
try { $listener.Stop() } catch {}
Write-Host "Server stopped."
