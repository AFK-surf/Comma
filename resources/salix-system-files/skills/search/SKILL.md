---
name: search
description: Perform online searches and web content extraction with web.search and web.read_pages.
---

# Search

Use this skill whenever the user asks for online search, current information, web research, source discovery, article/page reading, or source-backed extraction.

## Workflow

1. Call `web.search` with a specific query.
2. Use the returned titles, URLs, snippets, and source dates to decide which sources matter.
3. When snippets are not enough, call `web.read_pages` with up to 10 selected URLs.
4. Give the final answer with source titles/URLs and relevant dates.

## Tool Shapes

`web.search`:

```json
{ "query": "specific search query" }
```

`web.read_pages`:

```json
{ "urls": ["https://example.com/a", "https://example.com/b"] }
```

## Guidance

- Use targeted queries with names, dates, product versions, locations, or source types when relevant.
- For recent or changing topics, include current-year or date terms and compare publication dates.
- Prefer primary or official sources for legal, medical, financial, security, software/API, and policy questions.
- Use `web.read_pages` when the user asks for details from pages, when snippets are inconclusive, or when source-backed summaries require full text.
- If web tools report that Exa is not configured, tell the user the blocker instead of inventing an answer.
