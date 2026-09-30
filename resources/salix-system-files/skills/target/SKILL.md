---
name: target
description: "Target (US): search products, check store availability, choose shipping, pickup, Drive Up, or same-day delivery, and place orders."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Target has no public API. Its `redsky.target.com` endpoints are internal; do not
depend on them.

## Cloud browser

1. Open `https://www.target.com` with `browser.*`.
2. Set the store or ZIP code first. Availability and price depend on it.
3. Search, open the product, and choose the fulfillment mode: Shipping, Order
   Pickup, Drive Up, or Same Day Delivery.
4. Add to cart and open the cart.
5. At sign-in, call `browser.request_control`. The user enters password and
   any SMS or email code.

Use the Comma in-app browser if login is challenged or the user needs saved
payment and Target Circle offers from their own session.

## Safety

Before Place your order, show items, fulfillment mode, store or address, time,
Circle offers, and total, and wait for confirmation. The user enters CVV for a
new card. Ask before any RedCard or Circle 360 sign-up.
