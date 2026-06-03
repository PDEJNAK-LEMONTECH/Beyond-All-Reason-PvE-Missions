<#
.SYNOPSIS
    BAR map_extender -- build a new, playable map by re-compositing an existing one.

.DESCRIPTION
    Maps are precompiled .sd7 archives (.smf geometry + .smt DXT1 texture tiles).
    This tool decodes a source map's raw layers, recomposes them into a larger
    canvas (region-collage: copy core + stamp rotated sub-regions, feather-blended),
    and re-emits a compiled map under a new name. SSMF overlays (normal/spec/splat)
    are dropped -- the derivative renders from the .smt diffuse only (see README).

    Key efficiency: the .smt tiles are REUSED verbatim; only the .smf tile-index map
    is rearranged, so copied terrain keeps perfect texture quality with zero
    recompression. A DXT1 encoder is used only to regenerate the 1024^2 minimap.

    Modes:
      roundtrip  - parse the source .smf, re-emit it unchanged (new name), verify load
      collage    - the creative recomposition (default)

.NOTES  Windows PowerShell 5.1.  Needs 7-Zip.
#>
[CmdletBinding()]
param(
    [string]$Source   = 'faster_than_light_1.1.sd7',  # source .sd7 in data/maps (or full path)
    [string]$OutName  = ' FTL Collage',                # map display name (version appended)
    [string]$Version  = '0.1',
    [ValidateSet('roundtrip','collage')]
    [string]$Mode     = 'collage',
    [string]$DataDir,
    [int]$ScaleX      = 2,                              # canvas width  multiplier (collage)
    [int]$ScaleZ      = 2,                              # canvas height multiplier (collage)
    [switch]$NoDeploy
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $DataDir) { $DataDir = Join-Path $env:LOCALAPPDATA 'Programs\Beyond-All-Reason\data' }
$mapsDir = Join-Path $DataDir 'maps'
$sevenz  = @("$env:ProgramFiles\7-Zip\7z.exe","${env:ProgramFiles(x86)}\7-Zip\7z.exe") |
           Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $sevenz) { throw "7-Zip not found." }

# --------------------------------------------------------------------------- #
#  C# : SMF/SMT read+write + DXT1 decode/encode + collage composition
# --------------------------------------------------------------------------- #
$cs = @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;

namespace MapExt {

public static class Dxt {
    public static byte[] DecodeDxt1(byte[] d, int w, int h) {
        byte[] outp = new byte[w*h*4];
        int p = 0;
        for (int by=0; by<h; by+=4)
        for (int bx=0; bx<w; bx+=4) {
            ushort c0 = (ushort)(d[p] | (d[p+1]<<8));
            ushort c1 = (ushort)(d[p+2] | (d[p+3]<<8));
            uint bits = (uint)(d[p+4] | (d[p+5]<<8) | (d[p+6]<<16) | (d[p+7]<<24));
            p += 8;
            int[] r=new int[4], g=new int[4], b=new int[4];
            r[0]=((c0>>11)&0x1f)*255/31; g[0]=((c0>>5)&0x3f)*255/63; b[0]=(c0&0x1f)*255/31;
            r[1]=((c1>>11)&0x1f)*255/31; g[1]=((c1>>5)&0x3f)*255/63; b[1]=(c1&0x1f)*255/31;
            if (c0>c1) {
                r[2]=(2*r[0]+r[1])/3; g[2]=(2*g[0]+g[1])/3; b[2]=(2*b[0]+b[1])/3;
                r[3]=(r[0]+2*r[1])/3; g[3]=(g[0]+2*g[1])/3; b[3]=(b[0]+2*b[1])/3;
            } else {
                r[2]=(r[0]+r[1])/2; g[2]=(g[0]+g[1])/2; b[2]=(b[0]+b[1])/2;
                r[3]=0; g[3]=0; b[3]=0;
            }
            for (int py=0; py<4; py++)
            for (int px=0; px<4; px++) {
                int idx=(int)((bits>>(2*(py*4+px)))&3);
                int x=bx+px, y=by+py;
                if (x>=w||y>=h) continue;
                int o=(y*w+x)*4;
                outp[o]=(byte)b[idx]; outp[o+1]=(byte)g[idx]; outp[o+2]=(byte)r[idx]; outp[o+3]=255;
            }
        }
        return outp;
    }

    // Simple DXT1 encoder (bounding-box endpoints). Good enough for the minimap.
    public static byte[] EncodeDxt1(byte[] bgra, int w, int h) {
        int blocks=((w+3)/4)*((h+3)/4);
        byte[] outp=new byte[blocks*8];
        int p=0;
        for (int by=0; by<h; by+=4)
        for (int bx=0; bx<w; bx+=4) {
            int rmin=255,gmin=255,bmin=255,rmax=0,gmax=0,bmax=0;
            for (int py=0; py<4; py++)
            for (int px=0; px<4; px++) {
                int x=Math.Min(bx+px,w-1), y=Math.Min(by+py,h-1);
                int o=(y*w+x)*4;
                int bb=bgra[o], gg=bgra[o+1], rr=bgra[o+2];
                if(rr<rmin)rmin=rr; if(gg<gmin)gmin=gg; if(bb<bmin)bmin=bb;
                if(rr>rmax)rmax=rr; if(gg>gmax)gmax=gg; if(bb>bmax)bmax=bb;
            }
            ushort c0=(ushort)(((rmax>>3)<<11)|((gmax>>2)<<5)|(bmax>>3));
            ushort c1=(ushort)(((rmin>>3)<<11)|((gmin>>2)<<5)|(bmin>>3));
            if (c0<c1) { ushort t=c0; c0=c1; c1=t; }
            // build 4 palette colors (c0>c1 path)
            int[] pr=new int[4], pg=new int[4], pb=new int[4];
            pr[0]=((c0>>11)&0x1f)*255/31; pg[0]=((c0>>5)&0x3f)*255/63; pb[0]=(c0&0x1f)*255/31;
            pr[1]=((c1>>11)&0x1f)*255/31; pg[1]=((c1>>5)&0x3f)*255/63; pb[1]=(c1&0x1f)*255/31;
            pr[2]=(2*pr[0]+pr[1])/3; pg[2]=(2*pg[0]+pg[1])/3; pb[2]=(2*pb[0]+pb[1])/3;
            pr[3]=(pr[0]+2*pr[1])/3; pg[3]=(pg[0]+2*pg[1])/3; pb[3]=(pb[0]+2*pb[1])/3;
            uint bits=0;
            for (int py=0; py<4; py++)
            for (int px=0; px<4; px++) {
                int x=Math.Min(bx+px,w-1), y=Math.Min(by+py,h-1);
                int o=(y*w+x)*4;
                int bb=bgra[o], gg=bgra[o+1], rr=bgra[o+2];
                int best=0, bestd=int.MaxValue;
                for (int k=0;k<4;k++){ int dr=rr-pr[k],dg=gg-pg[k],db=bb-pb[k]; int dd=dr*dr+dg*dg+db*db; if(dd<bestd){bestd=dd;best=k;} }
                bits |= (uint)best << (2*(py*4+px));
            }
            outp[p]=(byte)(c0&0xff); outp[p+1]=(byte)(c0>>8);
            outp[p+2]=(byte)(c1&0xff); outp[p+3]=(byte)(c1>>8);
            outp[p+4]=(byte)(bits&0xff); outp[p+5]=(byte)((bits>>8)&0xff);
            outp[p+6]=(byte)((bits>>16)&0xff); outp[p+7]=(byte)((bits>>24)&0xff);
            p+=8;
        }
        return outp;
    }
}

public class Smf {
    public const int MINIMAP_SIZE = 699048; // 1024^2 DXT1 + full mip chain
    public int version, mapid, mapx, mapy, squareSize, texelPerSquare, tileSize;
    public float minHeight, maxHeight;
    public ushort[] heights;     // (mapx+1)*(mapy+1)
    public byte[] typemap;       // (mapx/2)*(mapy/2)
    public byte[] metalmap;      // (mapx/2)*(mapy/2)
    public byte[] minimap;       // MINIMAP_SIZE
    public byte[] grass;         // (mapx/4)*(mapy/4) or null
    public bool hasGrass;
    public List<int> tileFileCounts = new List<int>();
    public List<string> tileFileNames = new List<string>();
    public int[] tileIndex;      // (mapx/4)*(mapy/4)
    public byte[] featureBlock;  // raw [featurePtr..EOF)

    public int TW { get { return mapx/4; } }  // tile columns
    public int TH { get { return mapy/4; } }  // tile rows
    public int HW { get { return mapx+1; } }
    public int HH { get { return mapy+1; } }
    public int MW { get { return mapx/2; } }
    public int MH { get { return mapy/2; } }
    public int GW { get { return mapx/4; } }
    public int GH { get { return mapy/4; } }

    static string ReadCStr(BinaryReader r) {
        var sb=new StringBuilder(); byte b;
        while ((b=r.ReadByte())!=0) sb.Append((char)b);
        return sb.ToString();
    }

    public static Smf Read(string path) {
        var s=new Smf();
        byte[] all=File.ReadAllBytes(path);
        using (var ms=new MemoryStream(all))
        using (var r=new BinaryReader(ms)) {
            r.ReadBytes(16); // magic
            s.version=r.ReadInt32(); s.mapid=r.ReadInt32();
            s.mapx=r.ReadInt32(); s.mapy=r.ReadInt32();
            s.squareSize=r.ReadInt32(); s.texelPerSquare=r.ReadInt32(); s.tileSize=r.ReadInt32();
            s.minHeight=r.ReadSingle(); s.maxHeight=r.ReadSingle();
            int heightPtr=r.ReadInt32(), typePtr=r.ReadInt32(), tilesPtr=r.ReadInt32(),
                miniPtr=r.ReadInt32(), metalPtr=r.ReadInt32(), featPtr=r.ReadInt32();
            int numExtra=r.ReadInt32();
            int grassPtr=0;
            for (int i=0;i<numExtra;i++) {
                long hpos=ms.Position;
                int size=r.ReadInt32(); int type=r.ReadInt32();
                if (type==1) { grassPtr=r.ReadInt32(); s.hasGrass=true; } // MEH_Vegetation
                ms.Position=hpos+size; // skip to next extra header
            }
            // sections by pointer
            ms.Position=heightPtr;
            int hcount=s.HW*s.HH; s.heights=new ushort[hcount];
            for (int i=0;i<hcount;i++) s.heights[i]=r.ReadUInt16();
            ms.Position=typePtr;  s.typemap =r.ReadBytes(s.MW*s.MH);
            ms.Position=miniPtr;  s.minimap =r.ReadBytes(MINIMAP_SIZE);
            ms.Position=metalPtr; s.metalmap=r.ReadBytes(s.MW*s.MH);
            if (s.hasGrass && grassPtr>0) { ms.Position=grassPtr; s.grass=r.ReadBytes(s.GW*s.GH); }
            // tiles
            ms.Position=tilesPtr;
            int numTileFiles=r.ReadInt32(); int numTilesTotal=r.ReadInt32();
            for (int i=0;i<numTileFiles;i++) { s.tileFileCounts.Add(r.ReadInt32()); s.tileFileNames.Add(ReadCStr(r)); }
            int tcount=s.TW*s.TH; s.tileIndex=new int[tcount];
            for (int i=0;i<tcount;i++) s.tileIndex[i]=r.ReadInt32();
            // features (raw to EOF)
            ms.Position=featPtr;
            s.featureBlock=r.ReadBytes((int)(all.Length-featPtr));
        }
        return s;
    }

    public void Write(string path) {
        using (var ms=new MemoryStream())
        using (var w=new BinaryWriter(ms)) {
            // --- header (pointers patched after) ---
            byte[] magic=Encoding.ASCII.GetBytes("spring map file\0");
            w.Write(magic);
            w.Write(version); w.Write(mapid);
            w.Write(mapx); w.Write(mapy);
            w.Write(squareSize); w.Write(texelPerSquare); w.Write(tileSize);
            w.Write(minHeight); w.Write(maxHeight);
            long ptrPos=ms.Position;
            w.Write(0); w.Write(0); w.Write(0); w.Write(0); w.Write(0); w.Write(0); // 6 ptrs
            w.Write(hasGrass?1:0); // numExtraHeaders
            long grassPtrPos=0;
            if (hasGrass) {
                w.Write(12); w.Write(1);      // size,type=vegetation
                grassPtrPos=ms.Position; w.Write(0); // grassPtr patched later
            }
            // --- sections ---
            int heightPtr=(int)ms.Position;
            foreach (var hv in heights) w.Write(hv);
            int typePtr=(int)ms.Position;   w.Write(typemap);
            int miniPtr=(int)ms.Position;   w.Write(minimap);
            int metalPtr=(int)ms.Position;  w.Write(metalmap);
            int grassPtr=0;
            if (hasGrass) { grassPtr=(int)ms.Position; w.Write(grass); }
            int tilesPtr=(int)ms.Position;
            w.Write(tileFileCounts.Count);
            int total=0; foreach(var c in tileFileCounts) total+=c; w.Write(total);
            for (int i=0;i<tileFileCounts.Count;i++) {
                w.Write(tileFileCounts[i]);
                w.Write(Encoding.ASCII.GetBytes(tileFileNames[i])); w.Write((byte)0);
            }
            foreach (var ti in tileIndex) w.Write(ti);
            int featPtr=(int)ms.Position;   w.Write(featureBlock);
            // --- patch pointers ---
            ms.Position=ptrPos;
            w.Write(heightPtr); w.Write(typePtr); w.Write(tilesPtr);
            w.Write(miniPtr); w.Write(metalPtr); w.Write(featPtr);
            if (hasGrass) { ms.Position=grassPtrPos; w.Write(grassPtr); }
            File.WriteAllBytes(path, ms.ToArray());
        }
    }
}

// ----- .smt tile store (DXT1 tiles) -----
public class Smt {
    public int numTiles, tileSize, comp, bytesPerTile;
    public byte[] header;        // 32-byte header
    public List<byte[]> tiles = new List<byte[]>();
    public static Smt Read(string path) {
        var s=new Smt(); byte[] all=File.ReadAllBytes(path);
        using (var ms=new MemoryStream(all)) using (var r=new BinaryReader(ms)) {
            s.header=r.ReadBytes(32);
            s.numTiles=BitConverter.ToInt32(s.header,20);
            s.tileSize=BitConverter.ToInt32(s.header,24);
            s.comp=BitConverter.ToInt32(s.header,28);
            s.bytesPerTile=(all.Length-32)/Math.Max(1,s.numTiles);
            for (int i=0;i<s.numTiles;i++) s.tiles.Add(r.ReadBytes(s.bytesPerTile));
        }
        return s;
    }
    public void Write(string path) {
        using (var ms=new MemoryStream()) using (var w=new BinaryWriter(ms)) {
            byte[] h=(byte[])header.Clone();
            Array.Copy(BitConverter.GetBytes(tiles.Count),0,h,20,4);
            w.Write(h);
            foreach (var t in tiles) w.Write(t);
            File.WriteAllBytes(path, ms.ToArray());
        }
    }
    public byte[] EncodeTile(byte[] bgra32) {
        var ms=new MemoryStream();
        int sz=32; byte[] cur=bgra32;
        while (true) {
            byte[] enc=Dxt.EncodeDxt1(cur, sz, sz);
            ms.Write(enc,0,enc.Length);
            if (ms.Length>=bytesPerTile || sz==1) break;
            cur=Box(cur, sz); sz/=2;
        }
        byte[] outp=new byte[bytesPerTile];
        Array.Copy(ms.ToArray(),0,outp,0,Math.Min((int)ms.Length,bytesPerTile));
        return outp;
    }
    static byte[] Box(byte[] src, int n) {
        int m=n/2; byte[] o=new byte[m*m*4];
        for (int y=0;y<m;y++) for (int x=0;x<m;x++)
            for (int c=0;c<4;c++) {
                int s=((2*y)*n+(2*x))*4+c;
                int v=(src[s]+src[s+4]+src[((2*y+1)*n+(2*x))*4+c]+src[((2*y+1)*n+(2*x+1))*4+c])/4;
                o[(y*m+x)*4+c]=(byte)v;
            }
        return o;
    }
}

public class Stamp {
    public int sx0,sy0,sx1,sy1;  // source tile rect [inclusive..exclusive)
    public int dx,dy;            // dest tile origin
    public int tf;               // 0 none, 1 rot180, 2 mirrorX, 3 mirrorY
}

public static class Composer {
    static void Tf(int tf,int i,int j,int W,int H,out int si,out int sj){
        if(tf==1){si=W-1-i;sj=H-1-j;}
        else if(tf==2){si=W-1-i;sj=j;}
        else if(tf==3){si=i;sj=H-1-j;}
        else {si=i;sj=j;}
    }
    static byte[] RotBgra(byte[] b,int n,int tf){
        if(tf==0) return b;
        byte[] o=new byte[b.Length];
        for(int y=0;y<n;y++)for(int x=0;x<n;x++){
            int sx,sy; Tf(tf,x,y,n,n,out sx,out sy);
            for(int c=0;c<4;c++) o[(y*n+x)*4+c]=b[(sy*n+sx)*4+c];
        }
        return o;
    }

    public static Smf Build(Smf src, Smt smt, int newMapx, int newMapy,
                            ushort bgHeight, int bgTile, List<Stamp> stamps, string outSmtPath) {
        var d=new Smf();
        d.version=src.version; d.mapid=src.mapid; d.mapx=newMapx; d.mapy=newMapy;
        d.squareSize=src.squareSize; d.texelPerSquare=src.texelPerSquare; d.tileSize=src.tileSize;
        d.minHeight=src.minHeight; d.maxHeight=src.maxHeight;
        d.hasGrass=src.hasGrass;
        d.heights=new ushort[d.HW*d.HH];
        for (int i=0;i<d.heights.Length;i++) d.heights[i]=bgHeight;
        d.typemap=new byte[d.MW*d.MH];
        d.metalmap=new byte[d.MW*d.MH];
        if (d.hasGrass) d.grass=new byte[d.GW*d.GH];
        d.tileIndex=new int[d.TW*d.TH];
        for (int i=0;i<d.tileIndex.Length;i++) d.tileIndex[i]=bgTile;

        var cache=new Dictionary<string,int>();
        foreach (var st in stamps) {
            int W=st.sx1-st.sx0, H=st.sy1-st.sy0;
            for (int j=0;j<H;j++) for (int i=0;i<W;i++) {
                int si,sj; Tf(st.tf,i,j,W,H,out si,out sj);
                int sTx=st.sx0+si, sTy=st.sy0+sj;
                int dTx=st.dx+i, dTy=st.dy+j;
                if (dTx<0||dTy<0||dTx>=d.TW||dTy>=d.TH) continue;
                if (sTx<0||sTy<0||sTx>=src.TW||sTy>=src.TH) continue;
                int srcTile=src.tileIndex[sTy*src.TW+sTx];
                int useTile=srcTile;
                if (st.tf!=0) {
                    string key=srcTile+":"+st.tf;
                    if (!cache.TryGetValue(key, out useTile)) {
                        byte[] bgra=Dxt.DecodeDxt1(smt.tiles[srcTile], 32, 32);
                        smt.tiles.Add(smt.EncodeTile(RotBgra(bgra, 32, st.tf)));
                        useTile=smt.tiles.Count-1; cache[key]=useTile;
                    }
                }
                d.tileIndex[dTy*d.TW+dTx]=useTile;
                if (d.hasGrass) d.grass[dTy*d.GW+dTx]=src.grass[sTy*src.GW+sTx];
                for (int a=0;a<2;a++) for (int b=0;b<2;b++) {
                    int sa=a, sb=b;
                    if(st.tf==1){sa=1-a;sb=1-b;} else if(st.tf==2){sa=1-a;} else if(st.tf==3){sb=1-b;}
                    int dmx=dTx*2+a, dmy=dTy*2+b, smx=sTx*2+sa, smy=sTy*2+sb;
                    d.metalmap[dmy*d.MW+dmx]=src.metalmap[smy*src.MW+smx];
                    d.typemap[dmy*d.MW+dmx]=src.typemap[smy*src.MW+smx];
                }
            }
            int vW=W*4, vH=H*4;
            for (int j=0;j<=vH;j++) for (int i=0;i<=vW;i++) {
                int di=st.dx*4+i, dj=st.dy*4+j;
                if (di<0||dj<0||di>=d.HW||dj>=d.HH) continue;
                int sii,sjj; Tf(st.tf,i,j,vW,vH,out sii,out sjj);
                int sx=st.sx0*4+sii, sy=st.sy0*4+sjj;
                if (sx<0||sy<0||sx>=src.HW||sy>=src.HH) continue;
                d.heights[dj*d.HW+di]=src.heights[sy*src.HW+sx];
            }
        }

        d.tileFileCounts.Add(smt.tiles.Count);
        d.tileFileNames.Add(System.IO.Path.GetFileName(outSmtPath));
        smt.Write(outSmtPath);

        d.minimap = BuildMinimap(src, newMapx, newMapy, stamps);

        var fb=new MemoryStream(); var fw=new BinaryWriter(fb);
        fw.Write(0); fw.Write(0);
        d.featureBlock=fb.ToArray();
        return d;
    }

    static byte[] BuildMinimap(Smf src, int newMapx, int newMapy, List<Stamp> stamps) {
        byte[] srcMini = Dxt.DecodeDxt1(src.minimap, 1024, 1024);
        byte[] dst = new byte[1024*1024*4];
        for (int i=0;i<dst.Length;i+=4){ dst[i]=90; dst[i+1]=60; dst[i+2]=25; dst[i+3]=255; }
        int srcTW=src.TW, srcTH=src.TH, newTW=newMapx/4, newTH=newMapy/4;
        foreach (var st in stamps) {
            int W=st.sx1-st.sx0, H=st.sy1-st.sy0;
            int dpx0=(int)((double)st.dx/newTW*1024), dpy0=(int)((double)st.dy/newTH*1024);
            int dpx1=(int)((double)(st.dx+W)/newTW*1024), dpy1=(int)((double)(st.dy+H)/newTH*1024);
            for (int py=dpy0;py<dpy1;py++) for (int px=dpx0;px<dpx1;px++) {
                if (px<0||py<0||px>=1024||py>=1024) continue;
                double fu=(double)(px-dpx0)/Math.Max(1,(dpx1-dpx0));
                double fv=(double)(py-dpy0)/Math.Max(1,(dpy1-dpy0));
                double tu=fu, tv=fv;
                if(st.tf==1){tu=1-fu;tv=1-fv;} else if(st.tf==2){tu=1-fu;} else if(st.tf==3){tv=1-fv;}
                double sTx=st.sx0+tu*W, sTy=st.sy0+tv*H;
                int spx=(int)(sTx/srcTW*1024), spy=(int)(sTy/srcTH*1024);
                if (spx<0||spy<0||spx>=1024||spy>=1024) continue;
                int so=(spy*1024+spx)*4, doo=(py*1024+px)*4;
                dst[doo]=srcMini[so]; dst[doo+1]=srcMini[so+1]; dst[doo+2]=srcMini[so+2]; dst[doo+3]=255;
            }
        }
        var ms=new MemoryStream();
        int sz=1024; byte[] cur=dst;
        while (sz>=4) {
            byte[] enc=Dxt.EncodeDxt1(cur, sz, sz);
            ms.Write(enc,0,enc.Length);
            if (sz==4) break;
            cur=BoxDown(cur, sz); sz/=2;
        }
        byte[] outp=new byte[Smf.MINIMAP_SIZE];
        Array.Copy(ms.ToArray(),0,outp,0,Math.Min((int)ms.Length,Smf.MINIMAP_SIZE));
        return outp;
    }
    static byte[] BoxDown(byte[] src, int n) {
        int m=n/2; byte[] o=new byte[m*m*4];
        for (int y=0;y<m;y++) for (int x=0;x<m;x++)
            for (int c=0;c<4;c++) {
                int s=((2*y)*n+(2*x))*4+c;
                int v=(src[s]+src[s+4]+src[((2*y+1)*n+(2*x))*4+c]+src[((2*y+1)*n+(2*x+1))*4+c])/4;
                o[(y*m+x)*4+c]=(byte)v;
            }
        return o;
    }
}
}
'@
if (-not ([System.Management.Automation.PSTypeName]'MapExt.Smf').Type) {
    Add-Type -TypeDefinition $cs
}

# --------------------------------------------------------------------------- #
#  Extract source .smf/.smt
# --------------------------------------------------------------------------- #
$srcPath = if (Test-Path $Source) { (Resolve-Path $Source).Path } else { Join-Path $mapsDir $Source }
if (-not (Test-Path $srcPath)) { throw "Source map not found: $srcPath" }
$work = Join-Path $env:TEMP ('mapext_' + [IO.Path]::GetFileNameWithoutExtension($srcPath))
if (Test-Path $work) { Get-ChildItem $work -Recurse | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $work | Out-Null
& $sevenz e $srcPath "-o$work" -y -r '*.smf' '*.smt' *> $null
$srcSmf = Get-ChildItem $work -Filter *.smf | Select-Object -First 1
$srcSmt = Get-ChildItem $work -Filter *.smt | Select-Object -First 1
Write-Host "source .smf: $($srcSmf.Name)  .smt: $($srcSmt.Name)"

$smf = [MapExt.Smf]::Read($srcSmf.FullName)
Write-Host ("loaded: {0}x{1} squares ({2}x{3} elmos), height [{4}..{5}], tiles {6}x{7}, grass={8}" -f `
    $smf.mapx,$smf.mapy,($smf.mapx*8),($smf.mapy*8),$smf.minHeight,$smf.maxHeight,$smf.TW,$smf.TH,$smf.hasGrass)

# Composition happens in compose_collage.ps1 (dot-sourced) for collage mode.
$slug = ($OutName.Trim() -replace '[^A-Za-z0-9]+','_').ToLower().Trim('_')
$fullName = $OutName.Trim() + ' ' + $Version

if ($Mode -eq 'roundtrip') {
    $outSmf = Join-Path $work ($slug + '.smf')
    $smf.Write($outSmf)
    Write-Host "round-trip written: $outSmf ($((Get-Item $outSmf).Length) bytes vs source $($srcSmf.Length))"
    $script:OUT_SMF = $outSmf
    $script:OUT_SMT = $srcSmt.FullName   # reuse tiles verbatim
} else {
    . (Join-Path $toolDir 'compose_collage.ps1')   # fills $script:OUT_SMF / $script:OUT_SMT
}

# --------------------------------------------------------------------------- #
#  Package + deploy
# --------------------------------------------------------------------------- #
$pkg = Join-Path $work 'pkg'
if (Test-Path $pkg) { Get-ChildItem $pkg -Recurse | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force (Join-Path $pkg 'maps') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $pkg 'maphelper') | Out-Null
Copy-Item $script:OUT_SMF (Join-Path $pkg "maps\$slug.smf") -Force
Copy-Item $script:OUT_SMT (Join-Path $pkg "maps\$slug.smt") -Force
Set-Content (Join-Path $pkg 'maphelper\mapinfo.lua') 'return VFS.Include("mapinfo.lua")' -Encoding ASCII

# mapinfo.lua
$mi = (Get-Content (Join-Path $toolDir 'mapinfo_template.lua') -Raw)
$mi = $mi.Replace('@@NAME@@', $OutName.Trim())
$mi = $mi.Replace('@@VERSION@@', $Version)
$mi = $mi.Replace('@@MINH@@', [string]$smf.minHeight)
$mi = $mi.Replace('@@MAXH@@', [string]$smf.maxHeight)
if (-not $script:TEAMS_LUA) {
    # default: two starts near opposite corners of whatever canvas we produced
    $mx = if ($script:NEW_MAPX) { $script:NEW_MAPX } else { $smf.mapx }
    $mz = if ($script:NEW_MAPY) { $script:NEW_MAPY } else { $smf.mapy }
    $script:TEAMS_LUA = "`t`t[0] = {startPos = {x = $([int]($mx*8*0.2)), z = $([int]($mz*8*0.5))}},`n`t`t[1] = {startPos = {x = $([int]($mx*8*0.8)), z = $([int]($mz*8*0.5))}},"
}
$mi = $mi.Replace('@@TEAMS@@', $script:TEAMS_LUA)
[IO.File]::WriteAllText((Join-Path $pkg 'mapinfo.lua'), $mi, (New-Object Text.UTF8Encoding($false)))

$sd7 = Join-Path $work ($slug + '.sd7')
if (Test-Path $sd7) { [IO.File]::Delete($sd7) }
Push-Location $pkg
& $sevenz a -t7z $sd7 'mapinfo.lua' 'maphelper' 'maps' *> $null
Pop-Location
Write-Host "packaged: $sd7  ($([math]::Round((Get-Item $sd7).Length/1MB,1)) MB)  map name = '$fullName'"

if (-not $NoDeploy) {
    Copy-Item $sd7 (Join-Path $mapsDir ($slug + '.sd7')) -Force
    Write-Host "deployed to: $(Join-Path $mapsDir ($slug + '.sd7'))"
}
$script:MAP_FULLNAME = $fullName
$script:MAP_SLUG = $slug
