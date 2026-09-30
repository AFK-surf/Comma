---
name: douyin
description: "抖音 Douyin: download Douyin videos, read video details, and browse or search Douyin content."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Douyin has no public agent API, and it shows slider challenges to datacenter
browsers. Work on the user's Mac.

## Download

Run `yt-dlp` with `env.exec` on the user's device:
`yt-dlp --cookies-from-browser chrome -o "%(title)s.%(ext)s" "<douyin url>"`.
- Douyin needs fresh cookies, even without login. If yt-dlp reports
  "Fresh cookies are needed", ask the user to open douyin.com in Chrome once,
  then retry.
- Share links (`v.douyin.com/...`) work; yt-dlp follows the redirect.
- `yt-dlp -J <url>` returns metadata (title, author, counts) without a
  download.
Copy the file with `env.copy` when the user needs it in chat.

## Browse and search

Open `https://www.douyin.com` or `https://www.douyin.com/search/<q>` in the
Comma in-app browser. The user logs in with the Douyin app QR code if the
page asks.

Download only content the user has the right to save. Comments, likes, and
follows are public. Confirm them first. Shop purchases are done by the user.
