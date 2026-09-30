---
name: taobao-shangou
description: "淘宝闪购 (formerly 饿了么 Ele.me) food and grocery delivery: search shops, build an order, check out, and track delivery."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

The 淘宝闪购 MCP servers are for merchants only. There is no consumer API. Use
the H5 site in the Comma in-app browser. Alibaba shows slider captchas to the
cloud browser, which runs outside China.

## Flow on `https://h5.ele.me`

1. Login: the user enters the SMS code (the account links to Taobao and
   Alipay), or scans a Taobao QR code.
2. Set or choose the delivery address.
3. Search the shop or item. Compare rating, delivery time, fees, and minimum
   order.
4. Choose items and 规格, and add them to the cart.
5. 去结算: check address, time, remarks, and red packets. Read the final total.
6. After the user confirms, submit the order.
7. The cashier uses Alipay. The user enters the payment password, scans the
   QR code, or uses face check.
8. Report the order status and ETA.

## Safety

Before submitting, show shop, items, address, time, discounts, and total, and
wait for confirmation.
