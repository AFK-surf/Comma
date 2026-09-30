---
name: apple-music
description: "Apple Music and Music.app on the user's Mac: play, pause, skip, current track, library playlists, and adding catalog songs through music.apple.com."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Apple Music has no official MCP, and its API needs a MusicKit developer token
and a user token that Salix cannot get. Control Music.app on the user's Mac.

## Music.app with `osascript`

Run with `env.exec` on the initiating Message's client device:
- `osascript -e 'tell application "Music" to play playlist "<name>"'`
- `osascript -e 'tell application "Music" to pause'` (also `play`,
  `next track`, `previous track`, `set sound volume to 50`).
- `osascript -e 'tell application "Music" to get {name, artist} of current track'`
- Search the local library:
  `tell application "Music" to play (first track of library playlist 1 whose name contains "<q>")`.

The first call shows a macOS Automation prompt. Ask the user to click Allow.
If it was denied, they turn it on in System Settings > Privacy & Security >
Automation.

A community MCP, `uvx applemusic-mcp serve` (github.com/epheterson/applemusic-mcp),
can run as a device MCP binding for richer library tools.

## Catalog songs

AppleScript sees only the local library. To find a song that is not in the
library, open `https://music.apple.com/search?term=<q>` in the Comma in-app
browser, use "Add to Library" after the user is signed in, then play it with
Music.app.

Subscriptions and purchases are done by the user.
