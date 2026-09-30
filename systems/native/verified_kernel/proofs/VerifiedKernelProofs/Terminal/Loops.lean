import VerifiedKernel.Terminal

/-!
# Machine-word loops

The byte scans and row copies of the fast paths run over `USize` indices whose
bounds are proved. This module shows that each loop equals its `Nat` form,
which the other proofs use.
-/

namespace VerifiedKernel.Terminal

theorem uget_eq (bytes : ByteArray) (i : USize) (h : i.toNat < bytes.size) :
    bytes.uget i h = bytes[i.toNat]! := by
  simp [ByteArray.uget, getElem!_pos bytes i.toNat h]; rfl

theorem scanWhile_go_spec (p : UInt8 → Bool) (bytes : ByteArray) (j n : Nat) :
    j ≤ scanWhile.go p bytes j n ∧ scanWhile.go p bytes j n ≤ j + n ∧
      ∀ k, j ≤ k → k < scanWhile.go p bytes j n → p bytes[k]! = true := by
  induction n generalizing j with
  | zero => simp only [scanWhile.go]; exact ⟨Nat.le_refl _, by omega, fun k a b => by omega⟩
  | succ n ih =>
    rw [scanWhile.go]
    split
    · rename_i h
      have ⟨a, b, c⟩ := ih (j + 1)
      refine ⟨by omega, by omega, fun k h1 h2 => ?_⟩
      by_cases e : k = j
      · subst e; exact h
      · exact c k (by omega) h2
    · exact ⟨Nat.le_refl _, by omega, fun k a b => by omega⟩

theorem scanWhileU_eq (p : UInt8 → Bool) (bytes : ByteArray) (e : USize) (he : e.toNat ≤ bytes.size)
    (d : Nat) : ∀ j : USize, e.toNat - j.toNat = d → j.toNat ≤ e.toNat →
      (scanWhileU p bytes e he j).toNat = scanWhile.go p bytes j.toNat d := by
  induction d with
  | zero =>
    intro j hd hj
    rw [scanWhileU, dif_neg (by rw [USize.lt_iff_toNat_lt]; omega)]
    rfl
  | succ d ih =>
    intro j hd hj
    have hlt : j < e := by rw [USize.lt_iff_toNat_lt]; omega
    have hs := usize_succ_toNat j e hlt
    rw [scanWhileU, dif_pos hlt, scanWhile.go, uget_eq]
    split
    · rw [ih (j + 1) (by omega) (by omega), hs]
    · rfl

theorem scanWhile_eq (p : UInt8 → Bool) (bytes : ByteArray) (i : Nat) :
    scanWhile p bytes i = scanWhile.go p bytes i (bytes.size - i) := by
  unfold scanWhile
  split
  · rename_i h
    have hi : i.toUSize.toNat = i := toNat_toUSize_of_lt (by omega)
    have he : bytes.size.toUSize.toNat = bytes.size := toNat_toUSize_of_lt h.1
    rw [scanWhileU_eq p bytes _ _ (bytes.size - i) _ (by rw [hi, he]) (by rw [hi, he]; exact h.2), hi]
  · rfl

/-! ### Positions and sizes

The state stores positions and sizes as `UInt32`. Their values stay far below
2^32, so these lemmas move arithmetic on them to `Nat`. -/

theorem toNat_umin (a b : UInt32) : (min a b).toNat = min a.toNat b.toNat := by
  show (if a ≤ b then a else b).toNat = _
  split <;> rename_i h <;> simp only [UInt32.le_iff_toNat_le] at h <;> omega

theorem toNat_toUInt32 {n : Nat} (h : n < 2 ^ 32) : n.toUInt32.toNat = n := by
  rw [Nat.toUInt32_eq, UInt32.toNat_ofNat_of_lt' h]

theorem toUInt32_toNat (a : UInt32) : a.toNat.toUInt32 = a := by
  rw [Nat.toUInt32_eq, UInt32.ofNat_toNat]

theorem toNat_usub {a b : UInt32} (h : b.toNat ≤ a.toNat) : (a - b).toNat = a.toNat - b.toNat := by
  rw [UInt32.toNat_sub]; have := a.toNat_lt; have := b.toNat_lt; omega

theorem toNat_uadd {a b : UInt32} (h : a.toNat + b.toNat < 2 ^ 32) : (a + b).toNat = a.toNat + b.toNat := by
  rw [UInt32.toNat_add]; exact Nat.mod_eq_of_lt h

/-- The clamped column `min x (cols - 1)`. -/
theorem toNat_clamp (x c : UInt32) (hc : 0 < c) :
    (min x (c - 1)).toNat = min x.toNat (c.toNat - 1) := by
  have : 0 < c.toNat := hc
  rw [toNat_umin, toNat_usub (by simp; omega), UInt32.toNat_one]

/-- A word equals the word of its value. -/
theorem uint32_eq_toUInt32 {a : UInt32} {n : Nat} (h : a.toNat = n) : a = n.toUInt32 := by
  rw [← h, toUInt32_toNat]

end VerifiedKernel.Terminal
