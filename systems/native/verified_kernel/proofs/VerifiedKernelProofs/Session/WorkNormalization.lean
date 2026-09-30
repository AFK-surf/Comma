import VerifiedKernelProofs.Session.WorkRetirement

namespace VerifiedKernel.Session.WorkConservation
open Data

theorem merge_permutation {cmp : Term → Term → KernelM Ordering}
    {fuel : Nat} {xs ys acc out : List Term} {j r : List Term}
    (h : sortM.merge cmp fuel xs ys acc j = .ok (out, r)) :
    out.Perm (acc.reverse ++ xs ++ ys) := by
  induction fuel generalizing xs ys acc j with
  | zero =>
    cases xs <;> cases ys
    all_goals first
      | (have eq := pure_ok h; rw [eq]; simp)
      | (simp only [sortM.merge, fail_ok_iff] at h)
  | succ fuel ih =>
    cases xs with
    | nil =>
      have eq := pure_ok h
      rw [eq]
      simp
    | cons x xs =>
      cases ys with
      | nil =>
        have eq := pure_ok h
        rw [eq]
        simp
      | cons y ys =>
        unfold sortM.merge at h
        obtain ⟨order, _, _, h⟩ := bind_ok h
        split at h
        · simpa [List.append_assoc] using ih h
        · have perm := ih h
          simp only [List.reverse_cons, List.append_assoc, List.cons_append,
            List.nil_append] at perm
          have moved := List.Perm.append_left acc.reverse
            (List.perm_middle (l₁ := x :: xs) (l₂ := ys) (a := y)).symm
          exact perm.trans (by simpa [List.append_assoc] using moved)

theorem sort_permutation {cmp : Term → Term → KernelM Ordering}
    {fuel : Nat} {xs out : List Term} {j r : List Term}
    (h : sortM.sort cmp fuel xs j = .ok (out, r)) : out.Perm xs := by
  induction fuel generalizing xs out j r with
  | zero =>
    have eq := pure_ok h
    rw [eq]
  | succ fuel ih =>
    unfold sortM.sort at h
    split at h
    · have eq := pure_ok h
      rw [eq]
    · obtain ⟨left, _, sortedLeft, h⟩ := bind_ok h
      obtain ⟨right, _, sortedRight, h⟩ := bind_ok h
      have merged := merge_permutation h
      simp only [List.reverse_nil, List.nil_append] at merged
      have parts := List.Perm.append (ih sortedLeft) (ih sortedRight)
      change (left ++ right).Perm ((xs.splitAt (xs.length / 2)).1 ++ (xs.splitAt (xs.length / 2)).2) at parts
      exact merged.trans (by simpa using parts)

theorem sortM_permutation {cmp : Term → Term → KernelM Ordering}
    {xs out : List Term} {j r : List Term}
    (h : sortM cmp xs j = .ok (out, r)) : out.Perm xs := sort_permutation h

theorem mapM_filterMap_identity {α β : Type} {f : α → KernelM β} {projection : β → Option α}
    (correct : ∀ x value j r, f x j = .ok (value, r) → projection value = some x)
    {xs : List α} {ys : List β} {j r : List Term}
    (h : xs.mapM f j = .ok (ys, r)) : ys.filterMap projection = xs := by
  induction xs generalizing ys j r with
  | nil =>
    have eq := pure_ok h
    subst ys
    rfl
  | cons x xs ih =>
    rw [List.mapM_cons] at h
    obtain ⟨value, _, first, h⟩ := bind_ok h
    obtain ⟨tail, _, rest, h⟩ := bind_ok h
    have eq := pure_ok h
    subst ys
    simp [correct x value _ _ first, ih rest]

/-- Sorting by an observed key preserves every input value, including its complete payload. -/
theorem sortBy_permutation {f : Term → KernelM Term} {descending : Bool}
    {xs out : List Term} {j r : List Term}
    (h : sortBy xs f descending j = .ok (out, r)) : out.Perm xs := by
  unfold sortBy at h
  obtain ⟨keyed, _, keyedRead, h⟩ := bind_ok h
  obtain ⟨ordered, _, sorted, h⟩ := bind_ok h
  let projection : Term → Option Term := fun x => match x with
    | .tuple [_, value] => some value
    | _ => none
  have keys : keyed.filterMap projection = xs := by
    apply mapM_filterMap_identity (f := fun x => do return Term.tuple [← f x, x]) _ keyedRead
    intro x value j r hx
    obtain ⟨key, _, _, hx⟩ := bind_ok hx
    have eq := pure_ok hx
    subst value
    rfl
  have perm := (sortM_permutation sorted).filterMap projection
  rw [keys] at perm
  have eq := pure_ok h
  rw [eq]
  exact perm

def CanonicalQueueItem (item : Term) : Prop :=
  ∃ fields, item = .map fields ∧ fields.all (fun pair => pair.1.isBinary) = true ∧
    0 < queueId item

theorem canonical_item_map {item : Term} (canonical : CanonicalQueueItem item) : item.isMap = true := by
  obtain ⟨fields, rfl, _⟩ := canonical
  rfl

theorem canonical_item_stringify {item : Term} (canonical : CanonicalQueueItem item) :
    shallowStringify item = pure item := by
  obtain ⟨fields, rfl, binary, _⟩ := canonical
  funext j
  simp only [shallowStringify, entries, bind, StateT.bind, Pure.pure, StateT.pure,
    Except.pure, Except.bind, binary, ↓reduceIte]

theorem mapM_identity {f : Term → KernelM Term} {xs ys : List Term} {j r : List Term}
    (correct : ∀ x ∈ xs, f x = pure x)
    (h : xs.mapM f j = .ok (ys, r)) : ys = xs := by
  induction xs generalizing ys j r with
  | nil => exact pure_ok h
  | cons x xs ih =>
    rw [List.mapM_cons] at h
    obtain ⟨value, _, first, h⟩ := bind_ok h
    rw [correct x (by simp)] at first
    have eq := pure_ok first
    subst value
    obtain ⟨tail, _, rest, h⟩ := bind_ok h
    rw [pure_ok h, ih (fun x hx => correct x (by simp [hx])) rest]

/-- Normalization only permutes canonical items. It cannot drop or change their payloads. -/
theorem normalizeQueue_permutation {xs out : List Term} {j r : List Term}
    (canonical : ∀ item ∈ xs, CanonicalQueueItem item)
    (h : normalizeQueue (list xs) j = .ok (out, r)) : out.Perm xs := by
  simp only [normalizeQueue, list] at h
  have maps : xs.filter Term.isMap = xs := List.filter_eq_self.mpr
    (fun item member => canonical_item_map (canonical item member))
  rw [maps] at h
  obtain ⟨normalized, _, normalizedRead, h⟩ := bind_ok h
  have normalizedValue := mapM_identity
    (fun item member => canonical_item_stringify (canonical item member)) normalizedRead
  subst normalized
  obtain ⟨positive, _, filtered, h⟩ := bind_ok h
  have positiveValue : positive = xs.filter (fun item => decide (0 < queueId item)) := by
    apply filterM_exact _ filtered
    intro item value j r test
    obtain ⟨id, _, read, test⟩ := bind_ok test
    rw [queueItemId_value read] at test
    exact pure_ok test
  have allPositive : xs.filter (fun item => decide (0 < queueId item)) = xs := by
    apply List.filter_eq_self.mpr
    intro item member
    obtain ⟨_, _, _, positive⟩ := canonical item member
    simpa using positive
  rw [allPositive] at positiveValue
  subst positive
  exact sortBy_permutation h

/-- The consume removal characterization applies to the original queue, not only a normalized copy. -/
theorem queueConsume_members {s e t : Term} {items : List Term} {n : Int} {j r : List Term}
    (read : s.get (a "input_queue") = list items)
    (canonical : ∀ item ∈ items, CanonicalQueueItem item)
    (id : e.get (b "queue_id") = i n)
    (h : queueConsume s e j = .ok (t, r)) :
    ∃ kept, t.get (a "input_queue") = list kept ∧
      ∀ item, item ∈ kept ↔ item ∈ items ∧ queueId item ≠ n := by
  obtain ⟨raw, normalized, _, _, normalize, rawValue, next⟩ := queueConsume_exact id h
  rw [rawValue, read] at normalize
  have perm := normalizeQueue_permutation canonical normalize
  refine ⟨_, next, ?_⟩
  intro item
  simp only [List.mem_filter, decide_eq_true_eq, perm.mem_iff]

/-- ACK removal cannot silently drop another canonical queue item during normalization. -/
theorem queueAck_members {s e t : Term} {items : List Term} {previous requested : Int}
    {j r : List Term}
    (read : s.get (a "input_queue") = list items)
    (canonical : ∀ item ∈ items, CanonicalQueueItem item)
    (baseline : s.get (a "queue_ack_id") = i previous)
    (request : e.get (b "queue_ack_id") = i requested)
    (h : queueAck s e j = .ok (t, r)) :
    ∃ kept, t.get (a "input_queue") = list kept ∧
      ∀ item, item ∈ kept ↔ item ∈ items ∧ max previous requested < queueId item := by
  obtain ⟨raw, normalized, _, _, normalize, rawValue, next⟩ := queueAck_exact baseline request h
  rw [rawValue, read] at normalize
  have perm := normalizeQueue_permutation canonical normalize
  refine ⟨_, next, ?_⟩
  intro item
  simp only [List.mem_filter, decide_eq_true_eq, perm.mem_iff]

theorem unackedItems_members {s : Term} {items out : List Term} {ack : Int} {j r : List Term}
    (read : s.get (a "input_queue") = list items)
    (baseline : s.get (a "queue_ack_id") = i ack)
    (h : StateQuery.unackedItems s j = .ok (out, r)) :
    ∀ item, item ∈ out ↔ item ∈ items ∧ ack < queueId item := by
  unfold StateQuery.unackedItems at h
  obtain ⟨value, _, valueRead, h⟩ := bind_ok h
  have valueEq : value = i ack := by
    simp only [field, fetch_ok_iff] at valueRead
    exact valueRead.2.2.1.trans baseline
  subst value
  obtain ⟨raw, _, rawRead, h⟩ := bind_ok h
  have rawEq : raw = list items := by
    simp only [field, fetch_ok_iff] at rawRead
    exact rawRead.2.2.1.trans read
  subst raw
  obtain ⟨kept, _, filtered, h⟩ := bind_ok h
  have keptValue : kept = items.filter (fun item => decide (ack < queueId item)) :=
    filterM_exact (fun _ _ _ _ hx => ack_predicate hx) filtered
  have perm := sortBy_permutation h
  intro item
  rw [perm.mem_iff, keptValue]
  simp

end VerifiedKernel.Session.WorkConservation
