# Mission API — scripted PvE scenarios

This documents the scripted-PvE system added to our private BAR mod. It builds on BAR's
(previously disabled) **Mission API**: a synced, multiplayer-safe **triggers → actions**
framework. A *scenario* is a single Lua file that declares teams, a one-time setup, a set of
triggers, and the actions they fire.

## Quick start — just launch the prepared demo

Everything is pre-wired. To play the demo:

1. Open the BAR launcher and start the game **on the dev build** (Settings → Developer →
   Singleplayer → the dev game, as in `DEV_LOCAL.md`).
2. **Single Player → Scenarios → "Scripted PvE Demo"** → pick a faction → **Start**.

That scenario (`singleplayer/scenarios/scenario025.lua`) bakes in the map (**Red Comet Remake
1.8**), one **BARb** AI on the enemy side, and the `mission_path` modoption — so nothing needs
configuring. What you'll see:

- **At start:** a Dragon's-Teeth **wall across the centre** of the map, and a **dormant** BARb AI
  (paralyzed base on the right) that does nothing yet.
- **Walk your commander up to the wall** → it is **breached** (explodes).
- **Reach Tech 2** → the AI is fed metal and gains a squad of defenders.
- **Grow your army past ~8000 metal value** → the AI **wakes up** and starts playing.
- **Kill the enemy commander** → victory message.

To tweak it, edit `singleplayer/missions/pve_demo.lua` and run **`/luarules reload`** in-game
(chat console) — no relaunch needed for trigger/action changes.

## Enabling a scenario (manually / for other scenarios)

Set the modoption **`mission_path`** to the scenario file path relative to the game's
`singleplayer/` folder, e.g.:

```
mission_path = missions/pve_demo.lua
mission_difficulty = normal          # easy | normal | hard
```

If `mission_path` is empty (the default), the whole Mission API removes itself and a normal
match is completely unaffected.

You can set the modoption either in the lobby's *Game Options → PvE Scenario* section, or in a
start script's `[modoptions]` block (see `MULTIPLAYER_HOST.md`).

A third optional modoption, **`mission_debug_los`** (bool, default off), is a debug/testing aid:
when on, it reveals the whole map (global line-of-sight) for the human side so you can watch the
entire scenario unfold. It has no effect outside scenarios. The scenario designer's **Inf LOS**
checkbox sets it on the start scripts it generates.

## Scenario file structure

A scenario returns four tables (see `singleplayer/missions/pve_demo.lua` for a full working
example that exercises every trigger and action):

```lua
return {
  Teams    = { ... },   -- optional, role -> team mapping
  Setup    = { ... },   -- once at game start: freeze + pre-placed bases
  Triggers = { ... },   -- conditions
  Actions  = { ... },   -- effects
}
```

### Teams (roles)

Triggers and actions refer to teams by **role name**, never by raw teamID, so a scenario is
independent of lobby slot order.

```lua
Teams = {
  humans  = { allyTeam = 0 },   -- all teams on allyTeam 0
  enemies = { allyTeam = 1 },   -- all teams on allyTeam 1
  boss    = { team = 3 },       -- a single explicit teamID
}
```

Defaults if you omit `Teams`: **`humans` = allyTeam 0**, **`enemies` = allyTeam 1**.

**Auto-generated roles** (so you can target a side or a specific AI without declaring anything):

| Role | Means |
|------|-------|
| `humans` / `players` | the whole human side |
| `enemies` / `aiteam` | the whole AI side (all AIs) |
| `human1`, `human2`, … / `player1`, … | a specific human player (by teamID order) |
| `enemy1`, `enemy2`, … / `ai1`, `ai2`, … | a specific AI (by teamID order) |

> **Stable numbering:** `ai1`/`ai2`/… map to AIs in teamID order, which is **fixed for a given
> mission** as long as the start script is fixed — so "AI #2" is the same AI every run. For a
> guarantee, declare them explicitly: `Teams = { ai2 = { team = 2 } }`.

Targeting rules:
- Actions on a role apply to **all** teams in it — `GiveResource{team="aiteam", metal=1000}` pays
  **every** AI 1000 each; `GiveResource{team="ai2", ...}` pays only AI #2.
- Spawn/order actions use the role's **primary** (first) team when one unit/team is implied.
- Threshold triggers (`ArmyValueExceeded`, `ResourceStored`) fire if **any single team** in the
  role qualifies (i.e. "any human reaches 8000", not the summed side).

> **Lobby convention:** put the human player(s) on allyTeam 0 and the BARb AI(s) on allyTeam 1.

### Setup

```lua
Setup = {
  freeze = { "enemies" },             -- roles that start dormant (paralyzed + neutral)
  bases = {                           -- pre-placed units per role (spawned at game start)
    enemies = {
      { def = "armmex",   x = 4100, z = 950 },
      { def = "armlab",   x = 4300, z = 1000, facing = "west" },  -- facing optional
    },
  },
}
```

### Triggers

Common fields: `type`, `settings`, `parameters`, `actions` (list of action ids).
`settings` supports `repeating` (bool), `maxRepeats` (number), `prerequisites` (list of other
trigger tables that must have fired first), `difficulties` (table keyed by difficulty), and
`active` (set `false` to start disabled and enable later via the `EnableTrigger` action).

| Trigger type          | Parameters | Fires when |
|-----------------------|------------|------------|
| `TimeElapsed`         | `gameFrame`, `interval?` | a game frame is reached (30 frames = 1s); repeats every `interval` if `repeating` |
| `UnitEnteredLocation` | `team?`, `onlyCommander?`, `x`, `z`, `radius` | a qualifying unit of `team` enters the cylinder (edge-triggered) |
| `UnitLeftLocation`    | `team?`, `onlyCommander?`, `x`, `z`, `radius` | a qualifying unit leaves the cylinder |
| `UnitKilled`          | `unitName?`, `team?`, `onlyCommander?` | a tracked-by-name unit dies, OR any unit of `team` dies (optionally only commanders) |
| `TechLevelReached`    | `team?`, `techLevel?` (default 2) | a unit of `team` **finishes** with `customParams.techlevel >= techLevel` |
| `ArmyValueExceeded`   | `team?`, `value` | **any single team** in `team` has unit `metalCost` sum ≥ `value` |
| `ResourceStored`      | `team?`, `resource` ("metal"/"energy"), `amount` | **any single team** in `team` has ≥ `amount` stored |
| `TeamDestroyed`       | `team` | `team` has had units and now has **none** (e.g. an AI eliminated) |

`team` defaults to `humans` when omitted. Area/army/resource/team-destroyed triggers are polled
(~0.5–1s); kill/tech triggers are event-driven.

### Actions

| Action type     | Parameters | Effect |
|-----------------|------------|--------|
| `SendMessage`   | `message` | synced echo to all players |
| `SpawnUnits`    | `name?`, `unitDefName`, `quantity?`, `x`, `y?`, `z`, `team?`, `facing?` | spawn units for a team (default Gaia); multiples auto-grid |
| `DespawnUnits`  | `name` | silently remove units spawned under `name` |
| `GiveResource`  | `team`, `metal?`, `energy?` | add resources to every team of the role |
| `FreezeTeam`    | `team` | make a team dormant (paralyze + neutral, kept up each second) |
| `UnfreezeTeam`  | `team`, `metal?`, `energy?` | wake a team and optionally inject resources |
| `SpawnBarrier`  | `name`, `unitDefName`, `team?`, `x1`, `z1`, `x2`, `z2`, `spacing?` | line of walls/Dragon's Teeth (default Gaia) |
| `ExplodeBarrier`| `name` | destroy a named barrier with a real explosion |
| `IssueOrders`   | `name?` (group), `team?` (role), `cmd` (move/fight/attack/patrol/guard/stop), `x?`, `z?` | order a spawn group and/or a role's units to a position |
| `Victory` / `Defeat` | `team?` (default humans) | **end the match** — that side wins / loses |
| `EnableTrigger` / `DisableTrigger` | `triggerId` | toggle another trigger |

### Targeting examples

```lua
-- Any human reaches 8000 army value -> wake AI #2 (and inject resources)
{ type=triggerTypes.ArmyValueExceeded, parameters={ team="humans", value=8000 },
  actions={ "wakeAi2" } }
wakeAi2 = { type=actionTypes.UnfreezeTeam, parameters={ team="ai2", metal=5000 } }

-- Any human reaches T2 -> spawn 250 Ticks for AI #1
{ type=triggerTypes.TechLevelReached, parameters={ team="humans", techLevel=2 },
  actions={ "ticksForAi1" } }
ticksForAi1 = { type=actionTypes.SpawnUnits,
  parameters={ unitDefName="armtick", quantity=250, x=1234, z=5678, team="ai1" } }

-- Human enters a zone -> +1000 metal to EVERY AI
{ type=triggerTypes.UnitEnteredLocation, parameters={ team="humans", x=2000, z=2000, radius=600 },
  actions={ "payAis" } }
payAis = { type=actionTypes.GiveResource, parameters={ team="aiteam", metal=1000 } }

-- Kill any one of the 3 AIs (its commander) -> blow the wall
{ type=triggerTypes.UnitKilled, parameters={ team="aiteam", onlyCommander=true },
  actions={ "blowWall" } }
-- ...or a specific one: parameters={ team="ai2", onlyCommander=true }
```

Because triggers and actions are fully decoupled, **any** trigger can fire `ExplodeBarrier`
(or any action), and several triggers may share one action.

Suggested barrier units: `armdrag` / `cordrag` (Dragon's Teeth), `armfort` / `corfort` (walls).

## How "freeze" works (important caveat)

BAR's skirmish AIs (BARb, etc.) run their own decision loop **outside Lua**; a gadget cannot
pause that loop. "Freeze" therefore makes the AI *effectively dormant*: its units are kept
**paralyzed** (re-applied every second) and **neutral**, and its economy is starved (give it
nothing until you wake it). `UnfreezeTeam` clears the paralysis/neutral flag and optionally
injects metal/energy, after which the real AI plays normally. New units a frozen team produces
are auto-frozen via the `UnitCreated`/`UnitFinished` callins.

## Iterating

- Logic changes (triggers/actions): edit the scenario file and run **`/luarules reload`** in the
  in-game chat console — no restart needed.
- `Setup`/base changes: restart the match (bases spawn once at game start).
- Validation errors are logged with the `[Mission API]` prefix in
  `…\Beyond-All-Reason\data\infolog.txt`.

## Files

| File | Role |
|------|------|
| `luarules/gadgets/api_missions.lua` | loader: reads modoptions, resolves team roles, runs Setup |
| `luarules/gadgets/api_missions_triggers.lua` | trigger detection + freeze upkeep + action dispatch |
| `luarules/mission_api/triggers_schema.lua` | trigger types + parameter validation schema |
| `luarules/mission_api/actions_schema.lua` | action types + parameter validation schema |
| `luarules/mission_api/actions.lua` | action implementations |
| `luarules/mission_api/actions_dispatcher.lua` | maps action type → function (positional unpack) |
| `luarules/mission_api/{triggers,actions}_loader.lua` | parse + validate the scenario tables |
| `singleplayer/missions/pve_demo.lua` | demo scenario + authoring template |

> **Note for new action/trigger types:** the dispatcher unpacks action parameters *positionally
> in schema order*, so a new action function's argument order **must** match the order of its
> entry in `actions_schema.lua`.
