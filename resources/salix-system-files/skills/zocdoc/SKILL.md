---
name: zocdoc
description: "Zocdoc (US): find doctors by specialty, location, and insurance, check open appointment times, and book, reschedule, or cancel visits."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Zocdoc has a developer API and an MCP server, but both are for approved
partners. No public MCP URL exists, so do not invent one. Use one only if
`mcp.list` already shows a Zocdoc binding.

## Comma in-app browser

zocdoc.com blocks datacenter browsers, so use the Comma in-app browser.
1. Search `https://www.zocdoc.com` by specialty or visit reason, ZIP code, and
   insurance plan.
2. Compare providers: in-network status, rating, distance, video or in-person,
   and the next open times. Take a screenshot.
3. Pick a time with the user. Enter the visit reason and new or existing
   patient status.
4. The user signs in and enters patient and insurance details themselves.
5. Some bookings need confirmation by phone or email. Tell the user.

## Safety

This is health information. Use only what the user gives, and do not choose an
insurance plan for them. Before Book, confirm provider, location, date, time,
visit type, and the cancellation or no-show policy. Report the confirmation
from the page. For urgent symptoms, tell the user to contact emergency
services instead of booking.
