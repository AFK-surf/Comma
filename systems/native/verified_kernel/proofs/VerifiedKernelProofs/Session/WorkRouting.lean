import VerifiedKernelProofs.Session.WorkQueueFrames
import VerifiedKernelProofs.Session.WorkInput
import VerifiedKernelProofs.Session.WorkExecution
import VerifiedKernelProofs.Session.WorkMaterializeRouting

namespace VerifiedKernel.Session.WorkConservation
open Data

theorem queueAppend_session {s e t : Term} {j r : List Term}
    (h : queueAppend s e j = .ok (t, r)) : t.get (a "session_id") = s.get (a "session_id") := by
  unfold queueAppend at h
  repeat' first
    | exact write_field_frame h rfl
    | (have same := pure_ok h; subst t; rfl)
    | (exact (fail_ok h).elim)
    | split at h
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)
    | dsimp only at h

theorem pruneResultRefs_session {s t : Term} {j r : List Term}
    (h : pruneResultRefs s j = .ok (t, r)) : t.get (a "session_id") = s.get (a "session_id") := by
  unfold pruneResultRefs at h
  repeat' first
    | exact write_field_frame h rfl
    | (have same := pure_ok h; subst t; rfl)
    | split at h
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)

theorem queueConsume_session {s e t : Term} {j r : List Term}
    (h : queueConsume s e j = .ok (t, r)) : t.get (a "session_id") = s.get (a "session_id") := by
  unfold queueConsume at h
  iterate 4 obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, written, pruned⟩ := bind_ok h
  exact (pruneResultRefs_session pruned).trans (write_field_frame written rfl)

theorem queueAck_session {s e t : Term} {j r : List Term}
    (h : queueAck s e j = .ok (t, r)) : t.get (a "session_id") = s.get (a "session_id") := by
  unfold queueAck at h
  iterate 6 obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, written, pruned⟩ := bind_ok h
  exact (pruneResultRefs_session pruned).trans (write_field_frame written rfl)

theorem sessionEvent_session {s e t : Term} {j r : List Term}
    (h : sessionEvent s e j = .ok (t, r)) : t.get (a "session_id") = s.get (a "session_id") :=
  (sessionEvent_fields h).2 "session_id" rfl

theorem inner_session {s e t : Term} {j r : List Term}
    (h : inner s e j = .ok (t, r)) : t.get (a "session_id") = s.get (a "session_id") := by
  by_cases append : (e.get (b "type") == b "queue_append") = true
  · apply queueAppend_session
    simpa +decide [inner, binary_beq_true append] using h
  by_cases ack : (e.get (b "type") == b "queue_ack") = true
  · apply queueAck_session
    simpa +decide [inner, binary_beq_true ack] using h
  by_cases consume : (e.get (b "type") == b "queue_consume") = true
  · simp +decide [inner, binary_beq_true consume] at h
    split at h
    · exact queueConsume_session h
    · have same := pure_ok h; subst t; rfl
  by_cases fact : (e.get (b "type") == b "session_event") = true
  · apply sessionEvent_session
    simpa +decide [inner, binary_beq_true fact] using h
  exact (inner_queue_frame (Bool.eq_false_iff.mpr append) (Bool.eq_false_iff.mpr ack)
    (Bool.eq_false_iff.mpr consume) (Bool.eq_false_iff.mpr fact) h).2.2.2.1

/-- Projection executes every canonical event targeted to the current Session, without skips. -/
theorem projected_routed_exact {s t : Term} {raw normalized j r : List Term}
    (trace : ProjectedBatch s raw j normalized t r)
    (routed : ∀ event ∈ raw, Routed (s.get (a "session_id")) event) :
    normalized = raw ∧ t.get (a "session_id") = s.get (a "session_id") := by
  induction trace with
  | nil => exact ⟨rfl, rfl⟩
  | skip prepared tail ih =>
    have head := routed _ List.mem_cons_self
    exact (prepareTrusted_canonical_not_skipped head.1 head.2 prepared).elim
  | cons prepared activity tail ih =>
    have head := routed _ List.mem_cons_self
    obtain ⟨_, read, _, reduced⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys head.1 read
    subst same
    have frame := (afterEvent_queue_frame activity).2.2.2.1.trans (inner_session reduced)
    have rest := ih (fun event member => by
      have found := routed event (List.mem_cons_of_mem _ member)
      exact ⟨found.1, found.2.trans frame.symm⟩)
    exact ⟨congrArg (List.cons _) rest.1, rest.2.trans frame⟩

/-- The public query's events all execute in its Session during actual projection. -/
theorem materialize_project_exact {s t : Term} {events j r before after : List Term}
    {limit : Int} {wake : Bool} {hwm : Term}
    (planned : StateQuery.materialize s limit j = .ok (.tuple [list events, Term.bool wake, hwm], r))
    (projected : Command.project s events before = .ok (t, after)) :
    ProjectedBatch s events before events t after := by
  obtain ⟨normalized, trace⟩ := project_execution projected
  have same := (projected_routed_exact trace (materialize_routed planned)).1
  subst normalized
  exact trace

/-- Every planned retirement has its concrete queue payload in the actually projected records. -/
theorem materialize_project_payloads {s t : Term} {events j r before after : List Term}
    {limit : Int} {wake : Bool} {hwm : Term}
    (planned : StateQuery.materialize s limit j = .ok (.tuple [list events, Term.bool wake, hwm], r))
    (projected : Command.project s events before = .ok (t, after)) :
    ∃ session items selected ack consumes j₁ j₂ j₃,
      StateQuery.unackedItems s j₁ = .ok (items, j₂) ∧
      StateQuery.materializeBatch s items limit j₂ = .ok ((selected, ack, consumes), j₃) ∧
      field s "session_id" j = .ok (session, j₁) ∧ TranscriptExtends s t ∧
      (Ordered items → ∀ item ∈ items, Retired ack consumes item →
        ∃ record, ContainsRecord t record ∧ QueuedRecord item record) := by
  have trace := materialize_project_exact planned projected
  have ordinary := materialize_ordinary planned
  obtain ⟨session, items, selected, ack, consumes, generated, wake', hwm', j₁, j₂, j₃,
    pending, plan, result, covered, sid⟩ :=
    materialize_batch_has_records planned
  have same : events = generated := by
    injection result with eq
    injection eq with first
    exact Term.list.inj first
  subst generated
  refine ⟨session, items, selected, ack, consumes, j₁, j₂, j₃, pending, plan, sid,
    projected_batch_extends trace ordinary, ?_⟩
  intro ordered item member retired
  obtain ⟨event, member, generated⟩ := covered ordered item member retired
  obtain ⟨record, _, present, fields⟩ :=
    projected_batch_input_fields trace ordinary member (generated_record_event generated)
  exact ⟨record, present, generated_record_payload generated fields⟩

end VerifiedKernel.Session.WorkConservation
