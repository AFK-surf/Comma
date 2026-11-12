# Salix system-core TLA+ models

The [repository policy](../README.md) sets the line budget and scope. Only the
following modules are retained.

IFC authorization and consent use the [IFC Lean model](../../docs/verification.md), not TLA+.
`SalixIFC.decide/4` calls `VerifiedKernel.IFC.decideChecked` through the static ETF NIF.
Membership resolution, receipt spending, and consent settlement stay at their owning seams.

| Model                   | Checked boundary                                                                                                                                      | Implementation mapping                                                                             |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `S3`                    | Shared assumption: linearizable per-object conditional writes; applied/unapplied ambiguous outcomes                                                   | `SalixStore.S3` and its fault-injecting fake; helper, no standalone configuration                  |
| `HeadCommit`            | Unique owned epoch, honest handles, contiguous log and monotone committed epochs                                                                      | `SalixStore.AgentPGStore` root revision and epoch conditional updates                                         |
| `Lease`                 | At most one currently valid ETag token; live-object epochs do not regress                                                                             | `SalixStore.Lease`, `SalixCluster.S3Lease`, `SalixAgent.Tailnet.NodeRecord`                         |
| `SessionEpochFence`     | No lower-epoch commit after a higher epoch lands; fenced runners stop dispatching                                                                     | InternalSessionStore.PG captured epoch and revision; runner fencing                                  |
| `RpcDeliver`            | Per-id durable deduplication, ACK implies durable queue append, session admission authority                                                           | `SalixAgent.deliver/3`, `AgentActor.verify_rpc_delivery_owner/1`, internal session store           |
| `SessionHotArchive`     | Archive chunk exists before hot-head advancement; ambiguous flush settlement; archived bytes agree with durable log                                   | Lean `Session.ArchivePublication` and `InternalSessionStore.PG` publication/settlement                               |
| `ArchiveAppend`         | A stale writer cannot roll back the archive below its committed watermark                                                                             | Conditional-publication abstraction; format-3 uses immutable create-only segment keys             |
| `ComputeCapacityAction` | Guest storage-headroom failures do not enter a timer retry loop; a busy import slot retries the claim                                               | `SalixEnv.ComputeReconciler` claim settlement and candidate selection                              |

## Assumptions and honest limits

Session event reducers execute in the Lean verified kernel. Pure reducer
behavior is covered by implementation tests and Lean properties, not TLA+.

Read each module header and configuration for the actual finite bounds. S3 is
assumed linearizable per key, not globally transactional. Ambiguous replies can
hide either applied or unapplied writes. Holder identifiers must distinguish
live processes. Session epochs come from the root ownership protocol. The
session model abstracts allocation and does not prove a composed end-to-end
execution theorem. RPC deduplication is per message identity, not exactly-once
external side effects. The RPC ghost second writer is an explicit
over-approximation, not a supported delivery mode.

Lease belief exclusion and globally monotone lease epochs across deletion are
**not** promised. Their two expected counterexamples remain.
The former split-check RPC fence can race an owner move. Its stale-but-durable
append counterexample remains under `Spec`. `RpcDeliver_Safety` uses `PgSpec`: the
Agent authority check and Session write share one atomic transition, matching
the Agent row lock held through the PG Session transaction. It also checks
`NoStaleCommit`. This does not prove the importer, runtime routing, or external
effect execution. Do not turn expected counterexamples into passing assertions.

Safety configurations do not claim progress. Archive liveness configurations
use their declared fair actions and finite failure budgets. They do not promise
progress with permanently unavailable storage or unbounded owner churn. External
runtime acceptance and lifecycle safety do not prove eventual provider/native
completion.

The feature mappings below add no model transition, invariant, fault bound,
fairness assumption, or progress claim unless they say so. Implementation
regressions cover the behavior that the models do not prove.

## Triage run fence release

The [Triage contract](../../docs/bridge-for-teams/design.md) releases a run that
node drain interrupts before transport. A draining node starts no new run. Each
sealed generation has one fence record. `SalixIM.Triage.RunFence.release/1`
marks an `unused` or `claimed` fence `released`. The next run replaces it at
`fence_epoch + 1`. Every run write checks its run id and epoch in the same
conditional write. This is the `SessionEpochFence` abstraction: a replacement
is a higher-epoch claim, and no lower-epoch write lands after it. A released
record also refuses writes from its own run at the same epoch. The model does
not check this stronger refusal. Older nodes reject a released or epoch-stamped
record as invalid, so the `LegacyStrip` window cannot remove the epoch.

## Signal account state

A Signal account has one ring-placed owner. `SalixSignal.Storage.claim/2`
raises `signal_accounts.owner_epoch`, and every write runs in one Postgres
transaction that first checks the caller still holds that epoch. This is the
`SessionEpochFence` abstraction: no lower-epoch commit lands after a higher
claim, and a fenced owner stops. The receive path commits the session advance
and the envelope admission together, then acknowledges the service. This is
the `RpcDeliver` property that an acknowledgement implies a durable append,
with per-envelope deduplication by server GUID. The store is a Postgres row
with a transactional epoch check, not an S3 conditional write. Voice calls hold
no durable state except an idempotent billing charge keyed by carrier call ID.

## Lease-aware agent routing

Placement prefers a connected holder of an unexpired durable lease over the
hash-ring preference. Unowned or expired agents use the ring. A disconnected
live holder fails closed until it reconnects or the lease expires. `RpcDeliver`
over-approximates resolution with potentially stale placement.

The RPC owner check records a fresh remote head as an epoch-guarded
ownership-cell fence before it returns `not_owner`. The retry then resolves the
durable owner. `RpcDeliver.FenceRead` permits refusal and bounded
re-resolution. A root-head observation only stops local dispatch. It adds no
commit authority. A successful cast does not prove that processing started.

The `RpcDeliver` owner fence observation is one head read per delivery. It is
shared with placement and starts in the provider callback. This widens the
modeled `FenceRead ; MoveOwner ; CommitCAS` window by the callback's duration
(`RpcDeliver_FenceResidual.cfg` retains that former exposure). PG Session
commit closes this ownership window with its Agent row lock. Placement
routes locally on a live ownership cell without that read. The fence still
uses it.

Participant delivery retries are outside the safety abstraction (see
[Conversation log consumption](../../docs/salix/conversation-owner-actor.md#conversation-log-consumption)).
Permanent network or storage failure has no eventual-delivery guarantee.

## Workload image update mapping

Manual and automatic Workload updates pause pending input claims and preserve
accepted inputs. After confirmed stop, `Compute.prepare_runtime_bootstrap`
retires the execution epoch and rebinds only pending inputs. Import storage
failures park the existing ReconcilerClaim, which preserves
`ComputeCapacityAction.NoAutomaticRetry`. Namespace projection with the same
storage-headroom failure uses this boundary too, including an admitted command
whose outcome remains unknown. `CapacityChanges` cannot schedule another
attempt. Public explicit Retry maps to `OperatorRetries` and preserves the
Allocation, generation and resource limits. The model does not prove native
namespace idempotence, command-outcome preservation, native-file continuity or
the whole update protocol; implementation tests and runtime checks cover them.

## Commands and coverage

```sh
make tla-salix
./tla/salix/check.sh --list
./tla/salix/check.sh Lease Lease_BeliefExclusion Lease_EpochReset
```

`check.sh` is the exact configuration roster, including safe variants,
liveness checks and expected violations. `ci-shard.sh` assigns every row to one
CI shard. Parse errors, OOMs, and unexpected TLC exits are failures, not
accepted counterexamples. `HeadCommit.cfg` uses `VIEW View` to drop
history-only values. The module states why equal views have equal futures.

Former Salix modules outside the table are not current formal coverage. See the
scope policy before you add a replacement.

## Task and Router commands

Identified Slack app users and human provider users use the same admitted
authority abstraction in `IFC.System`. Provider identity sealing and placement
are implementation-test obligations.

Worker reports use the admitted-command boundary for one send to their assigned
Task. `SalixIM.TaskExecution` validates the assignment and consumed delegator
message before `SalixIFC.decide/4`. Router Task continuation uses the same
boundary. `SalixIM.TaskContinuation` validates canonical assignment, consumed
Worker Message, Router participant Session, and the protected Slack return
target before the IFC decision.

The Worker-selected Triage path reuses `RpcDeliver` for bounded same-identity
command retries and durable input deduplication. Its `no_wake` context append
claims durable acceptance only, not the model's fair-execution witness. The
Lean model's `Gates.commandScope` records the Task/source/Worker authority
obligation. These models do not prove exactly-once Slack effects or end-to-end
progress.

## Session body archival

The Session sealer captures bounded cuts through committed `last_seq`, independently of logical compaction.
`SessionHotArchive` maps immutable content before directory/watermark publication and frozen business settlement.
Independent archive publication advances the SQL revision while preserving the business storage identity.
Settlement confirms the original business revision. A later write must reload after a maintenance conflict.
`ResidentRevisionSound` rejects an old resident marked with the maintenance revision.
The model's hot window represents the PG body range after its archive watermark.
Runtime context can also contain cold records above the logical compaction watermark.
`ArchiveAdvance` publishes the directory and removes that PG body range atomically.
Reader tests check context restoration, fork, protected results, and paging. SQL failure and lost-reply tests check publication with deletion.
The Lean archive-publication projection assumes every input message is above the captured archive watermark.
`PG.archive_window` supplies this physical-plan premise with its `seq > archived_through` query; the proof does not identify an older resident payload with an archived object.
`ArchiveAppend` retains the conditional monotone-publication abstraction for the directory and watermark.
Its separate publication steps admit more interleavings than the atomic PG publication transaction.
Neither abstraction requires a byte-fill minimum. The checked liveness assumes bounded faults and fair progress;
it does not cover permanent storage failure or the engineering microbatch and idle-delay policy.

## Tool admission batching

Internal tool admission stores running records with the assistant intent before
dispatch. Terminal results keep the owner CAS and durable prerequisite ordering.
`HeadCommit` and `SessionEpochFence` model the committed boundaries and owner
fences. The Lean AgentLoop bracket requires a successful intent commit before
execution. Runtime tests, not TLA+, check that the stored admission precedes
dispatch.

The Session command adapter separates owner-local `write` from `durable_fence`.
Local application does not correspond to durable append in these models. The
fence corresponds to the PostgreSQL delta transaction and its captured owner
epoch and revision. Input acceptance and effect continuations follow confirmed commit. No unfenced command
revision crosses an Actor mailbox boundary.

Native Revision planning is volatile and unacknowledged. The Actor carries the
pending revision to the same frozen PostgreSQL submission without resubmitting
retirement events.

Speculative provider computation is outside the durable-state models. Public
deltas, response application, and tool dispatch still require the fence. A
yielded Router wait is a pending revision committed with activation in the
same processing entry, or fenced before that entry ends. The owner awaits the
commit task within its callback, so another mailbox entry cannot replace the
in-flight submission. The delegated writer carries the owner's frozen epoch.

Round preparation adopts refreshed catalogs and configuration only at a later
round boundary. Provider dispatch requires billing authorization and the owner
epoch. No speculative output is released before its frozen revision commits.
Pending revisions persist their delta without replaying events. The Session
transaction commits input identity, source progress, and due state together.
The former separate recovery-marker ordering is no longer a commit boundary.

## Slack recipient continuation

Slack callback admission reuses the Router's durable thread participation and
resolves Triage subscriptions against the exact channel authority generation.
Peer file replies enter the recipient lane as ordinary input. Signature checks,
installation fencing, ambient owner pins, command authority, and source-message
deduplication stay in their existing seams. Signed-callback regression tests
cover admission and cross-channel isolation.

Runaway retirement uses the fenced Session commit and transcript ACK. It
abandons the current activation's reply obligations as failed. It does not
acknowledge queued deliveries, grant provider-send authority, or claim that
accepted asynchronous operations were cancelled.

The Agent Conversation log path extends `RpcDeliver` with one target source
position. `SourceFrontierImpliesDurable` requires its frontier to imply a
durable queue append. Both normal and ambiguous successful CAS transitions
commit these facts together. The implementation mapping is
`Session.Command.commitInput` and `conversation_source_advance`, called through
`ConversationConsumer` and `SessionDelivery.stage`. Non-target scanning,
multiple source positions, and notification liveness are implementation-test
concerns.

## Cloud VM idle suspension mapping

Cloud VM quiet, carrier stop, and wake preserve the accepted queue and Session
identity. Only the durable dispatch ACK consumes input. The Session work
projection supplies conservative demand without changing its mark-before-CAS
protocol. Compute owns Group facts and uses the bounded reconciler for
Cloudflare and VMM. Used Cloudflare VMs require settlement, and every archive
keeps the active-operation fence and checkpoint-before-destroy ordering. An
orphan whose group no longer exists can be destroyed without a checkpoint. The
VM record stays on provider failure for retry. TLC does not prove provider
keepalive, Cloudflare liveness, SQL/S3 handoff, or the complete archive
protocol.

## Session computation and persistence

Direct-log input, source progress, and activation share the Session CAS.
`stage_conversation` returns working state only. Its computation steps stutter
in `RpcDeliver`. `SourceFrontierImpliesDurable` and `AckImpliesDurable` map to
the committed input/frontier batch. `SessionEpochFence` checks the frozen epoch
at CAS. Replayable read computation does not commit state or authorize effects.
Mutation-free terminal results and large-result content join the Session
checkpoint before publication. `SessionHotArchive` keeps its content-before-head
boundary when that checkpoint seals archive segments. Resident frontier queries
read committed state.

### Cloud runtime account quota selection

Automatic runtime account selection excludes known, unreset provider-wide quota
exhaustion. Reconciliation may revoke an exhausted automatic binding only after
an idle-only Connector acknowledgement, before it assigns a replacement.
Explicit manual bindings are not rotated. Binding-row and Connector
delivery-revision fences stay authoritative. This does not replay Tasks, change
source capabilities, or consume accepted input.

Group provider cutover changes the current Compute allocation in one database
transaction. The Connector seals a quiet source before target publication.
Accepted native work prevents export. No retained model proves provider
migration.

## Router-owned meeting summaries

Meeting completion stages a durable, input-versioned Router request before
publication. Summary submission uses the single-key S3 CAS boundary. Delivery
keeps its generation fence and provider checkpoints. Request retries reuse
source identity until timeout, then replace the request identity. This does not
make RPC deduplication exactly-once external delivery. No eventual completion
guarantee applies under a failed Router.
