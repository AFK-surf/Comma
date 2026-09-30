import VerifiedKernelProofs.Session.WorkRetirementSafety

namespace VerifiedKernel.Session.WorkConservation
open Data

/-- Queue admission keeps the allocator ahead of the retirement watermark. -/
def QueueReady (s : Term) : Prop :=
  QueueAllocated s ∧ QueueUnacked s ∧
    integerValue (s.get (a "queue_ack_id")) < integerValue (s.get (a "next_queue_id"))

theorem queue_frame_ready {s t : Term} (frame : QueueFrame s t) (ready : QueueReady s) : QueueReady t := by
  obtain ⟨allocated, ⟨items, ack, read, baseline, above⟩, bound⟩ := ready
  refine ⟨queue_frame_allocated frame allocated,
    ⟨items, ack, frame.1.trans read, frame.2.2.1.trans baseline, above⟩, ?_⟩
  simpa only [frame.2.1, frame.2.2.1] using bound

theorem sessionEvent_ready {s e t : Term} {j r : List Term}
    (ready : QueueReady s) (h : sessionEvent s e j = .ok (t, r)) : QueueReady t := by
  obtain ⟨allocated, live, bound⟩ := ready
  have result := sessionEvent_allocation allocated h
  obtain ⟨items, next, read, nextRead, positive, canonical, _⟩ := allocated
  obtain ⟨original, ack, originalRead, baseline, above⟩ := live
  have equal : original = items := Term.list.inj (originalRead.symm.trans read)
  subst original
  obtain ⟨queue, _, _, _, retry, queueValue, _, nextValue⟩ := sessionEvent_queue_result read h
  obtain ⟨kept, encoded, _, ids⟩ := markRetry_allocation canonical retry
  refine ⟨result, ⟨kept, ack, queueValue.trans encoded, (sessionEvent_ack h).trans baseline, ?_⟩, ?_⟩
  · intro current member
    have idMember : queueId current ∈ items.map queueId := by
      rw [← ids]
      exact List.mem_map_of_mem member
    obtain ⟨previous, present, same⟩ := List.mem_map.mp idMember
    rw [← same]
    exact above previous present
  · simpa only [sessionEvent_ack h, nextValue] using bound

theorem queueAppend_ready {s e t : Term} {j r : List Term}
    (ready : QueueReady s) (h : queueAppend s e j = .ok (t, r)) : QueueReady t := by
  have result := queueAppend_allocated ready.1 h
  have allocated := ready.1
  obtain ⟨items, next, read, nextRead, positive, canonical, _⟩ := allocated
  rcases queueAppend_allocates nextRead h with same | ⟨item, normalized, payload, j₁, j₂, j₃, j₄,
      _, normalizedRead, fields, queueValue, nextValue⟩
  · subst t; exact ready
  obtain ⟨_, ⟨original, ack, originalRead, baseline, above⟩, bound⟩ := ready
  have equal : original = items := Term.list.inj (originalRead.symm.trans read)
  subst original
  rw [read] at normalizedRead
  have permutation := normalizeQueue_permutation canonical normalizedRead
  have ackBelow : ack < next := by simpa only [baseline, nextRead, i, integerValue] using bound
  have itemId : queueId item = next := by
    unfold queueId
    rw [fields.2.1]
    rfl
  refine ⟨result, ⟨normalized ++ [item], ack, queueValue, (queueAppend_ack h).trans baseline, ?_⟩, ?_⟩
  · intro current member
    rcases List.mem_append.mp member with old | fresh
    · exact above current (permutation.mem_iff.mp old)
    · have same : current = item := by simpa using fresh
      simpa only [same, itemId] using ackBelow
  · simp only [queueAppend_ack h, baseline, nextValue, i, integerValue]
    omega

theorem admitted_inner_ready {s e t : Term} {j r : List Term}
    (ready : QueueReady s) (allowed : Command.inputEventAllowed e = true)
    (h : inner s e j = .ok (t, r)) : QueueReady t := by
  have excluded := InputAdmission.admitted_event_no_retirement (events := [e])
    (event := e) (by simpa using allowed) (by simp)
  by_cases append : e.get (b "type") = b "queue_append"
  · apply queueAppend_ready ready; simpa +decide [inner, append] using h
  by_cases fact : e.get (b "type") = b "session_event"
  · apply sessionEvent_ready ready; simpa +decide [inner, fact] using h
  exact queue_frame_ready (inner_queue_frame (binary_ne_false append) (binary_ne_false excluded.1)
    (binary_ne_false excluded.2.1) (binary_ne_false fact) h) ready

theorem projected_admitted_ready {s t : Term} {raw normalized j r : List Term}
    (trace : ProjectedBatch s raw j normalized t r) (ready : QueueReady s)
    (allowed : normalized.all Command.inputEventAllowed = true) : QueueReady t := by
  induction trace with
  | nil => exact ready
  | skip prepared tail ih =>
    have same := prepareTrusted_none prepared
    subst same
    exact ih ready allowed
  | cons prepared activity tail ih =>
    obtain ⟨_, _, _, reduced⟩ := prepareTrusted_stringify prepared
    simp only [List.all_cons, Bool.and_eq_true] at allowed
    exact ih (queue_frame_ready (afterEvent_queue_frame activity) (admitted_inner_ready ready allowed.1 reduced)) allowed.2

theorem queueConsume_ready {s e t : Term} {id : Int} {j r : List Term}
    (ready : QueueReady s) (request : e.get (b "queue_id") = i id)
    (h : queueConsume s e j = .ok (t, r)) : QueueReady t := by
  have allocated := queueConsume_allocation ready.1 h
  obtain ⟨allocation, ⟨items, ack, read, baseline, above⟩, bound⟩ := ready
  obtain ⟨original, _, originalRead, _, _, keys, _⟩ := allocation
  have equal : original = items := Term.list.inj (originalRead.symm.trans read)
  subst original
  obtain ⟨kept, nextRead, members⟩ := queueConsume_members read keys request h
  refine ⟨allocated, ⟨kept, ack, nextRead, (queueConsume_ack h).trans baseline, ?_⟩, ?_⟩
  · exact fun item member => above item ((members item).mp member).1
  · simpa only [queueConsume_ack h, queueConsume_next_id h] using bound

theorem queueAck_ready {s e t : Term} {requested next : Int} {j r : List Term}
    (ready : QueueReady s) (nextRead : s.get (a "next_queue_id") = i next)
    (request : e.get (b "queue_ack_id") = i requested) (requestBound : requested < next)
    (h : queueAck s e j = .ok (t, r)) : QueueReady t := by
  have allocated := queueAck_allocation ready.1 h
  obtain ⟨allocation, ⟨items, ack, read, baseline, above⟩, bound⟩ := ready
  obtain ⟨original, _, originalRead, _, _, keys, _⟩ := allocation
  have equal : original = items := Term.list.inj (originalRead.symm.trans read)
  subst original
  obtain ⟨kept, queueRead, members⟩ := queueAck_members read keys baseline request h
  refine ⟨allocated, ⟨kept, max ack requested, queueRead, queueAck_watermark baseline request h, ?_⟩, ?_⟩
  · exact fun item member => ((members item).mp member).2
  · simp only [queueAck_watermark baseline request h, queueAck_next_id h, nextRead, i, integerValue]
    have before : ack < next := by simpa only [baseline, nextRead, i, integerValue] using bound
    omega

theorem materialized_inner_ready {s e t ack : Term} {consumes j r : List Term} {next : Int}
    (ready : QueueReady s) (nextRead : s.get (a "next_queue_id") = i next)
    (shape : MaterializedEvent ack consumes e) (ackBound : ack ≠ nil → queueId ack < next)
    (h : inner s e j = .ok (t, r)) : QueueReady t ∧ t.get (a "next_queue_id") = i next := by
  rcases shape with record | ⟨kind, present, request⟩ | ⟨kind, consumed, member, request⟩ | kind
  · rcases record.2 with kind | kind
    all_goals
      have frame := inner_queue_frame
        (by simp +decide [kind]) (by simp +decide [kind])
        (by simp +decide [kind]) (by simp +decide [kind]) h
      exact ⟨queue_frame_ready frame ready, frame.2.1.trans nextRead⟩
  · have reduced : queueAck s e j = .ok (t, r) := by simpa +decide [inner, kind] using h
    exact ⟨queueAck_ready ready nextRead request (ackBound present) reduced,
      (queueAck_next_id reduced).trans nextRead⟩
  · simp +decide [inner, kind] at h
    split at h
    · exact ⟨queueConsume_ready ready request h, (queueConsume_next_id h).trans nextRead⟩
    · have same := pure_ok h; subst t; exact ⟨ready, nextRead⟩
  · have reduced : sessionEvent s e j = .ok (t, r) := by simpa +decide [inner, kind] using h
    have updated := sessionEvent_ready ready reduced
    obtain ⟨items, _, read, _⟩ := ready.1
    obtain ⟨_, _, _, _, _, _, _, frame⟩ := sessionEvent_queue_result read reduced
    exact ⟨updated, frame.trans nextRead⟩

theorem projected_materialized_ready {s t ack : Term} {raw normalized consumes j r : List Term} {next : Int}
    (trace : ProjectedBatch s raw j normalized t r) (ready : QueueReady s)
    (nextRead : s.get (a "next_queue_id") = i next)
    (shape : ∀ event ∈ normalized, MaterializedEvent ack consumes event)
    (ackBound : ack ≠ nil → queueId ack < next) : QueueReady t := by
  induction trace with
  | nil => exact ready
  | skip prepared tail ih =>
    have same := prepareTrusted_none prepared
    subst same
    exact ih ready nextRead shape
  | cons prepared activity tail ih =>
    obtain ⟨_, _, _, reduced⟩ := prepareTrusted_stringify prepared
    obtain ⟨updated, nextValue⟩ := materialized_inner_ready ready nextRead
      (shape _ List.mem_cons_self) ackBound reduced
    have frame := afterEvent_queue_frame activity
    exact ih (queue_frame_ready frame updated) (frame.2.1.trans nextValue)
      (fun event member => shape event (List.mem_cons_of_mem _ member))

theorem plan_ack_member {items selected consumes : List Term} {ack : Term}
    (plan : Plan items selected ack consumes) (present : ack ≠ nil) : ack ∈ items := by
  obtain ⟨pre, _, selectedPre, ackEq, _, selectedItems⟩ := plan
  apply selectedItems
  apply selectedPre
  cases last : pre.getLast? with
  | none => simp [last] at ackEq; exact (present ackEq).elim
  | some value =>
    simp only [last, Option.getD_some] at ackEq
    subst ack
    exact List.mem_of_getLast? last

/-- Materialization keeps the queue invariant required by the next input or materialization. -/
theorem materialize_project_ready {s t : Term} {events j r before after : List Term}
    {limit : Int} {wake : Bool} {hwm : Term} (ready : QueueReady s)
    (planned : StateQuery.materialize s limit j = .ok (.tuple [list events, Term.bool wake, hwm], r))
    (projected : Command.project s events before = .ok (t, after)) : QueueReady t := by
  have trace := materialize_project_exact planned projected
  obtain ⟨session, items, selected, ack, consumes, j₁, j₂, j₃, _, pending, plan, shape⟩ := materialize_coordinates planned
  have allocation := ready.1
  obtain ⟨queue, next, read, nextRead, _, _, bounded, _⟩ := allocation
  have live := ready.2.1
  obtain ⟨original, previous, originalRead, baseline, _⟩ := live
  have equal : original = queue := Term.list.inj (originalRead.symm.trans read)
  subst original
  apply projected_materialized_ready trace ready nextRead shape
  intro present
  have member := plan_ack_member (batch_plan plan) present
  exact bounded ack ((unackedItems_members read baseline pending ack).mp member).1

theorem project_input_ready {s t : Term} {events j r : List Term}
    (ready : QueueReady s) (keys : ∀ event ∈ events, BinaryKeys event)
    (allowed : events.all Command.inputEventAllowed = true)
    (h : Command.project s events j = .ok (t, r)) : QueueReady t := by
  obtain ⟨normalized, trace⟩ := project_execution h
  have subset := (projected_binary_sublist trace keys).subset
  exact projected_admitted_ready trace ready
    (List.all_eq_true.mpr (fun event member => List.all_eq_true.mp allowed event (subset member)))

theorem input_projection_ready {s args result : Term} {j r : List Term}
    (ready : QueueReady s) (h : Command.input s args j = .ok (result, r)) :
    result = Command.duplicateInput ∨
    result = Command.finish (.tuple [a "error", a "saturated"]) ∨
    result = Command.finish (.tuple [a "error", a "invalid_delivery_events"]) ∨
    ∃ batch, InputStart result batch ∧
      ∀ t before after, Command.project s batch before = .ok (t, after) → QueueReady t := by
  rcases input_start h with duplicate | saturated | invalid | ⟨batch, start, keys, allowed⟩
  · exact Or.inl duplicate
  · exact Or.inr (Or.inl saturated)
  · exact Or.inr (Or.inr (Or.inl invalid))
  · exact Or.inr (Or.inr (Or.inr ⟨batch, start,
      fun _ _ _ projected => project_input_ready ready keys allowed projected⟩))

end VerifiedKernel.Session.WorkConservation
