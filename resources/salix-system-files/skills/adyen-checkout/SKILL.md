---
name: adyen-checkout
description: "Adyen and Checkout.com merchant accounts: payment links, payment details, refunds, voids, and account data through the official Adyen and Checkout.com MCP servers."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Both services serve merchants only. Use them only for the user's own merchant
account.

## Checkout.com

- Official remote MCP: `https://mcp.checkout.com` (HTTP). Sandbox:
  `https://checkout.mcp.sbox.cko.tech`. Connect with `mcp_manager.authorize`
  (Dashboard login). The Dashboard user's role limits the operations; prefer a
  minimal role.
- Tools include docs and API search, create and get payment link, get payment
  details, list entities, and voids.

## Adyen

- Official MCP `@adyen/mcp` is a local stdio package (alpha). Run
  `npx -y @adyen/mcp --env=TEST` as a server or device MCP binding with
  `ADYEN_API_KEY` as a binding secret. Live needs `--env=LIVE --livePrefix=...`.
- Use `--tools=` to expose only the tools the task needs.
- Tools cover checkout sessions, payment methods, payment links, cancel and
  refund, and Management API reads.

## Safety

Use test or sandbox environments first. Before a payment link, refund, cancel,
or void, show the amount, currency, merchant account, and payment reference, and
wait for the user to confirm.
