# compose_collage.ps1 -- dot-sourced by extend_map.ps1 (collage mode).
# Recipe "Archipelago Remix": a 1536x1024-square canvas. A low land plain forms
# the background; three land masses are stamped from the source map:
#   1. the FULL source as the main continent (upright -> reused tiles, perfect quality)
#   2. the source's top-left quadrant, ROTATED 180 deg, as a second isle
#   3. the source's centre, MIRRORED-X, as a third isle
# Transformed isles decode->transform->re-encode only their own tiles (appended to .smt).
# Stamps are spaced apart so their edges meet the plain (mesa/cliff coasts) -- no
# stamp-to-stamp seams to blend.

$newMapx = 1536   # 12*128 squares (12288 elmos)
$newMapy = 1024   #  8*128 squares ( 8192 elmos)

# background plain height: realHeight +40 -> ushort in source's [-50..950] scale
$bgReal   = 40.0
$bgHeight = [uint16]([math]::Round(($bgReal - $smf.minHeight) / ($smf.maxHeight - $smf.minHeight) * 65535))
$bgTile   = [int]$smf.tileIndex[0]

$smtObj = [MapExt.Smt]::Read($srcSmt.FullName)
Write-Host ("[collage] source .smt: {0} tiles, {1} bytes/tile" -f $smtObj.numTiles, $smtObj.bytesPerTile)

function New-Stamp($sx0,$sy0,$sx1,$sy1,$dx,$dy,$tf) {
    $s = New-Object MapExt.Stamp
    $s.sx0=$sx0; $s.sy0=$sy0; $s.sx1=$sx1; $s.sy1=$sy1; $s.dx=$dx; $s.dy=$dy; $s.tf=$tf
    return $s
}
$stamps = New-Object 'System.Collections.Generic.List[MapExt.Stamp]'
# source is 192x192 tiles; canvas is 384x256 tiles
$stamps.Add((New-Stamp 0 0 192 192   24  32  0))   # main continent (upright)
$stamps.Add((New-Stamp 0 0  96  96  268  16  1))   # NE isle, rotated 180
$stamps.Add((New-Stamp 48 48 144 144 264 150 2))   # SE isle, mirrored-X

$outSmt = Join-Path $work ($slug + '.smt')
$outSmf = Join-Path $work ($slug + '.smf')
Write-Host "[collage] composing $newMapx x $newMapy squares, bgHeight=$bgHeight, bgTile=$bgTile ..."
$d = [MapExt.Composer]::Build($smf, $smtObj, $newMapx, $newMapy, $bgHeight, $bgTile, $stamps, $outSmt)
$d.Write($outSmf)
Write-Host ("[collage] wrote .smf ({0:n0} B) + .smt ({1:n0} B, {2} tiles)" -f (Get-Item $outSmf).Length, (Get-Item $outSmt).Length, $smtObj.tiles.Count)

# start positions (elmos): player on the main continent, AI on the rotated NE isle.
# continent stamp dest tile origin (24,32); source team0 start was (1856,1187) elmos.
$playerX = (24*32) + 1856; $playerZ = (32*32) + 1187          # -> on the continent
$aiX     = (268+48)*32;    $aiZ     = (16+48)*32              # -> centre of NE isle
$script:TEAMS_LUA = ("`t`t[0] = {{startPos = {{x = {0}, z = {1}}}}},`n`t`t[1] = {{startPos = {{x = {2}, z = {3}}}}}," -f $playerX,$playerZ,$aiX,$aiZ)
Write-Host "[collage] start positions: player=($playerX,$playerZ) ai=($aiX,$aiZ)"

# expose for packaging + later milestones
$script:OUT_SMF = $outSmf
$script:OUT_SMT = $outSmt
$script:NEW_MAPX = $newMapx
$script:NEW_MAPY = $newMapy
