---
name: dianping
description: "大众点评 Dianping: find restaurants and local shops in China, compare ratings, prices per person, reviews, hours, and group-buy deals."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Dianping has no consumer API. Use the H5 site in the Comma in-app browser.
Dianping has strict anti-scraping (login walls after a few pages, verification
pages, and obfuscated fonts for numbers). The cloud browser can work for one
or two read-only lookups.

## Flow on `https://m.dianping.com`

1. Choose the city first. Search by keyword, area, or cuisine.
2. Sort or filter by distance, rating, and 人均 (price per person).
3. On shop pages, read the score, 人均, address, hours, recommended dishes, and
   deals. If numbers look wrong (obfuscated font), take a screenshot and read
   it from the image.
4. Give a short list with name, score, 人均, distance, and a link.

If the site asks to log in, the user enters the SMS code or scans with the
Dianping or Meituan app.

Keep the number of pages small to avoid verification walls.

## Safety

Group-buy deals, reservations, and hotel bookings redirect to Meituan payment.
Confirm the deal, quantity, validity, and price first; the user pays.
