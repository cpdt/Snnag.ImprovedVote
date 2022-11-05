global function Snnags_Improved_Vote_Init

table<string, string> map_names
table<string, string> mode_names

array<entity> players_skip_voting

bool are_all_same_map
bool are_all_same_mode

bool has_started_vote

void function Snnags_Improved_Vote_Init()
{
    if ( GetConVarBool("SIV_ENABLE_SKIP") )
        FSU_RegisterCommand("skip", "\x1b[113m" + FSU_GetString("FSU_PREFIX") + "skip\x1b[0m If enough players vote the current map will be skipped", "", SIV_Skip_Command)

    if ( GetMapName() == "mp_lobby" ) return

    InitMapModeNames()

    are_all_same_map = true
    are_all_same_mode = true

    if ( SIV_PLAYLIST.len() > 0 ) {
        string[2] first_entry = SIV_PLAYLIST[0]

        foreach ( entry in SIV_PLAYLIST )
        {
            if ( entry[0] != first_entry[0] )
                are_all_same_map = false
            if ( entry[1] != first_entry[1] )
                are_all_same_mode = false
        }
    }

    AddCallback_GameStateEnter( eGameState.Postmatch, Postmatch_Threaded )
    AddCallback_OnClientDisconnected( ClientDisconnected )
}

// !skip
void function SIV_Skip_Command( entity player, array< string > args )
{
    if ( GetMapName() == "mp_lobby" )
    {
        Chat_ServerPrivateMessage(player, "Can't skip in lobby", false)
        return
    }

    if ( GetGameState() > eGameState.Playing )
    {
        Chat_ServerPrivateMessage(player, "Can't skip in this game state", false)
        return
    }

    if ( players_skip_voting.find(player) != -1 )
    {
        Chat_ServerPrivateMessage(player, "You have already voted!", false)
        return
    }

    players_skip_voting.append(player)

    int required_players = int(GetPlayerArray().len() * FSU_GetFloat("FSU_MAPCHANGE_FRACTION"))
    if ( required_players == 0 ) required_players = 1

    Chat_ServerBroadcast("\x1b[113m[" + players_skip_voting.len() + "/" + required_players + "]\x1b[0m players want to skip this map (!skip)")
    
    if ( players_skip_voting.len() >= required_players )
    {
        thread SkipMap_Threaded()
    }
    else
    {
        Chat_ServerBroadcast("\x1b[113m[" + players_skip_voting.len() + "/" + required_players + "]\x1b[0m players want to skip this map (!skip)")
    }
}

void function ClientDisconnected(entity player)
{
    // If all players have now left, skip to the next match.
    if ( GetPlayerArray().len() == 0 )
    {
        array< string[2] > selection = CreateVoteSelection(1)
        
        if ( selection.len() == 0 )
        {
            // No available selections, repeat the current map and mode
            StartMatch( GetMapName(), GAMETYPE )
        }
        else
        {
            StartMatch( selection[0][0], selection[0][1] )
        }
    }
}

void function SkipMap_Threaded()
{
    // Based on _gamestate_mp.nut
    foreach ( entity player in GetPlayerArray() )
    {
        player.FreezeControlsOnServer()
        ScreenFadeToBlackForever(player, 4.0)
    }

    wait 4.0
    CleanUpEntitiesForRoundEnd()

    foreach( entity player in GetPlayerArray() )
			player.UnfreezeControlsOnServer()
    
    SetGameState(eGameState.Postmatch)
}

void function Postmatch_Threaded()
{
    bool vote_enabled = GetConVarBool("SIV_ENABLE_GAME_VOTE")
    if ( !vote_enabled && GetConVarBool("ns_should_return_to_lobby") )
    {
        return
    }

    array< string[2] > selection
    int vote_index

    bool can_vote = vote_enabled && !(are_all_same_map && are_all_same_mode)
    if ( can_vote && FSU_CanCreatePoll() )
    {
        selection = CreateVoteSelection(GetConVarInt("SIV_MAX_OPTIONS"))

        // No entries: will continue the current map and mode
        // One entry: no need to vote
        if ( selection.len() > 1 )
        {
            float duration = GetConVarFloat("SIV_POSTMATCH_LENGTH")
            FSU_CreatePoll( FormatEntries(selection), "Next match vote", duration, false )
            Chat_ServerBroadcast("Use \x1b[113m\"!vote <number>\"\x1b[0m to vote for the next match.")

            wait duration

            vote_index = FSU_GetPollResultIndex()
            if ( vote_index == -1 ) vote_index = 0
        }
        else
        {
            wait GAME_POSTMATCH_LENGTH
        }
    }
    else
    {
        selection = CreateVoteSelection(1)
        wait GAME_POSTMATCH_LENGTH
    }

    if ( selection.len() == 0 )
    {
        // No available selections, repeat the current map and mode
        StartMatch( GetMapName(), GAMETYPE )
        return
    }

    // Make sure vote index is in range (just in case!)
    if ( vote_index >= selection.len() ) vote_index = 0

    // Lets go
    StartMatch( selection[vote_index][0], selection[vote_index][1] )
}

// Copied from _private_lobby.gnut
void function StartMatch(string map, string mode)
{
    try
    {
        SetCurrentPlaylist( mode )
    }
    catch ( exception )
    {
        if ( mode == "speedball" )
            SetCurrentPlaylist( "lf" )

        print( "Couldn't find playlist for gamemode " + mode )
    }

    RefreshPlayerTeams( mode )

    if ( !( mode in GAMETYPE_TEXT ) )
        mode = GetPlaylistGamemodeByIndex( mode, 0 )
    
    GameRules_ChangeMap( map, mode )
}

array< string[2] > function CreateVoteSelection(int max)
{
    // Goals:
    //  - None of the options should have the current map/mode
    //  - None of the options should be repeated
    //  - Should have as many modes as possible
    //  - Should have as many maps as possible
    // To achieve this an iterative method is used. We keep a list of all
    // entries that haven't been used yet (and are not the current entry), and
    // then repeatedly do these steps until the list is empty or we have the
    // required number of entries:
    //   1. Copy the valid entry list to a temp list.
    //   2. Repeatedly, until the temp list is empty or the vote list == max:
    //      1. Pick a random entry from the temp list and add to the vote list
    //      2. Remove the netry from the valid entry list
    //      3. Remove all entries in the temp list with a matching map
    //         (can skip if are_all_same_map is true)
    //      4. Remove all entries in the temp list with a matching mode
    //         (can skip if are_all_same_mode is true)

    // Build a list of entries excluding the current one
    array< string[2] > valid_entries
    foreach ( entry in SIV_PLAYLIST )
    {
        if ( entry[0] != GetMapName() || entry[1] != GameRules_GetGameMode() )
        {
            valid_entries.append(entry)
        }
    }

    array< string[2] > vote_list

    while ( vote_list.len() < max && valid_entries.len() > 0 )
    {
        array< string[2] > temp_list = valid_entries.slice(0)

        while ( vote_list.len() < max && temp_list.len() > 0 )
        {
            // Pick a random entry
            string[2] entry = temp_list[RandomInt(temp_list.len())]

            // Insert the entry after another entry with the same mode, so the list is somewhat sorted
            int insert_index = vote_list.len() - 1
            for ( ; insert_index >= 0; insert_index-- )
            {
                if (vote_list[insert_index][1] == entry[1]) {
                    break;
                }
            }

            vote_list.insert(insert_index + 1, entry)

            // Remove the entry from the valid list
            int entry_index
            foreach ( valid_entry in valid_entries )
            {
                if ( valid_entry == entry )
                    break
                
                entry_index++
            }
            valid_entries.remove(entry_index)

            // Remove all entries in the temp list with a matching map or mode
            int tempIndex
            for (int i = 0; i < temp_list.len(); )
            {
                if (temp_list[i][0] == entry[0] || temp_list[i][1] == entry[1])
                {
                    temp_list.remove(i)
                } else {
                    i++
                }
            }
        }
    }

    return vote_list
}

array< string > function FormatEntries(array< string[2] > entries)
{
    array< string > formatted_array
    bool is_first = true

    foreach ( entry in entries )
    {
        string suffix = ""
        if ( is_first )
        {
            suffix = " (next)"
            is_first = false
        }

        if ( are_all_same_map )
            formatted_array.append(LocalizeMode(entry[1]) + suffix)
        else if ( are_all_same_mode )
            formatted_array.append(LocalizeMap(entry[0]) + suffix)
        else
            formatted_array.append(LocalizeMode(entry[1]) + " - " + LocalizeMap(entry[0]) + suffix)
    }

    return formatted_array
}

void function InitMapModeNames()
{
    map_names["mp_angel_city"] <- "Angel City"
    map_names["mp_black_water_canal"] <- "Black Water Canal"
    map_names["mp_box"] <- "Box"
    map_names["mp_coliseum"] <- "Coliseum"
    map_names["mp_coliseum_column"] <- "Pillars"
    map_names["mp_colony02"] <- "Colony"
    map_names["mp_complex3"] <- "Complex"
    map_names["mp_crashsite3"] <- "Crash Site"
    map_names["mp_drydock"] <- "Drydock"
    map_names["mp_eden"] <- "Eden"
    map_names["mp_forwardbase_kodai"] <- "Forwardbase Kodai"
    map_names["mp_glitch"] <- "Glitch"
    map_names["mp_grave"] <- "Boomtown"
    map_names["mp_homestead"] <- "Homestead"
    map_names["mp_lf_deck"] <- "Deck"
    map_names["mp_lf_meadow"] <- "Meadow"
    map_names["mp_lf_stacks"] <- "Stacks"
    map_names["mp_lf_township"] <- "Township"
    map_names["mp_lf_traffic"] <- "Traffic"
    map_names["mp_lf_uma"] <- "UMA"
    map_names["mp_lobby"] <- "Lobby"
    map_names["mp_relic02"] <- "Relic"
    map_names["mp_rise"] <- "Rise"
    map_names["mp_thaw"] <- "Exoplanet"
    map_names["mp_wargames"] <- "War Games"

    mode_names["private_match"] <- "Private Match"
    mode_names["aitdm"] <- "Attrition"
    mode_names["at"] <- "Bounty Hunt"
    mode_names["coliseum"] <- "Coliseum"
    mode_names["cp"] <- "Amped Hardpoint"
    mode_names["ctf"] <- "Capture the Flag"
    mode_names["fd"] <- "Frontier Defense"
    mode_names["fd_easy"] <- "Frontier Defense (Easy)"
    mode_names["fd_hard"] <- "Frontier Defense (Hard)"
    mode_names["fd_insane"] <- "Frontier Defense (Insane)"
    mode_names["fd_master"] <- "Frontier Defense (Master)"
    mode_names["fd_normal"] <- "Frontier Defense (Regular)"
    mode_names["lts"] <- "Last Titan Standing"
    mode_names["mfd"] <- "Marked for Death"
    mode_names["ps"] <- "Pilots vs. Pilots"
    mode_names["solo"] <- "Campaign"
    mode_names["tdm"] <- "Skirmish"
    mode_names["ttdm"] <- "Titan Brawl"
    mode_names["speedball"] <- "Live Fire"
    mode_names["alts"] <- "Aegis Last Titan Standing"
    mode_names["attdm"] <- "Aegis Titan Brawl"
    mode_names["ffa"] <- "Free For All"
    mode_names["fra"] <- "Free Agents"
    mode_names["holopilot_lf"] <- "The Great Bamboozle"
    mode_names["rocket_lf"] <- "Rocket Arena"
    mode_names["turbo_lts"] <- "Turbo Last Titan Standing"
    mode_names["turbo_ttdm"] <- "Turbo Titan Brawl"
    mode_names["chamber"] <- "One in the Chamber"
    mode_names["ctf_comp"] <- "Competitive CTF"
    mode_names["fastball"] <- "Fastball"
    mode_names["gg"] <- "Gun Game"
    mode_names["hidden"] <- "The Hidden"
    mode_names["hs"] <- "Hide and Seek"
    mode_names["inf"] <- "Infection"
    mode_names["kr"] <- "Amped Killrace"
    mode_names["sbox"] <- "Sandbox"
    mode_names["sns"] <- "Sticks and Stones"
    mode_names["tffa"] <- "Titan FFA"
    mode_names["tt"] <- "Titan Tag"
    mode_names["sp_coop"] <- "Campaign Coop"
}

string function LocalizeMap(string map)
{
    if ( map in SIV_CUSTOM_MAP_NAMES )
        return SIV_CUSTOM_MAP_NAMES[map]
    if ( map in map_names )
        return map_names[map]
    return map
}

string function LocalizeMode(string mode)
{
    if ( mode in SIV_CUSTOM_MODE_NAMES )
        return SIV_CUSTOM_MODE_NAMES[mode]
    if ( mode in mode_names )
        return mode_names[mode]
    return mode
}

// Copied from _gamestate_mp.nut
void function CleanUpEntitiesForRoundEnd()
{
	// this function should clean up any and all entities that need to be removed between rounds, ideally at a point where it isn't noticable to players
	SetPlayerDeathsHidden( true ) // hide death sounds and such so people won't notice they're dying
	
	foreach ( entity player in GetPlayerArray() )
	{
		ClearTitanAvailable( player )
		
		if ( IsAlive( player ) )
			player.Die( svGlobal.worldspawn, svGlobal.worldspawn, { damageSourceId = eDamageSourceId.round_end } )
		
		if ( IsAlive( player.GetPetTitan() ) )
			player.GetPetTitan().Destroy()
	}
	
	foreach ( entity npc in GetNPCArray() )
		if ( IsValid( npc ) )
			npc.Destroy() // need this because getnpcarray includes the pettitans we just killed at this point
	
	// destroy weapons
	ClearDroppedWeapons()
		
	foreach ( entity battery in GetEntArrayByClass_Expensive( "item_titan_battery" ) )
		battery.Destroy()
	
	// allow other scripts to clean stuff up too
	svGlobal.levelEnt.Signal( "CleanUpEntitiesForRoundEnd" ) 

	SetPlayerDeathsHidden( false )
}

// Copied from _private_lobby.gnut
void function RefreshPlayerTeams(string mode)
{
	int maxTeams = GetGamemodeVarOrUseValue( mode, "max_teams", "2" ).tointeger()
	int maxPlayers = GetGamemodeVarOrUseValue( mode, "max_players", "12" ).tointeger()

	// special case for situations where we wrongly assume ffa teams because there's 2 teams/2 players
	if ( maxPlayers == maxTeams && maxTeams > 2 )
	{
		array<entity> players = GetPlayerArray()
		for ( int i = 0; i < players.len(); i++ )
			SetTeam( players[ i ], i + 7 ) // 7 is the lowest ffa team
	}
	else
	{
		bool lastSetMilitia = false
		foreach ( entity player in GetPlayerArray() )
		{
			if ( player.GetTeam() == TEAM_MILITIA || player.GetTeam() == TEAM_IMC )
				continue
				
			if ( lastSetMilitia ) // ensure roughly evenish distribution
				SetTeam( player, TEAM_IMC )
			else
				SetTeam( player, TEAM_MILITIA )
				
			lastSetMilitia = !lastSetMilitia
		}
	}
}
