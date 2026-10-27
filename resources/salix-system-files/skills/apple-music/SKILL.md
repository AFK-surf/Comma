---
name: apple-music
description: "Apple Music and Music.app on the user's Mac: play, pause, skip, current track, library songs and playlists, and adding catalog songs through music.apple.com."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Apple Music has no official MCP, and its API needs a MusicKit developer token
and a user token that Salix cannot get. Control Music.app on the user's Mac.

## Music.app

The user turns on Music in Comma > Plugins > Mac apps on their Mac. Comma then serves
`mcp.mac.music_*`: now playing, play, pause, next and previous track, volume,
shuffle, library search, and playing a song or playlist from the library. A
missing tool means Music is off; tell the user to turn it on there. Do not run
`osascript` instead.

`permission_required` means macOS has not allowed Comma to control Music; the
user allows it in Comma > Plugins > Mac apps. `device_offline` means the Mac is asleep
or Comma is closed.

## Catalog songs

The library search sees only the local library. To find a song that is not in
the library, open `https://music.apple.com/search?term=<q>` in the Comma in-app
browser, use "Add to Library" after the user is signed in, then play it with
`music_search_library` and `music_play_track`.

Subscriptions and purchases are done by the user.
