import VerifiedKernelProofs.Provider.TermRefl
import VerifiedKernelProofs.Provider.ProjectionStateless

/-!
The hash-map keys of the chat projection form an equivalence with a compatible hash.
-/

namespace VerifiedKernel.Provider.Messages

instance : EquivBEq CallKey where
  rfl := by
    intro x
    show (x.value == x.value && x.value == x.value) = true
    rw [Term.beq_self]; rfl
  symm := by
    intro x y h
    change (x.value == y.value && y.value == x.value) = true at h
    show (y.value == x.value && x.value == y.value) = true
    rw [Bool.and_comm]; exact h
  trans := by
    intro x y z h₁ h₂
    change (x.value == y.value && y.value == x.value) = true at h₁
    change (y.value == z.value && z.value == y.value) = true at h₂
    show (x.value == z.value && z.value == x.value) = true
    simp only [Bool.and_eq_true] at h₁ h₂ ⊢
    exact ⟨Term.beq_trans h₁.1 h₂.1, Term.beq_trans h₂.2 h₁.2⟩

instance : LawfulHashable CallKey where
  hash_eq := by
    intro x y h
    change (x.value == y.value && y.value == x.value) = true at h
    simp only [Bool.and_eq_true] at h
    obtain ⟨x⟩ := x
    obtain ⟨y⟩ := y
    simp only at h
    show hash (CallKey.mk x) = hash (CallKey.mk y)
    simp only [hash]
    cases x <;> cases y <;> first
      | rfl
      | (have e : _ = _ := eq_of_beq (α := ByteArray) h.1
         rw [e])
      | (exfalso; simp [BEq.beq] at h; done)

end VerifiedKernel.Provider.Messages
