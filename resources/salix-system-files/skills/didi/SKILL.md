---
name: didi
description: "滴滴出行 DiDi ride-hailing in mainland China: estimate fares, call a car, check order status and driver location, and cancel rides."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Official MCP

Bind `https://mcp.didichuxing.com/mcp-servers?key={api_key}` (streamable
HTTP). Test with the sandbox `.../mcp-servers-sandbox?key={api_key}` (mock
orders). The personal key comes from mcp.didichuxing.com/claw (the key page;
login is a QR scan in the 滴滴出行 app). The Beta tier estimates and returns app
links; ordering needs the Pro tier.

Tools (all values are strings): `maps_textsearch` (full city name, for example
北京市), `maps_regeocode`, `taxi_estimate`, `taxi_create_order`,
`taxi_query_order`, `taxi_get_driver_location`, `taxi_cancel_order`,
`taxi_generate_ride_app_link`.

## Flow

1. `maps_textsearch` for pickup and destination. Ask the user when there is
   more than one likely place.
2. `taxi_estimate` returns a `traceId` and the price for each car type.
3. The user picks the car type (快车, 专车, 特惠快车...). Never substitute one.
4. After the user confirms car type and price, call `taxi_create_order` with
   the latest `traceId`. Error -32021 means it expired: estimate again.
5. `taxi_query_order` and `taxi_get_driver_location` for status (1 accepted,
   2 arrived, 4 in trip, 5 complete). Share the plate and driver name.

If create fails with `Unexpected content type: text/plain`, the user has not
turned on DiDi MCP 免密支付 on mcp.didichuxing.com. Tell them; do not retry.
Without ordering access, give the link from `taxi_generate_ride_app_link`.

## Safety

Creating an order dispatches a real car and charges the user's DiDi account.
Cancellation after a driver accepts can cost a fee. Ask before cancel.
