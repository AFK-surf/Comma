# Comma

Comma is a personal agent that works 24/7. You ask once, and Comma carries the
work to done.

Comma runs in the Mac app, in the browser, and in your chats on Signal,
Telegram, and WeChat. It works in your connected apps and files, on your Mac,
and on its own cloud computer. The agent harness, Salix, keeps your agent
running and calls a large model only when the work needs one.

You can use the hosted service at [comma.surf](https://comma.surf), or run your
own instance from this repository.

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

## How Salix is built

Salix is written in Elixir and Lean. Each agent runs as its own process on the
Erlang VM. When one part fails, it restarts, and the other agents keep running.
Messages that Salix has accepted survive the restart. An interrupted action that
changes something does not run again on its own.

The core of the agent loop is Lean code, and a machine checks its proofs. The
proofs show that Salix keeps accepted work through failures and restarts. They
show that a failed reply does not count as done, and that Salix records each
action that changes something before it starts that action. Salix starts each
such action at most once. The proofs also check that data goes only where it is
allowed. They rest on stated assumptions about the code around the kernel. They
do not prove storage, model judgment, or task success. See
[Verification](docs/verification.md).

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
