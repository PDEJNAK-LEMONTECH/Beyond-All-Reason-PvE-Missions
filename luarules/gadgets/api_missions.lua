local gadget = gadget ---@type Gadget

function gadget:GetInfo()
	return {
		name = "Mission API loader",
		desc = "Load and populate global mission table for scripted PvE scenarios",
		date = "2023.03.14",
		layer = 0,
		enabled = true, -- removes itself at runtime unless the mission_path modoption is set
	}
end

if not gadgetHandler:IsSyncedCode() then
	return false
end

local scriptPath
local triggersController, actionsController
local setup
local setupDone = false

-------------------------------------------------------------------------------
-- Team-role resolution
-- Roles map to teamIDs. A scenario may declare roles explicitly; otherwise we
-- default to the documented lobby convention: humans on allyTeam 0, AIs on
-- allyTeam 1. We also auto-generate indexed roles human1.. / enemy1.. .
-------------------------------------------------------------------------------

local function teamsInAllyTeam(allyTeamID, gaiaTeamID)
	local result = {}
	for _, teamID in ipairs(Spring.GetTeamList() or {}) do
		if teamID ~= gaiaTeamID and Spring.GetTeamAllyTeamID(teamID) == allyTeamID then
			result[#result + 1] = teamID
		end
	end
	return result
end

local function makeRole(teamIDs, allyTeamID)
	return { teamIDs = teamIDs, allyTeamID = allyTeamID, primary = teamIDs[1] }
end

local function buildTeams(declaredTeams)
	local gaiaTeamID = Spring.GetGaiaTeamID()
	local roles = {}

	-- Explicit declarations from the scenario file.
	if declaredTeams then
		for role, def in pairs(declaredTeams) do
			if def.team ~= nil then
				roles[role] = makeRole({ def.team }, Spring.GetTeamAllyTeamID(def.team))
			elseif def.allyTeam ~= nil then
				roles[role] = makeRole(teamsInAllyTeam(def.allyTeam, gaiaTeamID), def.allyTeam)
			end
		end
	end

	-- Defaults (only fill roles not already declared).
	if not roles.humans then
		roles.humans = makeRole(teamsInAllyTeam(0, gaiaTeamID), 0)
	end
	if not roles.enemies then
		roles.enemies = makeRole(teamsInAllyTeam(1, gaiaTeamID), 1)
	end

	-- Convenience indexed roles + aliases so scenarios can target a side or a
	-- specific AI by its (stable) number: human1/player1, enemy1/ai1, ...
	-- AI/team numbering is stable across runs as long as the start script is fixed.
	for i, teamID in ipairs(roles.humans.teamIDs) do
		roles['human' .. i]  = makeRole({ teamID }, roles.humans.allyTeamID)
		roles['player' .. i] = roles['human' .. i]
	end
	for i, teamID in ipairs(roles.enemies.teamIDs) do
		roles['enemy' .. i] = makeRole({ teamID }, roles.enemies.allyTeamID)
		roles['ai' .. i]    = roles['enemy' .. i]
	end

	-- Whole-side aliases.
	roles.aiteam  = roles.enemies   -- the AI side (all AIs)
	roles.players = roles.humans    -- the human side (all humans)

	return roles
end

-------------------------------------------------------------------------------
-- Mission loading
-------------------------------------------------------------------------------

local function loadMission()
	local mission = VFS.Include("singleplayer/" .. scriptPath)

	GG['MissionAPI'].Teams = buildTeams(mission.Teams)
	setup = mission.Setup

	triggersController.PreprocessRawTriggers(mission.Triggers or {})
	actionsController.PreprocessRawActions(mission.Actions or {})

	GG['MissionAPI'].Triggers = triggersController.GetTriggers()
	GG['MissionAPI'].Actions = actionsController.GetActions()

	triggersController.PostprocessTriggers()
end

-- Apply the scenario's freeze list immediately so commanders spawned by the
-- engine get caught by the freeze upkeep / UnitCreated callin in the triggers gadget.
local function applyInitialFreeze()
	if not (setup and setup.freeze) then return end
	for _, role in ipairs(setup.freeze) do
		local entry = GG['MissionAPI'].Teams[role]
		if entry then
			for _, teamID in ipairs(entry.teamIDs) do
				GG['MissionAPI'].FrozenTeams[teamID] = true
			end
		else
			Spring.Log('api_missions.lua', LOG.ERROR, "[Mission API] Setup.freeze references unknown role: " .. tostring(role))
		end
	end
end

-- Pin start positions (player + AIs) from the scenario. We set the team start
-- positions here in Initialize, but be aware this ALONE is NOT enough: for
-- startpostype 0/1 the engine forcibly resets every team's start position to the
-- MAP's built-in defaults at the GameStart transition (after Initialize AND
-- GamePreload run), ignoring both the script's StartPosX/Z and this call. So the
-- commanders still spawn at the map defaults; repositionStartUnits() (frame 1)
-- is what actually moves them onto the scenario positions. We keep this call so
-- the values are correct for anything that reads them before the engine reset.
local function applyStartPositions()
	if not (setup and setup.startPositions) then return end
	for _, sp in ipairs(setup.startPositions) do
		local entry = GG['MissionAPI'].Teams[sp.role]
		if entry then
			local y = Spring.GetGroundHeight(sp.x, sp.z)
			for _, teamID in ipairs(entry.teamIDs) do
				Spring.SetTeamStartPosition(teamID, sp.x, y, sp.z)
			end
		else
			Spring.Log('api_missions.lua', LOG.ERROR, "[Mission API] Setup.startPositions references unknown role: " .. tostring(sp.role))
		end
	end
end

-- For startPosType FIXED/RANDOM (startpostype 0/1) the engine forcibly resets every
-- team's start position to the MAP's built-in defaults at the GameStart transition,
-- AFTER Initialize/GamePreload run -- so Spring.SetTeamStartPosition can't pin spawns,
-- and game_initial_spawn spawns each commander at the map default. We therefore move
-- the already-spawned start units (the commanders) onto the scenario's intended
-- positions on frame 1, before we place the pre-set bases.
local function repositionStartUnits()
	if not (setup and setup.startPositions) then return end
	for _, sp in ipairs(setup.startPositions) do
		local entry = GG['MissionAPI'].Teams[sp.role]
		if entry then
			local y = Spring.GetGroundHeight(sp.x, sp.z)
			for _, teamID in ipairs(entry.teamIDs) do
				for _, unitID in ipairs(Spring.GetTeamUnits(teamID) or {}) do
					Spring.SetUnitPosition(unitID, sp.x, y, sp.z)
				end
				-- keep the stored start position consistent with the moved unit
				Spring.SetTeamStartPosition(teamID, sp.x, y, sp.z)
			end
		end
	end
end

-- Spawn pre-placed bases. Deferred to GameFrame 1 so teams/terrain are ready;
-- spawned units inherit the frozen state via the triggers gadget's UnitCreated.
local function spawnBases()
	if not (setup and setup.bases) then return end
	for role, units in pairs(setup.bases) do
		local entry = GG['MissionAPI'].Teams[role]
		if not entry or not entry.primary then
			Spring.Log('api_missions.lua', LOG.ERROR, "[Mission API] Setup.bases references unresolved role: " .. tostring(role))
		else
			for _, u in ipairs(units) do
				local y = u.y or Spring.GetGroundHeight(u.x, u.z)
				local unitID = Spring.CreateUnit(u.def, u.x, y, u.z, u.facing or "south", entry.primary)
				if not unitID then
					Spring.Log('api_missions.lua', LOG.ERROR, "[Mission API] Setup.bases failed to create '" .. tostring(u.def) .. "' for role " .. role)
				end
			end
		end
	end
end

-- Debug/testing helper: reveal the whole map for the human side. Driven by the
-- mission_debug_los modoption (the scenario designer's "Inf LOS" checkbox). Has
-- no gameplay effect beyond visibility; AI sides are left untouched.
local function applyDebugLos()
	if not Spring.GetModOptions().mission_debug_los then return end
	local humans = GG['MissionAPI'].Teams.humans
	if humans and humans.allyTeamID ~= nil then
		Spring.SetGlobalLos(humans.allyTeamID, true)
		Spring.Log('api_missions.lua', LOG.NOTICE, "[Mission API] Debug infinite LOS enabled for human allyTeam " .. tostring(humans.allyTeamID))
	end
end

-------------------------------------------------------------------------------

function gadget:Initialize()
	scriptPath = Spring.GetModOptions().mission_path

	if scriptPath == nil or scriptPath == "" then
		gadgetHandler:RemoveGadget()
		return
	end

	GG['MissionAPI'] = {}
	GG['MissionAPI'].Difficulty = Spring.GetModOptions().mission_difficulty or "normal"

	local triggersSchema = VFS.Include('luarules/mission_api/triggers_schema.lua')
	local actionsSchema = VFS.Include('luarules/mission_api/actions_schema.lua')
	GG['MissionAPI'].TriggerTypes = triggersSchema.Types
	GG['MissionAPI'].ActionTypes = actionsSchema.Types

	GG['MissionAPI'].TrackedUnits = { byName = {}, byId = {} }
	GG['MissionAPI'].FrozenTeams = {}
	GG['MissionAPI'].Barriers = {}

	triggersController = VFS.Include('luarules/mission_api/triggers_loader.lua')
	actionsController = VFS.Include('luarules/mission_api/actions_loader.lua')

	loadMission()
	applyInitialFreeze()
	applyStartPositions()
	applyDebugLos()
end

function gadget:GameFrame(n)
	if not setupDone and n >= 1 then
		repositionStartUnits()
		spawnBases()
		setupDone = true
	end
end

function gadget:Shutdown()
	GG['MissionAPI'] = nil
end
