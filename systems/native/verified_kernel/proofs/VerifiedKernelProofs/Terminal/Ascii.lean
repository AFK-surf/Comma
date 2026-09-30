import VerifiedKernelProofs.Terminal.Frame
import VerifiedKernelProofs.Terminal.Rows

/-!
# Printable ASCII runs

`writeAscii` writes a run of printable ASCII a row segment at a time.
`writeAscii_eq_run` shows that it equals `step` applied to each byte.
-/

namespace VerifiedKernel.Terminal

/-- `step` applied to `bytes[i:i + n]`, one byte at a time. -/
def run (t : State) (bytes : ByteArray) (i : Nat) : Nat → State
  | 0 => t
  | n + 1 => run (step t bytes[i]!) bytes (i + 1) n

theorem run_add (t : State) (bytes : ByteArray) (i a b : Nat) :
    run t bytes i (a + b) = run (run t bytes i a) bytes (i + a) b := by
  induction a generalizing t i with
  | zero => simp [run]
  | succ a ih =>
    rw [show a + 1 + b = (a + b) + 1 by omega, run, run, ih, show i + 1 + a = i + (a + 1) by omega]

/-- `putChar` for narrow characters `bytes[i:i + n]`, one at a time. -/
def putRun (t : State) (bytes : ByteArray) (g : Bool) (i : Nat) : Nat → State
  | 0 => t
  | n + 1 => putRun (putChar t (asciiCell g bytes[i]!) 1) bytes g (i + 1) n

theorem putRun_add (t : State) (bytes : ByteArray) (g : Bool) (i a b : Nat) :
    putRun t bytes g i (a + b) = putRun (putRun t bytes g i a) bytes g (i + a) b := by
  induction a generalizing t i with
  | zero => simp [putRun]
  | succ a ih =>
    rw [show a + 1 + b = (a + b) + 1 by omega, putRun, putRun, ih,
      show i + 1 + a = i + (a + 1) by omega]

/-! ### Fields that printing leaves alone -/

theorem index_parser (t : State) : (index t).parser = t.parser := by
  unfold index scrollUpOnce; dsimp only; repeat' split
  all_goals rfl

theorem index_cfg (t : State) : (index t).cfg = t.cfg := by
  unfold index scrollUpOnce; dsimp only; repeat' split
  all_goals rfl

theorem index_utf8Need (t : State) : (index t).utf8Need = t.utf8Need := (keeps_index t).2.2.1

/-- The pending wrap that `putChar` performs first. -/
def wrap (t : State) : State :=
  if t.pendingWrap && t.autowrap then index { t with x := 0, pendingWrap := false } else t

theorem wrap_cfg (t : State) : (wrap t).cfg = t.cfg := by
  unfold wrap; split
  · exact index_cfg _
  · rfl

theorem wrap_of_not_pending (t : State) (h : t.pendingWrap = false) : wrap t = t := by
  simp [wrap, h]

/-- The column after `k` characters from the clamped column, in machine words
and in `Nat`. -/
theorem col_step (x c : UInt32) (hc : 0 < c) (k : Nat)
    (hk : min x.toNat (c.toNat - 1) + k ≤ c.toNat) :
    (decide (min x (c - 1) + k.toUInt32 ≥ c) = decide (min x.toNat (c.toNat - 1) + k ≥ c.toNat)) ∧
    (if min x (c - 1) + k.toUInt32 ≥ c then c - 1 else min x (c - 1) + k.toUInt32) =
      (if min x.toNat (c.toNat - 1) + k ≥ c.toNat then c.toNat - 1
        else min x.toNat (c.toNat - 1) + k).toUInt32 := by
  have hx := toNat_clamp x c hc
  have hct := c.toNat_lt
  have hc' : 0 < c.toNat := hc
  have hkl : k < 2 ^ 32 := by omega
  have hsum : (min x (c - 1) + k.toUInt32).toNat = min x.toNat (c.toNat - 1) + k := by
    rw [toNat_uadd (by rw [hx, toNat_toUInt32 hkl]; omega), hx, toNat_toUInt32 hkl]
  have hiff : (min x (c - 1) + k.toUInt32 ≥ c) ↔ (min x.toNat (c.toNat - 1) + k ≥ c.toNat) := by
    rw [ge_iff_le, UInt32.le_iff_toNat_le, hsum]
  refine ⟨decide_eq_decide.mpr hiff, ?_⟩
  by_cases h : min x.toNat (c.toNat - 1) + k ≥ c.toNat
  · rw [if_pos (hiff.mpr h), if_pos h]
    exact uint32_eq_toUInt32 (by rw [toNat_usub (by simp; omega), UInt32.toNat_one])
  · rw [if_neg (fun e => h (hiff.mp e)), if_neg h]
    exact uint32_eq_toUInt32 hsum

/-- `cols - 1` as the word of its value. -/
theorem usub_one (c : UInt32) (hc : 0 < c) : c - 1 = (c.toNat - 1).toUInt32 := by
  have : 0 < c.toNat := hc
  exact uint32_eq_toUInt32 (by rw [toNat_usub (by simp; omega), UInt32.toNat_one])

theorem putChar_one (t : State) (c : Cell) (hc : 0 < t.cols) :
    putChar t c 1 =
      let t1 := wrap t
      let x := min t1.x.toNat (t1.cols.toNat - 1)
      { t1 with
        grid := t1.grid.modify (phys t1 t1.y) (charOp t1.insert t1.cols.toNat x c)
        lastChar := c
        x := (if x + 1 ≥ t1.cols.toNat then t1.cols.toNat - 1 else x + 1).toUInt32
        pendingWrap := decide (x + 1 ≥ t1.cols.toNat) && t1.autowrap } := by
  unfold putChar
  simp only [show (1 == 2) = false from rfl, Bool.false_and, Bool.false_eq_true, if_false]
  generalize hw : (if t.pendingWrap && t.autowrap then index { t with x := 0, pendingWrap := false }
    else t) = t1
  have ht : wrap t = t1 := hw
  have hc1 : 0 < t1.cols := by rw [← ht]; simp only [State.cols, wrap_cfg]; exact hc
  rw [ht]
  have hx := toNat_clamp t1.x t1.cols hc1
  have ⟨hd, hi⟩ := col_step t1.x t1.cols hc1 1 (by have : 0 < t1.cols.toNat := hc1; omega)
  simp only [show (1 : Nat).toUInt32 = 1 from rfl] at hd hi ⊢
  simp only [hx, hd, hi, Nat.add_sub_cancel]
  unfold charOp insOp cellOp
  cases t1.insert <;> rfl

theorem modify_modify (g : Array Row) (p : Nat) (f h : Row → Row) :
    (g.modify p f).modify p h = g.modify p (fun r => h (f r)) := by
  apply Array.ext_getElem?
  intro j
  simp only [Array.getElem?_modify]
  split <;> simp [Option.map_map, Function.comp_def]


/-- `n + 1` narrow characters that fit on the cursor's row: one row update. -/
theorem putRun_segment (t : State) (bytes : ByteArray) (g : Bool) (i n : Nat) (hc : 0 < t.cols)
    (hn : min (wrap t).x.toNat ((wrap t).cols.toNat - 1) + n + 1 ≤ (wrap t).cols.toNat) :
    putRun t bytes g i (n + 1) =
      let t1 := wrap t
      let x := min t1.x.toNat (t1.cols.toNat - 1)
      { t1 with
        grid := t1.grid.modify (phys t1 t1.y)
          (fun row => segRun t1.insert t1.cols.toNat row bytes g x i (n + 1))
        lastChar := (asciiCell g bytes[i + n]!)
        x := (if x + n + 1 ≥ t1.cols.toNat then t1.cols.toNat - 1 else x + n + 1).toUInt32
        pendingWrap := decide (x + n + 1 ≥ t1.cols.toNat) && t1.autowrap } := by
  induction n generalizing t i with
  | zero =>
    rw [putRun, putRun, putChar_one t _ hc]
    rfl
  | succ n ih =>
    rw [putRun, putChar_one t _ hc]
    have hc1 : 0 < (wrap t).cols := by simp only [State.cols, wrap_cfg]; exact hc
    generalize wrap t = t1 at hn hc1 ⊢
    dsimp only
    have hct := t1.cols.toNat_lt
    have hx : min t1.x.toNat (t1.cols.toNat - 1) + 1 < t1.cols.toNat := by omega
    have hpw : (decide (min t1.x.toNat (t1.cols.toNat - 1) + 1 ≥ t1.cols.toNat) && t1.autowrap) = false := by
      simp only [ge_iff_le, Bool.and_eq_false_iff, decide_eq_false_iff_not, Nat.not_le]
      exact Or.inl hx
    have hxe : (if min t1.x.toNat (t1.cols.toNat - 1) + 1 ≥ t1.cols.toNat then t1.cols.toNat - 1
        else min t1.x.toNat (t1.cols.toNat - 1) + 1) = min t1.x.toNat (t1.cols.toNat - 1) + 1 :=
      if_neg (by omega)
    simp only [hpw, hxe]
    have hsx : (min t1.x.toNat (t1.cols.toNat - 1) + 1).toUInt32.toNat =
        min t1.x.toNat (t1.cols.toNat - 1) + 1 := toNat_toUInt32 (by omega)
    have hmin : min (min t1.x.toNat (t1.cols.toNat - 1) + 1) (t1.cols.toNat - 1) =
        min t1.x.toNat (t1.cols.toNat - 1) + 1 := Nat.min_eq_left (by omega)
    rw [ih _ _ (by exact hc1)
      (by rw [wrap_of_not_pending _ rfl]; dsimp only [State.cols]
          simp only [State.cols] at hsx hmin hn; rw [hsx, hmin]; omega)]
    rw [wrap_of_not_pending _ rfl]
    dsimp only [State.cols, State.autowrap, State.insert]
    simp only [State.cols] at hsx hmin
    rw [hsx, hmin]
    erw [modify_modify]
    rw [show i + 1 + n = i + (n + 1) by omega,
      show min t1.x.toNat (t1.cfg.cols.toNat - 1) + 1 + n + 1 =
        min t1.x.toNat (t1.cfg.cols.toNat - 1) + (n + 1) + 1 by omega]
    simp only [segRun_succ (n := n + 1), State.mk.injEq, true_and, and_true]
    and_intros <;> rfl

/-- Without autowrap, characters past the last column overwrite it. -/
theorem putRun_overflow (S : State) (bytes : ByteArray) (g : Bool) (i r : Nat) (hc : 0 < S.cols)
    (hpw : S.pendingWrap = false) (haw : S.autowrap = false) (hx : S.x.toNat = S.cols.toNat - 1) :
    putRun S bytes g i (r + 1) =
      { S with
        grid := S.grid.modify (phys S S.y) (fun row => segSame S.insert S.cols.toNat row bytes g i (r + 1))
        lastChar := (asciiCell g bytes[i + r]!)
        x := (S.cols.toNat - 1).toUInt32
        pendingWrap := false } := by
  have hct := S.cols.toNat_lt
  have hc' : 0 < S.cols.toNat := hc
  induction r generalizing S i with
  | zero =>
    rw [putRun, putRun, putChar_one S _ hc, wrap_of_not_pending S hpw]
    dsimp only
    rw [hx, Nat.min_self, if_pos (by omega)]
    simp only [State.autowrap] at haw
    simp only [State.autowrap, haw, Bool.and_false, segSame_succ, segSame_zero, Nat.add_zero]
  | succ r ih =>
    rw [putRun, putChar_one S _ hc, wrap_of_not_pending S hpw]
    dsimp only
    rw [hx, Nat.min_self, if_pos (by omega)]
    simp only [State.autowrap] at haw
    simp only [State.autowrap, haw, Bool.and_false]
    rw [ih _ _ (by exact hc) (by rfl) (by exact haw) (by exact toNat_toUInt32 (by omega)) (by exact hct)
      (by exact hc')]
    dsimp only [State.cols, State.insert]
    erw [modify_modify]
    simp only [segSame_succ (n := r + 1), State.mk.injEq, true_and, and_true]
    rw [show i + 1 + r = i + (r + 1) by omega]

/-- `writeAscii` equals `putChar` applied to each byte. -/
theorem writeAscii_go (bytes : ByteArray) (g : Bool) (j : Nat) (t : State) (i fuel : Nat)
    (hcols : 0 < t.cols) (hfuel : j - i ≤ fuel) :
    writeAscii.go bytes g j t i fuel = putRun t bytes g i (j - i) := by
  induction fuel generalizing t i with
  | zero =>
    rw [writeAscii.go, show j - i = 0 by omega]; rfl
  | succ fuel ih =>
    rw [writeAscii.go]
    by_cases hij : i ≥ j
    · rw [if_pos hij, show j - i = 0 by omega]; rfl
    rw [if_neg hij]
    rw [show (if t.pendingWrap && t.autowrap then index { t with x := 0, pendingWrap := false }
      else t) = wrap t from rfl]
    have hcfg : (wrap t).cfg = t.cfg := wrap_cfg t
    have hcols1 : 0 < (wrap t).cols := by simp only [State.cols, hcfg]; exact hcols
    have hc' : 0 < (wrap t).cols.toNat := hcols1
    have hct := (wrap t).cols.toNat_lt
    -- Column arithmetic in `Nat`.
    have hclamp := toNat_clamp (wrap t).x (wrap t).cols hcols1
    have hroom : ((wrap t).cols - min (wrap t).x ((wrap t).cols - 1)).toNat =
        (wrap t).cols.toNat - min (wrap t).x.toNat ((wrap t).cols.toNat - 1) := by
      rw [toNat_usub (by rw [hclamp]; omega), hclamp]
    simp only [hroom, hclamp]
    -- The segment: `n' + 1` characters from column `x`.
    obtain ⟨n', hn'⟩ : ∃ n', min ((wrap t).cols.toNat - min (wrap t).x.toNat ((wrap t).cols.toNat - 1))
        (j - i) = n' + 1 :=
      ⟨min ((wrap t).cols.toNat - min (wrap t).x.toNat ((wrap t).cols.toNat - 1)) (j - i) - 1, by omega⟩
    have hfit : min (wrap t).x.toNat ((wrap t).cols.toNat - 1) + (n' + 1) ≤ (wrap t).cols.toNat := by omega
    have hseg := putRun_segment t bytes g i n' hcols (by omega)
    have hsplit : putRun t bytes g i (j - i) =
        putRun (putRun t bytes g i (n' + 1)) bytes g (i + (n' + 1)) (j - i - (n' + 1)) := by
      rw [← putRun_add]; congr 1; omega
    rw [hsplit, hseg]
    dsimp only
    rw [hn']
    have ⟨hd, hi⟩ := col_step (wrap t).x (wrap t).cols hcols1 (n' + 1) hfit
    simp only [← Nat.add_assoc] at hd hi
    rw [hi]
    simp only [hd]
    generalize ht1 : wrap t = t1 at hcfg hcols1 hc' hct hn' hfit hclamp ⊢
    by_cases hover : i + (n' + 1) < j ∧ t1.autowrap = false
    · -- Without autowrap, the rest of the run overwrites the last column.
      have hx : min t1.x.toNat (t1.cols.toNat - 1) + n' = t1.cols.toNat - 1 := by omega
      rw [if_pos (by simp [hover.1, hover.2])]
      obtain ⟨r, hr⟩ : ∃ r, j - i - (n' + 1) = r + 1 := ⟨j - i - (n' + 1) - 1, by omega⟩
      rw [hr, putRun_overflow _ _ _ _ _ (by exact hcols1)
        (by simp only [State.autowrap] at hover ⊢; simp [hover.2])
        (by simp only [State.autowrap] at hover ⊢; exact hover.2)
        (by dsimp only; rw [if_pos (by omega), toNat_toUInt32 (by omega)]; rfl)]
      dsimp only [State.cols, State.insert]
      erw [modify_modify]
      simp only [State.mk.injEq, true_and, and_true]
      refine ⟨?_, ?_, ?_⟩
      · congr 1
        funext row
        simp only [State.cols] at hx hfit
        rw [show i + (n' + 1) = i + n' + 1 by omega, segSame_segRun _ _ row bytes g _ i n' r (by omega),
          segRun_eq_batch _ _ _ _ _ _ _ _ (by omega),
          show i + n' + 1 + r = j - 1 by omega,
          show min t1.x.toNat (t1.cfg.cols.toNat - 1) + (n' + 1) - 1 =
            min t1.x.toNat (t1.cfg.cols.toNat - 1) + n' by omega, hx]
        rfl
      · first
          | exact (usub_one _ hcols1).symm
          | exact usub_one _ hcols1
      · rw [show i + (n' + 1) + r = j - 1 by omega]
    · have hc : ¬((decide (i + (n' + 1) < j) && !t1.autowrap) = true) := by
        simp only [Bool.and_eq_true, decide_eq_true_eq, Bool.not_eq_true']
        intro ⟨a, b⟩
        exact hover ⟨a, b⟩
      rw [if_neg hc]
      rw [ih _ _ (by exact hcols1) (by omega)]
      rw [show j - (i + (n' + 1)) = j - i - (n' + 1) by omega]
      congr 1
      simp only [State.mk.injEq, true_and, and_true]
      refine ⟨?_, ?_⟩
      · congr 1
        funext row
        rw [segRun_eq_batch _ _ _ _ _ _ _ _ (by omega),
          show min t1.x.toNat (t1.cols.toNat - 1) + (n' + 1) - 1 = min t1.x.toNat (t1.cols.toNat - 1) + n' by
            omega]
        rfl
      · rw [show i + (n' + 1) - 1 = i + n' by omega]

/-! ### From bytes to characters -/

theorem printable_iff (b : UInt8) : printable b = true ↔ 0x20 ≤ b.toNat ∧ b.toNat < 0x7F := by
  simp [printable, UInt8.le_iff_toNat_le, UInt8.lt_iff_toNat_lt]

/-- Printable ASCII and its DEC Special Graphics replacements are narrow. -/
theorem charWidth_asciiCell (g : Bool) (b : UInt8) (hb : printable b = true) :
    charWidth (asciiCell g b) = 1 := by
  have ⟨lo, hi⟩ := (printable_iff b).mp hb
  have narrow : ∀ c : UInt32, c.toNat < 0x300 → charWidth c = 1 := by
    intro c hc; unfold charWidth; rw [if_pos (by simp [UInt32.lt_iff_toNat_lt]; omega)]
  cases g
  · exact narrow _ (by simp [asciiCell]; omega)
  · simp only [asciiCell, if_true]
    unfold decGraphics
    split
    all_goals first
      | decide
      | exact narrow _ (by simp; omega)

theorem step_printable (t : State) (b : UInt8) (hneed : t.utf8Need = 0)
    (hparser : t.parser = .ground) (hb : printable b = true) :
    step t b = putChar t (asciiCell (graphics t) b) 1 := by
  have ⟨lo, hi⟩ := (printable_iff b).mp hb
  have n18 : (b == 0x18) = false := by
    simp only [beq_eq_false_iff_ne, ne_eq]; intro h; subst h; simp at lo
  have n1a : (b == 0x1A) = false := by
    simp only [beq_eq_false_iff_ne, ne_eq]; intro h; subst h; simp at lo
  have n1b : (b == 0x1B) = false := by
    simp only [beq_eq_false_iff_ne, ne_eq]; intro h; subst h; simp at lo
  have n20 : ¬(b < 0x20) := by simp [UInt8.lt_iff_toNat_lt]; omega
  have n7f : b < 0x7F := by simp [UInt8.lt_iff_toNat_lt]; omega
  have w := charWidth_asciiCell (graphics t) b hb
  unfold step nonUtf8Byte groundByte print
  simp only [hneed, beq_self_eq_true, if_true, n18, n1a, n1b, Bool.false_or, Bool.false_and,
    Bool.false_eq_true, if_false, hparser, n20, n7f]
  change (match charWidth (asciiCell (graphics t) b) with
    | 0 => combine t (asciiCell (graphics t) b)
    | w => putChar t (asciiCell (graphics t) b) w) = _
  rw [w]
  rfl

theorem putChar_fields (t : State) (c : Cell) (hc : 0 < t.cols) :
    (putChar t c 1).parser = t.parser ∧ (putChar t c 1).cfg = t.cfg ∧
      (putChar t c 1).utf8Need = t.utf8Need := by
  rw [putChar_one t c hc]
  refine ⟨?_, wrap_cfg t, ?_⟩
  · show (wrap t).parser = t.parser
    unfold wrap; split
    · exact index_parser _
    · rfl
  · show (wrap t).utf8Need = t.utf8Need
    unfold wrap; split
    · exact index_utf8Need _
    · rfl

/-- On printable bytes in ground state, `step` is `putChar`. -/
theorem run_printable (t : State) (bytes : ByteArray) (i n : Nat) (hneed : t.utf8Need = 0)
    (hparser : t.parser = .ground) (g : Bool) (hg : graphics t = g) (hc : 0 < t.cols)
    (hp : ∀ k, i ≤ k → k < i + n → printable bytes[k]! = true) :
    run t bytes i n = putRun t bytes g i n := by
  induction n generalizing t i with
  | zero => rfl
  | succ n ih =>
    rw [run, putRun, step_printable t _ hneed hparser (hp i (by omega) (by omega)), hg]
    have ⟨p, c, u⟩ := putChar_fields t (asciiCell g bytes[i]!) hc
    apply ih
    · rw [u]; exact hneed
    · rw [p]; exact hparser
    · simp only [graphics, State.shift1, State.g0, State.g1, c]; exact hg
    · simp only [State.cols, c]; exact hc
    · intro k h1 h2; exact hp k (by omega) (by omega)

theorem asciiRunEnd_spec (bytes : ByteArray) (i : Nat) (hi : i < bytes.size)
    (hpi : printable bytes[i]! = true) :
    i < asciiRunEnd bytes i ∧ asciiRunEnd bytes i ≤ bytes.size ∧
      ∀ k, i ≤ k → k < asciiRunEnd bytes i → printable bytes[k]! = true := by
  unfold asciiRunEnd
  rw [scanWhile_eq]
  obtain ⟨n, hn⟩ : ∃ n, bytes.size - i = n + 1 := ⟨bytes.size - i - 1, by omega⟩
  rw [hn, scanWhile.go, if_pos hpi]
  have ⟨a, b, c⟩ := scanWhile_go_spec printable bytes (i + 1) n
  refine ⟨by omega, by omega, fun k h1 h2 => ?_⟩
  by_cases e : k = i
  · subst e; exact hpi
  · exact c k (by omega) h2

/-- The printable ASCII fast path equals `step` applied to each byte, in
either character set and either insert or replace mode. -/
theorem writeAscii_eq_run (t : State) (bytes : ByteArray) (i j : Nat) (hneed : t.utf8Need = 0)
    (hparser : t.parser = .ground)
    (hcols : 0 < t.cols) (hp : ∀ k, i ≤ k → k < j → printable bytes[k]! = true) :
    writeAscii t bytes (graphics t) i j = run t bytes i (j - i) := by
  unfold writeAscii
  rw [writeAscii_go _ _ _ _ _ _ hcols (Nat.le_refl _),
    run_printable t bytes i _ hneed hparser _ rfl hcols (fun k a b => hp k a (by omega))]

end VerifiedKernel.Terminal
