<#
.SYNOPSIS
    One-time asset prep for the BAR Scenario Designer.

.DESCRIPTION
    Builds the data the visual designer needs to run fully offline:

      * maps/<sd7>.jpg   - a minimap thumbnail for every installed map
      * data.js          - window.BAR_MAPS  (name, real world size in elmos, thumb)
                           window.BAR_UNITS (def name, label, faction, category)

    Why a prep step at all?  The designer must draw each map with its TRUE
    aspect ratio.  The minimap shipped inside a map (maps/mini.png) is always a
    square 1024x1024 image, so it cannot tell us the real proportions.  The real
    dimensions live in the .smf map-file header (ints "mapx"/"mapy" at byte
    offsets 24 and 28; world size in elmos = value * 8).  We read those, extract
    the square minimap, and let the designer un-squish it into the correct rect.

    Map display names (needed for the start-script "mapname=") come from the
    engine's ArchiveCache, not the file name.

.NOTES
    Windows PowerShell 5.1 compatible.  Requires 7-Zip and an installed BAR.
    Re-run it whenever you install new maps.
#>
[CmdletBinding()]
param(
    # BAR data dir (contains maps\, cache\). Auto-detected if omitted.
    [string]$DataDir,
    # Path to 7z.exe. Auto-detected if omitted.
    [string]$SevenZip,
    # Longest edge of the generated thumbnails, in pixels.
    [int]$ThumbSize = 512,
    # Skip re-extracting maps whose thumbnail already exists.
    [switch]$SkipExistingThumbs
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$mapsOut   = Join-Path $scriptDir 'maps'
$dataJs    = Join-Path $scriptDir 'data.js'

# ---------------------------------------------------------------------------
# Locate dependencies
# ---------------------------------------------------------------------------
if (-not $DataDir) {
    $DataDir = Join-Path $env:LOCALAPPDATA 'Programs\Beyond-All-Reason\data'
}
if (-not (Test-Path $DataDir)) {
    throw "BAR data dir not found at '$DataDir'. Pass -DataDir explicitly."
}
$mapsDir  = Join-Path $DataDir 'maps'
$cacheLua = Join-Path $DataDir 'cache\ArchiveCache20.lua'

if (-not $SevenZip) {
    $candidates = @(
        'C:\Program Files\7-Zip\7z.exe',
        'C:\Program Files (x86)\7-Zip\7z.exe',
        (Get-Command 7z -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
    )
    $SevenZip = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $SevenZip -or -not (Test-Path $SevenZip)) {
    throw "7-Zip not found. Install it or pass -SevenZip 'path\to\7z.exe'."
}

Write-Host "Repo root : $repoRoot"
Write-Host "BAR data  : $DataDir"
Write-Host "7-Zip     : $SevenZip"
Write-Host ""

New-Item -ItemType Directory -Force -Path $mapsOut | Out-Null
Add-Type -AssemblyName System.Drawing

# DXT1 decoder for the minimap embedded in every .smf (universal across maps,
# unlike the optional/variously-named external mini.png/mini.dds/mini.bmp).
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

public static class SmfMini {
    // Returns the 1024x1024 minimap from an .smf, or null if absent/unreadable.
    public static Bitmap Decode(string smfPath) {
        byte[] hdr = new byte[80];
        using (var fs = File.OpenRead(smfPath)) {
            if (fs.Read(hdr, 0, 80) < 80) return null;
            string magic = System.Text.Encoding.ASCII.GetString(hdr, 0, 15);
            if (magic != "spring map file") return null;
            int ptr = BitConverter.ToInt32(hdr, 64);     // minimapPtr
            if (ptr <= 0) return null;
            int dxtLen = (1024 / 4) * (1024 / 4) * 8;     // level-0 DXT1 = 524288 bytes
            byte[] dxt = new byte[dxtLen];
            fs.Seek(ptr, SeekOrigin.Begin);
            if (fs.Read(dxt, 0, dxtLen) < dxtLen) return null;
            return DecodeDxt1(dxt, 1024, 1024);
        }
    }

    static Bitmap DecodeDxt1(byte[] data, int width, int height) {
        Bitmap bmp = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        var bd = bmp.LockBits(new Rectangle(0, 0, width, height),
                              ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        int stride = bd.Stride;
        byte[] px = new byte[stride * height];
        int o = 0, bw = width / 4, bh = height / 4;
        int[] r = new int[4], g = new int[4], b = new int[4];
        for (int by = 0; by < bh; by++) {
            for (int bx = 0; bx < bw; bx++) {
                int c0 = data[o] | (data[o + 1] << 8);
                int c1 = data[o + 2] | (data[o + 3] << 8);
                uint bits = (uint)(data[o + 4] | (data[o + 5] << 8) | (data[o + 6] << 16) | (data[o + 7] << 24));
                o += 8;
                Unpack565(c0, ref r, ref g, ref b, 0);
                Unpack565(c1, ref r, ref g, ref b, 1);
                if (c0 > c1) {
                    r[2] = (2 * r[0] + r[1]) / 3; g[2] = (2 * g[0] + g[1]) / 3; b[2] = (2 * b[0] + b[1]) / 3;
                    r[3] = (r[0] + 2 * r[1]) / 3; g[3] = (g[0] + 2 * g[1]) / 3; b[3] = (b[0] + 2 * b[1]) / 3;
                } else {
                    r[2] = (r[0] + r[1]) / 2; g[2] = (g[0] + g[1]) / 2; b[2] = (b[0] + b[1]) / 2;
                    r[3] = 0; g[3] = 0; b[3] = 0;
                }
                for (int py = 0; py < 4; py++) {
                    for (int pxx = 0; pxx < 4; pxx++) {
                        int idx = (int)((bits >> (2 * (py * 4 + pxx))) & 3);
                        int p = (by * 4 + py) * stride + (bx * 4 + pxx) * 4;
                        px[p] = (byte)b[idx]; px[p + 1] = (byte)g[idx]; px[p + 2] = (byte)r[idx]; px[p + 3] = 255;
                    }
                }
            }
        }
        Marshal.Copy(px, 0, bd.Scan0, px.Length);
        bmp.UnlockBits(bd);
        return bmp;
    }

    static void Unpack565(int c, ref int[] r, ref int[] g, ref int[] b, int i) {
        int rr = (c >> 11) & 0x1F; r[i] = (rr << 3) | (rr >> 2);
        int gg = (c >> 5) & 0x3F;  g[i] = (gg << 2) | (gg >> 4);
        int bb = c & 0x1F;         b[i] = (bb << 3) | (bb >> 2);
    }
}
'@

# DDS decoder for unit build-pictures (unitpics\*.dds). Most are uncompressed
# 32-bit BGRA, a few are DXT1 or 24-bit. Returns the level-0 image as a Bitmap.
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

public static class DdsImage {
    public static Bitmap Decode(string path){
        byte[] d = File.ReadAllBytes(path);
        if(d.Length<128 || d[0]!=(byte)'D'||d[1]!=(byte)'D'||d[2]!=(byte)'S'||d[3]!=(byte)' ') return null;
        int height = BitConverter.ToInt32(d,12);
        int width  = BitConverter.ToInt32(d,16);
        if(width<=0||height<=0||width>4096||height>4096) return null;
        int pfFlags = BitConverter.ToInt32(d,80);
        uint fourcc = BitConverter.ToUInt32(d,84);
        int rgbBits = BitConverter.ToInt32(d,88);
        int off=128; bool hasFourCC=(pfFlags&0x4)!=0;
        Bitmap bmp=new Bitmap(width,height,PixelFormat.Format32bppArgb);
        var bd=bmp.LockBits(new Rectangle(0,0,width,height),ImageLockMode.WriteOnly,PixelFormat.Format32bppArgb);
        int stride=bd.Stride; byte[] px=new byte[stride*height]; bool ok=true;
        if(hasFourCC && fourcc==0x31545844u){ // 'DXT1'
            int o=off,bw=(width+3)/4,bh=(height+3)/4; int[] r=new int[4],g=new int[4],b=new int[4];
            for(int by=0;by<bh;by++)for(int bx=0;bx<bw;bx++){
                if(o+8>d.Length){ok=false;break;}
                int c0=d[o]|(d[o+1]<<8); int c1=d[o+2]|(d[o+3]<<8);
                uint bits=(uint)(d[o+4]|(d[o+5]<<8)|(d[o+6]<<16)|(d[o+7]<<24)); o+=8;
                U(c0,r,g,b,0); U(c1,r,g,b,1);
                if(c0>c1){ r[2]=(2*r[0]+r[1])/3;g[2]=(2*g[0]+g[1])/3;b[2]=(2*b[0]+b[1])/3; r[3]=(r[0]+2*r[1])/3;g[3]=(g[0]+2*g[1])/3;b[3]=(b[0]+2*b[1])/3; }
                else { r[2]=(r[0]+r[1])/2;g[2]=(g[0]+g[1])/2;b[2]=(b[0]+b[1])/2; r[3]=0;g[3]=0;b[3]=0; }
                for(int py=0;py<4;py++)for(int pxx=0;pxx<4;pxx++){
                    int X=bx*4+pxx,Y=by*4+py; if(X>=width||Y>=height)continue;
                    int idx=(int)((bits>>(2*(py*4+pxx)))&3); int p=Y*stride+X*4;
                    px[p]=(byte)b[idx];px[p+1]=(byte)g[idx];px[p+2]=(byte)r[idx];px[p+3]=255; }
            }
        } else if(!hasFourCC && rgbBits==32){
            for(int y=0;y<height;y++)for(int x=0;x<width;x++){ int s=off+(y*width+x)*4; if(s+4>d.Length){ok=false;break;}
                int p=y*stride+x*4; px[p]=d[s];px[p+1]=d[s+1];px[p+2]=d[s+2];px[p+3]=d[s+3]; }
        } else if(!hasFourCC && rgbBits==24){
            for(int y=0;y<height;y++)for(int x=0;x<width;x++){ int s=off+(y*width+x)*3; if(s+3>d.Length){ok=false;break;}
                int p=y*stride+x*4; px[p]=d[s];px[p+1]=d[s+1];px[p+2]=d[s+2];px[p+3]=255; }
        } else ok=false;
        if(ok) Marshal.Copy(px,0,bd.Scan0,px.Length);
        bmp.UnlockBits(bd);
        if(!ok){ bmp.Dispose(); return null; }
        return bmp;
    }
    static void U(int c,int[] r,int[] g,int[] b,int i){ int rr=(c>>11)&0x1F;r[i]=(rr<<3)|(rr>>2); int gg=(c>>5)&0x3F;g[i]=(gg<<2)|(gg>>4); int bb=c&0x1F;b[i]=(bb<<3)|(bb>>2);}
}
'@

# ---------------------------------------------------------------------------
# 1. Parse ArchiveCache for display name + .smf file name, keyed by .sd7
# ---------------------------------------------------------------------------
Write-Host "Reading map metadata from ArchiveCache..."
$mapMeta = @{}   # sd7 file name -> @{ name; shortname; mapfile }
if (Test-Path $cacheLua) {
    $cacheText = [System.IO.File]::ReadAllText($cacheLua)
    # Match each archive block: starts at  { name = "foo.sd7"  and ends at  \n\t\t},
    # archivedata.name (the display name) is always the entry just before name_pure.
    $blockRe = [regex]'\{\s*name\s*=\s*"([^"]+\.sd7)"[\s\S]*?\n\t\t\},'
    foreach ($bm in $blockRe.Matches($cacheText)) {
        $block = $bm.Value
        $sd7 = $bm.Groups[1].Value
        $mDisp = [regex]::Match($block, '\bname\s*=\s*"([^"]*)"\s*,\s*\r?\n\s*name_pure')
        $mFile = [regex]::Match($block, 'mapfile\s*=\s*"([^"]*)"')
        if ($mFile.Success) {
            $mapMeta[$sd7] = @{
                name    = if ($mDisp.Success) { $mDisp.Groups[1].Value } else { '' }
                mapfile = $mFile.Groups[1].Value
            }
        }
    }
}
Write-Host ("  metadata for {0} archives" -f $mapMeta.Count)

# ---------------------------------------------------------------------------
# 2. For each installed map: extract minimap + read true dimensions
# ---------------------------------------------------------------------------
function Read-SmfSize([string]$smfPath) {
    # Returns @{x;z} world size in elmos, or $null. Reads only the header.
    $fs = [System.IO.File]::OpenRead($smfPath)
    try {
        $buf = New-Object byte[] 32
        [void]$fs.Read($buf, 0, 32)
    } finally { $fs.Close() }
    $magic = [System.Text.Encoding]::ASCII.GetString($buf, 0, 15)
    if ($magic -ne 'spring map file') { return $null }
    $mapx = [BitConverter]::ToInt32($buf, 24)   # width  in squares
    $mapy = [BitConverter]::ToInt32($buf, 28)   # height in squares
    if ($mapx -le 0 -or $mapy -le 0) { return $null }
    return @{ x = $mapx * 8; z = $mapy * 8 }    # squareSize is always 8 elmos
}

function Save-Thumb([System.Drawing.Image]$img, [string]$dst, [int]$maxEdge, [string]$bg, [string]$fmt = 'jpg') {
    $w = $img.Width; $h = $img.Height
    $scale = [Math]::Min(1.0, $maxEdge / [Math]::Max($w, $h))
    $nw = [Math]::Max(1, [int]($w * $scale)); $nh = [Math]::Max(1, [int]($h * $scale))
    $bmp = New-Object System.Drawing.Bitmap $nw, $nh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    if ($bg) { $g.Clear([System.Drawing.ColorTranslator]::FromHtml($bg)) }
    $g.DrawImage($img, 0, 0, $nw, $nh)
    $g.Dispose()
    if ($fmt -eq 'png') { $bmp.Save($dst, [System.Drawing.Imaging.ImageFormat]::Png) }
    else { $bmp.Save($dst, [System.Drawing.Imaging.ImageFormat]::Jpeg) }
    $bmp.Dispose()
}

$sd7Files = Get-ChildItem -Path $mapsDir -Filter '*.sd7' -File | Sort-Object Name
Write-Host ("Found {0} map archives. Extracting..." -f $sd7Files.Count)

$maps = New-Object System.Collections.ArrayList
$tmpRoot = Join-Path $env:TEMP ('bar_designer_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
$noThumb = 0; $idx = 0

try {
    foreach ($f in $sd7Files) {
        $idx++
        $sd7 = $f.Name
        $base = [IO.Path]::GetFileNameWithoutExtension($sd7)
        $thumbRel = "maps/$base.jpg"
        $thumbAbs = Join-Path $mapsOut "$base.jpg"
        $meta = $mapMeta[$sd7]
        $dispName = if ($meta -and $meta.name) { $meta.name } else {
            ((($base -replace '_', ' ') -replace '\s+', ' ').Trim())
        }

        Write-Progress -Activity 'Processing maps' -Status "$idx/$($sd7Files.Count) $sd7" `
            -PercentComplete (($idx / $sd7Files.Count) * 100)

        $haveThumb = (Test-Path $thumbAbs)
        if ($SkipExistingThumbs -and $haveThumb) {
            # still need dimensions; fall through to extract smf only
        }

        $tmp = Join-Path $tmpRoot $base
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null

        # Extract just the .smf (holds both the dimensions and the minimap).
        $smfPattern = if ($meta -and $meta.mapfile) { [IO.Path]::GetFileName($meta.mapfile) } else { '*.smf' }
        & $SevenZip e $f.FullName "-o$tmp" -y -r $smfPattern *> $null
        $smf = Get-ChildItem -Path $tmp -Filter '*.smf' -File -ErrorAction SilentlyContinue | Select-Object -First 1

        # --- dimensions ---
        $size = $null
        if ($smf) { try { $size = Read-SmfSize $smf.FullName } catch {} }
        if (-not $size) { $size = @{ x = 8192; z = 8192 } }  # safe square fallback

        # --- thumbnail (decode the DXT1 minimap embedded in the .smf) ---
        if ($smf -and -not ($SkipExistingThumbs -and $haveThumb)) {
            try {
                $bmp = [SmfMini]::Decode($smf.FullName)
                if ($bmp) { Save-Thumb $bmp $thumbAbs $ThumbSize; $bmp.Dispose(); $haveThumb = $true }
            } catch { Write-Warning "thumb failed for $sd7 : $_" }
        }
        if (-not $haveThumb) { $noThumb++ }

        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

        [void]$maps.Add([ordered]@{
            file  = $sd7
            name  = $dispName
            w     = $size.x
            h     = $size.z
            thumb = if ($haveThumb) { $thumbRel } else { $null }
        })
    }
} finally {
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
    Write-Progress -Activity 'Processing maps' -Completed
}
Write-Host ("  {0} maps processed, {1} without a thumbnail" -f $maps.Count, $noThumb)

# ---------------------------------------------------------------------------
# 3. Scan repo unit defs for the unit/building picker
# ---------------------------------------------------------------------------
Write-Host "Scanning unit definitions..."
$unitsDir = Join-Path $repoRoot 'units'

# Display names come from the i18n file (unitdef .lua files have no name field).
$nameMap = @{}
$namesJson = Join-Path $repoRoot 'language\en\units.json'
if (Test-Path $namesJson) {
    try {
        $j = (Get-Content -LiteralPath $namesJson -Raw -Encoding UTF8 | ConvertFrom-Json).units.names
        foreach ($p in $j.PSObject.Properties) { $nameMap[$p.Name.ToLower()] = $p.Value }
    } catch { Write-Warning "could not parse $namesJson : $_" }
}

# Build-picture lookup (unitpics\<def>.dds) + output dir for decoded icons.
$picsDir  = Join-Path $repoRoot 'unitpics'
$iconsOut = Join-Path $scriptDir 'icons'
New-Item -ItemType Directory -Force -Path $iconsOut | Out-Null
$picMap = @{}
if (Test-Path $picsDir) {
    Get-ChildItem -Path $picsDir -Filter '*.dds' -File | ForEach-Object { $picMap[$_.BaseName.ToLower()] = $_.FullName }
}
$iconCount = 0

$units = New-Object System.Collections.ArrayList
if (Test-Path $unitsDir) {
    $unitFiles = Get-ChildItem -Path $unitsDir -Filter '*.lua' -File -Recurse
    foreach ($uf in $unitFiles) {
        $def = [IO.Path]::GetFileNameWithoutExtension($uf.Name).ToLower()
        # category = first path segment under units\ (e.g. ArmBuildings). Files
        # sitting directly in units\ (commanders, drones) have no folder -> group them.
        $rel = $uf.FullName.Substring($unitsDir.Length).TrimStart('\','/')
        $parts = $rel -split '[\\/]'
        $cat = if ($parts.Count -gt 1) { $parts[0] } elseif ($def -match 'com') { 'Commanders' } else { 'Misc' }
        $faction = switch -Regex ($def) {
            '^arm' { 'Armada'; break }
            '^cor' { 'Cortex'; break }
            '^leg' { 'Legion'; break }
            default { 'Other' }
        }
        $label = if ($nameMap.ContainsKey($def)) { $nameMap[$def] } else { $def }

        # decode the build picture to a small PNG icon (once)
        $iconRel = $null
        if ($picMap.ContainsKey($def)) {
            $iconAbs = Join-Path $iconsOut "$def.png"
            $iconRel = "icons/$def.png"
            if (-not ($SkipExistingThumbs -and (Test-Path $iconAbs))) {
                try {
                    $dimg = [DdsImage]::Decode($picMap[$def])
                    if ($dimg) { Save-Thumb $dimg $iconAbs 64 '#20262f' 'png'; $dimg.Dispose(); $iconCount++ }
                    else { $iconRel = $null }
                } catch { $iconRel = $null }
            } elseif (Test-Path $iconAbs) { $iconCount++ }
        }

        [void]$units.Add([ordered]@{ def = $def; name = $label; cat = $cat; faction = $faction; icon = $iconRel })
    }
}
$units = $units | Sort-Object { $_.faction }, { $_.cat }, { $_.def }
Write-Host ("  {0} unit defs, {1} with names, {2} with icons" -f $units.Count, $nameMap.Count, $iconCount)

# ---------------------------------------------------------------------------
# 4. Emit data.js  (loaded via <script> so the app needs no web server)
# ---------------------------------------------------------------------------
Write-Host "Writing data.js..."
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('// Generated by prepare_assets.ps1 - do not edit by hand.')
[void]$sb.AppendLine('// Re-run the script after installing new maps.')
[void]$sb.AppendLine(('window.BAR_MAPS = {0};' -f ($maps | ConvertTo-Json -Depth 4 -Compress)))
[void]$sb.AppendLine(('window.BAR_UNITS = {0};' -f ($units | ConvertTo-Json -Depth 4 -Compress)))
[System.IO.File]::WriteAllText($dataJs, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "Done."
Write-Host ("  $dataJs")
Write-Host ("  {0} maps, {1} units" -f $maps.Count, $units.Count)
Write-Host "Open designer.html in a browser to start."
