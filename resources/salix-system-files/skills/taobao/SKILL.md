---
name: taobao
description: "淘宝 Taobao and Tmall shopping: search products, compare prices, shops, sales, and coupons, add to cart, place orders, and check order and logistics status."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Taobao has no consumer ordering API (Taobao Union APIs are affiliate-only).
The mobile app is blocked by risk control on emulators, and the cloud browser
triggers slider captchas. Work on the user's Mac.

## Taobao desktop client MCP (if available)

Taobao desktop client 2.5 or later has a local MCP. The user turns it on in
Settings > AI 设置 > 开启 MCP 服务. It listens on `http://[::1]:3654/mcp`
(IPv6 localhost only; 127.0.0.1 fails). Bind it as a device MCP binding, or
send JSON-RPC with `curl` through `env.exec`. It uses the client's login and
can search, read details, add to cart, and submit orders.

## Comma in-app browser

Otherwise use the user's web login:
1. Search at `https://s.taobao.com/search?q=<query>`.
2. Compare price after coupons, shop rating, sales, shipping, and whether the
   shop is Tmall or official. Take screenshots for comparisons.
3. Open the product, choose the SKU, and add to cart or 立即购买.
4. On the order page, check address and final price, then submit after
   confirmation.
5. The user pays with Alipay (password, face, or QR).

## Safety

Before submitting, show item, SKU, shop, quantity, address, and total, and
wait for confirmation. Never press 确认收货 (confirm receipt) for the user: it
releases the payment to the seller.
