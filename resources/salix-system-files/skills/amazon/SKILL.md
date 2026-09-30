---
name: amazon
description: "Amazon shopping: search and compare products, check prices, sellers, reviews, and delivery dates, add to cart, place orders, and track or return orders."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Amazon has no consumer ordering API. The Creators API (replaced PA-API) returns
catalog data for approved Associates only. SP-API and the Ads MCP are for
sellers and advertisers.

## Comma in-app browser (preferred)

Amazon challenges datacenter browsers and AI agents, so use the Comma in-app
browser with the user's own login.
1. Open `https://www.amazon.com` (or the user's country site, for example
   amazon.co.jp) and search with `/s?k=<query>`.
2. Compare price, seller ("Ships from" and "Sold by"), Prime, rating count,
   delivery date, and return policy. Take a screenshot for comparisons.
3. Choose options on the product page and use Add to Cart. Do not click Buy
   Now: it can skip the review page.
4. Proceed to checkout. Sign in with the credentials that the user gives you,
   or the user signs in. The user completes OTP or passkey steps.

The cloud browser can do anonymous product search if the in-app browser is not
available.

## Safety

Before Place your order, show the item, seller, quantity, address, delivery
date, payment method, and total, and wait for confirmation. Check that the
seller is not a lookalike. Do not start Subscribe & Save without asking. Report
the order number from the confirmation page.
