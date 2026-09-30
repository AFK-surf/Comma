---
name: spotify
description: "Spotify: search tracks, albums, and playlists, control playback, see what is playing, save to library, and edit playlists."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Composio

Use the Composio `spotify` toolkit when a connection exists or the user can
connect one: `SPOTIFY_SEARCH`, `SPOTIFY_GET_CURRENTLY_PLAYING_TRACK`,
`SPOTIFY_START_PLAYBACK`, `SPOTIFY_ADD_ITEMS_TO_PLAYLIST`.
- Playback control needs Spotify Premium and an active device. If no device
  is active, ask the user to open Spotify on a phone or computer first.
- Spotify limits apps in Development Mode (few allowlisted users, 10 search
  results). If the connection fails for these reasons, use the fallbacks.

## Fallbacks

- Spotify desktop app on the user's Mac, with `env.exec`:
  `osascript -e 'tell application "Spotify" to play track "spotify:track:<id>"'`,
  `playpause`, `next track`,
  `get {name, artist} of current track`. The first call shows a macOS
  Automation prompt.
- Web player `https://open.spotify.com` in the Comma in-app browser with the
  user's login, for search and playlist edits.

Deleting a playlist cannot be undone. Confirm it first. Subscription changes
are done by the user.
