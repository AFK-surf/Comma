# Salix system-core TLA+ models

The [repository policy](../README.md) limits the entire model/config corpus to
5,000 physical lines and supersedes the former feature-by-feature inventory.
Only the following modules are retained. Their transition definitions, checked
properties, fault bounds and configurations are unchanged by the reduction.

`SalixIFC.decide/4` now calls `VerifiedKernel.IFC.decideChecked` through the static ETF NIF.
The [IFC Lean model](../../docs/verification.md) now covers request, writer, flow, declassification, and consent rules.
Membership resolution, receipt spending, and consent settlement remain at their existing owning seams.
The former `InformationFlow` and `InformationFlowConsent` modules and their eight configurations are retired.
Their replacements and trust boundaries are listed in the [IFC contract](../../docs/verification.md).

| Model                   | Checked boundary                                                                                                                                      | Implementation mapping                                                                             |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `S3`                    | Shared assumption: linearizable per-object conditional writes; applied/unapplied ambiguous outcomes                                                   | `SalixStore.S3` and its fault-injecting fake; helper, no standalone configuration                  |
| `HeadCommit`            | Unique owned epoch, honest handles, contiguous log and monotone committed epochs                                                                      | `SalixStore.Agent` claim/commit/release on the root object                                         |
| `Lease`                 | At most one currently valid ETag token; live-object epochs do not regress                                                                             | `SalixStore.Lease`, `SalixCluster.S3Lease`                                                         |
| `SessionEpochFence`     | No lower-epoch commit after a higher epoch lands; fenced runners stop dispatching                                                                     | Internal session store/state runtime-epoch CAS and runner fencing                                  |
| `RpcDeliver`            | Per-id durable deduplication, ACK implies durable queue append, session admission authority                                                           | `SalixAgent.deliver/3`, `AgentActor.verify_rpc_delivery_owner/1`, internal/external session stores |
| `SessionHotArchive`     | Archive chunk exists before hot-head advancement; ambiguous flush settlement; archived bytes agree with durable log                                   | Lean `Session.ArchivePublication` and `InternalSessionStore` hot CAS                               |
| `ArchiveAppend`         | A stale writer cannot roll back the archive below its committed watermark                                                                             | Conditional-publication abstraction; format-3 uses immutable create-only segment keys             |
| `ExternalRuntime`       | ACK transfers exactly the accepted prefix, not proof of running; native evidence uses exact execution/capability/source; failed dispatch retains work | External session actor/store and Connector durable-input/native-event boundary                     |
| `ComputeCapacityAction` | Guest import-capacity failures do not enter a timer retry loop                                                                                        | `SalixEnv.ComputeReconciler` claim settlement and candidate selection                              |

Provider output now consumes the Conversation log with a Participant cursor and conditional delivery receipts.
The retained ownership, conditional-write, and external Session acceptance boundaries do not change.
Provider retry, Task thread fencing, crash verification, and approved backlog disposal remain implementation-test contracts.
These tests do not prove exactly-once platform effects or add a retained-model progress claim.

RFC34 does not change an `ExternalRuntime` transition or progress claim. The
model already separates input-prefix ACK from exact native execution evidence.
Connector version 3 records now keep that evidence through terminal delivery
and Host release. The Host usage-right set is an instance-local bounded guard,
not another durable acceptance owner. Host and Connector fault tests cover its
acquire, release, orphan, and settlement behavior.

## Assumptions and honest limits

Session event reducers now execute in the Lean verified kernel.
The Actor and store boundaries retain the ownership, fencing, durable append,
and archive transitions mapped above. No retained model transition or progress
claim changes. Pure reducer behavior remains in implementation tests and Lean
properties, not replacement feature-level TLA+ models.

Read each module header and configuration for the actual finite bounds. S3 is
assumed linearizable per key, not globally transactional; ambiguous replies can
hide either applied or unapplied writes. Holder identifiers must distinguish
live processes. Session epochs come from the root ownership protocol; the
session model abstracts allocation and does not prove a composed end-to-end
execution theorem. RPC deduplication is per message identity, not exactly-once
external side effects. The retained RPC ghost second writer is an explicit
over-approximation, not a supported historical delivery mode.

Lease belief exclusion and globally monotone lease epochs across deletion are
**not** promised; their two expected counterexamples remain. The RPC fence can
race an owner move, so the residual stale-but-durable append counterexample
also remains. Do not turn these into passing assertions by weakening the model.

Safety configurations do not claim progress. Archive liveness configurations
use their declared fair actions and finite failure budgets; they do not promise
progress with permanently unavailable storage or unbounded owner churn. External
runtime acceptance and lifecycle safety do not prove eventual provider/native
completion. Removing the separate recovery/progress models makes no new promise.

## Signal account state

A Signal account has one ring-placed owner. `SalixSignal.Storage.claim/2`
raises `signal_accounts.owner_epoch`, and every write runs in one Postgres
transaction that first checks the caller still holds that epoch. This is the
`SessionEpochFence` abstraction: no lower-epoch commit lands after a higher
claim, and a fenced owner stops. The receive path commits the session advance
and the envelope admission together, then acknowledges the service. This is
the `RpcDeliver` property that an acknowledgement implies a durable append,
with per-envelope deduplication by server GUID. The mapping is by abstraction:
the store is a Postgres row with a transactional epoch check, not an S3
conditional write. No retained transition, fault bound or progress claim
changes. Voice calls hold no durable state except an idempotent billing charge
keyed by carrier call ID.

## Lease-aware agent routing

Agent placement prefers a connected holder of an unexpired durable lease over
the hash-ring preference. Unowned or expired agents use the ring; a disconnected
live holder fails closed until it reconnects or the lease expires. The owner
fence, session CAS and source-id deduplication remain unchanged. `RpcDeliver`
continues to over-approximate resolution with potentially stale placement, and
`HeadCommit`/`SessionEpochFence` retain their existing safety mappings. No new
model or stronger liveness property is claimed.

The RPC owner check records a fresh remote head as an epoch-guarded ownership-cell
fence before returning `not_owner`. The existing two-attempt retry then resolves
the durable owner instead of reusing the stale cell. `RpcDeliver.FenceRead`
already permits refusal and bounded re-resolution. `SessionEpochFence` retains
its durable Session-CAS fence and local dispatch-stop semantics. The earlier
root-head observation only stops local dispatch. It adds no commit authority. Explicit wake returns
placement failures to its caller. A successful cast does not prove processing
started. These runtime regressions add no model transition or liveness claim.

Participant delivery retains ownership-contention retries without spending the
business-error attempt budget, with a separate limit of 60 ownership refusals.
After this limit, the delivery enters `failed` with its last ownership error.
This retry policy and rolling-topology progress
are outside the retained safety abstraction; implementation regressions cover
live-holder preference, disconnected/expired holders, cross-node ingress, and
durable retry recovery. Permanent network/storage failure still offers no
eventual-delivery guarantee.

## Explicit external Session migration mapping

`ExternalSessionStore.migration_command/5` preserves the accepted queue through freeze,
staging, retirement, cancellation, and binding commit. These are stuttering steps for
`ExternalRuntime` accepted-work conservation. Dispatch ACK still consumes the exact prefix;
source event rejection still uses its capability fence. Releasing the actor-local failed
batch after commit or cancellation maps to the existing restart retry boundary.
`RpcDeliver` retains durable admission and deduplication while dispatch is frozen.
No retained transition, fairness assumption, or progress claim changes.

The source seal, native-file transfer, target activation order, cross-store crash recovery,
and provider background-task drain are outside those abstractions. Connector migration
and external Session owner regressions cover these boundaries; the locked CLI integration
can use real OpenRouter responses to check native continuation and target restart.
This is not a machine-checked proof of the complete migration protocol or provider progress.

## Workload image update mapping

Manual and automatic Workload updates pause pending input claims and preserve accepted inputs.
After confirmed stop, `Compute.prepare_runtime_bootstrap` retires the execution epoch and rebinds only pending inputs.
These steps preserve `ExternalRuntime` accepted-work and stale-capability boundaries. They add no provider progress claim.
Import storage failures park the existing ReconcilerClaim, preserving `ComputeCapacityAction.NoAutomaticRetry`.
No retained transition, fairness assumption, or invariant changes.
Implementation tests cover release target fencing, automatic admission, phase recovery, cancellation, and exact-container replacement.
Automatic deadline retries retain existing safety boundaries. They claim no progress when quiet evidence is unavailable.
The retained models do not prove native-file continuity or this whole update protocol.

## Commands and coverage

```sh
make tla-salix
./tla/salix/check.sh --list
./tla/salix/check.sh Lease Lease_BeliefExclusion Lease_EpochReset
```

`check.sh` is the exact 42-configuration roster, including safe variants,
liveness checks and expected violations. `ci-shard.sh` assigns every row once;
`HeadCommit` retains a dedicated shard. Parse errors, OOMs, and unexpected TLC
exits are failures, not accepted counterexamples.

All former Salix modules outside this table are retired from TLC/CI. Their old
source anchors and historical design/test reports are not current formal
coverage; see the scope policy before adding a replacement. Runtime regression
tests and product/data-safety guarantees are unchanged.

Identified Slack app users and human provider users use the same admitted authority abstraction in `IFC.System`.
Provider identity sealing and placement remain implementation-test obligations.

Ordinary Worker reports use the existing admitted-command boundary for one
send to their assigned Task. `SalixIM.TaskExecution` validates the assignment
and consumed delegator message before `SalixIFC.decide/4`. Implementation
regressions cover this call-local agent authority and denied private-source
reports. The model's reader sets, flow rules and receipt semantics do not change.

The Worker-selected Triage path reuses `RpcDeliver` for bounded same-identity
command retries and durable input deduplication. Its `no_wake` context append
claims durable acceptance only, not the model's fair-execution witness.
The Lean model's `Gates.commandScope` records the current Task/source/Worker authority obligation.
No retained distributed transition changes. Completion replay, private-history cursor, reaction recovery and
provider-confirmed thread continuation remain implementation regressions; these
models do not prove exactly-once Slack effects or end-to-end progress.

Router Task continuation uses the same call-local command boundary.
`SalixIM.TaskContinuation` validates canonical assignment, consumed Worker Message,
Router participant Session, and the protected Slack return target before the
IFC decision. Its admission checks are covered by implementation tests, not TLC.
The normalized command, source-label, and membership transitions remain unchanged.

## Compacted hot-history tails

The Session sealer now closes partial segments at the captured compaction ceiling.
`SessionHotArchive` still maps publication before hot-head advancement and ambiguous settlement.
The sealer now captures one durable revision for publication and CAS. A conflict reloads and repeats publication within the existing retry budget.
This refines the existing durable-source and ETag fences. It adds no model transition or progress claim.
`ArchiveAppend` still maps the monotone compaction ceiling and archive watermark.
Neither retained abstraction requires a byte-fill minimum.
These transitions and assumptions are unchanged. Implementation regressions cover partial tails,
failed publication, adopted boundaries, and complete transcript reads.
No new liveness guarantee applies to permanent storage failure or uncompacted history.

## Tool admission batching

Ordinary internal tool admission stores running records with the assistant intent before dispatch.
Terminal results retain the existing owner CAS and durable prerequisite ordering.
`HeadCommit` and `SessionEpochFence` still model the same committed boundaries and owner fences.
No retained transition, failure assumption, or liveness claim changes.
The Lean AgentLoop bracket still requires a successful intent commit before execution.
Its result-stage callback is a no-op when running observations were committed with that intent.
Runtime tests, not the retired RoundEffects model, check that the stored admission precedes actual dispatch.

The Session command adapter now separates owner-local `write` from
`durable_fence`. Local application does not correspond to durable append in
these models. The fence corresponds to the existing snapshot CAS and its
recovery prerequisites. Input acceptance and effect continuations follow fence
success. No unfenced command revision crosses an Actor mailbox boundary, so the
retained models gain no new acknowledged volatile state or recovery assumption.

Native Revision planning now retains materialization batches through local application, including wait expiry and asynchronous activation.
The Actor carries that pending revision to the same snapshot CAS without resubmitting retirement events.
Planning remains volatile and unacknowledged. `RpcDeliver`, `SessionEpochFence`, and the archive models retain their transitions and fault assumptions.

The `RpcDeliver` owner fence observation is one head read per delivery,
shared with placement and started by the provider callback ahead of the
facade; it is not skipped. This widens the modeled `FenceRead ; MoveOwner ;
CommitCAS` window by the callback's own duration only
(`RpcDeliver_FenceResidual.cfg` is the same accepted exposure). Placement
routes locally on a live ownership cell without that read; the fence still
uses it. The claim installs the cell before its best-effort lease index
write; the head CAS is unchanged.

Speculative provider computation is outside the retained durable-state models.
It covers the async-terminal continuation and the inbound activation alike.
Public deltas, response application, and tool dispatch still require the fence.
A yielded Router wait is a pending revision fenced by the activation CAS of the
same processing entry, or fenced before that entry ends.
The owner awaits the snapshot task within its callback, so another mailbox
entry cannot write through that in-flight CAS. The delegated writer carries the
owner's frozen epoch, including after a same-node claim change. Existing runtime
tests cover the provider overlap, failed-fence gate, and delegated epoch.

Round preparation refreshes compiled model-facing catalogs and configuration in one owner-local task and
adopts its result only at a later round boundary. Dynamic reply/tool authority is
still materialized for the current activation. Billing authorization overlaps
preparation; provider dispatch still requires authorization and the owner epoch.
The asynchronous session fence may start before provider preparation, but no
speculative output is released before that exact frozen revision commits.
Pending revisions persist their already-applied state without replaying events;
the original CAS base, result validation, normalization, recovery-marker ordering
and conflict handling remain unchanged. These are local scheduling/computation
changes: the retained `SessionEpochFence`, `RpcDeliver`, and archive mappings
above retain their existing transitions and assumptions. Implementation
regressions cover delayed refresh, denied billing and failed persistence.

## Slack recipient continuation

Slack callback admission reuses the Router's durable thread participation and
resolves Triage subscriptions against the exact channel authority generation.
Peer file replies enter the existing recipient lane as ordinary input; callback
signature checks, installation fencing, ambient owner pins, command authority,
and source-message deduplication remain in their existing seams. The retained
`RpcDeliver`, `HeadCommit`, and `SessionEpochFence` mappings do not change.
Admission and cross-channel isolation are covered by signed-callback regression
tests rather than a new feature-level model.

Runaway retirement uses the existing fenced Session commit and transcript ACK.
It abandons the current activation's reply obligations as failed, without
acknowledging queued deliveries, granting provider-send authority, or claiming
accepted asynchronous operations were cancelled. The retained CAS, epoch and
durable-delivery mappings are unchanged. Native and Actor regressions cover
this scheduling policy; the retained TLA+ suite does not prove it.

The Agent Conversation log path extends `RpcDeliver` with one target source position.
`SourceFrontierImpliesDurable` requires its frontier to imply a durable queue append.
Both normal and ambiguous successful CAS transitions commit these facts together.
The implementation mapping is `Session.Command.commitInput` and `conversation_source_advance`,
called through `ConversationConsumer` and `SessionDelivery.stage`.
External admission maps the same transition to `ExternalSessionStore.stage_delivery`,
whose single state CAS appends input and updates the Participant source position.
Multiple sources reuse this per-source invariant. No additional protocol owner is added.
Non-target scanning, multiple source positions, and notification liveness remain implementation-test concerns.
No new progress claim or external delivery guarantee follows from this abstraction.

## Codex startup recovery mapping

Codex persists its thread binding before starting or steering a native turn.
A prepared execution ID alone is not native execution evidence. Startup retains
an unbound execution, its durable input batches, and its Session identity.
Recovery retries the original input with the original execution ID. The record
version alone does not change the persist-before-submit ordering.

For a Host-backed claim, startup also retains the exact Host target. The existing
Host recovery check must succeed before the Connector retries the input. A
changed or unavailable target does not authorize replay. A missing input batch
does not authorize a fabricated input. These errors remain local to the affected
Session. Settling records retain their terminal evidence and use the existing
ACK/release path.

These steps preserve the existing `ExternalRuntime` failed-dispatch/restart and
input-prefix ACK boundaries. The abstract retry does not depend on the local
prepared execution ID. No retained model transition or progress guarantee changes.
Connector restart tests exercise the real Codex implementation and protocol
fixtures. They add no cross-container recovery guarantee.

## Cloud VM idle suspension mapping

Cloud VM quiet, carrier stop, and wake preserve the accepted queue and Session identity.
They are stuttering steps for `ExternalRuntime` accepted-work conservation.
Only the existing durable dispatch ACK consumes input. Binding and source capability fences remain unchanged.
The existing Session work projection supplies conservative demand without changing its mark-before-CAS protocol.
No retained invariant, transition, fairness assumption, or progress claim changes.
Implementation regressions cover quiet admission races, native snapshots, archive-before-destroy, uncertain release, and wake.
Compute now owns Group facts and uses the existing bounded reconciler for Cloudflare and VMM.
The legacy writer handoff and Connector snapshot import are runtime boundaries, not new retained-model transitions.
TLC does not prove provider keepalive, SQL/S3 handoff, or the complete archive protocol.
Cloudflare never-used VMs start their idle grace at readiness; used VMs still
require settlement and every archive retains the active-operation fence and
checkpoint-before-destroy ordering. Orphans whose group no longer exists can be
destroyed without starting the container to checkpoint it, retaining the VM
record on provider failure for retry. These provider cleanup steps do not change
the retained accepted-work or archive-publication models. Cloud VM lifecycle
regressions cover initial grace, admission races, archive/wake, and orphan retry;
TLC does not claim Cloudflare provider liveness.

## Session computation and persistence

Direct-log input, source progress, and activation share the existing Session CAS.
`stage_conversation` returns working state only. Its computation steps stutter in `RpcDeliver`.
`SourceFrontierImpliesDurable` and `AckImpliesDurable` still map to the committed input/frontier batch.
`SessionEpochFence` still checks the frozen epoch at CAS. Replayable read computation does not commit state or authorize effects.
Mutation-free terminal results and large-result content join the Session checkpoint before publication.
`SessionHotArchive` retains its content-before-head boundary when that checkpoint seals archive segments.
Resident frontier queries read committed state. Consuming a coalesced processing hint joins the same terminal/activation transition.
These mappings change no retained transition, invariant, fault bound, or fairness assumption.
Speculative cancellation, live configuration validation, and output gating remain runtime-test obligations.

### Cloud runtime account quota selection

Automatic runtime account selection excludes known, unreset provider-wide quota
exhaustion. Reconciliation may revoke an exhausted automatic binding only after
an idle-only Connector acknowledgement, before assigning a replacement; explicit
manual bindings are not rotated. Binding-row and Connector delivery-revision
fences remain authoritative. This does not introduce Task replay, change source
capabilities, or consume accepted input; the existing session and runtime-binding
abstractions are unchanged. Store, socket reconciliation, and Connector regression
tests cover quota selection, deferred rotation, and generation retirement rather
than adding a feature-level model.

Group provider cutover changes the current Compute allocation in one database transaction.
The Connector seals a quiet source before target publication. Accepted native work prevents export.
This does not change `ExternalRuntime` input-prefix ACK or exact native-evidence transitions.
Provider export/import, file preservation, and transport registration fencing use implementation regressions.
No retained model proves provider migration or adds a progress claim for unavailable providers.
## Router-owned meeting summaries

Meeting completion now stages a durable, input-versioned Router request before
publication. Summary submission uses the existing single-key S3 CAS boundary;
delivery retains its existing generation fence and provider checkpoints. Request
retries reuse source identity until timeout, then replace the request identity;
this does not strengthen RPC deduplication into exactly-once external delivery.
The retained S3/RPC/session abstractions are unchanged. Feature regressions cover
request-before-enqueue ordering, stale inputs/claims, bounded retries, scoped
submission and the existing attribution/publication gate. No new feature-level
model or eventual completion guarantee under a failed Router is claimed.
