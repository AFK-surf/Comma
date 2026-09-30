import VerifiedKernelProofs.Session.WorkInputTermAccepted

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem inputEvent_term_session {session payload now event source : Term} {j r : List Term}
    (h : Command.inputEvent session source payload now j = .ok (event, r)) :
    event.get (b "session_id") = session := by
  unfold Command.inputEvent at h
  repeat obtain ⟨_, _, _, h⟩ := bind_ok h
  have eventEq := pure_ok h
  subst event
  cases present : session == nil
  · simp +decide [compact_lookup, List.find?_cons, bne, present]
  · have same := atom_beq_true present
    subst session
    simp +decide [compact_lookup, List.find?_cons, nil]

theorem queue_input_identity_groups {event normalized : Term} {keys before middle after : List Term}
    (kind : event.get (b "type") = b "queue_append")
    (normalizedRead : stringify ((event.get (b "payload")).default empty) before = .ok (normalized, middle))
    (keysRead : queueKeys event normalized (event.get (b "kind")) middle = .ok (keys, after)) :
    Command.inputIdentityGroups event before = .ok ([keys], after) := by
  unfold Command.inputIdentityGroups
  simp +decide only [kind]
  apply bind_ok_iff.mpr
  refine ⟨normalized, middle, normalizedRead, ?_⟩
  apply bind_ok_iff.mpr
  exact ⟨keys, after, keysRead, rfl⟩

theorem resident_main_term_input_creates {s t payload now event source : Term}
    {j r observations : List Term}
    (nonnull : (source == nil) = false)
    (generated : Command.inputEvent (s.get (a "session_id")) source payload now j = .ok (event, r))
    (invariant : QueueAllocated s)
    (fresh : ∀ normalized keys first middle last,
      stringify ((event.get (b "payload")).default empty) first = .ok (normalized, middle) →
      queueKeys event normalized (event.get (b "kind")) middle = .ok (keys, last) →
      ∀ key ∈ keys, IdentityAbsent (s.get (a "input_dedupe")) key)
    (execution : ResidentTrace (runTrusted s event observations) (.tuple [a "done", t])) :
    ∃ item, MainTermInputFact event source item ∧ CanonicalQueueItem item ∧
      ∀ sealed, ConcreteRepresented t sealed item := by
  obtain ⟨reduced, normalized, before, after, prepared, activity⟩ := resident_execution_step execution
  cases normalized with
  | none => exact (prepareTrusted_canonical_not_skipped (inputEvent_binary_keys generated)
      (inputEvent_term_session generated) prepared).elim
  | some normalized =>
    obtain ⟨innerBefore, read, innerAfter, call⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys (inputEvent_binary_keys generated) read
    subst normalized
    have present : (source != nil) = true := by simp only [bne, nonnull, Bool.not_false]
    have kind := (inputEvent_source_term_fields present generated).1
    have append : queueAppend s event innerBefore = .ok (reduced, innerAfter) := by
      simpa +decide [inner, kind] using call
    obtain ⟨item, fact, canonical, represented⟩ :=
      inputEvent_append_term_creates nonnull generated invariant fresh append
    exact ⟨item, fact, canonical, fun sealed =>
      (concrete_representation_frame (activity_frame_work activity)).mp (represented sealed)⟩

theorem checked_resident_term_input_creates {s t payload now event source entryPayload limit : Term}
    {earlier selected j r guardBefore guardAfter journal rest : List Term}
    (nonnull : (source == nil) = false)
    (admitted : RoundQuery.deliveryAdmission s (.tuple [source, entryPayload, limit]) journal =
      .ok (a "accept", rest))
    (generated : Command.inputEvent (s.get (a "session_id")) source payload now j = .ok (event, r))
    (checked : Command.inputIdentitiesDistinct (earlier ++ [event]) guardBefore = .ok (true, guardAfter))
    (canonical : ∀ e ∈ earlier, BinaryKeys e)
    (allowed : ∀ e ∈ earlier, Command.inputEventAllowed e = true)
    (selectedFrom : ∀ e ∈ selected, e ∈ earlier)
    (ready : QueueReady s)
    (execution : ResidentBatch s (selected ++ [event]) t) :
    QueueReady t ∧
      (∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item) ∧
      ∃ item, MainTermInputFact event source item ∧ CanonicalQueueItem item ∧
        ∀ sealed, ConcreteRepresented t sealed item := by
  obtain ⟨middle, before, after⟩ := resident_batch_append execution
  cases after with
  | cons head tail =>
    cases tail
    have sid := resident_batch_session before
    have atMain : Command.inputEvent (middle.get (a "session_id")) source payload now j =
        .ok (event, r) := by rw [sid]; exact generated
    have present : (source != nil) = true := by simp only [bne, nonnull, Bool.not_false]
    have kind := (inputEvent_source_term_fields present atMain).1
    have prefixSafe := resident_batch_input_safety before ready
      (fun e mem => canonical e (selectedFrom e mem)) (fun e mem => allowed e (selectedFrom e mem))
    have mainAllowed : Command.inputEventAllowed event = true := by
      simp +decide [Command.inputEventAllowed, kind]
    have mainSafe := resident_input_safety prefixSafe.1 (inputEvent_binary_keys atMain) mainAllowed head
    refine ⟨mainSafe.1, fun sealed item represented =>
      mainSafe.2 sealed item (prefixSafe.2 sealed item represented),
      resident_main_term_input_creates nonnull atMain prefixSafe.1.1 ?_ head⟩
    intro normalized keys first between last normalizedRead keysRead key member
    have initial := admitted_input_queueKeys_fresh nonnull admitted generated normalizedRead keysRead key member
    have groups := queue_input_identity_groups kind normalizedRead keysRead
    exact checked_prefix_resident_term_absent checked groups (by simpa using member)
      canonical allowed selectedFrom initial before

end VerifiedKernel.Session.WorkConservation
