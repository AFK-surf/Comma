---
name: amap
description: "高德地图 AMap (China maps): place search, geocoding, nearby POIs, driving, transit, walking, and cycling routes, weather, and navigation or taxi links."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Official MCP

Bind `https://mcp.amap.com/mcp?key={api_key}` (streamable HTTP; SSE at
`/sse`). The key is a Web服务 key from console.amap.com/dev/key. Stdio
alternative: `npx -y @amap/amap-maps-mcp-server` with `AMAP_MAPS_API_KEY`.

Tools include `maps_text_search`, `maps_around_search`, `maps_search_detail`,
`maps_geo`, `maps_regeocode`, `maps_direction_driving`,
`maps_direction_transit_integrated` (needs city), `maps_direction_walking`,
`maps_bicycling`, `maps_distance`, `maps_weather`, and `maps_ip_location`.
The hosted server can also return navigation and taxi app links. Check
`mcp.list` for their exact names.

Coordinates are GCJ-02 in `lon,lat` order. Convert before mixing with Baidu
(BD-09) data.

## Links (no key)

- Navigation: `https://uri.amap.com/navigation?from=<lon>,<lat>,<name>&to=<lon>,<lat>,<name>&mode=car&src=comma&callnative=1`
  (`mode`: car, bus, walk, ride).
- Marker: `https://uri.amap.com/marker?position=<lon>,<lat>&name=<name>`.
Links open the AMap app on a phone.

## Taxi

AMap cannot place a taxi order through the API. Its taxi link opens 高德打车 in
the app, where the user orders. Use `didi` to order through an API.
