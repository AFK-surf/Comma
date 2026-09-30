import VerifiedKernelProofs.Order

namespace VerifiedKernel.Term
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem fold_max_seed (values : List Nat) (seed : Nat) : seed ≤ values.foldl max seed := by
  induction values generalizing seed with
  | nil => exact Nat.le_refl _
  | cons value values ih => exact Nat.le_trans (Nat.le_max_left _ _) (ih _)

theorem fold_max_member {values : List Nat} {value : Nat} (seed : Nat)
    (member : value ∈ values) : value ≤ values.foldl max seed := by
  induction values generalizing seed with
  | nil => contradiction
  | cons head values ih =>
    rcases List.mem_cons.mp member with rfl | tail
    · exact Nat.le_trans (Nat.le_max_right _ _) (fold_max_seed values _)
    · exact ih _ tail

theorem depth_positive (value : Term) : 0 < value.depth := by
  cases value <;> simp only [depth] <;> omega

theorem list_depth_member {values : List Term} {value : Term} (member : value ∈ values) :
    value.depth ≤ (values.map depth).foldl max 0 :=
  fold_max_member 0 (List.mem_map.mpr ⟨value, member, rfl⟩)

theorem map_depth_member {values : List (Term × Term)} {value : Term × Term}
    (member : value ∈ values) :
    max value.1.depth value.2.depth ≤
      (values.map (fun pair => max pair.1.depth pair.2.depth)).foldl max 0 :=
  fold_max_member 0 (List.mem_map.mpr ⟨value, member, rfl⟩)

theorem zip_fuel_change {oldFuel newFuel : Nat} {left right : List Term}
    (change : ∀ x y, x.depth ≤ newFuel → exactFuel oldFuel x y = true → exactFuel newFuel x y = true)
    (bound : (left.map depth).foldl max 0 ≤ newFuel)
    (old : (left.zip right).all (fun pair => exactFuel oldFuel pair.1 pair.2) = true) :
    (left.zip right).all (fun pair => exactFuel newFuel pair.1 pair.2) = true := by
  apply List.all_eq_true.mpr
  intro pair member
  exact change _ _ (Nat.le_trans (list_depth_member (List.of_mem_zip member).1) bound)
    (List.all_eq_true.mp old pair member)

theorem map_fuel_change {oldFuel newFuel : Nat} {left right : List (Term × Term)}
    (change : ∀ x y, x.depth ≤ newFuel → exactFuel oldFuel x y = true → exactFuel newFuel x y = true)
    (bound : (left.map (fun pair => max pair.1.depth pair.2.depth)).foldl max 0 ≤ newFuel)
    (old : left.all (fun pair => right.any (fun other =>
      exactFuel oldFuel pair.1 other.1 && exactFuel oldFuel pair.2 other.2)) = true) :
    left.all (fun pair => right.any (fun other =>
      exactFuel newFuel pair.1 other.1 && exactFuel newFuel pair.2 other.2)) = true := by
  apply List.all_eq_true.mpr
  intro pair member
  obtain ⟨other, included, hit⟩ := List.any_eq_true.mp (List.all_eq_true.mp old pair member)
  have pairBound := Nat.le_trans (map_depth_member member) bound
  obtain ⟨key, value⟩ := Bool.and_eq_true_iff.mp hit
  exact List.any_eq_true.mpr ⟨other, included, Bool.and_eq_true_iff.mpr
    ⟨change _ _ (by omega) key, change _ _ (by omega) value⟩⟩

theorem exactFuel_change {oldFuel newFuel : Nat} {left right : Term}
    (bound : left.depth ≤ newFuel) (old : exactFuel oldFuel left right = true) :
    exactFuel newFuel left right = true := by
  induction oldFuel generalizing newFuel left right with
  | zero => contradiction
  | succ oldFuel ih =>
    cases newFuel with
    | zero => have positive := depth_positive left; omega
    | succ newFuel =>
      cases left <;> cases right <;>
        simp only [exactFuel, Bool.false_eq_true] at old ⊢
      all_goals simp only [depth] at bound
      all_goals try simp only [Bool.and_eq_true] at old ⊢
      all_goals first
        | exact old
        | exact ⟨old.1, zip_fuel_change (fun _ _ => ih) (by omega) old.2⟩
        | exact ⟨old.1, map_fuel_change (fun _ _ => ih) (by omega) old.2⟩
        | exact ⟨⟨old.1.1, ih (by omega) old.1.2⟩,
            zip_fuel_change (fun _ _ => ih) (by omega) old.2⟩

theorem zip_all_trans {left middle right : List Term} {relation : Term → Term → Bool}
    (transitive : ∀ x y z, relation x y = true → relation y z = true → relation x z = true)
    (firstLength : left.length = middle.length) (secondLength : middle.length = right.length)
    (first : (left.zip middle).all (fun pair => relation pair.1 pair.2) = true)
    (second : (middle.zip right).all (fun pair => relation pair.1 pair.2) = true) :
    (left.zip right).all (fun pair => relation pair.1 pair.2) = true := by
  induction left generalizing middle right with
  | nil => simp
  | cons x xs ih =>
    cases middle with
    | nil => simp at firstLength
    | cons y ys =>
      cases right with
      | nil => simp at secondLength
      | cons z zs =>
        simp only [List.length_cons, Nat.add_right_cancel_iff] at firstLength secondLength
        simp only [List.zip_cons_cons, List.all_cons, Bool.and_eq_true] at first second ⊢
        exact ⟨transitive x y z first.1 second.1,
          ih firstLength secondLength first.2 second.2⟩

theorem map_all_trans {left middle right : List (Term × Term)} {relation : Term → Term → Bool}
    (transitive : ∀ x y z, relation x y = true → relation y z = true → relation x z = true)
    (first : left.all (fun pair => middle.any (fun other =>
      relation pair.1 other.1 && relation pair.2 other.2)) = true)
    (second : middle.all (fun pair => right.any (fun other =>
      relation pair.1 other.1 && relation pair.2 other.2)) = true) :
    left.all (fun pair => right.any (fun other =>
      relation pair.1 other.1 && relation pair.2 other.2)) = true := by
  apply List.all_eq_true.mpr
  intro pair member
  obtain ⟨other, included, firstHit⟩ :=
    List.any_eq_true.mp (List.all_eq_true.mp first pair member)
  obtain ⟨last, present, secondHit⟩ :=
    List.any_eq_true.mp (List.all_eq_true.mp second other included)
  obtain ⟨firstKeys, firstValues⟩ := Bool.and_eq_true_iff.mp firstHit
  obtain ⟨secondKeys, secondValues⟩ := Bool.and_eq_true_iff.mp secondHit
  exact List.any_eq_true.mpr ⟨last, present, Bool.and_eq_true_iff.mpr
    ⟨transitive _ _ _ firstKeys secondKeys, transitive _ _ _ firstValues secondValues⟩⟩

theorem byte_beq_trans {left middle right : ByteArray}
    (first : (left == middle) = true) (second : (middle == right) = true) :
    (left == right) = true := by
  change (left.data == middle.data) = true at first
  change (middle.data == right.data) = true at second
  change (left.data == right.data) = true
  exact beq_iff_eq.mpr ((eq_of_beq first).trans (eq_of_beq second))

theorem exactFuel_trans {fuel : Nat} {left middle right : Term}
    (first : exactFuel fuel left middle = true)
    (second : exactFuel fuel middle right = true) : exactFuel fuel left right = true := by
  induction fuel generalizing left middle right with
  | zero => contradiction
  | succ fuel ih =>
    cases left <;> cases middle <;>
      simp only [exactFuel, Bool.false_eq_true] at first
    all_goals cases right <;> simp only [exactFuel, Bool.false_eq_true] at second ⊢
    all_goals try simp only [Bool.and_eq_true, beq_iff_eq] at first second ⊢
    all_goals first
      | exact first.trans second
      | exact ⟨first.1.trans second.1,
          zip_all_trans (fun _ _ _ => ih) first.1 second.1 first.2 second.2⟩
      | exact ⟨first.1.trans second.1, map_all_trans (fun _ _ _ => ih) first.2 second.2⟩
      | exact ⟨⟨first.1.1.trans second.1.1, ih first.1.2 second.1.2⟩,
          zip_all_trans (fun _ _ _ => ih) first.1.1 second.1.1 first.2 second.2⟩
      | exact byte_beq_trans first second
      | exact ⟨byte_beq_trans first.1 second.1, first.2.trans second.2⟩

theorem exactFuel_of_beq {left right : Term} (same : (left == right) = true) :
    exactFuel (max left.depth right.depth) left right = true := by
  cases left <;> cases right
  all_goals first
    | contradiction
    | exact same
    | exact (Bool.and_eq_true_iff.mp same).2
    | simpa only [depth, Nat.max_self, exactFuel, BEq.beq] using same

theorem beq_of_exactFuel {fuel : Nat} {left right : Term}
    (same : exactFuel fuel left right = true) : (left == right) = true := by
  have aligned := exactFuel_change (Nat.le_max_left left.depth right.depth) same
  cases left <;> cases right
  all_goals first
    | exact aligned
    | simpa only [depth, Nat.max_self, exactFuel, BEq.beq] using aligned
    | (apply Bool.and_eq_true_iff.mpr
       refine ⟨?_, aligned⟩
       cases fuel with
       | zero => contradiction
       | succ fuel => exact (Bool.and_eq_true_iff.mp same).1)
    | (cases fuel <;> simp [exactFuel] at same)

theorem beq_trans {left middle right : Term}
    (first : (left == middle) = true) (second : (middle == right) = true) :
    (left == right) = true := by
  let common := max left.depth middle.depth
  have firstExact : exactFuel common left middle = true := exactFuel_of_beq first
  have secondExact : exactFuel common middle right = true :=
    exactFuel_change (Nat.le_max_right _ _) (exactFuel_of_beq second)
  exact beq_of_exactFuel (exactFuel_trans firstExact secondExact)

theorem has_of_beq {value left right : Term}
    (same : (left == right) = true) (present : value.has left = true) : value.has right = true := by
  cases value with
  | map fields =>
    obtain ⟨pair, member, hit⟩ := List.any_eq_true.mp present
    exact List.any_eq_true.mpr ⟨pair, member, beq_trans hit same⟩
  | _ => contradiction

end VerifiedKernel.Term
