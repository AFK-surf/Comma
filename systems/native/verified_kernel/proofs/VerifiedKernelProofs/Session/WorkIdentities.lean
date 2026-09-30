import VerifiedKernelProofs.Session.WorkInput
import Std.Data.HashSet.Lemmas

namespace VerifiedKernel.Session.WorkConservation
open Data

local instance : LawfulBEq ByteArray where
  eq_of_beq := by
    intro left right same
    exact ByteArray.ext (eq_of_beq same)
  rfl := by
    intro value
    change (value.data == value.data) = true
    exact beq_self_eq_true _

def binaryIdentityStep (state : Std.HashSet ByteArray × List Term) (value : Term) :
    Std.HashSet ByteArray × List Term :=
  match value with
  | .binary raw => if state.1.contains raw then state else (state.1.insert raw, value :: state.2)
  | _ => state

theorem uniq_binary_fold (items : List Term) (binary : items.all Term.isBinary = true) :
    uniq items = (items.foldl binaryIdentityStep (∅, [])).2.reverse := by
  let loop : Term → (Std.HashSet ByteArray × List Term) → Id (ForInStep (Std.HashSet ByteArray × List Term)) :=
    fun value state =>
      match value with
      | .binary raw =>
        if !state.1.contains raw then pure (.yield (state.1.insert raw, value :: state.2))
        else pure (.yield state)
      | _ => pure (.yield state)
  have same : loop = fun value state => pure (.yield (binaryIdentityStep state value)) := by
    funext value state
    cases value with
    | binary raw =>
      cases present : state.1.contains raw <;>
        simp only [loop, binaryIdentityStep, present, Bool.not_false, Bool.not_true,
          Bool.false_eq_true, ↓reduceIte]
    | _ => rfl
  unfold uniq
  rw [if_pos binary]
  change ((do
    let result ← forIn items (∅, []) loop
    pure result.2.reverse) : Id (List Term)).run = _
  rw [same, List.forIn_pure_yield_eq_foldl]
  rfl

def BinaryIdentityState (state : Std.HashSet ByteArray × List Term) : Prop :=
  state.2.Nodup ∧ ∀ raw, Term.binary raw ∈ state.2 ↔ state.1.contains raw = true

theorem binaryIdentityStep_state {state : Std.HashSet ByteArray × List Term} (value : Term)
    (before : BinaryIdentityState state) : BinaryIdentityState (binaryIdentityStep state value) := by
  cases value with
  | binary raw =>
    dsimp only [binaryIdentityStep]
    split
    · exact before
    · rename_i missing
      refine ⟨List.nodup_cons.mpr ⟨fun member => missing ((before.2 raw).mp member), before.1⟩, ?_⟩
      intro other
      simp only [List.mem_cons, Term.binary.injEq, Std.HashSet.contains_insert, Bool.or_eq_true,
        beq_iff_eq, ← before.2]
      simp only [eq_comm]
  | _ => exact before

theorem binaryIdentityFold_state (items : List Term) {state : Std.HashSet ByteArray × List Term}
    (before : BinaryIdentityState state) : BinaryIdentityState (items.foldl binaryIdentityStep state) := by
  induction items generalizing state with
  | nil => exact before
  | cons value items ih => exact ih (binaryIdentityStep_state value before)

theorem binaryIdentityStep_items (state : Std.HashSet ByteArray × List Term) (value : Term) :
    (binaryIdentityStep state value).2 = state.2 ∨
      (binaryIdentityStep state value).2 = value :: state.2 := by
  cases value <;> try exact Or.inl rfl
  dsimp only [binaryIdentityStep]
  split
  · exact Or.inl rfl
  · exact Or.inr rfl

theorem binaryIdentityFold_sublist (items : List Term) (state : Std.HashSet ByteArray × List Term) :
    (items.foldl binaryIdentityStep state).2.reverse.Sublist (state.2.reverse ++ items) := by
  induction items generalizing state with
  | nil => simp
  | cons value items ih =>
    rw [List.foldl_cons]
    have rest := ih (binaryIdentityStep state value)
    rcases binaryIdentityStep_items state value with same | added
    · rw [same] at rest
      exact rest.trans ((List.Sublist.cons value (List.Sublist.refl items)).append_left state.2.reverse)
    · simpa only [added, List.reverse_cons, List.append_assoc, List.singleton_append] using rest

theorem binary_term_beq {left right : Term} (leftBinary : left.isBinary = true)
    (rightBinary : right.isBinary = true) (same : (left == right) = true) : left = right := by
  cases left <;> cases right <;> simp only [Term.isBinary, Bool.false_eq_true] at leftBinary rightBinary
  rename_i left right
  change (left.data == right.data) = true at same
  exact congrArg Term.binary (ByteArray.ext (eq_of_beq same))

theorem binary_nodup_distinct {items : List Term} (binary : items.all Term.isBinary = true)
    (unique : items.Nodup) : items.Pairwise (fun left right => (left == right) = false) := by
  induction items with
  | nil => exact .nil
  | cons head tail ih =>
    simp only [List.all_cons, Bool.and_eq_true] at binary
    obtain ⟨missing, unique⟩ := List.nodup_cons.mp unique
    refine List.pairwise_cons.mpr ⟨?_, ih binary.2 unique⟩
    intro item member
    apply Bool.eq_false_iff.mpr
    intro same
    have equal := binary_term_beq binary.1 (List.all_eq_true.mp binary.2 item member) same
    exact missing (equal ▸ member)

def fallbackIdentityStep (seen : List Term) (value : Term) : List Term :=
  if seen.any (· == value) then seen else seen ++ [value]

theorem fallbackIdentityFold_length (items seen : List Term) :
    (items.foldl fallbackIdentityStep seen).length ≤ seen.length + items.length := by
  induction items generalizing seen with
  | nil => simp
  | cons value items ih =>
    rw [List.foldl_cons]
    have bound := ih (fallbackIdentityStep seen value)
    by_cases hit : seen.any (· == value) = true
    · have same : fallbackIdentityStep seen value = seen := by simp only [fallbackIdentityStep, hit, ↓reduceIte]
      rw [same] at bound ⊢
      simp only [List.length_cons]
      omega
    · have same : fallbackIdentityStep seen value = seen ++ [value] := by simp only [fallbackIdentityStep, hit, Bool.false_eq_true, ↓reduceIte]
      rw [same] at bound ⊢
      simp only [List.length_append, List.length_cons, List.length_nil] at bound ⊢
      omega

theorem fallbackIdentityFold_distinct {items seen : List Term}
    (before : seen.Pairwise (fun left right => (left == right) = false))
    (size : (items.foldl fallbackIdentityStep seen).length = seen.length + items.length) :
    (seen ++ items).Pairwise (fun left right => (left == right) = false) := by
  induction items generalizing seen with
  | nil => simpa using before
  | cons value items ih =>
    rw [List.foldl_cons] at size
    by_cases hit : seen.any (· == value) = true
    · have same : fallbackIdentityStep seen value = seen := by simp only [fallbackIdentityStep, hit, ↓reduceIte]
      rw [same] at size
      have bound := fallbackIdentityFold_length items seen
      simp only [List.length_cons] at size
      omega
    · have same : fallbackIdentityStep seen value = seen ++ [value] := by simp only [fallbackIdentityStep, hit, Bool.false_eq_true, ↓reduceIte]
      rw [same] at size
      have fresh : ∀ item ∈ seen, (item == value) = false :=
        fun item member => Bool.eq_false_iff.mpr (List.any_eq_false.mp (Bool.eq_false_iff.mpr hit) item member)
      have extended : (seen ++ [value]).Pairwise (fun left right => (left == right) = false) := by
        apply List.pairwise_append.mpr
        refine ⟨before, by simp, ?_⟩
        intro item member other singleton
        have same : other = value := by simpa using singleton
        subst other
        exact fresh item member
      have equalSize : (items.foldl fallbackIdentityStep (seen ++ [value])).length =
          (seen ++ [value]).length + items.length := by simpa only [List.length_cons, List.length_append, List.length_nil,
            List.length_singleton, Nat.add_assoc, Nat.add_comm, Nat.add_left_comm] using size
      simpa only [List.append_assoc, List.singleton_append] using ih extended equalSize

/-- The actual length guard rejects every earlier-to-later identity collision under the runtime equality test. -/
theorem uniq_length_distinct {items : List Term} (size : (uniq items).length = items.length) :
    items.Pairwise (fun left right => (left == right) = false) := by
  by_cases binary : items.all Term.isBinary = true
  · have initial : BinaryIdentityState (∅, []) := ⟨by simp, by simp [Std.HashSet.contains_empty]⟩
    have final := binaryIdentityFold_state items initial
    have sublist := binaryIdentityFold_sublist items (∅, [])
    simp only [List.reverse_nil, List.nil_append] at sublist
    rw [uniq_binary_fold items binary] at size
    have same := sublist.eq_of_length size
    apply binary_nodup_distinct binary
    rw [← same]
    exact (List.reverse_perm _).nodup_iff.mpr final.1
  · unfold uniq at size
    rw [if_neg binary] at size
    change (items.foldl fallbackIdentityStep []).length = items.length at size
    exact fallbackIdentityFold_distinct (items := items) (seen := []) (by simp)
      (by simpa only [List.length_nil, Nat.zero_add] using size)

theorem inputIdentitiesDistinct_sound {events : List Term} {j r : List Term}
    (h : Command.inputIdentitiesDistinct events j = .ok (true, r)) :
    ∃ groups before, events.mapM Command.inputIdentityGroups j = .ok (groups, before) ∧
      groups.flatten.flatten.Pairwise (fun left right => (left == right) = false) := by
  unfold Command.inputIdentitiesDistinct at h
  obtain ⟨groups, before, read, h⟩ := bind_ok h
  have checked := pure_ok h
  exact ⟨groups, before, read, uniq_length_distinct (eq_of_beq checked.symm)⟩

theorem beq_binary_right {value : Term} {raw : ByteArray}
    (same : (value == Term.binary raw) = true) : value = Term.binary raw := by
  cases value with
  | binary bytes =>
    change (bytes.data == raw.data) = true at same
    exact congrArg Term.binary (ByteArray.ext (eq_of_beq same))
  | _ => exact Bool.noConfusion same

theorem binaryIdentityStep_contains (state : Std.HashSet ByteArray × List Term) (value : Term) (target : ByteArray) :
    (binaryIdentityStep state value).1.contains target = true ↔
      state.1.contains target = true ∨ value = .binary target := by
  cases value with
  | binary raw =>
    dsimp only [binaryIdentityStep]
    by_cases hit : state.1.contains raw = true
    · rw [if_pos hit]
      constructor
      · exact Or.inl
      · rintro (old | same)
        · exact old
        · have same := Term.binary.inj same
          subst target
          exact hit
    · rw [if_neg hit]
      simp only [Std.HashSet.contains_insert, Bool.or_eq_true, beq_iff_eq, Term.binary.injEq]
      exact or_comm
  | _ => simp only [binaryIdentityStep, reduceCtorEq, or_false]

theorem binaryIdentityFold_contains (items : List Term) (state : Std.HashSet ByteArray × List Term) (target : ByteArray) :
    (items.foldl binaryIdentityStep state).1.contains target = true ↔
      state.1.contains target = true ∨ Term.binary target ∈ items := by
  induction items generalizing state with
  | nil => simp
  | cons value items ih =>
    rw [List.foldl_cons, ih, binaryIdentityStep_contains]
    simp only [List.mem_cons, eq_comm, or_assoc]

theorem fallbackIdentityStep_binary_member (seen : List Term) (value : Term) (target : ByteArray) :
    Term.binary target ∈ fallbackIdentityStep seen value ↔ Term.binary target ∈ seen ∨ Term.binary target = value := by
  unfold fallbackIdentityStep
  split
  · rename_i hit
    constructor
    · exact Or.inl
    · rintro (old | same)
      · exact old
      · subst value
        obtain ⟨previous, member, same⟩ := List.any_eq_true.mp hit
        have same := beq_binary_right same
        subst previous
        exact member
  · simp only [List.mem_append, List.mem_singleton]

theorem fallbackIdentityFold_binary_member (items seen : List Term) (target : ByteArray) :
    Term.binary target ∈ items.foldl fallbackIdentityStep seen ↔
      Term.binary target ∈ seen ∨ Term.binary target ∈ items := by
  induction items generalizing seen with
  | nil => simp
  | cons value items ih =>
    rw [List.foldl_cons, ih, fallbackIdentityStep_binary_member]
    simp only [List.mem_cons, or_assoc]

/-- Alias deduplication cannot hide a binary source identity from batch admission. -/
theorem uniq_binary_member (items : List Term) (target : ByteArray) :
    Term.binary target ∈ uniq items ↔ Term.binary target ∈ items := by
  by_cases binary : items.all Term.isBinary = true
  · rw [uniq_binary_fold items binary, List.mem_reverse]
    have initial : BinaryIdentityState (∅, []) := ⟨by simp, by simp [Std.HashSet.contains_empty]⟩
    rw [(binaryIdentityFold_state items initial).2 target, binaryIdentityFold_contains]
    simp
  · unfold uniq
    rw [if_neg binary]
    change Term.binary target ∈ items.foldl fallbackIdentityStep [] ↔ _
    rw [fallbackIdentityFold_binary_member]
    simp

theorem uniq_avoids_binary {items : List Term} {target : ByteArray}
    (different : ∀ value ∈ uniq items, (value == Term.binary target) = false) :
    ∀ value ∈ items, (value == Term.binary target) = false := by
  intro value member
  apply Bool.eq_false_iff.mpr
  intro same
  have equal := beq_binary_right same
  subst value
  have absent := different _ ((uniq_binary_member items target).mpr member)
  rw [same] at absent
  exact Bool.noConfusion absent

end VerifiedKernel.Session.WorkConservation
