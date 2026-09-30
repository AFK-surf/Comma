---
name: fliggy
description: "飞猪 Fliggy travel: search flights, trains, hotels, and attractions through Fliggy's official FlyAI, and book on Fliggy."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Search: official FlyAI

Fliggy's FlyAI open platform (flyai.open.fliggy.com) is query-only. Results
include bookable items with links.
- CLI on the user's Mac: `npm i -g @fly-ai/flyai-cli`. The user creates an API
  key in the FlyAI console and configures it following `flyai --help`.
- Commands: `flyai search-flight`, `search-train`, `search-hotel`,
  `search-poi`, `keyword-search`, `ai-search`. Check `--help` for flags.
- The CLI is a client of the remote MCP `https://flyai.open.fliggy.com/mcp`.
  Prefer the CLI: the MCP may reject calls without the CLI's signed headers.

## Booking: Comma in-app browser

Open the result link or `https://m.fliggy.com` in the Comma in-app browser.
The user logs in with the Taobao account (QR or SMS).
1. Check times, price, and refund and change rules.
2. Choose real-name passengers or guests from the account.
3. Decline add-ons unless the user asks for them.
4. After confirmation, submit. The user pays with Alipay.
5. Report the order number.

## Safety

Before submitting, show the itinerary, passengers, rules, add-ons, and total,
and wait for confirmation. Refunds and changes can cost fees.
