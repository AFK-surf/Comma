import VerifiedKernelProofs.Proof.TermComparison
import VerifiedKernelProofs.Provider.Loop

/-!
`Term` equality is reflexive.
-/

namespace VerifiedKernel.Term

theorem mem_zip_self {α : Type} : ∀ {xs : List α} {a b : α}, (a, b) ∈ xs.zip xs → a = b ∧ a ∈ xs
  | [], _, _, h => by simp at h
  | x :: xs, a, b, h => by
    simp only [List.zip_cons_cons, List.mem_cons, Prod.mk.injEq] at h
    rcases h with ⟨rfl, rfl⟩ | h
    · exact ⟨rfl, List.mem_cons_self ..⟩
    · obtain ⟨e, m⟩ := mem_zip_self h
      exact ⟨e, List.mem_cons_of_mem _ m⟩

theorem exactFuel_self : ∀ (fuel : Nat) (x : Term), x.depth ≤ fuel → exactFuel fuel x x = true
  | 0, x, h => absurd h (by have := depth_positive x; omega)
  | fuel + 1, x, h => by
    cases x with
    | integer v => simp [exactFuel]
    | atom v => simp [exactFuel]
    | binary v => simp only [exactFuel]; exact beq_self_eq_true _
    | floatBits v => simp [exactFuel]
    | tuple xs | list xs =>
      simp only [exactFuel, beq_self_eq_true, Bool.true_and]
      apply List.all_eq_true.mpr
      intro p hp
      obtain ⟨a, b⟩ := p
      obtain ⟨rfl, mem⟩ := mem_zip_self hp
      apply exactFuel_self
      simp only [depth] at h
      have := list_depth_member mem
      show a.depth ≤ fuel
      omega
    | map xs =>
      simp only [exactFuel, beq_self_eq_true, Bool.true_and]
      apply List.all_eq_true.mpr
      intro p hp
      apply List.any_eq_true.mpr
      refine ⟨p, hp, ?_⟩
      simp only [depth] at h
      have := map_depth_member hp
      simp only [Bool.and_eq_true]
      exact ⟨exactFuel_self _ _ (by omega), exactFuel_self _ _ (by omega)⟩
    | improper xs tail =>
      simp only [exactFuel, beq_self_eq_true, Bool.true_and, Bool.and_eq_true]
      simp only [depth] at h
      refine ⟨exactFuel_self _ _ (by omega), ?_⟩
      apply List.all_eq_true.mpr
      intro p hp
      obtain ⟨a, b⟩ := p
      obtain ⟨rfl, mem⟩ := mem_zip_self hp
      apply exactFuel_self
      have := list_depth_member mem
      show a.depth ≤ fuel
      omega
    | bitstring v n => simp only [exactFuel, Bool.and_eq_true]; exact ⟨beq_self_eq_true _, beq_self_eq_true _⟩

theorem beq_self (x : Term) : (x == x) = true := by
  cases x with
  | integer v => exact beq_self_eq_true v
  | atom v => exact beq_self_eq_true v
  | binary v => exact beq_self_eq_true v
  | floatBits v => exact beq_self_eq_true v
  | tuple xs =>
    show (xs.length == xs.length && exactFuel (max (Term.tuple xs).depth (Term.tuple xs).depth) _ _) = true
    rw [Nat.max_self, beq_self_eq_true, Bool.true_and]; exact exactFuel_self _ _ (Nat.le_refl _)
  | list xs =>
    show (xs.length == xs.length && exactFuel (max (Term.list xs).depth (Term.list xs).depth) _ _) = true
    rw [Nat.max_self, beq_self_eq_true, Bool.true_and]; exact exactFuel_self _ _ (Nat.le_refl _)
  | map xs =>
    show (xs.length == xs.length && exactFuel (max (Term.map xs).depth (Term.map xs).depth) _ _) = true
    rw [Nat.max_self, beq_self_eq_true, Bool.true_and]; exact exactFuel_self _ _ (Nat.le_refl _)
  | improper xs t =>
    show exactFuel (max (Term.improper xs t).depth (Term.improper xs t).depth) _ _ = true
    rw [Nat.max_self]; exact exactFuel_self _ _ (Nat.le_refl _)
  | bitstring v n =>
    show (v == v && n == n) = true
    rw [beq_self_eq_true, beq_self_eq_true]; rfl

end VerifiedKernel.Term
