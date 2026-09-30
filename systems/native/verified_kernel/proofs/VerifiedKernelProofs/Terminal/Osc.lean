import VerifiedKernelProofs.Terminal.Csi

/-!
# Complete OSC strings

`feed` dispatches an OSC string terminated by BEL or `ESC \` in one step.
`osc_run` shows that the byte state machine dispatches the same text: the
first `maxOscBytes` bytes before the terminator.
-/

namespace VerifiedKernel.Terminal

/-- The state `t` with the OSC parser holding `acc`. -/
abbrev inOsc (t : State) (acc : ByteArray) (esc : Bool) : State :=
  { t with parser := .osc acc esc }

/-- `P` with `bytes[k:k + n]` pushed while it holds fewer than `maxOscBytes`. -/
def pushCap (P : ByteArray) (bytes : ByteArray) (k : Nat) : Nat → ByteArray
  | 0 => P
  | n + 1 => pushCap (if P.size < maxOscBytes then P.push bytes[k]! else P) bytes (k + 1) n

theorem step_osc_open (t : State) (hneed : t.utf8Need = 0) :
    step { t with parser := .escape } 0x5D = inOsc t .empty false := by
  unfold step nonUtf8Byte escape
  simp [hneed]

theorem step_osc_text (t : State) (hneed : t.utf8Need = 0) (hparser : t.parser = .ground)
    (acc : ByteArray) (c : UInt8) (hc : oscStop c = false) :
    step (inOsc t acc false) c =
      inOsc t (if acc.size < maxOscBytes then acc.push c else acc) false := by
  simp only [oscStop, Bool.or_eq_false_iff] at hc
  obtain ⟨⟨⟨h7, h1b⟩, h18⟩, h1a⟩ := hc
  unfold step
  rw [if_pos (show ((inOsc t acc false).utf8Need == 0) = true by simp [hneed])]
  unfold nonUtf8Byte
  simp only [inOsc, h18, h1a, h1b, Bool.false_or, Bool.false_and, Bool.false_eq_true, if_false]
  rw [reset_parser t hparser]
  unfold oscByte
  simp only [h7, h1b, Bool.false_or, Bool.false_and, Bool.false_eq_true, if_false]

theorem step_osc_bel (t : State) (hneed : t.utf8Need = 0) (hparser : t.parser = .ground)
    (acc : ByteArray) : step (inOsc t acc false) 0x07 = oscDispatch t acc := by
  unfold step
  rw [if_pos (show ((inOsc t acc false).utf8Need == 0) = true by simp [hneed])]
  unfold nonUtf8Byte
  dsimp only
  simp only [show ((0x07 : UInt8) == 0x18 || (0x07 : UInt8) == 0x1A) = false from rfl,
    show ((0x07 : UInt8) == 0x1B) = false from rfl, Bool.false_and, Bool.false_eq_true, if_false]
  rw [reset_parser t hparser]
  unfold oscByte
  simp

theorem step_osc_st (t : State) (hneed : t.utf8Need = 0) (hparser : t.parser = .ground)
    (acc : ByteArray) :
    step (step (inOsc t acc false) 0x1B) 0x5C = oscDispatch t acc := by
  have h1 : step (inOsc t acc false) 0x1B = inOsc t acc true := by
    unfold step
    rw [if_pos (show ((inOsc t acc false).utf8Need == 0) = true by simp [hneed])]
    unfold nonUtf8Byte
    simp only [inOsc]
    simp only [show ((0x1B : UInt8) == 0x18 || (0x1B : UInt8) == 0x1A) = false from rfl,
      Bool.false_and, Bool.false_eq_true, if_false]
    simp only [show ((0x1B : UInt8) == 0x1B) = true from rfl, Bool.true_and]
    simp only [Bool.true_or, Bool.not_true, Bool.false_eq_true, if_false]
    rw [reset_parser t hparser]
    unfold oscByte
    simp
  rw [h1]
  unfold step
  rw [if_pos (show ((inOsc t acc true).utf8Need == 0) = true by simp [hneed])]
  unfold nonUtf8Byte
  dsimp only
  simp only [show ((0x5C : UInt8) == 0x18 || (0x5C : UInt8) == 0x1A) = false from rfl,
    show ((0x5C : UInt8) == 0x1B) = false from rfl, Bool.false_and, Bool.false_eq_true, if_false]
  rw [reset_parser t hparser]
  unfold oscByte
  simp

theorem run_osc_text (t : State) (hneed : t.utf8Need = 0) (hparser : t.parser = .ground)
    (bytes : ByteArray) (acc : ByteArray) (k n : Nat)
    (hp : ∀ m, k ≤ m → m < k + n → oscStop bytes[m]! = false) :
    run (inOsc t acc false) bytes k n = inOsc t (pushCap acc bytes k n) false := by
  induction n generalizing acc k with
  | zero => rfl
  | succ n ih =>
    rw [run, step_osc_text t hneed hparser acc _ (hp k (by omega) (by omega)), pushCap]
    exact ih _ _ (fun m a b => hp m (by omega) (by omega))

theorem pushCap_eq (P bytes : ByteArray) (k n : Nat) (hs : P.size ≤ maxOscBytes) :
    pushCap P bytes k n = pushRange P bytes k (min n (maxOscBytes - P.size)) := by
  induction n generalizing P k with
  | zero => simp [pushCap, pushRange]
  | succ n ih =>
    rw [pushCap]
    by_cases h : P.size < maxOscBytes
    · rw [if_pos h, ih _ _ (by rw [ByteArray.size_push]; omega), ByteArray.size_push,
        show min (n + 1) (maxOscBytes - P.size) = min n (maxOscBytes - (P.size + 1)) + 1 by omega,
        pushRange]
    · rw [if_neg h, ih _ _ hs, show maxOscBytes - P.size = 0 by omega, Nat.min_zero, Nat.min_zero]
      rfl

theorem byteArray_ext (a b : ByteArray) (hs : a.size = b.size)
    (h : ∀ i, i < a.size → a[i]! = b[i]!) : a = b := by
  apply ByteArray.ext
  apply Array.ext hs
  intro i h1 h2
  have := h i h1
  rw [getElem!_pos a i h1, getElem!_pos b i (hs ▸ h1)] at this
  exact this

theorem pushRange_extract (bytes : ByteArray) (k n : Nat) (h : k + n ≤ bytes.size) :
    pushRange .empty bytes k n = bytes.extract k (k + n) := by
  apply byteArray_ext
  · rw [size_pushRange, ByteArray.size_extract, ByteArray.size_empty]; omega
  · intro i hi
    rw [size_pushRange, ByteArray.size_empty] at hi
    rw [getElem!_pushRange_empty _ _ _ _ (by omega)]
    have hi' : i < (bytes.extract k (k + n)).size := by rw [ByteArray.size_extract]; omega
    rw [getElem!_pos (bytes.extract k (k + n)) i hi', ByteArray.getElem_extract,
      getElem!_pos bytes (k + i) (by omega)]

theorem skipOscText_go (bytes : ByteArray) (k n : Nat) :
    k ≤ scanWhile.go (fun c => !oscStop c) bytes k n ∧ scanWhile.go (fun c => !oscStop c) bytes k n ≤ k + n ∧
      ∀ m, k ≤ m → m < scanWhile.go (fun c => !oscStop c) bytes k n → oscStop bytes[m]! = false := by
  have ⟨a, b, c⟩ := scanWhile_go_spec (fun c => !oscStop c) bytes k n
  exact ⟨a, b, fun m h1 h2 => by simpa using c m h1 h2⟩

/-- The OSC fast path: a complete string found by `scanOsc` is dispatched as the
byte state machine dispatches it. -/
theorem osc_run (t : State) (hneed : t.utf8Need = 0) (hparser : t.parser = .ground)
    (bytes : ByteArray) (i : Nat) (hesc : bytes[i]! = 0x1B) (hbr : bytes[i + 1]! = 0x5D)
    (hi : i + 2 ≤ bytes.size) (hnext : scanOsc bytes (i + 2) ≠ 0) :
    run t bytes i (scanOsc bytes (i + 2) - i) = oscFast t bytes (i + 2) := by
  have ⟨mge, mle, mspec⟩ := skipOscText_go bytes (i + 2) (bytes.size - (i + 2))
  have hm : skipOscText bytes (i + 2) = scanWhile.go (fun c => !oscStop c) bytes (i + 2) (bytes.size - (i + 2)) := scanWhile_eq _ _ _
  generalize scanWhile.go (fun c => !oscStop c) bytes (i + 2) (bytes.size - (i + 2)) = m at mge mle mspec hm
  -- The text, capped, is what `oscFast` extracts.
  have hacc : pushCap .empty bytes (i + 2) (m - (i + 2)) =
      bytes.extract (i + 2) (min m (i + 2 + maxOscBytes)) := by
    rw [pushCap_eq _ _ _ _ (by simp [ByteArray.size_empty, maxOscBytes]), ByteArray.size_empty,
      Nat.sub_zero, pushRange_extract _ _ _ (by omega)]
    congr 1; omega
  have hopen : run t bytes i (2 + (m - (i + 2))) = inOsc t (pushCap .empty bytes (i + 2) (m - (i + 2))) false := by
    rw [run_add, run, run, run, hesc, hbr, step_esc t hneed hparser, step_osc_open t hneed,
      run_osc_text t hneed hparser bytes _ _ _ (fun j a b => mspec j a (by omega))]
  unfold oscFast
  rw [hm, ← hacc]
  unfold scanOsc at hnext ⊢
  rw [hm] at hnext ⊢
  dsimp only at hnext ⊢
  split at hnext
  · rename_i hb
    simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at hb
    rw [if_pos (by simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq]; exact hb),
      show m + 1 - i = (2 + (m - (i + 2))) + 1 by omega, run_add,
      hopen, run, run, show i + (2 + (m - (i + 2))) = m by omega, hb.2,
      step_osc_bel t hneed hparser]
  · rename_i hb
    split at hnext
    · rename_i hc
      simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at hc
      rw [if_neg hb, if_pos (by simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq]; exact hc),
        show m + 2 - i = (2 + (m - (i + 2))) + 2 by omega, run_add, hopen, run, run, run,
        show i + (2 + (m - (i + 2))) = m by omega, hc.1.2, hc.2, step_osc_st t hneed hparser]
    · exact absurd rfl hnext

end VerifiedKernel.Terminal
