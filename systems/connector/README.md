# Salix device connectors

`salix-connect` is the Go Connector for devices, Cloudflare, and managed native runtimes.
It owns the Codex, Pi, Kimi, and Claude protocol implementations.

The two-node integration test runs the Go binary.

Connectors expose filesystem and process operations through the shared protocol.
A device connection starts read-only. Managed cloud connections retain their existing access policy.

## How it fits

```
   connector ──WebSocket──▶ Salix node A  (owns this connector run, SalixWeb.ConnectorSocket)
                                        │  connector_run_id stamped node A
                                        ▼
   agent on node B ──env.exec tool──▶ SalixWeb.EnvDispatch ──▶ SalixEnv.Connector.Live
                                        │  record says node A
                                        ▼  :erpc to node A → SalixEnv.Bridge.rpc → WebSocket
```

The connector connects to _one_ node; agents on _any_ node reach it. This
replaces willow's NATS `env.<env_id>.req` bridge with BEAM distribution.

Device and runtime identity are defined in
[`docs/compute-devices.md`](../../docs/compute-devices.md).
The wire protocol names the live connection `connector_run_id`; external agent
binding stays on the stable device runtime.

## Run it

Comma device settings use `salix-connect --device`. This mode defaults to read-only
access and discovers local agents without starting them. The user enables
operations in Settings > Devices before native agent execution. See
[Comma device settings](../../docs/compute-devices.md) for access ownership,
manual startup, and the difference from attachment-only connectors.

````sh
# Production remote connector: authenticate with a group-scoped connector credential.
	go run ./salix-connect \
	    --server http://127.0.0.1:4000 \
	    --connector-token "$SALIX_CONNECTOR_TOKEN" \
	    --name my-laptop \
	    --alias my-laptop \
	    --root /tmp/salix-workdir

````

## Runner provisioning installer

The runner onboarding path uses one installer to prepare the local bundle:
`salix-connect` for the connector transport and `bft-runner` for the
host-side claim and lifecycle loop. The installer does not merge those
concepts or load a launchd service by itself; it installs/verifies the
artifacts, prepares the runner workdir, writes a protected runner config,
generates a launchd plist for the loop worker, and emits a non-secret local
status document.

BridgeForTeams org settings generate the short-lived wrapper command. The
[ops runbook](../../docs/bridge-for-teams/design.md) owns its
operator procedure. Operators do not copy raw `BFT_*` exports.

Server and Runner releases advance together. Runner-only Fin fields are retired.
Runner configuration uses `paths.workdir`. Launch input uses `root`, relative to that workdir or absolute.
For an old configuration, set `paths.workdir` to the existing workspace directory before starting the updated Runner.
Keep existing Connector root locations. Missing `workdir` fails before launch instead of selecting another data directory.
An old Runner is stale until updated. This does not revoke independently running Connectors or delete their data.

The wrapper endpoint validates the install code, lazy-mints the durable runner
token, reads the immutable descriptor bundled in the running Server image,
exports its exact per-platform URL/size/SHA facts, and runs the installer
bundled in that same image. It does not download and execute a second shell.
The installer requires the Server-bound `salix-connect`, Agent VMM Host, and
runner targets; missing targets fail closed. There is no catalog, `latest`,
sidecar, local-binary, or environment-derived artifact fallback.

After install, the safe dry-run form validates registration, heartbeat, claim,
and connector launch inputs without starting the connector:

```sh
"$HOME/.bridge-for-teams/bin/bft-runner" dry-run
```

The installer also writes a local `bft-runner` command under
`$BFT_INSTALL_PREFIX/bin`. It is a thin, non-secret wrapper around the installed
worker and the protected config path, so day-two operator commands stay short:

```sh
"$HOME/.bridge-for-teams/bin/bft-runner" doctor
"$HOME/.bridge-for-teams/bin/bft-runner"
"$HOME/.bridge-for-teams/bin/bft-runner" status
"$HOME/.bridge-for-teams/bin/bft-runner" logs
```

The `doctor` and `status` commands invoke the packaged managed
`agent-vmm inspect` contract through the path recorded by the installer.
The commands report local VMM state separately from the runner heartbeat and
Salix admission. The runner does not parse launchd, Host, or Guest state
itself. It still owns its process status, Group connectors, and local runner
logs.

`bft-runner` keeps heartbeating, claims pending requests, starts
`salix-connect`, and keeps restoring every locally configured Connector after
an unexpected process or host interruption. There is no lifetime restart cap:
one failed local start is retried on the next bounded worker interval. An
explicit BridgeForTeams stop removes that desired state and is not recovered.
Recovery status callbacks after an unexpected exit are asynchronous
observations; rejection or control-plane unavailability cannot block local
supervision or heartbeat, including while initial Server registration is
unavailable. Before each process generation starts, the runner invalidates the
previous generation's status file; only a status emitted by a currently owned
live process can project `connected`. A failed spawn therefore remains
`connector_restart_pending` without a stale PID or Connector run id. The runner
refreshes ready child-exit facts after blocking heartbeat/update and no-content
claim responses before reading a status file or projecting local state, so a
child that exited during the wait cannot be reported as connected from a stale
process handle. These refreshes do not spawn: the full ensure pass still runs
once per bounded control iteration.
The runner does not claim beyond the local configured capacity while it is
already maintaining desired connectors. It also observes the provision
request's non-secret Bridge status so a registry-reconciled `connected`
request updates local status without re-exposing connector credentials.

The [Runner and Agent VMM Host ops runbook](../../docs/bridge-for-teams/design.md)
owns launchd setup, headless service accounts, updates, cleanup, and recovery.
This README only defines installer and connector behavior.

The base managed install has no Homebrew prerequisite and skips optional local
attachment converters. To provision the exact fallback set (`jq`, ImageMagick,
pandoc/Poppler, LibreOffice, ffmpeg, and 7-Zip), install Homebrew first and set
`BFT_INSTALL_FALLBACK_TOOLS=1`. That opt-in is preflighted before any release
artifact is downloaded; converter binaries remain discoverable through the
generated launchd `PATH`.

For a user launch agent, the service helper retains the existing explicit
start, stop, status, and remove actions. For a system service, `bft-runner`
keeps status read-only and returns the exact protected-executor action for a
mutation. Run the BFT installer as the selected non-root service user. It
rejects root execution and system launchd inputs before it downloads release
artifacts. Do not run the service-user-owned runner as root. An administrator
must install the selected Agent VMM Host release separately. After the
foreground smoke test, run `agent-vmm-service-executor install --job runner`.
This action writes and starts the fixed BFT runner job. Later service actions
use the matching `start`, `stop`, or `remove` command.
The executor does not accept the config's plist, program, environment, or
identity values. Service removal does not remove the runner
config, worker binary, workdir, or workspace roots. The older installer
launchd gates remain for user-agent service control.

When the Server selects a new Agent VMM Host release, a login-agent runner
invokes the packaged managed updater with the exact release ID, HTTPS URL,
SHA-256, size, and a stable request ID. The updater preserves the current bundle
when preparation fails. Its typed result tells the runner to continue normal
work, pause for an exclusive transition, retry the same request at a reported
time, request an administrator action, or require a terminal operator decision.
Retry, administrator, and terminal results remain nested update advisories;
they do not stop heartbeats, observation, or claims. An invalid or nonzero CLI
result becomes a bounded terminal advisory instead of a process restart loop.
A system-daemon runner reports
`agent_vmm_administrator_update_required` and continues its normal work. It
does not invoke `sudo`. The administrator installer uses the fixed executor for
the daemon job and the lifecycle owner for the state-preserving cutover. A
post-cutover failure retains the previous bundle for forward repair with the
same request; it does not restore the old binary.

The BFT HTTPS wrapper serves the installer bundled in the BFT Server image; it
does not download and execute a second remote shell. An install code authorizes
one runner identity and records only the issuing Server build as diagnostics.
At install time the script accepts `darwin-arm64`; other platforms fail closed
until the Server image contains a complete supported target set. The script
installs the connector artifact as `salix-connect`, installs the worker as
`bft-runner`, prepares
`$BFT_WORKDIR` (default `$BFT_INSTALL_PREFIX/work`), and writes:

- `$BFT_INSTALL_PREFIX/runner.json` with mode `0600`; may include the
  runner token when supplied by onboarding.
- `$BFT_INSTALL_PREFIX/runner-install-status.json` without reusable secrets.
- `$BFT_INSTALL_PREFIX/com.bridgeforteams.runner.plist` without
  reusable secrets.

The installed operator entrypoint is `bft-runner`. Normal users and operators do
not pass worker flags or config paths; the wrapper reads the protected
runner config written by the installer. `bft-runner dry-run` claims at most
one request without starting a connector, while `bft-runner` keeps
heartbeating, claims requests, and starts `salix-connect`. The connector
credential is passed in the child process environment, not in argv.

The lower-level worker entrypoints remain available through `bft-runner run ...`
and `bft-runner claim ...` for debugging, but they are not the product operation
path.

    On connect it prints the current connector run id. The device appears in Salix
    device inventory, and command/file operations dispatch to the current online
    connector run for that device.

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

`system_info` carries host facts — `hostname`, `os_type`, `os_version`, `arch`,
`cpu_model`, `cpu_count`, `memory_total` (bytes), and a `collected_at`
timestamp. It is reported on connect and then refreshed on a timer
(`--system-info-interval`, default 300s; `0` disables; env
`SALIX_CONNECTOR_SYSTEM_INFO_INTERVAL`) by re-sending the metadata frame. Salix
persists it into the connector record (with a `system_info_updated_at` stamp)
and surfaces it in the Salix and BridgeForTeams dashboards.

The connector also reports discovered external runtimes. Codex runtime identity
is generated from the normalized Codex CLI command path. Version, auth
readiness, app-server readiness, and the ability to prepare the Connector-owned
external workspace root are reported as runtime status metadata. Initial,
initial and operator probes evaluate that workspace precondition; a
failure marks every probed runtime `workspace_unavailable` even if its native
handshake succeeds. A metadata cache read never retries workspace preparation,
while the next real probe can restore `available` after the workspace recovers.
Failed observations also carry an owner-normalized `readiness_message` beside
the stable `readiness_issue`. That message is bounded, displayable diagnostic
detail; it never contains raw provider output, credentials, commands, or the
absolute workspace path. `last_error` remains private diagnostic evidence and
is not a fallback for public status. Older connectors that omit
`readiness_message` remain compatible.

Every native runtime keeps the Connector-assigned session workspace as its cwd.
Codex, Pi, and Kimi also receive the Connector root as `SALIX_ENV_ROOT`, the
absolute Connector-managed tool executable as `SALIX_CLI`, and the same
host-workspace instructions. External runtime prompts invoke `"$SALIX_CLI"`
directly so a provider login shell cannot lose the tool when it resets `PATH`.
An empty session workspace therefore does not make a provider guess project
context from temporary directories or another session.

One process-local inventory owns the latest observations: initial connection
and the Server `runtime_probe` request update that cache, then publish metadata.
The periodic system-info heartbeat republishes the cache without starting
external processes. Metadata assembly itself is a side-effect-free cache read.
An exact probe can only select a provider and identity already in the current
inventory; it cannot execute a caller-supplied command. Same-target probes share
one in-flight result, all probes use a two-slot global limit, and the refreshed
metadata frame is sent before the request response. Probe trigger and duration
are frame-scoped evidence: the cache strips them, one singleflight publisher
reports them once, and waiters do not return before that publication completes.
Cached session or health metadata therefore cannot replay runtime-probe metrics.
When external-session admission encounters an expired observation, the Server
may issue this exact-target request once and use its fresh response for that
admission. A fresh unavailable result is not retried and ordinary list renders
do not probe. The metadata frame remains the sole durable projection writer.

Codex account state is read from the Connector-owned app-server with the
structured `account/read` RPC. The runtime observation may include a bounded
`auth` V1 snapshot (`status`, optional `mode`, `requires_openai_auth`,
`observed_at`, and optional stable `issue`); it never includes account
identifiers, provider errors, credentials, commands, or paths. Full Connectors
with an exact Codex inventory target advertise `runtime_auth_v1` and accept
`runtime_auth_read`, `runtime_auth_login_start`, and
`runtime_auth_login_cancel`. Login start supports the remote-safe
`device_code` flow and returns only an opaque Connector attempt id, HTTPS
verification URL, one-time user code, and expiry. The URL must be exactly
`https://auth.openai.com/codex/device`; the Connector ceremony lasts 15 minutes,
and Salix/BFT reject future expiries beyond that bound plus 60 seconds of clock
skew. Native login ids and Codex credentials remain process-local to
Codex/Connector. The cancel attempt id is carried in the JSON body of the fixed
`.../auth/login` DELETE route, never in the URL or telemetry path.
Connector read may include the complete active correlation tuple
`attempt_id + flow + expires_at`, and Connector cancel echoes `attempt_id`;
neither returns the verification URL/code. Salix/BFT narrow read to `auth` and
cancel to `auth + canceled`, so these internal correlation ids do not become
public response fields.

The provider-neutral administrator surface uses `runtime_auth_status`,
`runtime_auth_verify`, `runtime_auth_login_start`, and the bounded
`runtime_auth_input_begin|submit|cancel` transition family. Each request binds
an authorized actor and an exact Compute Workload or connected-runtime carrier.
The browser seals private material directly to the target's in-memory HPKE key;
the Server transports only the envelope and bounded offer/receipt projections.
Status is a cache read and does not call a provider. Pi and Claude expose only
the methods supported by their pinned native versions and current profile;
credential import and Claude authorization-code completion are restricted to
an owned Compute runtime because a connected user CLI has no exclusive native
writer. Connected targets remain available for status and supported explicit
verification. Codex keeps its legacy public device-code read/start/cancel
contract. A configured API key remains unverified until one explicit, fixed
small native verification call succeeds.

The shipped capability matrix is versioned with the runtime bundle:

| Runtime | Packaged version | Advertised administrator methods                                                                                                                                                                                   |
| ------- | ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Codex   | 0.153.0          | ChatGPT device login; owned Compute `auth.json` import for ChatGPT/OpenAI; OpenAI API-key import.                                                                                                                  |
| Pi      | 0.84.4           | Owned Compute: OpenRouter API-key or one native auth-entry import. All targets: explicit OpenRouter verification when a supported profile exists.                                                                  |
| Claude  | 2.1.258          | Owned Compute: Anthropic authorization-code login on Linux, fixed Anthropic/OpenRouter settings import, and Linux native credentials-file import. All targets: explicit verification for the active fixed profile. |

Platform, storage-policy, native-profile, and current-target checks may narrow
this list. The Connector advertises only methods that pass those checks; callers
cannot select another provider, executable, path, endpoint, model, or settings
shape.

Attempts are fenced by the exact runtime generation, native login id, and
Connector attempt id, use separate two-slot admission within the ordinary
request bound, and publish safe state immediately. A dispatched start whose
transport result is ambiguous publishes a terminal error before its generation
fence. Any fence of an already published active/pending attempt atomically
clears that attempt and publishes its terminal error first; an invalid ceremony
rejected before pending publication cannot leave a cached pending owner. The
fence then removes and terminates an unbound generation so the next auth
request starts fresh. If an external-runtime session is attached, the
generation stays current and running but is quarantined from auth admission,
auth notification, auth snapshot publication, and full-probe commit; ordinary
session RPC and the advertised runtime capability remain available and are not
rebound.

A WebSocket connect failure or ambiguous initialize result instead makes the
exact generation unusable for both auth and ordinary RPC. The Connector
publishes `auth_probe_failed`, removes that generation from admission, and
terminates it without waiting while normal session recovery may install and
bind a replacement. A late close callback for the retired generation may clear
only references that still point to it; it cannot clear a replacement session
or auth attempt.

An incremental `account/read`/notification is authentication evidence, not a
complete runtime-readiness probe. It may preserve cached overall readiness only
after a full probe of the same exact process generation committed while auth
was ready. Non-ready auth invalidates that proof, and a new generation cannot
inherit an older generation's ready/model result; it remains unavailable with
`runtime_probe_failed` until its own full probe commits. Full-probe commits are
also fenced by exact generation and auth epoch so stale observations cannot
overwrite a newer auth publication. The former feature-level models are
[retired historical evidence](../../tla/connector/README.md); runtime tests now
protect these contracts.

`connector_health` is an eleven-field, numeric, schema-versioned snapshot. Its
timestamps are Unix epoch milliseconds; its counters cover request/runtime-proxy
capacity and in-flight work, managed processes, recoverable native sessions, and
durable input/event backlog. It contains no paths, commands, identities, native
ids, errors, prompts, payloads, or credentials. Salix owns online/offline state
through the current connector run and heartbeat; health is only a last-observed
local snapshot and remains visibly stale after disconnect.

Each discovered runtime observation also carries a bounded `session_snapshot`
derived by the existing external-runtime recovery owner. A durable `watch` adds
the Salix product `session_id`, a successful durable `forget` removes it, and
startup `load` rebuilds the projection from validated recovery records. Native
settled or Server lifecycle state does not change membership. Failed
`watch/forget` persistence leaves the previous committed snapshot unchanged.
Metadata reads the in-memory projection and never rescans bbolt, workspaces,
transcripts, or provider-native threads.

Recovery records are assigned only when their exact `provider + command` matches
an inventory observation's `provider + identity_material`; the connector never
guesses another runtime for an unmatched record. Each snapshot contains only:

```json
{
  "schema_version": 1,
  "observed_at": 1780000000000,
  "session_count": 2,
  "session_ids": ["ses1_0000000000000000928", "ses1_0000000000000000929"],
  "truncated": false
}
```

Product session ids are canonical, unique, and sorted. At most 64 ids are sent
per runtime and at most 256 per metadata frame. Runtimes are ordered by
`(provider, identity_material)` before the global budget is assigned; every
runtime whose full set is not present reports the complete `session_count` and
`truncated=true`. The snapshot does not include agent, task, conversation,
dispatch/execution, lifecycle, command, identity material, workspace, model,
token, prompt, payload, error, or provider-native session identity. Session
ownership changes enqueue metadata through the same bounded/coalesced publisher;
reconnect replays the cache and process restart rebuilds it from durable state.
Salix binds each accepted snapshot to the current device connection generation.
If a newly connected legacy Connector omits snapshots, the retained runtime can
still be addressed, but its public session projection is `not_reported` and
empty rather than inheriting ids from the previous generation. Salix validates
the complete runtime list before normalization (map/type safety, 32-runtime
bound, unique targets, and nested snapshot bounds) and atomically retains the
previous legal record when any entry is invalid.

Salix treats connector metadata as untrusted. Before replacing the current
device record it validates the exact schema, millisecond timestamp, canonical
unique sorted ids, count/truncation consistency, per-runtime and per-frame caps,
and the snapshot's attachment to an exact runtime observation. An invalid frame
does not partially update or clear the previous valid device projection. The
Server creates no runtime work/session index: the tenant-scoped `/sessions`
operation and device page read only this bounded last-observed device record and
do not infer task ownership or external session lifecycle.

## External runtime recovery

`salix-connect` owns native-session recovery locally; the Server does not start
or coordinate recovery. After a native session has been created, the Connector
persists two separate facts in `<root>/external-runtime/state.db` (directory
mode `0700`, database mode `0600`). `session-identities-v2` keeps the long-lived
resumable identity: provider, Salix session id, exact native payload, command,
and workspace. `active-executions-v2` is sparse and exists only while work is
starting, running, interrupted, or settling. Its version 3 record owns the
current dispatch, native execution ID, exact Compute target, Host acquisition,
terminal event, and release state. Both buckets have one bbolt transaction owner, but identity
existence alone is never interpreted as a recovery obligation. The same
database owns the durable `input-batches-v1` inbox and
`session-events-v1` runtime-event outbox in separate buckets; it is
connector-local and excluded from VM workspace archives. The
legacy `external-runtime/active/` path is excluded as well. Updating
one session is a single bbolt transaction and never scans or rewrites the other
sessions. Identity records do not store capabilities, prompts, current
execution, the input queue, messages, or transcript. Once an identity exists,
its command, workspace, and native payload remain authoritative; a later input
cannot replace or rebind them. Input batches are
persisted before the connector returns its
durable-local ACK and remain until the native runtime accepts the complete
batch, including when that ACK never reaches the Server. Treat the database as
secret because it contains live session capabilities and pending input; do not
copy it into logs or evidence.

Normal online input remains Server push. After each Server transport generation
becomes ready, the Connector sends exactly one payload-free
`agent_runtime_catchup` hint. Salix scopes the existing unfinished-session
candidate keyset to the authenticated group, re-reads each authoritative
Session, checks its exact token and stable device binding, and wakes the normal
Session owner. The response contains no session, message, queue, or history
data; the Connector neither polls nor stores a Server delivery cursor. Actual
input still arrives through `agent_runtime_input` and is committed to
`input-batches-v1` before ACK. The bounded one-shot pass only shortens recovery
for Server-queued input missed while offline; normal singleton recovery remains
the completeness fallback.

An explicit provider verification can make a runtime ready after that
connection-level hint has already completed. Once Salix has persisted a fresh
`agent_runtimes` snapshot, each false-to-true runtime readiness epoch starts the
same bounded device catch-up once. Repeated ready metadata is coalesced. This
persist-before-wake hint is also lossy; it adds no delivery cursor or second
recovery owner.

`agent_runtime_input` commits the complete batch before returning its stable
`dispatch_id`. A background worker stores the execution ID before it calls the
provider. It then acquires the Host right for the exact Compute target. The
provider does not start until both facts exist. The worker delivers the batch
without using the Server transport.
For one session it claims all batches that are pending at the delivery claim,
merges their messages into one strict
`external_session_message_batch_v1` JSON envelope, and invokes the runtime only
once. Native acceptance deletes all constituent records in one transaction;
connector, host, or native-process interruption before that point causes the
remaining batches to be merged and replayed at least once. The envelope carries
the constituent batch ids, stable message ids, and human-readable UTC
send/delivery times. User content is encoded only as JSON values, and the
envelope always warns that a replay may be a duplicate. Sessions remain
independent and concurrent. A new batch committed after a session's native call
has already begun is merged into the next call rather than serialized per
message.

Later input can steer the same active native execution. A completed execution
does not resume only because a late tool result arrives. The Connector settles
that execution before it starts a new execution for pending input.

Native terminal evidence and the event outbox commit in one transaction. The
record then enters `settling`. The Connector removes it only after the Server
acknowledges the event, local obligations end, and the Host acknowledges the
exact release. A lost release reply retries the release. It does not dispatch
provider input again.

On the first startup after upgrading, the connector transactionally imports
legacy `<root>/external-runtime/active/*.json` records into bbolt and removes
the files only after the transaction commits. Repeating the import after an
interruption is idempotent; malformed, unsafe, or conflicting legacy records
stop startup instead of guessing which state is authoritative.

A startup transaction also canonicalizes the exact legacy async-tool
completion shape that older Servers could already have placed in
`input-batches-v1` with a result larger than 16000 JSON characters. It preserves
the batch, message, and tool-call identities, removes only the oversized
duplicate result, bounds error references, and tells the runtime to read the
durable Server result with `tool_call.get_result` from offset 0. The rewrite is
idempotent and happens before delivery, so an old batch rejected by a native
input limit can drain after a connector upgrade. Current `result_page`
notifications, short results, and ordinary user input are not rewritten or
truncated. For the historical failed shape whose inner status defaulted to
`completed`, the outer `tool_call_failed` type remains authoritative and the
delivered inner status/source references are normalized to `failed`. Newly
received copies of the exact legacy shape pass through the same canonicalization
before their durable-local ACK.

The Connector upgrades old active records in one startup transaction. A record
without a native execution ID returns its input claim to the durable inbox.
Codex saves its thread binding before it submits native input. A Codex execution
without that binding retains its original execution ID and input claim.
The health pass retries the saved input after any required Host authority check.
This also applies to legacy records with a matching durable input batch.
A missing batch or unavailable Host authority retains the affected Session for
recovery. It does not prevent other Sessions from loading. A record with a native
identity requires a provider check. The Connector does not replay an unknown
provider start.

The Connector loads only `active-executions-v2` at startup, checks those
records immediately, and then starts another health pass every ten seconds.
Each pass covers every active execution present at its start, with at most
eight probes or native-process restarts running concurrently. This concurrency limit protects the host; it
does not limit or permanently partition the recovery set. A native
process or protocol probe failure, connector restart, and host restart first
resume the recorded Codex thread, Pi session, or Kimi session. If Codex reports
missing native history, it can create a new thread unless the input requires
strict native resume. The loop
runs independently of the Server transport, so recovery continues while the
Server cannot connect to this connector. A native runtime that settles the
current turn records terminal lifecycle evidence and enters release settlement.
Its resumable identity remains for a later real input. A runtime's own normal process exit is an explicit terminal stop
and removes both facts, so it is not resumed later. Externally killed or failed
processes with active work retain an interrupted active execution and remain
recoverable. If an idle Codex
app-server exits after settlement, the identity remains idle: the Connector
does not restart it or invent an interruption prompt. A later real input may
resume that thread, but only the new input is sent.

The recovery obligation exists as soon as a persisted session is loaded. A
transient provider initialize, resume, probe, or recovery-turn start failure
after a native process has already attached does not clear that obligation; a
later health pass retries it. Only native acceptance and terminal settlement of
the recovery turn clear the active execution. A `runtime_recovered` event is
emitted only after the native runtime accepts that recovery turn; attaching a
process alone is not reported as recovery.

On the first v2 startup, every legacy `active-sessions-v1` record becomes a
resumable identity. Exact terminal evidence dominates stale pending input,
deletes the correlated stale inbox row, and makes the record identity-only. If
there is no terminal evidence but the correlated input is still pending, that
input remains in the inbox for at-least-once replay and the old execution is not
simultaneously recovered. A record with neither terminal nor pending evidence
is ambiguous because an already-ACKed running event has also left the outbox,
so migration conservatively preserves that old v1 recovery obligation as
active. Legacy JSON recovery files likewise represent an explicit interrupted
obligation and migrate to both buckets. The legacy bucket or file is removed
only in the transaction that commits its replacement facts.
Migration builds the lifecycle evidence index with one event-outbox scan and
then classifies each session once; it does not rescan every event per session.

An unconfirmed initialize response is not retried on the same app-server
connection: the Connector terminates that owned process and retries from a
fresh process, avoiding an ambiguous applied-but-response-lost handshake.

The local tool gateway never queues tool execution while the Server transport
is offline. Every tool returns `503` immediately. Failed tool calls are not
persisted, replayed, or converted into a later native-session reminder. Standard
operation and error events produced by the runtime still enter the durable
runtime-event outbox and are reported when the Server becomes available. The
Connector canonicalizes every event before its bbolt write. Message/thinking
content is capped at 16 KiB, error detail at 4 KiB, and a whole event at 64
KiB. Operations retain only bounded allowlisted identity/path/command/range
metadata; output becomes an `omitted`/`json_bytes` summary. Raw file contents,
tool results, stdout/stderr, body, text, and content are never stored in the
outbox or reported to the Server. Invalid standard/lifecycle shapes are not
persisted. The Connector drains that outbox in ordered
`external_runtime_events` requests of
at most 64 records and 8 MiB of stored event JSON. The count caps Server work
per request; the byte cap leaves envelope headroom below the 16 MiB WebSocket
frame limit. The Server validates one capability/scope per distinct token,
partitions the transport batch by exact `{agent, session, capability}` owner,
and invokes each Session owner once while preserving that Session's event
order. Up to eight Session partitions run independently; each owner call has a
4.5-second deadline and a 4.75-second task settlement bound. A stalled
partition therefore stays retryable without blocking a healthy Session's
commit or ACK. The Server loads the configured batch facade before feature
detection, so the first request after node startup does not fall back to the
legacy per-item path. A normal ordered new suffix is appended with one segment
GET and one conditional PUT per affected existing segment (or one create-only
PUT for each new segment). Replay records settle with one GET and at most one
conditional PUT per affected segment while retaining positionally aligned
duplicate/conflict/committed results. Records inside one segment remain serial;
up to four distinct affected segments settle independently inside the exact
Session owner, so finite segment latency does not make a long-lived Session's
multi-segment replay consume the whole owner deadline. Genuinely missing older records are
merged into that same segment write rather than replayed one at a time.
SessionRecord settlement is the ACK authority. The exact Session owner then
previews matching lifecycle siblings in durable record order and writes at most
the latest effective transition. A delayed event from another execution cannot
replace an already-observed current execution. At a new dispatch, the first
eligible execution installs authority once, later matching siblings coalesce
to that execution's latest event, and later foreign executions remain fenced.
This same order determines authority after a transient first status-read
failure, so only the first execution's latest sibling remains retryable. A
stale, mismatched, or already-current replay writes neither Session target nor
status. If that final projection write fails transiently, only its event
remains retryable; earlier durable siblings stay accepted. For an existing
target, a failed status read resolves the current execution from the exact
durable target record with one bounded segment read. Only if that target
identity also remains unreadable does the owner conservatively retain one
latest event per candidate execution and ACK none of those ambiguous
candidates. The
Server replies in original transport order with `accepted_event_ids` plus bounded
`permanently_rejected_events` entries carrying the event id and stable error
code. The Connector settles both sets in one bbolt transaction. Omitted and
transiently failed items remain durable while later items may succeed; a known
stale identity/capability/lifecycle rejection or a deleted target's `not_found`
cannot poison the outbox forever,
and a lost whole-batch
response deletes nothing. A delivery attempt is capped at one minute for the
batch. It does not force 64 independent capability reads, owner calls, or
segment read/modify/write cycles through the old single-item path.
Whole-response and invalid-ACK failures keep the approximately five-second
retry cadence. A valid partial ACK instead defers the exact Sessions whose
items were explicitly left retryable for 30 seconds, while the captured-tail
forward scan continues to later Sessions without requiring another reconnect;
after reaching that finite tail, the next due cooldown resumes from the start.
Every batch delivery attempt
has a fresh transport request ID, separate from the durable event IDs, so a
late response cannot settle a newer retry with different batch membership.
On startup the Connector transactionally canonicalizes existing outbox
records and deletes permanently invalid poison records. A changed legacy
record keeps its durable event ID and is isolated once through the legacy
single-event exact-ID coordinator: a missing Server record appends the safe
form, while an already accepted raw record settles as a same-ID content
conflict. The local migration marker is never sent on wire. Newly observed
events are already at most 64 KiB and always use the normal batch method. The
Server retains the legacy method for old Connectors and this startup
settlement. Deploy the
Server before the Connector during a rolling upgrade; a newer Connector
talking to an older Server keeps rejected batches in the durable outbox until
the Server becomes compatible.
Startup removes the retired `runtime-reminders-v1` bucket from an existing
database.

Methods: `exec`, `read`, `write`, `delete`, `stat`, `list`, `glob`, `grep`,
`runtime_probe`, `runtime_auth_read`, `runtime_auth_login_start`,
`runtime_auth_login_cancel`, `runtime_auth_status`, `runtime_auth_verify`,
`runtime_auth_input_begin`, `runtime_auth_input_submit`,
`runtime_auth_input_cancel`, `computer_use` (stub). `exec` returns
`{exit_code, stdout, stderr, truncated,
status}` with 64 KiB per-channel caps. File
reads/writes are inline (UTF-8) up to 10 MB.

## Reconnection

With `--reconnect` (default) the connector retries with exponential backoff and
opens a fresh connector run for the same connector identity. Runtime bindings
stay attached to the stable device runtime; they are resolved to the current
online connector run only when work is dispatched. The one-shot catch-up hint
above only wakes Server owners after the new generation is ready; it does not
replace ordinary online push with pull.

## Path Semantics

`--root` is the base directory for relative paths. Absolute paths are resolved
as absolute OS paths. The production connector does not impose a filesystem
jail; deploy it as an appropriately scoped OS user on a machine or VM whose
filesystem access is intended to be available to the agent. Commands run via
`/bin/sh -c` in the resolved working directory.

## Workspace Archival

External runtime workspaces under `~/.comma/workspaces` that have been idle for
`--workspace-archive-idle-seconds` (default 72h; `0` keeps the default) are
packed into a verified `tar.zst` under `~/.comma/workspace-archives` and removed
from disk. `--workspace-archive` (default on;
`SALIX_WORKSPACE_ARCHIVE=false` to disable) controls the whole mechanism.

Idleness is decided by session activity: every input batch and runtime event
refreshes a per-session activity timestamp, and a session idle beyond the
threshold is closed and archived. Sessions created before activity tracking
existed fall back to workspace mtimes (regular files and directories; symlink
mtimes are ignored because they record creation, not activity). Sessions with
in-flight executions are never touched.

Closing an idle session first terminates session-owned stray processes —
anything whose working directory is inside that session's workspace, such as
dev servers an agent left running. Shared runtime processes (the codex
app-server and similar) are never terminated: their pids are collected from
the runtime registry and excluded, and the cwd whitelist alone already keeps
them safe because they run outside session workspaces. Strays get SIGTERM,
five seconds of grace, then SIGKILL; if anything survives termination the
workspace is kept and retried on a later pass instead of being archived under
a live writer. Regenerable directories (node_modules, language build outputs,
tool caches — see `workspaceArchiveSkipDirs`) are excluded from the archive
and intentionally not restored; source files, configuration, and `.git` state
are.

When new input arrives for a session whose workspace is archived, the connector
restores it before dispatching the runtime, bounded by
`--workspace-archive-restore-timeout-seconds` (default 60;
`SALIX_WORKSPACE_ARCHIVE_RESTORE_TIMEOUT_SECONDS`). On timeout the restore is
aborted and treated as a failure so dispatch can never block forever. Restored
files carry fresh mtimes, so a restored workspace is immediately non-idle and
cannot be re-archived by a passing sweep. The runtime input batch gains a
`runtime`-role notice: a successful restore tells the agent the workspace came
from an archive and regenerable caches may be missing; a timed-out or otherwise
failed restore tells the agent the session proceeds with a fresh empty
workspace, where the archive still lives, and how to extract specific files
from it itself. A corrupt archive can never be restored, so it is discarded on
first failed restore instead of occupying space and failing every future
dispatch; that notice says the contents are unrecoverable. Re-archival
atomically overwrites the previous archive for the same session (temp file
plus rename), so stale archives never accumulate.

This mechanism is local filesystem lifecycle management only. It does not
change settlement, recovery, or delivery protocol semantics across the
Server/Connector boundary, so it is out of scope for the distributed protocol
modeling requirement and adds no protocol progress claims.
