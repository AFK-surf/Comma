import VerifiedKernelProofs.Session.WorkNormalization
import VerifiedKernelProofs.Session.WorkEncoding

namespace VerifiedKernel.Session.WorkConservation
open Data

def KeyOrdered (key : Term → Int) (xs : List Term) : Prop :=
  xs.Pairwise (fun x y => key x ≤ key y)

theorem merge_key_ordered {key : Term → Int} {valid : Term → Prop} {cmp : Term → Term → KernelM Ordering}
    (correct : ∀ x y value j r, valid x → valid y → cmp x y j = .ok (value, r) →
      (value != .gt) = true → key x ≤ key y)
    (reverse : ∀ x y value j r, valid x → valid y → cmp x y j = .ok (value, r) →
      (value != .gt) = false → key y ≤ key x)
    {fuel : Nat} {xs ys acc out : List Term} {j r : List Term}
    (left : KeyOrdered key xs) (right : KeyOrdered key ys)
    (initial : KeyOrdered key acc.reverse)
    (before : ∀ a ∈ acc, ∀ b ∈ xs ++ ys, key a ≤ key b)
    (values : ∀ x ∈ xs ++ ys, valid x)
    (h : sortM.merge cmp fuel xs ys acc j = .ok (out, r)) : KeyOrdered key out := by
  induction fuel generalizing xs ys acc j with
  | zero =>
    cases xs <;> cases ys
    all_goals first
      | (solve | simp only [sortM.merge, fail_ok_iff] at h)
      | (rw [pure_ok h]; apply List.pairwise_append.mpr
         exact ⟨initial, by assumption, fun a ha b hb => before a (by simpa using ha) b (by simpa using hb)⟩)
  | succ fuel ih =>
    cases xs with
    | nil =>
      rw [pure_ok h]
      exact List.pairwise_append.mpr
        ⟨initial, right, fun a ha b hb => before a (by simpa using ha) b (by simpa using hb)⟩
    | cons x xs =>
      cases ys with
      | nil =>
        rw [pure_ok h]
        exact List.pairwise_append.mpr
          ⟨initial, left, fun a ha b hb => before a (by simpa using ha) b (by simpa using hb)⟩
      | cons y ys =>
        unfold sortM.merge at h
        obtain ⟨order, _, compared, h⟩ := bind_ok h
        split at h
        · rename_i choose
          have xy := correct x y order _ _ (values x (by simp)) (values y (by simp)) compared choose
          apply ih (List.pairwise_cons.mp left).2 right _ _ _ h
          · simp only [List.reverse_cons]
            apply List.pairwise_append.mpr
            exact ⟨initial, by simp, fun a ha b hb => by
              have same : b = x := by simpa using hb
              subst b
              exact before a (by simpa using ha) x (by simp)⟩
          · intro a ha b hb
            rcases List.mem_cons.mp ha with rfl | old
            · rcases List.mem_append.mp hb with bx | bys
              · exact (List.pairwise_cons.mp left).1 b bx
              · rcases List.mem_cons.mp bys with rfl | bys
                · exact xy
                · exact Int.le_trans xy ((List.pairwise_cons.mp right).1 b bys)
            · exact before a old b (by
                simp only [List.mem_append, List.mem_cons] at hb ⊢
                rcases hb with hx | hy
                · exact Or.inl (Or.inr hx)
                · exact Or.inr hy)
          · intro value member
            exact values value (List.mem_append.mpr (by
              rcases List.mem_append.mp member with hx | hy
              · exact Or.inl (List.mem_cons_of_mem _ hx)
              · exact Or.inr hy))
        · rename_i choose
          have yx := reverse x y order _ _ (values x (by simp)) (values y (by simp)) compared (Bool.eq_false_iff.mpr choose)
          apply ih left (List.pairwise_cons.mp right).2 _ _ _ h
          · simp only [List.reverse_cons]
            apply List.pairwise_append.mpr
            exact ⟨initial, by simp, fun a ha b hb => by
              have same : b = y := by simpa using hb
              subst b
              exact before a (by simpa using ha) y (by simp)⟩
          · intro a ha b hb
            rcases List.mem_cons.mp ha with rfl | old
            · rcases List.mem_append.mp hb with bxs | bys
              · rcases List.mem_cons.mp bxs with rfl | bxs
                · exact yx
                · exact Int.le_trans yx ((List.pairwise_cons.mp left).1 b bxs)
              · exact (List.pairwise_cons.mp right).1 b bys
            · exact before a old b (by
                simp only [List.mem_append, List.mem_cons] at hb ⊢
                rcases hb with hx | hy
                · exact Or.inl hx
                · exact Or.inr (Or.inr hy))
          · intro value member
            exact values value (List.mem_append.mpr (by
              rcases List.mem_append.mp member with hx | hy
              · exact Or.inl hx
              · exact Or.inr (List.mem_cons_of_mem _ hy)))

theorem sort_key_ordered {key : Term → Int} {valid : Term → Prop} {cmp : Term → Term → KernelM Ordering}
    (correct : ∀ x y value j r, valid x → valid y → cmp x y j = .ok (value, r) →
      (value != .gt) = true → key x ≤ key y)
    (reverse : ∀ x y value j r, valid x → valid y → cmp x y j = .ok (value, r) →
      (value != .gt) = false → key y ≤ key x)
    {fuel : Nat} {xs out : List Term} {j r : List Term}
    (enough : xs.length < fuel)
    (values : ∀ x ∈ xs, valid x)
    (h : sortM.sort cmp fuel xs j = .ok (out, r)) : KeyOrdered key out := by
  induction fuel generalizing xs out j r with
  | zero => omega
  | succ fuel ih =>
    unfold sortM.sort at h
    split at h
    · rename_i short
      rw [pure_ok h]
      cases xs with
      | nil => exact List.Pairwise.nil
      | cons x xs =>
        have empty : xs = [] := by
          cases xs with
          | nil => rfl
          | cons y ys => simp only [List.length_cons] at short; omega
        subst xs
        simp [KeyOrdered]
    · rename_i long
      obtain ⟨left, _, first, h⟩ := bind_ok h
      obtain ⟨right, _, second, h⟩ := bind_ok h
      have leftValues : ∀ x ∈ (xs.splitAt (xs.length / 2)).1, valid x :=
        fun x member => values x (List.mem_of_mem_take (by simpa using member))
      have rightValues : ∀ x ∈ (xs.splitAt (xs.length / 2)).2, valid x :=
        fun x member => values x (List.mem_of_mem_drop (by simpa using member))
      apply merge_key_ordered correct reverse (ih _ leftValues first) (ih _ rightValues second)
        (by simp [KeyOrdered]) (by simp) _ h
      · change (xs.splitAt (xs.length / 2)).1.length < fuel
        simp only [List.splitAt_eq, List.length_take]
        omega
      · change (xs.splitAt (xs.length / 2)).2.length < fuel
        simp only [List.splitAt_eq, List.length_drop]
        omega
      · intro x member
        rcases List.mem_append.mp member with hl | hr
        · exact leftValues x ((sort_permutation first).mem_iff.mp hl)
        · exact rightValues x ((sort_permutation second).mem_iff.mp hr)

theorem sortM_key_ordered {key : Term → Int} {valid : Term → Prop} {cmp : Term → Term → KernelM Ordering}
    (correct : ∀ x y value j r, valid x → valid y → cmp x y j = .ok (value, r) →
      (value != .gt) = true → key x ≤ key y)
    (reverse : ∀ x y value j r, valid x → valid y → cmp x y j = .ok (value, r) →
      (value != .gt) = false → key y ≤ key x)
    {xs out : List Term} {j r : List Term}
    (values : ∀ x ∈ xs, valid x)
    (h : sortM cmp xs j = .ok (out, r)) : KeyOrdered key out :=
  sort_key_ordered correct reverse (by omega) values h

def taggedKey : Term → Int
  | .tuple [.integer n, _] => n
  | _ => 0

theorem sortBy_key_ordered {key : Term → Int} {f : Term → KernelM Term}
    (correct : ∀ x value j r, f x j = .ok (value, r) → value = i (key x))
    {xs out : List Term} {j r : List Term}
    (h : sortBy xs f false j = .ok (out, r)) : KeyOrdered key out := by
  unfold sortBy at h
  obtain ⟨keyed, _, keyedRead, h⟩ := bind_ok h
  have keyedValue := mapM_exact (g := fun x => Term.tuple [i (key x), x])
    (fun x value j r read => by
      obtain ⟨field, _, fieldRead, read⟩ := bind_ok read
      rw [correct x field _ _ fieldRead] at read
      exact pure_ok read) keyedRead
  subst keyed
  obtain ⟨sorted, _, sortedRead, h⟩ := bind_ok h
  let valid := fun tag => ∃ x, tag = Term.tuple [i (key x), x]
  have values : ∀ tag ∈ xs.map (fun x => Term.tuple [i (key x), x]), valid tag := by
    intro tag member
    obtain ⟨x, _, rfl⟩ := List.mem_map.mp member
    exact ⟨x, rfl⟩
  have ordered : KeyOrdered taggedKey sorted := by
    apply sortM_key_ordered (valid := valid) _ _ values sortedRead
    all_goals
      intro x y value j r vx vy read branch
      obtain ⟨x, rfl⟩ := vx
      obtain ⟨y, rfl⟩ := vy
      simp only [Bool.false_eq_true, ↓reduceIte, i, order_integer] at read
      have result := (Prod.mk.inj (Except.ok.inj read)).1
      subst value
      simp only [taggedKey]
      cases cmp : compare (key x) (key y) with
      | lt => have less := Int.compare_eq_lt.mp cmp; simp [cmp] at branch <;> omega
      | eq => have same := Int.compare_eq_eq.mp cmp; omega
      | gt => have more := Int.compare_eq_gt.mp cmp; simp [cmp] at branch <;> omega
  have sortedValues : ∀ tag ∈ sorted, valid tag :=
    fun tag member => values tag ((sortM_permutation sortedRead).mem_iff.mp member)
  rw [pure_ok h]
  apply List.pairwise_filterMap.mpr
  apply List.Pairwise.imp_of_mem _ ordered
  intro a b ha hb relation x hx y hy
  obtain ⟨a, rfl⟩ := sortedValues a ha
  obtain ⟨b, rfl⟩ := sortedValues b hb
  have ax : a = x := Option.some.inj hx
  have by' : b = y := Option.some.inj hy
  subst x
  subst y
  exact relation

theorem queue_sort_ordered {items out : List Term} {j r : List Term}
    (h : sortBy items queueItemId false j = .ok (out, r)) :
    KeyOrdered queueId out := sortBy_key_ordered (fun _ _ _ _ read => queueItemId_value read) h

/-- The executable pending-queue query supplies order. Only identity uniqueness remains an invariant. -/
theorem unackedItems_ordered {s : Term} {items out : List Term} {ack : Int} {j r : List Term}
    (read : s.get (a "input_queue") = list items)
    (baseline : s.get (a "queue_ack_id") = i ack)
    (unique : (items.map queueId).Nodup)
    (h : StateQuery.unackedItems s j = .ok (out, r)) : Ordered out := by
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
  have diff : items.Pairwise (fun x y => queueId x ≠ queueId y) :=
    List.pairwise_map.mp unique
  have keptDiff : (kept.map queueId).Nodup := by
    rw [keptValue]
    exact List.pairwise_map.mpr (diff.filter _)
  have outDiff : out.Pairwise (fun x y => queueId x ≠ queueId y) :=
    List.pairwise_map.mp (((sortBy_permutation h).map queueId).nodup_iff.mpr keptDiff)
  have ordered := queue_sort_ordered h
  exact (ordered.and outDiff).imp (fun pair => by omega)

end VerifiedKernel.Session.WorkConservation
