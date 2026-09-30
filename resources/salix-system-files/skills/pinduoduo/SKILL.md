---
name: pinduoduo
description: "拼多多 Pinduoduo shopping: search products, compare single-buy and group-buy prices, place orders, and check order status."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Pinduoduo has no consumer API, and it has strong anti-bot checks. Use the H5
site in the Comma in-app browser, not the cloud browser.

## Flow on `https://mobile.yangkeduo.com`

1. Login: the user enters the SMS code.
2. Search the product. Compare price, sales, shop rating, and reviews.
3. On the product page, compare 单独购买 (buy alone) with 拼单 (group price).
4. Choose the spec and quantity, and check the address.
5. After the user confirms, submit. The user pays (多多支付, WeChat, or Alipay).
6. Report the order status.

Some features only work in the app. If the page asks to open the app, tell
the user.

## Safety

Before paying, show item, spec, price type, address, and total, and wait for
confirmation. Do not share 助力 or 砍价 (friend-help) links for the user, and do
not start them without asking.
