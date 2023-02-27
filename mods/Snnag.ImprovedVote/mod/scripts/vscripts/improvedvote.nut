global function SIV_Init

table<string, string> map_names
table<string, string> mode_names

int skip_cooldown_iteration
array<entity> players_skip_voting
array<entity> players_showing_skip

bool are_all_same_map
bool are_all_same_mode

bool has_started_vote
float vote_end_time
table<entity, int> player_votes
array<string> vote_options

void function SIV_Init()
{
    if ( GetConVarBool("SIV_ENABLE_SKIP") )
    {
        FSCC_CommandStruct command
        command.m_UsageUser = "skip"
        command.m_UsageAdmin = "skip"
        command.m_Description = "Vote to skip to the end of the current match."
        command.m_Group = "VOTE"
        command.m_Abbreviations = []
        command.Callback = SIV_CommandCallback_Skip
        FSCC_RegisterCommand("skip", command)
    }
    if ( GetConVarBool("SIV_ENABLE_GAME_VOTE") )
    {
        FSCC_CommandStruct command
        command.m_UsageUser = "vote <number>"
        command.m_UsageAdmin = "vote <number>"
        command.m_Description = "Vote for the next match."
        command.m_Group = "VOTE"
        command.m_Abbreviations = ["v"]
        command.Callback = SIV_CommandCallback_Vote
        FSCC_RegisterCommand("vote", command)
    }

    if ( GetMapName() == "mp_lobby" ) return

    InitMapModeNames()

    are_all_same_map = true
    are_all_same_mode = true

    if ( SIV_PLAYLIST.len() > 0 )
    {
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
void function SIV_CommandCallback_Skip( entity player, array< string > args )
{
    if ( GetMapName() == "mp_lobby" )
    {
        FSU_PrivateChatMessage(player, "%ECan't skip in lobby.")
        return
    }

    if ( GetGameState() > eGameState.Playing )
    {
        FSU_PrivateChatMessage(player, "%ECan't skip right now.")
        return
    }

    if ( players_skip_voting.find(player) != -1 )
    {
        FSU_PrivateChatMessage(player, "%EYou have already voted!")
        return
    }

    players_skip_voting.append(player)

    int player_count = GetPlayerArray().len()
    int required_players = int(player_count * GetConVarFloat("SIV_MAPCHANGE_FRACTION"))
    if ( required_players < 2 ) required_players = 2
    if ( required_players > player_count ) required_players = player_count

    string vote_description = "[" + players_skip_voting.len() + "/" + required_players + "]"

    foreach ( entity player in GetPlayerArray() )
    {
        if ( players_showing_skip.find(player) == -1 )
        {
            NSCreateStatusMessageOnPlayer(player, vote_description, "skip votes (!skip)", "siv_skip_votes")
            players_showing_skip.append(player)
        }
        else
        {
            NSEditStatusMessageOnPlayer(player, vote_description, "skip votes (!skip)", "siv_skip_votes")
        }
    }

    if ( players_skip_voting.len() >= required_players )
    {
        foreach ( entity player in GetPlayerArray() )
        {
            NSSendAnnouncementMessageToPlayer(player, "MATCH ENDING", "Match ending due to skip votes.", <1,0,0>, 0, 1)
        }

        thread SkipMap_Threaded()
    }
    else if ( players_skip_voting.len() == 1 )
    {
        // Show an information box if this is the first player to skip.
        // Ensures players aren't overwhelmed with information boxes.
        foreach ( entity player in GetPlayerArray() )
        {
            if ( player != players_showing_skip[0] )
            {
                NSSendInfoMessageToPlayer(player, "Tip: you can vote to skip this match by entering '!skip' into chat.")
            }
        }
    }

    if ( players_skip_voting.len() < required_players )
    {
        FSU_PrivateChatMessage(player, "%SYour vote has been counted!")
    }

    thread SkipCooldownIteration_Threaded()
}

// !vote
void function SIV_CommandCallback_Vote( entity player, array< string > args )
{
    if (!has_started_vote)
    {
        FSU_PrivateChatMessage(player, "%EVoting has not started yet.")
        return
    }
    if (args.len() == 0)
    {
        FSU_PrivateChatMessage(player, "%ENo argument! %TWhich selection do you want to vote for?")
        return
    }
    
    int vote_index = args[0].tointeger() - 1
    if ( vote_index < 0 || vote_index >= vote_options.len() )
    {
        FSU_PrivateChatMessage(player, "%EInvalid argument.")
        return
    }

    player_votes[player] <- vote_index
    FSU_PrivateChatMessage(player, "%SYour vote for %H" + vote_options[vote_index] + "%S has been counted!")

    UpdateVoteDisplay()
}

array<int> function CountVotes()
{
    array<int> votes_counted
    foreach ( option in vote_options )
        votes_counted.append(0)
    
    foreach ( player, index in player_votes )
        votes_counted[index]++

    return votes_counted
}

void function UpdateVoteDisplay()
{
    array<int> counts = CountVotes()

    string poll_text = "Vote for the next match in chat with !vote:"
    foreach ( index, option in vote_options )
    {
        poll_text += "\n" + (index + 1) + ". " + option

        if ( counts[index] == 1 )
            poll_text += " (1 vote)"
        else if ( counts[index] > 1 )
            poll_text += " (" + counts[index] + " votes)"
    }

    float duration = GetConVarFloat("SIV_POSTMATCH_LENGTH")

    foreach ( entity player in GetPlayerArray() )
    {
        SendHudMessage(player, poll_text, 0.3, 0.1, 240, 180, 40, 230, 0, duration, 0.2)
    }
}

void function ClientDisconnected(entity player)
{
    // If the player skip voted, remove them from the list.
    int skip_voting_index = players_skip_voting.find(player)
    if ( skip_voting_index != -1 )
        players_skip_voting.remove(skip_voting_index)
    
    int showing_skip_index = players_showing_skip.find(player)
    if ( showing_skip_index != -1 )
        players_showing_skip.remove(showing_skip_index)

    // If all players have now left, skip to the next match.
    if ( GetPlayerArray().len() <= 1 )
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

void function SkipCooldownIteration_Threaded()
{
    float cooldown_length = GetConVarFloat("SIV_SKIP_VOTE_LENGTH")

    skip_cooldown_iteration++
    int iteration = skip_cooldown_iteration

    wait cooldown_length

    // Do not clear the skip if this is not the latest cooldown thread.
    if ( skip_cooldown_iteration != iteration )
        return

    foreach ( entity player in players_showing_skip )
    {
        NSDeleteStatusMessageOnPlayer(player, "siv_skip_votes")
    }
    players_skip_voting = []
    players_showing_skip = []
}

void function SkipMap_Threaded()
{
    wait 2.0

    // Based on _gamestate_mp.nut
    foreach ( entity player in GetPlayerArray() )
    {
        player.FreezeControlsOnServer()
        ScreenFadeToBlackForever(player, 2.0)
    }

    wait 2.0
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
    if ( can_vote )
    {
        selection = CreateVoteSelection(GetConVarInt("SIV_MAX_OPTIONS"))

        // No entries: will continue the current map and mode
        // One entry: no need to vote
        if ( selection.len() > 1 )
        {
            float duration = GetConVarFloat("SIV_POSTMATCH_LENGTH")
            vote_options = FormatEntries(selection)

            has_started_vote = true
            vote_end_time = Time() + duration

            UpdateVoteDisplay()

            wait duration
            
            array<int> votes_counted = CountVotes()
            
            int max_votes
            foreach ( index, count in votes_counted )
            {
                if ( count > max_votes )
                {
                    vote_index = index
                    max_votes = count
                }
            }
        }
        else {
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
    //      2. Remove the entry from the valid entry list
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
    mode_names["fw"] <- "Frontier War"
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
