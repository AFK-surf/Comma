# Development

## Entry points

Read [AGENTS.md](../AGENTS.md) and the scoped instructions for the package you change.
Use the package manifest and root Makefile as command authorities.
Use [Testing](testing.md) for validation commands and [Release operations](release-operations.md) for deployment.
Local source execution is not release validation.

## Comma App

For everyday Electron UI work against staging, run from the repository root:

```sh
COMMA_BUILD_FLAVOR=dev \
COMMA_API_BASE_URL=https://salix-staging.comma.surf \
pnpm --dir clients dev:electron
```

This uses the Comma Dev identity, `@comma-dev` data directory, and `comma-dev://` protocol.
Do not select the staging build flavor only to reach staging services.
That flavor shares the installed Comma Staging profile and protocol handler.
Credentials belong to their backend. Do not clear a developer profile automatically when switching backends.
Staging interactions affect a real shared environment.

Use `make dev-electron` for the local backend or deterministic fixtures.
Package an app when validation needs signing, keychain identity, installation, updates, or packaged resources.
A routine UI edit does not require packaging.

## Local model switching

The dev-container runs `systems/devcontainer/bootstrap.exs` before backend startup.
Database migrations alone do not establish Agent configuration admission.
For a pending handoff, bootstrap verifies that Bridge Agent and Project tables are absent.
It then completes the empty handoff through `SalixStore.AgentConfigurationRollout`.
A database with Bridge tables requires the release handoff instead.
Never use the local initialization path in staging or production.

If model selection returns `agent_configuration_rollout_pending`:

1. Check bootstrap completion.
2. Update the local bootstrap code if necessary.
3. Run `make dev-container-restart` with the original Compose port overrides.
4. Retry model selection.
5. Confirm the saved selection through `GET /v1/comma/workspaces/:workspace_id/agent-models`.

Preserve overrides such as `COMMA_DEV_REDIS_PORT=16379`.
Do not write admission markers manually or replace API keys to hide this error.

## Local subscription setup

The dev-container builds the Go subscription worker.
The `comma-dev-salix-agent-priv` volume keeps Linux binaries separate from host builds.
After a Compose volume change or subscription support update, run `make dev-container-rebuild` with the original port overrides.

Startup retains the local encryption key at `/var/lib/comma-dev/subscription-storage-key` in `comma-dev-cache`.
`subscription_proxy.storage_key`, then `SALIX_SUBSCRIPTION_STORAGE_KEY`, overrides the generated key.
Preserve the effective key with the database. Do not delete the volume to repair startup. A pre-rename stack keeps both in old-named volumes; copy them first.
Deployments use their existing secret configuration, not this local file.

## Cloud VM external runtimes

The Cloudflare image bundles the Go Connector. Configure Cloudflare for the tenant and enable the Agent's VM.
Deploy image changes through the mainline release flow. A source change does not update an existing cloud resource.
The Router can then call:

```json
{"provider":"codex","request_id":"coding-worker"}
```

Use `env.ensure_runtime` with the same request ID to inspect progress.
The runtime automatically selects an enabled, compatible account from the tenant account pool.
When readiness becomes true, pass `target` unchanged to `agent.create_worker.runtime`.
Codex uses subscription OAuth. Claude supports subscription OAuth and compatible Provider API keys.
Auto selection skips global quota exhaustion/cooldown, not unknown/model-only/expired limits.
Healthy bindings stay pinned. Exhausted auto bindings need a replacement and an updated
Connector's idle ACK to rotate. No Task replay. Manual bind/unbind disables automation.
A failed attempt requires an explicit `retry: true`. Do not generate another request ID to retry.
Each VM supports at most 16 installation intents. This change adds no removal API or account-selection UI.

Cloud VM installation refreshes the connected runtime inventory before automatic
account selection. Missing inventory fails after three discovery attempts. Retry
uses the same installation target. A missing target does not mean an empty account
pool. Test the bound managed runtime, not a preinstalled CLI with a different
executable path or credential home.

An idle Cloudflare Workload archives its files and native state before stopping its resource. Command dispatch can wake the exact
Group VM using the exact wake parameters from `device.get`. Aliases, other
devices, and unknown environment IDs cannot wake that VM. The caller
retries after `vm_waking`. Credential delivery waits while the Connector is
parked. It preserves pending revocation and does not consume delivery retries.
Reconnect still requires current account authority before native execution.

Trusted tenant runtime API routes:

| Method and path | Operation |
| --- | --- |
| `POST /v1/runtime/agent-groups/:group_id/agents/:id/cloud-vm/runtimes` | Prepare with the same body as the Router tool. |
| `GET /v1/runtime/groups/:group_id/cloud-vm/runtimes/:request_id` | Read installation, current target, auth, and account binding status. |
| `PUT /v1/runtime/groups/:group_id/cloud-vm/runtimes/:request_id/managed-auth` | Bind an existing account with `{"account_id":"..."}`. |
| `DELETE /v1/runtime/groups/:group_id/cloud-vm/runtimes/:request_id/managed-auth` | Request confirmed native revocation before binding removal. |

These routes use existing tenant runtime authentication. They are server operator APIs, not browser account authorization.
An uncertain auth write can persist a pending binding. Read status before retrying.
Offline revocation remains pending until reconnect or upstream action.
Store test keys outside the checkout. Use an isolated Cloudflare target. Remove it only under its data owner's approved scope.
CLI installation, readiness, and successful model execution require separate verification.

Runnable Session candidates, durable inputs, recovery, pending results, native background tasks, and managed processes prevent archive.
Human approval and reply waits do not require an active VM.
The shared Compute reconciler archives only after the Connector confirms quiet. Restore preserves the exact device, entry paths, and Session identities.
Internal executable links and file permissions survive. Unsupported entries or archive limits stop deletion and leave the source available.
An uncertain destroy keeps the old process fenced and the saved archive intact. Resolve the reported transition before retrying.
Read-only status does not wake a resource.

`zstd_enabled` selects streamed tar+zstd R2 archives. Old gzip archives remain readable.

See [ownership and recovery](architecture/DOMAIN_CONCEPTS.md#cloud-vm-runtime-preparation).

## Background Loops and scripts locally

`mix compile` downloads the pinned prebuilt spinfoam release into `apps/salix_agent/priv/spinfoam` and verifies its digest.
No toolchain is involved: the binary embeds its C compiler, and runtime tests build their fixtures through it.
The same binary runs `script.run` programs, so `script.*` tools and the two C skill scripts also depend on it.
On a platform without a release package, background loops and scripts report unavailable locally and every `:spinfoam` tagged test skips itself.
See `systems/native/spinfoam/README.md`.

## Tooling and artifacts

Use the runtime and operating system you actually have.
Do not claim native, browser, provider, or cluster checks from static validation.
Keep temporary fixtures, PDFs, screenshots, and benchmark outputs outside `docs/`.
Use an isolated account and workload for tests that can alter user data.
Remove test-owned resources after validation. Do not delete resources owned by another session.

See [Compute Node initialization](product-features.md#compute-node-workload-initialization) for the enable/disable lifecycle.

## Compute Node Host setup

Configure the Electron main process before launch:

| Variable | Meaning |
| --- | --- |
| `COMMA_VMM_DOWNLOAD_URL` | Public HTTPS archive URL. The default comes from `.github/agent-vmm-host.json`. |
| `COMMA_VMM_SOURCE_PATH` | Dev-only VMM checkout. An omitted value selects the shared download. |

An explicit source checkout builds a local Host bundle, keyed by its canonical path.
The path digest identifies a directory; it grants no integrity or authorization.
Before enrollment, Comma repairs the shared VMM service to use that bundle.
It shares runtime data and can interrupt other registrations.
Settings show the source, stage, and errors. A failed source build never falls back to a download.
The local backend requires [Gateway startup and enrollment configuration](#local-vmm-gateway).
The current published VMM requires a trusted HTTPS exchange endpoint.
The local VMM source change also permits HTTP exchange on localhost, 127.0.0.1, or ::1.
Gateway TLS remains required.

Source builds run the VMM Guest script in a temporary Linux arm64 Docker container.
They run `make headless-release` on macOS for the Host, with development signing.
The checkout includes uncommitted source changes.
Comma does not install host development tools or clone source repositories.
The temporary Guest builder discards its container cache.

Preparation starts only after an explicit action.
A preparation error does not trigger an automatic retry.
Restarting Comma reads state but does not resume installation or reconstruction.
Use **Continue setup** to continue enrollment or retry preparation.
Use **Rebuild Host** to prepare changed source.
A rebuild uses the VMM update operation to replace and restart the locally built Host.
Comma retains its update arguments after interruption.
An explicit retry resumes that update before it builds another version.
VMM owns runtime replacement and its recovery records.
A whole-Host restart interrupts running work across that Host's registrations.
Disabling one registration stops admission and requests its workload drain.
Normal removal revokes that registration and stops its environments into Retained.
Normal removal preserves private files and volumes.
Local force disposal requires a separate confirmation and deletes the selected private scope.
It does not wait for business tasks to finish or delete the shared Host.

## Local VMM Gateway

Local Compute Node use requires Salix, the VMM Gateway, and the VMM Host.
The Connector opens a connection from the Host to the Gateway.
The Gateway forwards observations and command results to Salix.
Comma App startup does not start the Gateway.
The dev-container does not start it. Use a separate terminal or process supervisor.

### Configuration

Use the Gateway implementation in `systems/gateway/salix-vmm-gateway`.
Its [README](../systems/gateway/salix-vmm-gateway/README.md) defines transport and session ownership.
Configure these values before startup:

| Gateway variable | Local configuration |
| --- | --- |
| `GATEWAY_INSTANCE_ID` | A stable name for this local Gateway. |
| `REMOTE_LISTEN` | Host-accessible TLS listener, for example `127.0.0.1:27443`. |
| `INTERNAL_LISTEN` | mTLS listener reachable from Salix, for example `:27444`. |
| `HEALTH_LISTEN` | Local health listener, for example `127.0.0.1:27445`. |
| `CONTROL_BASE_URL` | Salix control API origin, for example `http://127.0.0.1:24000`. Use your published backend port. |
| `CONTROL_SECRET` | The same secret as Salix `SALIX_AGENT_VMM_GATEWAY_CONTROL_SECRET`, with at least 32 bytes. |
| `TLS_CERT_FILE`, `TLS_KEY_FILE` | Server certificate and private key paths on the Gateway host. |
| `CLIENT_CA_FILE` | CA file that verifies the Salix client certificate. |

Configure all five Salix Gateway variables from `systems/config/runtime.exs`:
`SALIX_AGENT_VMM_GATEWAY_URL_TEMPLATE`, `SALIX_AGENT_VMM_GATEWAY_CONTROL_SECRET`,
`SALIX_AGENT_VMM_GATEWAY_CA_FILE`, `SALIX_AGENT_VMM_GATEWAY_CERT_FILE`, and `SALIX_AGENT_VMM_GATEWAY_KEY_FILE`.
The URL template must reach the internal listener from Salix.
Certificate paths must exist inside the Salix container. The server certificate must cover the URL hostname.
Container loopback does not reach a Gateway on the Mac. Use a host address that the container can resolve.

Set `agent_vmm.install_material.remote_enrollment.gateway_endpoint` to the remote listener address that the Host can reach.
Set its `trust_bundle` to the base64-encoded PEM CA bundle that verifies the Gateway server certificate.
See `systems/config/config.example.json` for the configuration structure.
HTTP loopback enrollment does not remove Gateway TLS or internal mTLS requirements.
Preserve existing credentials, keys, certificates, and data when restarting this stack.

### Startup and verification

1. Start the configured Salix backend with the original Compose port overrides.
2. Reuse the existing Gateway executable. Build it only when missing or when Gateway source or dependencies change.
3. Export the configured Gateway variables in a separate terminal.
4. Run the executable in that terminal.
5. Check readiness, then enable Compute Node in Comma App.

For a first build, run this command from the repository root:

```sh
mkdir -p .local/vmm-gateway
(cd systems/gateway/salix-vmm-gateway && go build -o ../../../.local/vmm-gateway/gateway .)
```

The Go module expects a sibling `agent-vmm` checkout through its `replace` directive.
Resolve that source dependency before building. `COMMA_VMM_SOURCE_PATH` only configures Comma Host preparation, not the Gateway Go module.
Go reuses its build cache. A Gateway restart requires no Host or Guest rebuild.

After exporting the configured variables, start the existing executable:

```sh
.local/vmm-gateway/gateway
```

For the example health port, verify readiness:

```sh
curl --fail -i http://127.0.0.1:27445/readyz
```

For workload creation, mount the published server runtime bundle manifest at `/opt/comma/runtime-images/manifest.json` in the backend container.
Use the manifest from a successful mainline server image.
The manifest selects published runtime archives. The Gateway obtains the selected archive when the existing runtime flow requests it.
Reuse the manifest and existing binaries across restarts. A missing manifest is separate from Host enrollment or Gateway connectivity.

A `204` response confirms listener readiness. It does not prove a Host connection or successful Salix authentication.
Confirm `registration connected` for the expected registration in the Gateway log.
Refresh the matching tenant's Compute nodes page. Confirm `Ready` and `Connected`.

If the page shows `Unknown / Observation Stale`, Salix has no observation from the last 45 seconds.
Check the Gateway process, its listeners, and its control API errors before reinstalling the Host.
A healthy Salix container or an enabled Comma switch alone does not prove this connection works.
Restart a stopped Gateway with the same configuration and executable. The Host reconnects automatically.
A Gateway restart drops live sessions. Do not restart it during active work without accounting for that interruption.

## Comma Host preparation

Electron main owns missing-Host preparation and its UI projection.
The native capability layer never accepts a renderer-provided executable, source path, or download URL.
Startup configuration selects those values.
See [development setup](development.md#compute-node-host-setup) for shared-Host defaults and local source selection.

The default archive uses the existing release reference's SHA-256 and byte size.
The independently shipped Comma reference supplies the expected bytes, not the download response.
A mismatch stops extraction and leaves an existing installation unchanged.
An explicit public URL override trusts the operator-selected HTTPS source.
It does not inherit the default release's exact-byte pin.
The existing `codesign` verification checks bundle integrity, not the publisher's identity.
No new Team ID or online signature authority is introduced.

The preparer bounds compressed downloads to 2 GiB and extracted contents to 8 GiB and 100,000 entries.
A maintained ZIP extractor checks traversal, and Comma rejects symbolic links before extraction.
Preparation uses a SQLite transaction per destination to serialize Comma processes.
Process exit releases the transaction without a stale-lock timer.
Comma retains completed downloads for explicit retries and publishes a verified bundle with a directory rename.
A failed verification invalidates the download cache entry.
The SQLite file is local coordination, not a new product entity or readiness authority.

Existing enrollment models still describe the same registration and accepted-work boundaries.
Host preparation precedes enrollment and does not change the remote protocol.
File preparation is not proof of Host health, Gateway connection, or Salix admission.
Readiness continues to require those existing observations.
## SSH terminal development

The SSH listener is disabled by default. Use a local backend for enrollment
and chat tests. Email delivery and billing follow the backend's normal settings.

1. Apply the Comma database migrations.
2. Set `COMMA_SSH_LISTEN_PORT=2222` on a backend that runs `comma_product`.
3. Start the backend with its usual development command.
4. Connect with an explicit client identity:

   ```sh
   ssh -t -p 2222 -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 comma@localhost
   ```

The first startup generates the host keypair and stores its unencrypted PEM in
Postgres. Subsequent startups present the same host fingerprint. No additional
secret is required. A dedicated client key avoids enrolling whichever identity
an SSH agent offers first.

Enter your email and its code on first connection. Select a workspace by number.
For a new account, SSH starts the existing default-workspace provisioning flow.
Enter `/workspace` to refresh its status. Use `/keys` to list key IDs and `/revoke KEY_ID` to revoke
one. Revoking the current key ends the connection. Use `/quit` to exit without
revoking the key.

The staging and production release configurations expose SSH through a TCP
LoadBalancer. See [Kubernetes setup](../k8s/comma/README.md#ssh-terminal-endpoint).
Deploy only through the approved mainline release flow.

Run the focused tests from `systems/`:

```sh
MIX_ENV=test mix ecto.migrate -r Comma.Repo
mix test apps/comma_tui/test apps/comma_ssh/test \
  apps/comma_core/test/comma/accounts/ssh_identities_test.exs \
  apps/comma_core/test/comma/accounts/sessions_test.exs
```

The SSH tests use local TCP sockets, OTP and OpenSSH clients, PTY channels, Comma
email challenges, and sandboxed account storage. They verify terminal restoration
and normal exit with a pinned host key. Chat tests use the canonical
Conversation path with test storage. They do not prove public network routing,
production email delivery, terminal font behavior, or a live model response.

Read the running listener's fingerprint without exposing private material:

```sh
bin/comma rpc 'IO.puts(CommaSSH.Listener.fingerprint())'
```

### Computer Use screenshots

The Connector retains screenshots on the source device for 15 minutes under
`computer-use/screenshots` in its runtime directory. Only these temporary files
are disposable. Limits are 5 MiB per image, 128 images, and 128 MiB per Connector.
A full directory rejects new captures without evicting retained images.

Reads hold the cleanup lock. Expiry runs while the Connector is alive; after a
restart, startup removes expired files and resumes expiry timers.
The tool returns a device/environment image reference. Model requests read it
through the existing Computer Use authorization and encode native image input.
Salix creates no VFS copy. Offline or expired images produce explicit unavailable
results. This path requires an image-capable model.
