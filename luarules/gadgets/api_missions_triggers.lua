local gadget = gadget ---@type Gadget

function gadget:GetInfo()
	return {
		name = "Mission API triggers",
		desc = "Monitor and activate triggers, dispatch actions, and upkeep team freeze",
		date = "2023.03.16",
		layer = 1, -- MUST be loaded after api_missions
		enabled = true,
	}
end

if not gadgetHandler:IsSyncedCode() then
	return false
end

local actionsDispatcher
local missionAPI, types, triggers, trackedUnits, frozenTeams

-- Pre-categorised trigger lists (built in Initialize for cheap per-frame scanning).
local timeTriggers       = {}
local areaEnterTriggers  = {}
local areaLeftTriggers   = {}
local techTriggers       = {}
local armyTriggers       = {}
local killTriggers       = {}
local resourceTriggers   = {}
local teamDestroyedTriggers = {}

-- Throttle: heavy polls don't need to run every frame.
local AREA_INTERVAL   = 15   -- ~0.5s
local ARMY_INTERVAL   = 30   -- ~1s
local FREEZE_INTERVAL = 15   -- re-apply paralyze before it decays meaningfully

local spGetUnitPosition = Spring.GetUnitPosition
local spGetTeamUnits    = Spring.GetTeamUnits
local spGetUnitDefID    = Spring.GetUnitDefID
local spGetTeamResources = Spring.GetTeamResources

-------------------------------------------------------------------------------
-- Unit classification helpers
-------------------------------------------------------------------------------

local isCommanderDef = {}   -- [unitDefID] = true
local techLevelDef   = {}   -- [unitDefID] = number
local metalCostDef   = {}   -- [unitDefID] = number

for unitDefID, ud in pairs(UnitDefs) do
	isCommanderDef[unitDefID] = (ud.customParams and ud.customParams.iscommander) and true or false
	techLevelDef[unitDefID]   = tonumber(ud.customParams and ud.customParams.techlevel) or 1
	metalCostDef[unitDefID]   = ud.metalCost or 0
end

local function teamSet(teamIDs)
	local s = {}
	for _, t in ipairs(teamIDs or {}) do s[t] = true end
	return s
end

-------------------------------------------------------------------------------
-- Trigger validity / activation (kept from the original scaffold)
-------------------------------------------------------------------------------

local function triggerValid(trigger)
	if not trigger.settings.active then return false end

	for _, prerequisiteTrigger in pairs(trigger.settings.prerequisites) do
		if not prerequisiteTrigger.triggered then return false end
	end

	if trigger.triggered and not trigger.settings.repeating then return false end
	if trigger.settings.repeating and trigger.settings.maxRepeats ~= nil and trigger.repeatCount > trigger.settings.maxRepeats then return false end
	if trigger.settings.difficulties ~= nil and not trigger.settings.difficulties[missionAPI.Difficulty] then return false end

	return true
end

local function activateTrigger(trigger)
	if not triggerValid(trigger) then
		return
	end

	trigger.triggered = true
	trigger.repeatCount = trigger.repeatCount + 1

	for _, actionId in ipairs(trigger.actions) do
		actionsDispatcher.Invoke(actionId)
	end
end

-------------------------------------------------------------------------------
-- Resolve a trigger's "team" role parameter into a concrete teamID set.
-------------------------------------------------------------------------------

local function resolveTriggerTeams(trigger)
	local role = trigger.parameters.team
	if not role then
		-- No role given: default to the human teams.
		local humans = missionAPI.Teams and missionAPI.Teams.humans
		return humans and teamSet(humans.teamIDs) or {}
	end
	local entry = missionAPI.Teams and missionAPI.Teams[role]
	if not entry then
		Spring.Log('api_missions_triggers.lua', LOG.ERROR, "[Mission API] Trigger references unknown team role: " .. tostring(role))
		return {}
	end
	return teamSet(entry.teamIDs)
end

-------------------------------------------------------------------------------
-- Initialize: split triggers by type, resolve their team sets.
-------------------------------------------------------------------------------

function gadget:Initialize()
	if not GG['MissionAPI'] then
		gadgetHandler:RemoveGadget()
		return
	end

	actionsDispatcher = VFS.Include('luarules/mission_api/actions_dispatcher.lua')
	missionAPI   = GG['MissionAPI']
	types        = missionAPI.TriggerTypes
	triggers     = missionAPI.Triggers
	trackedUnits = missionAPI.TrackedUnits
	frozenTeams  = missionAPI.FrozenTeams

	for _, trigger in pairs(triggers) do
		local t = trigger.type
		if t == types.TimeElapsed then
			timeTriggers[#timeTriggers + 1] = trigger
		elseif t == types.UnitEnteredLocation then
			trigger._teams = resolveTriggerTeams(trigger)
			trigger._present = false
			areaEnterTriggers[#areaEnterTriggers + 1] = trigger
		elseif t == types.UnitLeftLocation then
			trigger._teams = resolveTriggerTeams(trigger)
			trigger._present = false
			areaLeftTriggers[#areaLeftTriggers + 1] = trigger
		elseif t == types.TechLevelReached then
			trigger._teams = resolveTriggerTeams(trigger)
			techTriggers[#techTriggers + 1] = trigger
		elseif t == types.ArmyValueExceeded then
			trigger._teams = resolveTriggerTeams(trigger)
			armyTriggers[#armyTriggers + 1] = trigger
		elseif t == types.UnitKilled then
			trigger._teams = trigger.parameters.team and resolveTriggerTeams(trigger) or nil
			killTriggers[#killTriggers + 1] = trigger
		elseif t == types.ResourceStored then
			trigger._teams = resolveTriggerTeams(trigger)
			resourceTriggers[#resourceTriggers + 1] = trigger
		elseif t == types.TeamDestroyed then
			trigger._teams = resolveTriggerTeams(trigger)
			trigger._everHadUnits = false
			teamDestroyedTriggers[#teamDestroyedTriggers + 1] = trigger
		end
	end
end

-------------------------------------------------------------------------------
-- Area detection helpers
-------------------------------------------------------------------------------

-- Is any qualifying unit of the trigger's team set within its cylinder?
local function anyUnitInArea(trigger)
	local p = trigger.parameters
	local r2 = p.radius * p.radius
	for teamID in pairs(trigger._teams) do
		for _, unitID in ipairs(spGetTeamUnits(teamID) or {}) do
			if (not p.onlyCommander) or isCommanderDef[spGetUnitDefID(unitID) or -1] then
				local x, _, z = spGetUnitPosition(unitID)
				if x then
					local dx, dz = x - p.x, z - p.z
					if dx * dx + dz * dz <= r2 then
						return true
					end
				end
			end
		end
	end
	return false
end

local function singleTeamArmyValue(teamID)
	local total = 0
	for _, unitID in ipairs(spGetTeamUnits(teamID) or {}) do
		total = total + (metalCostDef[spGetUnitDefID(unitID) or -1] or 0)
	end
	return total
end

local function roleUnitCount(teamSetTable)
	local total = 0
	for teamID in pairs(teamSetTable) do
		total = total + #(spGetTeamUnits(teamID) or {})
	end
	return total
end

-------------------------------------------------------------------------------
-- Per-frame evaluation + freeze upkeep
-------------------------------------------------------------------------------

function gadget:GameFrame(n)
	-- TimeElapsed (unchanged behaviour)
	for _, trigger in ipairs(timeTriggers) do
		local gameframe = trigger.parameters.gameFrame
		local interval  = trigger.parameters.interval
		if n == gameframe or (trigger.settings.repeating and interval and n > gameframe and (n - gameframe) % interval == 0) then
			activateTrigger(trigger)
		end
	end

	-- Area enter/leave (edge-detected)
	if n % AREA_INTERVAL == 0 then
		for _, trigger in ipairs(areaEnterTriggers) do
			local inside = anyUnitInArea(trigger)
			if inside and not trigger._present then
				activateTrigger(trigger)
			end
			trigger._present = inside
		end
		for _, trigger in ipairs(areaLeftTriggers) do
			local inside = anyUnitInArea(trigger)
			if (not inside) and trigger._present then
				activateTrigger(trigger)
			end
			trigger._present = inside
		end
	end

	if n % ARMY_INTERVAL == 0 then
		-- Army value threshold: fire if ANY single team in the role qualifies.
		for _, trigger in ipairs(armyTriggers) do
			for teamID in pairs(trigger._teams) do
				if singleTeamArmyValue(teamID) >= trigger.parameters.value then
					activateTrigger(trigger)
					break
				end
			end
		end

		-- Resource stored: fire if ANY team in the role has >= amount stored.
		for _, trigger in ipairs(resourceTriggers) do
			local res = trigger.parameters.resource
			local amount = trigger.parameters.amount
			for teamID in pairs(trigger._teams) do
				local current = spGetTeamResources(teamID, res)
				if current and current >= amount then
					activateTrigger(trigger)
					break
				end
			end
		end

		-- Team destroyed: fire once the role has had units and then has none.
		for _, trigger in ipairs(teamDestroyedTriggers) do
			local count = roleUnitCount(trigger._teams)
			if count > 0 then
				trigger._everHadUnits = true
			elseif trigger._everHadUnits then
				activateTrigger(trigger)
			end
		end
	end

	-- Freeze upkeep: keep frozen teams' units paralyzed + neutral.
	if n % FREEZE_INTERVAL == 0 and missionAPI.FreezeUnit then
		for teamID in pairs(frozenTeams) do
			for _, unitID in ipairs(spGetTeamUnits(teamID) or {}) do
				missionAPI.FreezeUnit(unitID)
			end
		end
	end
end

-------------------------------------------------------------------------------
-- Tech level reached: detect on construction completion.
-------------------------------------------------------------------------------

function gadget:UnitFinished(unitID, unitDefID, unitTeam)
	-- Freeze freshly-finished units belonging to a frozen team.
	if frozenTeams[unitTeam] and missionAPI.FreezeUnit then
		missionAPI.FreezeUnit(unitID)
	end

	local level = techLevelDef[unitDefID] or 1
	for _, trigger in ipairs(techTriggers) do
		if trigger._teams[unitTeam] and level >= (trigger.parameters.techLevel or 2) then
			activateTrigger(trigger)
		end
	end
end

function gadget:UnitCreated(unitID, unitDefID, unitTeam)
	-- Keep dormant teams dormant even if they somehow start a build.
	if frozenTeams[unitTeam] and missionAPI.FreezeUnit then
		missionAPI.FreezeUnit(unitID)
	end
end

-------------------------------------------------------------------------------
-- Unit killed: match by tracked name, or by team (+optional commander filter).
-------------------------------------------------------------------------------

function gadget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
	local name = trackedUnits.byId[unitID]

	for _, trigger in ipairs(killTriggers) do
		local p = trigger.parameters
		local matched = false
		if p.unitName and name == p.unitName then
			matched = true
		elseif trigger._teams and trigger._teams[unitTeam] then
			matched = (not p.onlyCommander) or isCommanderDef[unitDefID]
		end
		if matched then
			activateTrigger(trigger)
		end
	end

	-- Keep tracking tables clean.
	if name and missionAPI.UntrackId then
		missionAPI.UntrackId(unitID)
	end
end
