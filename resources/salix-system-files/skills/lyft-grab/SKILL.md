---
name: lyft-grab
description: "Lyft (US/Canada) and Grab (Southeast Asia) rides: explain options and give the user an app link to book, because neither offers web or API booking."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Neither service lets Salix book a ride.
- Lyft: the public API is closed to new apps, and ride.lyft.com redirects to a
  marketing page. The Concierge API is for business contracts.
- Grab: the Farefeed fare API and other APIs are partner-only. The web site
  links to the app.

## What to do

1. Resolve the pickup and destination with a maps skill (`google-maps` outside
   China) and give the distance and a typical drive time.
2. Give the user an app link to finish the booking on their phone:
   - Lyft: `lyft://ridetype?id=lyft&pickup[latitude]=<lat>&pickup[longitude]=<lng>&destination[latitude]=<lat>&destination[longitude]=<lng>`
   - Grab: tell the user to open the Grab app and enter the destination.
3. Tell the user that you cannot see the live price. The app shows it.
4. If Uber serves the same city and the user agrees, you can book through the
   `uber` path instead.

Do not use community scrapers to book rides on these services.
