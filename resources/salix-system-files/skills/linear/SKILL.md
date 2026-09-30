---
name: linear
description: Work with Linear through the `linear` CLI, including issue listing, creation, updates, comments, team/project/label lookup, JSON issue views, and OAuth-backed CLI access on persistent environments.
---

# Linear

Use this skill whenever the task involves Linear and the `linear` CLI is available or should be made available. Prefer CLI workflows for listing, creating, viewing, and updating Linear records.

These notes are grounded against `@schpet/linear-cli` version `2.6.0`, and the setup below installs that version. Other versions can have different commands and flags, so inspect subcommand help when syntax is uncertain.

Tool names below are canonical call targets. In the internal LLM runtime, invoke them with `call(tool="<name>", params={...})`.

## Comma plugin connections

Comma connects this plugin through Salix-managed OAuth. Reuse its active `linear` credential alias for API or VM operations.
Use the connected official MCP tools when they cover the task. Check the current tool catalog before choosing a tool.
The API credential also authorizes the official MCP server.
Existing Composio connections can still serve supported tasks. Their presence does not require a new Composio authorization.

## Typical Goals

- Check existing issues before creating duplicates.
- Create issues with clear titles, descriptions, team assignment, labels, projects, priorities, or assignees when requested.
- View, update, comment on, assign, transition, or close issues.
- List teams, labels, and projects to resolve names, keys, and IDs.
- Configure reusable OAuth-backed CLI access on a persistent VM.

## Operating Principles

- Inspect `linear --help` and subcommand help when command syntax is uncertain; CLI versions can differ.
- Prefer structured or explicit output flags when supported by the installed CLI. In `2.6.0`, `linear issue query`, `linear issue view`, `linear label list`, and `linear project list` accept `--json`; `linear issue mine` does not.
- Use managed OAuth for Linear credentials. When credentials are missing, expired, or insufficient, use `oauth.request_authorization` to connect the user's Linear account, then pass the saved credential to `env.exec` using `credential_env`.
- Check existing issues before creating a new one unless the user explicitly asks to create a new issue.
- Do not claim an issue was found, created, or updated until a `linear` command succeeds and returns an identifier or URL.
- If auth or permissions fail, report the concrete blocker and the command that exposed it.

## Managed OAuth

Before requesting authorization, check whether a Linear OAuth credential already exists:

1. Call `oauth.list_credentials`.
2. If a `linear` credential is available and active, use its alias in `env.exec` using `credential_env`; replace `"default"` below with the actual alias returned by `oauth.list_credentials`:
   ```json
   [
     {
       "env_var": "LINEAR_ACCESS_TOKEN",
       "provider": "linear",
       "alias": "default",
       "value": "access_token"
     }
   ]
   ```
   The CLI does not read `LINEAR_ACCESS_TOKEN`. Its environment variable is `LINEAR_API_KEY`, and it sends that value unchanged as the `Authorization` header. A Linear OAuth token needs the `Bearer` prefix, so start each `env.exec` command that runs `linear` with this line:
   ```bash
   if [ -n "$LINEAR_ACCESS_TOKEN" ]; then export LINEAR_API_KEY="Bearer $LINEAR_ACCESS_TOKEN"; fi
   ```
   Do not pass `--workspace` while `LINEAR_API_KEY` is set. The CLI rejects that combination.
3. If no usable Linear credential exists, call `oauth.request_authorization` with `provider: "linear"`, a short stable `alias` such as `"default"`, and a concise `reason`. Request scopes for the intended work; omit `scopes` for read-only access, or pass `["read", "write"]` when mutations such as creating, updating, commenting, or assigning issues are needed.
4. Share the returned `authorization_url` with the user and wait for them to confirm they completed authorization.
5. Call `oauth.complete_authorization` with the returned `state`. If it returns `completed`, retry the Linear command with `env.exec` using `credential_env` and the returned alias. If it returns `pending`, ask the user to finish the authorization flow. If it returns `failed` or `expired`, start a fresh authorization flow.

Managed OAuth injects the token into the subprocess that needs Linear access.

### If oauth.\* tools are unavailable (Composio tenants)

Some tenants use Composio instead of per-provider OAuth apps, and the tool
catalog reflects the available capabilities. If the `oauth.*` tools are not in
the current tool catalog but `composio.*` tools are, do not try this skill's
managed-OAuth or `env.exec` `credential_env` flow for Linear. Instead:

1. Check `composio.list_connections` for an ACTIVE `linear` connection.
2. If none, connect with `composio.request_connection` (toolkit `linear`),
   post the returned Connect Link to the requester, and verify with
   `composio.check_connection`.
3. Run Linear operations directly with `composio.execute`
   (e.g. `LINEAR_LIST_LINEAR_ISSUES`); discover tool slugs and schemas with
   `composio.list_tools` / `composio.get_tool`.

See the `composio` skill for the full flow and how to choose between the two
paths when both are available.

## Initial Checks

```bash
linear --version
linear --help
linear auth list
linear auth whoami
linear team list
```

If the installed version is not `2.6.0`, inspect subcommand help before you use the flags below.

If `linear` is not installed, check whether `npx` can run the CLI:

```bash
npx -y @schpet/linear-cli@2.6.0 --help
```

## Issue Discovery And Triage

In `2.6.0`, find issues with `linear issue query`. It supports full-text search with `--search`. It needs `--team <key>` or `--all-teams` when no default team is configured. `linear issue list` is an alias of `linear issue mine`, which lists only your own issues and rejects `--assignee`, `--all-assignees`, and `--unassigned`.

```bash
linear issue query --help
linear issue query --search "login timeout" --all-teams --limit 50 --no-pager
linear issue query --team COMMA --limit 50 --json
linear issue mine --team COMMA --state started --state unstarted --no-pager
```

Useful `issue query` flags in `2.6.0`:

- `--search <term>` for full-text search. Add `--search-comments` to also search comments. `--sort` cannot be used with `--search`.
- `--team <key>` repeatable, or `--all-teams`.
- `--state <state>` repeatable, with values `triage`, `backlog`, `unstarted`, `started`, `completed`, `canceled`. All states is the default.
- `--assignee <username>` or `--unassigned`. All assignees is the default.
- `--project <project>`, `--label <label>` repeatable, `--cycle <cycle>`, and `--milestone <milestone>`.
- `--created-after <date>` and `--updated-after <date>`.
- `--sort manual|priority`.
- `--limit <limit>`, default `50`, `0` for no limit.
- `--include-archived`.
- `--json`.
- `--no-pager`.

Inspect candidates with JSON when downstream parsing is useful:

```bash
linear issue view <issue-id-or-key>
linear issue view <issue-id-or-key> --json --no-comments --no-download
linear issue url <issue-id-or-key>
linear issue title <issue-id-or-key>
```

When deciding whether an issue is a duplicate, compare:

- User-visible symptom.
- Affected product, platform, or workflow.
- Recency and status.
- Existing owner, team, label, or project context.

## Create Issues

Before creating, resolve the target team and optional metadata:

```bash
linear team list
linear label list --all
linear label list --all --json
linear project list --all-teams
```

Create the issue non-interactively when the requested fields are known. Keep the description specific and actionable:

```bash
linear issue create --team COMMA --title "Investigate login timeout on macOS" --description "..." --label Bug --priority 2 --no-interactive
```

Useful `issue create` flags in `2.6.0`:

- `--title <title>`.
- `--description <description>`, or `--description-file <path>` for Markdown content.
- `--team <team>`.
- `--assignee <assignee>` or `--assignee self`.
- `--label <label>` repeatable.
- `--project <project>`.
- `--state <state>`.
- `--priority <priority>` where `1` is highest and `4` is lowest.
- `--estimate <estimate>`.
- `--due-date <dueDate>`.
- `--parent <team_number>`.
- `--start`.
- `--no-interactive`.

After creation, capture and report:

- Issue key or identifier.
- Title.
- URL.
- Team and status if available.

## Update, Comment, And Transition

Inspect command help before mutating records:

```bash
linear issue update --help
linear issue comment --help
linear issue comment add --help
```

Common operations include:

- Add a comment with investigation notes or a user-provided update.
- Assign or unassign an issue.
- Change status or workflow state.
- Add labels, project, priority, estimate, parent, or due date.
- Close or reopen an issue.

In `2.6.0`, `linear issue update --label` replaces all labels on the issue. To keep the other labels, use `--add-label` and `--remove-label`.

Examples:

```bash
linear issue update COMMA-123 --state started --assignee self
linear issue update COMMA-123 --add-label Bug --add-label Regression --priority 1
linear issue comment add COMMA-123 --body "Investigated the timeout path; next step is checking session refresh."
linear issue comment list COMMA-123
```

After mutation, re-view the issue or rely on the command's returned identifier/URL to verify the change.

## Projects, Teams, And Workflow Context

Use lookup commands to avoid guessing names or IDs:

```bash
linear team list
linear team members COMMA
linear label list --all
linear label list --team COMMA
linear label list --workspace
linear project list --all-teams
linear project list --team COMMA
linear project view <projectId>
```

The `2.6.0` top-level command set includes `auth`, `issue`, `team`, `user`, `project`, `project-update`, `cycle`, `milestone`, `initiative`, `initiative-update`, `label`, `document`, `config`, `schema`, `api`, and `markdown`.

If workflow-state names are uncertain, inspect issue details and use `linear issue update --state <state>` with a known state name or type.

## Authentication And Setup

If `linear auth whoami` already works, do not recreate credentials. If setup is required, use the managed OAuth flow above and run Linear commands with `env.exec` using `credential_env`.

Success criteria for setup:

- `@schpet/linear-cli` is installed or invokable through a persistent wrapper.
- A Linear OAuth token is available to the CLI through `env.exec` with `credential_env`, and the command exports it as `LINEAR_API_KEY` with the `Bearer` prefix.
- `linear auth whoami` succeeds.
- A real read command such as `linear team list` succeeds.

Setup workflow:

1. Check for Node/npm and prior CLI state with `linear auth list`.
2. Install the CLI globally with `npm install -g @schpet/linear-cli@2.6.0`.
3. After global install, the binary may land in the nvm version bin path rather than a `PATH` directory. Check with `ls "$(npm prefix -g)/bin/linear"`. **Prefer creating a symlink** into a persistent `PATH` directory over an `npx` wrapper (which re-downloads on every invocation):
   ```bash
   ln -sf "$(npm prefix -g)/bin/linear" /home/sprite/.local/bin/linear
   ```
4. Verify with `linear auth whoami` and `linear team list` using `env.exec` with `credential_env` and the `LINEAR_API_KEY` export from Managed OAuth.

## Failure Handling

- `linear` command missing after `npm install -g`: the binary is in the nvm version bin path. Symlink it: `ln -sf "$(npm prefix -g)/bin/linear" /home/sprite/.local/bin/linear`.
- Network calls to `https://api.linear.app/graphql` fail: the selected environment may block outbound access. Report the blocker and the failing command, or use another connected environment that has network access.
- `No API key configured`: the command did not export `LINEAR_API_KEY`. Export it from the injected token as Managed OAuth describes.
- `No default team configured`: pass `--team <key>`, or `--all-teams` for `linear issue query`.
- `whoami` works but an issue query fails: run `linear team list`; treat query errors caused by filters, sort, or project config as non-auth failures.
- No Linear access: clearly report the access blocker and do not fabricate issue data.
