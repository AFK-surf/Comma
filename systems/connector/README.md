# Salix device connectors

`salix-connect` is the Go Connector for devices, Cloudflare, and managed native runtimes.
It owns the Codex and Claude runtime implementations.

Connectors expose filesystem and process operations through the shared protocol.
A device connection starts read-only. Managed cloud connections keep their existing access policy.

## How it fits

```
   connector ──WebSocket──▶ Salix node A  (owns this connector run, SalixWeb.ConnectorSocket)
                                        │  connector_run_id stamped node A
                                        ▼
   agent on node B ──env.exec tool──▶ SalixWeb.EnvDispatch ──▶ SalixEnv.Connector.Live
                                        │  record says node A
                                        ▼  :erpc to node A → SalixEnv.Bridge.rpc → WebSocket
```

The connector connects to _one_ node. Agents on _any_ node reach it.

[`docs/compute-devices.md`](../../docs/compute-devices.md) defines device and runtime identity.
The wire protocol names the live connection `connector_run_id`. External agent
binding stays on the stable device runtime.

## Run it

Comma device settings use `salix-connect --device`. This mode starts with read-only
access and discovers local agents without starting them. The user enables
operations in Settings > Devices before native agent execution. See
[Comma device settings](../../docs/compute-devices.md) for access ownership,
manual startup, and attachment-only connectors.

```sh
# Production remote connector: authenticate with a group-scoped connector credential.
go run ./salix-connect \
    --server http://127.0.0.1:4000 \
    --connector-token "$SALIX_CONNECTOR_TOKEN" \
    --name my-laptop \
    --alias my-laptop \
    --root /tmp/salix-workdir
```

On connect, the connector prints the current connector run id. The device shows in Salix
device inventory. Command and file operations go to the current online
connector run for that device.

## Runner provisioning installer

One installer prepares the local runner bundle: `salix-connect` for the
connector transport and `bft-runner` for the host-side claim and lifecycle loop.
The installer installs and verifies the artifacts, prepares the runner workdir,
writes a protected runner config, generates a launchd plist for the loop worker,
and writes a non-secret local status document. It does not load a launchd service.

BridgeForTeams org settings generate the short-lived wrapper command. The
[ops runbook](../../docs/bridge-for-teams/design.md) owns the operator procedure.
Operators do not copy raw `BFT_*` exports.

Server and Runner releases advance together.
Runner configuration uses `paths.workdir`. Launch input uses `root`, relative to that workdir or absolute.
For an old configuration, set `paths.workdir` to the existing workspace directory before you start the updated Runner.
Keep existing Connector root locations. A missing `workdir` fails before launch. The Runner does not select another data directory.
An old Runner is stale until you update it. This does not revoke independently running Connectors or delete their data.

### Install trust

The wrapper endpoint validates the install code and mints the durable runner
token when first needed. It reads the immutable descriptor bundled in the running
Server image, exports its exact per-platform URL, size, and SHA facts, and runs the
installer bundled in that same image. It does not download and execute a second shell.
The installer requires the Server-bound `salix-connect`, Agent VMM Host, and
runner targets. Missing targets fail closed. There is no catalog, `latest`,
sidecar, local-binary, or environment-derived artifact fallback.
An install code authorizes one runner identity. The Server records only the
issuing Server build as diagnostics. The script accepts `darwin-arm64`. Other
platforms fail closed until the Server image has a complete supported target set.

The script installs `salix-connect` and `bft-runner`, prepares `$BFT_WORKDIR`
(default `$BFT_INSTALL_PREFIX/work`), and writes:

- `$BFT_INSTALL_PREFIX/runner.json` with mode `0600`. It can contain the
  runner token from onboarding.
- `$BFT_INSTALL_PREFIX/runner-install-status.json` without reusable secrets.
- `$BFT_INSTALL_PREFIX/com.bridgeforteams.runner.plist` without
  reusable secrets.

The base install has no Homebrew prerequisite and skips optional local
attachment converters. To install the fallback set (`jq`, ImageMagick,
pandoc/Poppler, LibreOffice, ffmpeg, and 7-Zip), install Homebrew first and set
`BFT_INSTALL_FALLBACK_TOOLS=1`. The installer checks this option before it
downloads any release artifact.

The Server-bound Computer Use helper target installs `Comma Computer Use.app`
at `<salix-connect dir>/native/macos/`, where `salix-connect` looks for it.
One implementation replaces it: the runner's update and the installer (through
`bft-runner computer-use-helper install`). It takes a lock beside the app,
extracts the archive there, checks the SHA-256 and
`codesign --verify --deep --strict`, and exchanges the new app with the
installed one in one atomic swap (`renamex_np` with `RENAME_SWAP`; a first
install is one rename). It deletes the old app only after the swap. After a
failed swap both apps stay. A later run removes leftovers only when the
installed app passes the same checks. A running old helper is stopped;
`salix-connect` opens the new one on its next action. If the old helper does
not exit within 5 seconds, the runner reports `applied_restart_pending`.
The runner reinstalls when the heartbeat digest differs or the installed app
is missing or fails the signature check. A failed helper update does not stop
runner work. A Server release without this target leaves the installed helper
unchanged.

The helper is signed with the Developer ID. On a Mac that ran a helper with
another signature, macOS does not carry its Screen Recording and Accessibility
grants over. Grant them once by hand in that user's GUI session:
`CommaComputerUseDaemon --permissions-status` reports the current grants, and
`--permissions-ui` opens the authorization window. Nothing grants them
automatically.

### Operator commands

The installed operator entrypoint is `$BFT_INSTALL_PREFIX/bin/bft-runner`. It is a
non-secret wrapper that reads the protected runner config. Do not pass worker
flags or config paths.

```sh
"$HOME/.bridge-for-teams/bin/bft-runner" dry-run
"$HOME/.bridge-for-teams/bin/bft-runner" doctor
"$HOME/.bridge-for-teams/bin/bft-runner"
"$HOME/.bridge-for-teams/bin/bft-runner" status
"$HOME/.bridge-for-teams/bin/bft-runner" logs
```

- `dry-run` validates registration, heartbeat, claim, and connector launch
  inputs. It claims at most one request and does not start a connector.
- No subcommand: heartbeat, claim requests, and start `salix-connect`.
- `doctor` and `status` call the packaged `agent-vmm inspect` contract through
  the path that the installer recorded. They report local VMM state separately
  from the runner heartbeat and Salix admission.

`bft-runner run ...` and `bft-runner claim ...` are lower-level debug entrypoints,
not the product operation path.

The runner passes the connector credential in the child process environment, not in argv.

### Supervision

`bft-runner` restores every locally configured Connector after an unexpected
process or host interruption. There is no lifetime restart cap. A failed local
start retries on the next worker interval. An explicit BridgeForTeams stop
removes that desired state, and the runner does not recover it.
Status callbacks cannot block local supervision or heartbeat. Only a status from
a currently owned live process can report `connected`. A failed spawn stays
`connector_restart_pending`.
The runner does not claim beyond its configured local capacity. It reads the
non-secret Bridge status of the provision request, so a `connected` request
updates local status without exposing connector credentials again.

### Service and updates

The [Runner and Agent VMM Host ops runbook](../../docs/bridge-for-teams/design.md)
owns launchd setup, headless service accounts, updates, cleanup, and recovery.

For a user launch agent, the service helper keeps the explicit start, stop,
status, and remove actions. For a system service, `bft-runner` keeps status
read-only and returns the exact protected-executor action for a mutation.

1. Run the BFT installer as the selected non-root service user. The installer
   rejects root execution and system launchd inputs before it downloads artifacts.
2. Do not run the service-user-owned runner as root.
3. An administrator installs the selected Agent VMM Host release separately.
4. After the foreground smoke test, the administrator runs
   `agent-vmm-service-executor install --job runner`. This writes and starts the
   fixed BFT runner job.
5. For later service actions, use the matching `start`, `stop`, or `remove` command.

The executor does not accept the plist, program, environment, or identity values
from the config. Service removal does not remove the runner config, worker binary,
workdir, or workspace roots.

When the Server selects a new Agent VMM Host release, a login-agent runner
calls the packaged managed updater with the exact release ID, HTTPS URL,
SHA-256, size, and a stable request ID. The updater keeps the current bundle
when preparation fails. Its typed result tells the runner to continue, pause for
an exclusive transition, retry the same request at a given time, request an
administrator action, or require a terminal operator decision. Retry,
administrator, and terminal results are update advisories. They do not stop
heartbeats, observation, or claims.
A system-daemon runner reports `agent_vmm_administrator_update_required` and
continues its normal work. It does not call `sudo`. The administrator installer
uses the fixed executor for the daemon job. A post-cutover failure keeps the
previous bundle for forward repair with the same request. It does not restore
the old binary.

## Wire protocol

One JSON object per WebSocket text frame (see
`apps/salix_env/lib/salix_env/protocol.ex`):

| Direction                               | Frame                                                                                                               |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| server → connector (greeting)           | `{"type":"connected","connector_run_id":"env_…","device_id":"dev_…","connector_id":"conn_…"}`                       |
| server → connector (request)            | `{"id","type":"request","method","params"}`                                                                         |
| connector → server (ok)                 | `{"id","type":"response","result":{…}}`                                                                             |
| connector → server (error)              | `{"id","type":"error","error":"…"}`                                                                                 |
| either way (liveness)                   | `{"type":"heartbeat"}`                                                                                              |
| connector → server (on connect/refresh) | `{"type":"metadata","capabilities":{"agent_runtimes":[…],…},"skills":[…],"system_info":{…},"connector_health":{…}}` |

`system_info` carries host facts: `hostname`, `os_type`, `os_version`, `arch`,
`cpu_model`, `cpu_count`, `memory_total` (bytes), and `collected_at`.
The connector sends it on connect and then on a timer
(`--system-info-interval`, default 300s, `0` disables, env
`SALIX_CONNECTOR_SYSTEM_INFO_INTERVAL`). Salix stores it on the connector record
and shows it in the Salix and BridgeForTeams dashboards.

### Runtime status

The connector reports discovered external runtimes with version, auth readiness,
app-server readiness, and workspace readiness. A workspace failure marks every
probed runtime `workspace_unavailable`. A failed observation carries a stable
`readiness_issue` and a bounded `readiness_message`. The message never contains raw
provider output, credentials, commands, or the absolute workspace path.
`last_error` is private diagnostic evidence. It is not a fallback for public status.
Older connectors that omit `readiness_message` stay compatible.

The Server `runtime_probe` request can only select a provider and identity that
are already in the current inventory. It cannot execute a caller-supplied command.
Ordinary list renders do not probe. The metadata frame is the only durable
projection writer.

### Codex auth

The connector reads Codex account state from its app-server with the
`account/read` RPC. The runtime observation can include a bounded `auth` V1
snapshot (`status`, optional `mode`, `requires_openai_auth`, `observed_at`, and
optional stable `issue`). It never includes account identifiers, provider errors,
credentials, commands, or paths.

Full Connectors with an exact Codex inventory target advertise `runtime_auth_v1` and accept
`runtime_auth_read`, `runtime_auth_login_start`, and `runtime_auth_login_cancel`.
Login start supports the `device_code` flow. It returns only an opaque Connector
attempt id, an HTTPS verification URL, a one-time user code, and an expiry.

- The URL must be exactly `https://auth.openai.com/codex/device`.
- The Connector ceremony lasts 15 minutes. Salix and BFT reject expiries beyond
  that bound plus 60 seconds of clock skew.
- Native login ids and Codex credentials stay process-local to Codex and the Connector.
- The cancel attempt id goes in the JSON body of the fixed `.../auth/login`
  DELETE route, never in the URL or telemetry path.
- Connector read can include `attempt_id + flow + expires_at`, and cancel echoes
  `attempt_id`. Neither returns the verification URL or code. Salix and BFT
  narrow read to `auth` and cancel to `auth + canceled`, so these ids are not
  public response fields.

### Administrator auth

The provider-neutral administrator surface uses `runtime_auth_status`,
`runtime_auth_verify`, `runtime_auth_login_start`, and
`runtime_auth_input_cancel`. Each request binds an authorized actor and an
exact connected-runtime carrier. Status is a cache read and does not call a
provider. The carrier imports no credential and writes no native file.
The Connector refuses `runtime_auth_input_begin` and `runtime_auth_input_submit`.
Codex keeps its device-code read, start, and cancel contract. Claude offers one
fixed verification call for its active Anthropic or OpenRouter settings profile.
It reads only the Salix settings carrier and works with any installed Claude.
A configured API key stays unverified until that call succeeds.

| Runtime | Advertised administrator methods                         |
| ------- | -------------------------------------------------------- |
| Codex   | ChatGPT device login.                                    |
| Claude  | Explicit verification for the active fixed profile.      |

Platform, storage-policy, native-profile, and current-target checks can narrow
this list. The Connector advertises only methods that pass those checks. Callers
cannot select another provider, executable, path, endpoint, model, or settings
shape.

Auth attempts are fenced by the exact runtime generation, native login id, and
Connector attempt id. A stale observation cannot overwrite a newer auth result.
A new runtime generation does not inherit the readiness of an older generation.

### Connector health

`connector_health` is a numeric, schema-versioned snapshot of request capacity,
in-flight work, and managed processes. Timestamps are Unix epoch milliseconds.
It contains no paths, commands, identities, native ids, errors, prompts,
payloads, or credentials. Salix owns online and offline state through the
current connector run and heartbeat. Health is only a last-observed local
snapshot and stays visibly stale after disconnect.

### Methods

Main methods: `exec`, `read`, `write`, `delete`, `stat`, `list`, `glob`, `grep`,
`computer_use`, `runtime_probe`, and the `runtime_auth_*` methods above.
`dispatchSession` in `salix-connect/main.go` has the full list.
`exec` returns `{exit_code, stdout, stderr, truncated, status}` with 64 KiB
per-channel caps. File reads and writes are inline (UTF-8) up to 10 MiB.

## Legacy External Session state

Earlier releases kept External Session state under
`<state root>/external-runtime/` (`state.db` and `active/`). The current
Connector does not open or write that directory. It stays in place, never
goes into a VM workspace or durable archive, and restore skips it. Its presence
still shows that a managed Cloud VM disk admitted work before, so a
fresh-image marker cannot reset that fact.

## Reconnection

With `--reconnect` (default), the connector retries with exponential backoff and
opens a fresh connector run for the same connector identity. Runtime bindings
stay on the stable device runtime. Salix resolves them to the current online
connector run only when it dispatches work.

Salix sends a heartbeat every 15 seconds. It closes a connection when the
connector sends no heartbeat for 45 seconds. The connector closes a connection
that gets no frame for 45 seconds, then reconnects. This includes a connection
that ended without a close frame, for example after a sleep or a network change.

## Path Semantics

`--root` is the base directory for relative paths. Absolute paths resolve
as absolute OS paths. The production connector does not impose a filesystem
jail. Deploy it as a correctly scoped OS user on a machine or VM where the agent
may access the filesystem. Commands run through `/bin/sh -c` in the resolved
working directory.
