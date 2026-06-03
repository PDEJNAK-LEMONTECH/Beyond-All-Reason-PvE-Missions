local triggerTypes = {
	TimeElapsed = 1,
	UnitExists = 2,
	UnitNotExists = 3,
	ConstructionStarted = 4,
	ConstructionFinished = 5,
	UnitKilled = 6,
	UnitCaptured = 7,
	UnitResurrected = 8,
	UnitEnteredLocation = 9,
	UnitLeftLocation = 10,
	UnitDwellLocation = 11,
	UnitSpotted = 12,
	UnitUnspotted = 13,
	FeatureNotExists = 14,
	FeatureReclaimed = 15,
	FeatureDestroyed = 16,
	ResourceStored = 17,
	ResourceProduction = 18,
	TotalUnitsLost = 19,
	TotalUnitsBuilt = 20,
	TotalUnitsKilled = 21,
	TotalUnitsCaptured = 22,
	TeamDestroyed = 23,
	Victory = 24,
	Defeat = 25,
	-- Added for the private scripted-PvE mod:
	TechLevelReached = 26,
	ArmyValueExceeded = 27,
}

local parameters = {
	[triggerTypes.TimeElapsed] = {
		[1] = {
			name = 'gameFrame',
			required = true,
			type = 'number',
		},
		[2] = {
			name = 'interval',
			required = false,
			type = 'number'
		},
	},
	[triggerTypes.UnitExists] = {  },
	[triggerTypes.UnitNotExists] = {  },
	[triggerTypes.ConstructionStarted] = {  },
	[triggerTypes.ConstructionFinished] = {  },
	[triggerTypes.UnitKilled] = {
		[1] = { name = 'unitName',      required = false, type = 'string' },  -- tracked name from SpawnUnits/Setup
		[2] = { name = 'team',          required = false, type = 'string' },  -- team role, e.g. "enemies"
		[3] = { name = 'onlyCommander', required = false, type = 'boolean' }, -- match only iscommander units
	},
	[triggerTypes.UnitCaptured] = {  },
	[triggerTypes.UnitResurrected] = {  },
	[triggerTypes.UnitEnteredLocation] = {
		[1] = { name = 'team',          required = false, type = 'string' },  -- team role whose units count, e.g. "humans"
		[2] = { name = 'onlyCommander', required = false, type = 'boolean' }, -- only trigger on commander units
		[3] = { name = 'x',             required = true,  type = 'number' },
		[4] = { name = 'z',             required = true,  type = 'number' },
		[5] = { name = 'radius',        required = true,  type = 'number' },
	},
	[triggerTypes.UnitLeftLocation] = {
		[1] = { name = 'team',          required = false, type = 'string' },
		[2] = { name = 'onlyCommander', required = false, type = 'boolean' },
		[3] = { name = 'x',             required = true,  type = 'number' },
		[4] = { name = 'z',             required = true,  type = 'number' },
		[5] = { name = 'radius',        required = true,  type = 'number' },
	},
	[triggerTypes.UnitDwellLocation] = {  },
	[triggerTypes.UnitSpotted] = {  },
	[triggerTypes.UnitUnspotted] = {  },
	[triggerTypes.FeatureNotExists] = {  },
	[triggerTypes.FeatureReclaimed] = {  },
	[triggerTypes.FeatureDestroyed] = {  },
	[triggerTypes.ResourceStored] = {
		[1] = { name = 'team',     required = false, type = 'string' },  -- role; fires if ANY team in it qualifies
		[2] = { name = 'resource', required = true,  type = 'string' },  -- "metal" or "energy"
		[3] = { name = 'amount',   required = true,  type = 'number' },  -- current stored >= amount
	},
	[triggerTypes.ResourceProduction] = {  },
	[triggerTypes.TotalUnitsLost] = {  },
	[triggerTypes.TotalUnitsBuilt] = {  },
	[triggerTypes.TotalUnitsKilled] = {  },
	[triggerTypes.TotalUnitsCaptured] = {  },
	[triggerTypes.TeamDestroyed] = {
		[1] = { name = 'team', required = true, type = 'string' },  -- role; fires when it has had units and now has none
	},
	[triggerTypes.Victory] = {  },
	[triggerTypes.Defeat] = {  },

	-- Added for the private scripted-PvE mod:
	[triggerTypes.TechLevelReached] = {
		[1] = { name = 'team',      required = false, type = 'string' },  -- team role, e.g. "humans"
		[2] = { name = 'techLevel', required = false, type = 'number' },  -- defaults to 2 in detection code
	},
	[triggerTypes.ArmyValueExceeded] = {
		[1] = { name = 'team',  required = false, type = 'string' },      -- team role, e.g. "humans"
		[2] = { name = 'value', required = true,  type = 'number' },      -- total metalCost threshold
	},
}

return {
	Types = triggerTypes,
	Parameters = parameters,
}