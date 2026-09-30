import VerifiedKernelProofs.Session.WorkRepresentation
import VerifiedKernelProofs.Session.AppendOnly.SessionEvent

namespace VerifiedKernel.Session.WorkConservation
open Data

theorem enumMap_projection {xs ys : List Term} {f : Term → KernelM Term} {j r : List Term}
    (projection : Term → Term)
    (keep : ∀ x y j r, f x j = .ok (y, r) → projection y = projection x)
    (h : enumMap (list xs) f j = .ok (ys, r)) : ys.map projection = xs.map projection := by
  unfold enumMap at h
  obtain ⟨acc, _, folded, h⟩ := bind_ok h
  obtain ⟨items, folded, same⟩ := enumFold_ok folded
  rw [same xs rfl] at folded
  rw [pure_ok h, List.map_reverse, foldlM_cons_map projection keep xs folded]
  simp

/-- Retry marking preserves queue order and each item's work-bearing fields. -/
theorem markRetry_work {items : List Term} {fact result : Term} {j r : List Term}
    (h : markRetry (list items) fact j = .ok (result, r)) :
    ∃ kept, result = list kept ∧ kept.map queueWorkProjection = items.map queueWorkProjection := by
  unfold markRetry at h
  split at h
  · obtain ⟨kept, _, mapped, h⟩ := bind_ok h
    refine ⟨kept, pure_ok h, enumMap_projection queueWorkProjection ?_ mapped⟩
    intro before after j r reduced
    obtain ⟨_, _, _, reduced⟩ := bind_ok reduced
    dsimp only at reduced
    split at reduced
    · rw [put_ok reduced]
      unfold queueWorkProjection
      simp only [get_put_binary_other _ _ (show "activation_retry_consumed" ≠ "queue_id" by decide),
        get_put_binary_other _ _ (show "activation_retry_consumed" ≠ "kind" by decide),
        get_put_binary_other _ _ (show "activation_retry_consumed" ≠ "dedupe_key" by decide),
        get_put_binary_other _ _ (show "activation_retry_consumed" ≠ "payload" by decide)]
    · rw [pure_ok reduced]
  · exact ⟨items, pure_ok h, rfl⟩

theorem markRetry_represents_queue {items : List Term} {fact result original current : Term}
    {j r : List Term} (member : current ∈ items) (same : QueueWork original current)
    (h : markRetry (list items) fact j = .ok (result, r)) :
    ∃ kept next, result = list kept ∧ next ∈ kept ∧ QueueWork original next := by
  obtain ⟨kept, result, projected⟩ := markRetry_work h
  have present : queueWorkProjection current ∈ kept.map queueWorkProjection := by
    rw [projected]
    exact List.mem_map_of_mem member
  obtain ⟨next, member, identity⟩ := List.mem_map.mp present
  exact ⟨kept, next, result, member,
    queueWork_projection.mpr (identity.trans (queueWork_projection.mp same))⟩

/-- The fact reducer writes exactly the retry result and keeps records and the allocator. -/
theorem sessionEvent_queue_result {s e t : Term} {items j r : List Term}
    (read : s.get (a "input_queue") = list items)
    (h : sessionEvent s e j = .ok (t, r)) :
    ∃ queue fact j₁ j₂, markRetry (list items) fact j₁ = .ok (queue, j₂) ∧
      t.get (a "input_queue") = queue ∧ t.get (a "messages") = s.get (a "messages") ∧
      t.get (a "next_queue_id") = s.get (a "next_queue_id") := by
  have frame := (sessionEvent_fields h).2
  obtain ⟨queue, fact, first, last, retry, written⟩ := sessionEvent_retry_result h
  refine ⟨queue, fact, first, last, ?_, written, frame "messages" rfl, frame "next_queue_id" rfl⟩
  simpa only [read] using retry

/-- Session facts keep concrete work. Retry marking changes no work-bearing queue field. -/
theorem sessionEvent_representation {s e t item : Term} {items sealed j r : List Term}
    (read : s.get (a "input_queue") = list items)
    (h : sessionEvent s e j = .ok (t, r))
    (represented : ConcreteRepresented s sealed item) : ConcreteRepresented t sealed item := by
  obtain ⟨queue, _, _, _, retry, queueValue, messages, _⟩ := sessionEvent_queue_result read h
  rcases represented with pending | recorded | archived
  · obtain ⟨original, current, originalRead, member, same⟩ := pending
    have equal : original = items := Term.list.inj (originalRead.symm.trans read)
    subst original
    obtain ⟨kept, next, result, present, keptWork⟩ := markRetry_represents_queue member same retry
    exact Or.inl ⟨kept, next, queueValue.trans result, present, keptWork⟩
  · obtain ⟨record, ⟨records, recordsRead, present⟩, fields⟩ := recorded
    exact Or.inr (Or.inl ⟨record, ⟨records, messages.trans recordsRead, present⟩, fields⟩)
  · exact Or.inr (Or.inr archived)

theorem foldlM_cons_all {property : Term → Prop} {f : Term → KernelM Term}
    (correct : ∀ x y j r, property x → f x j = .ok (y, r) → property y)
    {xs initial out : List Term} {j r : List Term}
    (input : ∀ x ∈ xs, property x) (before : ∀ x ∈ initial, property x)
    (h : xs.foldlM (fun acc item => (do return (← f item) :: acc : KernelM (List Term))) initial j = .ok (out, r)) :
    ∀ x ∈ out, property x := by
  induction xs generalizing initial j with
  | nil => rw [pure_ok h]; exact before
  | cons x xs ih =>
    rw [List.foldlM_cons] at h
    obtain ⟨next, _, step, h⟩ := bind_ok h
    obtain ⟨value, _, applied, step⟩ := bind_ok step
    rw [pure_ok step] at h
    apply ih (fun y member => input y (List.mem_cons_of_mem _ member)) _ h
    intro y member
    rcases List.mem_cons.mp member with rfl | old
    · exact correct x y _ _ (input x (by simp)) applied
    · exact before y old

theorem enumMap_all {property : Term → Prop} {f : Term → KernelM Term} {xs out j r : List Term}
    (correct : ∀ x y j r, property x → f x j = .ok (y, r) → property y)
    (input : ∀ x ∈ xs, property x)
    (h : enumMap (list xs) f j = .ok (out, r)) : ∀ x ∈ out, property x := by
  unfold enumMap at h
  obtain ⟨acc, _, folded, h⟩ := bind_ok h
  obtain ⟨items, folded, same⟩ := enumFold_ok folded
  rw [same xs rfl] at folded
  have kept := foldlM_cons_all correct input (by simp) folded
  intro x member
  rw [pure_ok h, List.mem_reverse] at member
  exact kept x member

theorem markRetry_allocation {items : List Term} {fact result : Term} {j r : List Term}
    (canonical : ∀ item ∈ items, CanonicalQueueItem item)
    (h : markRetry (list items) fact j = .ok (result, r)) :
    ∃ kept, result = list kept ∧ (∀ item ∈ kept, CanonicalQueueItem item) ∧
      kept.map queueId = items.map queueId := by
  unfold markRetry at h
  split at h
  · obtain ⟨kept, _, mapped, h⟩ := bind_ok h
    refine ⟨kept, pure_ok h, enumMap_all ?_ canonical mapped, ?_⟩
    · intro before after j r valid reduced
      obtain ⟨_, _, _, reduced⟩ := bind_ok reduced
      dsimp only at reduced
      split at reduced
      · rw [put_ok reduced]
        exact canonical_put_other valid (by decide)
      · rw [pure_ok reduced]
        exact valid
    · have ids := enumMap_projection (fun item => i (queueId item)) ?_ mapped
      · have values := congrArg (List.map integerValue) ids
        simpa only [List.map_map, Function.comp_def, i, integerValue] using values
      · intro before after j r reduced
        obtain ⟨_, _, _, reduced⟩ := bind_ok reduced
        dsimp only at reduced
        split at reduced
        · rw [put_ok reduced]
          simp only [queueId, get_put_binary_atom,
            get_put_binary_other _ _ (show "activation_retry_consumed" ≠ "queue_id" by decide)]
        · rw [pure_ok reduced]
  · exact ⟨items, pure_ok h, canonical, rfl⟩

theorem sessionEvent_allocation {s e t : Term} {j r : List Term}
    (invariant : QueueAllocated s) (h : sessionEvent s e j = .ok (t, r)) : QueueAllocated t := by
  obtain ⟨items, next, read, nextRead, positive, canonical, bounded, unique⟩ := invariant
  obtain ⟨result, _, _, _, retry, queueValue, _, nextValue⟩ := sessionEvent_queue_result read h
  obtain ⟨kept, result, canonical, ids⟩ := markRetry_allocation canonical retry
  refine ⟨kept, next, queueValue.trans result, nextValue.trans nextRead, positive, canonical, ?_, ?_⟩
  · intro item member
    have present : queueId item ∈ items.map queueId := by rw [← ids]; exact List.mem_map_of_mem member
    obtain ⟨original, present, same⟩ := List.mem_map.mp present
    rw [← same]
    exact bounded original present
  · rw [ids]
    exact unique

end VerifiedKernel.Session.WorkConservation
