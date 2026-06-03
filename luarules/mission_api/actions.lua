-- Mission API action implementations (SYNCED).
-- Included by actions_dispatcher.lua, which unpacks each action's parameters
-- positionally in the order declared in actions_schema.lua and calls the matching
-- function below. Therefore every function's argument order MUST match its schema.

local missionAPI   = GG['MissionAPI']
local trackedUnits = missionAPI.TrackedUnits   -- { byName = { [name] = {ids...} }, byId = { [id] = name } }
local triggers     = missionAPI.Triggers
local frozenTeams  = missionAPI.FrozenTeams     -- { [teamID] = true }
local barriers     = missionAPI.Barriers        -- { [name] = {ids...} }

local PARALYZE_AMOUNT = 1.0e9                    -- kept topped-up by the freeze upkeep loop

local spCreateUnit       = Spring.CreateUnit
local spDestroyUnit      = Spring.DestroyUnit
local spGetGroundHeight  = Spring.GetGroundHeight
local spAddTeamResource  = Spring.AddTeamResource
local spSetUnitHealth    = Spring.SetUnitHealth
local spSetUnitNeutral   = Spring.SetUnitNeutral
local spGetTeamUnits     = Spring.GetTeamUnits
local spGetGaiaTeamID    = Spring.GetGaiaTeamID
local spGiveOrderToUnit  = Spring.GiveOrderToUnit
local spGameOver         = Spring.GameOver
local spGetAllyTeamList  = Spring.GetAllyTeamList
local spGetTeamAllyTeamID = Spring.GetTeamAllyTeamID

local CMD_MAP = {
	move   = CMD.MOVE,
	fight  = CMD.FIGHT,
	attack = CMD.ATTACK,
	patrol = CMD.PATROL,
	guard  = CMD.GUARD,
	stop   = CMD.STOP,
}

local function logError(msg)
	Spring.Log('actions.lua', LOG.ERROR, "[Mission API] " .. msg)
end

-------------------------------------------------------------------------------
-- Team-role resolution
-- GG['MissionAPI'].Teams is populated by api_missions.lua and maps a role name
-- (e.g. "humans", "enemies", "enemy1") to { teamIDs = {...}, allyTeamID, primary }.
-------------------------------------------------------------------------------

local function resolveTeams(role)
	local entry = missionAPI.Teams and missionAPI.Teams[role]
	if not entry then
		logError("Unknown team role: " .. tostring(role))
		return {}
	end
	return entry.teamIDs or {}
end

local function resolvePrimaryTeam(role)
	local entry = missionAPI.Teams and missionAPI.Teams[role]
	if entry and entry.primary then
		return entry.primary
	end
	logError("Unknown team role (primary): " .. tostring(role))
	return nil
end

-------------------------------------------------------------------------------
-- Tracked-unit bookkeeping
-------------------------------------------------------------------------------

local function track(name, unitId)
	if not (name and unitId) then return end
	trackedUnits.byName[name] = trackedUnits.byName[name] or {}
	table.insert(trackedUnits.byName[name], unitId)
	trackedUnits.byId[unitId] = name
end

local function untrackId(unitId)
	local name = trackedUnits.byId[unitId]
	trackedUnits.byId[unitId] = nil
	if name and trackedUnits.byName[name] then
		for i, id in ipairs(trackedUnits.byName[name]) do
			if id == unitId then
				table.remove(trackedUnits.byName[name], i)
				break
			end
		end
	end
end

-- Exposed so the triggers gadget can keep tracking tables clean on unit death.
missionAPI.UntrackId = untrackId

-------------------------------------------------------------------------------
-- Freeze helpers (also used by the upkeep loop in api_missions_triggers.lua)
-------------------------------------------------------------------------------

local function freezeUnit(unitId)
	spSetUnitHealth(unitId, { paralyze = PARALYZE_AMOUNT })
	spSetUnitNeutral(unitId, true)
end
missionAPI.FreezeUnit = freezeUnit

local function unfreezeUnit(unitId)
	spSetUnitHealth(unitId, { paralyze = 0 })
	spSetUnitNeutral(unitId, false)
end

-------------------------------------------------------------------------------
-- Existing actions (kept; SendMessage/Enable/Disable unchanged)
-------------------------------------------------------------------------------

local function enableTrigger(triggerId)
	if triggers[triggerId] then
		triggers[triggerId].settings.active = true
	else
		logError("EnableTrigger: unknown trigger " .. tostring(triggerId))
	end
end

local function disableTrigger(triggerId)
	if triggers[triggerId] then
		triggers[triggerId].settings.active = false
	else
		logError("DisableTrigger: unknown trigger " .. tostring(triggerId))
	end
end

local function sendMessage(message)
	-- Synced echo reaches all clients' infolog; widgets may also surface it.
	Spring.Echo("[Mission] " .. tostring(message))
end

-------------------------------------------------------------------------------
-- SpawnUnits (fixed: honours team role, quantity and facing)
-- schema order: name, unitDefName, quantity, x, y, z, team, facing
-------------------------------------------------------------------------------

local function spawnUnits(name, unitDefName, quantity, x, y, z, team, facing)
	quantity = quantity or 1
	facing   = facing or "south"

	local teamID = team and resolvePrimaryTeam(team) or spGetGaiaTeamID()
	if not teamID then return end

	-- Lay multiples out in a simple grid so they do not stack on one tile.
	local perRow = math.ceil(math.sqrt(quantity))
	for i = 0, quantity - 1 do
		local ox = (i % perRow) * 48
		local oz = math.floor(i / perRow) * 48
		local px, pz = x + ox, z + oz
		local py = y or spGetGroundHeight(px, pz)

		local unitId = spCreateUnit(unitDefName, px, py, pz, facing, teamID)
		if unitId then
			track(name, unitId)
		else
			logError("SpawnUnits: failed to create '" .. tostring(unitDefName) .. "' at " .. px .. "," .. pz)
		end
	end
end

local function despawnUnits(name)
	local ids = trackedUnits.byName[name]
	if not ids then return end

	for _, unitId in ipairs(ids) do
		trackedUnits.byId[unitId] = nil
		spDestroyUnit(unitId, false, true)   -- selfd=false, reclaimed=true -> silent removal
	end
	trackedUnits.byName[name] = nil
end

-------------------------------------------------------------------------------
-- GiveResource: inject metal/energy into every team of a role
-- schema order: team, metal, energy
-------------------------------------------------------------------------------

local function giveResource(team, metal, energy)
	for _, teamID in ipairs(resolveTeams(team)) do
		if metal and metal ~= 0 then
			spAddTeamResource(teamID, "metal", metal)
		end
		if energy and energy ~= 0 then
			spAddTeamResource(teamID, "energy", energy)
		end
	end
end

-------------------------------------------------------------------------------
-- FreezeTeam / UnfreezeTeam
-------------------------------------------------------------------------------

local function freezeTeam(team)
	for _, teamID in ipairs(resolveTeams(team)) do
		frozenTeams[teamID] = true
		for _, unitId in ipairs(spGetTeamUnits(teamID) or {}) do
			freezeUnit(unitId)
		end
	end
end

-- schema order: team, metal, energy
local function unfreezeTeam(team, metal, energy)
	for _, teamID in ipairs(resolveTeams(team)) do
		frozenTeams[teamID] = nil
		for _, unitId in ipairs(spGetTeamUnits(teamID) or {}) do
			unfreezeUnit(unitId)
		end
		if metal and metal ~= 0 then
			spAddTeamResource(teamID, "metal", metal)
		end
		if energy and energy ~= 0 then
			spAddTeamResource(teamID, "energy", energy)
		end
	end
end

-------------------------------------------------------------------------------
-- SpawnBarrier / ExplodeBarrier (dragon's teeth / walls along a line)
-- schema order: name, unitDefName, team, x1, z1, x2, z2, spacing
-------------------------------------------------------------------------------

local function spawnBarrier(name, unitDefName, team, x1, z1, x2, z2, spacing)
	spacing = spacing or 32
	local teamID = team and resolvePrimaryTeam(team) or spGetGaiaTeamID()
	if not teamID then return end

	local dx, dz = x2 - x1, z2 - z1
	local length = math.sqrt(dx * dx + dz * dz)
	local steps  = math.max(1, math.floor(length / spacing))

	barriers[name] = barriers[name] or {}
	for i = 0, steps do
		local t = (steps == 0) and 0 or (i / steps)
		local px = x1 + dx * t
		local pz = z1 + dz * t
		local py = spGetGroundHeight(px, pz)
		local unitId = spCreateUnit(unitDefName, px, py, pz, "south", teamID)
		if unitId then
			table.insert(barriers[name], unitId)
		end
	end
end

local function explodeBarrier(name)
	local ids = barriers[name]
	if not ids then
		logError("ExplodeBarrier: unknown barrier '" .. tostring(name) .. "'")
		return
	end
	for _, unitId in ipairs(ids) do
		spDestroyUnit(unitId, false, false)   -- reclaimed=false -> real explosion
	end
	barriers[name] = nil
end

-------------------------------------------------------------------------------
-- IssueOrders: command a named spawn group and/or a whole role to move/attack.
-- schema order: name, team, cmd, x, z
-------------------------------------------------------------------------------

local function issueOrders(name, team, cmd, x, z)
	local cmdID = CMD_MAP[cmd]
	if not cmdID then
		logError("IssueOrders: unknown cmd '" .. tostring(cmd) .. "'")
		return
	end

	local units = {}
	if name and trackedUnits.byName[name] then
		for _, id in ipairs(trackedUnits.byName[name]) do units[#units + 1] = id end
	end
	if team then
		for _, teamID in ipairs(resolveTeams(team)) do
			for _, id in ipairs(spGetTeamUnits(teamID) or {}) do units[#units + 1] = id end
		end
	end

	local params = {}
	if cmdID ~= CMD.STOP and x and z then
		params = { x, spGetGroundHeight(x, z), z }
	end

	for _, id in ipairs(units) do
		spGiveOrderToUnit(id, cmdID, params, {})
	end
end

-------------------------------------------------------------------------------
-- Victory / Defeat: actually end the match for a side (default humans).
-------------------------------------------------------------------------------

local function victory(team)
	local entry = missionAPI.Teams[team or "humans"]
	if entry then
		spGameOver({ entry.allyTeamID })
	end
end

local function defeat(team)
	local loser = missionAPI.Teams[team or "humans"]
	if not loser then return end
	local gaiaAlly = spGetTeamAllyTeamID(spGetGaiaTeamID())
	local winners = {}
	for _, allyID in ipairs(spGetAllyTeamList() or {}) do
		if allyID ~= loser.allyTeamID and allyID ~= gaiaAlly then
			winners[#winners + 1] = allyID
		end
	end
	spGameOver(winners)
end

return {
	EnableTrigger  = enableTrigger,
	DisableTrigger = disableTrigger,
	SendMessage    = sendMessage,
	SpawnUnits     = spawnUnits,
	DespawnUnits   = despawnUnits,
	GiveResource   = giveResource,
	FreezeTeam     = freezeTeam,
	UnfreezeTeam   = unfreezeTeam,
	SpawnBarrier   = spawnBarrier,
	ExplodeBarrier = explodeBarrier,
	IssueOrders    = issueOrders,
	Victory        = victory,
	Defeat         = defeat,
}
