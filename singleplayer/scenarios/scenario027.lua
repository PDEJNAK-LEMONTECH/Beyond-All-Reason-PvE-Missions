-- FTL Collage -- example scenario on a map built by tools/map_extender (region-collage
-- recomposition of "Faster Than Light"). Appears in Single Player -> Scenarios.
-- __BARVERSION__ is filled by the menu with the running game (works on the dev .sdd).
local scenariodata = {
	index			= 27, -- MUST equal the filename number
	scenarioid		= "ftl_collage_demo",
	version			= "1",
	title			= "FTL Collage (map_extender)",
	author			= "map_extender",
	imagepath		= "scenario027.jpg",
	imageflavor		= "An archipelago remixed from a single map...",
	summary			= [[Demonstrates tools/map_extender: a new playable map composed by re-compositing an existing one (a continent plus rotated/mirrored island copies), with a small scripted Mission API scenario on top.]],
	briefing		= [[The map "FTL Collage" was generated from "Faster Than Light" by tools/map_extender:
the western CONTINENT is the original map; the NE and SE ISLES are rotated / mirrored
copies of sub-regions of it, set in a low plain.

What the script does:
    1. You start on the western continent.
    2. After 30s the dormant BARb garrison on the NE isle wakes (gets resources + defenders).
    3. Reach the enemy isle with your commander for a prompt.
    4. Destroy the enemy Commander to win.

Edit singleplayer/missions/ftl_collage_demo.lua and use /luarules reload to iterate.]],

	mapfilename		= "FTL Collage 0.1", -- built + deployed by tools/map_extender
	playerstartx	= "20%",
	playerstarty	= "27%",
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
		scenarioid = "ftl_collage_demo",
	},

	startscript		= [[[Game]
{
    [allyTeam0] { startrectleft = 0;    startrectright = 0.45; startrecttop = 0; startrectbottom = 1; numallies = 0; }
    [allyTeam1] { startrectleft = 0.6;  startrectright = 1;    startrecttop = 0; startrectbottom = 0.5; numallies = 0; }

    [team0] { Side = __PLAYERSIDE__; Handicap = __PLAYERHANDICAP__; RgbColor = 0 0.50999999 0.77999997; AllyTeam = 0; TeamLeader = 0; }
    [team1] { Side = Armada; Handicap = __ENEMYHANDICAP__; RgbColor = 0.89999998 0.1 0.28999999; AllyTeam = 1; TeamLeader = 0; }

    [ai0] { Host = 0; IsFromDemo = 0; Name = BARbarianAI(1); ShortName = BARb; Team = 1; Version = stable; }

    [modoptions]
    {
        scenariooptions = __SCENARIOOPTIONS__;
        mission_path = missions/ftl_collage_demo.lua;
        mission_difficulty = normal;
    }

    [player0] { IsFromDemo = 0; Name = __PLAYERNAME__; Team = 0; rank = 0; }

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

    [RESTRICT] { __RESTRICTEDUNITS__ }
}
	]],
}

return scenariodata
