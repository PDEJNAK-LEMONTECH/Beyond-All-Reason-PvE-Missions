-- ============================================================================
-- pve_demo.lua  --  Scripted PvE demo scenario (Mission API)
-- ----------------------------------------------------------------------------
-- This file is BOTH a working demo and the authoring template. It is loaded by
-- the Mission API when the `mission_path` modoption is set to:
--     missions/pve_demo.lua
--
-- A scenario returns four tables:
--   Teams    - (optional) maps role names to allyTeams/teams. Defaults:
--                humans = allyTeam 0, enemies = allyTeam 1.
--   Setup    - run once at game start: which teams start frozen (dormant) and
--              what pre-placed base each team gets.
--   Triggers - conditions that, when met, fire one or more actions.
--   Actions  - the things that happen (spawn, give metal, wake team, barriers).
--
-- Lobby convention (see MULTIPLAYER_HOST.md / MISSION_API.md):
--   put the human player(s) on allyTeam 0 and the BARb AI(s) on allyTeam 1.
--
-- Coordinates here are derived from the map size so the demo works on any map.
-- For a hand-tuned scenario you would use absolute world coordinates instead.
-- ============================================================================

local mapX = Game.mapSizeX
local mapZ = Game.mapSizeZ

local centerX, centerZ = mapX * 0.5, mapZ * 0.5
local enemyX,  enemyZ  = mapX * 0.80, mapZ * 0.50   -- where the dormant AI base sits

local triggerTypes = GG['MissionAPI'].TriggerTypes
local actionTypes  = GG['MissionAPI'].ActionTypes

-- ----------------------------------------------------------------------------

local Teams = {
	humans  = { allyTeam = 0 },
	enemies = { allyTeam = 1 },
}

local Setup = {
	-- The AI starts dormant: its commander (and the base below) are paralyzed
	-- and neutral until a trigger wakes it.
	freeze = { "enemies" },

	-- Pre-placed base layout for the AI. The engine already spawns the AI's
	-- commander from the start script; these are extra buildings around it.
	bases = {
		enemies = {
			{ def = "armmex",   x = enemyX - 120, z = enemyZ - 120 },
			{ def = "armsolar", x = enemyX - 120, z = enemyZ + 20  },
			{ def = "armsolar", x = enemyX - 60,  z = enemyZ + 20  },
			{ def = "armlab",   x = enemyX + 40,  z = enemyZ,        facing = "west" },
			{ def = "armllt",   x = enemyX + 160, z = enemyZ - 80  },
			{ def = "armllt",   x = enemyX + 160, z = enemyZ + 80  },
		},
	},
}

-- ----------------------------------------------------------------------------

local Triggers = {
	-- (0) At game start: raise a dragon's-teeth wall across the centre of the map.
	spawnWallAtStart = {
		type = triggerTypes.TimeElapsed,
		settings = { repeating = false },
		parameters = { gameFrame = 1 },
		actions = { "raiseWall", "msgWall" },
	},

	-- (1) Human COMMANDER reaches the central wall -> blow it open.
	commanderApproach = {
		type = triggerTypes.UnitEnteredLocation,
		settings = { repeating = false },
		parameters = {
			team = "humans",
			onlyCommander = true,
			x = centerX, z = centerZ, radius = 700,
		},
		actions = { "blowWall", "msgBlow" },
	},

	-- (2) Human reaches T2 -> feed the (still dormant) AI metal + a defensive squad,
	--     then order that squad to push toward the centre (new IssueOrders action).
	humanReachedT2 = {
		type = triggerTypes.TechLevelReached,
		settings = { repeating = false },
		parameters = { team = "humans", techLevel = 2 },
		actions = { "feedEnemy", "enemyDefenders", "orderDefenders", "msgT2" },
	},

	-- (2b) Human stockpiles metal -> taunt (new ResourceStored trigger, per-team "any").
	humanStockpile = {
		type = triggerTypes.ResourceStored,
		settings = { repeating = false },
		parameters = { team = "humans", resource = "metal", amount = 3000 },
		actions = { "msgStockpile" },
	},

	-- (3) Human army value exceeds the threshold -> WAKE the AI.
	humanArmyBig = {
		type = triggerTypes.ArmyValueExceeded,
		settings = { repeating = false },
		parameters = { team = "humans", value = 8000 },
		actions = { "wakeEnemy", "msgWake" },
	},

	-- (4) The AI commander dies -> message + actually WIN the match (new Victory action).
	enemyComKilled = {
		type = triggerTypes.UnitKilled,
		settings = { repeating = false },
		parameters = { team = "enemies", onlyCommander = true },
		actions = { "msgVictory", "winGame" },
	},
}

-- ----------------------------------------------------------------------------

local Actions = {
	raiseWall = {
		type = actionTypes.SpawnBarrier,
		parameters = {
			name = "centerWall",
			unitDefName = "armdrag",          -- Armada Dragon's Teeth
			-- team omitted -> spawned on Gaia so it blocks everyone neutrally
			x1 = centerX - 400, z1 = centerZ,
			x2 = centerX + 400, z2 = centerZ,
			spacing = 40,
		},
	},
	msgWall = {
		type = actionTypes.SendMessage,
		parameters = { message = "A barrier blocks the centre of the map. Push your commander up to breach it." },
	},
	blowWall = {
		type = actionTypes.ExplodeBarrier,
		parameters = { name = "centerWall" },
	},
	msgBlow = {
		type = actionTypes.SendMessage,
		parameters = { message = "The central wall is breached!" },
	},

	feedEnemy = {
		type = actionTypes.GiveResource,
		parameters = { team = "enemies", metal = 5000, energy = 5000 },
	},
	enemyDefenders = {
		type = actionTypes.SpawnUnits,
		parameters = {
			name = "enemyDefenders",
			unitDefName = "armrock",          -- Rocko (bot)
			quantity = 4,
			x = enemyX - 200, z = enemyZ,
			team = "enemies",
		},
	},
	orderDefenders = {
		type = actionTypes.IssueOrders,
		parameters = { name = "enemyDefenders", cmd = "fight", x = centerX, z = centerZ },
	},
	msgT2 = {
		type = actionTypes.SendMessage,
		parameters = { message = "The enemy stirs as you reach Tech 2..." },
	},
	msgStockpile = {
		type = actionTypes.SendMessage,
		parameters = { message = "Sitting on a pile of metal? The enemy notices." },
	},

	wakeEnemy = {
		type = actionTypes.UnfreezeTeam,
		parameters = { team = "enemies", metal = 8000, energy = 8000 },
	},
	msgWake = {
		type = actionTypes.SendMessage,
		parameters = { message = "The enemy AI has awoken. Good luck." },
	},

	msgVictory = {
		type = actionTypes.SendMessage,
		parameters = { message = "Enemy commander destroyed - victory!" },
	},
	winGame = {
		type = actionTypes.Victory,
		parameters = { team = "humans" },
	},
}

return {
	Teams = Teams,
	Setup = Setup,
	Triggers = Triggers,
	Actions = Actions,
}
