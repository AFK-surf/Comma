---
name: stripe
description: "Stripe: pay for a purchase with a one-time card from the user's Link wallet (US/CA), or manage the user's own Stripe merchant account (payments, invoices, refunds, balances)."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Consumer purchase: Link Agent Wallet (US and Canada only)

Run `npx @stripe/link-cli` with `env.exec` on the user's device.
1. `link-cli auth login`. The user opens the URL and logs in to Link.
2. `link-cli user-info retrieve` shows spend limits. Do not assume limits.
3. `link-cli spend-request create --amount <cents> --merchant-name <n> --merchant-url <u> --context "<at least 100 characters: item, seller, reason>"`.
   Give the user the `approval_url`. They have 10 minutes to approve in Link.
4. `link-cli spend-request retrieve <id> --interval 2 --max-attempts 300` until approved.
5. `link-cli spend-request retrieve <id> --include card --output-file <path>`.
   The file keeps the card number out of chat and logs.
6. Enter the card at checkout in the browser. The card is valid for 12 hours.
   For 3-D Secure, send the user to the returned `action_url`.
A higher price needs `update --amount` and a new approval. Use `--test` for a dry run.

## User's Stripe merchant account

Bind the official remote MCP `https://mcp.stripe.com` (streamable HTTP) with
OAuth through `mcp_manager.authorize`, or a Stripe Agent API key as a binding
secret. From 2026-10-31 full secret keys and non-Agent restricted keys fail.
Tools: `stripe_api_search`, `stripe_api_details`, `stripe_api_read`,
`stripe_api_write`, `get_balance_summary`, `search_stripe_documentation`.
Refunds and outbound payments return an approval URL. Give it to the user, then
retry after they approve. Fallback: the Composio `stripe` toolkit.

Confirm every write that moves money (charge, refund, payout, invoice send)
with amount, currency, and payee. Prefer sandbox mode for tests.
