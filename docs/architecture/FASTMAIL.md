# Fastmail MCP plugin

Fastmail is an optional hosted MCP plugin. It connects to Fastmail's official
server at `https://api.fastmail.com/mcp` over Streamable HTTP. It does not
replace Google, Microsoft, or Composio connections, and it does not add a new
OAuth provider.

## Connect

1. In Fastmail on the web, open **Settings > Privacy & Security > Connected apps
   & API tokens > Manage API tokens > New API token**.
2. Name the token and select **Type: MCP**. A JMAP token is not an MCP token.
   Fastmail Basic plans do not support API tokens.
3. Start with **Read data**. Add **Make changes** or **Send email** only when
   needed.
4. Generate and copy the token. Fastmail shows it only once.
5. In Comma, open **Plugins > Fastmail** and enter the token in the credential
   form. Do not paste it in chat messages, commands, or files.

The plugin reuses the existing group-scoped secret form (`FASTMAIL_MCP_TOKEN`).
Comma sends the token only in the `Authorization: Bearer` header, never in the
URL or model-visible tool arguments. Public binding projections, tool outputs,
and logs redact the stored token through the existing `SalixMCP` secret
handling.

The plugin is disabled by default (`default_enabled: false`). Credentials are
group-scoped: a connection in a shared Workspace grants access to that
Workspace, not to an independently consented personal source.

## Permissions and dynamic tool discovery

Fastmail documents three token permission tiers:

| Token permission | What Fastmail allows |
| --- | --- |
| Read data | Search and read email, contacts, and calendars. |
| Make changes | Draft replies; move, delete, and organize email; update contacts and calendars. |
| Send email | Send email on your behalf. |

Comma discovers tool names and schemas dynamically from the authenticated
`tools/list` response after connecting. The plugin does not hard-code Fastmail
tool names or infer unadvertised capabilities. Sending mail and destructive
changes still require user authorization under normal agent policy; a token
permission does not authorize a specific action.

## Unsupported scope

- Attachments through MCP (not supported by Fastmail MCP)
- Fastmail OAuth
- JMAP
- Push subscriptions and automatic mailbox ingestion
- Routine or personal-source collection
- Automatic meeting or calendar sync

Installing this plugin does not enable those flows. Existing personal-source
providers remain unchanged.

## Disconnect, errors, and rate limits

Disconnecting Fastmail in Comma deletes only the local MCP binding. It does
**not** revoke the token at Fastmail. To revoke access at Fastmail, open
**Settings > Privacy & Security > Connected apps & API tokens > Manage API
tokens** and select **Remove access**.

Error handling separates authentication failures from throttling:

- **HTTP 401 / 403**: treated as credential rejection during setup and as
  `auth_failed` or `reauthorization_required` during tool calls. Verify that
  the token is **Type: MCP**, active, and granted the required permissions,
  then enter a replacement in the credential form.
- **HTTP 429**: treated as temporary unavailability during setup
  (`plugin_connection_unavailable`) and as `protocol_error` during tool calls,
  not as an invalid token. Retry later without tight polling, and never retry a
  send without checking its outcome.

## Architecture notes

`SalixMCP.HostedServices` declares the built-in MCP definition
(`mcp1_0000000000000000026`) and system plugin (`fastmail`, category
**Integrations**). `SalixMCP.ChinaServices` delegates `mcp_definitions/0` and
`plugin_definitions/0` to `SalixMCP.HostedServices` to keep existing callers
compatible. Authentication reuses `mcp_api_key` with `FASTMAIL_MCP_TOKEN`,
existing setup, binding, transport, and redaction owners.

## Official references

- [Fastmail MCP connection and permission guide](https://www.fastmail.help/hc/en-us/articles/15869557281295)
- [Fastmail API tokens, plan availability, and revocation](https://www.fastmail.help/hc/en-us/articles/5254602856719)
- [Fastmail MCP announcement](https://www.fastmail.com/blog/an-mcp-server-for-fastmail/)
