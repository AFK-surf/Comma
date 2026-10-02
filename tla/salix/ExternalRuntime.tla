-------------------------- MODULE ExternalRuntime --------------------------
(***************************************************************************)
(* External session input acceptance and native lifecycle projection.        *)
(*                                                                           *)
(* The actor dispatches the exact ordered prefix through the first provider  *)
(* source under a deterministic dispatch_id. Connector ACK means only that   *)
(* the prefix is durably owned in connector-local storage; the Server then   *)
(* removes exactly that prefix.                                               *)
(* Native running/settled/failed evidence is a separate event stream fenced   *)
(* by dispatch_id, execution_id, capability/binding, and a source watermark.  *)
(* Connector transport generations affect observation freshness, not the     *)
(* stable session capability or accepted queue ownership.                     *)
(* A terminal Server-to-Connector dispatch failure retains the durable queue  *)
(* and parks the full queued fence for this actor lifetime. A stale wake       *)
(* cannot immediately redispatch it; newly admitted input changes that fence  *)
(* and releases one fresh prefix attempt. A non-terminal                       *)
(* running-session steer failure does not install that fence: the existing     *)
(* execution stays running and the same queued steer remains dispatchable.     *)
(* Even a terminal failure installs the fence only after its durable failure   *)
(* record commits; persistence failure leaves the same snapshot dispatchable.  *)
(* Financial refusal logs the exact input prefix before local queue removal.  *)
(* Restart retains that refusal; new input is not part of the refused prefix. *)
(* LogLocalRefusal/ApplyLocalRefusal map to ExternalSessionStore rejection     *)
(* records and commit_status_record; neither changes an existing execution.  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS MaxMsg, MaxExec, AckConfirmsRunning, FenceExecution,
          ExactSnapshotAck, FenceCapability, FenceFailedDispatch,
          FenceOnlyTerminalFailure, FenceOnlyPersistedFailure,
          RestartReleasesFailedDispatch, IsolateProviderSource, DurableLocalRefusal

Msg == 1..MaxMsg
Exec == 1..MaxExec
Dispatch == 0..MaxMsg
Statuses == {"idle", "starting", "running", "failed", "unknown"}
WorkStates == {"running", "settled", "failed"}
DispatchKinds == {"none", "terminal", "steer", "unknown"}
FailurePersistenceStates == {"none", "durable", "error"}

VARIABLES locallyRejected,   \* durable Server-owned financial refusal records
          enqueued,          \* all messages durably admitted by Server
          queue,             \* current durable external input queue
          connectorOwned,    \* messages durably accepted in connector DB
          records,           \* accepted input materialized in SessionRecords
          nextMsg,
          actorPC,
          snapshot,
          dispatch,
          queueFence,       \* full queue tail captured for retry fencing
          dispatchKind,     \* in-flight mode, retained after failure as witness
          failurePersistence, \* durable failure record outcome for last attempt
          failedDispatch,   \* actor-lifetime fence for the last failed batch
          targetDispatch,
          targetExecution,
          status,
          evidenceDispatch,
          evidenceExecution,
          sourceWatermark,
          nextRecord,
          connectorRun,
          availabilityRun,
          connected,
          capabilityCurrent,
          staleCapabilityAppend

vars == <<locallyRejected, enqueued, queue, connectorOwned, records, nextMsg, actorPC,
          snapshot, dispatch, queueFence, dispatchKind, failurePersistence,
          failedDispatch, targetDispatch, targetExecution, status,
          evidenceDispatch, evidenceExecution, sourceWatermark, nextRecord,
          connectorRun, availabilityRun, connected, capabilityCurrent,
          staleCapabilityAppend>>

TypeOK ==
  /\ locallyRejected \subseteq Msg
  /\ enqueued \subseteq Msg /\ queue \subseteq Msg
  /\ connectorOwned \subseteq Msg /\ records \subseteq Msg
  /\ nextMsg \in 1..(MaxMsg + 1)
  /\ actorPC \in {"idle", "await_ack"}
  /\ snapshot \subseteq Msg /\ dispatch \in Dispatch
  /\ queueFence \in Dispatch
  /\ dispatchKind \in DispatchKinds
  /\ failurePersistence \in FailurePersistenceStates
  /\ failedDispatch \in Dispatch
  /\ targetDispatch \in Dispatch /\ targetExecution \in 0..MaxExec
  /\ status \in Statuses
  /\ evidenceDispatch \in Dispatch /\ evidenceExecution \in 0..MaxExec
  /\ sourceWatermark \in 0..(MaxMsg * MaxExec * 3 + 3)
  /\ nextRecord \in 1..(MaxMsg * MaxExec * 3 + 4)
  /\ connectorRun \in 1..3 /\ availabilityRun \in 1..3
  /\ connected \in BOOLEAN /\ capabilityCurrent \in BOOLEAN
  /\ staleCapabilityAppend \in BOOLEAN

Init ==
  /\ locallyRejected = {}
  /\ enqueued = {} /\ queue = {} /\ connectorOwned = {} /\ records = {}
  /\ nextMsg = 1 /\ actorPC = "idle" /\ snapshot = {} /\ dispatch = 0
  /\ queueFence = 0
  /\ dispatchKind = "none"
  /\ failurePersistence = "none"
  /\ failedDispatch = 0
  /\ targetDispatch = 0 /\ targetExecution = 0 /\ status = "idle"
  /\ evidenceDispatch = 0 /\ evidenceExecution = 0
  /\ sourceWatermark = 0 /\ nextRecord = 1
  /\ connectorRun = 1 /\ availabilityRun = 1 /\ connected = TRUE
  /\ capabilityCurrent = TRUE /\ staleCapabilityAppend = FALSE

MaxOf(S) == CHOOSE x \in S : \A y \in S : x >= y
MinOf(S) == CHOOSE x \in S : \A y \in S : x <= y

DispatchPrefix(S) == IF IsolateProviderSource THEN {MinOf(S)} ELSE S

Enqueue ==
  /\ nextMsg <= MaxMsg
  /\ enqueued' = enqueued \cup {nextMsg}
  /\ queue' = queue \cup {nextMsg}
  /\ nextMsg' = nextMsg + 1
  /\ UNCHANGED <<locallyRejected, connectorOwned, records, actorPC, snapshot, dispatch,
                 queueFence, dispatchKind, failurePersistence, failedDispatch,
                 targetDispatch, targetExecution, status, evidenceDispatch,
                 evidenceExecution, sourceWatermark, nextRecord, connectorRun,
                 availabilityRun, connected, capabilityCurrent,
                 staleCapabilityAppend>>

\* input_batch_id is derived from the last message in the selected prefix;
\* the actor-local terminal failure fence separately captures the full queue.
BeginDispatch ==
  /\ actorPC = "idle" /\ queue # {} /\ capabilityCurrent
  /\ MinOf(queue) \notin locallyRejected
  /\ (~FenceFailedDispatch \/ MaxOf(queue) # failedDispatch)
  /\ snapshot' = DispatchPrefix(queue)
  /\ dispatch' = MaxOf(DispatchPrefix(queue))
  /\ queueFence' = MaxOf(queue)
  /\ targetDispatch' = MaxOf(DispatchPrefix(queue))
  /\ actorPC' = "await_ack"
  \* Session admission precedes RPC. A failed status observation does not
  \* gate that RPC or certify whether a previous execution is still active.
  /\ dispatchKind' \in
       {"unknown", IF status = "running" /\ targetExecution # 0 THEN "steer" ELSE "terminal"}
  /\ failurePersistence' = "none"
  /\ IF dispatchKind' = "unknown"
       THEN /\ status' = "unknown"
            /\ UNCHANGED <<targetExecution, evidenceDispatch, evidenceExecution>>
       ELSE IF status = "running" /\ targetExecution # 0
       THEN UNCHANGED <<status, targetExecution, evidenceDispatch,
                        evidenceExecution>>
       ELSE /\ status' = "starting"
            /\ targetExecution' = 0
            /\ evidenceDispatch' = 0
            /\ evidenceExecution' = 0
  /\ UNCHANGED <<locallyRejected, enqueued, queue, connectorOwned, records, nextMsg,
                 failedDispatch,
                 sourceWatermark, nextRecord, connectorRun, availabilityRun,
                 connected, capabilityCurrent, staleCapabilityAppend>>

\* Connector atomically persists the batch before returning ACK.  Server
\* materializes those exact messages and removes only that snapshot; a suffix
\* enqueued while the request was in flight remains queued.
AcceptSnapshot ==
  /\ actorPC = "await_ack" /\ snapshot \subseteq queue
  /\ connectorOwned' = connectorOwned \cup snapshot
  /\ records' = records \cup snapshot
  /\ queue' = IF ExactSnapshotAck THEN queue \ snapshot ELSE {}
  /\ IF AckConfirmsRunning /\ status = "starting"
       THEN /\ status' = "running"
            /\ UNCHANGED <<targetExecution, evidenceDispatch,
                           evidenceExecution>>
       ELSE UNCHANGED <<status, targetExecution, evidenceDispatch,
                        evidenceExecution>>
  /\ actorPC' = "idle" /\ snapshot' = {} /\ dispatch' = 0
  /\ queueFence' = 0
  /\ dispatchKind' = "none"
  /\ failurePersistence' = "none"
  /\ failedDispatch' = 0
  /\ UNCHANGED <<locallyRejected, enqueued, nextMsg, targetDispatch, sourceWatermark,
                 nextRecord, connectorRun, availabilityRun, connected,
                 capabilityCurrent, staleCapabilityAppend>>

\* A user-owned runtime error, dependency deadline, invalid result, or
\* admission failure keeps the exact durable snapshot queued.  Once its
\* lifecycle failure record is durable, a terminal start installs the
\* actor-local fence that coalesces already-queued recovery wakes; it is
\* deliberately reset by actor restart rather than persisted as durable
\* poison.  A non-terminal steer explicitly clears that fence and remains
\* eligible for a later actor wake.  FenceOnlyTerminalFailure is the mutation
\* switch for the historical bug that parked failed steers.
PersistDispatchFailure ==
  /\ actorPC = "await_ack"
  /\ failurePersistence' = "durable"
  /\ failedDispatch' =
       IF dispatchKind \in {"steer", "unknown"} /\ FenceOnlyTerminalFailure
         THEN 0
         ELSE queueFence
  /\ actorPC' = "idle" /\ snapshot' = {} /\ dispatch' = 0
  /\ queueFence' = 0
  /\ IF status = "starting" /\ dispatchKind = "terminal"
       THEN /\ status' = "failed"
            /\ evidenceDispatch' = targetDispatch
            /\ evidenceExecution' = targetExecution
       ELSE UNCHANGED <<status, evidenceDispatch, evidenceExecution>>
  /\ UNCHANGED <<locallyRejected, enqueued, queue, connectorOwned, records, nextMsg,
                 targetDispatch, targetExecution, sourceWatermark, nextRecord,
                 connectorRun, availabilityRun, connected, capabilityCurrent,
                 staleCapabilityAppend, dispatchKind>>

\* Failure-record storage is a system dependency.  A clean error/CAS miss has
\* not made the terminal observation durable, so it cannot activate the
\* actor-local failed-batch fence.  The unchanged snapshot remains eligible
\* for a later actor wake.  The mutation switch reproduces fencing before the
\* persistence result is known.
DispatchFailurePersistenceError ==
  /\ actorPC = "await_ack"
  /\ failurePersistence' = "error"
  /\ failedDispatch' =
       IF FenceOnlyPersistedFailure THEN 0 ELSE queueFence
  /\ actorPC' = "idle" /\ snapshot' = {} /\ dispatch' = 0
  /\ queueFence' = 0
  /\ UNCHANGED <<locallyRejected, enqueued, queue, connectorOwned, records, nextMsg,
                 targetDispatch, targetExecution, status, evidenceDispatch,
                 evidenceExecution, sourceWatermark, nextRecord, connectorRun,
                 availabilityRun, connected, capabilityCurrent,
                 staleCapabilityAppend, dispatchKind>>

\* Actor death abandons only process-local in-flight/fence state.  The Server
\* queue and all Connector/lifecycle facts remain durable.  The mutation
\* switch makes the documented restart-release progress claim executable.
ActorRestart ==
  /\ actorPC' = "idle"
  /\ snapshot' = {}
  /\ dispatch' = 0
  /\ queueFence' = 0
  /\ dispatchKind' = "none"
  /\ failurePersistence' = "none"
  /\ failedDispatch' =
       IF RestartReleasesFailedDispatch THEN 0 ELSE failedDispatch
  /\ UNCHANGED <<locallyRejected, enqueued, queue, connectorOwned, records, nextMsg,
                 targetDispatch, targetExecution, status, evidenceDispatch,
                 evidenceExecution, sourceWatermark, nextRecord, connectorRun,
                 availabilityRun, connected, capabilityCurrent,
                 staleCapabilityAppend>>

\* Financial refusal is local input disposition, not Connector acceptance.
\* Log the exact prefix before removing it; new Enqueue tails may interleave.
LogLocalRefusal(prefix) ==
  /\ actorPC = "idle" /\ queue # {}
  /\ MinOf(queue) \notin locallyRejected
  /\ locallyRejected' = IF DurableLocalRefusal THEN locallyRejected \cup prefix ELSE locallyRejected
  /\ records' = IF DurableLocalRefusal THEN records \cup prefix ELSE records
  /\ queue' = IF DurableLocalRefusal THEN queue ELSE queue \ prefix
  /\ UNCHANGED <<enqueued, connectorOwned, nextMsg, actorPC, snapshot, dispatch,
                 queueFence, dispatchKind, failurePersistence, failedDispatch,
                 targetDispatch, targetExecution, status, evidenceDispatch,
                 evidenceExecution, sourceWatermark, nextRecord, connectorRun,
                 availabilityRun, connected, capabilityCurrent, staleCapabilityAppend>>

ApplyLocalRefusal ==
  /\ actorPC = "idle" /\ queue # {} /\ MinOf(queue) \in locallyRejected
  /\ queue' = queue \ locallyRejected
  /\ UNCHANGED <<locallyRejected, enqueued, connectorOwned, records, nextMsg,
                 actorPC, snapshot, dispatch, queueFence, dispatchKind,
                 failurePersistence, failedDispatch, targetDispatch, targetExecution,
                 status, evidenceDispatch, evidenceExecution, sourceWatermark,
                 nextRecord, connectorRun, availabilityRun, connected,
                 capabilityCurrent, staleCapabilityAppend>>

(***************************************************************************)
(* Runtime events are persisted before projection.  Matching identity and a *)
(* newer watermark can advance lifecycle; old identity/out-of-order records  *)
(* remain audit records but cannot overwrite current work.                   *)
(***************************************************************************)
RuntimeEvent(d, e, ws) ==
  /\ capabilityCurrent /\ d \in Dispatch \ {0} /\ e \in Exec
  /\ nextRecord <= MaxMsg * MaxExec * 3 + 3
  /\ nextRecord' = nextRecord + 1
  /\ LET matches ==
       d = targetDispatch /\
       (targetExecution = 0 \/ targetExecution = e)
     IN
       IF (matches \/ ~FenceExecution) /\ nextRecord > sourceWatermark
         THEN /\ targetExecution' = IF matches THEN e ELSE targetExecution
              /\ evidenceDispatch' = d /\ evidenceExecution' = e
              /\ sourceWatermark' = nextRecord
              /\ status' =
                   IF ws = "running" THEN "running"
                   ELSE IF ws = "settled" THEN "idle"
                   ELSE "failed"
         ELSE UNCHANGED <<targetExecution, evidenceDispatch,
                          evidenceExecution, sourceWatermark, status>>
  /\ UNCHANGED <<locallyRejected, enqueued, queue, connectorOwned, records, nextMsg, actorPC,
                 snapshot, dispatch, queueFence, dispatchKind, failurePersistence,
                 failedDispatch, targetDispatch, connectorRun, availabilityRun,
                 connected, capabilityCurrent, staleCapabilityAppend>>

StartingTimeout ==
  /\ status = "starting"
  /\ status' = "unknown"
  /\ UNCHANGED <<locallyRejected, enqueued, queue, connectorOwned, records, nextMsg, actorPC,
                 snapshot, dispatch, queueFence, dispatchKind, failurePersistence,
                 failedDispatch, targetDispatch, targetExecution,
                 evidenceDispatch, evidenceExecution, sourceWatermark,
                 nextRecord, connectorRun, availabilityRun, connected,
                 capabilityCurrent, staleCapabilityAppend>>

Disconnect ==
  /\ connected
  /\ connected' = FALSE
  /\ UNCHANGED <<locallyRejected, enqueued, queue, connectorOwned, records, nextMsg, actorPC,
                 snapshot, dispatch, queueFence, dispatchKind, failurePersistence,
                 failedDispatch, targetDispatch, targetExecution, status,
                 evidenceDispatch, evidenceExecution, sourceWatermark,
                 nextRecord, connectorRun, availabilityRun, capabilityCurrent,
                 staleCapabilityAppend>>

\* Stable capability survives transport reconnect.  PublicStatus below
\* invalidates an observation from an older connector run.
Reconnect ==
  /\ ~connected /\ connectorRun < 3
  /\ connectorRun' = connectorRun + 1
  /\ availabilityRun' = connectorRun + 1
  /\ connected' = TRUE
  /\ UNCHANGED <<locallyRejected, enqueued, queue, connectorOwned, records, nextMsg, actorPC,
                 snapshot, dispatch, queueFence, dispatchKind, failurePersistence,
                 failedDispatch, targetDispatch, targetExecution, status,
                 evidenceDispatch, evidenceExecution, sourceWatermark,
                 nextRecord, capabilityCurrent, staleCapabilityAppend>>

Rebind ==
  /\ capabilityCurrent
  /\ capabilityCurrent' = FALSE
  /\ UNCHANGED <<locallyRejected, enqueued, queue, connectorOwned, records, nextMsg, actorPC,
                 snapshot, dispatch, queueFence, dispatchKind, failurePersistence,
                 failedDispatch, targetDispatch, targetExecution, status,
                 evidenceDispatch, evidenceExecution, sourceWatermark,
                 nextRecord, connectorRun, availabilityRun, connected,
                 staleCapabilityAppend>>

AttemptStaleCapabilityEvent ==
  /\ ~capabilityCurrent
  /\ staleCapabilityAppend' = ~FenceCapability
  /\ UNCHANGED <<locallyRejected, enqueued, queue, connectorOwned, records, nextMsg, actorPC,
                 snapshot, dispatch, queueFence, dispatchKind, failurePersistence,
                 failedDispatch, targetDispatch, targetExecution, status,
                 evidenceDispatch, evidenceExecution, sourceWatermark,
                 nextRecord, connectorRun, availabilityRun, connected,
                 capabilityCurrent>>

Next ==
  \/ (\E cutoff \in queue : LogLocalRefusal({m \in queue : m <= cutoff}))
  \/ ApplyLocalRefusal
  \/ Enqueue \/ BeginDispatch \/ AcceptSnapshot \/ PersistDispatchFailure
  \/ DispatchFailurePersistenceError
  \/ ActorRestart
  \/ \E d \in Dispatch \ {0}, e \in Exec, ws \in WorkStates :
       RuntimeEvent(d, e, ws)
  \/ StartingTimeout \/ Disconnect \/ Reconnect \/ Rebind
  \/ AttemptStaleCapabilityEvent

Spec == Init /\ [][Next]_vars
RestartSpec == Spec /\ WF_vars(ActorRestart)

(***************************************************************************)
(* Queue/acceptance accounting and lifecycle accuracy.                       *)
(***************************************************************************)
QueueAccounting ==
  /\ queue \cup connectorOwned \cup locallyRejected = enqueued
  /\ queue \cap connectorOwned = {}
  /\ connectorOwned \cap locallyRejected = {}
  /\ locallyRejected \subseteq records
  /\ records \subseteq enqueued

RefusedInputCannotDispatch ==
  actorPC = "await_ack" => snapshot \cap locallyRejected = {}

RefusalRecoveryEnabled ==
  actorPC = "idle" /\ queue # {} /\ MinOf(queue) \in locallyRejected
  => ENABLED ApplyLocalRefusal
AcceptedInputIsDurable ==
  connectorOwned \subseteq records /\ connectorOwned \subseteq enqueued

ProviderSourceIsolated ==
  actorPC = "await_ack" => Cardinality(snapshot) <= 1

\* A failed deterministic queue fence cannot become in-flight again in the
\* same actor lifetime. A larger full-queue fence remains enabled even when
\* its selected prefix has the same dispatch id, proving fresh durable input
\* can release one bounded retry without mixing the queued suffix.
FailedBatchCannotRedispatch ==
  failedDispatch # 0 /\ actorPC = "await_ack" => queueFence # failedDispatch

FreshInputReleasesFailedBatch ==
  actorPC = "idle" /\ failedDispatch # 0 /\ queue # {} /\
  MaxOf(queue) # failedDispatch /\ capabilityCurrent /\
  MinOf(queue) \notin locallyRejected
  => ENABLED BeginDispatch

\* Steer and unknown-mode errors are non-terminal. They leave the existing
\* execution observation intact and must not turn the terminal failed-batch guard
\* into durable poison for the still-pending steer snapshot.
FailedSteerRemainsDispatchable ==
  actorPC = "idle" /\ dispatchKind \in {"steer", "unknown"} /\ queue # {} /\
  capabilityCurrent /\
  MinOf(queue) \notin locallyRejected
  => /\ failedDispatch = 0
     /\ ENABLED BeginDispatch

UnpersistedFailureRemainsDispatchable ==
  actorPC = "idle" /\ failurePersistence = "error" /\ queue # {} /\
  capabilityCurrent /\
  MinOf(queue) \notin locallyRejected
  => /\ failedDispatch = 0
     /\ ENABLED BeginDispatch

UnfencedQueueIsDispatchable ==
  actorPC = "idle" /\ failedDispatch = 0 /\ queue # {} /\ capabilityCurrent /\
  MinOf(queue) \notin locallyRejected
  => ENABLED BeginDispatch

ActorRestartEventuallyReleasesTerminalFence ==
  failedDispatch # 0 ~> failedDispatch = 0

\* ACK cannot create native-running truth.  Existing running steer remains
\* valid because it already carries matching evidence.
RunningHasMatchingEvidence ==
  status = "running" =>
    /\ targetExecution # 0
    /\ evidenceDispatch # 0
    /\ evidenceExecution = targetExecution

TerminalHasMatchingEvidence ==
  status \in {"idle", "failed"} /\ sourceWatermark > 0 =>
    /\ evidenceDispatch = targetDispatch
    /\ evidenceExecution = targetExecution

StaleCapabilityCannotAppend == ~staleCapabilityAppend

PublicStatus ==
  IF status \in {"starting", "running"} /\
       (~connected \/ connectorRun # availabilityRun)
    THEN "unknown"
    ELSE status

LostObservationIsUnknown ==
  status \in {"starting", "running"} /\
  (~connected \/ connectorRun # availabilityRun)
  => PublicStatus = "unknown"

=============================================================================
