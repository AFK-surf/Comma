---
name: paypal
description: "PayPal: manage a PayPal business account (invoices, orders, refunds, disputes, subscriptions, transactions), or help the user pay with PayPal at a web checkout."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Business account: official MCP

Bind the remote MCP `https://mcp.paypal.com/http` (streamable HTTP; SSE at
`/sse`) and connect with `mcp_manager.authorize` (PayPal login and consent).
Sandbox: `https://mcp.sandbox.paypal.com/http`. Fallback: the Composio `paypal`
toolkit.

Tools cover invoices (create, send, remind, cancel, QR), orders (create, get,
pay), refunds, disputes, shipment tracking, catalog, subscriptions, and
transaction lists.

PayPal documents no approval gate on these tools. Before pay order, create
refund, send invoice, create or cancel subscription, or accept a dispute claim,
show the amount, currency, payee, and effect, and wait for the user to confirm.

## Consumer paying with PayPal

There is no public API to pay on a consumer's behalf. At the merchant checkout,
choose PayPal in the cloud browser and call `browser.request_control` so the
user logs in and approves the payment. If PayPal flags the cloud browser, use
the Comma in-app browser.
