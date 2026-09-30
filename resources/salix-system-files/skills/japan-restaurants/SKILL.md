---
name: japan-restaurants
description: "Japan restaurant search and reservations on Tabelog (食べログ) and TableCheck: ratings, availability, courses, and booking."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Neither service has a public consumer API. Use the web sites with the cloud
browser, or the Comma in-app browser if a challenge appears.

## Tabelog

- For visitors, use `https://tabelog.com/en/` (English, Chinese, and Korean
  booking for about 35,000 venues). The Japanese site often expects a Japanese
  phone number.
- Search by area, genre, and date. Tabelog scores are strict: 3.5 or more is
  very good.
- Login uses email and an emailed code. The user registers a card.
- Booking costs JPY 440 per person when confirmed, usually not refunded.
  Online changes are limited to date, time, and party size.

## TableCheck

- Search at `https://www.tablecheck.com/en/` or open the venue page
  `https://www.tablecheck.com/en/shops/<shop>/reserve` from the restaurant site.
- Guests book with name, email, and phone. An account is optional.
- Some venues require a card guarantee or prepayment for a course.

## Safety

Before booking, confirm date, time, party size, course and price, seating,
booking fees, and the cancellation policy. Same-day cancellation fees in Japan
are often 50 to 100%. The user enters card details and 3-D Secure.
