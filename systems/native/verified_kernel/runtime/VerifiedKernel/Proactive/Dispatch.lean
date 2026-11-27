import VerifiedKernel.Term
import VerifiedKernel.Proactive.Kernel

namespace VerifiedKernel.Proactive

private def boolean : Term → Except String Bool
  | .atom "true" => .ok true
  | .atom "false" => .ok false
  | _ => .error "expected_boolean"

private def integer : Term → Except String Int
  | .integer n => .ok n
  | _ => .error "expected_integer"

private def optInt : Term → Except String (Option Int)
  | .atom "nil" => .ok none
  | .integer n => .ok (some n)
  | _ => .error "expected_optional_integer"

private def encodeOptInt : Option Int → Term
  | none => .atom "nil"
  | some n => .integer n

private def decodeCardKind : String → CardKind
  | "options" => .options
  | "text" => .text
  | "login" => .login
  | "secret" => .secret
  | "vault" => .secret
  | "signin" => .signin
  | "device" => .device
  | "adb" => .device
  | "rig" => .rig
  | _ => .none

private def decodePhase : Term → Except String StopPhase
  | .atom "working" => .ok .working
  | .atom "done" => .ok .done
  | .atom "failed" => .ok .failed
  | .atom "need" => .ok (.need .none)
  | .tuple [.atom "need", .atom card] => .ok (.need (decodeCardKind card))
  | .tuple [.atom "need", .binary bytes] =>
    match String.fromUTF8? bytes with
    | some card => .ok (.need (decodeCardKind card))
    | none => .ok (.need .none)
  | _ => .error "invalid_stop_phase"

private def decodeTrack : Term → Except String MatterTrack
  | .atom "unseen" => .ok .unseen
  | .tuple [.atom "open", .integer tag, .integer atMs] =>
    .ok (.open { tag := tag, atMs := atMs })
  | .tuple [.atom "handled", .integer tag, .integer atMs] =>
    .ok (.handled { tag := tag, atMs := atMs })
  | .tuple [.atom "left", .integer tag, .integer atMs] =>
    .ok (.left { tag := tag, atMs := atMs })
  | _ => .error "invalid_matter_track"

private def encodeTrack : MatterTrack → Term
  | .unseen => .atom "unseen"
  | .open obs => .tuple [.atom "open", .integer obs.tag, .integer obs.atMs]
  | .handled obs => .tuple [.atom "handled", .integer obs.tag, .integer obs.atMs]
  | .left obs => .tuple [.atom "left", .integer obs.tag, .integer obs.atMs]

private def decodePool : Term → Except String PoolKind
  | .atom "ordinary" => .ok .ordinary
  | .atom "reserve" => .ok .reserve
  | .atom "code" => .ok .code
  | _ => .error "invalid_pool_kind"

private def encodePool : PoolKind → Term
  | .ordinary => .atom "ordinary"
  | .reserve => .atom "reserve"
  | .code => .atom "code"

private def encodeTransition : StopTransition → Term
  | .noop => .atom "noop"
  | .present obs pool high =>
    .tuple [
      .atom "present",
      .tuple [.integer obs.tag, .integer obs.atMs],
      encodePool pool,
      .atom (if high then "high" else "normal")
    ]
  | .close obs =>
    .tuple [.atom "close", .tuple [.integer obs.tag, .integer obs.atMs]]

private def decodeAnchorsLoop : List Term → List ByteArray → Except String (List ByteArray)
  | [], acc => .ok acc
  | .binary bytes :: rest, acc => decodeAnchorsLoop rest (bytes :: acc)
  | _ :: _, _ => .error "expected_binary_anchor"

private def decodeAnchors : Term → Except String (List ByteArray)
  | .list items => decodeAnchorsLoop items []
  | _ => .error "expected_anchor_list"

private def decodeTriageModeStr : String → TriageSourceMode
  | "callback" => .callback
  | "clickhouse_etl" => .clickhouseEtl
  | "periodic_patrol" => .periodicPatrol
  | "scheduled_recheck" => .scheduledRecheck
  | "historical_thread_reenactment" => .historicalReenactment
  | _ => .other

private def decodeTriageMode : Term → Except String TriageSourceMode
  | .atom s => .ok (decodeTriageModeStr s)
  | .binary bytes =>
    match String.fromUTF8? bytes with
    | some s => .ok (decodeTriageModeStr s)
    | none => .ok .other
  | _ => .error "invalid_triage_mode"

private def decodeAddresseeStr : String → TriageAddressee
  | "none" => .none
  | "self" => .self
  | "mixed" => .mixed
  | "other" => .other
  | _ => .invalid

private def decodeAddressee : Term → Except String TriageAddressee
  | .atom s => .ok (decodeAddresseeStr s)
  | .binary bytes =>
    match String.fromUTF8? bytes with
    | some s => .ok (decodeAddresseeStr s)
    | none => .ok .invalid
  | _ => .ok .invalid

private def encodeAddressee : TriageAddressee → Term
  | .none => .atom "none"
  | .self => .atom "self"
  | .mixed => .atom "mixed"
  | .other => .atom "other"
  | .invalid => .atom "invalid"

private def encodeBoundaryAction : TriageBoundaryAction → Term
  | .allow => .atom "allow"
  | .forceSilenceOutsideAuthority => .atom "force_silence_outside_authority"
  | .forceSilenceDuplicate => .atom "force_silence_duplicate"
  | .rejectTarget => .atom "reject_target"

private def decodeFreshness : Term → Except String FreshnessOutcome
  | .tuple [.atom "fresh", .binary auth] => .ok (.fresh auth)
  | .atom "stale" => .ok .stale
  | .atom "transient_error" => .ok .transientError
  | .atom "permanent_error" => .ok .permanentError
  | _ => .error "invalid_freshness_outcome"

private def decodePrepare : Term → Except String PrepareOutcome
  | .atom "prepared" => .ok .prepared
  | .atom "retryable_error" => .ok .retryableError
  | .atom "non_retryable_error" => .ok .nonRetryableError
  | _ => .error "invalid_prepare_outcome"

private def encodeDelegationDecision : DelegationDecision → Term
  | .commit => .atom "commit"
  | .suppressStale => .atom "suppress_stale"
  | .suppressAuthorityDrift => .atom "suppress_authority_drift"
  | .retryLater => .atom "retry_later"
  | .blockPermanent => .atom "block_permanent"

private def decodeCompletionOutcome : Term → Except String CompletionOutcome
  | .atom "applied" => .ok .applied
  | .atom "stale" => .ok .stale
  | .atom "failed" => .ok .failed
  | _ => .error "invalid_completion_outcome"

private def encodeInvestigationNext : InvestigationNext → Term
  | .completed => .atom "completed"
  | .retry => .atom "retry"
  | .failed => .atom "failed"

private def encodeStillfailDisposition : TriageStillfailDisposition → Term
  | .noOverlap => .atom "no_overlap"
  | .deferSilenceAlreadyHandled => .atom "defer_silence_already_handled"
  | .surfaceBlockerWithFollowUp => .atom "surface_blocker_with_follow_up"
  | .verifyPublicEvidence => .atom "verify_public_evidence"

def invoke : Term → Term → Except String Term
  | .atom "step_stop", .tuple [track, phase, atMs, sinceMs] => do
    let (next, transition) :=
      stepStop (← decodeTrack track) (← decodePhase phase) (← integer atMs) (← integer sinceMs)
    return .tuple [encodeTrack next, encodeTransition transition]
  | .atom "router_replied", track => do
    let (next, changed) := routerReplied (← decodeTrack track)
    return .tuple [encodeTrack next, .atom (if changed then "true" else "false")]
  | .atom "effective_busy_until", .tuple [pool, meetingBusy] => do
    let out := effectiveBusyUntil (← decodePool pool) (← optInt meetingBusy)
    return encodeOptInt out
  | .atom "schedule_deferral",
    .tuple [opensAt, nowMs, leadMs, busyUntil, dueMs, reserveWindowAt, isAct] => do
    let (nextAt, dueWake) :=
      scheduleDeferral
        (← integer opensAt)
        (← integer nowMs)
        (← integer leadMs)
        (← optInt busyUntil)
        (← optInt dueMs)
        (← optInt reserveWindowAt)
        (← boolean isAct)
    return .tuple [.integer nextAt, encodeOptInt dueWake]
  | .atom "absorb_by_worker",
    .tuple [directHuman, codeHint, incomplete, itemAnchors, workerAnchors] => do
    let absorbed :=
      absorbByWorker
        (← boolean directHuman)
        (← boolean codeHint)
        (← boolean incomplete)
        (← decodeAnchors itemAnchors)
        (← decodeAnchors workerAnchors)
    return .atom (if absorbed then "true" else "false")
  | .atom "gate_jev", .tuple [isQuiet, probBp, thresholdBp] => do
    let quiet := gateJev (← boolean isQuiet) (← integer probBp) (← integer thresholdBp)
    return .atom (if quiet then "quiet" else "escalate_to_llm")
  | .atom "triage_target_route", .tuple [mode, addr, actorIsAgent] => do
    let route :=
      triageTargetRoute (← decodeTriageMode mode) (← decodeAddressee addr) (← boolean actorIsAgent)
    return encodeAddressee route
  | .atom "triage_boundary_action", addr => do
    let action := triageBoundaryAction (← decodeAddressee addr)
    return encodeBoundaryAction action
  | .atom "triage_is_intake", .tuple [mode, addr, actorIsAgent] => do
    let intake :=
      triageIsIntake (← decodeTriageMode mode) (← decodeAddressee addr) (← boolean actorIsAgent)
    return .atom (if intake then "true" else "false")
  | .atom "decide_delegation_effect", .tuple [first, prep, second] => do
    let out :=
      decideDelegationEffect (← decodeFreshness first) (← decodePrepare prep) (← decodeFreshness second)
    return encodeDelegationDecision out
  | .atom "settle_investigation_outcome", .tuple [outcome, attempts] => do
    let next :=
      settleInvestigationOutcome (← decodeCompletionOutcome outcome) (← integer attempts)
    return encodeInvestigationNext next
  | .atom "triage_stillfail_guidance",
    .tuple [sameThread, sharedAnchor, asksStatus, phase] => do
    let disp :=
      triageStillfailGuidance
        (← boolean sameThread)
        (← boolean sharedAnchor)
        (← boolean asksStatus)
        (← decodePhase phase)
    return encodeStillfailDisposition disp
  | .atom "clamp_follow_up_hours", rawHours => do
    return .integer (clampFollowUpHours (← integer rawHours))
  | _, _ => .error "invalid_proactive_request"

end VerifiedKernel.Proactive
