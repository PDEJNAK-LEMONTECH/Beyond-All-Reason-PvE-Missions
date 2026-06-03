-- Scripted PvE Demo -- showcases the Mission API (see MISSION_API.md + singleplayer/missions/pve_demo.lua)
-- Appears in Single Player -> Scenarios. __BARVERSION__ is filled in by the menu with the running
-- game, so this works on the dev .sdd automatically. The mission_path modoption below activates the
-- Mission API scenario script.
local scenariodata = {
	index			= 25, -- MUST equal the filename number
	scenarioid		= "pvedemo_missionapi",
	version			= "1",
	title			= "Scripted PvE Demo",
	author			= "local mod",
	imagepath		= "scenario025.jpg",
	imageflavor		= "A dormant enemy waits behind a wall...",
	summary			= [[Demonstrates the scripted-PvE Mission API: a dormant BARb AI behind a wall that you breach, with scripted events as you tech up and grow your army.]],
	briefing		= [[A single Barbarian AI sits dormant on the right, behind a barrier across the centre of the map.

What the script does:
    1. At start: a Dragon's Teeth wall is raised across the centre.
    2. Move your COMMANDER up to the wall: it is breached.
    3. Reach Tech 2: the enemy is fed metal and gains defenders.
    4. Grow your army past ~8000 metal value: the AI WAKES UP and attacks.
    5. Destroy the enemy Commander to win.

This is a sandbox to verify the Mission API - edit singleplayer/missions/pve_demo.lua and use
/luarules reload to iterate.]],

	mapfilename		= "Red Comet Remake 1.8", -- installed on this machine
	playerstartx	= "15%",
	playerstarty	= "50%",
	partime			= 3000,
	parresources	= 1000000,
	difficulty		= 4,
	defaultdifficulty = "Normal",
	difficulties	= {
		{name = "Beginner", playerhandicap = 50, enemyhandicap = 0},
		{name = "Normal",   playerhandicap = 0,  enemyhandicap = 0},
		{name = "Hard",     playerhandicap = 0,  enemyhandicap = 25},
	},
	allowedsides	= {"Armada", "Cortex", "Random"},
	victorycondition = "Destroy the enemy Commander",
	losscondition	= "Death of your Commander",
	unitlimits		= {},

	scenariooptions = {
		scenarioid = "pvedemo_missionapi",
	},

	startscript		= [[[Game]
{
    [allyTeam0]
    {
        startrectleft = 0;
        startrectright = 0.25;
        startrecttop = 0;
        startrectbottom = 1;
        numallies = 0;
    }

    [allyTeam1]
    {
        startrectleft = 0.75;
        startrectright = 1;
        startrecttop = 0;
        startrectbottom = 1;
        numallies = 0;
    }

    [team0]
    {
        Side = __PLAYERSIDE__;
        Handicap = __PLAYERHANDICAP__;
        RgbColor = 0 0.50999999 0.77999997;
        AllyTeam = 0;
        TeamLeader = 0;
    }

    [team1]
    {
        Side = Armada;
        Handicap = __ENEMYHANDICAP__;
        RgbColor = 0.89999998 0.1 0.28999999;
        AllyTeam = 1;
        TeamLeader = 0;
    }

    [ai0]
    {
        Host = 0;
        IsFromDemo = 0;
        Name = BARbarianAI(1);
        ShortName = BARb;
        Team = 1;
        Version = stable;
    }

    [modoptions]
    {
        scenariooptions = __SCENARIOOPTIONS__;
        mission_path = missions/pve_demo.lua;
        mission_difficulty = normal;
    }

    [player0]
    {
        IsFromDemo = 0;
        Name = __PLAYERNAME__;
        Team = 0;
        rank = 0;
    }

    hostip = 127.0.0.1;
    hostport = 0;
    numplayers = 1;
    startpostype = 2;
    mapname = __MAPNAME__;
    ishost = 1;
    numusers = 2;
    gametype = __BARVERSION__;
    GameStartDelay = 3;
    myplayername = __PLAYERNAME__;
    nohelperais = 0;

    NumRestrictions = __NUMRESTRICTIONS__;

    [RESTRICT]
    {
        __RESTRICTEDUNITS__
    }
}
	]],
}

return scenariodata
