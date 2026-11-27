import VerifiedKernel.Proactive.Kernel

namespace VerifiedKernel.Proactive

local instance : LawfulBEq ByteArray where
  eq_of_beq := by intro x y h; apply ByteArray.ext; exact eq_of_beq h
  rfl := by intro bytes; change (bytes.data == bytes.data) = true; exact beq_self_eq_true _

/-- At-most-once stop handoff: once `stepStop` emits `.present`, repeating the same
`(phase, atMs)` observation from the resulting state is a no-op. -/
theorem same_stop_idempotent_after_present
    (track next : MatterTrack) (phase : StopPhase) (atMs sinceMs : Int)
    (obs : Observation) (pool : PoolKind) (urg : Bool)
    (h : stepStop track phase atMs sinceMs = (next, .present obs pool urg)) :
    stepStop next phase atMs sinceMs = (next, .noop) := by
  cases phase with
  | working =>
    cases track <;> simp [stepStop, observationOf] at h
  | need card =>
    by_cases seen : alreadyObserved track { tag := 1, atMs := atMs } = true
    · simp [stepStop, observationOf, seen] at h
    · simp [stepStop, observationOf, seen] at h
      obtain ⟨rfl, rfl, _, _⟩ := h
      simp [stepStop, observationOf, alreadyObserved]
  | done =>
    by_cases seen : alreadyObserved track { tag := 2, atMs := atMs } = true
    · simp [stepStop, observationOf, seen] at h
    · simp [stepStop, observationOf, seen] at h
      obtain ⟨rfl, rfl, _, _⟩ := h
      simp [stepStop, observationOf, alreadyObserved]
  | failed =>
    by_cases seen : alreadyObserved track { tag := 3, atMs := atMs } = true
    · simp [stepStop, observationOf, seen] at h
    · simp [stepStop, observationOf, seen] at h
      obtain ⟨rfl, rfl, _, _⟩ := h
      simp [stepStop, observationOf, alreadyObserved]

/-- Router reply fence: once `routerReplied` marks an open matter handled, any stale
index page carrying the same observation `(tag, atMs)` produces `.noop`. -/
theorem router_reply_absorbs_stale_index
    (obs : Observation) (phase : StopPhase) (atMs sinceMs : Int)
    (sameObs : observationOf phase atMs = some obs) :
    let (replied, _) := routerReplied (.open obs)
    stepStop replied phase atMs sinceMs = (.handled obs, .noop) := by
  simp [routerReplied, stepStop, sameObs, alreadyObserved]

/-- Interactive system cards (`login`, `secret`, `signin`, `device`, `rig`) always
route to the `code` pool with high urgency when presented. -/
theorem urgent_card_routes_code_pool
    (track next : MatterTrack) (card : CardKind) (atMs sinceMs : Int)
    (obs : Observation) (pool : PoolKind) (urg : Bool)
    (urgent : card.isUrgentSystem = true)
    (h : stepStop track (.need card) atMs sinceMs = (next, .present obs pool urg)) :
    pool = .code ∧ urg = true := by
  by_cases seen : alreadyObserved track { tag := 1, atMs := atMs } = true
  · simp [stepStop, observationOf, seen] at h
  · simp [stepStop, observationOf, seen, poolOfPhase, urgencyHighOf, urgent] at h
    exact ⟨h.2.2.1.symm, h.2.2.2⟩

/-- Returning to `working` closes an `open` stop once into `.left`, a second `working`
poll is `.noop`, and any later non-working stop rearms into `.present`. -/
theorem working_closes_once
    (obs : Observation) (at1 at2 sinceMs : Int) :
    let (closed, cmd1) := stepStop (.open obs) .working at1 sinceMs
    closed = .left obs ∧ cmd1 = .close obs ∧
      stepStop closed .working at2 sinceMs = (.left obs, .noop) := by
  simp [stepStop, observationOf]

theorem left_rearms_on_next_stop
    (prev nextObs : Observation) (phase : StopPhase) (atMs sinceMs : Int)
    (stopped : observationOf phase atMs = some nextObs) :
    (stepStop (.left prev) phase atMs sinceMs).1 = .open nextObs := by
  simp [stepStop, stopped, alreadyObserved]

/-- Code and reserve pools never defer behind calendar meetings. -/
theorem code_and_reserve_bypass_meeting (meetingBusy : Option Int) :
    effectiveBusyUntil .code meetingBusy = none ∧
      effectiveBusyUntil .reserve meetingBusy = none := by
  cases meetingBusy <;> simp [effectiveBusyUntil]

/-- Strict forward liveness: `scheduleDeferral` always wakes strictly after `nowMs`. -/
theorem scheduleDeferral_strictly_future
    (opensAt nowMs leadMs : Int)
    (busyUntil dueMs reserveWindowAt : Option Int) (isAct : Bool) :
    (scheduleDeferral opensAt nowMs leadMs busyUntil dueMs reserveWindowAt isAct).1 > nowMs := by
  simp only [scheduleDeferral]
  omega

/-- Deadline safety: when an actionable matter has a future reserve window `rw > nowMs`,
deferral behind meetings or closed ordinary pools never pushes `nextAt` past `rw`. -/
theorem scheduleDeferral_respects_reserve_window
    (opensAt nowMs leadMs rw : Int)
    (busyUntil dueMs : Option Int)
    (future : rw > nowMs) :
    (scheduleDeferral opensAt nowMs leadMs busyUntil dueMs (some rw) true).1 ≤ rw := by
  cases busyUntil with
  | none =>
    simp only [scheduleDeferral, future, ↓reduceIte]
    omega
  | some b =>
    by_cases hb : b > opensAt <;>
      simp only [scheduleDeferral, future, hb, ↓reduceIte] <;>
      omega

/-- Active-worker absorption safety: direct human mentions/DMs never get absorbed. -/
theorem direct_human_never_absorbed
    (codeHint incomplete : Bool) (itemAnchors workerAnchors : List ByteArray) :
    absorbByWorker true codeHint incomplete itemAnchors workerAnchors = false := by
  simp [absorbByWorker]

/-- Active-worker absorption safety: verification/login code hints never get absorbed. -/
theorem code_hint_never_absorbed
    (directHuman incomplete : Bool) (itemAnchors workerAnchors : List ByteArray) :
    absorbByWorker directHuman true incomplete itemAnchors workerAnchors = false := by
  simp [absorbByWorker]

/-- Active-worker absorption safety: truncated or unread-attachment items never get absorbed. -/
theorem incomplete_never_absorbed
    (directHuman codeHint : Bool) (itemAnchors workerAnchors : List ByteArray) :
    absorbByWorker directHuman codeHint true itemAnchors workerAnchors = false := by
  simp [absorbByWorker]

/-- Disjoint strong anchors never trigger worker absorption. -/
theorem disjoint_anchors_never_absorbed
    (directHuman codeHint incomplete : Bool) (itemAnchors workerAnchors : List ByteArray)
    (disjoint : sharesAnchor itemAnchors workerAnchors = false) :
    absorbByWorker directHuman codeHint incomplete itemAnchors workerAnchors = false := by
  cases directHuman <;> cases codeHint <;> cases incomplete <;>
    simp [absorbByWorker, disjoint]

/-- Passive automated alerts sharing a strong anchor with an active worker are absorbed. -/
theorem shared_anchor_absorbs_passive_alert
    (itemAnchors workerAnchors : List ByteArray)
    (shared : sharesAnchor itemAnchors workerAnchors = true) :
    absorbByWorker false false false itemAnchors workerAnchors = true := by
  simp [absorbByWorker, shared]

/-- Jev pre-gate safety: `"escalate"` choices and probabilities below 5000 bp never quiet. -/
theorem escalate_choice_never_quiets (probBp rawThresholdBp : Int) :
    gateJev false probBp rawThresholdBp = false := by
  simp [gateJev]

theorem sub_floor_probability_never_quiets
    (isQuietChoice : Bool) (probBp rawThresholdBp : Int)
    (low : probBp < 5000) :
    gateJev isQuietChoice probBp rawThresholdBp = false := by
  cases isQuietChoice with
  | false => simp [gateJev]
  | true =>
    unfold gateJev clampThresholdBp
    by_cases h1 : rawThresholdBp < 5000
    · simp [h1]
      omega
    · by_cases h2 : rawThresholdBp > 10000 <;> simp [h1, h2] <;> omega

/-- Explicit `@other` addressee always forces `outside_authority` silence and never
enters ordinary Triage Worker intake across all source lanes. -/
theorem explicit_other_forces_outside_authority
    (mode : TriageSourceMode) (actorIsAgent : Bool) :
    triageTargetRoute mode .other actorIsAgent = .other ∧
      triageBoundaryAction (triageTargetRoute mode .other actorIsAgent) =
        .forceSilenceOutsideAuthority ∧
      triageIsIntake mode .other actorIsAgent = false := by
  cases mode <;> cases actorIsAgent <;>
    simp [triageTargetRoute, triageBoundaryAction, triageIsIntake]

/-- Human-authored explicit `@self` / `@mixed` messages are owned by the direct-message
route: Triage patrol/ETL suppresses duplicate replies and never spawns a second intake Task. -/
theorem explicit_human_self_suppresses_duplicate
    (mode : TriageSourceMode) :
    triageBoundaryAction (triageTargetRoute mode .self false) = .forceSilenceDuplicate ∧
      triageIsIntake mode .self false = false ∧
      triageBoundaryAction (triageTargetRoute mode .mixed false) = .forceSilenceDuplicate ∧
      triageIsIntake mode .mixed false = false := by
  cases mode <;> simp [triageTargetRoute, triageBoundaryAction, triageIsIntake]

/-- Any evaluation admitted into ordinary Worker intake is guaranteed to satisfy the
`allow` recipient boundary (`target_route == none`). -/
theorem intake_implies_allow_boundary
    (mode : TriageSourceMode) (addr : TriageAddressee) (actorIsAgent : Bool)
    (h : triageIsIntake mode addr actorIsAgent = true) :
    triageBoundaryAction (triageTargetRoute mode addr actorIsAgent) = .allow := by
  cases mode <;> cases addr <;> cases actorIsAgent <;>
    simp [triageIsIntake, triageTargetRoute, triageBoundaryAction] at h ⊢

/-- Double-freshness & authority fence (`TriageProductEffect.tla`):
`decideDelegationEffect` authorizes `commit` iff both pre-prepare and post-prepare
source checks are `.fresh` with the exact same `authorityRef` around `.prepared`. -/
theorem commit_iff_matching_double_freshness
    (first : FreshnessOutcome) (prep : PrepareOutcome) (second : FreshnessOutcome) :
    decideDelegationEffect first prep second = .commit ↔
      ∃ auth, first = .fresh auth ∧ prep = .prepared ∧ second = .fresh auth := by
  cases first with
  | stale => simp [decideDelegationEffect]
  | transientError => simp [decideDelegationEffect]
  | permanentError => simp [decideDelegationEffect]
  | fresh a1 =>
    cases prep with
    | retryableError => simp [decideDelegationEffect]
    | nonRetryableError => simp [decideDelegationEffect]
    | prepared =>
      cases second with
      | stale => simp [decideDelegationEffect]
      | transientError => simp [decideDelegationEffect]
      | permanentError => simp [decideDelegationEffect]
      | fresh a2 =>
        by_cases eq : (a1 == a2) = true
        · have heq : a1 = a2 := by simpa using eq
          subst heq
          simp [decideDelegationEffect]
        · have hne : a2 ≠ a1 := by
            intro h
            subst h
            simp at eq
          simp [decideDelegationEffect, eq, hne]

/-- Authority drift during Triage delegation preparation deterministically suppresses commit. -/
theorem authority_drift_suppresses_commit
    (auth1 auth2 : ByteArray) (drift : auth1 ≠ auth2) :
    decideDelegationEffect (.fresh auth1) .prepared (.fresh auth2) =
      .suppressAuthorityDrift := by
  have hbeq : (auth1 == auth2) = false := by
    cases h : auth1 == auth2 with
    | false => rfl
    | true =>
      exfalso
      apply drift
      simpa using h
  simp [decideDelegationEffect, hbeq]

/-- Bounded Triage stale-source retries: once `attempts ≥ 3`, another stale publication
terminates in `.failed` rather than looping indefinitely. -/
theorem stale_attempts_bounded_at_three (attempts : Int) (exhausted : attempts ≥ 3) :
    settleInvestigationOutcome .stale attempts = .failed := by
  have h : ¬ (attempts < 3) := by omega
  simp [settleInvestigationOutcome, h]

/-- Applied Triage completion always transitions the investigation to `.completed`. -/
theorem applied_always_completes (attempts : Int) :
    settleInvestigationOutcome .applied attempts = .completed := by
  simp [settleInvestigationOutcome]

/-- Same-thread `still.fail` coordination: when a connected `still.fail` worker is actively
`working` in the same Slack thread and no separate status inquiry was asked, CFT Triage
defers via `silence` (`already_handled`) rather than racing a second bot reply. -/
theorem same_thread_working_defers_to_stillfail (sharedAnchor : Bool) :
    triageStillfailGuidance true sharedAnchor false .working =
      .deferSilenceAlreadyHandled := by
  simp [triageStillfailGuidance]

/-- Blocked `still.fail` coordination & bounded follow-up interval: when an overlapping
`still.fail` session is in `need` or `failed` for an unresolved question, Triage surfaces
blocker context with a follow-up whose recheck hours always lie within `[1, 720]`. -/
theorem blocked_stillfail_requests_bounded_follow_up
    (sameThread sharedAnchor : Bool) (card : CardKind) (rawHours : Int)
    (overlap : sameThread = true ∨ sharedAnchor = true) :
    triageStillfailGuidance sameThread sharedAnchor true (.need card) =
        .surfaceBlockerWithFollowUp ∧
      triageStillfailGuidance sameThread sharedAnchor true .failed =
        .surfaceBlockerWithFollowUp ∧
      1 ≤ clampFollowUpHours rawHours ∧ clampFollowUpHours rawHours ≤ 720 := by
  have hov : (sameThread || sharedAnchor) = true := by
    rcases overlap with rfl | rfl <;> simp
  refine ⟨?_, ?_, ?_, ?_⟩
  · simp [triageStillfailGuidance, hov]
  · simp [triageStillfailGuidance, hov]
  · unfold clampFollowUpHours
    by_cases h1 : rawHours < 1
    · simp [h1]
    · by_cases h2 : rawHours > 720 <;> simp [h1, h2] <;> omega
  · unfold clampFollowUpHours
    by_cases h1 : rawHours < 1
    · simp [h1]
    · by_cases h2 : rawHours > 720 <;> simp [h1, h2] <;> omega

end VerifiedKernel.Proactive
