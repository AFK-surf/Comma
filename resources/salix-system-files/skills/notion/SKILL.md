---
name: notion
description: Work with Notion through the `notion-cli` (4ier/notion-cli), including OAuth-backed CLI access, CLI installation via npm, and workspace operations such as searching pages, reading content, querying databases, and listing recent updates. Use when the user asks to read, search, or update their Notion workspace from the CLI.
---

# Notion

Use this skill whenever the task involves Notion and `notion-cli` is available or should be set up. Prefer CLI workflows for all read/write operations once the CLI is configured.

These notes are grounded against `@4ier/notion-cli` version `0.4.0`.

Tool names below are canonical call targets. In the internal LLM runtime, invoke them with `call(tool="<name>", params={...})`.

## Comma plugin connections

Comma connects this plugin through Salix-managed OAuth. Reuse its active `notion` credential alias for API or VM operations.
Use the connected official MCP tools when they cover the task. Check the current tool catalog before choosing a tool.
Notion API OAuth and official MCP OAuth are separate grants. Complete both steps from Plugins when adding the plugin.
An API token does not authorize the official Notion MCP server.
Existing Composio connections can still serve supported tasks. Their presence does not require a new Composio authorization.

## Typical Goals

- Authenticate the CLI against the user's Notion workspace.
- Search pages and databases.
- Read page content as Markdown.
- Query databases with filters and sorts.
- Create or update pages and blocks.
- List recent activity across the workspace.

## Operating Principles

- Always verify the CLI is authenticated before running workspace commands.
- Use `cloud-vm` for CLI installation and all shell operations.
- Use managed OAuth for Notion credentials. When credentials are missing, expired, or insufficient, use `oauth.request_authorization` to connect the user's Notion workspace, then pass the saved credential to `env.exec` using `credential_env`.

## Managed OAuth

Before requesting authorization, check whether a Notion OAuth credential already exists:

1. Call `oauth.list_credentials`.
2. If a `notion` credential is available and active, use its alias in `env.exec` using `credential_env`; replace `"default"` below with the actual alias returned by `oauth.list_credentials`:
   ```json
   [
     {
       "env_var": "NOTION_TOKEN",
       "provider": "notion",
       "alias": "default",
       "value": "access_token"
     }
   ]
   ```
3. If no usable Notion credential exists, call `oauth.request_authorization` with `provider: "notion"`, a short stable `alias` such as `"default"`, and a concise `reason`. Do not pass `scopes`; the Notion adapter builds the provider authorization URL without scope parameters.
4. Share the returned `authorization_url` with the user and wait for them to confirm they completed authorization.
5. Call `oauth.complete_authorization` with the returned `state`. If it returns `completed`, retry the Notion command with `env.exec` using `credential_env` and the returned alias. If it returns `pending`, ask the user to finish the authorization flow. If it returns `failed` or `expired`, start a fresh authorization flow.

Managed OAuth injects the token into the subprocess that needs Notion access.

### If oauth.\* tools are unavailable (Composio tenants)

Some tenants use Composio instead of per-provider OAuth apps, and the tool
catalog reflects the available capabilities. If the `oauth.*` tools are not in
the current tool catalog but `composio.*` tools are, do not try this skill's
managed-OAuth or `env.exec` `credential_env` flow for Notion. Instead:

1. Check `composio.list_connections` for an ACTIVE `notion` connection.
2. If none, connect with `composio.request_connection` (toolkit `notion`),
   post the returned Connect Link to the requester, and verify with
   `composio.check_connection`.
3. Run Notion operations directly with `composio.execute`
   (e.g. `NOTION_SEARCH_NOTION_PAGE`); discover tool slugs and schemas with
   `composio.list_tools` / `composio.get_tool`.

See the `composio` skill for the full flow and how to choose between the two
paths when both are available.

## Initial Checks

```bash
NOTION_BIN="$(npm root -g)/@4ier/notion-cli/bin/notion-bin"
$NOTION_BIN auth status
$NOTION_BIN user me
```

If auth passes, proceed to the requested task. If not, run the full setup below.

---

## Setup: Install and Authenticate

Use this setup when the CLI is missing or cannot be reached from the selected environment.

### Step 1 — Install notion-cli on cloud-vm

```bash
npm install -g @4ier/notion-cli
node $(npm root -g)/@4ier/notion-cli/install.js   # downloads the Go binary
```

Verify:

```bash
NOTION_BIN="$(npm root -g)/@4ier/notion-cli/bin/notion-bin"
$NOTION_BIN --version
```

### Step 2 — Verify OAuth-backed CLI access

Run Notion commands with `env.exec` using `credential_env` and the OAuth credential alias returned by `oauth.list_credentials` or `oauth.complete_authorization`.

```bash
NOTION_BIN="$(npm root -g)/@4ier/notion-cli/bin/notion-bin"
$NOTION_BIN auth status
$NOTION_BIN user me
```

---

## Common Operations

### Search workspace

```bash
$NOTION_BIN search "meeting notes"
$NOTION_BIN search ""   # lists recently edited pages
```

### List recent pages

```bash
$NOTION_BIN page list
```

### Read page content as Markdown

```bash
$NOTION_BIN block list <page-id> --md --depth 3
# Also accepts full Notion URLs:
$NOTION_BIN block list https://notion.so/My-Page-abc123def456 --md
```

### Query a database

```bash
$NOTION_BIN db query <db-id>
$NOTION_BIN db query <db-id> --filter 'Status=Done' --sort 'Date:desc'
# Complex filters (OR, nesting):
$NOTION_BIN db query <db-id> --filter-json '{"or":[{"property":"Status","status":{"equals":"Done"}}]}'
```

### Create a page in a database

```bash
$NOTION_BIN page create <db-id> --db "Name=Weekly Review" "Status=Todo"
```

### Append Markdown blocks to a page

```bash
$NOTION_BIN block append <page-id> --file notes.md
```

### Raw API escape hatch

```bash
$NOTION_BIN api GET /v1/users/me
$NOTION_BIN api GET /v1/databases/<db-id>
```

---

## Guardrails

**Do:**

- Use `$(npm root -g)/@4ier/notion-cli/bin/notion-bin` as the binary path — the `notion` symlink may not be on PATH in all environments.
- Verify `auth status` before every session's first workspace command.
- Use `--md` and `--depth` flags when reading nested page content.

**Don't:**

- Don't use the npm `notion` bin wrapper script directly — it is a shell script that Node tries to parse as JS, causing a SyntaxError. Always use `notion-bin`.

---

## Failure Modes

| Symptom                            | Likely cause                                                | Fix                                                                                |
| ---------------------------------- | ----------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `API token is invalid`             | OAuth token is missing, expired, or not accepted by the CLI | Request or refresh Notion OAuth, then retry with `env.exec` using `credential_env` |
| `notion-bin: command not found`    | Binary not on PATH                                          | Use full path `$(npm root -g)/@4ier/notion-cli/bin/notion-bin`                     |
| Token works but pages return empty | Integration not shared with workspace pages                 | Share the integration with the relevant pages/databases in Notion settings         |

---
