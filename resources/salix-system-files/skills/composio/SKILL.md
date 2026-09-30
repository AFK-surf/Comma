---
name: composio
description: Connect third-party services (Gmail, Google Calendar, Notion, Linear, Slack, GitHub, and ~300 other toolkits) through Composio-hosted auth and call them directly with the composio.* tools, when those tools are available in the tool catalog.
---

# Composio

Use this skill whenever the task involves a third-party service and the
`composio.*` tools are present in the current tool catalog. Composio hosts the
account connection flow and executes provider operations server-side: results
come back inline as data — no OAuth app setup, no credential injection, no
`env.exec` subprocess.

Tool names below are canonical call targets. In the internal LLM runtime,
invoke them with `call(tool="<name>", params={...})`.

## Typical Goals

- Read, search, or send Gmail messages; list or create Google Calendar events.
- Read or update Notion pages, Linear issues, GitHub issues/PRs, Slack messages.
- Connect a new third-party account for this agent group via a hosted link.
- Discover which service integrations ("toolkits") and operations ("tools")
  are available for a task.

## Choosing between Composio and managed OAuth

The tool catalog only shows the paths this tenant has configured, so in most
sessions there is no choice to make: use whichever of `composio.*` / `oauth.*`
is present. When **both** are available:

- For Comma GitHub, Linear, Notion, and Slack plugins, use connected official MCP tools when they cover the task.
  Reuse managed OAuth credentials for API, CLI, or VM work. Check existing connections before requesting authorization.
- For Slack, check `oauth.list_credentials` and `mcp.list` before Composio.
  The Slack MCP uses the Comma Slack plugin's user OAuth token.
  If the credential is active but MCP discovery is stale, use `mcp_manager.reconnect`, then `mcp.list`.
  If Slack rejects MCP app access, report that error. Do not request another connection unless the user asks.
- For other services, use `composio.execute` for direct provider calls: one-shot reads,
  simple writes, anything that maps to a single provider operation (fetch
  emails, list events, create an issue). It avoids the VM round-trip.
- Prefer the managed OAuth path (`oauth.*` + `env.exec` with
  `credential_env`, as described in the provider skills such as `google`)
  for complex, scripted, or file-heavy work: multi-step CLI pipelines,
  bulk exports, anything needing a working directory or provider CLIs.
- Do not connect the same service through both paths unless the user asks;
  check `oauth.list_credentials` and `composio.list_connections` before
  starting a new authorization.

## Operating Principles

- Connections belong to the agent group and are shared by its agents; never
  delete one (`composio.delete_connection`) unless the user asks.
- Only an ACTIVE connection can serve `composio.execute` calls. EXPIRED or
  FAILED connections need a fresh `composio.request_connection`.
- `successful=false` in an execute result is a provider-level failure
  (missing scopes, bad arguments, provider error) — read the `error` field
  and adjust; it is not a runtime fault.
- Results can be large; when a result comes back truncated, narrow the
  request (fewer items, filters, pagination) instead of retrying as-is.
- Do not claim a provider-side change happened until the execute result shows
  `successful=true`.

## Connecting an account

1. Check `composio.list_connections` for an ACTIVE connection for the toolkit.
2. If the toolkit slug is not obvious, search `composio.list_toolkits` with a
   query (common slugs: `gmail`, `googlecalendar`, `googledrive`, `notion`,
   `linear`, `slack`, `github`).
3. Call `composio.request_connection` with the toolkit slug. It returns a
   hosted Connect Link (`redirect_url`) and a `connected_account_id`, and sets
   a session wait.
4. Post the `redirect_url` to the requester yourself through the current
   visible reply path — it is NOT delivered automatically. For an internal
   Comma conversation, use `call(tool="im_api.internal.send_message",
params={...})` with `connect_id="internal"` inside params.
5. When the user says they finished (or the wait expires), verify with
   `composio.check_connection` using the `connected_account_id`. `pending`
   means they have not completed the browser flow yet; ask again or wait.

## Discovering and executing operations

1. Find the operation: `composio.list_tools` with the toolkit slug and/or a
   query (e.g. toolkit `gmail`, query "fetch emails"). Well-known slugs like
   `GMAIL_FETCH_EMAILS` or `GOOGLECALENDAR_EVENTS_LIST` can be used directly.
2. Fetch the input schema with `composio.get_tool` before the first call to
   an unfamiliar tool; build `arguments` to match its `input_parameters`.
3. Run it with `composio.execute`. The provider data is in the result's
   `data` field. When the group has several connections for one toolkit,
   pin one with `connected_account_id`.

## Failure Playbook

- `composio is not configured for this tenant` — this path is not enabled;
  use the `oauth.*` tools and the provider skill instead. If neither path is
  in the catalog, tell the user an admin must configure OAuth credentials or
  a Composio API key in the dashboard settings.
- Execute fails with `No connected account found` — connect first
  (see "Connecting an account").
- `successful=false` mentioning scopes or permissions — the connection lacks
  the needed scopes; reconnect the toolkit and tell the user why.
- Repeated provider 4xx in `error` — re-check the tool's schema with
  `composio.get_tool`; the arguments likely do not match `input_parameters`.
