---
name: xiaohongshu
description: "小红书 Xiaohongshu (RED): search notes, read note details and comments, and post notes or comments."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Xiaohongshu has no official API. It requires login to browse and challenges
datacenter browsers, so work from the user's Mac.

## Community MCP (preferred for repeated use)

`xpzouying/xiaohongshu-mcp` runs on the user's Mac (binary or Docker) and serves
HTTP MCP at `http://localhost:18060/mcp`. Bind it as a device MCP binding.
Tools: `get_login_qrcode`, `search_feeds`, `get_feed_detail`,
`post_comment_to_feed`, `like_feed`, `publish_content`, `publish_with_video`.
- Login: call `get_login_qrcode` and ask the user to scan it with the
  Xiaohongshu app.
- Do not use the same account in another web session at the same time.

Agent Reach (github.com/Panniantong/Agent-Reach) can also read Xiaohongshu
through the user's Chrome session.

## In-app browser

Without the MCP, open `https://www.xiaohongshu.com/explore` in the Comma in-app
browser. The user logs in with QR or SMS. Search with
`https://www.xiaohongshu.com/search_result?keyword=<q>` and read note text from
the page.

Keep a low request rate. Posting, comments, likes, and follows are public.
Show the exact text and images and confirm before you publish. Shop purchases
are done by the user.
