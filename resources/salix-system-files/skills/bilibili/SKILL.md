---
name: bilibili
description: "B站 Bilibili: search videos, read video details, subtitles, and comments, and download videos."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Bilibili has no public agent API. Its API returns HTTP 412 (risk control) to
datacenter IPs, so `web.http_request` and `browser.*` fail. Work on the user's
Mac with `env.exec`.

## Download and details

- `yt-dlp` supports bilibili.com:
  `yt-dlp -o "%(title)s.%(ext)s" https://www.bilibili.com/video/<BV id>`.
  Add `--cookies-from-browser chrome` for 1080p and member content.
- Metadata only: `yt-dlp -J <url>`. Subtitles:
  `yt-dlp --skip-download --write-subs --sub-langs all <url>`.
- Agent Reach (github.com/Panniantong/Agent-Reach) routes Bilibili search and
  details through `bili-cli`, with no login. After installing it, run
  `agent-reach doctor`.

## Web

For comments, favorites, or account pages, open `https://www.bilibili.com` in
the Comma in-app browser. The user logs in with the Bilibili app QR code.

Keep a low request rate to avoid account risk control. Posting comments,
likes, coins, and follows are public. Confirm them first. Download only content
the user has the right to save.
