import VerifiedKernelProofs.Terminal.Ascii

/-!
# Complete CSI sequences

`feed` parses a complete CSI sequence straight from the input.
`csi_run` shows that the byte state machine reaches the same dispatch.
-/

namespace VerifiedKernel.Terminal

/-- The state `t` with the CSI parser holding `priv`, `params` and `inter`. -/
abbrev inCsi (t : State) (priv : UInt8) (params inter : ByteArray) : State :=
  { t with parser := .csi priv params inter }

theorem reset_parser (t : State) (h : t.parser = .ground) :
    ({ t with parser := .ground } : State) = t := by
  cases t; simp_all

theorem byte_ne (c n : UInt8) (h : c.toNat ≠ n.toNat) : (c == n) = false := by
  simp only [beq_eq_false_iff_ne, ne_eq]; intro e; exact h (congrArg UInt8.toNat e)

theorem step_esc (t : State) (hneed : t.utf8Need = 0) (hparser : t.parser = .ground) :
    step t 0x1B = { t with parser := .escape } := by
  unfold step nonUtf8Byte
  simp [hneed, hparser]

theorem step_bracket (t : State) (hneed : t.utf8Need = 0) :
    step { t with parser := .escape } 0x5B = inCsi t 0 .empty .empty := by
  unfold step nonUtf8Byte escape
  simp [hneed]

/-- A byte the CSI parser treats as data: not a control, CAN, SUB or ESC. -/
theorem step_inCsi (t : State) (hneed : t.utf8Need = 0) (hparser : t.parser = .ground)
    (priv : UInt8) (P I : ByteArray) (c : UInt8) (hc : 0x20 ≤ c.toNat) :
    step (inCsi t priv P I) c = csiByte t priv P I c := by
  have n18 := byte_ne c 0x18 (by simp; omega)
  have n1a := byte_ne c 0x1A (by simp; omega)
  have n1b := byte_ne c 0x1B (by simp; omega)
  unfold step
  rw [if_pos (show ((inCsi t priv P I).utf8Need == 0) = true by simp [hneed])]
  unfold nonUtf8Byte
  simp only [n18, n1a, n1b, Bool.false_or, Bool.false_and, Bool.false_eq_true, if_false]
  rw [reset_parser t hparser]

theorem csiByte_marker (t : State) (c : UInt8) (hc : 0x3C ≤ c.toNat ∧ c.toNat ≤ 0x3F) :
    csiByte t 0 .empty .empty c = inCsi t c .empty .empty := by
  have n20 : ¬(c < 0x20) := by simp only [UInt8.lt_iff_toNat_lt, UInt8.reduceToNat]; omega
  have m : (c == 0x3C || c == 0x3D || c == 0x3E || c == 0x3F) = true := by
    simp only [Bool.or_eq_true, beq_iff_eq, ← UInt8.toNat_inj, UInt8.reduceToNat]; omega
  unfold csiByte
  simp [n20, m]

theorem csiByte_param (t : State) (priv : UInt8) (P I : ByteArray) (c : UInt8)
    (hc : paramByte c = true) (hs : P.size < maxParamBytes) :
    csiByte t priv P I c = inCsi t priv (P.push c) I := by
  have hc' : (0x30 ≤ c.toNat ∧ c.toNat ≤ 0x39) ∨ c.toNat = 0x3B ∨ c.toNat = 0x3A := by
    simp only [paramByte, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq,
      UInt8.le_iff_toNat_le, ← UInt8.toNat_inj, UInt8.reduceToNat] at hc
    omega
  have n20 : ¬(c < 0x20) := by simp only [UInt8.lt_iff_toNat_lt, UInt8.reduceToNat]; omega
  have nm : (c == 0x3C || c == 0x3D || c == 0x3E || c == 0x3F) = false := by
    simp only [Bool.or_eq_false_iff, beq_eq_false_iff_ne, ne_eq, ← UInt8.toNat_inj,
      UInt8.reduceToNat]; omega
  have hp : ((0x30 ≤ c && c ≤ 0x39) || c == 0x3B || c == 0x3A) = true := hc
  unfold csiByte
  simp only [n20, if_false, nm, Bool.false_and, Bool.false_eq_true, hp, if_true, hs]

theorem csiByte_inter (t : State) (priv : UInt8) (P I : ByteArray) (c : UInt8)
    (hc : intermediateByte c = true) :
    csiByte t priv P I c = inCsi t priv P (I.push c) := by
  have hc' : 0x20 ≤ c.toNat ∧ c.toNat ≤ 0x2F := by
    simp only [intermediateByte, Bool.and_eq_true, decide_eq_true_eq, UInt8.le_iff_toNat_le,
      UInt8.reduceToNat] at hc
    omega
  have n20 : ¬(c < 0x20) := by simp only [UInt8.lt_iff_toNat_lt, UInt8.reduceToNat]; omega
  have nm : (c == 0x3C || c == 0x3D || c == 0x3E || c == 0x3F) = false := by
    simp only [Bool.or_eq_false_iff, beq_eq_false_iff_ne, ne_eq, ← UInt8.toNat_inj,
      UInt8.reduceToNat]; omega
  have np : ((0x30 ≤ c && c ≤ 0x39) || c == 0x3B || c == 0x3A) = false := by
    simp only [Bool.or_eq_false_iff, Bool.and_eq_false_iff, decide_eq_false_iff_not,
      beq_eq_false_iff_ne, ne_eq, UInt8.le_iff_toNat_le, ← UInt8.toNat_inj, UInt8.reduceToNat]
    omega
  have hi : (0x20 ≤ c && c ≤ 0x2F) = true := hc
  unfold csiByte
  simp only [n20, if_false, nm, Bool.false_and, Bool.false_eq_true, np, hi, if_true]

theorem csiByte_final (t : State) (priv : UInt8) (P I : ByteArray) (c : UInt8)
    (hc : 0x40 ≤ c.toNat ∧ c.toNat ≤ 0x7E) :
    csiByte t priv P I c = dispatchCsi t priv (parseParams P 0 P.size) (I.size != 0) c := by
  have n20 : ¬(c < 0x20) := by simp only [UInt8.lt_iff_toNat_lt, UInt8.reduceToNat]; omega
  have nm : (c == 0x3C || c == 0x3D || c == 0x3E || c == 0x3F) = false := by
    simp only [Bool.or_eq_false_iff, beq_eq_false_iff_ne, ne_eq, ← UInt8.toNat_inj,
      UInt8.reduceToNat]; omega
  have np : ((0x30 ≤ c && c ≤ 0x39) || c == 0x3B || c == 0x3A) = false := by
    simp only [Bool.or_eq_false_iff, Bool.and_eq_false_iff, decide_eq_false_iff_not,
      beq_eq_false_iff_ne, ne_eq, UInt8.le_iff_toNat_le, ← UInt8.toNat_inj, UInt8.reduceToNat]
    omega
  have ni : (0x20 ≤ c && c ≤ 0x2F) = false := by
    simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, UInt8.le_iff_toNat_le,
      UInt8.reduceToNat]; omega
  have hf : 0x40 ≤ c ∧ c ≤ 0x7E := by
    simp only [UInt8.le_iff_toNat_le, UInt8.reduceToNat]; omega
  unfold csiByte
  simp only [n20, if_false, nm, Bool.false_and, Bool.false_eq_true, np, ni, hf, if_true,
    decide_true, Bool.and_self]

/-! ### Runs of parameter and intermediate bytes -/

/-- `P` with `bytes[k:k + n]` pushed. -/
def pushRange (P : ByteArray) (bytes : ByteArray) (k : Nat) : Nat → ByteArray
  | 0 => P
  | n + 1 => pushRange (P.push bytes[k]!) bytes (k + 1) n

theorem size_pushRange (P bytes : ByteArray) (k n : Nat) :
    (pushRange P bytes k n).size = P.size + n := by
  induction n generalizing P k with
  | zero => rfl
  | succ n ih => rw [pushRange, ih, ByteArray.size_push]; omega

theorem getElem!_pushRange (P bytes : ByteArray) (k n m : Nat) :
    (pushRange P bytes k n)[m]! = if m < P.size then P[m]!
      else if m < P.size + n then bytes[k + (m - P.size)]! else (pushRange P bytes k n)[m]! := by
  induction n generalizing P k with
  | zero => split <;> simp_all [pushRange] <;> omega
  | succ n ih =>
    rw [pushRange, ih, ByteArray.size_push, ByteArray.getElem!_push]
    by_cases h1 : m < P.size
    · simp [h1, Nat.lt_succ_of_lt h1, Nat.ne_of_lt h1]
    · by_cases h2 : m = P.size
      · subst h2; simp
      · have : ¬m < P.size + 1 := by omega
        simp only [h1, h2, this, if_false]
        by_cases h3 : m < P.size + 1 + n
        · rw [if_pos h3, if_pos (by omega)]; congr 1; omega
        · rw [if_neg h3, if_neg (by omega), ← pushRange]

theorem getElem!_pushRange_empty (bytes : ByteArray) (k n m : Nat) (h : m < n) :
    (pushRange .empty bytes k n)[m]! = bytes[k + m]! := by
  rw [getElem!_pushRange]
  simp [ByteArray.size_empty, h]

theorem run_params (t : State) (hneed : t.utf8Need = 0) (hparser : t.parser = .ground)
    (bytes : ByteArray) (priv : UInt8) (P I : ByteArray) (k n : Nat)
    (hp : ∀ m, k ≤ m → m < k + n → paramByte bytes[m]! = true)
    (hs : P.size + n ≤ maxParamBytes) :
    run (inCsi t priv P I) bytes k n = inCsi t priv (pushRange P bytes k n) I := by
  induction n generalizing P k with
  | zero => rfl
  | succ n ih =>
    have hb := hp k (by omega) (by omega)
    have h20 : 0x20 ≤ bytes[k]!.toNat := by
      simp only [paramByte, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq,
        UInt8.le_iff_toNat_le, ← UInt8.toNat_inj, UInt8.reduceToNat] at hb
      omega
    rw [run, step_inCsi t hneed hparser _ _ _ _ h20, csiByte_param _ _ _ _ _ hb (by omega),
      pushRange]
    exact ih _ _ (fun m a b => hp m (by omega) (by omega)) (by rw [ByteArray.size_push]; omega)

theorem run_inters (t : State) (hneed : t.utf8Need = 0) (hparser : t.parser = .ground)
    (bytes : ByteArray) (priv : UInt8) (P I : ByteArray) (k n : Nat)
    (hp : ∀ m, k ≤ m → m < k + n → intermediateByte bytes[m]! = true) :
    run (inCsi t priv P I) bytes k n = inCsi t priv P (pushRange I bytes k n) := by
  induction n generalizing I k with
  | zero => rfl
  | succ n ih =>
    have hb := hp k (by omega) (by omega)
    have h20 : 0x20 ≤ bytes[k]!.toNat := by
      simp only [intermediateByte, Bool.and_eq_true, decide_eq_true_eq, UInt8.le_iff_toNat_le,
        UInt8.reduceToNat] at hb
      omega
    rw [run, step_inCsi t hneed hparser _ _ _ _ h20, csiByte_inter _ _ _ _ _ hb, pushRange]
    exact ih _ _ (fun m a b => hp m (by omega) (by omega))

theorem parseParams_go_congr (a b : ByteArray) (i j cur : Nat) (out : Array Nat) (n : Nat)
    (h : ∀ m, m < n → a[i + m]! = b[j + m]!) :
    parseParams.go a i cur out n = parseParams.go b j cur out n := by
  induction n generalizing i j cur out with
  | zero => rfl
  | succ n ih =>
    have e := h 0 (by omega)
    simp only [Nat.add_zero] at e
    simp only [parseParams.go, e]
    split <;> exact ih _ _ _ _ (fun m hm => by
      have := h (m + 1) (by omega)
      rw [show i + (m + 1) = i + 1 + m by omega, show j + (m + 1) = j + 1 + m by omega] at this
      exact this)

theorem parseParams_pushRange (bytes : ByteArray) (k n : Nat) :
    parseParams (pushRange .empty bytes k n) 0 (pushRange .empty bytes k n).size =
      parseParams bytes k (k + n) := by
  unfold parseParams
  rw [size_pushRange, ByteArray.size_empty, Nat.zero_add, Nat.sub_zero, Nat.add_sub_cancel_left]
  apply parseParams_go_congr
  intro m hm
  rw [Nat.zero_add, getElem!_pushRange_empty _ _ _ _ hm]

/-! ### The scan -/

theorem skipParams_go (bytes : ByteArray) (k n : Nat) :
    k ≤ scanWhile.go paramByte bytes k n ∧
      ∀ m, k ≤ m → m < scanWhile.go paramByte bytes k n → paramByte bytes[m]! = true :=
  have ⟨a, _, c⟩ := scanWhile_go_spec paramByte bytes k n
  ⟨a, c⟩

theorem skipIntermediates_go (bytes : ByteArray) (k n : Nat) :
    k ≤ scanWhile.go intermediateByte bytes k n ∧
      ∀ m, k ≤ m → m < scanWhile.go intermediateByte bytes k n → intermediateByte bytes[m]! = true :=
  have ⟨a, _, c⟩ := scanWhile_go_spec intermediateByte bytes k n
  ⟨a, c⟩

theorem dispatchCsi_sgr (t : State) (params : Array Nat) : dispatchCsi t 0 params false 0x6D = t := by
  unfold dispatchCsi
  rfl

/-- A complete CSI sequence `ESC [ marker? params inters final` from ground state. -/
theorem csi_shape_run (t : State) (hneed : t.utf8Need = 0) (hparser : t.parser = .ground)
    (bytes : ByteArray) (i : Nat) (priv : UInt8) (ps pe ie : Nat)
    (hesc : bytes[i]! = 0x1B) (hbr : bytes[i + 1]! = 0x5B)
    (hpriv : (priv = 0 ∧ ps = i + 2) ∨
      (ps = i + 3 ∧ bytes[i + 2]! = priv ∧ 0x3C ≤ priv.toNat ∧ priv.toNat ≤ 0x3F))
    (hpe : ps ≤ pe) (hparams : ∀ m, ps ≤ m → m < pe → paramByte bytes[m]! = true)
    (hlen : pe - ps < maxParamBytes)
    (hie : pe ≤ ie) (hinters : ∀ m, pe ≤ m → m < ie → intermediateByte bytes[m]! = true)
    (hfinal : 0x40 ≤ bytes[ie]!.toNat ∧ bytes[ie]!.toNat ≤ 0x7E) :
    run t bytes i (ie + 1 - i) = dispatchCsi t priv (parseParams bytes ps pe) (ie != pe) bytes[ie]! := by
  have hps : i + 2 ≤ ps := by omega
  rw [show ie + 1 - i = 2 + ((ps - (i + 2)) + ((pe - ps) + ((ie - pe) + 1))) by omega,
    run_add, run_add, run_add, run_add]
  -- `ESC [`
  have h2 : run t bytes i 2 = inCsi t 0 .empty .empty := by
    rw [run, run, run, hesc, hbr, step_esc t hneed hparser, step_bracket t hneed]
  rw [h2, show i + 2 + (ps - (i + 2)) = ps by omega]
  -- The private marker.
  have hm : run (inCsi t 0 .empty .empty) bytes (i + 2) (ps - (i + 2)) = inCsi t priv .empty .empty := by
    rcases hpriv with ⟨h0, hs⟩ | ⟨hs, hb, lo, hi⟩
    · subst h0; rw [hs, Nat.sub_self]; rfl
    · rw [hs, show i + 3 - (i + 2) = 1 by omega, run, run, hb]
      rw [step_inCsi t hneed hparser _ _ _ _ (by omega), csiByte_marker t _ ⟨lo, hi⟩]
  rw [hm, run_params t hneed hparser bytes priv .empty .empty ps (pe - ps)
      (fun m a b => hparams m a (by omega)) (by simp [ByteArray.size_empty]; omega),
    show ps + (pe - ps) = pe by omega,
    run_inters t hneed hparser bytes priv _ .empty pe (ie - pe) (fun m a b => hinters m a (by omega)),
    show pe + (ie - pe) = ie by omega]
  rw [run, run]
  rw [step_inCsi t hneed hparser _ _ _ _ (by omega), csiByte_final _ _ _ _ _ hfinal,
    parseParams_pushRange, show ps + (pe - ps) = pe by omega, size_pushRange, ByteArray.size_empty,
    Nat.zero_add]
  have hb : (ie - pe != 0) = (ie != pe) := by
    by_cases h : ie = pe
    · subst h; simp only [Nat.sub_self, bne_self_eq_false]
    · have h1 : (ie - pe != 0) = true := by simp only [bne_iff_ne, ne_eq]; omega
      have h2 : (ie != pe) = true := by simp only [bne_iff_ne, ne_eq]; exact h
      rw [h1, h2]
  rw [hb]

/-- The CSI fast path: a complete sequence found by `scanCsi` is dispatched as
the byte state machine dispatches it. -/
theorem csi_run (t : State) (hneed : t.utf8Need = 0) (hparser : t.parser = .ground)
    (bytes : ByteArray) (i : Nat) (hesc : bytes[i]! = 0x1B) (hbr : bytes[i + 1]! = 0x5B)
    (hnext : (scanCsi bytes (i + 2)).next ≠ 0) :
    run t bytes i ((scanCsi bytes (i + 2)).next - i) =
      dispatchCsi t (scanCsi bytes (i + 2)).priv
        (parseParams bytes (scanCsi bytes (i + 2)).paramStart (scanCsi bytes (i + 2)).paramEnd)
        ((scanCsi bytes (i + 2)).interEnd != (scanCsi bytes (i + 2)).paramEnd)
        bytes[(scanCsi bytes (i + 2)).next - 1]! := by
  unfold scanCsi at hnext ⊢
  dsimp only at hnext ⊢
  generalize hc : (if i + 2 < bytes.size then bytes[i + 2]! else 0) = c at hnext ⊢
  generalize hmk : (c == 0x3C || c == 0x3D || c == 0x3E || c == 0x3F) = mk at hnext ⊢
  generalize hps : (if mk = true then i + 2 + 1 else i + 2) = ps at hnext ⊢
  have ⟨pe_ge, pe_spec⟩ := skipParams_go bytes ps (bytes.size - ps)
  generalize hpe : scanWhile.go paramByte bytes ps (bytes.size - ps) = pe at pe_ge pe_spec
  have hpe' : skipParams bytes ps = pe := by unfold skipParams; rw [scanWhile_eq]; exact hpe
  rw [hpe'] at hnext ⊢
  have ⟨ie_ge, ie_spec⟩ := skipIntermediates_go bytes pe (bytes.size - pe)
  generalize hie : scanWhile.go intermediateByte bytes pe (bytes.size - pe) = ie at ie_ge ie_spec
  have hie' : skipIntermediates bytes pe = ie := by unfold skipIntermediates; rw [scanWhile_eq]; exact hie
  rw [hie'] at hnext ⊢
  split at hnext
  · rename_i hcomplete
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hcomplete
    obtain ⟨⟨⟨hlen, hlt⟩, hlo⟩, hhi⟩ := hcomplete
    rw [if_pos (by simp only [Bool.and_eq_true, decide_eq_true_eq]; exact ⟨⟨⟨hlen, hlt⟩, hlo⟩, hhi⟩),
      Nat.add_sub_cancel]
    apply csi_shape_run t hneed hparser bytes i _ ps pe ie hesc hbr _ pe_ge pe_spec hlen ie_ge
      ie_spec ⟨by simp only [UInt8.le_iff_toNat_le, UInt8.reduceToNat] at hlo; exact hlo,
        by simp only [UInt8.le_iff_toNat_le, UInt8.reduceToNat] at hhi; exact hhi⟩
    cases mk
    · left; subst hps; simp
    · right
      subst hps
      have hm : 0x3C ≤ c.toNat ∧ c.toNat ≤ 0x3F := by
        simp only [Bool.or_eq_true, beq_iff_eq, ← UInt8.toNat_inj, UInt8.reduceToNat] at hmk
        omega
      have hin : i + 2 < bytes.size := by
        rcases Nat.lt_or_ge (i + 2) bytes.size with h | h
        · exact h
        · rw [if_neg (by omega)] at hc
          subst hc
          simp at hm
      rw [if_pos hin] at hc
      exact ⟨by simp, by simp [hc], hm⟩
  · exact absurd rfl hnext

end VerifiedKernel.Terminal
