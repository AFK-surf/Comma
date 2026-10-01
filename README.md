# Comma

### The sessionless, relentless personal agent.

[![Comma: the open-source, sessionless, relentless personal agent for macOS and Web](.github/assets/readme-banner.webp)](https://comma.surf/download)

Comma is an open-source personal agent built to be sessionless. Your work, memory, and context stay continuous across your computer, phone, cloud environment, applications, and connected devices.

It breaks down your goals into Tasks and keeps working through agentic loops until the job is done.

Built by AFK Inc., Comma is our attempt to create an open agentic system that keeps you away from software — and away from the keyboard.

You can use the hosted service at [comma.surf](https://comma.surf), or run your own instance from this repository.

## See Comma in action

### No more applications.

Hand over your work and life. Comma gets it done.

![No more applications.](.github/assets/no-applications-cover.png)

### Personal context, aligned.

Save money. Shop smarter based on your preferences. Check out on your trusted device.

![Personal context, aligned.](.github/assets/trusted-device-cover.png)

## Philosophy

- **Sessionless**
  - Conversations are just interfaces. **Tasks are the persistent execution state.**
  - Your memory, context, and ongoing Tasks continue across devices, conversations, and interfaces.
  - You should never have to choose the “right” session, or worry that starting a new conversation will lose unfinished work.

- **Relentless**
  - Comma is always on and works 24/7.
  - Tasks are automatically turned into independent agent loops that plan, execute, review, and verify until the goal is completed.
  - The goal stays alive until it's done.

- **Swarm Intelligence**
  - Comma automatically distributes work across agents and models with different strengths.
  - Smaller independent contexts reduce compression, drift, and context corruption.
  - You manage the goal, not the swarm.

- **Works with your existing agents**
  - Codex, Claude Code, and other agents can be invoked like applications or registered as Workers and Sub-agents.
  - Keep your existing tools and workflows; let Comma orchestrate and automate them.

- **Cloud for work. Your device for identity.**
  - Comma uses its own environment for long-running work, while sensitive identity, sessions, payments, and private data can stay on your devices.
  - When needed, Comma hands the Task to your computer or phone and continues from where it left off.

## What Comma does

- **Turns requests into Tasks.** A quick question gets an answer in chat.
  Bigger work becomes a Task. Comma checks its own work and decides when the
  Task is done.
- **Waits for your decisions.** When a decision is yours, the Task waits in
  Needs Review. Comma does the rest on its own, or only drafts if you prefer.
- **Shows all work on one board.** Tasks move through Backlog, In progress,
  Needs Review, and Done.
- **Writes first.** When something needs you, Comma tells you in chat and
  suggests the next step. Routines give you a briefing at the time you set.
- **Keeps watch with Loops.** A Loop is a small program that your agent writes.
  It watches an inbox, a repository, or a feed, and wakes the agent only when
  something needs it. A quiet hour uses no large-model tokens.
- **Works on your computers.** Salix connects your Mac. Comma can read files
  there. When you turn on Allow operations, it can also change files, run
  commands, and hand work to Codex, Claude Code, Pi, or Kimi.
- **Records your calls.** The Mac app can record a call, save it to Drive, and
  start a summary Task.
- **Uses your models.** Bring your own API key, or a ChatGPT or Claude plan.

## Built with Elixir and Lean. Verified with Lean and TLA+.

Comma is built for long-running, fault-tolerant agent workloads. Its runtime is primarily built with **Elixir/OTP**, with **Lean** used for critical systems components. Important runtime properties are specified and machine-checked in Lean, and we use **TLA+** to model-check core distributed protocols.

Each agent runs as its own process on the Erlang VM. When one part fails, it restarts, and the other agents keep running. Messages that Salix has accepted survive the restart. An interrupted action that changes something does not run again on its own.

The formal models check properties such as:

- accepted work is not silently lost across failures and restarts;
- a failed reply does not count as completed work;
- side-effecting actions are recorded before they start;
- an interrupted mutating action is not accidentally executed twice;
- stale workers cannot overwrite newer agent state;
- data only crosses boundaries where policy allows it.

Formal verification does not prove model judgment or task success. It verifies something more fundamental: **the runtime behaves according to the rules we designed, even when things fail.**

For a sessionless agent, reliability is not an infrastructure detail. **It is part of the product.**

See [Verification](docs/verification.md) and the [TLA+ models](tla/).

## Self-host with Docker Compose

The root `compose.yaml` starts a complete single-node instance. It builds the
Web client, the Admin client, and the server from source. It also starts
PostgreSQL, Redis, MinIO, ClickHouse, and Mailpit, a local email inbox. You do
not need a Comma account or a private repository token.

### Requirements

- Docker Engine with Compose v2.24 or later.
- Enough disk space for the build layers. The first build downloads public
  toolchains, including Lean, Elixir, Go, and Node.
- A model provider account for real model calls. The default stack does not
  include a mock model.

### First start

1. Copy the example configuration:

   ```sh
   cp .env.example .env
   ```

2. Set `COMMA_OWNER_EMAIL` to your email address. This account gets Admin
   access.
3. Set your model provider in `.env`, or skip this step and configure a
   private model in Settings after login.
4. Build and start the stack:

   ```sh
   docker compose up -d --build
   ```

5. Open <http://localhost:8080> and request a login code with your email
   address.
6. Read the code in the local inbox at <http://localhost:8025>.

The first start generates persistent secrets and initializes empty stores. By
default, all public ports bind to loopback only.

### Configuration

| Variable | Purpose |
|---|---|
| `COMMA_OWNER_EMAIL` | First owner account and Admin access |
| `COMMA_ALLOW_SIGNUP` | Public registration, off by default |
| `COMMA_LLM_BASE_URL` | Model provider endpoint |
| `COMMA_LLM_PROTOCOL` | Provider protocol, such as `chat_completions` |
| `COMMA_LLM_MODEL` | Provider model ID |
| `COMMA_LLM_API_KEY` | Provider credential |
| `COMMA_LLM_CONTEXT_TOKENS` | Model context budget |
| `COMMA_LLM_MAX_TOKENS` | Output token limit |
| `COMMA_EXA_API_KEY` | Optional Exa key for web search and page reading |
| `COMMA_SMTP_*` | Mail server for login codes |
| `COMMA_PUBLIC_URL`, `COMMA_API_URL`, `COMMA_ADMIN_URL`, `COMMA_SALIX_URL` | Browser origins |

Model calls use your provider account and can cause provider charges. A
self-hosted instance does not need Stripe or Comma credits.

### Interfaces

| Interface | Default address |
|---|---|
| Comma Web | <http://localhost:8080> |
| Comma Admin | <http://localhost:8082> |
| Comma Product API | <http://localhost:8081> |
| Salix dashboard | <http://localhost:4000/dash> |
| Local inbox | <http://localhost:8025> |

### Public access

For a public instance, put Comma behind your HTTPS reverse proxy. Web, Admin,
and the Product API must use different origins on one registrable domain, for
example `app.example.com`, `admin.example.com`, and `api.example.com`. Set a
real SMTP server. The local inbox is for loopback use only, because anyone who
can read it can use its login codes.

### Features that need external accounts

Agents, Tasks, object storage, search, and subscription-account storage run
inside the stack. To let Comma run commands on your own computer, connect the
computer from the device settings. Group cloud computers need a Cloudflare
configuration. Meetings and Agent VMM hosts need runtimes that this repository
does not include.

### Upgrades and backups

Stop the stack before an upgrade. Back up all five named volumes together:
`config`, `postgres`, `objects`, `clickhouse`, and `redis`. The `config` volume
holds the encryption key and authentication secrets. Do not delete it or
regenerate its secrets. `docker compose down` keeps your data. Do not add `-v`
unless you want to delete the instance.

Read the [self-hosting guide](systems/DEPLOYMENT.md#self-hosted-compose) before
public deployment, upgrades, or restores.

## Repository layout

```text
clients/        # Web and Electron clients and shared React packages
systems/        # Elixir umbrella for Salix, the Comma product, and Bridge For Teams
selfhost/       # Self-hosting configuration and storage images
docs/           # Engineering contracts
tla/            # TLA+ models of core distributed protocols
```

## Development

Install the client dependencies once, then start the local backend and the Web
client:

```sh
pnpm install
make dev
```

`make dev` uses a deterministic mock model, so you do not need a model key. Sign
in as `comma-local@example.com` and read the code in Mailpit at
<http://127.0.0.1:8025>. Use `make dev-electron` for the Mac app. Run the tests
from the repository root:

```sh
make test-clients
make test-systems
make test-policy
```

Start with these documents:

- [systems/README.md](systems/README.md): the backend, the Dev Container, and
  local setup.
- [docs/development.md](docs/development.md): everyday development workflows.
- [docs/README.md](docs/README.md): the index of engineering contracts.
- [docs/architecture/README.md](docs/architecture/README.md): the architecture
  overview.

## Security

Report a vulnerability to <support@comma.surf>. See the
[security page](https://comma.surf/security) for details.

## License and contributions

Comma's original code is licensed under [AGPL-3.0-only](LICENSE). Third-party
components keep their own licenses. If you serve a modified version, keep the
`/source.tar.gz` download available.

Contributions require the [AFK AI, Inc. CLA](CLA.md). See
[CONTRIBUTING.md](CONTRIBUTING.md).
