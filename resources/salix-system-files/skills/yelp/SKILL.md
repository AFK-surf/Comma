---
name: yelp
description: "Yelp: find local businesses and restaurants, compare ratings, read reviews, hours, and details, and ask Yelp's AI for recommendations."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## API

- Composio `yelp` toolkit: `YELP_SEARCH_BUSINESSES`,
  `YELP_GET_BUSINESS_DETAILS`, `YELP_GET_BUSINESS_REVIEWS`,
  `YELP_SEARCH_AND_CHAT`.
- Official Yelp MCP (github.com/Yelp/yelp-mcp, package `mcp-yelp-agent`) wraps
  the Yelp AI API with one tool, `yelp_agent`. It needs a paid `YELP_API_KEY`
  as a binding secret. Run it as a stdio or streamable-http MCP.

Report the rating, review count, price level, hours, and address with a Yelp
link. Say when data can be stale (for example, hours on holidays).

## Web

yelp.com blocks datacenter browsers. For pages the API does not cover, or for
reservations and waitlists, use the Comma in-app browser. See
`restaurant-reservations` for booking rules.

Writing reviews or messaging a business is public or sent in the user's name.
Show the text and confirm first.
