import VerifiedKernelProofs.Session.WorkInputAccepted

namespace VerifiedKernel.Session.WorkConservation
open Data

theorem resident_step_session {s event t : Term} (step : ResidentStep s event t) :
    t.get (a "session_id") = s.get (a "session_id") := by
  obtain ⟨middle, normalized, j, r, prepared, activity⟩ := step
  apply (activity "session_id" (by decide) (by decide)).trans
  cases normalized with
  | none => rw [prepareTrusted_none prepared]
  | some normalized =>
    obtain ⟨_, _, _, call⟩ := prepareTrusted_stringify prepared
    exact inner_session call

theorem resident_batch_session {s t : Term} {events : List Term} (execution : ResidentBatch s events t) :
    t.get (a "session_id") = s.get (a "session_id") := by
  induction execution with
  | nil => rfl
  | cons head tail ih => exact ih.trans (resident_step_session (resident_execution_step head))

theorem resident_batch_append {s t : Term} {first last : List Term}
    (execution : ResidentBatch s (first ++ last) t) :
    ∃ middle, ResidentBatch s first middle ∧ ResidentBatch middle last t := by
  induction first generalizing s with
  | nil => exact ⟨s, .nil _, execution⟩
  | cons event events ih =>
    cases execution with
    | cons head tail =>
      obtain ⟨middle, before, after⟩ := ih tail
      exact ⟨middle, .cons head before, after⟩

theorem checked_resident_input_creates {s t payload now event : Term} {source : ByteArray}
    {earlier selected j r guardBefore guardAfter : List Term}
    (generated : Command.inputEvent (s.get (a "session_id")) (.binary source) payload now j = .ok (event, r))
    (checked : Command.inputIdentitiesDistinct (earlier ++ [event]) guardBefore = .ok (true, guardAfter))
    (canonical : ∀ e ∈ earlier, BinaryKeys e)
    (allowed : ∀ e ∈ earlier, Command.inputEventAllowed e = true)
    (selectedFrom : ∀ e ∈ selected, e ∈ earlier)
    (ready : QueueReady s)
    (fresh : IdentityAbsent (s.get (a "input_dedupe")) (.binary source))
    (execution : ResidentBatch s (selected ++ [event]) t) :
    QueueReady t ∧
      (∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item) ∧
      ∃ item, MainInputFact event source item ∧ CanonicalQueueItem item ∧
        ∀ sealed, ConcreteRepresented t sealed item := by
  obtain ⟨middle, before, after⟩ := resident_batch_append execution
  cases after with
  | cons head tail =>
    cases tail
    have sid := resident_batch_session before
    have atMain : Command.inputEvent (middle.get (a "session_id")) (.binary source) payload now j =
        .ok (event, r) := by rw [sid]; exact generated
    obtain ⟨reduced, normalized, first, last, prepared, activity⟩ := resident_execution_step head
    cases normalized with
    | none => exact (prepareTrusted_canonical_not_skipped (inputEvent_binary_keys atMain)
        (inputEvent_session atMain) prepared).elim
    | some normalized =>
      obtain ⟨innerBefore, read, innerAfter, call⟩ := prepareTrusted_stringify prepared
      have same := shallowStringify_binary_keys (inputEvent_binary_keys atMain) read
      subst normalized
      have kind := (inputEvent_source_fields atMain).1
      have append : queueAppend middle event innerBefore = .ok (reduced, innerAfter) := by
        simpa +decide [inner, kind] using call
      obtain ⟨groups, groupsBefore, groupsAfter, groupRead, member⟩ := inputEvent_append_identity atMain append
      have stillFresh := checked_prefix_resident_absent checked groupRead member canonical allowed
        selectedFrom fresh before
      have prefixSafe := resident_batch_input_safety before ready
        (fun e mem => canonical e (selectedFrom e mem)) (fun e mem => allowed e (selectedFrom e mem))
      have mainAllowed : Command.inputEventAllowed event = true := by simp +decide [Command.inputEventAllowed, kind]
      have mainSafe := resident_input_safety prefixSafe.1 (inputEvent_binary_keys atMain) mainAllowed head
      exact ⟨mainSafe.1, fun sealed item present => mainSafe.2 sealed item (prefixSafe.2 sealed item present),
        resident_main_input_creates atMain prefixSafe.1.1 stillFresh head⟩

end VerifiedKernel.Session.WorkConservation
