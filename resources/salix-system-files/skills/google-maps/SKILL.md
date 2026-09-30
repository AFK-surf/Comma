---
name: google-maps
description: "Google Maps outside mainland China: search places, reviews, and opening hours, get routes and travel times, weather, and share map or directions links."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Official Grounding Lite MCP

Bind `https://mapstools.googleapis.com/mcp` (streamable HTTP) with header
`X-Goog-Api-Key: {api_key}` (a Google Cloud project with billing and the Maps
Grounding Lite API). Tools: `search_places` (summary and place IDs),
`compute_routes` (distance and duration, no turn-by-turn), `lookup_weather`.

## Composio

The Composio `google_maps` toolkit is the fallback:
`GOOGLE_MAPS_TEXT_SEARCH`, `GOOGLE_MAPS_NEARBY_SEARCH`,
`GOOGLE_MAPS_GET_PLACE_DETAILS`, `GOOGLE_MAPS_GET_ROUTE`,
`GOOGLE_MAPS_COMPUTE_ROUTE_MATRIX`, `GOOGLE_MAPS_GEOCODE_ADDRESS`.

## Links (no key)

- Directions: `https://www.google.com/maps/dir/?api=1&origin=<a>&destination=<b>&travelmode=driving`
  (`walking`, `transit`, `bicycling`).
- Search: `https://www.google.com/maps/search/?api=1&query=<q>`.

## Web

google.com/maps works in the cloud browser without login for search and
directions. Saved places and lists need the user's Google login, so use the
Comma in-app browser. For table booking, see `restaurant-reservations`.

Do not store Maps content for later reuse. Google's terms forbid caching it.
In mainland China, use `amap` or `baidu-maps` instead.
