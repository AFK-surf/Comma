---
name: meituan-waimai
description: "美团外卖 Meituan food delivery: search restaurants and drinks, choose items and options, apply coupons, place and track takeout orders."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Meituan has no consumer takeout API. Use the H5 site in the Comma in-app
browser. It uses the user's own login and China network. The cloud browser runs
outside China and triggers Meituan's slider and SMS checks.

## Flow on `https://h5.waimai.meituan.com`

1. Check the delivery address first. The H5 site needs the right city and
   location; choose or add the address in the address list.
2. Search the shop or item. Compare rating, delivery time, delivery fee, and
   minimum order.
3. In the shop, choose items and 规格 (size, sugar, ice), and add to cart.
4. 去结算 opens checkout: address, delivery time, tableware, remarks, and
   red packets or coupons. Pick the best valid coupon.
5. Read the final total after discounts.
6. After the user confirms, press 提交订单. The Meituan cashier opens.
7. The user enters the 美团支付 password or pays with WeChat or Alipay.
8. Report the order status and ETA from 订单.

If the page asks to log in, the user enters the SMS code or scans with the
Meituan app.

For a simple "buy and bring" errand, `meituan` (跑腿 Skill) is an API
alternative.

## Safety

Before 提交订单, show shop, items and options, address, time, coupons, and
total, and wait for confirmation. Merchants can refuse cancellation after they
accept the order.
