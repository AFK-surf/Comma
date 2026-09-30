---
name: grubhub
description: "Grubhub food delivery and pickup (US): search restaurants, read menus, build an order, check out, and track delivery."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Grubhub has no public consumer API or official MCP. Use the web site.

## Cloud browser

1. Open `https://www.grubhub.com` with `browser.*`.
2. Set the delivery address or pickup first. Availability depends on it.
3. Search the restaurant or dish, open the menu, choose items and required
   options, and add them to the bag.
4. At login, call `browser.request_control`. The user enters email, password,
   and any email code.
5. Open checkout and read the subtotal, fees, tip, Grubhub+ perks, total, and
   delivery estimate.

If the site shows a bot challenge, switch to the Comma in-app browser.

## Safety

Place Order charges the saved card. Show the full order and total and wait for
confirmation. The user enters CVC or 3-D Secure. After ordering, report the
order number and tracking status from the page.
