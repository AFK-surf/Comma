# Compute and devices

## Ownership

BFT owns access/setup. Salix owns devices/runtimes/dispatch. Projects map to Groups. Check org/Project access before setup/connection. Machine credentials are Group-scoped.

## Identity

| Identity | Scope/stability |
| --- | --- |
| device_id | Group enrollment. stable while credential remains |
| connector_id | Installation/credential |
| connector_run_id | Live connection. changes on reconnect |
| environment_id | Stable device command/file/process/computer-use target |
| device_runtime_id | Stable discovered device runtime |
| BFT runner_id | Product machine enrollment, not dispatch identity |

Tools target environments. Agents bind device_runtime. Dispatch resolves runs.
ExecutionTarget tags IDs, not access. Aliases cannot select targets. PID/port/socket/run route requests.
Codex IDs use normalized, trimmed entry paths. Same-path upgrades retain IDs.
Keep symlinks. Resolve bundles on execution. Never replace missing versions.
Rebind only new Sessions to discovered entries. Retain old bindings, input and runtime state.

## Installation

Install tools and `connector-token` (`installation:true`) need no SSH/Drive.
Consent starts read-only access until reboot, surviving terminal closure. No startup service.
First registration expires in 15 minutes, not later reconnects. Revocation remains valid.
Reuse uncertain commands. Verify `connection-check.txt` through the exact Device/Environment.

## Runner

BFT device-code authenticates runners. Group Connectors use Salix credentials without BFT login.
`bft-runner` owns launchd and run/claim diagnosis. `bft runners` manages installation/heartbeat.
Reconnect updates routes and fences stale runs. Controller/provider loss or upgrade cannot stop workloads.
Keep revocation. Reject unsupported operations locally. Heartbeat does not establish readiness.

## Compute and VMM

Project/Swarm/Group owns Compute Environments, separate from Device access.
Offline requests fail within budget. Input awaits READY. Recovery repairs missed hints without Session polls.
Preserve bindings, input, tool deadlines and receipts. Never substitute machines. See [deadlines](agent-runtime.md).
VMM gateway secrets under k8s/salix-vmm-gateway remain independent of [Comma candidate-Secret rollout](release-operations.md).
Preserve disks/volumes/credentials/snapshots without owner-approved disposal. Scope rebuilds and reenrollment/auth/readiness.
Compute uses [billing facts](billing-models.md), not delayed usage telemetry.

Worker selection wakes archived Cloudflare Workloads with a 30-second demand hold. Authorization applies.
Discovery reads. Unavailable targets prevent Worker creation.
Agent `env.exec` retains its async call during readiness. Its demand hold defaults to five minutes.
Exec timeout starts on send. Cloud VM unknown results never replay.
See [Compute and node UI](architecture/DOMAIN_CONCEPTS.md#7-devices-and-compute).

## Managed runtime credential binding

Accounts: Codex/device Claude OAuth. Claude/Compute pi API keys.
Owners remain unchanged. Offline Codex needs Server admission per resume. Bindings hold account references; Workload bindings survive replacement.

Subscriptions routes own accounts. API-key accounts store encrypted keys, bounded HTTPS endpoints, protocol/auth scheme. Public views omit keys. Changing connections/keys or deleting requires zero bindings; renaming does not. Disabling requests revocation, without offline/upstream proof.

BFT GET/PUT/DELETE: `/dashboard/orgs/:org/projects/:project/workloads/:id/managed-auth`; device targets replace `workloads/:id` with `devices/:device_id/runtimes/:runtime_id`.
Salix: tenant-admin Account action; tenant-key GET/PUT/DELETE `/v1/runtime/groups/:group_id/environments/:id/runtimes/:device_runtime_id/managed-auth`. No Group/Connector-token access.
Unready runtimes can bind. Device bind/retry delivers then probes. Delivery does not prove readiness. Selection is runtime-scoped.
BFT reads require project access; writes also require org admin/owner and project write. Readers get source/state/provider/issue. Configurers also get public accounts/snapshots. Use `no-store`; GET never retries.
Account pages are bounded. BFT polls pending state ≤60 times at 5s. Salix refreshes on demand. Reread uncertain writes.
States: `unbound`, `installing`, `configured`, `failed`, `account_disabled`, `revoking`. None proves model success.

Codex external tokens replace process auth and preserve native login storage.
AccountPool refreshes within 5m of expiry or after rejection. Versioned claims prevent duplicates.
Pi uses a managed directory and secret-free model projection. Claude gets the endpoint and one permitted auth variable in its child environment.
Both reject credential conflicts. No keys in auth files, managed/public projections, argv, durable queues, or Salix logs.
Connector/native process/extensions/tools/host can read secrets.

Delivery rechecks Device connections or Compute Workload, RuntimeInstance, allocation/execution generation, epoch, and VMM Host.
`runtime.subscription.v1` negotiates support. Sync is token-free.
CIRCL HPKE: fresh keys/nonces, P-256/HKDF-SHA256/AES-128-GCM.
AAD binds tenant/project/Workload/RuntimeInstance/generation/epoch/nonce. Ciphertext protects relays/logs, not compromised runtimes.
Compute: two pulls/socket, ≤11s each.
[Update existing Workloads](release-operations.md#workload-image-update).

Device Codex switches accounts directly. Compute/Claude require confirmed unbind before rebind.
Stop issuance first; delete only after the exact revoked-revision ACK.
Revocation interrupts managed processes, preserving Sessions. Offline revocation waits for reconnect/upstream action.
One node timer: four indexed deliveries, 90s claims, 60s tasks, 10s between batches.
Three failures stop retries until reconnect/admission/operator retry. Revisions fence installs/ACKs. Migration preserves selections/data.

## Host reconnect and Runtime recovery

Host/ProviderBinding epochs fence routes. RuntimeInstance epochs fence execution.
Creation fences allocation generation/execution/container instance. Dispatch checks route/state/generations/credentials/epochs.
Reconnect keeps generation. Resume needs fresh inventory and keeps consumed bootstrap/in-flight identity. Ready/retained reports keep draining. Release/revoke retires authority.
Late bootstrap cannot change epochs. Pending input alone can change execution epoch. In-flight input blocks replacement.
Connector retries `runtime_control_unavailable`/`runtime_recovery_expired` every 1 to 30 seconds, retaining credentials/cursors. Retired identities/unsupported protocols stop reconnect.

Bootstrap expiry repairs only never-authenticated execution. Otherwise use runtime credentials.
Repair requires quiesce and exact-instance stop. Stop/delete request IDs include instance/container generation.
Demand recreates stopped containers with fresh bootstrap and retained provider-state volumes.
Pressure reclamation requires no demand, settled obligations, current candidacy, and Runtime quiet.
External-worker sleep has no recovery deadline. Meetings retain continuous demand.

After the 900s deadline, recovery retries expired/legacy claims every 5 to 60 seconds, preserving outage age.
Host Session commit wakes its Workload without stealing claims. Container proof permits credential reuse.
Per node: four tasks, 870s/task, 900s/lease. Claim at start. Inspect one namespace.
Sweeps repair missed wakes. Readiness clears the deadline. Manual retry preserves age. Gateway errors omit private metadata and use finite reasons.
The owner recovers exited loops. Preserve children, credentials, volumes, and accepted work. Verify a task response.

Migration preserves credentials/container identity/volumes/accepted work. Missing/contradictory inventory fails closed within budget.
Use graceful mainline release. Back up affected allocation observations. Repair forward after cutover.

## Runtime execution and control

Persist execution/claim/target/native binding in bbolt before input. Get Host rights before input or unbound Codex/Claude retry. Later input joins. Retain records through local completion, terminal ACK, and exact release ACK. Check native execution/`ListExecutions`. Never replay unknown starts. Orphans/unknown results/stale or unreachable targets block quiet.

Settlement alert 120s, recovery 900s; reconnect resets neither. `execution_settlement_unknown` retries exact release post-terminal ACK. Round-robin release worker (not delivery): one RPC, 20s deadline, ≥5s retry, shared 5s timer. Settling holds input, not slots.

One authorized target RPC handles auth/quiet/migration, with no Host credentials or arbitrary methods. Auth owns credentials/locks; Compute owns quiet; External Session owns migration. Control/long work: two slots each; saturation fails; reads/status use none. Login/verification hold Host activity until confirmed.

## RFC: connected runtime 迁入 VMM 的终态

### 边界与不可约事实

VMM supports multiple tenants and >4 residents. CPU/memory follow use.
Pressure reclaims only idle instances; otherwise accept kernel OOM. There is no process migration, CLI conversion, scheduling, scaling, or resource guarantee.

Compute owns tenant/Workload/volume isolation and durability. SessionRecord owns ID/queue/binding; Connector owns native state/files; instance/token owns execution; Guest/Host owns pressure; Salix/Connector owns demand and unsettled obligations.
Reuse them with transient migration. Ordinary rebind preserves Sessions; explicit migration uses CAS.
See [inventory](architecture/DOMAIN_CONCEPTS.md).
Host namespace remains `(registration, allocation)`, separate from tenant Pool/ProviderBinding, credential, and volume.
No demand alone does not stop residency. Capacity admission/queues are retired.

### 资源契约

The Guest uses OCI/runsc/cgroup v2. Workload `cpu.max`/`memory.max`/`memory.high` are `max`. Workload CPU weight is 100.
PID/disk limits remain, without CPU/memory admission limits, `memory.min`, `memory.low`, or ballooning.
Workload/system parents share CPU/memory without fixed partitions. Host VM memory validation remains, without CPU/latency guarantees.

Sample memory.current/stat/pressure/events.local every 5s. Count gVisor memfd/shmem/file. RSS/anon alone or subtracting all file memory is incorrect.
Pressure enters after three samples ≥90% current/max or ≥10% PSI full avg10, or immediately on parent local oom/oom_kill increments.
Exit after three samples <80% current/max and <1% PSI full avg10. Measure initial thresholds; never use for SLA/admission.
Child OOM does not trigger pool reclamation.

One pool-wide candidate: oldest idle, scoped to registration/allocation/instance; observe only through its registration.
Salix requires no demand and idle ≥60s. Connector settles obligations before quiet. host stops the expected instance only.
Cancel on demand, changed instance, incomplete quiet, or 30s timeout. Do not reselect timed-out candidates that round.
Resample before another selection. No candidate means kernel OOM, never busy-instance killing, data deletion, or busy migration.
Parent OOM can kill other tenants' busy instances. Use existing failure convergence without unlimited restart or memory.oom.group.
Leaf settings require real runsc process-tree evidence.

Preserve commands, request IDs, payloads, deadlines, storage action-required, and start/stop/quiesce exclusion.
Recovery supports more than four instances. Preserve old migrations. Repair forward.
Sampling is parent O(1), with a stable child cursor, ≤16 instances, ≤4 RPCs, and a 5s deadline.
Indexed and paged work replaces total inventory gates. Coverage time scales with count. A timeout marks the sample unknown and advances the cursor.
Stale samples neither block start nor authorize quiet/stop. Recheck before reclamation.

### Session 迁移协议

Freeze Agent Session creation and per-Session dispatch. accepted inputs retain their queue.
Page all Sessions, transfer individually, then CAS Agent binding before unfreezing. Preserve business IDs and shared Connector/VMM service.
ExternalSessionStore commands carry Session/operation IDs, expected source/target bindings, and Group/Agent/Compute authorization.
SessionRecord.migration contains operation/source/target/phase/deadline/error, not a new entity.
Persist draining → staged → retiring → committed:

1. Drain: persist freeze; settle execution, async work, approvals/waits, and input/event ACKs. Global health/quiet is insufficient. Do not fabricate completion or replay unknown effects.
2. Stage: export workspace, native history, and settled Connector identity to persistent target staging. Verify readability/authentication without model, tool, or target dispatch.
3. Retire: persist irreversible retiring, recheck drain, then idempotently seal source execution. A lost ACK permits only status/seal retry. The operation pins source/target; preserve shared credentials and other Sessions.
4. Commit: after confirmed seal, install staging, CAS source/phase, update binding, invalidate old authority, then allow target dispatch. Reject late token/owner events; repair derived candidates from Session state.
5. Finish: next input continues the same Session/native ID. CAS Agent after all Sessions commit and clear transient state. Source deletion still requires owner authorization.

There is no SessionRecord/Postgres/bbolt transaction. Freeze and one-way phases fail closed.
Cancel only before retiring; afterward repair forward. Restart resumes persisted phases. A failed Agent update after Session commit keeps creation frozen.
Allow one Session per Agent and one transfer per Host; pages are ≤100. Cursor is rescannable progress; Session phase is authoritative.
Drain has 10m; transfer/validation has 30m. Retries do not extend deadlines. Expiry is actionable and preserves source, queue, and approvals.

Owner-approved abandonment archives unmigratable Workers before per-Session discard.
Delete only exact-capability bbolt rows, managed workspace/archive, and native resume files. Preserve shared root, credentials, and other Sessions; persist scope/plan for retry.
Uncertain scope, unsettled execution, or scan overflow retains the archive and fails closed.

### 原生状态、文件和认证：技术选择

`external_runtime_state.go` uses bbolt. Export only selected settled identity, never all state.db, recovery tokens, or unrelated data.
Rewrite command/workspace, retain native ID, and keep source seals until old authority closes.
Reuse authenticated typed prepare/export/import/retire/status/discard; add no public import API.
Stream Go tar compression. Bound manifest paths/count/bytes and pre-execution stat/capacity checks.
Reject unsupported entries, escaping links, traversal, and devices. Do not truncate or skip. Preserve internal links, permissions, and uncommitted files.
Persist complete staging before rename; clean only this operation's staging.
Group `/archive` retains links and native state.

Target uid1000, HOME/WORKDIR=/workspace, cwd=`/workspace/.comma/workspaces/<session>`.
Update startup/identity cwd. rewrite only Pi header.cwd and Codex local_image.path, preserving bodies.
Manifest external mounts/services/files. unmet dependencies block cutover. Historical absolute paths have no access guarantee.

| Locked provider | Migration |
| --- | --- |
| Codex 0.153.0 | Keep stdio JSON-RPC and thread/resume(threadId,cwd). Move selected rollout/references into target CODEX_HOME sessions; verify with thread/read. Do not fork or copy the whole home/auth store. |
| Claude 2.1.258 | Resume native ID. Move its project JSONL, subagents, and sidecars. Use target cwd without history rewrite. |
| Pi 0.84.4 | Use session-dir and session path/ID. Move selected JSONL/branch state into Connector `external-runtime/pi/<session>`; do not discover it from source cwd. |

Reuse Go providers, not an SDK; versions are in `systems/runtime-images/runtime-dependencies.lock.json`.
Test locked-CLI resume. Kimi returns `unsupported_provider`; never substitute provider/Session.
ComputeRuntimeAuth supplies authorized tenant auth, not credential stores. Reauthenticate non-exportable credentials and install locked Linux dependencies before cutover.

### 文件落点与结构预算

AgentControl owns creation freeze; ExternalSessionActor/Store owns phases/CAS; ExternalSessionMigration coordinates transfer.
Connector files/seals share archive exclusion. Restore archives before transfer; freeze prevents deletion.
Compute keeps ComputeRuntimeAuth. AgentVMM/HostClient/gateway route candidates; ComputeReconciler checks demand.
Images keep three locked providers and persistent HOME. VMM workload_run/observation owns cursors/candidates; resourcev2/guest quota owns cgroups; remoteconnector/remote_compute owns scoped routing/fencing.

Preserve queue consumers, import storage/action-required, release obligations, and generic connected runtimes. Session migration excludes appliance reservations. Controller redesign can remove them. Use new migrations; retire only selected tenant bindings.
Budget: no new entity/scheduler/database/public API; one Session migration value, one source seal per Session, one configuration-owned Agent freeze.
Host: one candidate and sampling cursor/counters. At most one Salix coordinator and Connector migration module; three static provider branches, no registry.
Transport: prepare/export/import/retire/status/discard, candidate, workload_oom_events. Remove compatibility after transfer and old-authority closure.

### 实施与验证

Test six residents, restart, pressure/demand races, OOM, stale stop, phase restart, lost seal ACK, archive races, old tokens, approvals, late ACKs, and same-native-ID continuation. Test rebind separately and report real CLI/cross-machine evidence.
Run affected Compute, Session, Connector, VMM, cgroup/Linux, docs, policy, and TLA checks.
WorkloadRunLifecycle covers execution rights, quiesce, and expected stop. ComputeCapacityAction covers import storage. Migration maps to retained ownership/accepted-work models; cross-store recovery needs fault E2E. Expected counterexamples must violate; bounded TLC is not runtime proof.

### 发布、证据与完成条件

Evidence covers six residents, VM/Host restart, pressure/OOM, and three locked CLIs with transfer, same-ID continuation, and target restart. Cross-machine proof remains separate.
Inventory registration, Agent/Session, provider/version, dependencies, and target volumes without secrets. Damaged state, unknown providers, unmovable files, or missing auth fail closed. Verify IDs, input, uncommitted files, source closure, and target restart; report incomplete transfers.
Use graceful mainline release; mixed versions do not justify staging shutdown. Converge within budgets or actionable errors.
Under release policy, back up and restore-verify affected durable files, credentials, and records. Never erase them as cache or weaken billing, auth, or accepted-work guarantees.

### 运维入口

Running mainline only, via bin/comma rpc:

```elixir
SalixAgent.Release.session_migration("status", %{
  "tenant_id" => tenant_id, "agent_id" => agent_id
})
SalixAgent.Release.session_migration("step", %{
  "tenant_id" => tenant_id, "agent_id" => agent_id,
  "operation_id" => operation_id, "target" => target_binding
})
```

Status returns ≤100 entries plus a cursor without capability tokens. Target an authorized same-provider Workload.
Repeat the same ID, one page/block per call, until `complete:true`. On error, inspect phase/deadline. Cancel before irreversible phases; afterward repair forward without extending deadlines or restoring source execution.
Operation IDs: 1–128 letters, digits, `_`, or `-`. A global step lock bounds throughput. Approved `archive_unmigratable` archives by Agent, tenant, binding, Session, and operation ID before scoped retryable deletion.
