# ============================================================================
#  host_launcher.ps1 -- one-window GUI to host a modded BAR PvE scenario for a
#  friend over the internet (Windows direct host). See tools/multiplayer/README.md.
#
#  Launch it via host_launcher.cmd (passes -ExecutionPolicy Bypass; this PC's
#  policy is Restricted, so a double-clicked .ps1 would die otherwise).
#
#  What it does:
#    * Lists the PvE scenarios in the CLEAN multiplayer clone
#      (data\games\BAR-PvE-Missions.sdd) -- the same files your friend has after a
#      `git pull`, so you can only host something he can actually load.
#    * Reads each scenario's embedded SCENARIO_DESIGNER_V1 block for its map +
#      AI count, so the match is wired up automatically.
#    * Opens the firewall + shows your public IP (you still port-forward the router).
#    * Generates a start script OUTSIDE the .sdd (so it never changes the synced
#      game archive) and launches spring.exe straight into the match.
# ============================================================================
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---- paths ------------------------------------------------------------------
$BarRoot   = Join-Path $env:LOCALAPPDATA 'Programs\Beyond-All-Reason'
$DataDir   = Join-Path $BarRoot 'data'
$GamesDir  = Join-Path $DataDir 'games'
$MapsDir   = Join-Path $DataDir 'maps'
$EngineDir = Join-Path $DataDir 'engine'
$CleanSdd  = Join-Path $GamesDir 'BAR-PvE-Missions.sdd'   # clean clone we host from
$ForkUrl   = 'https://github.com/PDEJNAK-LEMONTECH/Beyond-All-Reason-PvE-Missions.git'
$ForkBranch = 'pve-missions'
$SessionScript = Join-Path $DataDir 'pve_host_session.txt'  # generated, outside any .sdd

# data.js (from the scenario designer) gives map display-names for map-agnostic
# scenarios. Optional; we fall back to .sd7 basenames if it's missing.
$DataJs = Join-Path $PSScriptRoot '..\scenario_designer\data.js'

# ---- helpers ----------------------------------------------------------------
function Get-InstalledMaps {
    # Returns @(@{File=...; Name=...}). Prefers data.js display names; falls back
    # to .sd7 filenames present in data\maps.
    $present = @{}
    if (Test-Path $MapsDir) {
        Get-ChildItem -Path $MapsDir -Filter *.sd7 -ErrorAction SilentlyContinue |
            ForEach-Object { $present[$_.Name.ToLower()] = $true }
    }
    $out = @()
    if (Test-Path $DataJs) {
        try {
            $txt = Get-Content -Raw -LiteralPath $DataJs
            # data.js holds BOTH window.BAR_MAPS and window.BAR_UNITS -- grab only the maps array.
            $mm = [regex]::Match($txt, '(?s)window\.BAR_MAPS\s*=\s*(\[.*?\])\s*;')
            if ($mm.Success) {
                foreach ($m in (ConvertFrom-Json $mm.Groups[1].Value)) {
                    if ($present[$m.file.ToLower()]) { $out += @{ File = $m.file; Name = $m.name } }
                }
            }
        } catch { }
    }
    if ($out.Count -eq 0 -and (Test-Path $MapsDir)) {
        foreach ($k in $present.Keys) {
            $out += @{ File = $k; Name = [IO.Path]::GetFileNameWithoutExtension($k) }
        }
    }
    return ($out | Sort-Object { $_.Name })
}

function Test-MapInstalled([string]$sd7File) {
    if (-not $sd7File) { return $false }
    return (Test-Path (Join-Path $MapsDir $sd7File))
}

function Get-Scenarios([string]$missionsDir) {
    # Returns scenario objects discovered from <clone>\singleplayer\missions\*.lua.
    $list = @()
    if (-not (Test-Path $missionsDir)) { return $list }
    foreach ($f in (Get-ChildItem -Path $missionsDir -Filter *.lua -ErrorAction SilentlyContinue)) {
        $text = Get-Content -Raw -LiteralPath $f.FullName
        $title = $f.BaseName
        $mapName = $null; $mapFile = $null; $aiCount = 1; $hasBlock = $false
        $m = [regex]::Match($text, '(?s)SCENARIO_DESIGNER_V1\s*(\{.*?\})\s*\]==\]')
        if ($m.Success) {
            try {
                $b = ConvertFrom-Json $m.Groups[1].Value
                $hasBlock = $true
                if ($b.meta -and $b.meta.title) { $title = $b.meta.title }
                if ($b.map) { $mapName = $b.map.name; $mapFile = $b.map.file }
                if ($null -ne $b.aiCount) { $aiCount = [int]$b.aiCount }
            } catch { }
        }
        $list += [pscustomobject]@{
            Title       = $title
            MissionPath = "missions/$($f.Name)"
            MapName     = $mapName        # $null => map-agnostic (pick a map)
            MapFile     = $mapFile
            AiCount     = [Math]::Max(1, $aiCount)
            HasBlock    = $hasBlock
            File        = $f.Name
        }
    }
    return ($list | Sort-Object Title)
}

function Get-GameType([string]$sddPath) {
    # gametype string = "<modinfo name> <modinfo version>" (for our dev .sdd this is
    # the literal "Beyond All Reason $VERSION").
    $mi = Join-Path $sddPath 'modinfo.lua'
    if (-not (Test-Path $mi)) { return $null }
    $t = Get-Content -Raw -LiteralPath $mi
    $name = [regex]::Match($t, "name\s*=\s*'([^']*)'").Groups[1].Value
    $ver  = [regex]::Match($t, "version\s*=\s*'([^']*)'").Groups[1].Value
    if (-not $name) { return $null }
    if ($ver) { return "$name $ver" } else { return $name }
}

function Get-Engines {
    if (-not (Test-Path $EngineDir)) { return @() }
    return (Get-ChildItem -Path $EngineDir -Directory | Sort-Object Name -Descending | ForEach-Object { $_.Name })
}

function Get-PublicIP {
    foreach ($u in @('https://api.ipify.org','https://ifconfig.me/ip','https://icanhazip.com')) {
        try { return (Invoke-RestMethod -Uri $u -TimeoutSec 6).ToString().Trim() } catch { }
    }
    return $null
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function New-HostStartScript {
    param(
        [string]$HostName, [string]$FriendName, [int]$Port, [string]$MapName,
        [string]$MissionPath, [string]$Difficulty, [string]$Deathmode,
        [int]$AiCount, [string]$GameType, [bool]$DebugLos
    )
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('// Generated by host_launcher.ps1 -- do NOT put this inside a .sdd (it would')
    [void]$sb.AppendLine('// change the synced game archive and break your friend''s join).')
    [void]$sb.AppendLine('[Game]')
    [void]$sb.AppendLine('{')
    [void]$sb.AppendLine('    [modoptions]')
    [void]$sb.AppendLine('    {')
    [void]$sb.AppendLine("        mission_path = $MissionPath;")
    [void]$sb.AppendLine("        mission_difficulty = $Difficulty;")
    [void]$sb.AppendLine("        deathmode = $Deathmode;")
    if ($DebugLos) { [void]$sb.AppendLine('        mission_debug_los = 1;') }
    [void]$sb.AppendLine('    }')
    [void]$sb.AppendLine('    [allyTeam0] { numallies = 0; }')
    [void]$sb.AppendLine('    [allyTeam1] { numallies = 0; }')
    # humans on allyTeam0
    [void]$sb.AppendLine('    [team0] { TeamLeader = 0; AllyTeam = 0; Side = Armada; RgbColor = 0 0.5 1; }')
    [void]$sb.AppendLine('    [team1] { TeamLeader = 1; AllyTeam = 0; Side = Armada; RgbColor = 0 1 0.5; }')
    # AIs on allyTeam1 (team2..)
    for ($k = 0; $k -lt $AiCount; $k++) {
        $tid = 2 + $k
        [void]$sb.AppendLine("    [team$tid] { TeamLeader = 0; AllyTeam = 1; Side = Cortex; RgbColor = 1 0.2 0.2; }")
    }
    for ($k = 0; $k -lt $AiCount; $k++) {
        $tid = 2 + $k
        [void]$sb.AppendLine("    [ai$k] { Host = 0; IsFromDemo = 0; Name = BARbarianAI($($k+1)); ShortName = BARb; Team = $tid; Version = stable; }")
    }
    [void]$sb.AppendLine("    [player0] { Name = $HostName; Team = 0; rank = 0; IsFromDemo = 0; }")
    [void]$sb.AppendLine("    [player1] { Name = $FriendName; Team = 1; rank = 0; IsFromDemo = 0; }")
    [void]$sb.AppendLine('    hostip = 0.0.0.0;')
    [void]$sb.AppendLine("    hostport = $Port;")
    [void]$sb.AppendLine('    ishost = 1;')
    [void]$sb.AppendLine("    myplayername = $HostName;")
    [void]$sb.AppendLine('    numplayers = 2;')
    [void]$sb.AppendLine("    numusers = $(2 + $AiCount);")
    [void]$sb.AppendLine('    startpostype = 2;')
    [void]$sb.AppendLine("    mapname = $MapName;")
    [void]$sb.AppendLine("    gametype = $GameType;")
    [void]$sb.AppendLine('    GameStartDelay = 5;')
    [void]$sb.AppendLine('    nohelperais = 0;')
    [void]$sb.AppendLine('}')
    return $sb.ToString()
}

# ============================================================================
#  GUI
# ============================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = 'BAR PvE -- Host a match for a friend'
$form.Size = New-Object System.Drawing.Size(660, 660)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

$font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.Font = $font

function New-Label([string]$text,[int]$x,[int]$y,[int]$w=180) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x,$y)
    $l.Size = New-Object System.Drawing.Size($w,22); $form.Controls.Add($l); return $l
}

$y = 12
New-Label 'Clean clone (host from here):' 12 $y 200 | Out-Null
$lblClone = New-Label '' 215 $y 420
$lblClone.ForeColor = [System.Drawing.Color]::DimGray
$y += 26

$btnClone = New-Object System.Windows.Forms.Button
$btnClone.Text = 'Create / Sync clone'
$btnClone.Location = New-Object System.Drawing.Point(12, $y)
$btnClone.Size = New-Object System.Drawing.Size(150, 26)
$form.Controls.Add($btnClone)
$y += 38

New-Label 'Scenario:' 12 $y | Out-Null
$cboScenario = New-Object System.Windows.Forms.ComboBox
$cboScenario.Location = New-Object System.Drawing.Point(120, $y)
$cboScenario.Size = New-Object System.Drawing.Size(510, 24)
$cboScenario.DropDownStyle = 'DropDownList'
$form.Controls.Add($cboScenario)
$y += 30

$lblScenInfo = New-Label '' 120 $y 510
$lblScenInfo.Size = New-Object System.Drawing.Size(510, 36)
$lblScenInfo.ForeColor = [System.Drawing.Color]::DimGray
$y += 42

New-Label 'Map:' 12 $y | Out-Null
$cboMap = New-Object System.Windows.Forms.ComboBox
$cboMap.Location = New-Object System.Drawing.Point(120, $y)
$cboMap.Size = New-Object System.Drawing.Size(510, 24)
$cboMap.DropDownStyle = 'DropDownList'
$form.Controls.Add($cboMap)
$y += 36

New-Label 'Your name:' 12 $y | Out-Null
$txtHost = New-Object System.Windows.Forms.TextBox
$txtHost.Location = New-Object System.Drawing.Point(120, $y); $txtHost.Size = New-Object System.Drawing.Size(200,24)
$txtHost.Text = 'Dejnol'; $form.Controls.Add($txtHost)
New-Label "Friend's name:" 340 $y 90 | Out-Null
$txtFriend = New-Object System.Windows.Forms.TextBox
$txtFriend.Location = New-Object System.Drawing.Point(435, $y); $txtFriend.Size = New-Object System.Drawing.Size(195,24)
$form.Controls.Add($txtFriend)
$y += 34

New-Label 'UDP port:' 12 $y | Out-Null
$txtPort = New-Object System.Windows.Forms.TextBox
$txtPort.Location = New-Object System.Drawing.Point(120, $y); $txtPort.Size = New-Object System.Drawing.Size(90,24)
$txtPort.Text = '8452'; $form.Controls.Add($txtPort)
New-Label 'Difficulty:' 240 $y 70 | Out-Null
$cboDiff = New-Object System.Windows.Forms.ComboBox
$cboDiff.Location = New-Object System.Drawing.Point(315, $y); $cboDiff.Size = New-Object System.Drawing.Size(120,24)
$cboDiff.DropDownStyle = 'DropDownList'
[void]$cboDiff.Items.AddRange(@('beginner','normal','hard')); $cboDiff.SelectedItem = 'normal'
$form.Controls.Add($cboDiff)
$y += 34

New-Label 'Eliminate when:' 12 $y 100 | Out-Null
$cboDeath = New-Object System.Windows.Forms.ComboBox
$cboDeath.Location = New-Object System.Drawing.Point(120, $y); $cboDeath.Size = New-Object System.Drawing.Size(170,24)
$cboDeath.DropDownStyle = 'DropDownList'
[void]$cboDeath.Items.AddRange(@('own_com','com','killall','neverend')); $cboDeath.SelectedItem = 'own_com'
$form.Controls.Add($cboDeath)
$chkLos = New-Object System.Windows.Forms.CheckBox
$chkLos.Text = 'Infinite LOS (debug)'; $chkLos.Location = New-Object System.Drawing.Point(315, $y)
$chkLos.Size = New-Object System.Drawing.Size(180,24); $form.Controls.Add($chkLos)
$y += 34

New-Label 'Engine:' 12 $y | Out-Null
$cboEngine = New-Object System.Windows.Forms.ComboBox
$cboEngine.Location = New-Object System.Drawing.Point(120, $y); $cboEngine.Size = New-Object System.Drawing.Size(300,24)
$cboEngine.DropDownStyle = 'DropDownList'
$form.Controls.Add($cboEngine)
$y += 40

$btnNet = New-Object System.Windows.Forms.Button
$btnNet.Text = 'Prep network (firewall + show my IP)'
$btnNet.Location = New-Object System.Drawing.Point(12, $y); $btnNet.Size = New-Object System.Drawing.Size(280,30)
$form.Controls.Add($btnNet)

$btnHost = New-Object System.Windows.Forms.Button
$btnHost.Text = 'Host & Play'
$btnHost.Location = New-Object System.Drawing.Point(470, $y); $btnHost.Size = New-Object System.Drawing.Size(160,30)
$btnHost.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnHost)
$y += 38

$lblIP = New-Object System.Windows.Forms.Label
$lblIP.Location = New-Object System.Drawing.Point(12, $y); $lblIP.Size = New-Object System.Drawing.Size(620,26)
$lblIP.Font = New-Object System.Drawing.Font('Consolas', 11, [System.Drawing.FontStyle]::Bold)
$lblIP.ForeColor = [System.Drawing.Color]::DarkGreen
$form.Controls.Add($lblIP)
$y += 30

$log = New-Object System.Windows.Forms.TextBox
$log.Location = New-Object System.Drawing.Point(12, $y)
$log.Size = New-Object System.Drawing.Size(620, 160)
$log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'
$log.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($log)

function Write-Log([string]$m) { $log.AppendText(("{0}`r`n" -f $m)) }

# ---- state + populate -------------------------------------------------------
$script:Scenarios = @()
$script:Maps = Get-InstalledMaps

function Update-CloneStatus {
    if (Test-Path $CleanSdd) {
        $head = ''
        try { $head = (git -C $CleanSdd rev-parse --short HEAD 2>$null) } catch { }
        $lblClone.Text = "$CleanSdd  @ $head"
        $lblClone.ForeColor = [System.Drawing.Color]::DimGray
    } else {
        $lblClone.Text = 'NOT FOUND -- click "Create / Sync clone" to set it up.'
        $lblClone.ForeColor = [System.Drawing.Color]::Firebrick
    }
}

function Reload-Scenarios {
    $missionsDir = Join-Path $CleanSdd 'singleplayer\missions'
    $script:Scenarios = Get-Scenarios $missionsDir
    $cboScenario.Items.Clear()
    foreach ($s in $script:Scenarios) { [void]$cboScenario.Items.Add($s.Title) }
    if ($cboScenario.Items.Count -gt 0) { $cboScenario.SelectedIndex = 0 }
    else { $lblScenInfo.Text = 'No scenarios found in the clean clone. Create/sync it, then `git pull` after authoring.' }
}

function On-ScenarioChanged {
    $i = $cboScenario.SelectedIndex
    if ($i -lt 0) { return }
    $s = $script:Scenarios[$i]
    if ($s.MapName) {
        # dedicated scenario: map is fixed by the scenario
        $cboMap.Items.Clear(); [void]$cboMap.Items.Add($s.MapName); $cboMap.SelectedIndex = 0
        $cboMap.Enabled = $false
        $installed = Test-MapInstalled $s.MapFile
        $warn = if ($installed) { 'map installed' } else { 'MAP NOT INSTALLED -- click "Create / Sync" area note / pr-downloader it' }
        $lblScenInfo.Text = "$($s.MissionPath)  |  AIs: $($s.AiCount)  |  map: $($s.MapName)  ($warn)"
    } else {
        # map-agnostic (e.g. the demo): let the host pick any installed map
        $cboMap.Items.Clear()
        foreach ($m in $script:Maps) { [void]$cboMap.Items.Add($m.Name) }
        if ($cboMap.Items.Count -gt 0) { $cboMap.SelectedIndex = 0 }
        $cboMap.Enabled = $true
        $lblScenInfo.Text = "$($s.MissionPath)  |  AIs: $($s.AiCount)  |  map-agnostic -- pick any installed map above"
    }
}

$cboScenario.Add_SelectedIndexChanged({ On-ScenarioChanged })

foreach ($e in (Get-Engines)) { [void]$cboEngine.Items.Add($e) }
if ($cboEngine.Items.Count -gt 0) { $cboEngine.SelectedIndex = 0 }

# ---- button handlers --------------------------------------------------------
$btnClone.Add_Click({
    try {
        if (-not (Test-Path $CleanSdd)) {
            Write-Log "Cloning fork into $CleanSdd (one-time, may be large)..."
            $form.Cursor = 'WaitCursor'
            git clone --branch $ForkBranch --recurse-submodules $ForkUrl $CleanSdd 2>&1 | ForEach-Object { Write-Log $_ }
        } else {
            Write-Log "Syncing clean clone (git pull + submodule update)..."
            $form.Cursor = 'WaitCursor'
            git -C $CleanSdd pull 2>&1 | ForEach-Object { Write-Log $_ }
            git -C $CleanSdd submodule update --init --recursive 2>&1 | ForEach-Object { Write-Log $_ }
        }
        $dev = Join-Path $BarRoot 'devmode.txt'
        if (-not (Test-Path $dev)) { New-Item -ItemType File -Force $dev | Out-Null; Write-Log 'Wrote devmode.txt' }
        Update-CloneStatus
        Reload-Scenarios
        Write-Log 'Clone ready.'
    } catch {
        Write-Log "ERROR: $($_.Exception.Message)"
    } finally { $form.Cursor = 'Default' }
})

$btnNet.Add_Click({
    $port = 0
    if (-not [int]::TryParse($txtPort.Text.Trim(), [ref]$port)) { Write-Log 'Invalid port.'; return }
    $ruleName = "BAR PvE Host $port"
    if (Test-IsAdmin) {
        try {
            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol UDP -LocalPort $port -Action Allow -ErrorAction Stop | Out-Null
            Write-Log "Firewall: allowed inbound UDP $port."
        } catch { Write-Log "Firewall rule may already exist or failed: $($_.Exception.Message)" }
    } else {
        Write-Log 'Not elevated -- requesting admin to add the firewall rule...'
        $cmd = "New-NetFirewallRule -DisplayName '$ruleName' -Direction Inbound -Protocol UDP -LocalPort $port -Action Allow"
        try { Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-Command',$cmd -Wait; Write-Log 'Firewall rule requested.' }
        catch { Write-Log "Run this in an admin PowerShell: $cmd" }
    }
    Write-Log "REMINDER: port-forward UDP $port on your router to THIS PC."
    $ip = Get-PublicIP
    if ($ip) { $lblIP.Text = "Your public IP: $ip   (port $port)  -- tell your friend"; Write-Log "Public IP: $ip" }
    else { $lblIP.Text = 'Could not fetch public IP -- check https://whatismyip.com'; Write-Log 'Public IP lookup failed.' }
})

$btnHost.Add_Click({
    try {
        if (-not (Test-Path $CleanSdd)) { Write-Log 'No clean clone -- click "Create / Sync clone" first.'; return }
        $i = $cboScenario.SelectedIndex
        if ($i -lt 0) { Write-Log 'Pick a scenario.'; return }
        $s = $script:Scenarios[$i]
        $hostName = $txtHost.Text.Trim(); $friendName = $txtFriend.Text.Trim()
        if (-not $hostName -or -not $friendName) { Write-Log 'Fill in both player names.'; return }
        $port = 0; if (-not [int]::TryParse($txtPort.Text.Trim(), [ref]$port)) { Write-Log 'Invalid port.'; return }

        # resolve map name (display name for the start script)
        $mapName = if ($s.MapName) { $s.MapName } else { [string]$cboMap.SelectedItem }
        if (-not $mapName) { Write-Log 'Pick a map.'; return }

        # map installed?
        $mapFile = if ($s.MapFile) { $s.MapFile } else { ($script:Maps | Where-Object { $_.Name -eq $mapName } | Select-Object -First 1).File }
        if ($mapFile -and -not (Test-MapInstalled $mapFile)) {
            Write-Log "Map '$mapName' not installed. Fetch it first with pr-downloader (see README)."; return
        }

        $gameType = Get-GameType $CleanSdd
        if (-not $gameType) { Write-Log 'Could not read gametype from modinfo.lua.'; return }

        $engine = [string]$cboEngine.SelectedItem
        $springExe = Join-Path (Join-Path $EngineDir $engine) 'spring.exe'
        if (-not (Test-Path $springExe)) { Write-Log "spring.exe not found for engine $engine."; return }

        $script = New-HostStartScript -HostName $hostName -FriendName $friendName -Port $port `
            -MapName $mapName -MissionPath $s.MissionPath -Difficulty ([string]$cboDiff.SelectedItem) `
            -Deathmode ([string]$cboDeath.SelectedItem) -AiCount $s.AiCount -GameType $gameType -DebugLos ($chkLos.Checked)

        Set-Content -LiteralPath $SessionScript -Value $script -Encoding ASCII
        Write-Log "Wrote start script: $SessionScript"
        Write-Log "Scenario '$($s.Title)' | map '$mapName' | AIs $($s.AiCount) | gametype '$gameType'"
        Write-Log "Launching $engine ..."

        Start-Process -FilePath $springExe -ArgumentList @('--write-dir', $DataDir, $SessionScript) -WorkingDirectory (Split-Path $springExe)
        Write-Log 'spring.exe launched. Your friend joins with join.cmd <your-ip> <port> once you are in.'
    } catch {
        Write-Log "ERROR: $($_.Exception.Message)"
    }
})

# ---- init -------------------------------------------------------------------
Update-CloneStatus
Reload-Scenarios
On-ScenarioChanged
Write-Log 'Ready. 1) Create/Sync clone  2) pick scenario  3) Prep network  4) Host & Play.'
Write-Log 'Co-op note: both humans share allyTeam 0. If a scenario sets one human start, both commanders'
Write-Log 'land on it at frame 1 -- just move them apart, or author distinct human positions.'

[void]$form.ShowDialog()
