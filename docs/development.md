# Development

Follow [AGENTS.md](../AGENTS.md), package instructions, [Testing](testing.md), and [Release operations](release-operations.md).
Commands are in the manifests and the root Makefile. Local runs do not validate releases.

## Comma App

For staging UI work, run from the root:

```sh
COMMA_BUILD_FLAVOR=dev \
COMMA_API_BASE_URL=https://salix-staging.comma.surf \
pnpm --dir clients dev:electron
```

This runs Comma Dev (`@comma-dev`, `comma-dev://`) against shared staging services.
Do not select the staging flavor. It shares the installed Comma Staging profile and protocol handler.
Credentials are backend-specific. Never clear a profile automatically to switch backends.

Use `make dev-electron` for the local backend or deterministic fixtures.
Package only to validate signing, keychain identity, installation, updates, or packaged resources.

## Local model switching

The dev-container runs `systems/devcontainer/bootstrap.exs` before backend startup.
Migrations alone do not admit Agent configuration.
Bootstrap refuses a non-local database and calls `Comma.FreshInstall.run()` (`systems/apps/comma_core/lib/comma/fresh_install.ex`).
That runs the offline initialization: ClickHouse and Comma migrations, cutover steps, Group Compute, and the owner.
For a pending handoff, it verifies that the Bridge agent and project tables are absent, then completes the empty handoff through `SalixStore.AgentConfigurationRollout`.
A database with Bridge tables requires the release handoff.
Never use this local path in staging or production.

If model selection returns `agent_configuration_rollout_pending`:

1. Check bootstrap completion.
2. Update the local bootstrap code if necessary.
3. Run `make dev-container-restart` with the original Compose port overrides, for example `COMMA_DEV_REDIS_PORT=16379`.
4. Retry model selection.
5. Confirm the saved selection through `GET /v1/comma/workspaces/:workspace_id/agent-models`.

Do not write admission markers manually or replace API keys to hide this error.

## Local subscription setup

The dev-container builds the Go subscription worker.
The `comma-dev-salix-agent-priv` volume keeps its Linux binaries apart from host builds.
After a Compose volume change or a subscription support update, run `make dev-container-rebuild` with the original port overrides.

Startup keeps the local encryption key at `/var/lib/comma-dev/subscription-storage-key` in `comma-dev-cache`.
`subscription_proxy.storage_key`, then `SALIX_SUBSCRIPTION_STORAGE_KEY`, overrides the generated key.
Keep the effective key with the database. Do not delete the volume to repair startup.
A pre-rename stack keeps both in old-named volumes. Copy them first.
Deployments use their own secret configuration, not this file.

## Cloud VM stations

[Domain concepts](architecture/DOMAIN_CONCEPTS.md#cloud-vm-stations) describe the station, its profiles, and archive transport.
Deploy image changes through the mainline release flow. A source change does not update an existing cloud resource.
For a Cloudflare VM, configure Cloudflare for the tenant and turn on the Group's Cloud VM switch.

An authorized, enabled Group Host prepares a VMM Station in its Compute Environment.
Comma and BFT use the same preparation path. BFT's Devices page manages its Project's Runner installation.
The Host must connect to Salix; a Runner heartbeat alone does not establish that connection.
Multiple eligible Host registrations require an explicit placement decision.
New Group Cloud VMs use Cloudflare. Existing Cloud VM records retain their provider and archive.
VMM Station preparation leaves the Group's Cloudflare Station and accepted Tasks in place.
Automatic runtime Tasks prefer VMM, the requester's authorized computer, then enabled Cloudflare.
Explicit Task locations keep their target. Unknown invitation outcomes cannot switch machines.

An idle Cloudflare Workload tries an archive before it stops. Its disk follows the [Cloud VM data policy](compute-devices.md#cloud-vm-data-policy).
Command dispatch wakes the exact Group VM only with the exact wake parameters from `device.get`. Aliases, other devices, and unknown environment IDs cannot wake it.
The caller retries after `vm_waking`.
Runnable Session candidates, durable inputs, recovery, pending results, native background tasks, and managed processes prevent archive.
Human approval and reply waits do not need an active VM.
The Compute reconciler archives only after the station confirms quiet. Restore keeps the exact device and the station's chats.
Restore keeps internal executable links and permissions. Unsupported entries or archive limits fail that archive attempt.
An uncertain destroy keeps the old process fenced and the saved archive intact. Resolve the reported transition before you retry.
Read-only status does not wake a resource.
Archives that the retired Go connector wrote as gzip, or kept in Salix S3, are not restored. That VM starts empty.

## Compute Node Host setup

[Compute Node initialization](product-features.md#compute-node-settings-and-initialization) owns the enable and disable lifecycle.
Configure the Electron main process before launch:

| Variable | Meaning |
| --- | --- |
| `COMMA_VMM_DOWNLOAD_URL` | Public HTTPS archive URL. The default comes from `.github/agent-vmm-host.json`. |
| `COMMA_VMM_SOURCE_PATH` | Dev-only VMM checkout. Without it, Comma uses the shared download. |

A source checkout builds a local Host bundle, keyed by its canonical path. The path digest gives no integrity or authorization.
Before enrollment, Comma repairs the shared VMM service to use that bundle. It shares runtime data and can interrupt other registrations.
Settings show the source, stage, and errors. A failed source build never falls back to a download.
The local backend needs the [local VMM Gateway](#local-vmm-gateway).
The published VMM requires an HTTPS exchange endpoint. The local VMM source also permits HTTP exchange on localhost, 127.0.0.1, or ::1. Gateway TLS stays required.

Preparation starts after an explicit enable. Main then continues it by itself, also after a Comma restart, within a bounded budget and deadline.
Use **Rebuild Host** to prepare changed source.
A rebuild uses the VMM update operation to replace and restart the Host. An explicit retry resumes an interrupted update before it builds another version.
VMM owns runtime replacement and its recovery records.
A whole-Host restart interrupts running work across all registrations on that Host.
Disabling one registration stops admission and drains its workloads.
Normal removal revokes the registration and stops its environments into Retained. It keeps private files and volumes.
Local force disposal needs a separate confirmation and deletes the selected private scope.
It does not wait for business tasks or delete the shared Host.

### Host preparation

Electron main owns missing-Host preparation and its UI state.
The native capability layer never accepts an executable, source path, or download URL from the renderer. Startup configuration selects them.

The default archive must match the SHA-256 and byte size in the release reference that Comma ships.
A mismatch stops extraction and leaves an existing installation unchanged.
An explicit URL override trusts the operator's HTTPS source and has no byte pin.
`codesign` verification checks bundle integrity, not the publisher's identity.

Comma rejects traversal and symbolic links.
Preparation does not prove readiness. Readiness needs Host health, a Gateway connection, and Salix admission.

## Local VMM Gateway

Local Compute Node use needs Salix, the VMM Gateway, and the VMM Host.
The Host connects to the Gateway, and the Gateway forwards observations and command results to Salix.
Neither Comma App nor the dev-container starts the Gateway. Run it in a separate terminal or process supervisor.

### Configuration

The Gateway and its variables are in `systems/gateway/salix-vmm-gateway/main.go`. Set the Salix Gateway variables from `systems/config/runtime.exs`.
Certificate paths must exist inside the Salix container. Container loopback does not reach the Mac. Use a host address the container resolves.
Keep existing credentials, keys, certificates, and data when you restart this stack.

### Startup and verification

Restart a stopped Gateway with the same configuration. The Host reconnects automatically.
A restart drops live sessions, so do not restart during active work.

## SSH terminal development

SSH is disabled by default. Use a local backend for enrollment and chat tests.

1. Apply the Comma database migrations.
2. Set `COMMA_SSH_LISTEN_PORT=2222` on a backend that runs `comma_product`.
3. Start the backend.
4. Connect with an explicit client identity:

   ```sh
   ssh -t -p 2222 -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 comma@localhost
   ```

The first startup generates the host keypair and stores its unencrypted PEM in Postgres. Later startups present the same fingerprint.
On first connection, enter your email and its code, then select a workspace.
[SSH terminal client](clients.md#ssh-terminal-client) lists the commands. Revoking the current key ends the connection.

Staging and production expose SSH through a TCP LoadBalancer. See [Kubernetes setup](../k8s/comma/README.md#ssh-terminal-endpoint).
