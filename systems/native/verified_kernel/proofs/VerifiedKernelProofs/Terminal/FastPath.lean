import VerifiedKernelProofs.Terminal.Csi
import VerifiedKernelProofs.Terminal.Osc
import VerifiedKernelProofs.Terminal.Tab
import VerifiedKernelProofs.Terminal.Utf8

/-!
# The fast paths in `feed` are exact

`feed` handles line ends, tabs, printable ASCII runs in either character set,
complete CSI sequences, complete OSC strings and complete UTF-8 sequences
without the byte state machine. `feed_eq_foldl`
states that it still computes exactly `step` applied to each byte, for every
state that satisfies `Good`, and `Host.good` shows that every state the host
holds does.
-/

namespace VerifiedKernel.Terminal

theorem good_run (t : State) (bytes : ByteArray) (i n : Nat) (g : Good t) :
    Good (run t bytes i n) := by
  induction n generalizing t i with
  | zero => exact g
  | succ n ih => exact ih _ _ (good_step t _ g)

theorem scanCsi_bounds (bytes : ByteArray) (k : Nat) (h : (scanCsi bytes k).next ≠ 0) :
    k < (scanCsi bytes k).next ∧ (scanCsi bytes k).next ≤ bytes.size := by
  unfold scanCsi at h ⊢
  dsimp only at h ⊢
  generalize (if k < bytes.size then bytes[k]! else 0) = c at h ⊢
  generalize hps : (if (c == 0x3C || c == 0x3D || c == 0x3E || c == 0x3F) = true then k + 1 else k) = ps
    at h ⊢
  have hkps : k ≤ ps := by subst hps; split <;> omega
  have ⟨pe_ge, _⟩ := skipParams_go bytes ps (bytes.size - ps)
  have hpe' : skipParams bytes ps = scanWhile.go paramByte bytes ps (bytes.size - ps) := scanWhile_eq _ _ _
  rw [hpe'] at h ⊢
  generalize scanWhile.go paramByte bytes ps (bytes.size - ps) = pe at pe_ge h ⊢
  have ⟨ie_ge, _⟩ := skipIntermediates_go bytes pe (bytes.size - pe)
  have hie' : skipIntermediates bytes pe = scanWhile.go intermediateByte bytes pe (bytes.size - pe) := scanWhile_eq _ _ _
  rw [hie'] at h ⊢
  generalize scanWhile.go intermediateByte bytes pe (bytes.size - pe) = ie at ie_ge h ⊢
  split at h
  · rename_i hc
    rw [if_pos hc]
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hc
    omega
  · exact absurd rfl h

theorem utf8_case_bounds (bytes : ByteArray) (i need : Nat) (lead : UInt32) (hn4 : need < 4)
    (hd : (if (need == 0 || decide (i + need ≥ bytes.size)) = true then (0 : UInt64) else
      if (continuation bytes lead (i + 1) need != 0xFFFFFFFF &&
          validCodePoint (continuation bytes lead (i + 1) need) (need + 1)) = true then
        ((continuation bytes lead (i + 1) need).toUInt64 <<< 8) ||| (need + 1).toUInt64
      else 0) ≠ 0) :
    2 ≤ ((if (need == 0 || decide (i + need ≥ bytes.size)) = true then (0 : UInt64) else
      if (continuation bytes lead (i + 1) need != 0xFFFFFFFF &&
          validCodePoint (continuation bytes lead (i + 1) need) (need + 1)) = true then
        ((continuation bytes lead (i + 1) need).toUInt64 <<< 8) ||| (need + 1).toUInt64
      else 0) &&& 0xFF).toNat ∧
    i + ((if (need == 0 || decide (i + need ≥ bytes.size)) = true then (0 : UInt64) else
      if (continuation bytes lead (i + 1) need != 0xFFFFFFFF &&
          validCodePoint (continuation bytes lead (i + 1) need) (need + 1)) = true then
        ((continuation bytes lead (i + 1) need).toUInt64 <<< 8) ||| (need + 1).toUInt64
      else 0) &&& 0xFF).toNat ≤ bytes.size := by
  split at hd
  · exact absurd rfl hd
  rename_i h1
  rw [if_neg h1]
  simp only [Bool.or_eq_true, beq_iff_eq, decide_eq_true_eq, not_or] at h1
  split at hd
  · rename_i h2
    rw [if_pos h2, (unpack _ (need + 1) (by omega)).2]
    omega
  · exact absurd rfl hd

theorem scanUtf8_bounds (bytes : ByteArray) (i : Nat) (hd : scanUtf8 bytes i ≠ 0) :
    2 ≤ (scanUtf8 bytes i &&& 0xFF).toNat ∧ i + (scanUtf8 bytes i &&& 0xFF).toNat ≤ bytes.size := by
  unfold scanUtf8 at hd ⊢
  dsimp only at hd ⊢
  generalize bytes[i]! = c at hd ⊢
  by_cases r1 : (0xC2 ≤ c && c ≤ 0xDF) = true
  · simp only [r1, if_true, Nat.reduceBEq, Bool.false_eq_true, if_false] at hd ⊢
    exact utf8_case_bounds bytes i 1 _ (by omega) hd
  simp only [r1, Bool.false_eq_true, if_false] at hd ⊢
  by_cases r2 : (0xE0 ≤ c && c ≤ 0xEF) = true
  · simp only [r2, if_true, Nat.reduceBEq, Bool.false_eq_true, if_false] at hd ⊢
    exact utf8_case_bounds bytes i 2 _ (by omega) hd
  simp only [r2, Bool.false_eq_true, if_false] at hd ⊢
  by_cases r3 : (0xF0 ≤ c && c ≤ 0xF4) = true
  · simp only [r3, if_true, Nat.reduceBEq, Bool.false_eq_true, if_false] at hd ⊢
    exact utf8_case_bounds bytes i 3 _ (by omega) hd
  simp only [r3, Bool.false_eq_true, if_false] at hd
  exact absurd rfl hd

theorem step_cr (t : State) (hneed : t.utf8Need = 0) (hparser : t.parser = .ground) :
    step t 0x0D = carriageReturn t := by
  unfold step nonUtf8Byte groundByte control
  simp [hneed, hparser]

theorem step_lf (t : State) (hneed : t.utf8Need = 0) (hparser : t.parser = .ground) :
    step t 0x0A = index t := by
  unfold step nonUtf8Byte groundByte control
  simp [hneed, hparser]

theorem step_tab (t : State) (hneed : t.utf8Need = 0) (hparser : t.parser = .ground) :
    step t 0x09 = tabFast t := by
  rw [tabFast_eq]
  unfold step nonUtf8Byte groundByte control
  simp [hneed, hparser]

theorem scanOsc_bounds (bytes : ByteArray) (k : Nat) (h : scanOsc bytes k ≠ 0) :
    k < scanOsc bytes k ∧ scanOsc bytes k ≤ bytes.size := by
  have ⟨mge, _, _⟩ := skipOscText_go bytes k (bytes.size - k)
  unfold scanOsc at h ⊢
  have hm : skipOscText bytes k = scanWhile.go (fun c => !oscStop c) bytes k (bytes.size - k) := scanWhile_eq _ _ _
  rw [hm] at h ⊢
  dsimp only at h ⊢
  generalize scanWhile.go (fun c => !oscStop c) bytes k (bytes.size - k) = m at mge h ⊢
  split at h
  · rename_i hb
    rw [if_pos hb]
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hb
    omega
  · rename_i hb
    split at h
    · rename_i hc
      rw [if_neg hb, if_pos hc]
      simp only [Bool.and_eq_true, decide_eq_true_eq] at hc
      omega
    · exact absurd rfl h

/-- One iteration of `feed` equals `step` over the bytes it consumed. -/
theorem feed_go (bytes : ByteArray) (t : State) (i fuel : Nat) (g : Good t)
    (hfuel : bytes.size - i ≤ fuel) :
    feed.go bytes t i fuel = run t bytes i (bytes.size - i) := by
  induction fuel generalizing t i with
  | zero => rw [feed.go, show bytes.size - i = 0 by omega]; rfl
  | succ fuel ih =>
    rw [feed.go]
    by_cases hi : i ≥ bytes.size
    · rw [if_pos hi, show bytes.size - i = 0 by omega]; rfl
    rw [if_neg hi]
    -- Consuming `k ≥ 1` bytes that equal `run`, then continuing.
    have cont : ∀ (s : State) (k : Nat), 1 ≤ k → i + k ≤ bytes.size → run t bytes i k = s →
        feed.go bytes s (i + k) fuel = run t bytes i (bytes.size - i) := by
      intro s k hk hks hs
      rw [ih _ _ (hs ▸ good_run t bytes i k g) (by omega), ← hs, ← run_add]
      congr 1; omega
    have generic : feed.go bytes (step t bytes[i]!) (i + 1) fuel = run t bytes i (bytes.size - i) :=
      cont _ 1 (Nat.le_refl 1) (by omega) rfl
    dsimp only
    -- Outside ground state, or with a UTF-8 sequence pending, every byte goes through `step`.
    cases hp : t.parser
    all_goals try (simp only [Bool.and_false, Bool.not_false, if_true]; exact generic)
    by_cases hn' : t.utf8Need ≠ 0
    · have : (t.utf8Need == 0) = false := by simp [hn']
      simp only [this, Bool.false_and, Bool.not_false, if_true]
      exact generic
    have hn : t.utf8Need = 0 := by omega
    have hcp := (g.2 hn).1
    have hseen := (g.2 hn).2
    simp only [hn, beq_self_eq_true, Bool.true_and, Bool.not_true, Bool.false_eq_true, if_false]
    split
    · -- C0 controls.
      rename_i hlt
      split
      · rename_i h
        simp only [beq_iff_eq] at h
        exact cont _ 1 (Nat.le_refl 1) (by omega) (by rw [run, run, h, step_cr t hn hp])
      split
      · rename_i h
        simp only [beq_iff_eq] at h
        exact cont _ 1 (Nat.le_refl 1) (by omega) (by rw [run, run, h, step_lf t hn hp])
      split
      · rename_i h
        simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at h
        obtain ⟨hesc, hlt2⟩ := h
        split
        · -- A CSI sequence.
          rename_i hbr
          simp only [beq_iff_eq] at hbr
          split
          · exact generic
          rename_i hnext
          simp only [beq_iff_eq] at hnext
          have ⟨hlo, hhi⟩ := scanCsi_bounds bytes (i + 2) hnext
          have hrun := csi_run t hn hp bytes i hesc hbr hnext
          have := cont _ ((scanCsi bytes (i + 2)).next - i) (by omega) (by omega) hrun
          rw [show i + ((scanCsi bytes (i + 2)).next - i) = (scanCsi bytes (i + 2)).next by omega]
            at this
          split
          · rename_i hsgr
            simp only [Bool.and_eq_true, beq_iff_eq, Bool.not_eq_true'] at hsgr
            obtain ⟨⟨hf, hpriv⟩, hint⟩ := hsgr
            rw [hf, hpriv, hint, dispatchCsi_sgr] at this
            exact this
          · exact this
        split
        · -- An OSC string.
          rename_i hbr
          simp only [beq_iff_eq] at hbr
          split
          · exact generic
          rename_i hnext
          simp only [beq_iff_eq] at hnext
          have ⟨hlo, hhi⟩ := scanOsc_bounds bytes (i + 2) hnext
          have := cont _ (scanOsc bytes (i + 2) - i) (by omega) (by omega)
            (osc_run t hn hp bytes i hesc hbr (by omega) hnext)
          rw [show i + (scanOsc bytes (i + 2) - i) = scanOsc bytes (i + 2) by omega] at this
          exact this
        · exact generic
      split
      · -- A tab.
        rename_i h
        simp only [beq_iff_eq] at h
        exact cont _ 1 (Nat.le_refl 1) (by omega) (by rw [run, run, h, step_tab t hn hp])
      · exact generic
    split
    · -- A printable ASCII run.
      rename_i hge hlt
      have hpr : printable bytes[i]! = true := by
        simp only [printable, Bool.and_eq_true, decide_eq_true_eq]
        exact ⟨by simp only [UInt8.lt_iff_toNat_lt, UInt8.le_iff_toNat_le, UInt8.reduceToNat] at hge ⊢; omega, hlt⟩
      have ⟨hij, hjs, hall⟩ := asciiRunEnd_spec bytes i (by omega) hpr
      have := cont (writeAscii t bytes (graphics t) i (asciiRunEnd bytes i)) (asciiRunEnd bytes i - i)
        (by omega) (by omega) (writeAscii_eq_run t bytes i _ hn hp g.1 hall).symm
      rw [show i + (asciiRunEnd bytes i - i) = asciiRunEnd bytes i by omega] at this
      exact this
    split
    · -- A UTF-8 sequence.
      rename_i h
      have hc2 : 0xC2 ≤ bytes[i]!.toNat := by
        simp only [ge_iff_le, UInt8.le_iff_toNat_le, UInt8.reduceToNat] at h
        exact h
      split
      · exact generic
      rename_i hd
      simp only [beq_iff_eq] at hd
      have ⟨hlo, hhi⟩ := scanUtf8_bounds bytes i hd
      exact cont _ _ (by omega) hhi (utf8_run t hcp hn hseen hp bytes i hc2 hd)
    · exact generic

theorem byte_get (bytes : ByteArray) (i : Nat) (h : i < bytes.size) :
    bytes[i]! = bytes.data.toList[i]'(by simpa using h) := by
  rw [getElem!_pos bytes i h]
  simp only [Array.getElem_toList]
  rfl

theorem run_eq_foldl_drop (t : State) (bytes : ByteArray) (i : Nat) (hi : i ≤ bytes.size) :
    run t bytes i (bytes.size - i) = (bytes.data.toList.drop i).foldl step t := by
  generalize hn : bytes.size - i = n
  induction n generalizing t i with
  | zero =>
    rw [List.drop_eq_nil_of_le (by simp; change bytes.size ≤ i; omega)]
    rfl
  | succ n ih =>
    have hlt : i < bytes.data.toList.length := by simp; change i < bytes.size; omega
    rw [run, List.drop_eq_getElem_cons hlt, List.foldl_cons, ← byte_get bytes i (by simpa using hlt)]
    exact ih _ _ (by omega) (by omega)

/-- `feed` computes `step` applied to each byte. -/
theorem feed_eq_foldl (t : State) (bytes : ByteArray) (g : Good t) :
    feed t bytes = bytes.data.foldl step t := by
  unfold feed
  rw [feed_go bytes t 0 bytes.size g (by omega), run_eq_foldl_drop t bytes 0 (Nat.zero_le _),
    List.drop_zero, Array.foldl_toList]

theorem good_feed (t : State) (bytes : ByteArray) (g : Good t) : Good (feed t bytes) := by
  unfold feed
  rw [feed_go bytes t 0 bytes.size g (by omega)]
  exact good_run t bytes 0 _ g

/-- The states the host can hold: made by `exportNew`, and changed only by
`exportFeed` and `exportResize`. -/
inductive Host : State → Prop
  | new (cols rows : UInt32) : Host (exportNew cols rows)
  | feed (t : State) (bytes : ByteArray) : Host t → Host (exportFeed t bytes).1
  | resize (t : State) (cols rows : UInt32) : Host t → Host (exportResize t cols rows)

theorem Host.good {t : State} (h : Host t) : Good t := by
  induction h with
  | new cols rows => exact good_new _ _
  | feed t bytes _ ih => exact good_clearReplies _ (good_feed t bytes ih)
  | resize t cols rows _ ih => exact good_resize t _ _ ih

/-- For every state the host holds, the fast paths are exact: `feed` equals
`step` applied to each byte. -/
theorem host_feed_eq_foldl (t : State) (bytes : ByteArray) (h : Host t) :
    feed t bytes = bytes.data.foldl step t :=
  feed_eq_foldl t bytes h.good

end VerifiedKernel.Terminal
