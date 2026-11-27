---
name: live-activity
description: >-
  Show and update real-time Dynamic Island and Lock Screen Live Activities on
  the user's iPhone via `live_activity.upsert` and `live_activity.end` for
  ride-hailing, food/coffee delivery, flights, trains, parcels, pickup queues,
  timers, and long-running tasks.
prompt_summary: "Start, update, or end an iOS Live Activity (Dynamic Island / Lock Screen) for real-time progress such as flights, deliveries, parcels, or queues."
---

# Live Activity (`live_status_v1`)

Use `live_activity.upsert`, `live_activity.end`, and `live_activity.list` to
surface ongoing real-world or long-running progress on the user's iPhone
Dynamic Island and Lock Screen.

## Categories

Pick the closest category:
- `car` — ride-hailing (DiDi, Uber, Lyft, Grab)
- `delivery` — food or grocery delivery (Meituan, DoorDash, Uber Eats)
- `flight` — flight boarding, gate, delay, and arrival tracking
- `train` — rail departure, platform, and arrival tracking (12306)
- `transit` — bus, metro, or ferry arrival
- `package` — parcel delivery tracking (Kuaidi100, carrier tracking)
- `order` — coffee/drink or restaurant pickup queue (Luckin, Starbucks)
- `timer` — countdown timers and reminders
- `progress` — long-running builds, downloads, renders, or tasks

## Core Rules

1. **Stable key**: Choose a deterministic `key` (e.g. `ride:didi-8821`,
   `delivery:meituan-42`, `flight:CA1501`) and reuse it across updates.
2. **Native countdown**: Pass `eta_at` (RFC3339 UTC timestamp) whenever an
   arrival, departure, or completion time is known so iOS renders a live
   countdown without extra pushes.
3. **Structured fields**: Keep `title` short (<= 80 chars) and scannable; put
   secondary facts in `subtitle`, `detail_left` / `detail_right` (e.g. plate
   number, gate, pickup code), and `progress` (0.0..1.0) or `step`
   (`{current, total, label}`). Use `compact_label` (<= 16 chars) when no ETA
   is set.
4. **Alerts only on major transitions**: Pass `alert: {title?, body}` only for
   moments that warrant lighting up the phone (driver arrived, boarding now,
   drink ready for pickup, delivery at door). Omit `alert` on routine ETA ticks.
5. **Always end**: Call `live_activity.end` with `outcome` (`done`,
   `cancelled`, or `failed`) and a clear final `title` when finished. At most 5
   active live activities are allowed per workspace.

## Pairing with Background Loops

When polling an external status API (ride status, delivery ETA, flight gate,
coffee pickup queue), create a Background Loop (`loop.create`) that calls
`live_activity.upsert` and `live_activity.end` directly via `host.call`. This
updates the Dynamic Island on every poll without waking the LLM. Only call
`agent.notify` from the Loop when a human decision or conversational follow-up
is needed.
