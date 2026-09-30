---
name: doordash
description: "DoorDash food and grocery delivery (US/Canada): search restaurants and stores, build a cart, preview fees and ETA, place and track orders, and reorder."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Official CLI `dd-cli`

DoorDash publishes `dd-cli` (github.com/doordash-oss/doordash-cli). Access is by
waitlist. Run it with `env.exec` on the user's Mac.
- Login: the user runs `dd-cli login` in their own terminal. The token stays in
  the OS keychain. Treat an exported `DD_CLI_ACCESS_TOKEN` as a secret.
- Flow: `address list` (or `address find`/`add`), `search --query "<q>"`
  (`--dashpass-only`, `--price-tier`, `--max-eta-minutes`), `menu`,
  `cart add-items`, `order preview`, then `order submit`, `order status`.
  `order history` and reorder are also available.
- Payment uses saved cards only. Check `--help` for current flags.

## Web fallback

DoorDash challenges datacenter browsers, so use the Comma in-app browser on
`https://www.doordash.com` with the user's login. Set the delivery address
first, then search, add items with options, and open checkout.

## Safety

`order submit` and Place Order charge the card. First show subtotal, fees, tip,
total, address, and ETA from `order preview` or the checkout page, and wait for
the user to confirm. The Drive API is for merchants; do not use it. Community
DoorDash MCP servers are unofficial scrapers; prefer `dd-cli`.
