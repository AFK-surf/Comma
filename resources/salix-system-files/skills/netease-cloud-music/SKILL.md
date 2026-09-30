---
name: netease-cloud-music
description: "网易云音乐 NetEase Cloud Music: search songs, play and control music, daily recommendations, playlists, and cloud disk through the official ncm-cli."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

NetEase provides the official agent CLI `@music163/ncm-cli` and skills at
github.com/NetEase/skills. There is no MCP server. Run it with `env.exec` on
the user's Mac.

## Setup

1. `npm i -g @music163/ncm-cli`. Playback also needs `mpv`
   (`brew install mpv`).
2. Developer credentials: the user applies for an appId and privateKey at
   developer.music.163.com. Enter them with `ncm-cli configure`, or the user
   does it in their own terminal.
3. User login: `ncm-cli login --background` prints a QR link. The user scans it
   with the NetEase app. Check with `ncm-cli login --check`.

## Use

- Run `ncm-cli commands` and `ncm-cli <cmd> --help`. Do not guess flags.
- Examples: `ncm-cli search song --keyword "<q>"`, `play`, `pause`, `resume`,
  `next`, `state`, daily recommendations, and `playlist create`.
- Non-playback commands need `--userInput "<summary of the user's request>"`.
- Skip songs with `visible:false`. If the output says 请求总量超限, stop and tell
  the user the quota is used up.
- Song links use `https://music.163.com/#/song?id=<id>`.

Fallback: `https://music.163.com` in the Comma in-app browser with QR login.
Many songs are region-locked, so do not use the cloud browser.

Publishing notes or podcasts and cloud uploads are public or persistent.
Confirm them first.
