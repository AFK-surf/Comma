---
name: x-twitter
description: "X (Twitter): read a tweet or thread, read replies, download X videos, and post tweets or replies."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## X plugin

Use `mcp.list` with `kind: "tools"` and `binding_alias: "x"` for X API tools.
Inspect and call the required tool. Keep queries and result counts bounded.
Comma App accepts App-only Bearer Tokens only. BFT/Salix reuse Group OAuth and refresh its token.
Alias `x` takes priority, then the only X account. For multiple accounts, ask the user to name one `x`.
BFT/Salix use App-only tokens only without OAuth.
Follow shared MCP setup with the built-in X definition, alias `x`, and placement `server`.
Store App-only tokens as `config_values.X_BEARER_TOKEN`. Never copy OAuth tokens there.
X charges the app that issued the credential. No device is required.
Report credential or credit errors. Never fall back to App-only tokens after an OAuth error.
App-only tokens permit public reads. OAuth permits reads and writes within granted scopes.
Use discovered tools. For missing scopes, reconnect OAuth. Never retry writes with App-only tokens.

## Read one tweet (keyless)

Use `web.http_request` GET
`https://cdn.syndication.twimg.com/tweet-result?id=<tweet id>&token=a`
for text, author, media, and counts. Take the ID from the status URL.
`https://publish.x.com/oembed?url=<tweet url>` also works.
Neither returns replies, search, or timelines.

## Video

Run `yt-dlp -o "%(id)s.%(ext)s" <tweet url>` with `env.exec` on the user's
device. Add `--cookies-from-browser chrome` for protected or sensitive media.

## Replies, threads, search, and posting

For browser access, use the Comma in-app browser at `https://x.com` with the user's login.
X often challenges datacenter logins. Read page text and scroll for replies.
Use the browser when no MCP tool supports the action. Reuse OAuth before requesting credentials.
Posts, replies, DMs, likes, and deletes are public or permanent.
Show the exact text and confirm before you send.
