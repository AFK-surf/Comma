---
name: qq-music
description: "QQ音乐 QQ Music: search songs, play music, view My Music and playlists, and add songs to playlists on y.qq.com."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

QQ Music has no public API or MCP. Use the web player in the Comma in-app
browser. QQ Music blocks many songs for IPs outside mainland China, and audio
in the cloud browser does not reach the user, so do not use `browser.*`.

## Flow

1. Open `https://y.qq.com` with `comma call in-app-browser open-tab`.
2. If "我的音乐" or a play action needs login, ask the user to click 登录 and
   scan the QR code with QQ or WeChat.
3. Search with `https://y.qq.com/n/ryqq/search?w=<url-encoded query>`, read
   the result list, open the song page, then play, favorite, or use
   添加到歌单 (add to playlist).
4. Confirm the chosen song and artist with the user when the results are
   ambiguous.

If a song is greyed out, it is region-locked or needs VIP. Tell the user; do not
try other sites.

VIP (绿钻) purchases, album purchases, and top-ups are done by the user.
