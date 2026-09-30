---
name: restaurant-reservations
description: "Restaurant table reservations outside China and Japan: find availability and book, change, or cancel on OpenTable, Resy, Tock, SevenRooms, Yelp, or Reserve with Google."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

First find which system the restaurant uses: the Reserve link on its site or
Google Maps listing. Public booking APIs for these systems are partner-only.

## Resy: `restaurant-cli`

`npm i -g restaurant-cli` on the user's Mac (github.com/omarshahine/restaurant-cli),
run with `env.exec`. The user runs `restaurant setup resy` in their own terminal.
Use `--json --no-color --no-input` without `--yes`:
`search "<name>"`, `availability --venue <id> --date YYYY-MM-DD --party N`,
`book ... --dry-run`, then `book` after confirmation, `list --upcoming`,
`cancel <id>`. Exit code 6 means login is needed, 7 means rate-limited. The
CLI can also search OpenTable and Tock availability, but it does not book them.

## Browser systems

- OpenTable and Tock block datacenter browsers. Use the Comma in-app browser
  on opentable.com or exploretock.com. The user signs in (OpenTable uses a
  phone or email code).
- SevenRooms: cloud browser on the venue widget
  `https://www.sevenrooms.com/reservations/<venue>`. Guests need name, email,
  and phone; no account.
- Yelp reservations and waitlists: Comma in-app browser on yelp.com.
- Reserve with Google: Comma in-app browser on Google Maps with the user's
  Google login, or follow its Reserve link to the partner site.

## Safety

Before booking, confirm restaurant, date, time, party size, name and phone,
and any card hold, deposit, prepaid ticket (common on Tock), or no-show fee.
Do not snipe or hold multiple tables. Report the confirmation from the site.
