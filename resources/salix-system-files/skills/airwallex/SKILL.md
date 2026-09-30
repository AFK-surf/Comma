---
name: airwallex
description: "Airwallex business account: balances, FX rates and conversions, beneficiaries, transfers, cards, invoices, and subscriptions through the official Airwallex AgentOS MCP."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Airwallex serves business accounts only. It has no consumer wallet.

## Official MCP (AgentOS)

- Production: `https://mcp.airwallex.com/mcp` (HTTP), OAuth through
  `mcp_manager.authorize`. Grant only the scopes the task needs.
- Sandbox tools and docs: `https://mcp-demo.airwallex.com/developer` (OAuth).
  Docs only: `https://mcp-demo.airwallex.com/docs` (no auth).
- Fallback for reads: the Composio `airwallex` toolkit (account, balances,
  conversion currencies, beneficiaries, conversions, global accounts,
  transfers).

## Safety

AgentOS does not complete money-out actions itself. Transfers, FX conversions,
and payouts wait for a human confirmation in Airwallex. Tell the user where to
confirm; never claim the money moved until Airwallex shows it as confirmed.
Card issuing and beneficiary creation are sensitive writes. Confirm the card
holder, limits, or bank details with the user before the call.
