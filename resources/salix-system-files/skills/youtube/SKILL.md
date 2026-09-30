---
name: youtube
description: "YouTube: search videos and channels, read metadata, playlists, and comments, get transcripts or subtitles, and download videos."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Data API

Use the Composio `youtube` toolkit (Google OAuth) for search, video and channel
details, playlists, comments, captions list, and uploads, for example
`YOUTUBE_SEARCH_YOU_TUBE` and `YOUTUBE_CREATE_PLAYLIST`. Search costs 100
units of the daily quota, so do not repeat searches without need.

Keyless metadata through `web.http_request`:
- `https://www.youtube.com/oembed?url=<video-url>&format=json` (title, author,
  thumbnail).
- `https://www.youtube.com/feeds/videos.xml?channel_id=<UC...>` (latest
  uploads, XML).

## Downloads and transcripts

Run `yt-dlp` with `env.exec` on the user's device. YouTube asks datacenter IPs
to sign in, so do not run it on Salix servers.
- Transcript: `yt-dlp --skip-download --write-auto-subs --sub-langs "zh.*,en.*" --sub-format vtt <url>`.
- Video: `yt-dlp -f "bv*+ba/b" -o "%(title)s.%(ext)s" <url>`. Add
  `--cookies-from-browser chrome` for age-restricted or members-only videos.
Install with `brew install yt-dlp` if it is missing. Copy results with
`env.copy` when the user needs the file in chat.

## Web

For account actions that the API does not cover, use the Comma in-app browser
on youtube.com with the user's login.

Uploading, deleting, commenting, and privacy changes are public or permanent.
Confirm them first. Download only content the user has the right to save.
