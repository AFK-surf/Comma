import VerifiedKernelProofs.Session.WorkResidentEvidence

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 1000000
set_option Elab.async false

inductive ResidentReducedBatch : Term → List Term → Term → Prop where
  | nil (state : Term) : ResidentReducedBatch state [] state
  | cons {state reduced next final event : Term} {events j r : List Term}
      (call : inner state event j = .ok (reduced, r))
      (activity : ActivityFrame reduced next)
      (tail : ResidentReducedBatch next events final) : ResidentReducedBatch state (event :: events) final

theorem resident_routed_reduces {s t : Term} {events : List Term}
    (execution : ResidentBatch s events t)
    (routed : ∀ event ∈ events, Routed (s.get (a "session_id")) event) :
    ResidentReducedBatch s events t ∧ t.get (a "session_id") = s.get (a "session_id") := by
  induction execution with
  | nil => exact ⟨.nil _, rfl⟩
  | cons head tail ih =>
    obtain ⟨reduced, normalized, j, r, prepared, activity⟩ := resident_execution_step head
    have routedHead := routed _ List.mem_cons_self
    cases normalized with
    | none => exact (prepareTrusted_canonical_not_skipped routedHead.1 routedHead.2 prepared).elim
    | some normalized =>
      obtain ⟨_, read, _, reducedCall⟩ := prepareTrusted_stringify prepared
      have same := shallowStringify_binary_keys routedHead.1 read
      subst normalized
      have sid := (activity "session_id" (by decide) (by decide)).trans (inner_session reducedCall)
      have rest := ih (fun event member => by
        have route := routed event (List.mem_cons_of_mem _ member)
        exact ⟨route.1, route.2.trans sid.symm⟩)
      exact ⟨.cons reducedCall activity rest.1, rest.2.trans sid⟩

theorem activity_frame_extends {s t : Term} (frame : ActivityFrame s t) : TranscriptExtends s t := by
  intro messages read
  exact ⟨[], by simpa using (frame "messages" (by decide) (by decide)).trans read⟩

theorem resident_reduced_extends {s t : Term} {events : List Term}
    (execution : ResidentReducedBatch s events t) (ordinary : Ordinary events) : TranscriptExtends s t := by
  induction execution with
  | nil => exact extends_refl _
  | cons call activity tail ih =>
    have kind := ordinary _ List.mem_cons_self
    exact extends_trans (inner_extends kind.1 kind.2 call)
      (extends_trans (activity_frame_extends activity)
        (ih (fun event member => ordinary event (List.mem_cons_of_mem _ member))))

theorem resident_reduced_input_fields {s t e : Term} {events : List Term}
    (execution : ResidentReducedBatch s events t) (ordinary : Ordinary events)
    (member : e ∈ events) (kind : RecordEvent e) :
    ∃ record, RecordWitness e record ∧ ContainsRecord t record ∧ InputRecordFields e record := by
  induction execution with
  | nil => simp at member
  | cons call activity tail ih =>
    have ordinaryTail : Ordinary _ := fun event member => ordinary event (List.mem_cons_of_mem _ member)
    rcases List.mem_cons.mp member with same | later
    · subst same
      obtain ⟨record, witness, present, fields⟩ := input_event_stores_fields kind call
      exact ⟨record, witness,
        record_survives (resident_reduced_extends tail ordinaryTail)
          (record_survives (activity_frame_extends activity) present), fields⟩
    · exact ih ordinaryTail later

theorem materialize_resident_payloads {s t : Term} {events j r : List Term}
    {limit : Int} {wake : Bool} {hwm : Term}
    (planned : StateQuery.materialize s limit j = .ok (.tuple [list events, Term.bool wake, hwm], r))
    (execution : ResidentBatch s events t) :
    ∃ session items selected ack consumes j₁ j₂ j₃,
      StateQuery.unackedItems s j₁ = .ok (items, j₂) ∧
      StateQuery.materializeBatch s items limit j₂ = .ok ((selected, ack, consumes), j₃) ∧
      field s "session_id" j = .ok (session, j₁) ∧ TranscriptExtends s t ∧
      (Ordered items → ∀ item ∈ items, Retired ack consumes item →
        ∃ record, ContainsRecord t record ∧ QueuedRecord item record) := by
  have trace := (resident_routed_reduces execution (materialize_routed planned)).1
  have ordinary := materialize_ordinary planned
  obtain ⟨session, items, selected, ack, consumes, generated, wake', hwm', j₁, j₂, j₃,
    pending, plan, result, covered, sid⟩ := materialize_batch_has_records planned
  have same : events = generated := by
    injection result with eq
    injection eq with first
    exact Term.list.inj first
  subst generated
  refine ⟨session, items, selected, ack, consumes, j₁, j₂, j₃, pending, plan, sid,
    resident_reduced_extends trace ordinary, ?_⟩
  intro ordered item member retired
  obtain ⟨event, member, generated⟩ := covered ordered item member retired
  obtain ⟨record, _, present, fields⟩ := resident_reduced_input_fields trace ordinary member
    (generated_record_event generated)
  exact ⟨record, present, generated_record_payload generated fields⟩

end VerifiedKernel.Session.WorkConservation
