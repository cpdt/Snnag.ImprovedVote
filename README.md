# Snnag's Improved Vote

Improved map/mode voting for [Fifty's Server Utilities](https://northstar.thunderstore.io/package/Fifty/Server_Utilities/).

Use [my ServerUtils fork](https://github.com/cpdt/Snnag.ServerUtils) to fix the map vote poll overlapping other UI elements in the postmatch screen.

## Features

 - Set infinite map/mode combos. Players will be able to vote between a random selection of options.
 - Supports any number of maps and modes: voting will automatically disable if there are no options.
 - Voting runs during the postmatch screen instead of at a certain time remaining, meaning less interruptions.
 - Players always have a chance to vote, even if the match ends early.
 - A new `!skip` command goes to the postmatch screen, allowing players to see scores and vote for the next match.
 - Voting can be turned off to automatically pick a random map/mode combo at the end of each game. No more repeating playlists!

## Setting up

Copy `mod/scripts/vscripts/config.example.nut` to `mod/scripts/vscripts/config.nut`. This is where any config options that don't
fit into a ConVar will go.

 - `SIV_PLAYLIST` is the list of available maps/mode combos. Make sure that `PLAYLIST_LEN` is equal to the number of items in the playlist!
 - `SIV_CUSTOM_MAP_NAMES` is a table of map name overrides to customize how the poll is displayed.
 - `SIV_CUSTOM_MODE_NAMES` is a table of mode name overrides to customize how the poll is displayed.

## ConVars

 - `SIV_ENABLE_SKIP` enables or disables `!skip`. Default: `"1"` (enabled)
 - `SIV_ENABLE_GAME_VOTE` enables or disables voting. When disabled, a random map/mode combo will be picked. Default: `"1"` (enabled)
 - `SIV_MAX_OPTIONS` sets the max number of combos presented to players. Should be no more than 7. Default: `"5"`

## License

Provided under the MIT license. Check the LICENSE file for details.
