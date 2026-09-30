import VerifiedKernelProofs.Session.WorkRevisionRawPlan

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

/-- Materialization can cross activity updates without assuming identical query journals. -/
theorem materialize_framed_payloads {s projected t : Term} {events j r : List Term}
    {limit : Int} {wake : Bool} {hwm : Term}
    (sessionSame : s.get (a "session_id") = projected.get (a "session_id"))
    (planned : StateQuery.materialize projected limit j = .ok (.tuple [list events, Term.bool wake, hwm], r))
    (execution : ResidentBatch s events t) :
    ∃ session items selected ack consumes j₁ j₂ j₃,
      StateQuery.unackedItems projected j₁ = .ok (items, j₂) ∧
      StateQuery.materializeBatch projected items limit j₂ = .ok ((selected, ack, consumes), j₃) ∧
      field projected "session_id" j = .ok (session, j₁) ∧ TranscriptExtends s t ∧
      (Ordered items → ∀ item ∈ items, Retired ack consumes item →
        ∃ record, ContainsRecord t record ∧ QueuedRecord item record) := by
  have routed := materialize_routed planned
  rw [← sessionSame] at routed
  have trace := (resident_routed_reduces execution routed).1
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

theorem materialize_framed_ready {s projected t : Term} {events j r : List Term}
    {limit : Int} {wake : Bool} {hwm : Term} (ready : QueueReady s)
    (queueSame : projected.get (a "input_queue") = s.get (a "input_queue"))
    (ackSame : projected.get (a "queue_ack_id") = s.get (a "queue_ack_id"))
    (sessionSame : s.get (a "session_id") = projected.get (a "session_id"))
    (planned : StateQuery.materialize projected limit j = .ok (.tuple [list events, Term.bool wake, hwm], r))
    (execution : ResidentBatch s events t) : QueueReady t := by
  have routed := materialize_routed planned
  rw [← sessionSame] at routed
  have trace := (resident_routed_reduces execution routed).1
  obtain ⟨session, items, selected, ack, consumes, j₁, j₂, j₃, _, pending, plan, shape⟩ := materialize_coordinates planned
  obtain ⟨queue, next, read, nextRead, _, _, bounded, _⟩ := ready.1
  obtain ⟨original, previous, originalRead, baseline, _⟩ := ready.2.1
  have equal : original = queue := Term.list.inj (originalRead.symm.trans read)
  subst original
  apply resident_reduced_materialized_ready trace ready nextRead shape
  intro present
  have member := plan_ack_member (batch_plan plan) present
  exact bounded ack ((unackedItems_members (queueSame.trans read) (ackSame.trans baseline) pending ack).mp member).1

theorem materialize_framed_preserves {s projected t : Term} {events j r : List Term}
    {limit : Int} {wake : Bool} {hwm : Term} (ready : QueueReady s)
    (queueSame : projected.get (a "input_queue") = s.get (a "input_queue"))
    (ackSame : projected.get (a "queue_ack_id") = s.get (a "queue_ack_id"))
    (sessionSame : s.get (a "session_id") = projected.get (a "session_id"))
    (planned : StateQuery.materialize projected limit j = .ok (.tuple [list events, Term.bool wake, hwm], r))
    (execution : ResidentBatch s events t) :
    ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item := by
  have routed := materialize_routed planned
  rw [← sessionSame] at routed
  have trace := (resident_routed_reduces execution routed).1
  obtain ⟨session, items, selected, ack, consumes, j₁, j₂, j₃, pending, plan, sid, kept, covered⟩ :=
    materialize_framed_payloads sessionSame planned execution
  obtain ⟨session', items', selected', ack', consumes', k₁, k₂, k₃, sid', pending', plan', shape⟩ :=
    materialize_coordinates planned
  obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Except.ok.inj (sid.symm.trans sid'))
  obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Except.ok.inj (pending.symm.trans pending'))
  obtain ⟨samePlan, _⟩ := Prod.mk.inj (Except.ok.inj (plan.symm.trans plan'))
  obtain ⟨rfl, rfl, rfl⟩ := Prod.mk.inj samePlan
  obtain ⟨queue, _, read, _, _, canonical, _, unique⟩ := ready.1
  obtain ⟨queue', baseline, read', baselineRead, above⟩ := ready.2.1
  have equal : queue' = queue := Term.list.inj (read'.symm.trans read)
  subst queue'
  have ordered := unackedItems_ordered (queueSame.trans read) (ackSame.trans baselineRead) unique pending
  intro sealed item represented
  rcases represented with queued | recorded | archived
  · obtain ⟨original, current, originalRead, member, fields⟩ := queued
    have equal : original = queue := Term.list.inj (originalRead.symm.trans read)
    subst original
    by_cases retired : Retired ack consumes current
    · have pendingMember := (unackedItems_members (queueSame.trans read) (ackSame.trans baselineRead) pending current).mpr
        ⟨member, above current member⟩
      obtain ⟨record, present, stored⟩ := covered ordered current pendingMember retired
      exact Or.inr (Or.inl ⟨record, present, (queued_record_same_work fields).mpr stored⟩)
    · have initial : PendingWork s current := ⟨queue, current, read, member, rfl, rfl, rfl, rfl⟩
      obtain ⟨nextQueue, next, nextRead, nextMember, nextFields⟩ :=
        resident_reduced_unretired trace ready.1 (canonical current member) shape retired
          baselineRead (above current member) initial
      exact Or.inl ⟨nextQueue, next, nextRead, nextMember, queueWork_trans fields nextFields⟩
  · obtain ⟨record, present, fields⟩ := recorded
    exact Or.inr (Or.inl ⟨record, record_survives kept present, fields⟩)
  · exact Or.inr (Or.inr archived)

theorem materialize_framed_work {s projected t : Term} {events j r : List Term}
    {limit : Int} {wake : Bool} {hwm : Term} (ready : QueueReady s)
    (queueSame : projected.get (a "input_queue") = s.get (a "input_queue"))
    (ackSame : projected.get (a "queue_ack_id") = s.get (a "queue_ack_id"))
    (sessionSame : s.get (a "session_id") = projected.get (a "session_id"))
    (planned : StateQuery.materialize projected limit j = .ok (.tuple [list events, Term.bool wake, hwm], r))
    (execution : ResidentBatch s events t) :
    QueueReady t ∧ ∀ sealed item, ValueSemantics.Represented s sealed item → ValueSemantics.Represented t sealed item := by
  refine ⟨materialize_framed_ready ready queueSame ackSame sessionSame planned execution, ?_⟩
  obtain ⟨_, _, _, _, _, _, _, _, _, _, _, records, _⟩ := materialize_framed_payloads sessionSame planned execution
  intro sealed item represented
  exact ValueSemantics.execution_preserves
    (materialize_framed_preserves ready queueSame ackSame sessionSame planned execution sealed)
    (fun _ present => record_survives records present) represented

end VerifiedKernel.Session.WorkConservation
