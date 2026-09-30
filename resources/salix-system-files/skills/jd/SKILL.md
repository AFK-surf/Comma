---
name: jd
description: "京东 JD.com shopping: search products, compare JD self-operated and third-party prices, add to cart, place orders, and track delivery."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

JD has no consumer ordering API. JD Union returns product and affiliate data
only, and needs signed requests and permission approval, so do not use it for
shopping. JD search often requires login, and the cloud browser gets 安全验证
checks. Use the Comma in-app browser.

## Flow

1. Open `https://m.jd.com` (or `https://search.jd.com/Search?keyword=<q>`).
2. If login is needed, the user scans the QR code with the JD app or uses an
   SMS code.
3. Compare price, 京东自营 (JD self-operated) or third-party shop, PLUS price,
   coupons, delivery date, and reviews. Take screenshots for comparisons.
4. Open the product, choose the spec, then 加入购物车 or 立即购买.
5. 去结算: check the address, delivery, invoice, and final price.
6. After the user confirms, 提交订单.
7. The user pays in the JD cashier (京东支付 password or WeChat).
8. Report the order number and delivery estimate.

## Safety

Before 提交订单, show item, spec, seller, quantity, address, and total, and wait
for confirmation.
