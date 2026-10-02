---
name: x-twitter
description: "X (Twitter): read a tweet or thread, read replies, download X videos, and post tweets or replies."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Read one tweet (keyless)

`web.http_request` GET
`https://cdn.syndication.twimg.com/tweet-result?id=<tweet id>&token=a` returns
the tweet JSON: text, author, media, and counts. Take the ID from the status
URL. `https://publish.x.com/oembed?url=<tweet url>` also works. These do not
return replies, search, or timelines.

## Video

Run `yt-dlp -o "%(id)s.%(ext)s" <tweet url>` with `env.exec` on the user's
device. Add `--cookies-from-browser chrome` for protected or sensitive media.

## Replies, threads, search, and posting

Use the Comma in-app browser on `https://x.com` with the user's login. X often
challenges datacenter logins, so log in with the in-app browser. Read the
conversation from the page text and scroll for more replies.

The X API is pay-per-use only (about $0.005 per post read and $0.015 per post
created; more for posts with links). Use the official MCP
`https://api.x.com/mcp` only if the user has their own X developer app and
credits, and bind it with those credentials.

Posts, replies, DMs, likes, and deletes are public or permanent. Show the exact
text and confirm before you send.
