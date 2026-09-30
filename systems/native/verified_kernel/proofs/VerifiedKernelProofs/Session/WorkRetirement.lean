import VerifiedKernelProofs.Session.WorkConservation
import VerifiedKernelProofs.Session.WorkFrames

namespace VerifiedKernel.Session.WorkConservation
open Data

theorem maximum_integer (x y : Int) (j : List Term) :
    maximum (i x) (i y) j = .ok (i (max x y), j) := by
  simp only [maximum, atMost, bind, StateT.bind, Except.bind, i, order_integer,
    Pure.pure, StateT.pure, Except.pure]
  cases cmp : compare x y with
  | lt =>
    have le := Int.le_of_lt (Int.compare_eq_lt.mp cmp)
    simp [Int.max_eq_right le, StateT.pure, Pure.pure, Except.pure]
  | eq =>
    have eq : x = y := Int.compare_eq_eq.mp cmp
    subst y
    simp [StateT.pure, Pure.pure, Except.pure]
  | gt =>
    have le := Int.le_of_lt (Int.compare_eq_gt.mp cmp)
    simp [Int.max_eq_left le, StateT.pure, Pure.pure, Except.pure]

theorem filterAuxM_exact {p : Term → KernelM Bool} {predicate : Term → Bool}
    (correct : ∀ x value j r, p x j = .ok (value, r) → value = predicate x)
    {xs acc ys : List Term} {j r : List Term}
    (h : List.filterAuxM p xs acc j = .ok (ys, r)) :
    ys = (xs.filter predicate).reverse ++ acc := by
  induction xs generalizing acc j with
  | nil => simpa using pure_ok h
  | cons x xs ih =>
    unfold List.filterAuxM at h
    obtain ⟨value, _, tested, h⟩ := bind_ok h
    have eq := correct x value _ _ tested
    subst value
    have result := ih h
    cases test : predicate x <;> simpa [List.filter_cons, test, List.append_assoc] using result

theorem filterM_exact {p : Term → KernelM Bool} {predicate : Term → Bool}
    (correct : ∀ x value j r, p x j = .ok (value, r) → value = predicate x)
    {xs ys : List Term} {j r : List Term}
    (h : xs.filterM p j = .ok (ys, r)) : ys = xs.filter predicate := by
  unfold List.filterM at h
  obtain ⟨rev, _, filtered, h⟩ := bind_ok h
  have eq := pure_ok h
  rw [eq, filterAuxM_exact correct filtered]
  simp

theorem queueItemId_value {item id : Term} {j r : List Term}
    (h : queueItemId item j = .ok (id, r)) : id = i (queueId item) := by
  unfold queueItemId at h
  obtain ⟨binary, _, hb, h⟩ := bind_ok h
  obtain ⟨atom, _, ha, h⟩ := bind_ok h
  rw [(access_ok hb).1, (access_ok ha).1] at h
  exact pure_ok h

theorem consume_predicate {item : Term} {n : Int} {value : Bool} {j r : List Term}
    (h : (do return !(← queueItemId item).numericEq (i n)) j = .ok (value, r)) :
    value = decide (queueId item ≠ n) := by
  obtain ⟨id, _, read, h⟩ := bind_ok h
  rw [queueItemId_value read] at h
  have result := pure_ok h
  by_cases eq : queueId item = n
  · simpa [Term.numericEq, Term.numericEqFuel, Term.depth, Term.number, i, eq] using result
  · have ne : (queueId item == n) = false := by
      cases test : queueId item == n
      · rfl
      · exact False.elim (eq (eq_of_beq test))
    simpa [Term.numericEq, Term.numericEqFuel, Term.depth, Term.number, i, eq, ne] using result

theorem ack_predicate {item : Term} {n : Int} {value : Bool} {j r : List Term}
    (h : (do greater (← queueItemId item) (i n)) j = .ok (value, r)) :
    value = decide (n < queueId item) := by
  obtain ⟨id, _, read, h⟩ := bind_ok h
  rw [queueItemId_value read, greater_integer] at h
  exact (Prod.mk.inj (Except.ok.inj h)).1.symm

/-- The actual consume reducer removes exactly the requested ID from its normalized queue. -/
theorem queueConsume_exact {s e t : Term} {n : Int} {j r : List Term}
    (id : e.get (b "queue_id") = i n)
    (h : queueConsume s e j = .ok (t, r)) :
    ∃ raw items j₁ j₂, normalizeQueue raw j₁ = .ok (items, j₂) ∧
      raw = s.get (a "input_queue") ∧
      t.get (a "input_queue") = list (items.filter (fun item => decide (queueId item ≠ n))) := by
  unfold queueConsume at h
  obtain ⟨consumed, _, readId, h⟩ := bind_ok h
  have consumedId : consumed = i n := by
    cases e <;> simp only [get?, fail_ok_iff] at readId
    exact (pure_ok readId).trans id
  subst consumed
  obtain ⟨raw, _, read, h⟩ := bind_ok h
  have rawValue : raw = s.get (a "input_queue") := by
    simp only [field, fetch_ok_iff] at read
    exact read.2.2.1
  obtain ⟨items, j₂, normalized, h⟩ := bind_ok h
  obtain ⟨kept, _, filtered, h⟩ := bind_ok h
  have keptValue := filterM_exact (fun _ _ _ _ hx => consume_predicate hx) filtered
  obtain ⟨written, _, updated, pruned⟩ := bind_ok h
  refine ⟨raw, items, _, j₂, normalized, rawValue, ?_⟩
  obtain ⟨_, updated⟩ := write_cons updated
  have eq := pure_ok updated
  subst written
  rw [pruneResultRefs_queue pruned, get_put_same, keptValue]

/-- The actual ACK reducer removes exactly the prefix below its monotone ACK watermark. -/
theorem queueAck_exact {s e t : Term} {previous requested : Int} {j r : List Term}
    (baseline : s.get (a "queue_ack_id") = i previous)
    (request : e.get (b "queue_ack_id") = i requested)
    (h : queueAck s e j = .ok (t, r)) :
    ∃ raw items j₁ j₂, normalizeQueue raw j₁ = .ok (items, j₂) ∧
      raw = s.get (a "input_queue") ∧
      t.get (a "input_queue") =
        list (items.filter (fun item => decide (max previous requested < queueId item))) := by
  unfold queueAck at h
  obtain ⟨old, _, oldRead, h⟩ := bind_ok h
  have oldValue : old = i previous := by
    simp only [field, fetch_ok_iff] at oldRead
    exact oldRead.2.2.1.trans baseline
  subst old
  obtain ⟨value, _, valueRead, h⟩ := bind_ok h
  have valueEq := (access_ok valueRead).1.trans request
  subst value
  simp only [Term.default, Term.truthy, i, ↓reduceIte] at h
  obtain ⟨ack, _, maxRead, h⟩ := bind_ok h
  rw [maximum_integer] at maxRead
  have ackValue := (Prod.mk.inj (Except.ok.inj maxRead)).1.symm
  subst ack
  obtain ⟨raw, _, read, h⟩ := bind_ok h
  have rawValue : raw = s.get (a "input_queue") := by
    simp only [field, fetch_ok_iff] at read
    exact read.2.2.1
  obtain ⟨items, j₂, normalized, h⟩ := bind_ok h
  obtain ⟨kept, _, filtered, h⟩ := bind_ok h
  have keptValue := filterM_exact (fun _ _ _ _ hx => ack_predicate hx) filtered
  obtain ⟨written, _, updated, pruned⟩ := bind_ok h
  refine ⟨raw, items, _, j₂, normalized, rawValue, ?_⟩
  obtain ⟨_, updated⟩ := write_cons updated
  obtain ⟨_, updated⟩ := write_cons updated
  have eq := pure_ok updated
  subst written
  rw [pruneResultRefs_queue pruned, get_put_same, keptValue]

end VerifiedKernel.Session.WorkConservation
