local actionTypes = {
	EnableTrigger = 1,
	DisableTrigger = 2,
	IssueOrders = 3,
	AllowCommands = 4,
	RestrictCommands = 5,
	AlterBuildlist = 6,
	EnableBuildOption = 7,
	DisableBuildOption = 8,
	SpawnUnits = 9,
	SpawnConstruction = 10,
	DespawnUnits = 11,
	SpawnWeapons = 12,
	SpawnEffects = 13,
	RevealLOS = 14,
	UnrevealLOS = 15,
	AlterMapZones = 16,
	TransferUnits = 17,
	ControlCamera = 18,
	Pause = 19,
	Unpause = 20,
	PlayMedia = 21,
	SendMessage = 22,
	Victory = 23,
	Defeat = 24,
	-- Added for the private scripted-PvE mod:
	GiveResource = 25,
	FreezeTeam = 26,
	UnfreezeTeam = 27,
	SpawnBarrier = 28,
	ExplodeBarrier = 29,
}

local parameters = {
	[actionTypes.EnableTrigger] = {
		[1] = {
			name = 'triggerId',
			required = true,
			type = 'string',
		},
	 },

	[actionTypes.DisableTrigger] = {
		[1] = {
			name = 'triggerId',
			required = true,
			type = 'string',
		},
	 },

	[actionTypes.IssueOrders] = {
		[1] = { name = 'name', required = false, type = 'string' },  -- target a named spawn group, and/or
		[2] = { name = 'team', required = false, type = 'string' },  -- target all units of a role
		[3] = { name = 'cmd',  required = true,  type = 'string' },  -- move | fight | attack | patrol | guard | stop
		[4] = { name = 'x',    required = false, type = 'number' },  -- target position (not needed for stop)
		[5] = { name = 'z',    required = false, type = 'number' },
	},
	[actionTypes.AllowCommands] = {  },
	[actionTypes.RestrictCommands] = {  },
	[actionTypes.AlterBuildlist] = {  },
	[actionTypes.EnableBuildOption] = {  },
	[actionTypes.DisableBuildOption] = {  },

	[actionTypes.SpawnUnits] = {
		[1] = {
			name = 'name',
			required = false,
			type = 'string',
		},
		[2] = {
			name = 'unitDefName',
			required = true,
			type = 'string',
		},
		[3] = {
			name = 'quantity',
			required = false,
			type = 'number',
		},
		[4] = {
			name = 'x',
			required = true,
			type = 'number',
		},
		[5] = {
			name = 'y',
			required = false,
			type = 'number',
		},
		[6] = {
			name = 'z',
			required = true,
			type = 'number',
		},
		[7] = {
			name = 'team',
			required = false,
			type = 'string',
		},
		[8] = {
			name = 'facing',
			required = false,
			type = 'string',
		},
	},

	[actionTypes.SpawnConstruction] = {  },
	[actionTypes.DespawnUnits] = {
		[1] = {
			name = 'name',
			required = true,
			type = 'string',
		},
	 },
	[actionTypes.SpawnWeapons] = {  },
	[actionTypes.SpawnEffects] = {  },
	[actionTypes.RevealLOS] = {  },
	[actionTypes.UnrevealLOS] = {  },
	[actionTypes.AlterMapZones] = {  },
	[actionTypes.TransferUnits] = {  },
	[actionTypes.ControlCamera] = {  },
	[actionTypes.Pause] = {  },
	[actionTypes.Unpause] = {  },
	[actionTypes.PlayMedia] = {  },

	[actionTypes.SendMessage] = {
		[1] = {
			name = 'message',
			required = true,
			type = 'string',
		}
	},

	[actionTypes.Victory] = {
		[1] = { name = 'team', required = false, type = 'string' },  -- winning role's side (default humans)
	},
	[actionTypes.Defeat] = {
		[1] = { name = 'team', required = false, type = 'string' },  -- losing role's side (default humans)
	},

	-- Added for the private scripted-PvE mod.
	-- NOTE: parameter order below MUST match the argument order of the matching
	-- function in actions.lua, because actions_dispatcher unpacks positionally.

	[actionTypes.GiveResource] = {
		[1] = { name = 'team',   required = true,  type = 'string' },  -- team role, e.g. "enemies"
		[2] = { name = 'metal',  required = false, type = 'number' },
		[3] = { name = 'energy', required = false, type = 'number' },
	},

	[actionTypes.FreezeTeam] = {
		[1] = { name = 'team', required = true, type = 'string' },     -- team role to freeze (dormant)
	},

	[actionTypes.UnfreezeTeam] = {
		[1] = { name = 'team',   required = true,  type = 'string' },   -- team role to wake
		[2] = { name = 'metal',  required = false, type = 'number' },   -- optional metal injection on wake
		[3] = { name = 'energy', required = false, type = 'number' },   -- optional energy injection on wake
	},

	[actionTypes.SpawnBarrier] = {
		[1] = { name = 'name',        required = true,  type = 'string' },  -- group name (used by ExplodeBarrier)
		[2] = { name = 'unitDefName', required = true,  type = 'string' },  -- e.g. armdrag / cordrag / armfort
		[3] = { name = 'team',        required = false, type = 'string' },  -- team role; defaults to Gaia
		[4] = { name = 'x1',          required = true,  type = 'number' },  -- barrier line start
		[5] = { name = 'z1',          required = true,  type = 'number' },
		[6] = { name = 'x2',          required = true,  type = 'number' },  -- barrier line end
		[7] = { name = 'z2',          required = true,  type = 'number' },
		[8] = { name = 'spacing',     required = false, type = 'number' },  -- distance between pieces (default 32)
	},

	[actionTypes.ExplodeBarrier] = {
		[1] = { name = 'name', required = true, type = 'string' },          -- group name from SpawnBarrier
	},
}

return {
	Types = actionTypes,
	Parameters = parameters
}