---
name: expedia
description: "Expedia travel: search and book hotels, flights, packages, cars, and activities, and manage trips."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Expedia's Rapid API and B2B agent MCP need a partner contract. The open-source
`expedia-travel-recommendations-mcp` gives recommendations only and needs an
Expedia API key; use it only if a binding already exists.

## Comma in-app browser (preferred)

Expedia rate-limits datacenter clients, so use the Comma in-app browser on
`https://www.expedia.com`. If it is not available, try the cloud browser and
call `browser.request_control` for any challenge.
1. Choose Stays, Flights, Packages, Cars, or Things to do. Enter places,
   dates, and travelers.
2. Filter and compare total price, refundability, and (for flights) fare
   class, bags, and change rules.
3. The user signs in with an email code or password.
4. Enter traveler details. Flight names must match the passport or ID.

## Safety

Before Complete booking, show the itinerary, travelers, rate or fare rules,
refundability, and total, and wait for confirmation. The user enters card and
3-D Secure. Report the itinerary number from the confirmation page.
