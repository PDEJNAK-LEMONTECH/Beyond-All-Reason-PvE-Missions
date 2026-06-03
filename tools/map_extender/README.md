# map_extender — build a new playable BAR map by re-compositing an existing one

A proof-of-concept pipeline that takes an existing compiled map and emits a **new,
larger, playable map** by re-arranging the source's own terrain — no procedural
generation. Built for the private scripted-PvE mod; pairs with the Mission API and
the scenario designer.

> **Status: working PoC.** Verified end-to-end headless: the generated map
> `FTL Collage 0.1` loads, runs, and a Mission API scenario fires on it.

## What it does

Maps are precompiled `.sd7` archives: a `.smf` (16-bit heightmap, metal/type maps,
DXT1 minimap, a **tile-index map**, features) plus a `.smt` (the diffuse texture as
32×32 DXT1 tiles). This tool:

1. Extracts + **decodes** the source `.smf`/`.smt` into raw layers (C#, `extend_map.ps1`).
2. **Recomposites** them into a bigger canvas per a recipe (`compose_collage.ps1`).
3. Re-emits a compiled `.smf`/`.smt`, writes a minimal `mapinfo.lua`, packages a
   `.sd7`, and deploys it to `…/data/maps/`.

### The default recipe — "Archipelago Remix"

A `1536×1024`-square canvas (12288×8192 elmos): a low land **plain** as background,
with three land masses stamped from the source —

- the **full source** as the western *continent* (upright),
- the source's top-left quadrant **rotated 180°** as a NE *isle*,
- the source's centre **mirrored-X** as a SE *isle*.

Island edges meet the plain as natural mesa/cliff coasts, so there are no
stamp-to-stamp seams to blend.

## Key design decisions (and why)

- **Tile-index reuse.** Copied (upright) regions reference the *original* `.smt`
  tiles unchanged — zero recompression, perfect quality. Only **transformed**
  regions (rotated/mirrored) decode→transform→re-encode their tiles, appended to a
  new `.smt`. A DXT1 encoder is therefore needed only for those tiles + the
  regenerated 1024² minimap, never for the bulk of the map.
- **Diffuse-only.** Every modern BAR map is **SSMF** (separate normal/spec/splat
  overlay `.dds`, sized to the map). The PoC **drops** those overlays and renders
  from the recomposed `.smt` diffuse + a minimal `mapinfo.lua`. Result: geometry is
  fully correct and playable, but flatter-looking than the original. Full SSMF
  parity is a clean follow-up — recomposing an overlay `.dds` is the *same* collage
  operation applied per layer, just heavier (big BC-encoded textures).
- **Map name = `name .. " " .. version`.** Start scripts / `mapfilename` must use the
  full name (e.g. `FTL Collage 0.1`), or the engine fails archive resolution.

## Usage

Requires 7-Zip and an installed BAR (for the engine + source maps).

```powershell
# from a normal shell (uses -ExecutionPolicy Bypass via the .cmd, or call directly):
powershell -ExecutionPolicy Bypass -File tools\map_extender\extend_map.ps1 `
    -Source 'faster_than_light_1.1.sd7' -OutName 'FTL Collage' -Version '0.1' -Mode collage
```

- `-Mode roundtrip` re-emits the source unchanged (new name) — used to validate the
  binary read/write chain.
- The map is deployed to `…/data/maps/<slug>.sd7` and picked up by the engine's
  `ArchiveCache` automatically. Run `tools/scenario_designer/prepare_assets.ps1` to
  index it into the scenario designer.

> **Dev note:** the embedded C# is compiled with `Add-Type`. Because a .NET type
> can't be redefined in a live process, **edits to the C# require a fresh PowerShell
> process** — always launch via `powershell -File …`, never re-run inside a warm
> session.

### Verify a map / scenario loads (headless)

```powershell
tools\map_extender\loadtest.ps1 -MapName 'FTL Collage 0.1' `
    -MissionPath 'missions/ftl_collage_demo.lua' -StartPosType 0 -Seconds 34
```

`-StartPosType 0` makes the sim auto-start headless (type 2 waits for a human to
place a start, so no frames advance and no triggers fire).

## Files

| File | Role |
|------|------|
| `extend_map.ps1`       | orchestrator + embedded C# (`Smf`/`Smt` read+write, `Dxt` decode/encode, `Composer`) |
| `compose_collage.ps1`  | the recipe (canvas size, background, stamps, start positions) — dot-sourced |
| `mapinfo_template.lua` | minimal diffuse-only `mapinfo.lua` (`@@NAME@@`/`@@VERSION@@`/`@@MINH@@`/`@@MAXH@@`/`@@TEAMS@@`) |
| `loadtest.ps1`         | headless load/scenario smoke test |

## Example content (shipped)

- `singleplayer/missions/ftl_collage_demo.lua` — a small Mission API scenario on the
  generated map (dormant garrison on the NE isle; commanders pinned by
  `repositionStartUnits`).
- `singleplayer/scenarios/scenario027.lua` — the Single Player → Scenarios menu entry.

## Known limitations / next steps

- **Diffuse-only** (see above) — no normal/spec/splat; flatter lighting.
- DXT1 encoder is a simple bounding-box encoder (fine for the minimap + transformed
  island tiles; not perceptually optimal).
- Features (rocks/geo vents) are dropped; metal **map** is carried so islands keep
  their metal spots.
- Heightmap seams aren't feathered (not needed for water/plain coasts); stamp-to-stamp
  adjacency would need a blend band.
