import VerifiedKernelProofs.Session.WorkResidentMaterialize

namespace VerifiedKernel.Session.WorkConservation
open Data

theorem resident_reduced_unretired {s t item ack : Term} {events consumes : List Term} {previous : Int}
    (trace : ResidentReducedBatch s events t)
    (invariant : QueueAllocated s) (canonical : CanonicalQueueItem item)
    (shape : ∀ event ∈ events, MaterializedEvent ack consumes event)
    (unretired : ¬Retired ack consumes item)
    (baseline : s.get (a "queue_ack_id") = i previous) (above : previous < queueId item)
    (pending : PendingWork s item) : PendingWork t item := by
  induction trace generalizing previous with
  | nil => exact pending
  | cons reduced activity tail ih =>
    obtain ⟨pending, nextAck, ackValue, above⟩ := materialized_inner_unretired invariant canonical
      (shape _ List.mem_cons_self) unretired baseline above pending reduced
    have frame := activity_frame_queue activity
    exact ih (queue_frame_allocated frame (inner_allocation invariant reduced))
      (fun event member => shape event (List.mem_cons_of_mem _ member))
      (frame.2.2.1.trans ackValue) above (pending_frame frame.1 pending)

theorem materialize_resident_preserves {s t : Term} {events j r : List Term}
    {limit : Int} {wake : Bool} {hwm : Term}
    (invariant : QueueAllocated s) (live : QueueUnacked s)
    (planned : StateQuery.materialize s limit j = .ok (.tuple [list events, Term.bool wake, hwm], r))
    (execution : ResidentBatch s events t) :
    ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item := by
  have allocation := invariant
  have trace := (resident_routed_reduces execution (materialize_routed planned)).1
  obtain ⟨session, items, selected, ack, consumes, j₁, j₂, j₃, pending, plan, sid, kept, covered⟩ :=
    materialize_resident_payloads planned execution
  obtain ⟨session', items', selected', ack', consumes', k₁, k₂, k₃, sid', pending', plan', shape⟩ :=
    materialize_coordinates planned
  obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Except.ok.inj (sid.symm.trans sid'))
  obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Except.ok.inj (pending.symm.trans pending'))
  obtain ⟨samePlan, _⟩ := Prod.mk.inj (Except.ok.inj (plan.symm.trans plan'))
  obtain ⟨rfl, rfl, rfl⟩ := Prod.mk.inj samePlan
  obtain ⟨queue, _, read, _, _, canonical, _, unique⟩ := invariant
  obtain ⟨queue', baseline, read', baselineRead, above⟩ := live
  have equal : queue' = queue := Term.list.inj (read'.symm.trans read)
  subst queue'
  have ordered := unackedItems_ordered read baselineRead unique pending
  intro sealed item represented
  rcases represented with queued | recorded | archived
  · obtain ⟨original, current, originalRead, member, fields⟩ := queued
    have equal : original = queue := Term.list.inj (originalRead.symm.trans read)
    subst original
    by_cases retired : Retired ack consumes current
    · have pendingMember := (unackedItems_members read baselineRead pending current).mpr ⟨member, above current member⟩
      obtain ⟨record, present, stored⟩ := covered ordered current pendingMember retired
      exact Or.inr (Or.inl ⟨record, present, (queued_record_same_work fields).mpr stored⟩)
    · have initial : PendingWork s current := ⟨queue, current, read, member, rfl, rfl, rfl, rfl⟩
      obtain ⟨nextQueue, next, nextRead, nextMember, nextFields⟩ :=
        resident_reduced_unretired trace allocation (canonical current member) shape retired
          baselineRead (above current member) initial
      exact Or.inl ⟨nextQueue, next, nextRead, nextMember, queueWork_trans fields nextFields⟩
  · obtain ⟨record, present, fields⟩ := recorded
    exact Or.inr (Or.inl ⟨record, record_survives kept present, fields⟩)
  · exact Or.inr (Or.inr archived)

theorem resident_reduced_materialized_ready {s t ack : Term} {events consumes : List Term} {next : Int}
    (trace : ResidentReducedBatch s events t) (ready : QueueReady s)
    (nextRead : s.get (a "next_queue_id") = i next)
    (shape : ∀ event ∈ events, MaterializedEvent ack consumes event)
    (ackBound : ack ≠ nil → queueId ack < next) : QueueReady t := by
  induction trace with
  | nil => exact ready
  | cons reduced activity tail ih =>
    obtain ⟨updated, nextValue⟩ := materialized_inner_ready ready nextRead
      (shape _ List.mem_cons_self) ackBound reduced
    have frame := activity_frame_queue activity
    exact ih (queue_frame_ready frame updated) (frame.2.1.trans nextValue)
      (fun event member => shape event (List.mem_cons_of_mem _ member))

theorem materialize_resident_ready {s t : Term} {events j r : List Term}
    {limit : Int} {wake : Bool} {hwm : Term} (ready : QueueReady s)
    (planned : StateQuery.materialize s limit j = .ok (.tuple [list events, Term.bool wake, hwm], r))
    (execution : ResidentBatch s events t) : QueueReady t := by
  have trace := (resident_routed_reduces execution (materialize_routed planned)).1
  obtain ⟨session, items, selected, ack, consumes, j₁, j₂, j₃, _, pending, plan, shape⟩ := materialize_coordinates planned
  have allocation := ready.1
  obtain ⟨queue, next, read, nextRead, _, _, bounded, _⟩ := allocation
  have live := ready.2.1
  obtain ⟨original, previous, originalRead, baseline, _⟩ := live
  have equal : original = queue := Term.list.inj (originalRead.symm.trans read)
  subst original
  apply resident_reduced_materialized_ready trace ready nextRead shape
  intro present
  have member := plan_ack_member (batch_plan plan) present
  exact bounded ack ((unackedItems_members read baseline pending ack).mp member).1

end VerifiedKernel.Session.WorkConservation
