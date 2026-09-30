import VerifiedKernelProofs.Terminal.Loops

/-!
# Row operations

Each row operation is described cell by cell through `getElem?`, which also
fixes the row's length. `seqRun` is the row update of `putChar` applied one
character at a time; `seqRun_eq_batch` shows that it equals the single
update `writeAscii` makes for a row segment.
-/

namespace VerifiedKernel.Terminal

theorem getElem?_ensure_go (row : Row) (k m : Nat) :
    (ensure.go row k)[m]? =
      if m < row.size then row[m]? else if m < row.size + k then some blank else none := by
  induction k generalizing row with
  | zero =>
    rw [ensure.go]
    by_cases h1 : m < row.size
    · simp [h1]
    · simp only [h1, if_false, Nat.add_zero]; exact Array.getElem?_eq_none (by omega)
  | succ k ih =>
    rw [ensure.go, ih, show row.size + (k + 1) = row.size + 1 + k by omega]
    simp only [Array.size_push, Array.getElem?_push]
    by_cases h1 : m < row.size <;> by_cases h2 : m = row.size <;>
      by_cases h3 : m < row.size + 1 <;> by_cases h4 : m < row.size + 1 + k <;>
      simp only [h1, h2, h3, h4, if_true, if_false] <;> first | rfl | omega | (simp; omega)

theorem getElem?_ensure (row : Row) (n m : Nat) :
    (ensure row n)[m]? = if m < row.size then row[m]? else if m < n then some blank else none := by
  unfold ensure
  rw [getElem?_ensure_go]
  split
  · rfl
  · split <;> split <;> first | rfl | omega

theorem size_ensure_go (row : Row) (k : Nat) : (ensure.go row k).size = row.size + k := by
  induction k generalizing row with
  | zero => rfl
  | succ k ih => simp only [ensure.go, ih, Array.size_push]; omega

theorem size_ensure (row : Row) (n : Nat) : (ensure row n).size = max row.size n := by
  unfold ensure; rw [size_ensure_go]; omega

theorem ensure_of_le (row : Row) (n : Nat) (h : n ≤ row.size) : ensure row n = row := by
  unfold ensure; rw [Nat.sub_eq_zero_of_le h]; rfl

theorem getElem?_put (row : Row) (x : Nat) (c : Cell) (h : x ≤ row.size) (m : Nat) :
    (put row x c)[m]? = if m = x then some c else row[m]? := by
  unfold put
  split
  · rw [Array.set!_eq_setIfInBounds, Array.getElem?_setIfInBounds]
    by_cases hm : m = x
    · subst hm; simp [*]
    · simp [hm, Ne.symm hm]
  · rw [Array.getElem?_push]
    have : x = row.size := by omega
    subst this
    rfl

theorem size_put (row : Row) (x : Nat) (c : Cell) (h : x ≤ row.size) :
    (put row x c).size = max row.size (x + 1) := by
  unfold put
  split
  · simp [Array.set!_eq_setIfInBounds]; omega
  · simp; omega

theorem cellAt_eq (row : Row) (i : Nat) : cellAt row i = row[i]?.getD blank := by
  unfold cellAt
  split <;> simp_all


/-- `copyRun` and `copyGraphics` with the cell function made explicit. -/
def copyWith (row : Row) (bytes : ByteArray) (f : UInt8 → Cell) (x start : Nat) : Nat → Row
  | 0 => row
  | n + 1 => copyWith (put row x (f bytes[start]!)) bytes f (x + 1) (start + 1) n

theorem uset_eq_put (row : Row) (x : USize) (c : Cell) (h : x.toNat < row.size) :
    row.uset x c h = put row x.toNat c := by
  unfold put; rw [if_pos h]
  simp [Array.uset, Array.set!_eq_setIfInBounds, Array.setIfInBounds, h]

theorem appendWith_eq (f : UInt8 → Cell) (bytes : ByteArray) (stop : USize)
    (hs : stop.toNat ≤ bytes.size) (d : Nat) : ∀ (row : Row) (start : USize) (x : Nat),
      stop.toNat - start.toNat = d → start.toNat ≤ stop.toNat → row.size ≤ x →
      appendWith f row bytes stop hs start = copyWith row bytes f x start.toNat d := by
  induction d with
  | zero =>
    intro row start x hd _ _
    rw [appendWith, dif_neg (by rw [USize.lt_iff_toNat_lt]; omega)]; rfl
  | succ d ih =>
    intro row start x hd hle hx
    have hlt : start < stop := by rw [USize.lt_iff_toNat_lt]; omega
    have hsu := usize_succ_toNat start stop hlt
    rw [appendWith, dif_pos hlt, copyWith, uget_eq,
      ih _ _ (x + 1) (by omega) (by omega) (by simp; omega), hsu]
    congr 1
    unfold put; rw [if_neg (by omega)]

theorem overwriteWith_eq (f : UInt8 → Cell) (bytes : ByteArray) (stop : USize)
    (hs : stop.toNat ≤ bytes.size) (d : Nat) : ∀ (row : Row) (size : USize)
      (hsize : size.toNat = row.size) (x start : USize),
      stop.toNat - start.toNat = d → start.toNat ≤ stop.toNat →
      overwriteWith f row size hsize bytes stop hs x start = copyWith row bytes f x.toNat start.toNat d := by
  induction d with
  | zero =>
    intro row size hsize x start hd _
    rw [overwriteWith, dif_neg (by rw [USize.lt_iff_toNat_lt]; omega)]; rfl
  | succ d ih =>
    intro row size hsize x start hd hle
    have hlt : start < stop := by rw [USize.lt_iff_toNat_lt]; omega
    have hsu := usize_succ_toNat start stop hlt
    rw [overwriteWith, dif_pos hlt]
    split
    · rename_i hx
      have hxu := usize_succ_toNat x size hx
      have hx' : x.toNat < row.size := hsize ▸ hx
      rw [ih _ _ _ _ _ (by omega) (by omega), hxu, hsu, copyWith, uget_eq, uset_eq_put _ _ _ hx']
    · rename_i hx
      rw [USize.lt_iff_toNat_lt] at hx
      exact appendWith_eq f bytes stop hs (d + 1) row start x.toNat hd hle (by omega)

theorem copyWithU_go_eq (f : UInt8 → Cell) (row : Row) (bytes : ByteArray) (x start n : Nat) :
    copyWithU.go f bytes row x start n = copyWith row bytes f x start n := by
  induction n generalizing row x start with
  | zero => rfl
  | succ n ih => rw [copyWithU.go, copyWith, ih]

theorem copyWithU_eq (f : UInt8 → Cell) (row : Row) (bytes : ByteArray) (x start n : Nat) :
    copyWithU f row bytes x start n = copyWith row bytes f x start n := by
  unfold copyWithU
  split
  · rename_i h
    have hx : x.toUSize.toNat = x := toNat_toUSize_of_lt h.2.2.2
    have hst : start.toUSize.toNat = start := toNat_toUSize_of_lt (by omega)
    have hsp : (start + n).toUSize.toNat = start + n := toNat_toUSize_of_lt (by omega)
    rw [overwriteWith_eq f bytes _ _ n _ _ _ _ _ (by rw [hsp, hst]; omega) (by rw [hsp, hst]; omega), hx, hst]
  · exact copyWithU_go_eq f row bytes x start n

theorem copyRun_eq (row : Row) (bytes : ByteArray) (x start n : Nat) :
    copyRun row bytes x start n = copyWith row bytes (asciiCell false) x start n := by
  unfold copyRun; rw [copyWithU_eq]; rfl

theorem copyGraphics_eq (row : Row) (bytes : ByteArray) (x start n : Nat) :
    copyGraphics row bytes x start n = copyWith row bytes (asciiCell true) x start n := by
  unfold copyGraphics; rw [copyWithU_eq]; rfl

theorem copyCells_eq (row : Row) (bytes : ByteArray) (g : Bool) (x start n : Nat) :
    copyCells row bytes g x start n = copyWith row bytes (asciiCell g) x start n := by
  cases g
  · exact copyRun_eq row bytes x start n
  · exact copyGraphics_eq row bytes x start n

theorem getElem?_copyWith (row : Row) (bytes : ByteArray) (f : UInt8 → Cell) (x start n : Nat)
    (h : x ≤ row.size) (m : Nat) :
    (copyWith row bytes f x start n)[m]? =
      if x ≤ m ∧ m < x + n then some (f bytes[start + (m - x)]!) else row[m]? := by
  induction n generalizing row x start with
  | zero => simp [copyWith]; omega
  | succ n ih =>
    rw [copyWith, ih _ _ _ (by rw [size_put _ _ _ h]; omega), getElem?_put _ _ _ h]
    by_cases h1 : m = x
    · subst h1; simp; intro h; omega
    · by_cases h2 : x + 1 ≤ m ∧ m < x + 1 + n
      · rw [if_pos h2, if_pos (by omega)]
        congr 3; omega
      · rw [if_neg h2, if_neg h1, if_neg (by omega)]

theorem cellAt_eq_wide (row : Row) (i : Nat) :
    (i < row.size ∧ cellAt row i = wideCell) ↔ row[i]? = some wideCell := by
  unfold cellAt
  constructor
  · rintro ⟨h, e⟩; simp_all
  · intro e
    have : i < row.size := by
      rcases Nat.lt_or_ge i row.size with h | h
      · exact h
      · simp [Array.getElem?_eq_none h] at e
    simp_all

theorem blank_ne_wide : blank ≠ wideCell := by decide

theorem decGraphics_ne_wide (c : UInt32) (h : c.toNat < 256) : decGraphics c ≠ wideCell := by
  unfold decGraphics
  split
  all_goals first
    | decide
    | (intro e; have := congrArg UInt32.toNat e; simp [wideCell] at this; omega)

theorem asciiCell_ne_wide (g : Bool) (b : UInt8) : asciiCell g b ≠ wideCell := by
  have hb := b.toNat_lt
  cases g
  · intro h
    have := congrArg UInt32.toNat h
    simp [asciiCell, wideCell] at this
    omega
  · exact decGraphics_ne_wide _ (by simp; omega)

theorem getElem?_clearWideEdges (row : Row) (lo hi : Nat) (h : lo ≤ hi + 1) (m : Nat) :
    (clearWideEdges row lo hi)[m]? =
      if (0 < lo ∧ row[lo]? = some wideCell ∧ m + 1 = lo) ∨
          (row[hi + 1]? = some wideCell ∧ m = hi + 1) then some blank
      else row[m]? := by
  have lo_iff := cellAt_eq_wide row lo
  -- The right edge, given the row after the left edge was handled.
  have key : ∀ row1 : Row, row1.size = row.size →
      (∀ k, row1[k]? = if 0 < lo ∧ row[lo]? = some wideCell ∧ k + 1 = lo then some blank
        else row[k]?) →
      (if (decide (hi + 1 < row.size) && cellAt row1 (hi + 1) == wideCell) = true then
          row1.set! (hi + 1) blank else row1)[m]? =
        if (0 < lo ∧ row[lo]? = some wideCell ∧ m + 1 = lo) ∨
            (row[hi + 1]? = some wideCell ∧ m = hi + 1) then some blank
        else row[m]? := by
    intro row1 size1 r1
    have hi_eq : row1[hi + 1]? = row[hi + 1]? := by rw [r1]; rw [if_neg (by omega)]
    have hi_iff := cellAt_eq_wide row1 (hi + 1)
    rw [hi_eq, size1] at hi_iff
    by_cases c : row[hi + 1]? = some wideCell
    · have ⟨hs, hc⟩ := hi_iff.mpr c
      rw [if_pos (by simp [hs, hc]), Array.set!_eq_setIfInBounds, Array.getElem?_setIfInBounds]
      by_cases hm : m = hi + 1
      · subst hm
        have cw : row[hi + 1] = wideCell := by
          rw [Array.getElem?_eq_getElem hs] at c; exact Option.some.inj c
        simp [size1, hs, cw]
      · rw [if_neg (by omega), r1]
        by_cases d : 0 < lo ∧ row[lo]? = some wideCell ∧ m + 1 = lo
        · rw [if_pos d, if_pos (Or.inl d)]
        · rw [if_neg d, if_neg (by intro h'; rcases h' with h' | h'; exact d h'; exact hm h'.2)]
    · have n1 : ¬((decide (hi + 1 < row.size) && cellAt row1 (hi + 1) == wideCell) = true) := by
        simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq]
        intro ⟨a, b⟩
        exact c (hi_iff.mp ⟨a, b⟩)
      rw [if_neg n1, r1]
      by_cases d : 0 < lo ∧ row[lo]? = some wideCell ∧ m + 1 = lo
      · rw [if_pos d, if_pos (Or.inl d)]
      · rw [if_neg d, if_neg (by intro h'; rcases h' with h' | h'; exact d h'; exact c h'.1)]
  unfold clearWideEdges
  dsimp only
  by_cases c1 : (decide (lo > 0) && decide (lo < row.size) && cellAt row lo == wideCell) = true
  · rw [if_pos c1]
    simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at c1
    obtain ⟨⟨c0, cs⟩, cw⟩ := c1
    apply key _ (by simp [Array.set!_eq_setIfInBounds])
    intro k
    rw [Array.set!_eq_setIfInBounds, Array.getElem?_setIfInBounds]
    have w := lo_iff.mp ⟨cs, cw⟩
    by_cases hk : k + 1 = lo
    · simp [c0, w, hk, show lo - 1 = k by omega, show k < row.size by omega]
    · simp [hk, show lo - 1 ≠ k by omega]
  · rw [if_neg c1]
    apply key _ rfl
    intro k
    have n2 : ¬(0 < lo ∧ row[lo]? = some wideCell ∧ k + 1 = lo) := by
      intro ⟨a, b, _⟩
      have ⟨x1, x2⟩ := lo_iff.mpr b
      exact c1 (by simp [a, x1, x2])
    rw [if_neg n2]

theorem size_clearWideEdges (row : Row) (lo hi : Nat) :
    (clearWideEdges row lo hi).size = row.size := by
  unfold clearWideEdges; dsimp only
  split <;> split <;> simp_all [Array.set!_eq_setIfInBounds]


/-! ### One character at a time -/

/-- The row update of `putChar` for a narrow character in replace mode. -/
def cellOp (x : Nat) (c : Cell) (row : Row) : Row := put (clearWideEdges (ensure row x) x x) x c

/-- `n` narrow characters `bytes[i:i + n]` written from column `x`, one at a time. -/
def seqRun (row : Row) (bytes : ByteArray) (g : Bool) (x i : Nat) : Nat → Row
  | 0 => row
  | n + 1 => seqRun (cellOp x (asciiCell g bytes[i]!) row) bytes g (x + 1) (i + 1) n

/-- The cells after writing `k ≥ 1` characters from column `x` into `E`, a row
already padded to `x`. -/
def spec (E : Row) (bytes : ByteArray) (g : Bool) (x i k m : Nat) : Option Cell :=
  if x ≤ m ∧ m < x + k then some (asciiCell g bytes[i + (m - x)]!)
  else if (0 < x ∧ E[x]? = some wideCell ∧ m + 1 = x) ∨ (E[x + k]? = some wideCell ∧ m = x + k)
  then some blank
  else E[m]?

theorem cellOp_first (row : Row) (bytes : ByteArray) (g : Bool) (x i m : Nat) :
    (cellOp x (asciiCell g bytes[i]!) row)[m]? = spec (ensure row x) bytes g x i 1 m := by
  have hs : x ≤ (clearWideEdges (ensure row x) x x).size := by
    rw [size_clearWideEdges, size_ensure]; omega
  unfold cellOp spec
  rw [getElem?_put _ _ _ hs, getElem?_clearWideEdges _ _ _ (by omega)]
  by_cases hm : m = x
  · subst hm; simp
  · have r : ¬(x ≤ m ∧ m < x + 1) := by omega
    simp only [hm, r, if_false]

theorem cellOp_next (R E : Row) (bytes : ByteArray) (g : Bool) (x i k : Nat) (hk : 1 ≤ k)
    (hR : ∀ m, R[m]? = spec E bytes g x i k m) (m : Nat) :
    (cellOp (x + k) (asciiCell g bytes[i + k]!) R)[m]? = spec E bytes g x i (k + 1) m := by
  have hsize : x + k ≤ R.size := by
    have e := hR (x + k - 1)
    have r : x ≤ x + k - 1 ∧ x + k - 1 < x + k := by omega
    simp only [spec, r, and_self, if_true] at e
    have : x + k - 1 < R.size := by
      rcases Nat.lt_or_ge (x + k - 1) R.size with h | h
      · exact h
      · rw [Array.getElem?_eq_none h] at e; cases e
    omega
  have at_k : R[x + k]? ≠ some wideCell := by
    rw [hR]
    have r : ¬(x ≤ x + k ∧ x + k < x + k) := by omega
    have l : ¬(x + k + 1 = x) := by omega
    simp only [spec, r, l, and_false, false_or, and_true, if_false]
    by_cases c : E[x + k]? = some wideCell
    · simp only [c, if_true]; simp [blank_ne_wide]
    · simp only [c, if_false]; exact c
  have at_k1 : R[x + k + 1]? = E[x + k + 1]? := by
    rw [hR]
    have r : ¬(x ≤ x + k + 1 ∧ x + k + 1 < x + k) := by omega
    have l : ¬(x + k + 1 + 1 = x) := by omega
    have h : ¬(x + k + 1 = x + k) := by omega
    simp only [spec, r, l, h, and_false, false_or, if_false]
  have hs : x + k ≤ (clearWideEdges (ensure R (x + k)) (x + k) (x + k)).size := by
    rw [size_clearWideEdges, ensure_of_le _ _ hsize]; exact hsize
  have no_lo : (R[x + k]? = some wideCell) = False := eq_false at_k
  unfold cellOp
  rw [getElem?_put _ _ _ hs, ensure_of_le _ _ hsize, getElem?_clearWideEdges _ _ _ (by omega),
    at_k1]
  simp only [no_lo, false_and, and_false, false_or]
  unfold spec
  rw [show x + (k + 1) = x + k + 1 by omega]
  by_cases h1 : m = x + k
  · subst h1
    have r : x ≤ x + k ∧ x + k < x + k + 1 := by omega
    simp [r]
  · have r1 : (x ≤ m ∧ m < x + k + 1) ↔ (x ≤ m ∧ m < x + k) := by omega
    simp only [h1, if_false, r1]
    by_cases h2 : m = x + k + 1
    · subst h2
      have r : ¬(x ≤ x + k + 1 ∧ x + k + 1 < x + k) := by omega
      have l : ¬(x + k + 1 + 1 = x) := by omega
      simp only [r, l, and_false, false_or, and_true, if_false, at_k1]
    · rw [hR]
      have e1 : ¬(m = x + k + 1) := h2
      simp only [spec, e1, h1, and_false, or_false, if_false]

theorem seqRun_spec (R E : Row) (bytes : ByteArray) (g : Bool) (x i k r : Nat) (hk : 1 ≤ k)
    (hR : ∀ m, R[m]? = spec E bytes g x i k m) (m : Nat) :
    (seqRun R bytes g (x + k) (i + k) r)[m]? = spec E bytes g x i (k + r) m := by
  induction r generalizing R k with
  | zero => exact hR m
  | succ r ih =>
    rw [seqRun, show x + k + 1 = x + (k + 1) by omega, show i + k + 1 = i + (k + 1) by omega,
      ih _ _ (by omega) (cellOp_next R E bytes g x i k hk hR), Nat.add_assoc, Nat.add_comm 1 r]

theorem getElem?_seqRun (row : Row) (bytes : ByteArray) (g : Bool) (x i n m : Nat) :
    (seqRun row bytes g x i (n + 1))[m]? = spec (ensure row x) bytes g x i (n + 1) m := by
  rw [seqRun]
  have := seqRun_spec (cellOp x (asciiCell g bytes[i]!) row) (ensure row x) bytes g x i 1 n (Nat.le_refl 1)
    (cellOp_first row bytes g x i) m
  rw [Nat.add_comm 1 n] at this
  exact this

/-- Writing `n + 1` narrow characters one at a time equals clearing the halves
of wide characters at the segment's edges once and copying the bytes. -/
theorem seqRun_eq_batch (row : Row) (bytes : ByteArray) (g : Bool) (x i n : Nat) :
    seqRun row bytes g x i (n + 1) =
      copyCells (clearWideEdges (ensure row x) x (x + n)) bytes g x i (n + 1) := by
  apply Array.ext_getElem?
  intro m
  have hs : x ≤ (clearWideEdges (ensure row x) x (x + n)).size := by
    rw [size_clearWideEdges, size_ensure]; omega
  rw [getElem?_seqRun, copyCells_eq, getElem?_copyWith _ _ _ _ _ _ hs,
    getElem?_clearWideEdges _ _ _ (by omega)]
  unfold spec
  rw [show x + (n + 1) = x + n + 1 by omega]


/-! ### Overwriting one column -/

/-- `n` narrow characters `bytes[i:i + n]` all written at column `x`. -/
def sameRun (row : Row) (bytes : ByteArray) (g : Bool) (x i : Nat) : Nat → Row
  | 0 => row
  | n + 1 => sameRun (cellOp x (asciiCell g bytes[i]!) row) bytes g x (i + 1) n

theorem byte_ne_wide (b : UInt8) : b.toUInt32 ≠ wideCell := by
  intro h
  have := congrArg UInt32.toNat h
  have hb := b.toNat_lt
  simp [wideCell] at this
  omega

theorem cellOp_narrow (R : Row) (x : Nat) (c : Cell) (hs : x < R.size)
    (h0 : R[x]? ≠ some wideCell) (h1 : R[x + 1]? ≠ some wideCell) :
    cellOp x c R = R.set! x c := by
  have hc : clearWideEdges R x x = R := by
    apply Array.ext_getElem?
    intro m
    rw [getElem?_clearWideEdges _ _ _ (by omega),
      if_neg (by intro h; rcases h with h | h; exact h0 h.2.1; exact h1 h.1)]
  unfold cellOp
  rw [ensure_of_le _ _ (by omega), hc]
  unfold put
  rw [if_pos hs]

theorem sameRun_eq (R : Row) (bytes : ByteArray) (g : Bool) (x i r : Nat) (hs : x < R.size)
    (h0 : R[x]? ≠ some wideCell) (h1 : R[x + 1]? ≠ some wideCell) :
    sameRun R bytes g x i (r + 1) = R.set! x (asciiCell g bytes[i + r]!) := by
  induction r generalizing R i with
  | zero => simp only [sameRun, Nat.add_zero]; exact cellOp_narrow R x _ hs h0 h1
  | succ r ih =>
    rw [sameRun, cellOp_narrow R x _ hs h0 h1]
    rw [ih _ _ (by simp [Array.set!_eq_setIfInBounds]; exact hs)
      (by simp [Array.set!_eq_setIfInBounds, hs]
          exact asciiCell_ne_wide _ _)
      (by simp [Array.set!_eq_setIfInBounds]; exact h1)]
    apply Array.ext_getElem?
    intro m
    simp only [Array.set!_eq_setIfInBounds, Array.getElem?_setIfInBounds, Array.size_setIfInBounds]
    rw [show i + 1 + r = i + (r + 1) by omega]
    split <;> rfl

/-- After a segment that ends at column `x + n`, overwriting that column keeps
the rest of the segment. -/
theorem sameRun_seqRun (row : Row) (bytes : ByteArray) (g : Bool) (x i n r : Nat) :
    sameRun (seqRun row bytes g x i (n + 1)) bytes g (x + n) (i + n + 1) (r + 1) =
      (seqRun row bytes g x i (n + 1)).set! (x + n) (asciiCell g bytes[i + n + 1 + r]!) := by
  have at_last : (seqRun row bytes g x i (n + 1))[x + n]? = some (asciiCell g bytes[i + n]!) := by
    rw [getElem?_seqRun]; unfold spec
    rw [if_pos (by omega), show x + n - x = n by omega]
  apply sameRun_eq
  · rcases Nat.lt_or_ge (x + n) (seqRun row bytes g x i (n + 1)).size with h | h
    · exact h
    · rw [Array.getElem?_eq_none h] at at_last; cases at_last
  · rw [at_last]; intro h; exact asciiCell_ne_wide _ _ (Option.some.inj h)
  · rw [getElem?_seqRun, show x + n + 1 = x + (n + 1) by omega]; unfold spec
    have r : ¬(x ≤ x + (n + 1) ∧ x + (n + 1) < x + (n + 1)) := by omega
    have l : ¬(x + (n + 1) + 1 = x) := by omega
    simp only [r, l, and_false, false_or, if_false, and_true]
    by_cases c : (ensure row x)[x + (n + 1)]? = some wideCell
    · rw [if_pos c]; intro h; exact blank_ne_wide (Option.some.inj h)
    · rw [if_neg c]; exact c

/-! ### Insert mode -/

theorem getElem?_fillCells (row : Row) (cell : Cell) (i n : Nat) (h : i + n ≤ row.size) (m : Nat) :
    (fillCells row cell i n)[m]? = if i ≤ m ∧ m < i + n then some cell else row[m]? := by
  induction n generalizing row i with
  | zero => simp [fillCells]; omega
  | succ n ih =>
    rw [fillCells, ih _ _ (by simp [Array.set!_eq_setIfInBounds]; omega),
      Array.set!_eq_setIfInBounds, Array.getElem?_setIfInBounds]
    by_cases h1 : m = i
    · subst h1; simp [show m < row.size by omega]
    · by_cases h2 : i + 1 ≤ m ∧ m < i + 1 + n
      · rw [if_pos h2, if_pos (by omega)]
      · rw [if_neg h2, if_neg (Ne.symm h1), if_neg (by omega)]

theorem size_fillCells (row : Row) (cell : Cell) (i n : Nat) : (fillCells row cell i n).size = row.size := by
  induction n generalizing row i with
  | zero => rfl
  | succ n ih => rw [fillCells, ih]; simp [Array.set!_eq_setIfInBounds]

theorem size_moveRight (row : Row) (d i k : Nat) : (moveRight row d i k).size = row.size := by
  induction k generalizing row i with
  | zero => rfl
  | succ k ih => rw [moveRight, ih]; simp [Array.set!_eq_setIfInBounds]

/-- Copying rightward from the top index down reads cells not yet written. -/
theorem getElem?_moveRight (row : Row) (d i k : Nat) (hd : 1 ≤ d) (hi : i < row.size)
    (hk : k ≤ i + 1 - d) (m : Nat) :
    (moveRight row d i k)[m]? = if i + 1 - k ≤ m ∧ m ≤ i then row[m - d]? else row[m]? := by
  induction k generalizing row i with
  | zero => simp [moveRight]; intro h1 h2; omega
  | succ k ih =>
    have hsz : (row.set! i row[i - d]!).size = row.size := by simp [Array.set!_eq_setIfInBounds]
    rw [moveRight]
    by_cases hk0 : k = 0
    · subst hk0
      simp only [moveRight, Array.set!_eq_setIfInBounds, Array.getElem?_setIfInBounds]
      by_cases hm : m = i
      · subst hm
        simp [hi, getElem!_pos row (m - d) (by omega), Array.getElem?_eq_getElem (show m - d < row.size by omega)]
      · rw [if_neg (Ne.symm hm), if_neg (by omega)]
    · rw [ih _ _ (by rw [hsz]; omega) (by omega)]
      simp only [Array.set!_eq_setIfInBounds, Array.getElem?_setIfInBounds]
      by_cases hm : m = i
      · subst hm
        rw [if_neg (by omega), if_pos rfl, if_pos (by exact hi), if_pos (by omega),
          getElem!_pos row (m - d) (by omega), Array.getElem?_eq_getElem (show m - d < row.size by omega)]
      · rw [if_neg (Ne.symm hm)]
        by_cases hr : i - 1 + 1 - k ≤ m ∧ m ≤ i - 1
        · rw [if_pos hr, if_neg (show ¬(i = m - d) by omega),
            if_pos (show i + 1 - (k + 1) ≤ m ∧ m ≤ i by omega)]
        · rw [if_neg hr, if_neg (show ¬(i + 1 - (k + 1) ≤ m ∧ m ≤ i) by omega)]

/-- `shiftRight` cell by cell: blanks at `x`, the old cells moved right, and the
cells past `cols` unchanged. -/
theorem getElem?_shiftRight (row : Row) (x n cols : Nat) (hx : x < cols) (hn : 1 ≤ n) (m : Nat) :
    (shiftRight row x n cols)[m]? =
      if x ≤ m ∧ m < x + min n (cols - x) then some blank
      else if x + min n (cols - x) ≤ m ∧ m < cols then (ensure row cols)[m - min n (cols - x)]?
      else (ensure row cols)[m]? := by
  have hE : cols ≤ (ensure row cols).size := by rw [size_ensure]; omega
  unfold shiftRight
  dsimp only
  generalize ensure row cols = E at hE
  generalize hk : min n (cols - x) = k
  have hk1 : 1 ≤ k := by omega
  have hkx : x + k ≤ cols := by omega
  have hmv : ∀ m, (if cols > x + k then moveRight E k (cols - 1) (cols - x - k) else E)[m]? =
      if x + k ≤ m ∧ m < cols then E[m - k]? else E[m]? := by
    intro m
    split
    · rw [getElem?_moveRight _ _ _ _ hk1 (by omega) (by omega)]
      by_cases h : x + k ≤ m ∧ m < cols
      · rw [if_pos (by omega), if_pos h]
      · rw [if_neg (by omega), if_neg h]
    · rw [if_neg (by omega)]
  have hsz : (if cols > x + k then moveRight E k (cols - 1) (cols - x - k) else E).size = E.size := by
    split
    · exact size_moveRight _ _ _ _
    · rfl
  rw [getElem?_fillCells _ _ _ _ (by rw [hsz]; omega), hmv]

theorem size_shiftRight (row : Row) (x n cols : Nat) :
    (shiftRight row x n cols).size = max row.size cols := by
  unfold shiftRight
  dsimp only
  rw [size_fillCells]
  split
  · rw [size_moveRight, size_ensure]
  · rw [size_ensure]

/-- The row update of `putChar` for a narrow character in insert mode. -/
def insOp (cols x : Nat) (c : Cell) (row : Row) : Row :=
  put (clearWideEdges (shiftRight row x 1 cols) x x) x c

/-- `n` narrow characters inserted one at a time from column `x`. -/
def insRun (row : Row) (bytes : ByteArray) (g : Bool) (cols x i : Nat) : Nat → Row
  | 0 => row
  | n + 1 => insRun (insOp cols x (asciiCell g bytes[i]!) row) bytes g cols (x + 1) (i + 1) n

/-- The cells after inserting `k ≥ 1` characters at column `x` of `E`, the row
padded to `cols`: the characters, then the old cells from `x` (the first of
them blanked if it was the right half of a wide character). -/
def insSpec (E : Row) (bytes : ByteArray) (g : Bool) (cols x i k m : Nat) : Option Cell :=
  if x ≤ m ∧ m < x + k then some (asciiCell g bytes[i + (m - x)]!)
  else if x + k ≤ m ∧ m < cols then
    (if m = x + k ∧ E[x]? = some wideCell then some blank else E[m - k]?)
  else if m = cols ∧ x + k = cols ∧ E[cols]? = some wideCell then some blank
  else E[m]?

theorem insOp_first (row : Row) (bytes : ByteArray) (g : Bool) (cols x i : Nat) (hx : x < cols)
    (m : Nat) :
    (insOp cols x (asciiCell g bytes[i]!) row)[m]? = insSpec (ensure row cols) bytes g cols x i 1 m := by
  have hmin : min 1 (cols - x) = 1 := by omega
  have hS := getElem?_shiftRight row x 1 cols hx (Nat.le_refl 1)
  simp only [hmin] at hS
  have hsz : x ≤ (clearWideEdges (shiftRight row x 1 cols) x x).size := by
    rw [size_clearWideEdges, size_shiftRight]; omega
  have bw := blank_ne_wide
  unfold insOp insSpec
  rw [getElem?_put _ _ _ hsz, getElem?_clearWideEdges _ _ _ (by omega)]
  simp only [hS]
  clear hS hsz hmin
  rcases (by omega : m < x ∨ m = x ∨ (x < m ∧ m < cols) ∨ m = cols ∨ cols < m) with h | h | h | h | h
  all_goals simp (disch := omega) only [if_pos, if_neg]
  all_goals repeat' (first | (exfalso; omega) | split)
  all_goals first
    | rfl
    | (simp_all; done)
    | (exfalso; omega)
    | (simp_all; omega)
    | (have e : x + 1 = cols := by omega
       subst e; simp_all)

theorem insSpec_some (E : Row) (bytes : ByteArray) (g : Bool) (cols x i k m : Nat)
    (hE : cols ≤ E.size) (hm : m < cols) : insSpec E bytes g cols x i k m ≠ none := by
  unfold insSpec
  repeat' split
  all_goals first
    | (intro h; cases h)
    | (rw [Array.getElem?_eq_getElem (by omega)]; intro h; cases h)

theorem insOp_next (R E : Row) (bytes : ByteArray) (g : Bool) (cols x i k : Nat) (hk : 1 ≤ k)
    (hxk : x + k < cols) (hE : cols ≤ E.size) (hR : ∀ m, R[m]? = insSpec E bytes g cols x i k m)
    (m : Nat) :
    (insOp cols (x + k) (asciiCell g bytes[i + k]!) R)[m]? = insSpec E bytes g cols x i (k + 1) m := by
  have hRs : cols ≤ R.size := by
    have := insSpec_some E bytes g cols x i k (cols - 1) hE (by omega)
    rw [← hR] at this
    rcases Nat.lt_or_ge (cols - 1) R.size with h | h
    · omega
    · exact absurd (Array.getElem?_eq_none h) this
  have hmin : min 1 (cols - (x + k)) = 1 := by omega
  have hS := getElem?_shiftRight R (x + k) 1 cols hxk (Nat.le_refl 1)
  simp only [hmin, ensure_of_le _ _ hRs] at hS
  have hsz : x + k ≤ (clearWideEdges (shiftRight R (x + k) 1 cols) (x + k) (x + k)).size := by
    rw [size_clearWideEdges, size_shiftRight]; omega
  have bw := blank_ne_wide
  have aw := asciiCell_ne_wide g
  unfold insOp
  rw [getElem?_put _ _ _ hsz, getElem?_clearWideEdges _ _ _ (by omega)]
  simp only [hS, hR]
  clear hS hR hsz hmin
  unfold insSpec
  rcases (by omega : m < x ∨ (x ≤ m ∧ m < x + k) ∨ m = x + k ∨ (x + k < m ∧ m < cols) ∨ m = cols ∨
      cols < m) with h | h | h | h | h | h
  all_goals simp (disch := omega) only [if_pos, if_neg, true_and]
  all_goals repeat' (first | (exfalso; omega) | split)
  all_goals first
    | rfl
    | (simp_all; done)
    | (simp_all; omega)
    | (congr 1; omega)
    | (obtain rfl : m = cols := by omega
       simp_all; done)
    | (obtain rfl : m = cols := by omega
       simp_all; omega)
    | (obtain rfl : m = x + k + 1 := by omega
       simp_all; done)
    | (obtain rfl : m = x + k + 1 := by omega
       simp_all; omega)
    | (obtain rfl : cols = x + k + 1 := by omega
       simp_all; done)
    | (obtain rfl : cols = x + k + 1 := by omega
       simp_all; omega)

theorem insRun_spec (R E : Row) (bytes : ByteArray) (g : Bool) (cols x i k r : Nat) (hk : 1 ≤ k)
    (hr : x + k + r ≤ cols) (hE : cols ≤ E.size) (hR : ∀ m, R[m]? = insSpec E bytes g cols x i k m)
    (m : Nat) :
    (insRun R bytes g cols (x + k) (i + k) r)[m]? = insSpec E bytes g cols x i (k + r) m := by
  induction r generalizing R k with
  | zero => exact hR m
  | succ r ih =>
    rw [insRun, show x + k + 1 = x + (k + 1) by omega, show i + k + 1 = i + (k + 1) by omega,
      ih _ _ (by omega) (by omega) (insOp_next R E bytes g cols x i k hk (by omega) hE hR),
      Nat.add_assoc, Nat.add_comm 1 r]

theorem getElem?_insRun (row : Row) (bytes : ByteArray) (g : Bool) (cols x i n m : Nat)
    (h : x + n + 1 ≤ cols) :
    (insRun row bytes g cols x i (n + 1))[m]? = insSpec (ensure row cols) bytes g cols x i (n + 1) m := by
  rw [insRun]
  have := insRun_spec (insOp cols x (asciiCell g bytes[i]!) row) (ensure row cols) bytes g cols x i 1 n
    (Nat.le_refl 1) (by omega) (by rw [size_ensure]; omega) (insOp_first row bytes g cols x i (by omega)) m
  rw [Nat.add_comm 1 n] at this
  exact this

/-- Inserting `n + 1` narrow characters one at a time equals one shift of the
rest of the row, the edges of wide characters cleared once, and a copy. -/
theorem insRun_eq_batch (row : Row) (bytes : ByteArray) (g : Bool) (cols x i n : Nat)
    (h : x + n + 1 ≤ cols) :
    insRun row bytes g cols x i (n + 1) =
      copyCells (clearWideEdges (shiftRight row x (n + 1) cols) x (x + n)) bytes g x i (n + 1) := by
  apply Array.ext_getElem?
  intro m
  have hmin : min (n + 1) (cols - x) = n + 1 := by omega
  have hS := getElem?_shiftRight row x (n + 1) cols (by omega) (by omega)
  simp only [hmin] at hS
  have hs : x ≤ (clearWideEdges (shiftRight row x (n + 1) cols) x (x + n)).size := by
    rw [size_clearWideEdges, size_shiftRight]; omega
  have bw := blank_ne_wide
  rw [getElem?_insRun _ _ _ _ _ _ _ _ h, copyCells_eq, getElem?_copyWith _ _ _ _ _ _ hs,
    getElem?_clearWideEdges _ _ _ (by omega)]
  simp only [hS]
  clear hS hs hmin
  unfold insSpec
  rcases (by omega : m < x ∨ (x ≤ m ∧ m ≤ x + n) ∨ m = x + n + 1 ∨ (x + n + 1 < m ∧ m < cols) ∨
      m = cols ∨ cols < m) with h | h | h | h | h | h
  all_goals simp (disch := omega) only [if_pos, if_neg]
  all_goals repeat' (first | (exfalso; omega) | split)
  all_goals first
    | rfl
    | (simp_all; done)
    | (simp_all; omega)
    | (congr 1; omega)
    | (obtain rfl : m = cols := by omega
       simp_all; done)
    | (obtain rfl : m = x + n + 1 := by omega
       simp_all; done)
    | (obtain rfl : cols = x + n + 1 := by omega
       simp_all; done)
    | (obtain rfl : cols = x + n + 1 := by omega
       simp_all; omega)

/-- Insert mode at the last column: the cell is replaced. -/
theorem insOp_last (R : Row) (cols : Nat) (c : Cell) (hc : 1 ≤ cols) (hs : cols ≤ R.size)
    (hw : R[cols]? ≠ some wideCell) : insOp cols (cols - 1) c R = R.set! (cols - 1) c := by
  have hmin : min 1 (cols - (cols - 1)) = 1 := by omega
  have hS := getElem?_shiftRight R (cols - 1) 1 cols (by omega) (Nat.le_refl 1)
  simp only [hmin, ensure_of_le _ _ hs] at hS
  have hsz : cols - 1 ≤ (clearWideEdges (shiftRight R (cols - 1) 1 cols) (cols - 1) (cols - 1)).size := by
    rw [size_clearWideEdges, size_shiftRight]; omega
  have bw := blank_ne_wide
  apply Array.ext_getElem?
  intro m
  unfold insOp
  rw [getElem?_put _ _ _ hsz, getElem?_clearWideEdges _ _ _ (by omega), Array.set!_eq_setIfInBounds,
    Array.getElem?_setIfInBounds]
  simp only [hS]
  repeat' (first | (exfalso; omega) | split)
  all_goals first
    | rfl
    | (simp_all; done)
    | (simp_all; omega)
    | (obtain rfl : m = cols := by omega
       simp_all; done)

/-- `n` narrow characters all inserted at the last column. -/
def insSame (row : Row) (bytes : ByteArray) (g : Bool) (cols i : Nat) : Nat → Row
  | 0 => row
  | n + 1 => insSame (insOp cols (cols - 1) (asciiCell g bytes[i]!) row) bytes g cols (i + 1) n

theorem insSame_eq (R : Row) (bytes : ByteArray) (g : Bool) (cols i r : Nat) (hc : 1 ≤ cols)
    (hs : cols ≤ R.size) (hw : R[cols]? ≠ some wideCell) :
    insSame R bytes g cols i (r + 1) = R.set! (cols - 1) (asciiCell g bytes[i + r]!) := by
  induction r generalizing R i with
  | zero => simp only [insSame, Nat.add_zero]; exact insOp_last R cols _ hc hs hw
  | succ r ih =>
    rw [insSame, insOp_last R cols _ hc hs hw]
    rw [ih _ _ (by simp [Array.set!_eq_setIfInBounds]; omega)
      (by rw [Array.set!_eq_setIfInBounds, Array.getElem?_setIfInBounds, if_neg (by omega)]
          exact hw)]
    apply Array.ext_getElem?
    intro m
    simp only [Array.set!_eq_setIfInBounds, Array.getElem?_setIfInBounds, Array.size_setIfInBounds]
    rw [show i + 1 + r = i + (r + 1) by omega]
    split <;> rfl

/-- After an insert segment that ends at the last column, inserting more there
replaces that cell. -/
theorem insSame_insRun (row : Row) (bytes : ByteArray) (g : Bool) (cols x i n r : Nat)
    (h : x + n + 1 = cols) :
    insSame (insRun row bytes g cols x i (n + 1)) bytes g cols (i + n + 1) (r + 1) =
      (insRun row bytes g cols x i (n + 1)).set! (cols - 1) (asciiCell g bytes[i + n + 1 + r]!) := by
  have hl := getElem?_insRun row bytes g cols x i n (cols - 1) (by omega)
  apply insSame_eq _ _ _ _ _ _ (by omega)
  · rcases Nat.lt_or_ge (cols - 1) (insRun row bytes g cols x i (n + 1)).size with h1 | h1
    · omega
    · rw [Array.getElem?_eq_none h1] at hl
      unfold insSpec at hl
      rw [if_pos (by omega)] at hl
      cases hl
  · rw [getElem?_insRun _ _ _ _ _ _ _ _ (by omega)]
    unfold insSpec
    rw [if_neg (by omega), if_neg (by omega)]
    by_cases w : (ensure row cols)[cols]? = some wideCell
    · rw [if_pos ⟨rfl, h, w⟩]; intro e; exact blank_ne_wide (Option.some.inj e)
    · rw [if_neg (by intro e; exact w e.2.2)]; exact w

/-! ### Either mode -/

/-- The row update of `putChar` for a narrow character. -/
def charOp (ins : Bool) (cols x : Nat) (c : Cell) (row : Row) : Row :=
  if ins then insOp cols x c row else cellOp x c row

/-- `n` narrow characters `bytes[i:i + n]` written from column `x`, one at a time. -/
def segRun (ins : Bool) (cols : Nat) (row : Row) (bytes : ByteArray) (g : Bool) (x i n : Nat) : Row :=
  if ins then insRun row bytes g cols x i n else seqRun row bytes g x i n

theorem segRun_zero (ins : Bool) (cols : Nat) (row : Row) (bytes : ByteArray) (g : Bool) (x i : Nat) :
    segRun ins cols row bytes g x i 0 = row := by
  cases ins <;> rfl

theorem segRun_succ (ins : Bool) (cols : Nat) (row : Row) (bytes : ByteArray) (g : Bool) (x i n : Nat) :
    segRun ins cols row bytes g x i (n + 1) =
      segRun ins cols (charOp ins cols x (asciiCell g bytes[i]!) row) bytes g (x + 1) (i + 1) n := by
  cases ins <;> simp only [segRun, charOp, seqRun, insRun, Bool.false_eq_true, if_false, if_true]

/-- The row before a segment is copied into it. -/
def segBase (ins : Bool) (cols : Nat) (row : Row) (x n : Nat) : Row :=
  if ins then shiftRight row x n cols else ensure row x

theorem segRun_eq_batch (ins : Bool) (cols : Nat) (row : Row) (bytes : ByteArray) (g : Bool)
    (x i n : Nat) (h : x + n + 1 ≤ cols) :
    segRun ins cols row bytes g x i (n + 1) =
      copyCells (clearWideEdges (segBase ins cols row x (n + 1)) x (x + n)) bytes g x i (n + 1) := by
  cases ins
  · exact seqRun_eq_batch row bytes g x i n
  · exact insRun_eq_batch row bytes g cols x i n h

/-- `n` narrow characters all written at the last column. -/
def segSame (ins : Bool) (cols : Nat) (row : Row) (bytes : ByteArray) (g : Bool) (i n : Nat) : Row :=
  if ins then insSame row bytes g cols i n else sameRun row bytes g (cols - 1) i n

theorem segSame_zero (ins : Bool) (cols : Nat) (row : Row) (bytes : ByteArray) (g : Bool) (i : Nat) :
    segSame ins cols row bytes g i 0 = row := by
  cases ins <;> rfl

theorem segSame_succ (ins : Bool) (cols : Nat) (row : Row) (bytes : ByteArray) (g : Bool) (i n : Nat) :
    segSame ins cols row bytes g i (n + 1) =
      segSame ins cols (charOp ins cols (cols - 1) (asciiCell g bytes[i]!) row) bytes g (i + 1) n := by
  cases ins <;> simp only [segSame, charOp, sameRun, insSame, Bool.false_eq_true, if_false, if_true]

theorem segSame_segRun (ins : Bool) (cols : Nat) (row : Row) (bytes : ByteArray) (g : Bool)
    (x i n r : Nat) (h : x + n + 1 = cols) :
    segSame ins cols (segRun ins cols row bytes g x i (n + 1)) bytes g (i + n + 1) (r + 1) =
      (segRun ins cols row bytes g x i (n + 1)).set! (cols - 1) (asciiCell g bytes[i + n + 1 + r]!) := by
  cases ins
  · simp only [segSame, segRun, Bool.false_eq_true, if_false]
    rw [show cols - 1 = x + n by omega]
    exact sameRun_seqRun row bytes g x i n r
  · simp only [segSame, segRun, if_true]
    exact insSame_insRun row bytes g cols x i n r h

end VerifiedKernel.Terminal
