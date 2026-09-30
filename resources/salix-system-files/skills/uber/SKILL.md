---
name: uber
description: "Uber rides and Uber Eats: fare and ETA estimates, request a ride on m.uber.com, and order food delivery on ubereats.com."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

The Uber Rides API `request` scope is restricted, and Uber Eats has no ordering
API. Use the web sites in the Comma in-app browser, where the user is signed
in. Use the cloud browser only if the in-app browser is not available; Uber
often challenges new logins there.

## Rides: m.uber.com

1. Open `https://m.uber.com`. Enter pickup and destination, and check that
   the map pins match.
2. Read each product (UberX, Comfort, XL...), price, and pickup ETA. Take a
   screenshot.
3. The user picks the product and payment method.
4. After confirmation, press Request. Report driver, car, plate, and ETA from
   the page.
Scheduled rides use the Schedule option on the same page.

An estimate-only Uber MCP exists at `mcp.uber.com`, but its path is built for
another client. Use it only if `mcp.list` already shows an Uber binding.

## Uber Eats: ubereats.com

Set the delivery address, search the store, choose items and options, and open
checkout. Read subtotal, fees, tip, total, and ETA.

## Safety

Request and Place order charge the saved payment method. Show the product or
items, route or address, and price and wait for confirmation. Cancelling after
a driver match can cost a fee. The user completes login codes and passkeys.
