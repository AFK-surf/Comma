import VerifiedKernelProofs.Session.WorkBatch
import VerifiedKernelProofs.Session.WorkPayload
import VerifiedKernelProofs.Session.WorkRuntimePayload

namespace VerifiedKernel.Session.WorkConservation
open Data StateQuery

/-- Concrete input fields, not an abstract claim that some representation exists. -/
def InputRecordFields (event record : Term) : Prop :=
  (event.get (b "type") = b "delivery" ∧ DeliveryFields event record) ∨
  (event.get (b "type") = b "runtime_message" ∧ RuntimeFields event record)

theorem input_event_stores_fields {s e t : Term} {j r : List Term}
    (kind : RecordEvent e) (h : inner s e j = .ok (t, r)) :
    ∃ record, RecordWitness e record ∧ ContainsRecord t record ∧ InputRecordFields e record := by
  obtain ⟨queued, delivery | runtime⟩ := kind
  · have reduced : transcriptDelivery s e j = .ok (t, r) := by
      simp only [inner, delivery] at h
      simpa +decide using h
    obtain ⟨record, witness, kept, fields⟩ := delivery_stores_fields queued reduced
    exact ⟨record, witness, kept, Or.inl ⟨delivery, fields⟩⟩
  · have reduced : transcriptRuntime s e j = .ok (t, r) := by
      simp only [inner, runtime] at h
      simpa +decide using h
    obtain ⟨record, witness, kept, fields⟩ := runtime_stores_fields queued reduced
    exact ⟨record, witness, kept, Or.inr ⟨runtime, fields⟩⟩

theorem batch_input_fields {s t e : Term} {events : List Term}
    (applied : AppliedBatch s events t) (ordinary : Ordinary events)
    (member : e ∈ events) (kind : RecordEvent e) :
    ∃ record, RecordWitness e record ∧ ContainsRecord t record ∧ InputRecordFields e record := by
  induction applied with
  | nil => simp at member
  | @cons s middle next final head events j r rest prepared activity tail ih =>
    have ordinaryTail : Ordinary events :=
      fun event member => ordinary event (List.mem_cons_of_mem _ member)
    rcases List.mem_cons.mp member with same | later
    · subst head
      obtain ⟨_, _, _, reduced⟩ := prepare_stringify prepared
      obtain ⟨record, witness, kept, fields⟩ := input_event_stores_fields kind reduced
      exact ⟨record, witness,
        record_survives (applied_batch_extends tail ordinaryTail)
          (record_survives (afterEvent_extends activity) kept), fields⟩
    · exact ih ordinaryTail later

/-- Every planned retirement has a concrete record with the generated event's identity and content.
Successful canonical application is a premise. Durable CAS and host recovery remain outside this theorem. -/
theorem materialized_input_fields {state next : Term} {events : List Term}
    {wake : Bool} {hwm : Term} {limit : Int} {j r : List Term}
    (planned : materialize state limit j = .ok (.tuple [list events, Term.bool wake, hwm], r))
    (applied : AppliedBatch state events next) :
    ∃ session items selected ack consumes j₁ j₂ j₃,
      unackedItems state j₁ = .ok (items, j₂) ∧
      materializeBatch state items limit j₂ = .ok ((selected, ack, consumes), j₃) ∧
      field state "session_id" j = .ok (session, j₁) ∧
      TranscriptExtends state next ∧
      (Ordered items → ∀ item ∈ items, Retired ack consumes item →
        ∃ event ∈ events, Generated session item event ∧
          ∃ record, RecordWitness event record ∧ ContainsRecord next record ∧ InputRecordFields event record) := by
  obtain ⟨session, items, selected, ack, consumes, generated, wake', hwm', j₁, j₂, j₃,
    pending, plan, result, coverage, sid⟩ := materialize_batch_has_records planned
  have same : events = generated := by
    injection result with eq
    injection eq with first
    exact Term.list.inj first
  subst generated
  have ordinary := materialize_ordinary planned
  refine ⟨session, items, selected, ack, consumes, j₁, j₂, j₃, pending, plan, sid,
    applied_batch_extends applied ordinary, ?_⟩
  intro ordered item member retired
  obtain ⟨event, member, generated⟩ := coverage ordered item member retired
  exact ⟨event, member, generated,
    batch_input_fields applied ordinary member (generated_record_event generated)⟩

end VerifiedKernel.Session.WorkConservation
