---
name: flight-status
description: "Flight status and schedules: real-time status, delays, gates, routes between cities, aircraft position, and airport weather for any flight number."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Official VariFlight (飞常准) MCP

Bind `https://ai.variflight.com/servers/aviation/mcp/` (streamable HTTP). It
publishes OAuth metadata, so try `mcp_manager.authorize` first. Otherwise use
header `X-API-Key: {api_key}` with a key from ai.variflight.com/keys. Stdio
alternative: `npx -y @variflight-ai/variflight-mcp` with `VARIFLIGHT_API_KEY`.

Tools:
- `searchFlightsByNumber(fnum, date)`: status, times, gate, terminal.
- `searchFlightsByDepArr`: flights between two airports or cities.
- `getFlightTransferInfo`: connection options.
- `getRealtimeLocationByAnum`: aircraft position by registration.
- `getFutureWeatherByAirport`, `flightHappinessIndex` (on-time rate and
  comfort), `getFlightPriceByCities`, `searchFlightItineraries`.
Call `getTodayDate` when the user says today or tomorrow.

Report scheduled and estimated times in the airport's local time, and say
where data is an estimate. Free calls are limited; do not poll in a loop.
Use a Salix schedule when the user wants updates.

## Fallback

Without a binding, search the flight number with `web.search` and read the
airline or airport page with `web.read_pages`.

Booking is not in this skill. Use `ctrip` or `fliggy` in China and
`expedia` elsewhere.
