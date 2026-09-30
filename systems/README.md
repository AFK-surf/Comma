# Comma Systems

The backend runtime boundary of [Comma](../README.md): one Elixir/Mix umbrella,
one `mix release comma`, multiple **subsystems**. Each subsystem is a family of
OTP apps under [`apps/`](apps) (named `<subsystem>_*`) that are bundled into the
single release; per-node behavior emerges at runtime, not from build-time
configuration.

| Subsystem          | Apps                                            | What                                                                                                                                        |
| ------------------ | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| **Salix**          | `salix_*`                                       | The distributed, multi-tenant multi-agent runtime with optional remote VM environments (see below)                                          |
| **Comma product**    | `comma_core`, `comma_web`                           | Comma product backend/API: users, workspaces, sessions, conversations, and product policy; drives Salix through a small anti-corruption layer |
| **BridgeForTeams** | `bridge_for_teams_core`, `bridge_for_teams_web` | Parallel teams/business backend and dashboard; owns org/Agent Swarm/member/integration domain and shares the Salix runtime substrate        |

### Selecting subsystems per node

One image, one release — but a pod runs only the subsystems you select with
`COMMA_SUBSYSTEMS` (comma-separated; unset = all):

```sh
COMMA_SUBSYSTEMS=salix bin/comma start          # this pod runs only Salix
COMMA_SUBSYSTEMS=comma_product,salix bin/comma start
COMMA_SUBSYSTEMS=bridge_for_teams,salix bin/comma start
```

In the release, unselected subsystems' apps stay loaded-but-not-started; the
`:comma` launcher app starts the selected ones at boot ([`apps/comma`](apps/comma)).
An unknown subsystem name fails fast at startup. (Under `mix run`/`mix test`,
Mix starts all umbrella apps regardless — selection applies to the release.)

### Adding a subsystem

1. Drop its apps under `apps/<subsystem>_*`.
2. List them as `:load` in the release in [`mix.exs`](mix.exs)
   (`subsystem_apps/0`).
3. Register the subsystem → apps mapping in `Comma`'s `@subsystems`
   ([`apps/comma/lib/comma.ex`](apps/comma/lib/comma.ex)).

Subsystem config is keyed per-OTP-app in [`config/`](config), so it composes
without touching other subsystems.

---

## Salix

The distributed, multi-tenant multi-agent runtime with optional remote VM
environments. It uses native BEAM/OTP for process orchestration, object storage
for aggregate state and content, and PostgreSQL for queried control and
coordination data. See the current
[storage boundary](../docs/storage-search.md) and the historical
[migration record](../docs/product-features.md);
production deployment in [`DEPLOYMENT.md`](DEPLOYMENT.md).

### How it works, in one screen

Every former serializable transaction becomes: _mutate in memory → append an
immutable journal segment → CAS one per-agent `head.json` whose ETag is the
fencing token._

- **Commit protocol** (`SalixStore.Agent`): claim / commit / renew / release
  with epoch fencing — every commit revalidates the head ETag, so a stale
  owner _categorically cannot_ persist. Journal segments are keyed
  `journal/{epoch}/{seq}` and written create-once; replay resolves
  highest-epoch-per-seq, making fenced writers' orphan segments harmless.
  Snapshots bound replay; ambiguous PUTs (timeout/5xx) settle by GET-and-check
  on `commit_uuid`.
- **Delivery** (`SalixAgent.deliver/3`) is a single rpc ingress: it stages
  directly into the owner-routed role actor and acks only after the target
  session's ledger commit is durable (internal `input_dedupe`/`input_queue`,
  external `state.json` ledger) — no inbox object or queue marker exists. A
  timeout acks nothing; the caller retries with the same source id and the
  session ledger dedupes. Lost or failed wakes are rediscovered from durable
  session state via the Postgres SessionWork candidate projection, which the
  lease-gated recovery singleton sweeps to re-wake exact targets through
  placement.
- **Distribution**: one agent ⇒ one `gen_statem` somewhere in the cluster,
  placed by a libring consistent-hash ring — but placement is advisory; the
  S3 head CAS fences durable commits. Cluster singletons
  (recovery, GC, timers, schedules, analytics mirror) are S3-CAS leases, so
  every node runs the same release with no roles.
- **Agents** run the wake → round (LLM → tools → ordered commit) →
  park/passivate cycle under the lease guard; paused agents are pure S3
  objects (zero compute). Per-agent
  LLM provider config is a journaled template snapshot (anthropic /
  chat-completions / responses protocols), with global env only as fallback.

Production Salix requires object storage with conditional writes, PostgreSQL
configured through `salix.database.url`, and Redis through `REDIS_URL` or
`COMMA_REDIS_URL`. Missing database or Redis configuration rejects production
startup. PostgreSQL migrations and control-data cutover readiness must complete
before serving. See [the deployment guide](DEPLOYMENT.md) for subsystem-specific
configuration and [runtime configuration](config/runtime.exs) for startup requirements.

AWS/MinIO use S3 ETag conditionals
(`If-None-Match: *` / `If-Match: <etag>` on PUT); GCS XML API deployments must
set `storage.atomic_operations` to `"gcp"` so Salix uses object generation
preconditions instead.

### Salix apps

| App           | What                                                                                                                                                                           |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `salix_store` | Storage kernel: S3 interface (AWS SigV4 + fault-injecting fake), head-CAS protocol, journal/snapshots, blobs, leases, OAuth records, timers, spill, time travel                |
| `salix_agent` | Agent runtime: domain state machine, per-agent `gen_statem`, rounds, the tool registry, VFS, repair, compaction, LocalCache, GroupCommit, spinfoam Loops and `script.run`                 |
| `salix_web`   | HTTP API + SSE (Bandit/Plug): deliveries, transcripts, streams, HTML previews, health                                                                                          |
| `salix_im`    | IM provider connects and provider operations: internal IM, Slack/Feishu/Telegram/WeChat/voice provider manuals, inbound webhooks/pollers, outbound provider APIs, Slack file staging |
| `salix_voice` | Voice calls: one `CallActor` per call, GPT-Live model, Twilio and `comma.voice.v1` WebSocket carriers, delegation bridge, drain and metering ([contract](../docs/messaging-voice.md)) |

### Product apps

| App                     | What                                                                                                                                                                                                                                                                                                                     |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `comma`                   | Release launcher only: selects and starts subsystems from `COMMA_SUBSYSTEMS`; it intentionally has no product-domain dependencies                                                                                                                                                                                          |
| `comma_core`              | Comma product domain: accounts, sessions, workspaces, conversations, product events, and `Comma.Salix.*` runtime boundary                                                                                                                                                                                                    |
| `comma_web`               | Comma product/admin HTTP API and SSE endpoint, separate from `salix_web`                                                                                                                                                                                                                                                   |
| `bridge_for_teams_core` | BridgeForTeams commercial domain and Salix reconcile/outbox layer                                                                                                                                                                                                                                                        |
| `bridge_for_teams_web`  | BridgeForTeams dashboard                                                                                                                                                                                                                                                                                                 |
| `salix_llm`             | Provider clients: Anthropic Messages, OpenAI Chat Completions, OpenAI Responses (thinking-preserving item replay), SSE streaming, per-call provider config                                                                                                                                                               |
| `salix_cluster`         | Ring placement, recovery/GC/timers/schedules singletons, S3 leases, drain, multi-node tests                                                                                                                                                                                                                              |
| `salix_env`             | Device connector runs: connector WebSocket bridge (`SalixEnv.Bridge`/`Connector.Live`, multi-node via `:erpc`), connector-run registry, inter-node transfer server (one-time tokens), and cloud-VM providers including Sprites and the Cloudflare sandbox gateway. A real connector lives in [`connector/`](connector/). |
| `salix_media`           | Image/video generation + vision clients, per-turn caps                                                                                                                                                                                                                                                                   |
| `salix_analytics`       | Journal tailer, ClickHouse sink (ReplacingMergeTree / Cloud SharedReplacingMergeTree dedup), metering, lease-gated mirror                                                                                                                                                                                                |
| `salix_migrate`         | Go→Salix migration: import (snapshot+head materialization), one-way cutover flag, cohorts; pairs with `cmd/willow-salix-export`                                                                                                                                                                                          |
| `salix_meet`            | Meetings: group-owned worker agent lifecycle, dedicated meeting inbound, and meeting-state CAS                                                                                                                                                                                                                           |
| `salix_signal_proto`    | Pure Signal protocol core with no processes; a libsodium NIF holds the secret-dependent curve operations                                                                                                                                                                                                                 |
| `salix_signal`          | Signal runtime on top of `salix_signal_proto`: processes, storage and network |

### Getting started

The recommended team setup requires only Docker Desktop or OrbStack. The
committed [Dev Container](../.devcontainer/devcontainer.json) pins Elixir,
OTP, Node, pnpm, native build tools, and service dependencies, so team members
do not need a matching host Elixir toolchain.

For the one-click editor path, install a Dev Containers-compatible editor,
open the repository, and choose **Reopen in Container**. It automatically:

- builds the toolchain image on the first open;
- mounts the checkout at `/workspace/Comma`;
- starts MinIO, Postgres, ClickHouse, Redis, Mailpit, and the deterministic LLM;
- compiles the source-mounted backend, runs local migrations, and seeds the
  reusable developer account and Group;
- marks the service healthy only after both the Salix and Comma APIs are ready.

The toolchain image, Mix dependencies/build output, service data, and the Linux
spinfoam binary live in Docker volumes. Ordinary restarts therefore compile
only changed source and never build a Comma release image. The spinfoam volume
also keeps the container's Linux binary from overwriting the host's binary.

The same stack has a one-command path from any terminal. From the repository
root:

```sh
make dev-backend
```

The editor can attach while a first-time Mix compile is still running; follow
`make dev-systems-logs` from the host when desired. The terminal
`make dev-backend` entrypoint blocks until the service is healthy.

Useful lifecycle commands:

```sh
make dev-container-status
make dev-container-shell
make dev-container-restart  # recompile changed backend source, then wait for health
make dev-systems-logs
make dev-systems-down       # stop containers and retain every volume
```

Run `make dev-container-rebuild` only when the Dev Container Dockerfile or its
pinned toolchain changes. The first build can take several minutes; subsequent
`make dev-backend` and editor reopen operations reuse it.

Web and native Electron are still launched from the host, using host-installed
client dependencies. This avoids mixing Linux `node_modules` with the macOS
Electron toolchain:

```sh
pnpm --dir clients install # first host setup only
make dev                  # container backend + host Web on :5174
make dev-electron         # container backend + native Electron
```

The backend includes the Comma API, Salix runtime, local migration bootstrap,
MinIO, Postgres, ClickHouse, Redis, Mailpit, and a deterministic local LLM.
After it is ready, these checks should succeed:

```sh
curl http://127.0.0.1:4000/health   # Salix API
curl http://127.0.0.1:4200/health   # Comma product API
nc -vz 127.0.0.1 4400               # transfer server
```

The source-mode entrypoint runs ClickHouse and Comma/Postgres migrations before
starting the serving apps. On a completely empty local database, its
development-only bootstrap also records the empty legacy-import boundary and
executes the required Comma schema cutover. That path is guarded to
`MIX_ENV=dev`, `COMMA_ENVIRONMENT=local`, the local database name, and empty
product tables; it fails closed rather than touching populated or remote data.
Release containers continue to use the normal one-shot `comma-migrate` service.

The stack exposes:

| Service              | Local address                                       |
| -------------------- | --------------------------------------------------- |
| Salix API/dashboard  | `http://127.0.0.1:4000`                             |
| Comma product API      | `http://127.0.0.1:4200`                             |
| Salix transfer       | `127.0.0.1:4400`                                    |
| Mailpit inbox / SMTP | `http://127.0.0.1:8025` / `127.0.0.1:1025`          |
| MinIO API / console  | `http://127.0.0.1:19000` / `http://127.0.0.1:19001` |
| Postgres             | `127.0.0.1:15432`                                   |
| ClickHouse HTTP      | `http://127.0.0.1:18123`                            |

#### Run isolated Salix-only sandboxes in parallel

For Salix backend work that does not need the Comma product, each worktree can run
an independent Compose project. Only Salix HTTP and transfer are published to
the host; Postgres, MinIO, Redis, ClickHouse, and the deterministic LLM mock use
their default ports on the project's private network.

```sh
make salix-dev-up
make salix-dev-info
```

The worktree path determines a stable project suffix and two host ports. The
command prints the assigned API, dashboard, and transfer addresses. Override
the readable label or either port when necessary. Before creating containers,
the command refuses to start if either host port belongs to another service:

```sh
SALIX_DEV_ID=router-memory \
SALIX_DEV_HTTP_PORT=25001 \
SALIX_DEV_TRANSFER_PORT=45001 \
make salix-dev-up
```

There is deliberately no source watcher. After changing Salix code, rebuild
the image, stop the old Salix process, run the one-shot migration, and start the
new Salix release explicitly; dependency containers and their named volumes
remain running and in place:

```sh
make salix-dev-rebuild
make salix-dev-logs
```

Useful lifecycle commands:

```sh
make salix-dev-status  # addresses plus container health
make salix-dev-psql    # psql inside this worktree's private Postgres
make salix-dev-shell   # shell inside the running Salix release container
make salix-dev-down    # stop containers, keep data
make salix-dev-reset   # delete only this worktree's containers and volumes
```

Generated configuration lives under `.local/salix-dev/` and is ignored by
Git. An optional `compose.override.yml` in the generated project directory
applies to all lifecycle commands. Use it for local integration services and
private environment files. Keep these files in the ignored project directory.
Repeat explicit port overrides when you run lifecycle commands. Salix reaches dependencies through Compose DNS (`postgres:5432`,
`minio:9000`, `redis:6379`, `clickhouse:8123`); none of those ports is bound on
the host. The transfer listener remains on container port `4400`, while the
generated `transfer.advertise_port` carries its mapped host port in URLs used
for Salix node-to-node byte transfer when a peer reaches this sandbox through
the host mapping. Salix Connector does not use this endpoint; connector traffic
continues to use its JSON/frame stream.

#### Inspect the complete Salix system prompt

Dump a complete prompt through the production composer without starting Salix
or reading S3, Postgres, agent control records, plugins, IM connects, or MCP
bindings:

```sh
cd systems
mix salix.prompt.dump
mix salix.prompt.dump --role worker --runtime external --no-skill
mix salix.prompt.dump --agent-prompt "Additional diagnostic instructions"
```

The default emulation is an internal Router with its full role-eligible static
tool registry, a valid synthetic agent identity, one representative projected
skill, and diagnostic agent instructions. Dynamic provider operations are
absent because there are no emulated live connections. In an OTP release, use
the same renderer through:

```sh
bin/comma eval 'SalixAgent.Release.dump_system_prompt()'
```

The Dev Container seeds automatically before it becomes healthy.
`make dev-systems-seed` is an idempotent manual rerun: it creates or reuses
`comma-local@example.com`, its generated default Workspace and Salix Group
Router/Worker, a 20M local credit grant, and the user Chat. It prints the
generated Workspace ID and an API session token for curl or other local tooling.
`make dev-electron` stores that Session in the gitignored
`.local/comma-dev-session.json` and signs the unpackaged client in through its
normal Main-owned Session startup path; Electron Forge Main restarts re-read
the same file. Web, or Electron launched directly with
`pnpm --dir clients dev:electron`, still use the real passwordless login flow:
request a code for that email and read it from Mailpit.

Local Compose builds include the recommendation mock capability, but it starts
disabled. Start the ordinary local stack and toggle it from **Settings > Debug**:

```sh
make dev-systems-up
```

The Dev Container passes `COMMA_LOCAL_RECOMMENDATION_MOCK=true` while compiling
the source checkout. Production release builds still default that compile-time
capability to `false`, so they omit the mock implementation and routes. The
Debug switch changes the process-local runtime state without rebuilding.
Enabling it exercises the
production recommendation boundaries around the mock: Comma Web discovers a
group-scoped Composio connection, its bounded server collector executes the
fixed read-only recipe, the hidden recommendation renderer receives only those
collected facts and publishes through the validated, persisted recommendation
protocol, and Comma Center reads the result. The renderer is not disclosed
Composio, MCP, IM, discovery, web, or other source tools, and this flow neither
creates nor calls an MCP binding. Disabling the mock restores the original
provider targets; connections created while mock mode was enabled must be
reconnected to a real provider.

When that local grant is exhausted, explicitly advance its generation to issue
one more idempotent 20M grant through the same audited redeem-code API:

```sh
COMMA_LOCAL_CREDIT_GRANT_GENERATION=2 make dev-systems-seed
```

Increment the generation for each later top-up. Repeating the same generation
does not issue another grant.

#### Validate passwordless authentication locally

The default acceptance suite is fully local and deterministic. It does **not**
need a Google Cloud project or a real Google account: repository tests cover the
Web GIS callback and backend OIDC discovery, JWKS rotation, signature, audience,
nonce, and expiry with local providers. The live Web smoke below covers Email
OTP, cookie custody, revocation, and Workspace bootstrap; it does not pretend to
perform a real Google sign-in.

Start the backend and Web in separate terminals, then run the auth smoke from a
third terminal:

```sh
make dev-backend
pnpm --dir clients dev:web
pnpm --dir clients smoke:auth:local
```

The smoke uses the real local Comma API, Redis, SMTP/Mailpit, PostgreSQL, and a
browser. It requests a unique Email OTP, proves HttpOnly cookie custody and
token-free renderer state, reloads and revokes the Session, then proves the
owner-only Workspace reaches `ready` and repeated bootstrap returns the same
Workspace. It signs out its test Session before exiting. Stop the backend with
`make dev-systems-down`; this keeps the local volumes.

With the same backend running, the Electron smoke exercises the real renderer →
preload → Main → local Comma API path and reads its OTP from Mailpit:

```sh
pnpm --dir clients smoke:auth:electron:local
```

It builds Electron, proves Main owns OTP request/verification and the bearer,
waits for the owner Workspace, reloads, then signs out and replays the captured
Main-held bearer directly against the server to prove it changed from `200` to
`401`. The bearer is read only by the Playwright test process from Electron's
temporary `safeStorage` envelope; it never enters renderer state or test output.
The test is opt-in, so ordinary client E2E remains deterministic when the local
backend is not running.

A real Google sign-in is an optional manual canary, not a prerequisite for the
deterministic suite. Comma uses one Web OAuth Client ID per environment so a
development origin or revoked credential cannot affect production:

| Runtime     | Google Cloud boundary                             | OAuth client | Authorized JavaScript origins  |
| ----------- | ------------------------------------------------- | ------------ | ------------------------------ |
| Local Web   | Development/testing project                       | Web: Dev     | `http://127.0.0.1:5174`        |
| Staging Web | Development/testing project, or dedicated staging | Web: Staging | `https://app-staging.comma.surf` |
| Production  | Production/publishing project                     | Web: Prod    | `https://app.comma.surf`         |

This means three Web Client IDs are the recommended Comma layout, but the Google
policy boundary is that production must be in a separate project from
development/testing. Never add localhost or staging origins to the production
OAuth client. Origins are exact `scheme + host + port` values with no wildcard.
The GIS JavaScript callback flow does not need a Web redirect URI or a client
secret.

The checked-in local stack uses `127.0.0.1` for both Web and API so its
host-only `SameSite=Lax` cookie is same-site. If you intentionally use
`http://localhost:5174`, also expose/configure the API as
`http://localhost:4200` and register that exact Web origin; do not mix
`localhost` with `127.0.0.1` in one login flow.

To run the optional Web canary, add the Google account as a test user when the
development project's audience is still in Testing, then start the local stack
with the public Dev Client ID:

```sh
COMMA_GOOGLE_WEB_CLIENT_ID="YOUR_DEV_WEB_CLIENT_ID" make dev
```

Electron is a different OAuth application type. Create a **Desktop app** client
for the non-production build (and a separate production Desktop client), then
run its optional canary with:

```sh
COMMA_GOOGLE_ELECTRON_CLIENT_ID="YOUR_DEV_DESKTOP_CLIENT_ID" \
COMMA_GOOGLE_ELECTRON_CLIENT_SECRET="YOUR_DEV_DESKTOP_CLIENT_SECRET" \
make dev-electron
```

The Desktop flow uses the system browser plus a random loopback callback and
exchanges the one-time authorization code on the Comma backend. The matching
Desktop OAuth client secret stays in server configuration and is never bundled
into Electron; Comma uses it only because Google's token endpoint requires it for
this client registration. Restart the backend after changing the client ID or
secret. See Google's [GIS Web client setup](https://developers.google.com/identity/gsi/web/guides/get-google-api-clientid)
and [production OAuth policy](https://developers.google.com/identity/protocols/oauth2/production-readiness/policy-compliance).

The seed command rejects a non-loopback `COMMA_LOCAL_API_BASE_URL` by default
because it mutates users, sessions, workspaces, billing grants, and Chat data.
Only an intentional remote-data operation may opt in with
`COMMA_LOCAL_DEV_SEED_ALLOW_NON_LOOPBACK=I_UNDERSTAND_THIS_MUTATES_REMOTE_DATA`;
never set that variable for ordinary local development.

The default local LLM is intentionally deterministic, so local Chat and Task
testing never waits on a provider key or spends money:

- Send an ordinary Chat message and wait for a reply containing
  `LOCAL_CHAT_OK`.
- Send `LOCAL_CREATE_TASK` and verify a Task card appears, opens by its public
  Comma conversation ID, and reaches `completed` with `LOCAL_TASK_DONE`.
- The mock has a hard 20-visible-send cap and treats Worker self-delivery as a
  no-op, so a faulty local scenario cannot create an unbounded reply loop.

#### Use a real LLM locally

Real-provider credentials stay in the ignored `.local/` directory. Do not put
an API key in `systems/config/compose-dev.json`, a tracked Compose file, or a
Salix Template record. The Template should reference an environment variable
through `api_key_env` instead.

Create the two private files from the repository root:

```sh
mkdir -p .local
cp systems/config/compose-dev.json .local/compose-dev-real-llm.json
chmod 600 .local/compose-dev-real-llm.json
```

In `.local/compose-dev-real-llm.json`, replace only
`llm.default_template` with the approved provider settings. For an
OpenAI-compatible Responses endpoint, the shape is:

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

Put the matching credential in `.local/comma-real-llm.env`:

```dotenv
COMMA_REAL_LLM_API_KEY=YOUR_LOCAL_PROVIDER_KEY
```

Then restrict its permissions:

```sh
chmod 600 .local/comma-real-llm.env
```

Then start Web or Electron with the fixed entrypoint:

```sh
make dev-real-llm
# or: make dev-electron-real-llm
```

The committed `systems/docker-compose.devcontainer.real-llm.yml` only mounts
those ignored files into the source-mode Dev Container; it contains no
credentials. The default mock container may still run, but the Router and
Worker use the Template mounted from `.local/compose-dev-real-llm.json`.

Salix Templates are journaled in the local data volume. If this checkout has
already been seeded with the deterministic mock, changing the mounted JSON
does not rewrite the existing `comma-local-dev` Template. Reset the disposable
local volumes before switching providers, then start again:

```sh
docker compose \
  -f systems/docker-compose.dev.yml \
  -f systems/docker-compose.devcontainer.yml \
  down -v
make dev-real-llm
```

This deletes only local Compose data. A successful real-provider smoke should
answer a non-deterministic Chat prompt, create a Router-requested Worker Task,
and return the Worker result without `401` or provider errors in the `comma`
logs. If replies still contain `LOCAL_CHAT_OK`, the old mock Template is still
present in the volume. If the provider returns `401`, verify that
`api_key_env` exactly matches the variable name in
`.local/comma-real-llm.env`; do not print the rendered Compose configuration
because it expands `env_file` secrets.

`make dev` and `make dev-electron` own the client process in the foreground;
Ctrl-C stops that client while leaving the Docker backend available for the
next run. `make dev-electron` seeds and auto-signs in the local developer
through the unpackaged client's shared startup Session path. Local development
and E2E both write the seed through `SecureSessionStore` and then run
`SessionService.initialize`; E2E profile isolation and Connector fixtures do
not participate in authentication. The local launcher uses the normal Comma Dev
profile and selects real per-workspace Connector supervision by leaving the
explicit E2E Connector fixture unset.
Web is fixed to `5174` so Electron Forge can keep its renderer dev server on
`5173`; both clients use the local Comma API defaults without manual environment
variables. If the backend is already running, the frontend-native entrypoints
are `pnpm --dir clients dev:web` and `pnpm --dir clients dev:electron`; the
direct Electron command keeps the ordinary manual login flow.

When several Comma worktrees are open, quit other `Comma Dev`/Electron processes
before an Electron smoke. macOS can otherwise leave an older build running
under the same display name and shared app-data location, which makes the
smoke inspect the wrong binary or stale local database. Confirm the process
path points at this checkout when diagnosing an unexpected schema error.

Use `make dev-systems-logs` to follow the Comma and mock-LLM logs and
`make dev-systems-down` to stop without deleting state. To deliberately reset
all local data and rerun every migration from an empty store:

```sh
docker compose \
  -f systems/docker-compose.dev.yml \
  -f systems/docker-compose.devcontainer.yml \
  down -v
make dev-systems-up
```

The default compose scope is the complete Comma product path
(`salix,comma_product`). BridgeForTeams dashboard/onboarding and real external
providers are separate integration environments; they are not silently faked
by this stack.

For persistent BFT Dashboard development, follow the
[BFT local development guide](../docs/bridge-for-teams/design.md).
It includes the explicit Agent configuration handoff required after migrations.

For a host-native setup, install the libsodium headers and `pkg-config` first
(`brew install libsodium pkg-config` or `apt-get install libsodium-dev
pkg-config`); the `salix_signal_proto` NIF links libsodium.

```sh
# MinIO on :19000 with buckets salix-dev + salix-test
minio server /tmp/minio --address :19000 &
aws --endpoint-url http://127.0.0.1:19000 s3 mb s3://salix-dev
aws --endpoint-url http://127.0.0.1:19000 s3 mb s3://salix-test

mix deps.get
mix test                       # full suite (fake backend + real MinIO)
mix run --no-halt              # API on :4000, transfer on :4400
```

Runtime config is loaded from `/etc/salix/config.json` or `systems/config.json`
when present. Keep local `systems/config.json` private (`0600`) and untracked;
use [`config/config.example.json`](config/config.example.json) for committed
examples. Set `SALIX_CONFIG_PATH=/absolute/path/to/config.json` when a local
run should use an isolated config file without touching `systems/config.json`.

The top-level `vm` section in config JSON is the deployment's platform VM
configuration. It may define Sprites and Cloudflare providers and is consumed by
Comma workspaces directly. BridgeForTeams organizations do not inherit that
platform config by default: a tenant must either provide organization-owned
`vm.providers` config, or be explicitly marked with `vm.config_source` set to
`"platform"` by an operator. Legacy tenant `"sprites"` config is treated as
organization-owned VM config for migration compatibility.

Talk to it:

```sh
curl -X POST localhost:4000/v1/comma/admin/users \
  -H 'authorization: Bearer test-token' \
  -H 'content-type: application/json' \
  -d '{"email":"demo@example.com"}'
```

This curl demonstrates the deployment-bearer compatibility path. The separately
deployed human [Comma Admin Web](../docs/identity-security.md) uses its
path-scoped Cookie origin for the documented query and named command allowlists.
Human commands additionally require a server-derived Admin actor, reason,
target-bound confirmation, idempotency, and durable redacted audit evidence.

New Comma Workspaces default to `vm.enabled: true` and use the configured platform
VM provider. Explicit `vm.enabled: false` is preserved; existing Workspaces are
not migrated. In Comma Admin, **Users → Workspace & billing → Cloud VM** exposes
the desired setting for each ready Workspace. Changes require an audited reason
and target-bound confirmation, preserve the Workspace's provider choice, and
queue the existing Workspace convergence job rather than calling the VM provider
inline. Configuration sync is not VM readiness. Disabling updates the Router and
default Worker; the shared VM is only removed when no other agents or runtime
installation intents require it.

Set `ANTHROPIC_API_KEY` (or a per-agent template via
Salix agent templates/control records — protocol/model/base_url/api_key — for real
rounds; without a key, rounds settle with an LLM-error message.

### Salix emergency agent recovery

`SalixAgent.force_recover/2` is a break-glass IEx API for an internal-runtime
agent that is stuck in a running or queued state and is not making progress.
Run it from a trusted shell on a prod Salix/Comma release node.

Pasteable form:

```elixir
agent_id = "agent_..."
session_id = "..."

SalixAgent.force_recover(agent_id,
  session_id: session_id,
  timeout: 5_000
)
```

The API stops the live runtime/session processes, repairs the durable internal
session state, appends an operator recovery delivery, and wakes the session on
the owning node. It does not archive, cancel, or delete the agent. The default
target status is `:queued`, so the recovered session should immediately resume
from durable state.

When the exact session is unknown, omit `session_id:` to recover all active,
queued, or waiting internal sessions for the agent:

```elixir
SalixAgent.force_recover("agent_...", timeout: 5_000)
```

To park a stuck session without resuming it, pass `status: :idle`:

```elixir
SalixAgent.force_recover("agent_...",
  session_id: "...",
  status: :idle,
  timeout: 5_000
)
```

Expected success shape:

```elixir
{:ok,
 %{
   "agent_id" => "agent_...",
   "status" => "queued",
   "sessions" => [
     %{"session_id" => "...", "status" => "queued", "events" => n}
   ]
 }}
```

This API currently supports Salix-managed internal runtime agents. For external
runtime agents, recover the external runtime/session through its dedicated
control plane instead of this function.

### BridgeForTeams system-admin shell operations

BridgeForTeams keeps privileged bootstrap and recovery operations out of the
dashboard. A system admin should run them from an Elixir shell on a trusted
release node or from a trusted `MIX_ENV=prod` maintenance shell with the same
database configuration. The generated secret is returned once; do not persist it
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

Give the code to the intended owner. They redeem it at the dashboard signup
flow to create both the organization and their owner account. The organization
name and slug are bound to the invite code; the owner cannot change the slug
while redeeming it. Invite codes default to a 30-day expiry, are stored only as
hashes, and cannot be reused. Useful options are `:ttl_seconds`, `:expires_at`,
`:note`, and, for tests only, `:code`.

For staging mini-machine smoke tests, prefer the manual GitHub Actions workflow
`Comma Staging Bootstrap Invite` instead of requiring local GKE credentials. Run
it from the trusted `main` ref with:

- `org_name`: the staging organization display name.
- `org_slug`: the staging organization slug.

### BridgeForTeams CLI

BridgeForTeams has a terminal entrypoint for admin and agent workflows. The
distributed product CLI lives in `systems/cli/bft` and builds to a standalone Go
binary, so customer/admin machines do not need Elixir/Erlang installed. In a
source checkout:

```sh
go build -o /tmp/bft ./cli/bft/cmd/bft
/tmp/bft --help
go test -C cli/bft ./...
cli/bft/scripts/build-release.sh
```

Release artifacts are published by the `BFT CLI Release` GitHub workflow to
`${CLOUDFLARE_R2_PUBLIC_BASE_URL}/bft-cli`. Comma deployments consume that fixed
release path through hidden environment configuration. The dashboard
installer example uses `https://releases.example.com/bft-cli` and `latest`. The runtime
maps those values to `:bft_cli_artifact_base_url` / `:bft_cli_release_id` for
the dashboard installer.

Use the built binary when validating non-zero exit codes. `go run` wraps
program exits such as `64` as a Go tool failure and the shell sees `1`, which is
not the installed `bft` behavior.

The older `systems/bin/bft` / `mix bft` Elixir entrypoint has been retired.
Use the built Go binary for CLI behavior and the backend `/v1/cli/*` tests for
server-side contract coverage.

The CLI has two output modes:

- Human mode prints guided setup steps and copyable URLs.
- Agent mode uses stable JSON plus exit codes. Non-TTY stdout defaults to JSON;
  in a TTY, pass `--json` or `--output json`. Use `--output text` to force
  human text in redirected or piped runs. Exit codes are `0` success, `2`
  onboarding step needs manual action, `64` usage/context error, `66` not
  found, `69` runtime unavailable, `70` unexpected backend error. Use `--limit`
  and `--filter` on list commands to keep agent context bounded, and
  `--fields mode,commands` to project only selected top-level JSON data fields.

Common commands:

```sh
/tmp/bft agent help onboarding --json
/tmp/bft commands --json --fields mode,commands
/tmp/bft auth login --url <bft-api-base-url> --output text
/tmp/bft orgs list --limit 20 --filter acme
/tmp/bft projects list --org acme --limit 20
/tmp/bft context --org acme --project bridge --json
/tmp/bft conversations redeliver \
  --org acme --project bridge \
  --conversation cnv1_... --participant ptp1_... --message msg1_... \
  --request recovery-20260722-1 --confirm-mutating --json

/tmp/bft feishu app upsert \
  --org acme \
  --app-id cli_app \
  --bot \
  --app-secret-env BFT_FEISHU_APP_SECRET \
  --verification-token-env BFT_FEISHU_VERIFICATION_TOKEN \
  --confirm-mutating

/tmp/bft feishu connect ensure --org acme --project bridge --app-id cli_app --confirm-mutating --json
/tmp/bft feishu checks --org acme --project bridge --json
/tmp/bft onboarding smoke --step cli-login --org acme --json
/tmp/bft onboarding smoke --step feishu-cli --lark-cli lark-cli --assist-lark-app-init --json
/tmp/bft slack setup --org acme --project bridge --json
/tmp/bft completion zsh
```

Credential values should be passed by environment variable reference, not as
literal command-line arguments. The CLI redacts secret fields and secret-bearing
URL query parameters before printing human or JSON output.

- `note`: why the invite was minted.
- `ttl_seconds`: invite lifetime; defaults to 24 hours and is capped at seven days.

After the workflow finishes, download the one-day
`comma-staging-bootstrap-invite-*` artifact and open the `signup_url` value in the
staging dashboard. The workflow masks the URL for logs and does not print the raw
invite code during normal execution; treat the artifact as a short-lived secret.

To recover an existing account when organization SSO is misconfigured:

```elixir
{:ok, %{url: url}} =
  BridgeForTeams.AccountRecovery.create_recovery_link(
    "owner@example.com",
    base_url: "https://teams.example.com",
    note: "temporary SSO recovery"
  )
```

Send the generated `url` to the account owner through a trusted channel. The
link signs that account in once at `/auth/recovery`, then marks the recovery
token used before issuing a normal dashboard session. Recovery links default to
a one-hour expiry, are stored only as hashes, require an active existing user,
and cannot be reused. `create_recovery_link/2` accepts a `%User{}`, user id, or
email address; useful options are `:base_url`, `:ttl_seconds`, `:expires_at`,
`:note`, and, for tests only, `:token`.

### Bridge ToB local acceptance

Before running live Feishu acceptance, configure the Feishu app/connect using
the BridgeForTeams [Feishu Setup Runbook](../docs/bridge-for-teams/design.md).
That runbook lists the required credentials, permissions/events, manual Feishu
admin steps, automated Bridge/Salix probes, Q&A, and troubleshooting matrix.

For a reusable BridgeForTeams → Salix Feishu setup-to-first-message smoke, use
the repo-local acceptance harness after the local Systems app and public
callback/tunnel are already running:

```sh
systems/scripts/bridge_tob_acceptance_harness.sh --print-env-template
systems/scripts/bridge_tob_acceptance_harness.sh
```

The harness reads repo-local `.env` plus 0600 local secret files, checks Salix
and public callback readiness, performs Feishu URL verification, posts a
synthetic group-message-style inbound event, and reports the observed result.
It intentionally owns the acceptance scenario rather than the full dev
environment lifecycle.

For an explicitly live Feishu follow-up after the app/tenant is configured,
the optional live smoke can verify bot-visible chats and run a signed public
callback preflight with the active runtime connect. When the callback rejects
the signed preflight, the result includes a redacted `failure_code` and
`next_action` (for example, synchronizing the Feishu console Verification Token
or Encrypt Key with the runtime connect). Only when explicitly enabled does it
send one real redacted outbound smoke message:

```sh
cd systems
mix run --no-start scripts/bridge_tob_feishu_live_smoke.exs
BRIDGE_TOB_LIVE_FEISHU_SEND=true mix run --no-start scripts/bridge_tob_feishu_live_smoke.exs
```

The default mode is read-only. The signed callback preflight is synthetic and
does not prove a human-inbound first message; send mode proves real outbound
only. A user-visible first-message pass requires a real Feishu-sourced user
message followed by the assistant reply in that same group. Use the target chat
name or redacted ID prefix to select the group. Other marker, browser-surface,
screenshot, and report inputs are optional diagnostics and do not change that
pass condition:

```sh
BRIDGE_TOB_LIVE_FEISHU_TARGET_CHAT_NAME="your smoke group name" \
BRIDGE_TOB_LIVE_FEISHU_TARGET_CHAT_ID_PREFIX=oc_redacted \
BRIDGE_TOB_LIVE_FEISHU_BASE_MESSAGE_COUNT=26 \
BRIDGE_TOB_LIVE_FEISHU_MARKER_PREFIX=bridge-tob-live-real-xxxx \
  mix run --no-start scripts/bridge_tob_feishu_live_smoke.exs
```

When the only bot-visible chat is a bot p2p conversation or no suitable group is
available, the live smoke can optionally create a dedicated smoke group using
the visible member as the human member. This external Feishu side effect is
disabled by default and must be explicitly enabled:

```sh
BRIDGE_TOB_LIVE_FEISHU_CREATE_DEDICATED_GROUP=true \
  mix run --no-start scripts/bridge_tob_feishu_live_smoke.exs
```

#### Verbose JSONL logging

Disabled by default; enable with `--log-file <path>`:

```sh
mix run --no-halt -- --log-file salix.jsonl
```

(equivalently `SALIX_LOG_FILE=salix.jsonl` or `log.file` in config.json — the
release-friendly forms). Every agent step becomes one JSON object per line:
claim / wake / delivery staging, each LLM request and response, each tool
execution (args, result, duration), every journal commit (event types, epoch,
seq, outcome), park / passivate. Long strings are truncated and
credential-looking fields (`api_key`, `token`, …) are redacted. The logger is
the shared `CommaLog` (app `comma_log`), used by every subsystem.

### Test matrix

| Command                                                                                                              | What                                                                                                                                                                         |
| -------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `mix test`                                                                                                           | the full suite — unit, property (stateful S3-CAS linearizability), chaos (fault injection), integration                                                                      |
| `mix test --include multinode`                                                                                       | cross-node head-CAS fencing on two real BEAM nodes sharing MinIO (`epmd -daemon` first)                                                                                      |
| `mix test --include clickhouse`                                                                                      | analytics sink against a live ClickHouse at `127.0.0.1:8123`                                                                                                                 |
| `mix test --include go_exporter`                                                                                     | Go-side migration exporter round-trip (needs `go`, `sqlite3`)                                                                                                                |
| `SALIX_E2E_LLM_API_KEY=... mix test apps/salix_agent/test/live_llm*_e2e_test.exs --include live_llm --only live_llm` | real OpenCode Go `deepseek-v4-flash` checks for provider/runtime, Chat/Task semantics, and dynamic integrations; set `SALIX_LIVE_LLM_S3_BACKEND=aws` to exercise local MinIO |

CI (`.github/workflows/systems-ci.yml`) runs the suite against a MinIO
container, the multi-node test, and a ClickHouse service on every PR touching
`systems/**`. Pull requests skip the credentialed live-LLM shards; main pushes
and manual dispatches run them against MinIO as diagnostic evidence because the
external endpoint and model can be unavailable. `systems-docker.yml` publishes
the systems image to `ghcr.io/<owner>/<repo>`.

### Production

`mix release comma` builds the single everything-included release;
`Dockerfile` produces the deployable image (release + the pinned spinfoam binary).
Configuration is environment-driven via `config/runtime.exs` — see
[`DEPLOYMENT.md`](DEPLOYMENT.md) for the env reference, S3/IAM requirements,
Kubernetes/compose sketches, drain semantics, and the migration runbook.

## Platform telemetry

Feature authors must follow the
[`systems_observability` guide](apps/systems_observability/GUIDE.md). Stable
metric/query contracts live in the
[metric catalog](../docs/observability.md), and deployment,
failure handling, rollout, and the future Grafana boundary are documented in
[platform telemetry](../docs/observability.md).
