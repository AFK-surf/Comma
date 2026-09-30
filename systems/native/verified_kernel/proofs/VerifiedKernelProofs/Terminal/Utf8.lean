import VerifiedKernelProofs.Terminal.Ascii

/-!
# Complete UTF-8 sequences

`feed` decodes a complete, valid UTF-8 sequence straight from the input.
`utf8_run` shows that the byte-wise decoder prints the same code point.
-/

namespace VerifiedKernel.Terminal

/-- `t` with a UTF-8 sequence in progress. -/
abbrev inUtf8 (t : State) (cp : UInt32) (need seen : Nat) : State :=
  { t with utf8Cp := cp, utf8Need := need, utf8Seen := seen }

theorem reset_utf8 (t : State) (hcp : t.utf8Cp = 0) (hneed : t.utf8Need = 0)
    (hseen : t.utf8Seen = 0) (cp : UInt32) (need seen : Nat) :
    ({ inUtf8 t cp need seen with utf8Cp := 0, utf8Need := 0, utf8Seen := 0 } : State) = t := by
  cases t; simp_all

/-- The continuation bytes of a sequence that needs `seen + k` of them. -/
theorem run_continuation (t : State) (hcp : t.utf8Cp = 0) (hneed : t.utf8Need = 0)
    (hseen : t.utf8Seen = 0) (bytes : ByteArray) (need : Nat) (k seen j : Nat) (cp : UInt32)
    (hk : seen + (k + 1) = need)
    (hc : continuation bytes cp j (k + 1) ≠ 0xFFFFFFFF)
    (hv : validCodePoint (continuation bytes cp j (k + 1)) (need + 1) = true) :
    run (inUtf8 t cp need seen) bytes j (k + 1) =
      printCodePoint t (continuation bytes cp j (k + 1)) := by
  induction k generalizing seen j cp with
  | zero =>
    rw [continuation] at hc hv ⊢
    by_cases hb : (bytes[j]! &&& 0xC0 == 0x80) = true
    · simp only [hb, if_true, continuation] at hc hv ⊢
      rw [run, run]
      unfold step
      rw [if_neg (by simp; omega), if_pos hb]
      dsimp only
      rw [if_neg (by omega), reset_utf8 t hcp hneed hseen]
      simp only [hv, if_true]
    · simp only [hb, Bool.false_eq_true, if_false] at hc
      exact absurd rfl hc
  | succ k ih =>
    rw [continuation] at hc hv ⊢
    by_cases hb : (bytes[j]! &&& 0xC0 == 0x80) = true
    · simp only [hb, if_true] at hc hv ⊢
      rw [run]
      unfold step
      rw [if_neg (by simp; omega), if_pos hb]
      dsimp only
      rw [if_pos (by omega)]
      exact ih (seen + 1) (j + 1) _ (by omega) hc hv
    · simp only [hb, Bool.false_eq_true, if_false] at hc
      exact absurd rfl hc

theorem step_lead (t : State) (hneed : t.utf8Need = 0) (hparser : t.parser = .ground)
    (c : UInt8) (hc : 0xC2 ≤ c.toNat) (lead : UInt32) (need : Nat)
    (hg : groundByte t c = inUtf8 t lead need 0) :
    step t c = inUtf8 t lead need 0 := by
  have n18 : (c == 0x18) = false := by
    simp only [beq_eq_false_iff_ne, ne_eq, ← UInt8.toNat_inj, UInt8.reduceToNat]; omega
  have n1a : (c == 0x1A) = false := by
    simp only [beq_eq_false_iff_ne, ne_eq, ← UInt8.toNat_inj, UInt8.reduceToNat]; omega
  have n1b : (c == 0x1B) = false := by
    simp only [beq_eq_false_iff_ne, ne_eq, ← UInt8.toNat_inj, UInt8.reduceToNat]; omega
  unfold step
  rw [if_pos (by simp [hneed])]
  unfold nonUtf8Byte
  simp only [n18, n1a, n1b, Bool.false_or, Bool.false_and, Bool.false_eq_true, if_false, hparser]
  exact hg

theorem groundByte_lead (t : State) (c : UInt8) (hc : 0xC2 ≤ c.toNat) :
    groundByte t c =
      if 0xC2 ≤ c && c ≤ 0xDF then inUtf8 t (c &&& 0x1F).toUInt32 1 0
      else if 0xE0 ≤ c && c ≤ 0xEF then inUtf8 t (c &&& 0x0F).toUInt32 2 0
      else if 0xF0 ≤ c && c ≤ 0xF4 then inUtf8 t (c &&& 0x07).toUInt32 3 0
      else print t replacement := by
  have n20 : ¬(c < 0x20) := by simp only [UInt8.lt_iff_toNat_lt, UInt8.reduceToNat]; omega
  have n7f : ¬(c < 0x7F) := by simp only [UInt8.lt_iff_toNat_lt, UInt8.reduceToNat]; omega
  have e7f : (c == 0x7F) = false := by
    simp only [beq_eq_false_iff_ne, ne_eq, ← UInt8.toNat_inj, UInt8.reduceToNat]; omega
  unfold groundByte
  simp only [n20, n7f, e7f, if_false, Bool.false_eq_true]

theorem unpack (cp : UInt32) (len : Nat) (hl : len < 256) :
    (((cp.toUInt64 <<< 8) ||| len.toUInt64) >>> 8).toUInt32 = cp ∧
      (((cp.toUInt64 <<< 8) ||| len.toUInt64) &&& 0xFF).toNat = len := by
  have hcp := cp.toNat_lt
  have hv : ((cp.toUInt64 <<< 8) ||| len.toUInt64).toNat = cp.toNat * 256 + len := by
    rw [UInt64.toNat_or, UInt64.toNat_shiftLeft, UInt32.toNat_toUInt64,
      UInt64.toNat_ofNat_of_lt' (by omega : len < 2 ^ 64)]
    have e1 : (8 : UInt64).toNat % 64 = 8 := rfl
    rw [e1, Nat.shiftLeft_eq, Nat.mod_eq_of_lt (by omega : cp.toNat * 2 ^ 8 < 2 ^ 64),
      ← Nat.shiftLeft_eq,
      ← Nat.shiftLeft_add_eq_or_of_lt (by omega : len < 2 ^ 8), Nat.shiftLeft_eq]
  constructor
  · apply UInt32.toNat_inj.mp
    rw [UInt64.toNat_toUInt32, UInt64.toNat_shiftRight, hv]
    have e1 : (8 : UInt64).toNat % 64 = 8 := rfl
    rw [e1, Nat.shiftRight_eq_div_pow]
    omega
  · rw [UInt64.toNat_and, hv]
    have e1 : (0xFF : UInt64).toNat = 2 ^ 8 - 1 := rfl
    rw [e1, Nat.and_two_pow_sub_one_eq_mod]
    omega

/-- The fast path for one decoded sequence, given its length and lead bits. -/
theorem utf8_case (t : State) (hcp : t.utf8Cp = 0) (hneed : t.utf8Need = 0)
    (hseen : t.utf8Seen = 0) (bytes : ByteArray) (i need : Nat) (lead : UInt32)
    (hn : need ≠ 0) (hn4 : need < 4) (hstep : step t bytes[i]! = inUtf8 t lead need 0)
    (hd : (if (need == 0 || decide (i + need ≥ bytes.size)) = true then (0 : UInt64) else
      if (continuation bytes lead (i + 1) need != 0xFFFFFFFF &&
          validCodePoint (continuation bytes lead (i + 1) need) (need + 1)) = true then
        ((continuation bytes lead (i + 1) need).toUInt64 <<< 8) ||| (need + 1).toUInt64
      else 0) ≠ 0) :
    run t bytes i (((if (need == 0 || decide (i + need ≥ bytes.size)) = true then (0 : UInt64) else
      if (continuation bytes lead (i + 1) need != 0xFFFFFFFF &&
          validCodePoint (continuation bytes lead (i + 1) need) (need + 1)) = true then
        ((continuation bytes lead (i + 1) need).toUInt64 <<< 8) ||| (need + 1).toUInt64
      else 0) &&& 0xFF).toNat) =
      printCodePoint t ((if (need == 0 || decide (i + need ≥ bytes.size)) = true then (0 : UInt64) else
      if (continuation bytes lead (i + 1) need != 0xFFFFFFFF &&
          validCodePoint (continuation bytes lead (i + 1) need) (need + 1)) = true then
        ((continuation bytes lead (i + 1) need).toUInt64 <<< 8) ||| (need + 1).toUInt64
      else 0) >>> 8).toUInt32 := by
  split at hd
  · exact absurd rfl hd
  rename_i h1
  rw [if_neg h1]
  split at hd
  · rename_i h2
    rw [if_pos h2]
    simp only [Bool.and_eq_true, bne_iff_ne, ne_eq] at h2
    have ⟨u1, u2⟩ := unpack (continuation bytes lead (i + 1) need) (need + 1) (by omega)
    rw [u1, u2]
    obtain ⟨k, hk⟩ : ∃ k, need = k + 1 := ⟨need - 1, by omega⟩
    subst hk
    rw [run, hstep]
    exact run_continuation t hcp hneed hseen bytes (k + 1) k 0 (i + 1) lead (by omega) h2.1 h2.2
  · exact absurd rfl hd

/-- The UTF-8 fast path: a complete, valid sequence found by `scanUtf8` prints
the code point the byte-wise decoder prints. -/
theorem utf8_run (t : State) (hcp : t.utf8Cp = 0) (hneed : t.utf8Need = 0)
    (hseen : t.utf8Seen = 0) (hparser : t.parser = .ground) (bytes : ByteArray) (i : Nat)
    (hc2 : 0xC2 ≤ bytes[i]!.toNat) (hd : scanUtf8 bytes i ≠ 0) :
    run t bytes i (scanUtf8 bytes i &&& 0xFF).toNat =
      printCodePoint t (scanUtf8 bytes i >>> 8).toUInt32 := by
  have hstep := fun lead need hg => step_lead t hneed hparser bytes[i]! hc2 lead need hg
  have hg := groundByte_lead t bytes[i]! hc2
  unfold scanUtf8 at hd ⊢
  dsimp only at hd ⊢
  generalize hci : bytes[i]! = c at hd hg hstep ⊢
  by_cases r1 : (0xC2 ≤ c && c ≤ 0xDF) = true
  · simp only [r1, if_true] at hd hg ⊢
    simp only [Nat.reduceBEq, Bool.false_eq_true, if_true, if_false] at hd ⊢
    exact utf8_case t hcp hneed hseen bytes i 1 _ (by omega) (by omega) (by rw [hci]; exact hstep _ _ hg) hd
  simp only [r1, Bool.false_eq_true, if_false] at hd hg ⊢
  by_cases r2 : (0xE0 ≤ c && c ≤ 0xEF) = true
  · simp only [r2, if_true] at hd hg ⊢
    simp only [Nat.reduceBEq, Bool.false_eq_true, if_true, if_false] at hd ⊢
    exact utf8_case t hcp hneed hseen bytes i 2 _ (by omega) (by omega) (by rw [hci]; exact hstep _ _ hg) hd
  simp only [r2, Bool.false_eq_true, if_false] at hd hg ⊢
  by_cases r3 : (0xF0 ≤ c && c ≤ 0xF4) = true
  · simp only [r3, if_true] at hd hg ⊢
    simp only [Nat.reduceBEq, Bool.false_eq_true, if_false] at hd ⊢
    exact utf8_case t hcp hneed hseen bytes i 3 _ (by omega) (by omega) (by rw [hci]; exact hstep _ _ hg) hd
  simp only [r3, Bool.false_eq_true, if_false] at hd
  exact absurd rfl hd

end VerifiedKernel.Terminal
