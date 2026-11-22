# Fastmail MCP plugin

Fastmail is an optional plugin. It connects to Fastmail's official server at
`https://api.fastmail.com/mcp` over Streamable HTTP. It does not replace Google,
Microsoft, or Composio connections.

## Connect

1. In Fastmail on the web, open **Settings > Privacy & Security > Connected apps
   & API tokens > Manage API tokens > New API token**.
2. Give the token a name and select **Type: MCP**. A JMAP token is not an MCP
   token. Fastmail Basic plans do not support API tokens.
3. Start with **Read data**. Add other permissions only when you need them.
4. Generate and copy the token. Fastmail shows it only once.
5. In Comma, open **Plugins > Fastmail** and enter it in the credential form.
   Do not send it in a chat, paste it into a command, or commit it to a file.

The connection uses the existing group-scoped MCP credential configuration.
It sends the token only as an Authorization Bearer header, not in the URL or
model-visible tool arguments. The public binding projection and MCP result
redaction use the existing secret handling. The plugin is off by default.
Treat a connection in a shared Workspace as access for that Workspace, not as
an independently consented personal source.

## Permissions and capabilities

Fastmail documents these permission boundaries:

| Token permission | What Fastmail allows |
| --- | --- |
| Read data | Search and read email, contacts, and calendars. |
| Make changes | Draft replies; move, delete, and organize email; update contacts and calendars. |
| Send email | Send email on your behalf. |

The server's authenticated `tools/list` response is the execution contract.
Comma discovers it after connection; this plugin does not hard-code tool names
or infer unadvertised capabilities. Sending and destructive changes still need
the user's authorization under the normal agent policy. A token permission is
not approval for a particular action.

Fastmail currently does **not** support attachments through MCP. This change
also does not add Fastmail OAuth, JMAP, push subscriptions, mailbox ingestion,
Routine/personal-source collection, or automatic meeting/calendar sync. Those
need separate adapters and consent flows; installing this plugin does not turn
them on. Existing personal-source providers remain unchanged.

## Disconnect and failures

Disconnect the plugin credential in Comma to remove its local MCP binding.
To revoke the token at Fastmail, return to **Manage API tokens** and select
**Remove access**. Local disconnect does not revoke a token at Fastmail.

For an authorization failure, check that the token is MCP-type, still active,
and has the required permissions. Enter a replacement only in the credential
form. Rate limits and outages are not proof of an invalid token. Retry later;
do not create a tight polling loop or retry a send without checking its outcome.
Fastmail account data returned to the agent is subject to the AI client's data
handling policy. Use a least-privilege token and consider your organization's
compliance rules before connecting.

## Implementation and verification

`SalixMCP.HostedServices` declares the plugin and MCP definition together. The
legacy `SalixMCP.ChinaServices` registration entry point delegates to this
catalog so existing plugin and built-in owners keep the same interface. Existing
service declarations and their categories are preserved; Fastmail is in
**Integrations**. Authentication uses `mcp_api_key` with `FASTMAIL_MCP_TOKEN`,
a secret Bearer header, and the existing setup, binding, transport, and redaction
owners. There is no new credential store or provider-specific transport.

The mock tests exercise the production setup and gateway against a local MCP
fixture: credential validation, Bearer authentication, discovery and a read
call, public/result redaction, enable/disable, disconnect, group isolation,
401 rejection, and 429 classification. Fixture tool names do not describe the
live Fastmail schema.

Before merge, run the Fastmail and existing plugin setup tests, the provider
logo tests, formatting/type checks, and `pnpm docs:check`. A separate E2E check
needs an authorized Fastmail account and an MCP-type token entered through the
credential form. Start read-only: connect, inspect `tools/list`, search/read a
test message, check that no credential appears in client responses or logs,
then disconnect and revoke. Test sending or deletion only with explicit consent
and disposable data. Mock coverage is not evidence of a successful live login.

## Official references

- [Fastmail MCP connection and permission guide](https://www.fastmail.help/hc/en-us/articles/15869557281295)
- [Fastmail API tokens, plan availability, and revocation](https://www.fastmail.help/hc/en-us/articles/5254602856719)
- [Fastmail MCP announcement](https://www.fastmail.com/blog/an-mcp-server-for-fastmail/)
