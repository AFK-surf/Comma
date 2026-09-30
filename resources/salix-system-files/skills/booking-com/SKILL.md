---
name: booking-com
description: "Booking.com hotels and stays: search by destination and dates, compare rooms, rates, and cancellation terms, book, and manage bookings."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

The Booking.com Demand API and its MCP server are for approved affiliate
partners. The MCP cannot place orders. Salix uses the web site.

## Browser

Booking.com shows a JavaScript challenge to datacenter clients. Try the cloud
browser; if a challenge repeats, use the Comma in-app browser.
1. Search at `https://www.booking.com` with destination, check-in, check-out,
   rooms, and guests.
2. Filter by price, review score, free cancellation, and location. Compare
   total price including taxes and fees.
3. On the property, compare room and rate: refundable or not, pay now or pay at
   the property, breakfast, and cancellation deadline.
4. At sign-in (email code, passkey, or Google/Apple), call
   `browser.request_control`.
5. Enter guest details and open the final step.

## Safety

Before Complete booking, show property, dates, room, rate type, cancellation
policy, and total, and wait for confirmation. Non-refundable rates cannot be
undone. The user enters card and 3-D Secure. Report the confirmation number
and PIN from the page.
