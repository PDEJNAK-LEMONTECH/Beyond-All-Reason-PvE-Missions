<#  Headless load-test for a map (optionally with a Mission API scenario).
    Launches spring-headless on the given map for N seconds, then reports
    whether it loaded + ran, plus any fatal/error lines.  #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$MapName,   # full map name incl version, e.g. "FTL Collage 0.1"
    [string]$MissionPath,                       # optional, relative to singleplayer/ (mission_path modoption)
    [int]$Seconds = 30,
    [int]$AiCount = 1,
    [int]$StartPosType = 0,   # 0=fixed (sim auto-starts headless); 2=choose-in-game (waits for a human)
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
if (-not $DataDir) { $DataDir = Join-Path $env:LOCALAPPDATA 'Programs\Beyond-All-Reason\data' }
$eng = Get-ChildItem (Join-Path $DataDir 'engine') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$hl  = Join-Path $eng.FullName 'spring-headless.exe'
$gt='Beyond All Reason $VERSION'; $stf=Join-Path $DataDir '_script.txt'
if (Test-Path $stf) { $m=[regex]::Match((Get-Content $stf -Raw),'gametype\s*=\s*([^;\r\n]+)'); if($m.Success){$gt=$m.Groups[1].Value.Trim()} }

$sb=New-Object Text.StringBuilder
[void]$sb.AppendLine('[GAME]'); [void]$sb.AppendLine('{')
[void]$sb.AppendLine("`t[allyTeam0] { numallies = 0; }")
[void]$sb.AppendLine("`t[allyTeam1] { numallies = 0; }")
[void]$sb.AppendLine("`t[team0] { TeamLeader = 0; AllyTeam = 0; Side = Armada; RgbColor = 0 0.5 1; }")
for ($i=0; $i -lt $AiCount; $i++) {
  [void]$sb.AppendLine("`t[team$($i+1)] { TeamLeader = 0; AllyTeam = 1; Side = Armada; RgbColor = 0.9 0.1 0.29; }")
  [void]$sb.AppendLine("`t[ai$i] { Host = 0; Name = BARb$i; ShortName = BARb; Team = $($i+1); Version = stable; }")
}
[void]$sb.AppendLine("`t[player0] { Name = Tester; Team = 0; }")
$mo = "mission_path = $MissionPath; mission_difficulty = normal;"
if (-not $MissionPath) { $mo = '' }
if ($mo) { [void]$sb.AppendLine("`t[modoptions] { $mo }") }
[void]$sb.AppendLine("`tmapname = $MapName;")
[void]$sb.AppendLine("`tgametype = $gt;")
[void]$sb.AppendLine("`tstartpostype = $StartPosType;")
[void]$sb.AppendLine("`tishost = 1; hostip = 127.0.0.1; hostport = 0;")
[void]$sb.AppendLine("`tnumplayers = 1; numusers = $($AiCount+1);")
[void]$sb.AppendLine("`tmyplayername = Tester; nohelperais = 0; GameStartDelay = 0;")
[void]$sb.AppendLine('}')
$sp = Join-Path $env:TEMP 'mapext_loadtest.txt'
[IO.File]::WriteAllText($sp, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))

$log = Join-Path $DataDir 'infolog.txt'
$p = Start-Process -FilePath $hl -ArgumentList @('--write-dir',$DataDir,'--only-local',$sp) -PassThru -WindowStyle Hidden
Write-Host "launched pid $($p.Id) on '$MapName'; waiting ${Seconds}s..."
Start-Sleep -Seconds $Seconds
$alive = [bool](Get-Process -Id $p.Id -EA SilentlyContinue)
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue

# infolog.txt is recreated each run, so read the whole file
$fs=[IO.File]::Open($log,'Open','Read','ReadWrite'); $rd=New-Object IO.StreamReader($fs)
$new=$rd.ReadToEnd(); $rd.Close(); $fs.Close()
$lines = $new -split "`r?`n"
# real map/sim faults only; exclude known headless-GPU + unrelated-content noise
$fatal = $lines | Where-Object {
    ($_ -match 'Fatal|content_error|Failed to load map|Couldn..t load map|Map.*not found|Error in (Initialize|Load|GamePreload|GameFrame)') -and
    ($_ -notmatch 'icon=|FeatureDef|texture atlas|no GetInfo|GroundDecal|shader')
}
$good  = $lines | Where-Object { $_ -match 'using map|GameID:|took over control|\[Mission' }
Write-Host "`nprocess alive at ${Seconds}s (sim running = good): $alive"
Write-Host "`n--- key lines ---"; $good | Select-Object -Last 8 | ForEach-Object { $_ }
if ($fatal) { Write-Host "`n!!! FATAL/ERROR lines !!!"; $fatal | Select-Object -First 10 | ForEach-Object { $_ } }
else { Write-Host "`n(no fatal/content errors)" }
@{ alive=$alive; fatal=[bool]$fatal } | ConvertTo-Json -Compress
