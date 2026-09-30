---
name: meituan
description: "美团 Meituan official Skills: 跑腿 errands (pick up, deliver, buy for you, queue numbers), 酒旅 hotel, flight, train, and ticket search, and 领券 coupon claiming."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Meituan publishes these Skills as local CLI packages (Node 18 or later). Run
them with `env.exec` on the user's Mac. Read each package's own SKILL.md
before the first use.

## 跑腿 Paotui errands

Official repo: github.com/meituan/MT-Paotui-For-Client.
- Login: its `pt-passport` CLI prints an auth link. The user scans it or opens
  it in the Meituan app within 10 minutes, then the CLI polls for the token.
- Flow: address book, then quote (fee, ETA, `orderToken`), then the user's
  explicit 确认, then submit, then the pay link, then order status.
- The user pays in the H5 cashier within 15 minutes. Fees over ¥100 need a
  second confirmation.

## 酒旅 hotels and travel

ClawHub package `@meituan-travel-ai/meituan-travel` uses the same Meituan
Passport login. Queries take 1 to 2 minutes and return hotel, flight, train,
and ticket options with detail links. It does not book. The user books by
opening the link in the Meituan app or H5.

## 领券 coupons

`Meituan-Union/meituan-union-coupon-skill` uses SMS login and claims coupons
for takeout, dining, and hotels, at most once a day. If it asks for manual
verification, tell the user.

For takeout ordering, use `meituan-waimai`.

## Safety

Errand orders are real spending. Show pickup, drop-off, item, fee, and time
and wait for confirmation. Payment is always done by the user.
