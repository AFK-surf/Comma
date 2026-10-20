# Compute and devices

## Ownership

BFT owns setup/access. Salix owns devices/runtimes/dispatch. Projects map to Groups. Check org/Project access before connecting. Scope machine credentials to Groups.

## Identity

Device identity is Group-scoped. `connector_id` identifies installation. Reconnect changes `connector_run_id`.
`environment_id` selects commands, files, and processes. `device_runtime_id` identifies a discovered runtime. BFT `runner_id` identifies enrollment, not dispatch.
Dispatch resolves runs. Aliases cannot select targets. PID/port/socket/run IDs route requests.
External Sessions are retired. Workers bind to a station. Stored External Sessions stay read-only ([Retired Sessions](architecture/DOMAIN_CONCEPTS.md#retired-sessions)).
See the [domain inventory](architecture/DOMAIN_CONCEPTS.md#7-devices-and-compute).

## Installation and Runner

Tools and installation `connector-token` need no SSH/Drive. Consent grants read-only access until reboot, with no startup service.
First registration expires after 15 minutes. Reconnect does not. Revocation persists.
Reuse uncertain commands. Verify `connection-check.txt` through the exact Device/Environment.
Runners use BFT device-code auth. Group Connectors use Salix credentials, without BFT login.
Reconnect updates routes and fences stale runs. Manager loss or upgrade cannot stop independent workloads.
Reject unsupported operations locally.
Station cutover: [Station](architecture/DOMAIN_CONCEPTS.md#station).

## Compute and VMM

Project/Swarm/Group owns Compute Environments. Device access is separate.
Offline requests are bounded. Input awaits READY. Recovery repairs hints without Session polls.
Preserve bindings, input, tool deadlines and receipts. Never substitute machines. See [deadlines](agent-runtime.md).
VMM gateway secrets remain independent of [Comma candidate-Secret rollout](release-operations.md).
VMM Host and user Device disk disposal requires owner approval. Cloudflare Group VMs follow the policy below.
Compute uses [billing facts](billing-models.md), not delayed usage telemetry.

Authorized Worker selection wakes archived Cloudflare Workloads with a 30s demand hold.
See [Tasks](../systems/station/docs/tasks.md) for station wake when Salix cannot give a Task Message to an unconnected Group VM station.

Shell cleanup, seven-day authorization and remnants: [settings](product-features.md#compute-node-settings-and-initialization).

## Cloud VM data policy

Cloudflare Group VM disks are disposable, including edits, dependencies, native history, and local auth.
Archive and restore are best effort. After bounded recovery fails, rebuild the exact VM.
Local disk loss needs no further approval and must not block a release.
A Container's disk lives only as long as the Container. Salix never starts a ready VM's stopped Container empty: Salix seals the Gateway control and releases the Container, as an archive does. The VM is then `archived` with its last archive and wakes from it.
Salix never archives a stopped Container. With no archive, the VM starts empty and its record keeps `container_loss`.
A wake's Container restores the archive before it starts its station. If it cannot, it exits and no station connects.
An archive does not carry the station's runtime state (`run/` in its data directory: runner records, pids, ports). A restore drops that directory from an older archive that has it.

Preserve Salix-owned Sessions, Messages, queues, credentials, and execution records.
Never replay unknown effects or restore old pending execution after reset. Fence commands and confirm the exact carrier stopped.
Keep usable archives and report interrupted work or required login. Use Workload owner operations, never direct database edits.
Finish the generation-aware Comma rollout before reset. Do not restore an older serving binary afterward.
A reset advances the Workload generation. Sessions keep input with an unknown outcome and never replay it.

## Managed runtime credential binding

Accounts: Device/Workload Codex/Claude OAuth. Claude/Compute pi API keys.
Codex needs Server admission per resume. Bindings hold account references. Workload bindings survive replacement.

Subscriptions own accounts. API keys store encrypted keys, bounded HTTPS endpoints, protocol/auth scheme. Public views omit keys. Connection/key changes or deletion require zero bindings. Renaming does not. Disabling requests revocation, without offline/upstream proof.

BFT GET/PUT/DELETE: `/dashboard/orgs/:org/projects/:project/workloads/:id/managed-auth`; device targets replace `workloads/:id` with `devices/:device_id/runtimes/:runtime_id`.
Salix: tenant-admin Account action. Tenant-key GET/PUT/DELETE `/v1/runtime/groups/:group_id/environments/:id/runtimes/:device_runtime_id/managed-auth`. No Group/Connector-token access.
Unready runtimes can bind. Device bind/retry delivers then probes. Delivery does not prove readiness. Selection is per runtime.
BFT reads require project access. Writes require org admin/owner and project write. Readers get source/state/provider/issue. Configurers get public accounts/snapshots. Use `no-store`. GET never retries.

Codex external tokens replace process auth, preserving native login storage.
AccountPool refreshes within 5m of expiry or after rejection. Versioned claims prevent duplicates.
Pi uses a managed directory and secret-free model projection. Claude gets one auth variable in its child environment.
Claude OAuth uses `CLAUDE_CODE_OAUTH_TOKEN`. AccountPool keeps refresh tokens. API keys supply the endpoint.
Both reject credential conflicts. No keys in auth files, managed/public views, argv, durable queues, or Salix logs.
Connector/native process/extensions/tools/host can read secrets.

Delivery rechecks Device connection or Compute Workload/RuntimeInstance/allocation/execution generation/epoch/VMM Host.
`runtime.subscription.v1` negotiates support. Sync is token-free.
CIRCL HPKE: fresh keys/nonces, P-256/HKDF-SHA256/AES-128-GCM.
AAD binds tenant/project/Workload/RuntimeInstance/generation/epoch/nonce. Ciphertext protects relays/logs, not compromised runtimes.
Compute: two pulls/socket, ≤11s each.

Device Codex switches accounts directly. Compute/Claude require confirmed unbind before rebind.
Stop issuance. Delete only after the exact revoked-revision ACK.
Revocation interrupts managed processes, preserving Sessions. Offline revocation waits for reconnect/upstream action.

## Host reconnect and Runtime recovery

Host/ProviderBinding epochs fence routes. RuntimeInstance epochs fence execution.
Creation fences allocation generation/execution/container instance. Dispatch checks route/state/generations/credentials/epochs.
Reconnect keeps generation. Resume needs fresh inventory and keeps consumed bootstrap/in-flight identity. Ready/retained reports keep draining. Release/revoke retires authority.
Late bootstrap cannot change epochs. Pending input alone can change execution epoch. In-flight input blocks replacement.

Bootstrap expiry repairs only never-authenticated execution. Otherwise use runtime credentials.
Repair requires quiesce and exact-instance stop. Stop/delete request IDs include instance/container generation.
Demand recreates stopped containers with fresh bootstrap and retained provider-state volumes.
Meetings retain continuous demand.

Host Session commit wakes its Workload without stealing claims. Container proof permits credential reuse.
Sweeps repair missed wakes. Readiness clears the deadline. Manual retry preserves age. Gateway errors omit private metadata and use finite reasons.
The owner recovers exited loops. Preserve children, credentials, volumes, and accepted work. Verify a task response.

Migration preserves credentials/container identity/volumes/accepted work. Missing/contradictory inventory fails closed within budget.
Repair forward after cutover.
