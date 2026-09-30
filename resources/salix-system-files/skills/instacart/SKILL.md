---
name: instacart
description: "Instacart grocery delivery: turn a recipe or shopping list into an Instacart link, find nearby retailers, and help the user check out."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Official Developer Platform MCP

Bind the remote MCP `https://mcp.instacart.com/mcp` (streamable HTTP) with the
header `Authorization: Bearer <key>` as a binding secret (an Instacart
Developer Platform API key; development keys work at once, production keys
need Instacart review). The Composio `instacart` toolkit offers the same
functions: `INSTACART_CREATE_SHOPPING_LIST_PAGE`,
`INSTACART_CREATE_RECIPE_PAGE`, `INSTACART_GET_NEARBY_RETAILERS`.

Tools `create-recipe` and `create-shopping-list` return an Instacart page URL.
They do not fill a cart or place an order. Give the URL to the user: they pick
the store and check out on Instacart.

The cart-building Instacart MCP (`fig-mcp.instacart.com`) is for approved
partners only. Salix cannot use it.

## Checkout in a browser

When the user wants you to place the order, open the link or
`https://www.instacart.com` in the cloud browser, or in the Comma in-app
browser for the user's own session. The user logs in (email or phone code).
Choose the store, check items and substitutions, and open checkout.

## Safety

Show the store, items, substitution choices, delivery window, fees, tip, and
total, and wait for confirmation before Place Order.
