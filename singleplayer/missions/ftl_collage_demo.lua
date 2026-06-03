-- FTL Collage demo -- example Mission API scenario for the map_extender PoC map
-- ("FTL Collage 0.1", built by tools/map_extender from "Faster Than Light").
-- Player lands on the western continent; a dormant BARb garrison holds the
-- north-eastern isle. Start positions are pinned by the gadget's
-- repositionStartUnits() (see luarules/gadgets/api_missions.lua), which is why
-- this works on a startpostype 0/1 map. Iterate logic with /luarules reload.

local triggerTypes = GG['MissionAPI'].TriggerTypes
local actionTypes  = GG['MissionAPI'].ActionTypes

local Teams = { humans = { allyTeam = 0 }, enemies = { allyTeam = 1 } }

local Setup = {
	-- AI dormant until woken by the timer trigger below.
	freeze = { "enemies" },
	-- Pin commanders exactly where the collage placed land (continent / NE isle).
	startPositions = {
		{ role = "humans", x = 2624,  z = 2211 },
		{ role = "ai1",    x = 10112, z = 2048 },
	},
}

local Triggers = {
	intro = {
		type = triggerTypes.TimeElapsed,
		settings = { repeating = false },
		parameters = { gameFrame = 30 },
		actions = { "msgIntro" },
	},
	-- After 30s the garrison wakes, gets a resource injection and some defenders.
	wake = {
		type = triggerTypes.TimeElapsed,
		settings = { repeating = false },
		parameters = { gameFrame = 900 },
		actions = { "unfreezeEnemy", "msgWake", "reinforce" },
	},
	-- Player commander reaches the enemy isle.
	arrive = {
		type = triggerTypes.UnitEnteredLocation,
		settings = { repeating = false },
		parameters = { team = "humans", onlyCommander = true, x = 10112, z = 2048, radius = 1800 },
		actions = { "msgArrived" },
	},
	-- Kill the enemy commander to win.
	win = {
		type = triggerTypes.UnitKilled,
		settings = { repeating = false },
		parameters = { team = "enemies", onlyCommander = true },
		actions = { "victory" },
	},
}

local Actions = {
	msgIntro = {
		type = actionTypes.SendMessage,
		parameters = { message = "FTL Collage: you are on the western continent. A dormant garrison holds the NE isle -- destroy its commander." },
	},
	unfreezeEnemy = {
		type = actionTypes.UnfreezeTeam,
		parameters = { team = "ai1", metal = 2000, energy = 2000 },
	},
	msgWake = {
		type = actionTypes.SendMessage,
		parameters = { message = "The garrison has awakened!" },
	},
	reinforce = {
		type = actionTypes.SpawnUnits,
		parameters = { name = "garrison", unitDefName = "armpw", quantity = 6, x = 10112, z = 2400, team = "ai1" },
	},
	msgArrived = {
		type = actionTypes.SendMessage,
		parameters = { message = "You have reached the enemy isle. Finish their commander!" },
	},
	victory = {
		type = actionTypes.Victory,
		parameters = { team = "humans" },
	},
}

return { Teams = Teams, Setup = Setup, Triggers = Triggers, Actions = Actions }
