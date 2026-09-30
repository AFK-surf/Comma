---
name: ctrip
description: "携程 Ctrip travel in China: search and compare flights, trains, hotels, and attraction tickets, and book them on Ctrip."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Search: Ctrip Wendao (携程问道)

Ctrip's official agent query API answers natural-language travel questions
with Markdown results. It is query-only: it does not book, pay, or read orders.
- The user gets a token at `https://www.ctrip.com/wendao/openclaw` and saves it
  on their Mac in `~/.config/ctrip-wendao/token` themselves.
- Run on the Mac with `env.exec`:
  `jq -n --rawfile t ~/.config/ctrip-wendao/token --arg q "<question>" '{token: ($t|rtrimstr("\n")), query: $q}' | curl -s -X POST https://wendao-skill-prod.ctrip.com/skill/query -H 'Content-Type: application/json' -d @-`
- `Invalid token.` means the token is missing or expired.

## Booking: Comma in-app browser

Use `https://m.ctrip.com` (or www.ctrip.com) in the Comma in-app browser.
1. The user logs in with an SMS code or the Ctrip app QR code.
2. Search, then compare price, times, and refund and change rules.
3. Choose real-name passengers or guests saved in the account.
4. Decline add-ons (insurance, coupon packs, VIP lounges) unless the user
   asks for them.
5. After confirmation, submit. The user pays.
6. Report the order number.

Trip.com is the international site; use it for users outside China.

## Safety

Before submitting, show the itinerary, passengers, fare or rate rules, add-ons,
and total, and wait for confirmation. Refunds and changes can cost fees.
