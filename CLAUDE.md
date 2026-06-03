# CLAUDE.md — project guide

> Private, unreleased mod of **Beyond All Reason** (BAR), for the owner (`Dejnol`) and one
> colleague only. Never to be "released". This file orients any future Claude session.

## What this repo is

This repo is **game content only** (Lua gadgets/widgets, unit defs, UI, shaders, models) — the
clone of `beyond-all-reason/Beyond-All-Reason`. It is **not** the engine. The game runs on the
**Recoil engine**, which is installed separately at:

```
%LOCALAPPDATA%\Programs\Beyond-All-Reason          (engine + Chobby lobby)
%LOCALAPPDATA%\Programs\Beyond-All-Reason\data     (data dir: engine\, maps\, games\, cache\, infolog.txt)
```

The engine loads this repo as a local "dev" game via a **directory junction**:

```
…\data\games\BAR.sdd   →   C:\PROJ\BAR        (edits here are live in-game, no build step)
…\devmode.txt          enables the dev build in the lobby
```

Full setup notes: `DEV_LOCAL.md` (untracked). The dev game's archive name (the `gametype`
string for start scripts) is **`Beyond All Reason $VERSION`** (literal `$VERSION`).

## How to run / test a change

- **Dev game from the lobby:** launch BAR → Settings → Developer → Singleplayer → the dev game.
- **One-click PvE demo:** Desktop shortcut **"Play BAR PvE Demo"**, or `PLAY_DEMO.bat`
  (auto-picks newest engine, launches `pve_demo_solo.txt` straight into a match — no lobby).
- **In-game scenario:** Single Player → Scenarios → **"Scripted PvE Demo"**
  (`singleplayer/scenarios/scenario025.lua`).
- **Fast iteration:** edit a gadget/scenario and run **`/luarules reload`** in the chat console.
  Unit/weapon def and `Setup`/base changes need a full match restart.
- **Logs:** `…\data\infolog.txt`. Our scripted-event messages appear as `[Mission] …`;
  validation problems as `[Mission API] …`.

### Validating Lua before launching

A standalone linter is installed at `%LOCALAPPDATA%\luacheck\luacheck.exe` (v1.2.0).
**Run from the repo root** so it uses `.luacheckrc` (which knows the Spring globals):

```
& "$env:LOCALAPPDATA\luacheck\luacheck.exe" path\to\file.lua ...
```

### Headless smoke test (loads our gadgets + runs frames, no GUI)

```
spring-headless.exe --write-dir "<data>" --only-local "<startscript with startpostype=1>"
```
Run it in the background ~40s, then grep `infolog`/stdout for `[Mission`, `[Mission API]`,
and `Error in`. Graphics/shader errors are expected (no GPU) and are NOT ours.

## The headline feature: scripted-PvE "Mission API"

We **enabled, fixed, and extended** BAR's previously-disabled Mission API — a **synced
(multiplayer-safe)** declarative **triggers → actions** framework. A scenario is one Lua file
returning `{ Teams, Setup, Triggers, Actions }`. Authoring reference: **`MISSION_API.md`**.

**Status: verified end-to-end** — a full in-game playtest fired all five demo events
(wall-at-start, army-value wake, commander-enters-area breach, T2 event, kill-commander victory)
with zero errors. See `singleplayer/missions/pve_demo.lua`.

### Code map (all SYNCED)

| File | Role |
|------|------|
| `luarules/gadgets/api_missions.lua` | loader: reads modoptions, resolves team roles, runs `Setup` |
| `luarules/gadgets/api_missions_triggers.lua` | trigger detection + freeze upkeep + action dispatch |
| `luarules/mission_api/triggers_schema.lua` | trigger types + param validation |
| `luarules/mission_api/actions_schema.lua` | action types + param validation |
| `luarules/mission_api/actions.lua` | action implementations |
| `luarules/mission_api/actions_dispatcher.lua` | maps action type → function |
| `luarules/mission_api/{triggers,actions}_loader.lua` | parse + validate scenario tables |
| `singleplayer/missions/pve_demo.lua` | demo scenario + authoring template |
| `singleplayer/scenarios/scenario025.lua` | menu entry that launches the demo |

### Activation

Off by default. Set modoption **`mission_path`** (relative to `singleplayer/`, e.g.
`missions/pve_demo.lua`) + `mission_difficulty`. Empty `mission_path` ⇒ both gadgets self-remove,
so **normal matches are completely unaffected**. Modoptions live in `modoptions.lua` under section
`pve_scenario_options`.

### Implemented triggers / actions (extensible; ~20 more enum'd but unimplemented)

- **Triggers:** `TimeElapsed`, `UnitEnteredLocation`, `UnitLeftLocation`, `UnitKilled`,
  `TechLevelReached`, `ArmyValueExceeded`, `ResourceStored`, `TeamDestroyed`.
- **Actions:** `SendMessage`, `SpawnUnits`, `DespawnUnits`, `GiveResource`, `FreezeTeam`,
  `UnfreezeTeam`, `SpawnBarrier`, `ExplodeBarrier`, `IssueOrders`, `Victory`, `Defeat`,
  `EnableTrigger`, `DisableTrigger`.
- **Targeting:** roles resolve to teams — `humans`/`players`, `enemies`/`aiteam`, and per-entity
  `human1`/`player1`…, `enemy1`/`ai1`… (stable teamID order). Threshold triggers
  (`ArmyValueExceeded`, `ResourceStored`) use per-team "any". Any trigger can fire any action.

## Conventions & gotchas (read before editing the Mission API)

- **Teams are referenced by ROLE**, never raw teamID: `humans` (allyTeam 0), `enemies`
  (allyTeam 1), auto `human1`/`enemy1`…. Resolved at init. Lobby convention: humans=allyTeam0,
  AIs=allyTeam1.
- **Positional unpack invariant:** `actions_dispatcher` unpacks an action's parameters
  *positionally in `actions_schema.lua` order*. A new action function's argument order **must**
  match its schema entry order exactly.
- **Coordinates are absolute world coords (elmos)** — fully per-map. The *demo* uses
  `Game.mapSizeX/Z` proportional coords only so it runs on any map; real hand-authored scenarios
  should use absolute coords for one specific map.
- **Start positions are pinned by repositioning, not by `StartPosX/Z`.** For `startpostype` 0/1
  the engine resets every team to the MAP's built-in default start positions at GameStart,
  ignoring the script's `StartPosX/Z` *and* any `Spring.SetTeamStartPosition` from
  Initialize/GamePreload. So `Setup.startPositions` is enforced by `repositionStartUnits()` in
  `api_missions.lua`, which **moves the already-spawned commanders** onto the placed coords on
  frame 1. (The verified `pve_demo` used `startpostype=2`, so this was missed originally.)
- **Triggers ↔ actions are fully decoupled:** any trigger can fire `ExplodeBarrier` (or any
  action), and several triggers can share one action. Re-firing a gone barrier is a safe no-op.
- **AI "freeze" is an approximation** (engine AIs' brains can't be paused from Lua): frozen teams'
  units are kept paralyzed (`SetUnitHealth{paralyze=…}`, re-applied every 15 frames) + neutral +
  economy-starved; `UnfreezeTeam` clears that and can inject resources. New units auto-frozen via
  `UnitCreated`/`UnitFinished`.
- **Scaffold bugs we fixed (don't reintroduce):** `settings.active = settings.active or true`
  (could never be false → use nil-check); `SpawnUnits` hardcoded to team 0; loaders did
  `pairs(parameters[type])` which crashed on unknown types → guarded with `or {}`.

## Multiplayer / hosting

Both PCs must run the **same git commit** (the engine cross-checks synced code; mismatch ⇒
desync). Official autohosts can't serve our `.sdd`; self-host directly via the engine's
`spring-dedicated` with this game. See `MULTIPLAYER_HOST.md` (untracked) + `tools/StartScripts/pve_host.txt`.

## Untracked local files (in `.git/info/exclude`, host-specific)

`DEV_LOCAL.md`, `MULTIPLAYER_HOST.md`, `PLAY_DEMO.bat`, `pve_demo_solo.txt`. The Desktop shortcut
"Play BAR PvE Demo.lnk" is outside the repo.

## Visual scenario designer (authoring tool)

`tools/scenario_designer/` — an **offline, point-and-click map-editor app** for authoring Mission
API scenarios (no engine/server; just open `designer.html`). It draws each map's minimap with
**true proportions** (square `.smf` minimap un-squished using real `mapx`/`mapy` dims), lets you
place the AI base/spawns + player start, draw trigger areas & barriers, wire triggers→actions,
and **exports the mission `.lua` + a launchable `scenarioNNN.lua`**. Scenarios it saves carry an
embedded `SCENARIO_DESIGNER_V1` JSON block for perfect re-editing; hand-written ones import
best-effort via a built-in Lua reader.

- **Setup (once / after installing maps):** run `tools/scenario_designer/prepare_assets.ps1`
  (needs 7-Zip + installed BAR). It extracts/decodes minimaps, reads true map sizes, and scans
  unit defs → `data.js` + `maps/`.
- Full usage: `tools/scenario_designer/README.md`.

## Related docs

- `DEV_LOCAL.md` — dev environment wiring + iteration loop.
- `MISSION_API.md` — full scenario authoring reference (trigger/action catalogue, examples).
- `MULTIPLAYER_HOST.md` — hosting the modified game with a friend (sync, Linux dedicated, LAN fallback).
- `tools/scenario_designer/README.md` — the visual scenario designer.
