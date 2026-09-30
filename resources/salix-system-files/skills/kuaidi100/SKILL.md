---
name: kuaidi100
description: "快递100 Kuaidi100: track express packages by tracking number, estimate delivery time, and estimate shipping cost between Chinese addresses."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Official MCP

Bind `https://api.kuaidi100.com/mcp/streamable?key={api_key}` (streamable
HTTP; SSE at `/mcp/sse`). The key is the enterprise key from
api.kuaidi100.com. Stdio alternative: `uvx kuaidi100-mcp` with
`KUAIDI100_API_KEY`.

Tools:
- `query_trace`: tracking by number. SF Express also needs the last four
  digits of the sender's or recipient's phone.
- `estimate_time`: delivery time before shipping.
- `estimate_time_with_logistic`: arrival time for a package in transit.
- `estimate_price`: cost by courier, sender and recipient address, and
  weight. Couriers include shunfeng, jd, debangkuaidi, yuantong, zhongtong,
  shentong, yunda, and ems.

## Tips

- If the user does not know the courier, try `query_trace` without it or
  infer from the number format, and say which courier matched.
- Compare `estimate_price` across couriers when the user asks for the
  cheapest or fastest option.
- Kuaidi100 bills each query. Do not poll the same package in a loop; use a
  Salix schedule for updates.

The MCP does not book pickups (寄件下单). Tell the user to book in the courier's
app or on kuaidi100.com.
