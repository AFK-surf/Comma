---
name: baidu-maps
description: "百度地图 Baidu Maps (China): place search and details, geocoding, routes, real-time road traffic, weather, coordinate conversion, and Baidu Map app links."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Official MCP

Bind `https://mcp.map.baidu.com/mcp?ak={api_key}` (streamable HTTP; SSE at
`/sse`). The AK is a 服务端 (server) key from lbsyun.baidu.com with the MCP
service turned on. Stdio alternative: `@baidumap/mcp-server-baidu-map` with the
AK in its environment.

Tools: `map_geocode`, `map_reverse_geocode`, `map_search_places`,
`map_search_pro` (natural-language search), `map_place_details`,
`map_directions` (driving, riding, walking, transit),
`map_directions_matrix`, `map_road_traffic` (live congestion), `map_weather`,
`map_ip_location`, `map_district_search`, `map_geoconv`, `map_uri` (Baidu Map
app link), and `map_mark` (shareable trip map).

Baidu uses BD-09 coordinates. Convert with `map_geoconv` before you mix them
with AMap or DiDi (GCJ-02) or GPS (WGS-84) data.

The MCP is read-only. It has no ride-hailing and no real-time bus arrivals. Use
`didi` for rides and `chelaile` for bus arrivals.
