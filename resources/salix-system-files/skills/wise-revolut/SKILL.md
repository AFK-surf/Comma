---
name: wise-revolut
description: "Wise and Revolut accounts: balances, exchange rates, quotes, recipients, and transfer status; help the user send money or pay through the Wise or Revolut web or mobile app."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Neither service has an official MCP server or an agent spend-approval product.

## Wise

- Reads: the Composio `wise` toolkit (profiles, balances, currencies, exchange
  rate, quotes, recipients, transfers, activities).
- The Wise API (`https://api.wise.com`) uses a personal token from
  wise.com/settings/api-tokens. Salix can use it only through an MCP binding
  secret. Do not bind the community `2060-io/mcp-wise` server with a
  full-access token: its `send_money` tool quotes, creates, and funds a
  transfer in one call.
- EU and UK profiles cannot fund transfers with a personal token (strong
  customer authentication). Send money in the Comma in-app browser on wise.com.
  The user does login, 2FA, and the final confirmation.

## Revolut

- Personal accounts have no public API. Tell the user the steps in the Revolut
  app, or read the web app in the Comma in-app browser after the user logs in
  and approves in the mobile app.
- The Revolut Business API needs a certificate and signed requests. Use it only
  if the user already runs a Business API MCP binding.

Show the amount, currency, fee, rate, and recipient before any transfer, and
report the transfer ID or status that the service shows.
