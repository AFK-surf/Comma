import Std
import VerifiedKernel.StacklessStd

namespace VerifiedKernel.Proactive

/-- Sanitized card kind attached to a station-hosted chat's stop. -/
inductive CardKind where
  | none
  | options
  | text
  | login
  | secret
  | signin
  | device
  | rig
  deriving DecidableEq, Repr

/-- Interactive system cards (`login`, `secret`, `signin`, `device`, `rig`)
represent expiring local session gates (CLI OAuth codes, vault grants,
browser sign-ins, device unlocks) that must bypass ordinary handoff caps
and meeting deferral. -/
def CardKind.isUrgentSystem : CardKind → Bool
  | .login | .secret | .signin | .device | .rig => true
  | .none | .options | .text => false

/-- Current stop phase reported for a station-hosted chat concerning the owner. -/
inductive StopPhase where
  | working
  | need (card : CardKind)
  | done
  | failed
  deriving DecidableEq, Repr

/-- Proactive budget pool selected for a handoff. -/
inductive PoolKind where
  | ordinary
  | reserve
  | code
  deriving DecidableEq, Repr

/-- Canonical observation identity `(tag, atMs)` of a stop:
`tag = 1` for `need` (`needs_review:<at>`), `2` for `done`, `3` for `failed`. -/
structure Observation where
  tag : Int
  atMs : Int
  deriving DecidableEq, Repr

/-- Tracked state of a `station_task` matter in the Home conversation. -/
inductive MatterTrack where
  | unseen
  | open (obs : Observation)
  | handled (obs : Observation)
  | left (obs : Observation)
  deriving DecidableEq, Repr

/-- Command emitted by one reconciliation step on a `station_task` matter. -/
inductive StopTransition where
  | noop
  | present (obs : Observation) (pool : PoolKind) (urgencyHigh : Bool)
  | close (obs : Observation)
  deriving DecidableEq, Repr

def observationOf (phase : StopPhase) (atMs : Int) : Option Observation :=
  match phase with
  | .working => none
  | .need _ => some { tag := 1, atMs := atMs }
  | .done => some { tag := 2, atMs := atMs }
  | .failed => some { tag := 3, atMs := atMs }

def poolOfPhase : StopPhase → PoolKind
  | .need card => if card.isUrgentSystem then .code else .ordinary
  | _ => .ordinary

def urgencyHighOf (phase : StopPhase) (atMs sinceMs : Int) : Bool :=
  match phase with
  | .need card => card.isUrgentSystem || decide (atMs ≥ sinceMs)
  | .failed => decide (atMs ≥ sinceMs)
  | .working | .done => false

def alreadyObserved (track : MatterTrack) (obs : Observation) : Bool :=
  match track with
  | .open prev => decide (prev = obs)
  | .handled prev => decide (prev = obs)
  | .unseen | .left _ => false

/-- Monotonic transition for one station-hosted chat row against its Home matter state.
One `(tag, atMs)` stop presents at most once across both `open` and `handled` states;
moving back to `working` closes an `open` or `handled` stop into `left` once so the
next stop in the same chat starts fresh attention. -/
def stepStop (track : MatterTrack) (phase : StopPhase) (atMs sinceMs : Int) :
    MatterTrack × StopTransition :=
  match observationOf phase atMs with
  | none =>
    match track with
    | .unseen => (.unseen, .noop)
    | .left obs => (.left obs, .noop)
    | .open obs => (.left obs, .close obs)
    | .handled obs => (.left obs, .close obs)
  | some obs =>
    if alreadyObserved track obs then
      (track, .noop)
    else
      (.open obs, .present obs (poolOfPhase phase) (urgencyHighOf phase atMs sinceMs))

/-- Marks an open `station_task` matter handled immediately when the Router forwards
the owner's reply via `task.say`, preserving `obs` so stale index snapshots carrying
the same stop do not re-present. -/
def routerReplied (track : MatterTrack) : MatterTrack × Bool :=
  match track with
  | .open obs => (.handled obs, true)
  | .unseen | .handled _ | .left _ => (track, false)

/-- Only ordinary-pool handoffs wait behind a live calendar meeting; `code` and
`reserve` handoffs bypass meeting deferral. -/
def effectiveBusyUntil (pool : PoolKind) (meetingBusy : Option Int) : Option Int :=
  match pool, meetingBusy with
  | .ordinary, some untilMs => some untilMs
  | _, _ => none

/-- Bounded deferral & deadline liveness scheduler:
1. `nextAt > nowMs` always holds (strict forward progress);
2. For an actionable (`isAct = true`) matter with `reserveWindowAt = some rw`
   ahead of `nowMs`, `nextAt ≤ rw` even when `opensAt` or `busyUntil` is later. -/
def scheduleDeferral (opensAt nowMs leadMs : Int)
    (busyUntil dueMs reserveWindowAt : Option Int) (isAct : Bool) :
    Int × Option Int :=
  let dueWake :=
    match reserveWindowAt with
    | some rw =>
      if rw > nowMs then some rw
      else
        match dueMs with
        | some d =>
          if d - leadMs > nowMs then some (d - leadMs)
          else if d > nowMs then some d
          else none
        | none => none
    | none =>
      match dueMs with
      | some d =>
        if d - leadMs > nowMs then some (d - leadMs)
        else if d > nowMs then some d
        else none
      | none => none
  let baseOpen :=
    match busyUntil with
    | some b => if b > opensAt then b else opensAt
    | none => opensAt
  let bounded :=
    match isAct, reserveWindowAt with
    | true, some rw =>
      if rw > nowMs then min baseOpen rw else baseOpen
    | _, _ => baseOpen
  (max bounded (nowMs + 1), dueWake)

/-- Tail-recursive membership check over strong resource anchor bytes. -/
def containsAnchor : List ByteArray → ByteArray → Bool
  | [], _ => false
  | x :: rest, needle => if x == needle then true else containsAnchor rest needle

/-- Tail-recursive intersection check over strong resource anchor bytes. -/
def sharesAnchor : List ByteArray → List ByteArray → Bool
  | [], _ => false
  | x :: rest, ys => if containsAnchor ys x then true else sharesAnchor rest ys

/-- Active-worker absorption: a passive arrival that shares a strong resource
anchor (`github:`, `slack:`, `linear:`, `notion:`, `drive:`) with an active
`in_progress` station worker settles into the briefing without interrupting,
while direct human mentions/DMs, verification/login code hints, and incomplete
mail/attachment items always escalate. -/
def absorbByWorker (directHuman codeHint incomplete : Bool)
    (itemAnchors workerAnchors : List ByteArray) : Bool :=
  if directHuman || codeHint || incomplete then
    false
  else
    sharesAnchor itemAnchors workerAnchors

/-- Clamps a raw basis-point threshold into `[5000, 10000]`. -/
def clampThresholdBp (raw : Int) : Int :=
  let lo := if raw < 5000 then 5000 else raw
  if lo > 10000 then 10000 else lo

/-- Calibrated System-1 Jev pre-gate: suppresses to `:quiet` iff the classifier
selected `"quiet"` with calibrated probability meeting `[5000, 10000]` bp. -/
def gateJev (isQuietChoice : Bool) (probBp rawThresholdBp : Int) : Bool :=
  isQuietChoice && decide (probBp ≥ clampThresholdBp rawThresholdBp)

/-- Source lane that admitted one CFT Triage evaluation. -/
inductive TriageSourceMode where
  | callback
  | clickhouseEtl
  | periodicPatrol
  | scheduledRecheck
  | historicalReenactment
  | other
  deriving DecidableEq, Repr

/-- Syntactic addressee class of the frozen Slack decision target. -/
inductive TriageAddressee where
  | none
  | self
  | mixed
  | other
  | invalid
  deriving DecidableEq, Repr

/-- System-owned boundary action enforced for an explicit syntactic addressee. -/
inductive TriageBoundaryAction where
  | allow
  | forceSilenceOutsideAuthority
  | forceSilenceDuplicate
  | rejectTarget
  deriving DecidableEq, Repr

/-- Product-owner target route (`SalixIM.Triage.ProductDecision.target_route/2`):
in `clickhouse_etl`, an agent-authored message addressing `self` or `mixed`
normalizes to `none`; all other lanes preserve the syntactic addressee. -/
def triageTargetRoute (mode : TriageSourceMode) (addr : TriageAddressee)
    (actorIsAgent : Bool) : TriageAddressee :=
  match mode, actorIsAgent, addr with
  | .clickhouseEtl, true, .self => .none
  | .clickhouseEtl, true, .mixed => .none
  | _, _, _ => addr

/-- System-owned recipient boundary (`ProductDecision.enforce_target_boundary/2`). -/
def triageBoundaryAction : TriageAddressee → TriageBoundaryAction
  | .none => .allow
  | .other => .forceSilenceOutsideAuthority
  | .self | .mixed => .forceSilenceDuplicate
  | .invalid => .rejectTarget

/-- Ordinary domain-Worker intake gate (`SalixIM.Triage.WorkerSelection.intake?/1`):
only fresh ordinary lanes (`callback`, `clickhouse_etl`, `periodic_patrol`) whose
effective target route is `none` enter single-Worker `worker_pending` intake. -/
def triageIsIntake (mode : TriageSourceMode) (addr : TriageAddressee)
    (actorIsAgent : Bool) : Bool :=
  let ordinaryLane :=
    match mode with
    | .callback | .clickhouseEtl | .periodicPatrol => true
    | .scheduledRecheck | .historicalReenactment | .other => false
  ordinaryLane && decide (triageTargetRoute mode addr actorIsAgent = .none)

/-- Outcome of one `Freshness.check` around Triage delegation preparation. -/
inductive FreshnessOutcome where
  | fresh (authorityRef : ByteArray)
  | stale
  | transientError
  | permanentError
  deriving Inhabited

/-- Outcome of `TriageDelegation.prepare`. -/
inductive PrepareOutcome where
  | prepared
  | retryableError
  | nonRetryableError
  deriving DecidableEq, Repr

/-- Deterministic disposition of `SalixIM.Triage.DelegationEffect` (`TriageProductEffect.tla`). -/
inductive DelegationDecision where
  | commit
  | suppressStale
  | suppressAuthorityDrift
  | retryLater
  | blockPermanent
  deriving DecidableEq, Repr

/-- Double-freshness & authority fence around Triage delegation preparation:
`commit` is permitted iff both freshness checks succeed with identical `authorityRef`
around a successful `prepare`. -/
def decideDelegationEffect (first : FreshnessOutcome) (prep : PrepareOutcome)
    (second : FreshnessOutcome) : DelegationDecision :=
  match first with
  | .stale => .suppressStale
  | .transientError => .retryLater
  | .permanentError => .blockPermanent
  | .fresh auth1 =>
    match prep with
    | .retryableError => .retryLater
    | .nonRetryableError => .blockPermanent
    | .prepared =>
      match second with
      | .stale => .suppressStale
      | .transientError => .retryLater
      | .permanentError => .blockPermanent
      | .fresh auth2 =>
        if auth1 == auth2 then .commit else .suppressAuthorityDrift

/-- Effect settlement outcome for one Triage investigation completion. -/
inductive CompletionOutcome where
  | applied
  | stale
  | failed
  deriving DecidableEq, Repr

/-- Next lifecycle state of a Triage investigation Task (`settle_completion/3`). -/
inductive InvestigationNext where
  | completed
  | retry
  | failed
  deriving DecidableEq, Repr

/-- Bounded stale-source retry transition (`SalixIM.Triage.Investigation.settle_completion/3`):
a stale source retries while `attempts < 3` and terminates in `failed` once `attempts ≥ 3`. -/
def settleInvestigationOutcome (outcome : CompletionOutcome) (attempts : Int) :
    InvestigationNext :=
  match outcome with
  | .failed => .failed
  | .stale => if attempts < 3 then .retry else .failed
  | .applied => .completed

/-- Coordination disposition between CFT Triage and a connected `still.fail` session. -/
inductive TriageStillfailDisposition where
  | noOverlap
  | deferSilenceAlreadyHandled
  | surfaceBlockerWithFollowUp
  | verifyPublicEvidence
  deriving DecidableEq, Repr

/-- Coordinates a CFT Triage investigation with a connected `still.fail` session:
- When a `still.fail` worker is actively `working` in the exact same Slack thread and
  no separate status check was requested, Triage defers via `silence` (`already_handled`)
  instead of racing a duplicate bot reply;
- When a matching `still.fail` session (same Slack thread or shared PR/artifact anchor)
  is blocked in `need` or `failed` and the Slack request remains unresolved, Triage
  surfaces public-authorized blocker context with an `agent_owned` `follow_up`;
- Other overlapping sessions (`done`, or linked-artifact `working`) require verifying
  current public/channel evidence before answering or staying silent. -/
def triageStillfailGuidance (sameSlackThread sharesArtifactAnchor asksStatusOrHelp : Bool)
    (phase : StopPhase) : TriageStillfailDisposition :=
  if !(sameSlackThread || sharesArtifactAnchor) then
    .noOverlap
  else
    match phase with
    | .working =>
      if sameSlackThread && !asksStatusOrHelp then
        .deferSilenceAlreadyHandled
      else
        .verifyPublicEvidence
    | .need _ | .failed =>
      if asksStatusOrHelp then .surfaceBlockerWithFollowUp else .verifyPublicEvidence
    | .done => .verifyPublicEvidence

/-- Clamps a Triage `follow_up` `recheck_after_hours` interval into `[1, 720]` (30 days). -/
def clampFollowUpHours (rawHours : Int) : Int :=
  let lo := if rawHours < 1 then 1 else rawHours
  if lo > 720 then 720 else lo

end VerifiedKernel.Proactive
