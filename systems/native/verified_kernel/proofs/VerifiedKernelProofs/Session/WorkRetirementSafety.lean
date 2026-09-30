import VerifiedKernelProofs.Session.WorkSafetyOperations
import VerifiedKernelProofs.Session.WorkRouting
import VerifiedKernelProofs.Session.WorkMaterializeShape

namespace VerifiedKernel.Session.WorkConservation
open Data

theorem pruneResultRefs_ack {s t : Term} {j r : List Term}
    (h : pruneResultRefs s j = .ok (t, r)) : t.get (a "queue_ack_id") = s.get (a "queue_ack_id") := by
  unfold pruneResultRefs at h
  repeat' first
    | exact write_field_frame h rfl
    | (have same := pure_ok h; subst t; rfl)
    | split at h
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)

theorem queueConsume_ack {s e t : Term} {j r : List Term}
    (h : queueConsume s e j = .ok (t, r)) : t.get (a "queue_ack_id") = s.get (a "queue_ack_id") := by
  unfold queueConsume at h
  iterate 4 obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, written, pruned⟩ := bind_ok h
  exact (pruneResultRefs_ack pruned).trans (write_field_frame written rfl)

theorem queueAppend_ack {s e t : Term} {j r : List Term}
    (h : queueAppend s e j = .ok (t, r)) : t.get (a "queue_ack_id") = s.get (a "queue_ack_id") := by
  unfold queueAppend at h
  repeat' first
    | exact write_field_frame h rfl
    | (have same := pure_ok h; subst t; rfl)
    | (exact (fail_ok h).elim)
    | split at h
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)
    | dsimp only at h

theorem sessionEvent_ack {s e t : Term} {j r : List Term}
    (h : sessionEvent s e j = .ok (t, r)) : t.get (a "queue_ack_id") = s.get (a "queue_ack_id") :=
  (sessionEvent_fields h).2 "queue_ack_id" rfl

theorem queueAck_watermark {s e t : Term} {previous requested : Int} {j r : List Term}
    (baseline : s.get (a "queue_ack_id") = i previous)
    (request : e.get (b "queue_ack_id") = i requested)
    (h : queueAck s e j = .ok (t, r)) : t.get (a "queue_ack_id") = i (max previous requested) := by
  unfold queueAck at h
  obtain ⟨old, _, oldRead, h⟩ := bind_ok h
  have oldValue := (field_value oldRead).trans baseline
  subst old
  obtain ⟨value, _, valueRead, h⟩ := bind_ok h
  have valueEq := (access_ok valueRead).1.trans request
  subst value
  simp only [Term.default, Term.truthy, i, ↓reduceIte] at h
  obtain ⟨ack, _, maxRead, h⟩ := bind_ok h
  rw [maximum_integer] at maxRead
  have ackValue := (Prod.mk.inj (Except.ok.inj maxRead)).1.symm
  subst ack
  iterate 3 obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, written, pruned⟩ := bind_ok h
  rw [pruneResultRefs_ack pruned]
  obtain ⟨_, written⟩ := write_cons written
  exact (write_field_frame written rfl).trans (get_put_same _ _ _)

theorem inner_ack_frame {s e t : Term} {j r : List Term}
    (notAck : e.get (b "type") ≠ b "queue_ack")
    (h : inner s e j = .ok (t, r)) : t.get (a "queue_ack_id") = s.get (a "queue_ack_id") := by
  by_cases append : e.get (b "type") = b "queue_append"
  · apply queueAppend_ack; simpa +decide [inner, append] using h
  by_cases consume : e.get (b "type") = b "queue_consume"
  · simp +decide [inner, consume] at h
    split at h
    · exact queueConsume_ack h
    · have same := pure_ok h; subst t; rfl
  by_cases fact : e.get (b "type") = b "session_event"
  · apply sessionEvent_ack; simpa +decide [inner, fact] using h
  exact (inner_queue_frame (binary_ne_false append) (binary_ne_false notAck)
    (binary_ne_false consume) (binary_ne_false fact) h).2.2.1

theorem queueWork_id {original current : Term}
    (originalKeys : CanonicalQueueItem original) (currentKeys : CanonicalQueueItem current)
    (same : QueueWork original current) : queueId current = queueId original := by
  obtain ⟨first, rfl, firstKeys, _⟩ := originalKeys
  obtain ⟨second, rfl, secondKeys, _⟩ := currentKeys
  unfold queueId
  rw [binary_map_atom_nil _ firstKeys, binary_map_atom_nil _ secondKeys, same.1]

def PendingWork (s item : Term) : Prop :=
  ∃ queue current, s.get (a "input_queue") = list queue ∧ current ∈ queue ∧ QueueWork item current

theorem pending_frame {s t item : Term} (frame : QueuePreserved s t)
    (pending : PendingWork s item) : PendingWork t item := by
  obtain ⟨queue, current, read, member, same⟩ := pending
  exact ⟨queue, current, frame.trans read, member, same⟩

theorem sessionEvent_pending {s e t item : Term} {j r : List Term}
    (pending : PendingWork s item) (h : sessionEvent s e j = .ok (t, r)) : PendingWork t item := by
  obtain ⟨queue, current, read, member, same⟩ := pending
  obtain ⟨result, _, _, _, retry, output, _⟩ := sessionEvent_queue_result read h
  obtain ⟨kept, next, encoded, present, fields⟩ := markRetry_represents_queue member same retry
  exact ⟨kept, next, output.trans encoded, present, fields⟩

/-- Planned retirement events cannot remove work outside their retirement coordinates. -/
theorem materialized_inner_unretired {s e t item ack : Term} {consumes j r : List Term} {previous : Int}
    (invariant : QueueAllocated s) (canonical : CanonicalQueueItem item)
    (shape : MaterializedEvent ack consumes e) (unretired : ¬Retired ack consumes item)
    (baseline : s.get (a "queue_ack_id") = i previous) (above : previous < queueId item)
    (pending : PendingWork s item) (h : inner s e j = .ok (t, r)) :
    PendingWork t item ∧ ∃ nextAck, t.get (a "queue_ack_id") = i nextAck ∧ nextAck < queueId item := by
  rcases shape with record | ⟨kind, present, request⟩ | ⟨kind, consumed, member, request⟩ | kind
  · rcases record.2 with kind | kind
    all_goals
      have frame := inner_queue_frame
        (by simp +decide [kind]) (by simp +decide [kind])
        (by simp +decide [kind]) (by simp +decide [kind]) h
      exact ⟨pending_frame frame.1 pending, previous, frame.2.2.1.trans baseline, above⟩
  · have reduced : queueAck s e j = .ok (t, r) := by simpa +decide [inner, kind] using h
    obtain ⟨items, _, read, _, _, keys, _⟩ := invariant
    obtain ⟨original, current, originalRead, member, same⟩ := pending
    have equal : original = items := Term.list.inj (originalRead.symm.trans read)
    subst original
    have id := queueWork_id canonical (keys current member) same
    have ackBelow : queueId ack < queueId item := by
      by_cases below : queueId ack < queueId item
      · exact below
      · exact (unretired (Or.inl ⟨present, by omega⟩)).elim
    have maxBelow : max previous (queueId ack) < queueId item := by omega
    obtain ⟨kept, nextRead, members⟩ := queueAck_members read keys baseline request reduced
    refine ⟨⟨kept, current, nextRead, (members current).mpr ⟨member, ?_⟩, same⟩,
      _, queueAck_watermark baseline request reduced, maxBelow⟩
    simpa only [id] using maxBelow
  · simp +decide [inner, kind] at h
    split at h
    · have reduced := h
      obtain ⟨items, _, read, _, _, keys, _⟩ := invariant
      obtain ⟨original, current, originalRead, queued, same⟩ := pending
      have equal : original = items := Term.list.inj (originalRead.symm.trans read)
      subst original
      have id := queueWork_id canonical (keys current queued) same
      have different : queueId current ≠ queueId consumed := by
        intro equal
        exact unretired (Or.inr ⟨consumed, member, id.symm.trans equal⟩)
      obtain ⟨kept, nextRead, members⟩ := queueConsume_members read keys request reduced
      exact ⟨⟨kept, current, nextRead, (members current).mpr ⟨queued, different⟩, same⟩,
        previous, (queueConsume_ack reduced).trans baseline, above⟩
    · have same := pure_ok h
      subst t
      exact ⟨pending, previous, baseline, above⟩
  · have reduced : sessionEvent s e j = .ok (t, r) := by simpa +decide [inner, kind] using h
    exact ⟨sessionEvent_pending pending reduced, previous, (sessionEvent_ack reduced).trans baseline, above⟩

theorem projected_unretired {s t item ack : Term} {raw normalized consumes j r : List Term} {previous : Int}
    (trace : ProjectedBatch s raw j normalized t r)
    (invariant : QueueAllocated s) (canonical : CanonicalQueueItem item)
    (shape : ∀ event ∈ normalized, MaterializedEvent ack consumes event)
    (unretired : ¬Retired ack consumes item)
    (baseline : s.get (a "queue_ack_id") = i previous) (above : previous < queueId item)
    (pending : PendingWork s item) : PendingWork t item := by
  induction trace generalizing previous with
  | nil => exact pending
  | skip prepared tail ih =>
    have same := prepareTrusted_none prepared
    subst same
    exact ih invariant shape baseline above pending
  | cons prepared activity tail ih =>
    obtain ⟨_, _, _, reduced⟩ := prepareTrusted_stringify prepared
    have head := shape _ List.mem_cons_self
    obtain ⟨pending, nextAck, ackValue, above⟩ :=
      materialized_inner_unretired invariant canonical head unretired baseline above pending reduced
    have frame := afterEvent_queue_frame activity
    exact ih (queue_frame_allocated frame (inner_allocation invariant reduced))
      (fun event member => shape event (List.mem_cons_of_mem _ member))
      (frame.2.2.1.trans ackValue) above (pending_frame frame.1 pending)

/-- Every resident queue item lies above the persisted retirement watermark. -/
def QueueUnacked (s : Term) : Prop :=
  ∃ items ack, s.get (a "input_queue") = list items ∧ s.get (a "queue_ack_id") = i ack ∧
    ∀ item ∈ items, ack < queueId item

theorem queueWork_trans {first second third : Term}
    (left : QueueWork first second) (right : QueueWork second third) : QueueWork first third :=
  ⟨right.1.trans left.1, right.2.1.trans left.2.1,
    right.2.2.1.trans left.2.2.1, right.2.2.2.trans left.2.2.2⟩

/-- Concrete materialization conserves work through the actual query, projection, and queue filters. -/
theorem materialize_project_preserves {s t : Term} {events j r before after : List Term}
    {limit : Int} {wake : Bool} {hwm : Term}
    (invariant : QueueAllocated s) (live : QueueUnacked s)
    (planned : StateQuery.materialize s limit j = .ok (.tuple [list events, Term.bool wake, hwm], r))
    (projected : Command.project s events before = .ok (t, after)) :
    ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item := by
  have allocation := invariant
  have trace := materialize_project_exact planned projected
  obtain ⟨session, items, selected, ack, consumes, j₁, j₂, j₃, pending, plan, sid, kept, covered⟩ :=
    materialize_project_payloads planned projected
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
        projected_unretired trace allocation (canonical current member) shape retired
          baselineRead (above current member) initial
      exact Or.inl ⟨nextQueue, next, nextRead, nextMember, queueWork_trans fields nextFields⟩
  · obtain ⟨record, present, fields⟩ := recorded
    exact Or.inr (Or.inl ⟨record, record_survives kept present, fields⟩)
  · exact Or.inr (Or.inr archived)

end VerifiedKernel.Session.WorkConservation
