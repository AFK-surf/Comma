---
name: airbnb
description: "Airbnb stays: search listings by place, dates, and guests, read listing details, house rules, and cancellation policy, and book."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Airbnb has no public guest API or official MCP.

## Search: community MCP

`@openbnb/mcp-server-airbnb` (github.com/openbnb-org/mcp-server-airbnb) is a
stdio MCP. Bind it with command `npx -y @openbnb/mcp-server-airbnb` on the
server. Tools: `airbnb_search` and `airbnb_listing_details`. They return public
data and listing links. Do not enable `--ignore-robots-txt`.

## Booking: browser

Use the cloud browser on `https://www.airbnb.com`, or the Comma in-app browser
for the user's own session.
1. Open the listing. Read the total with fees, house rules, and the
   cancellation policy.
2. Choose Reserve. The user logs in (phone code, email, Google/Apple, or
   passkey) through `browser.request_control`. First bookings can need
   identity verification by the user.
3. For Request to book, the host message is sent in the user's name. Show the
   text before sending.

## Safety

Before Confirm and pay, show listing, dates, guests, cancellation policy, and
total, and wait for confirmation. The user enters card and 3-D Secure.
