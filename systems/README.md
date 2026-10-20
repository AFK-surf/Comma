# Comma Systems

The backend of [Comma](../README.md) is one Elixir/Mix umbrella with one
release, `mix release comma`. The release holds several **subsystems**. Each
subsystem is a set of OTP apps under [`apps/`](apps).

| Subsystem          | `COMMA_SUBSYSTEMS` name | What                                                                                    |
| ------------------ | ----------------------- | --------------------------------------------------------------------------------------- |
| **Salix**          | `salix`                 | The distributed, multi-tenant multi-agent runtime with optional remote VM environments |
| **Comma product**  | `comma_product`         | Comma product backend and API. It drives Salix through the `Comma.Salix.*` boundary     |
| **BridgeForTeams** | `bridge_for_teams`      | Teams backend and dashboard. It shares the Salix runtime                                |
| **Alert Router**   | `alert_router`          | Comma notification router                                                               |

`Comma`'s `@subsystems` map in [`apps/comma/lib/comma.ex`](apps/comma/lib/comma.ex)
lists the apps of each subsystem.

### Selecting subsystems per node

A pod runs only the subsystems in `COMMA_SUBSYSTEMS` (comma-separated). When it
is unset, the pod runs all subsystems:

```sh
COMMA_SUBSYSTEMS=salix bin/comma start
COMMA_SUBSYSTEMS=comma_product,salix bin/comma start
COMMA_SUBSYSTEMS=bridge_for_teams,salix bin/comma start
```

An unknown subsystem name stops startup. The selection applies only to the
release. `mix run` and `mix test` start all umbrella apps.

---

## Salix

Salix uses BEAM/OTP for process orchestration, object storage for aggregate
state and content, and PostgreSQL for queried control and coordination data.
See the [storage boundary](../docs/storage-search.md), the
[agent runtime](../docs/agent-runtime.md), and the
[Salix TLA+ specs](../tla/salix/README.md). Production deployment is in
[`DEPLOYMENT.md`](DEPLOYMENT.md).

Production Salix requires object storage with conditional writes, PostgreSQL
through `salix.database.url`, and Redis through `REDIS_URL` or
`COMMA_REDIS_URL`. Production startup fails when the database or Redis
configuration is missing. PostgreSQL migrations and control-data cutover
readiness must complete before Salix serves. See [`DEPLOYMENT.md`](DEPLOYMENT.md)
for storage conditionals (including `storage.atomic_operations` for GCS) and
[`config/runtime.exs`](config/runtime.exs) for startup requirements.

### Getting started

The team setup needs only Docker Desktop or OrbStack. The Dev Container image
pins Elixir, OTP, Node, pnpm, native build tools, and service dependencies.
From the repository root:

```sh
make dev-backend
```

This starts MinIO, Postgres, ClickHouse, Redis, Mailpit, and the deterministic
LLM. It compiles the source-mounted backend, runs local migrations, and seeds
the developer account and Group. It returns when the Salix and Comma APIs are
healthy. Build output and service data stay in Docker volumes, so a restart
compiles only changed source.

Lifecycle commands:

```sh
make dev-container-status
make dev-container-shell
make dev-container-restart  # recompile changed backend source, then wait for health
make dev-systems-logs
make dev-systems-down       # stop containers and keep every volume
make dev-container-rebuild  # only when the Dev Container Dockerfile or toolchain changes
```

Run Web and Electron from the host with host-installed client dependencies:

```sh
pnpm --dir clients install # first host setup only
make dev                  # container backend + host Web on :5174
make dev-electron         # container backend + native Electron
```

When the backend is ready, these checks must succeed:

```sh
curl http://127.0.0.1:4000/health   # Salix API
curl http://127.0.0.1:4200/health   # Comma product API
nc -vz 127.0.0.1 4400               # transfer server
```

The development-only bootstrap runs the Comma schema cutover on an empty local
database. It requires `MIX_ENV=dev`, `COMMA_ENVIRONMENT=local`, the local
database name, and empty product tables. It fails closed for populated or
remote data. Release containers use the one-shot `comma-migrate` service.

| Service              | Local address                                       |
| -------------------- | --------------------------------------------------- |
| Salix API/dashboard  | `http://127.0.0.1:4000`                             |
| Comma product API    | `http://127.0.0.1:4200`                             |
| Salix transfer       | `127.0.0.1:4400`                                    |
| Mailpit inbox / SMTP | `http://127.0.0.1:8025` / `127.0.0.1:1025`          |
| MinIO API / console  | `http://127.0.0.1:19000` / `http://127.0.0.1:19001` |
| Postgres             | `127.0.0.1:15432`                                   |
| ClickHouse HTTP      | `http://127.0.0.1:18123`                            |

#### Run isolated Salix-only sandboxes in parallel

For Salix work without the Comma product, each worktree can run its own
Compose project. Only Salix HTTP and transfer are published to the host:

```sh
make salix-dev-up
make salix-dev-info
```

The worktree path sets the project suffix and the two host ports. The command
refuses to start if a host port belongs to another service. To override the
label or ports:

```sh
SALIX_DEV_ID=router-memory \
SALIX_DEV_HTTP_PORT=25001 \
SALIX_DEV_TRANSFER_PORT=45001 \
make salix-dev-up
```

Repeat explicit port overrides for each lifecycle command. There is no source
watcher. After a Salix code change, rebuild:

```sh
make salix-dev-rebuild
make salix-dev-logs
make salix-dev-status  # addresses plus container health
make salix-dev-psql    # psql inside this worktree's private Postgres
make salix-dev-shell   # shell inside the running Salix release container
make salix-dev-down    # stop containers, keep data
make salix-dev-reset   # delete only this worktree's containers and volumes
```

Generated configuration is in the ignored `.local/salix-dev/` directory. An
optional `compose.override.yml` in the generated project directory applies to
all lifecycle commands. Keep private environment files there.

#### Inspect the complete Salix system prompt

Dump a complete prompt through the production composer. This does not start
Salix or read storage:

```sh
cd systems
mix salix.prompt.dump
mix salix.prompt.dump --role worker --runtime script --no-skill
mix salix.prompt.dump --agent-prompt "Additional diagnostic instructions"
```

In an OTP release:

```sh
bin/comma eval 'SalixAgent.Release.dump_system_prompt()'
```

#### Local seed data

The Dev Container seeds before it becomes healthy. `make dev-systems-seed` is
an idempotent rerun. It creates or reuses `comma-local@example.com`, its default
Workspace, the Salix Group Router and Worker, a local credit grant, and the user
Chat. It prints the Workspace ID and an API session token for local tools.

`make dev-electron` stores that Session in the ignored
`.local/comma-dev-session.json` and signs the unpackaged client in. Web, and
Electron started with `pnpm --dir clients dev:electron`, use the real
passwordless login. Request a code for that email and read it in Mailpit.

To issue one more credit grant, advance the generation. Repeating a generation
issues nothing:

```sh
COMMA_LOCAL_CREDIT_GRANT_GENERATION=2 make dev-systems-seed
```

The seed command mutates users, sessions, workspaces, billing grants, and Chat
data. It rejects a non-loopback `COMMA_LOCAL_API_BASE_URL`. Only an intentional
remote-data operation may set
`COMMA_LOCAL_DEV_SEED_ALLOW_NON_LOOPBACK=I_UNDERSTAND_THIS_MUTATES_REMOTE_DATA`.
Never set it for local development.

Local builds compile the recommendation mock with
`COMMA_LOCAL_RECOMMENDATION_MOCK=true`. It starts disabled. Toggle it in
**Settings > Debug**. Production builds omit the mock. Connections created
while the mock is on must be reconnected to a real provider.

#### Validate passwordless authentication locally

The default suite is local and deterministic. It needs no Google project or
account. Start the backend and Web, then run the smoke in a third terminal:

```sh
make dev-backend
pnpm --dir clients dev:web
pnpm --dir clients smoke:auth:local
```

With the same backend running, the Electron smoke tests the renderer, preload,
Main, and local API path. The test is opt-in:

```sh
pnpm --dir clients smoke:auth:electron:local
```

A real Google sign-in is an optional manual canary. Use one Web OAuth Client ID
per environment:

| Runtime     | Google Cloud boundary                             | OAuth client | Authorized JavaScript origins    |
| ----------- | ------------------------------------------------- | ------------ | -------------------------------- |
| Local Web   | Development/testing project                       | Web: Dev     | `http://127.0.0.1:5174`          |
| Staging Web | Development/testing project, or dedicated staging | Web: Staging | `https://app-staging.comma.surf` |
| Production  | Production/publishing project                     | Web: Prod    | `https://app.comma.surf`         |

Production must be in a separate Google project from development and testing.
Never add localhost or staging origins to the production OAuth client. Origins
are exact `scheme + host + port` values. The GIS callback flow needs no
redirect URI or client secret.

The local stack uses `127.0.0.1` for Web and API so the `SameSite=Lax` cookie
is same-site. Do not mix `localhost` and `127.0.0.1` in one login flow.

To run the Web canary, add the Google account as a test user while the
development project is in Testing:

```sh
COMMA_GOOGLE_WEB_CLIENT_ID="YOUR_DEV_WEB_CLIENT_ID" make dev
```

Electron needs a separate **Desktop app** client for non-production and for
production:

```sh
COMMA_GOOGLE_ELECTRON_CLIENT_ID="YOUR_DEV_DESKTOP_CLIENT_ID" \
COMMA_GOOGLE_ELECTRON_CLIENT_SECRET="YOUR_DEV_DESKTOP_CLIENT_SECRET" \
make dev-electron
```

The Comma backend exchanges the Desktop authorization code. The Desktop client
secret stays in server configuration and is never bundled into Electron.
Restart the backend after you change the client ID or secret. See Google's
[GIS Web client setup](https://developers.google.com/identity/gsi/web/guides/get-google-api-clientid)
and [production OAuth policy](https://developers.google.com/identity/protocols/oauth2/production-readiness/policy-compliance).

#### Local LLM

The default local LLM is deterministic. It needs no provider key:

- Send an ordinary Chat message. The reply contains `LOCAL_CHAT_OK`.
- Send `LOCAL_CREATE_TASK`. A Task card appears, opens by its public Comma
  conversation ID, and reaches `completed` with `LOCAL_TASK_DONE`.

#### Use a real LLM locally

Keep real-provider credentials in the ignored `.local/` directory. Do not put an
API key in `systems/config/compose-dev.json`, a tracked Compose file, or a Salix
Template record. The Template references an environment variable through
`api_key_env`.

Create the two private files from the repository root:

```sh
mkdir -p .local
cp systems/config/compose-dev.json .local/compose-dev-real-llm.json
chmod 600 .local/compose-dev-real-llm.json
```

In `.local/compose-dev-real-llm.json`, replace only `llm.default_template`. For
an OpenAI-compatible Responses endpoint:

```json
{
  "template_id": "comma-local-dev",
  "name": "Comma Local Dev Real LLM",
  "model": "YOUR_MODEL",
  "provider": "openai",
  "max_tokens": 2048,
  "context_tokens": 200000,
  "provider_config": {
    "protocol": "responses",
    "base_url": "YOUR_APPROVED_PROVIDER_BASE_URL",
    "api_key_env": "COMMA_REAL_LLM_API_KEY"
  }
}
```

Put the credential in `.local/comma-real-llm.env` and restrict it:

```dotenv
COMMA_REAL_LLM_API_KEY=YOUR_LOCAL_PROVIDER_KEY
```

```sh
chmod 600 .local/comma-real-llm.env
make dev-real-llm
# or: make dev-electron-real-llm
```

`systems/docker-compose.devcontainer.real-llm.yml` only mounts those ignored
files. It holds no credentials.

The local data volume keeps the journaled Template. If the checkout was seeded
with the mock, the mounted JSON does not replace the existing `comma-local-dev`
Template. Reset the local volumes before you switch providers:

```sh
docker compose \
  -f systems/docker-compose.dev.yml \
  -f systems/docker-compose.devcontainer.yml \
  down -v
make dev-real-llm
```

This deletes only local Compose data. If replies still contain
`LOCAL_CHAT_OK`, the mock Template is still in the volume. If the provider
returns `401`, check that `api_key_env` matches the variable name in
`.local/comma-real-llm.env`. Do not print the rendered Compose configuration,
because it expands `env_file` secrets.

#### Client processes and local data

`make dev` and `make dev-electron` run the client in the foreground. Ctrl-C
stops the client and leaves the backend running. Web uses port `5174` and
Electron Forge uses `5173`. When the backend already runs, use
`pnpm --dir clients dev:web` and `pnpm --dir clients dev:electron`.

With several worktrees open, quit other `Comma Dev` Electron processes before an
Electron smoke. macOS can keep an older build under the same name and app-data
location.

To reset all local data and rerun every migration:

```sh
docker compose \
  -f systems/docker-compose.dev.yml \
  -f systems/docker-compose.devcontainer.yml \
  down -v
make dev-systems-up
```

The default Compose scope is `salix,comma_product`. This stack does not fake
the BridgeForTeams dashboard or real external providers. For BFT Dashboard
work, see [Bridge For Teams](../docs/bridge-for-teams/design.md). For the Agent
configuration handoff after migrations, see
[Local model switching](../docs/development.md#local-model-switching).

#### Host-native setup

Install the libsodium, Opus, and libsrtp2 headers, `pkg-config`, and a Rust
toolchain (`brew install libsodium opus srtp pkg-config rustup`, or
`apt-get install libsodium-dev libopus-dev libsrtp2-dev pkg-config` with
rustup).

```sh
# MinIO on :19000 with buckets salix-dev + salix-test
minio server /tmp/minio --address :19000 &
aws --endpoint-url http://127.0.0.1:19000 s3 mb s3://salix-dev
aws --endpoint-url http://127.0.0.1:19000 s3 mb s3://salix-test

mix deps.get
mix test                       # full suite (fake backend + real MinIO)
mix run --no-halt              # API on :4000, transfer on :4400
```

Salix loads runtime config from `/etc/salix/config.json` or
`systems/config.json`. Keep a local `systems/config.json` private (`0600`) and
untracked. Use [`config/config.example.json`](config/config.example.json) for
committed examples. Set `SALIX_CONFIG_PATH=/absolute/path/to/config.json` to
use another config file.

The platform VM configuration is `ctl/vm/default_config.json`, managed from
the Salix dashboard or `/v1/admin/vm/default-config`. When it is absent, Salix
uses the top-level `vm` section of the config JSON. Comma workspaces use the
platform configuration. A BridgeForTeams tenant with its own VM config keeps
it, unless an operator sets `vm.config_source` to `"platform"`. A tenant with
no VM config uses the platform configuration. Sprites is retired.

Call the API:

```sh
curl -X POST localhost:4000/v1/comma/admin/users \
  -H 'authorization: Bearer test-token' \
  -H 'content-type: application/json' \
  -d '{"email":"demo@example.com"}'
```

This uses the deployment bearer. Human admins use
[Comma Admin Web](../docs/identity-security.md). Its commands require a
server-derived Admin actor, a reason, target-bound confirmation, idempotency,
and durable redacted audit evidence.

New Comma Workspaces default to `vm.enabled: true`. Explicit
`vm.enabled: false` is kept. In Comma Admin, **Users → Workspace & billing →
Cloud VM** sets the value for a ready Workspace. A change requires an audited
reason and target-bound confirmation, and queues the Workspace convergence job.
Configuration sync is not VM readiness. Salix removes the shared VM only when
no other agent or runtime installation intent needs it.

Real rounds need provider configuration in the agent's Template
(`protocol`, `model`, `base_url`, and `api_key` or `api_key_env`). There is no
cluster-wide fallback key. Without a key, the round fails at the provider and
settles with an LLM-error message.

#### Verbose JSONL logging

The log is disabled by default. Enable it with `--log-file <path>`, or with
`log.file` in config.json for a release:

```sh
mix run --no-halt -- --log-file salix.jsonl
```

Each agent step becomes one JSON object per line. Credential-looking fields are
redacted. The logger is `CommaLog` (app `comma_log`), shared by all subsystems.

### Salix emergency agent recovery

`SalixAgent.force_recover/2` is a break-glass IEx API for an internal-runtime
agent that is stuck in a running or queued state. Run it from a trusted shell
on a prod Salix/Comma release node:

```elixir
SalixAgent.force_recover("agent_...",
  session_id: "...",
  timeout: 5_000
)
```

It stops the live runtime and session processes, repairs the durable internal
session state, appends an operator recovery message, and wakes the session on
the owning node. It does not archive, cancel, or delete the agent.

Omit `session_id:` to recover every internal session of the agent that has
pending work. To clear the stuck state without a wake, pass `wake: false`. The
session goes back to idle, and pending durable work stays for normal
activation.

The result is `{:ok, %{"agent_id" => ..., "wake_requested" => ..., "sessions" => [...]}}`.
Each session entry has its `"status"`, its event count, and its wake result,
or an `"error"`.

The API supports only Salix-managed internal runtime agents. Recover an
external runtime agent through its own control plane.

### BridgeForTeams system-admin shell operations

Run privileged bootstrap and recovery operations from an Elixir shell on a
trusted release node, or from a trusted `MIX_ENV=prod` maintenance shell with
the same database configuration. The secret is returned once. Do not persist it
outside the operator handoff.

To create a one-time organization invite code:

```elixir
{:ok, %{code: code}} =
  BridgeForTeams.OrgCreationInvites.create_invite_code(
    org_name: "Acme Co",
    org_slug: "acme-co",
    note: "initial owner for acme-co"
  )
```

Give the code to the owner. They redeem it in the dashboard signup flow to
create the organization and their owner account. The name and slug are bound to
the code. Codes are stored only as hashes and cannot be reused.

For staging smoke tests, use the manual GitHub Actions workflow
`Comma Staging Bootstrap Invite` from the trusted `main` ref. It needs no local
GKE credentials. Inputs are `org_name`, `org_slug`, `note`, and `ttl_seconds`.
Download the one-day `comma-staging-bootstrap-invite-*` artifact and open its
`signup_url` in the staging dashboard. Treat the artifact as a short-lived
secret.

To recover an account when organization SSO is misconfigured:

```elixir
{:ok, %{url: url}} =
  BridgeForTeams.AccountRecovery.create_recovery_link(
    "owner@example.com",
    base_url: "https://teams.example.com",
    note: "temporary SSO recovery"
  )
```

Send the `url` to the account owner through a trusted channel. The link signs
that account in once at `/auth/recovery`. Links are stored only as hashes,
require an active user, and cannot be reused.

### BridgeForTeams CLI

The product CLI is a standalone Go binary in `systems/cli/bft`. It needs no
Elixir or Erlang. In a source checkout:

```sh
go build -o /tmp/bft ./cli/bft/cmd/bft
/tmp/bft --help
/tmp/bft commands --json
go test -C cli/bft ./...
cli/bft/scripts/build-release.sh
```

The `BFT CLI Release` workflow publishes releases to
`${CLOUDFLARE_R2_PUBLIC_BASE_URL}/bft-cli`. The dashboard installer reads
`:bft_cli_artifact_base_url` and `:bft_cli_release_id`.

Test exit codes with the built binary. `go run` turns a non-zero exit such as
`64` into `1`.

Output modes:

- Human mode prints guided setup steps and copyable URLs.
- Agent mode prints stable JSON. Non-TTY stdout defaults to JSON. In a TTY,
  pass `--json` or `--output json`. Pass `--output text` to force text. Use
  `--limit`, `--filter`, and `--fields` to bound the output.
- Exit codes: `0` success, `2` onboarding step needs manual action, `64`
  usage or context error, `66` not found, `69` runtime unavailable, `70`
  unexpected backend error.

Pass credentials by environment variable reference (for example
`--app-secret-env BFT_FEISHU_APP_SECRET`), not as literal arguments. The CLI
redacts secret fields and secret-bearing URL query parameters in its output.

### QQ bot

A QQ open platform bot connects to one Agent Swarm. The behavior is in the
moduledocs of `SalixIM.QQInbound`, `SalixIM.Provider.QQ`,
`SalixIM.Provider.QQ.Groups`, `SalixIM.Provider.QQ.Menu`, and
`SalixIM.QQMessageRecord`.

Setup:

1. Create a bot in the QQ open platform. Copy its AppID and AppSecret.
2. Connect it on the Swarm Connections page, or with `bft qq connect`. Salix
   checks the credentials with QQ.
3. In the QQ bot console, choose Webhook delivery and save the callback address
   `<public base URL>/v1/im/qq/events?app_id=<AppID>`. Subscribe to the private
   chat, group, interaction, and group member events. QQ accepts only HTTPS on
   port 80, 443, 8080, or 8443.
4. If the console has an IP allowlist, add the deployment's egress addresses.
   Salix calls `https://api.bot.qq.com`.

Operator notes:

- Salix verifies each callback with the Ed25519 key that QQ derives from the
  AppSecret.
- A group takes proactive messages only after a group admin turns on
  "机器人主动在群聊内发言" for the bot.
- The group record has every message only when a group admin sets
  "机器人可获取的群聊消息范围" to "获取群内全部消息". Private chats are not
  recorded.
- A bare group mention uses the context QQ attached; without it, Salix reads
  up to 10 earlier recorded messages of that group (1.5-second budget, at most
  32 concurrent reads per node). The Router asks for clarification when no
  clear request is found.
- A Task created from a human QQ request posts a Markdown status card to that
  chat, and a new one on each state change (QQ cannot edit messages). Cards use
  QQ's reply allowance; later group cards need proactive-message permission.
- A command panel made in the QQ bot console replaces the Swarm's menu. Delete
  it in the console to show the menu. A Swarm admin edits shortcuts on the
  Swarm Connections page or with `bft qq menu`.
- `qq.list_members` and `qq.get_member` work only for bots on QQ's allowlist.
  Other bots get error 11253. Ask the QQ open platform to add the bot.

The record uses the Postgres outbox `qq_mirror_outbox` and the ClickHouse table
`qq_messages`. It is on wherever ClickHouse is configured.
`qq_mirror.enabled: false` in the Salix config turns it off.

### Lark bot

A custom app of the Lark open platform (`open.larksuite.com`) connects to one
Agent Swarm. A Lark connect holds its own credentials and does not use the
organization's Feishu app. The behavior is in the moduledocs of
`SalixIM.LarkInbound`, `SalixIM.Provider.Lark`, `SalixIM.Provider.Lark.Docs`,
`SalixIM.Provider.Lark.Minutes`, `SalixIM.LarkMessageRecord`, and
`SalixIM.Provider.Lark.Manual`.

Setup:

1. Create a custom app in the Lark Developer Console and add the Bot
   capability. Copy the App ID, the App Secret, and the Verification Token or
   the Encrypt Key from Events & Callbacks.
2. Connect it on the Swarm Connections page, or with `bft lark connect`.
3. In Events & Callbacks, choose "Send events to developer's server" and save
   the request URL `<public base URL>/v1/im/lark/events?app_id=<App ID>`.
   Subscribe to `im.message.receive_v1` and `im.message.recalled_v1`. Under
   Callbacks, use the same URL and subscribe to `card.action.trigger`. Without
   it, confirmation card buttons do nothing.
4. Import the scopes. Use **Copy JSON** in the Lark section of the Swarm
   Connections page, or `bft lark scopes --output text`
   (`BridgeForTeams.LarkScopes`). In Permissions & Scopes, use the batch
   import. Without `im:message.group_msg`, the bot gets only messages that
   mention it.
5. Create a version of the app and publish it. Scopes and events take effect
   with the published version.
6. Run the checks: **Run checks** on the connect's row, or
   `bft lark checks --org <org> --project <project>` (`--connect-id` for one of
   several apps). `mix bridge_for_teams.run_checks --surface lark_bot` prints
   the same result. The gates are in `SalixIM.LarkChecks`.
   `bot.first_message` and `bot.manual` are always `needs_manual`.

Security and data notes:

- Salix accepts a callback when its signature or decryption proves the Encrypt
  Key, or its token equals the Verification Token.
- A confirmation for content that crosses an audience boundary goes to the
  requester's private chat with the bot (`SalixIM.IFC.LarkConfirmation`). Only
  that person's press decides it. The press never reaches the Router.
- Information flow control reads the chat from Lark. A chat with `external` is
  shared with another tenant. A `public` group has the audience of the whole
  connect. Any other group is a room of the members that Lark lists.
- Documents and Minutes are read as the bot. The bot opens a document only when
  it is shared with a chat that includes the bot, shared with the app, or open
  by link inside the tenant. Information flow control labels reads and decides
  writes with the rules of
  [Feishu cloud documents](../docs/architecture/DOMAIN_CONCEPTS.md#feishu-cloud-documents).
- A document link must be on a `larksuite.com` host. Feishu links go to a
  Feishu connect.
- Meetings, their AI notes, transcripts and recordings are read as a person.
  People sign in with their Lark account on the swarm's Connections page
  (Accounts). Each sign-in is a Group OAuth Binding of provider `lark`
  (`SalixStore.OAuth.Adapters.Lark`); the organization's OAuth app for Lark is
  the bot's Lark app with the redirect URL `/v1/oauth/lark/callback` and the
  user scopes of the batch import. `lark.search_meetings`, `lark.get_meeting`
  and `lark.get_note` run as every signed-in account, or as the one named by
  `account`. Document and Minutes reads take the same `account` parameter.
  A unified note has no transcript document: `lark.get_note` with
  `include_transcript` reads its transcript page by page from
  `/vc/v1/notes/:id/unified_note_transcript`.
- A Worker holds the document and Minutes operations of a Lark connect and
  every read operation (chat history, threads, search, chats, members,
  directory). The Router holds all of them.
- A finished Lark meeting reaches the Router as context. A turn from that
  message calls no Lark operation
  (`SalixIM.Provider.Lark.MeetingActivationAuthorization`).
- The message record uses the outbox `lark_mirror_outbox`, the ClickHouse table
  `lark_messages`, and the switch `lark_mirror.enabled`. A recall removes the
  message from search. The record does not import history from before the
  connect.

Not connected for Lark: run checks for meetings and calendar, and the meeting
preparation and history pages of the Dashboard.

#### Lark plugin and hosted MCP

The system plugin `lark` (`Salix.Control.Plugins`) holds the Swarm's Lark
connect (`lark-im`) and `im_api.lark.*`. It adds the Lark hosted MCP server
`https://mcp.larksuite.com/mcp` (target `remote:lark`, tools `mcp.lark.*`). It
is on by default in BridgeForTeams. Comma does not list it.

- The MCP connection `lark-native` uses native MCP OAuth
  (`Salix.Control.RemoteMCPOAuth`). A Swarm admin selects **Connect** on the
  plugin page and signs in to Lark. The token is that person's Lark user token.
  It is kept on the Swarm's MCP binding, and every Agent of the Swarm uses it.
  The bot credentials are not used.
- Salix requests the same read scopes as for Feishu, plus `offline_access`.

#### Sign-in with Lark

An organization can sign members in to the Dashboard with Lark
(`BridgeForTeams.Auth.Lark`), as SSO provider `lark`. It is separate from the
provider `feishu` and from any Swarm's Lark connect. An organization has one SSO
connection, so Lark replaces Feishu or generic OIDC.

1. Create or select a custom app in the Lark Developer Console. BFT stores its
   credentials for sign-in only.
2. Open **Settings → Single sign-on**, select **Lark**, and enter the App ID
   and App Secret. The secret is write-only. A blank secret keeps the stored
   one while the provider stays Lark.
3. Copy the Redirect URI from the page (`<public base URL>/auth/callback`). In
   **Security Settings** of the Lark app, add it to the redirect URLs.
4. Select **Run checks**, or run `bft sso checks --org <org>`.
5. Sign in with a test account in a new browser session at `/login?o=<slug>`.

Rules:

- Sign-in needs no scope. Lark returns the email only with
  `contact:user.email:readonly`. Enter extra scopes on the Single sign-on page.
  The Lark app must have them.
- The login key of a member is the Lark `union_id`, or else the `open_id`, in
  one organization. The `user_id` is never the key.
- A Lark identity never matches a Feishu identity or an email. After a switch
  to Lark, members sign in as new members with the first-sign-in role.
- A change to or from Lark keeps no scope, tenant binding, or first-sign-in
  policy of the previous provider, and it needs the new secret.
- Tenant binding. Threat: a Lark app that more than one tenant can use lets a
  person of another company sign in and become a member. Authority: the
  `tenant_key` in the Lark user info, read with the server's token. The
  expected value is `provider_config["tenant_key"]` of the SSO connection. An
  operator sets it with `BridgeForTeams.Orgs.upsert_sso_connection/3`. The
  Dashboard does not write it. Owner: `BridgeForTeams.Auth` compares the two at
  each sign-in. Result: on a mismatch the person gets no session, identity, or
  membership, and Operations records `sso.login.failed` with
  `lark_tenant_mismatch`. A connection without the key has no tenant check.
  Feishu has the same check with `feishu_tenant_mismatch`.

### Bridge ToB local acceptance

Before live Feishu acceptance, configure the Feishu app and connect. See
[Feishu](../docs/bridge-for-teams/design.md#feishu).

For a setup-to-first-message smoke, start the local Systems app and the public
callback tunnel, then run:

```sh
systems/scripts/bridge_tob_acceptance_harness.sh --print-env-template
systems/scripts/bridge_tob_acceptance_harness.sh
```

The harness reads repo-local `.env` and `0600` local secret files. It checks
readiness, performs Feishu URL verification, posts a synthetic inbound event,
and reports the result.

The live smoke checks bot-visible chats and a signed callback preflight. It is
read-only by default. `BRIDGE_TOB_LIVE_FEISHU_SEND=true` sends one real
redacted message:

```sh
cd systems
mix run --no-start scripts/bridge_tob_feishu_live_smoke.exs
BRIDGE_TOB_LIVE_FEISHU_SEND=true mix run --no-start scripts/bridge_tob_feishu_live_smoke.exs
```

A first-message pass requires a real Feishu user message and the assistant
reply in the same group. Select the group by name or redacted ID prefix:

```sh
BRIDGE_TOB_LIVE_FEISHU_TARGET_CHAT_NAME="your smoke group name" \
BRIDGE_TOB_LIVE_FEISHU_TARGET_CHAT_ID_PREFIX=oc_redacted \
BRIDGE_TOB_LIVE_FEISHU_BASE_MESSAGE_COUNT=26 \
BRIDGE_TOB_LIVE_FEISHU_MARKER_PREFIX=bridge-tob-live-real-xxxx \
  mix run --no-start scripts/bridge_tob_feishu_live_smoke.exs
```

To create a dedicated smoke group in Feishu (an external side effect, off by
default):

```sh
BRIDGE_TOB_LIVE_FEISHU_CREATE_DEDICATED_GROUP=true \
  mix run --no-start scripts/bridge_tob_feishu_live_smoke.exs
```

### Test matrix

| Command                                                                                                              | What                                                                    |
| -------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `mix test`                                                                                                           | the full suite                                                          |
| `mix test --include multinode`                                                                                       | cross-node tests on two real BEAM nodes (`epmd -daemon` first)          |
| `mix test --include clickhouse`                                                                                      | analytics sink against a live ClickHouse at `127.0.0.1:8123`            |
| `mix test --include go_exporter`                                                                                     | Go-side migration exporter round-trip (needs `go`, `sqlite3`)           |
| `SALIX_E2E_LLM_API_KEY=... mix test apps/salix_agent/test/live_llm*_e2e_test.exs --include live_llm --only live_llm` | real-provider checks. `SALIX_LIVE_LLM_S3_BACKEND=aws` uses local MinIO |

CI is in `.github/workflows/systems-ci.yml`.

### Production

`mix release comma` builds the release. `Dockerfile` builds the deployable
image. Configuration comes from the environment through `config/runtime.exs`.
See [`DEPLOYMENT.md`](DEPLOYMENT.md).

## Platform telemetry

Follow the [`systems_observability` guide](apps/systems_observability/GUIDE.md)
and [Observability](../docs/observability.md).
