---
name: chelaile
description: "车来了 real-time bus arrivals in Chinese cities: nearby stops, when the next bus arrives, bus positions and crowding, line details, and timetables."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Chelaile has no public API. Its H5 API responses are signed and encrypted, so
one `web.http_request` cannot read them.

## Community MCP

Bind the stdio package `npx -y chelaile-mcp-server`
(github.com/peanutsplash/chelaile-mcp). It needs no key or login.
Tools: `bus_list_cities`, `bus_search`, `bus_get_nearby_stops` (stops and ETAs
near a point), `bus_get_stop_detail`, `bus_get_line_detail`,
`bus_get_line_realtime` (next buses at a stop), `bus_list_line_buses`
(positions and crowding), `bus_get_timetable`, `bus_plan_transit`.
Coordinates are GCJ-02.

## Flow

1. Get the user's location with `location.request` if they say "near me", or
   geocode the stop with `amap`.
2. Find the city, then nearby stops or the line.
3. Report the next arrivals as minutes and stops away, with the direction
   (terminal station). Say that times are estimates.

This package is unofficial and can stop working when Chelaile changes its
keys. If it fails, open `https://web.chelaile.net.cn/ch5/index.html` in the
Comma in-app browser (it uses the user's location), or give line and stop
information from `amap`.
