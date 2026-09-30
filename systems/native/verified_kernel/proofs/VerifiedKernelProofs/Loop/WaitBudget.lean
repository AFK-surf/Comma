import VerifiedKernel.AgentLoop.WaitExtension
import VerifiedKernelProofs.Session.WorkAllocation

/-! # Wait extension budget

`WaitExtension.decide` re-arms an expired `wait_for` while a delegate is busy.
Each extension adds at least one second to `extended_ms`, and `extended_ms`
never passes the ceiling. Thus one wait chain has at most `ceiling / 1000`
extensions. The new deadline is at least one second after the observed time. -/

namespace VerifiedKernel.Session.Loop.Budget
open Data
open VerifiedKernel.Session.WorkConservation
set_option Elab.async false

/-- The runtime reader `WaitExtension.natural`: a non-negative integer field, else zero. -/
abbrev waitNatural : Term → String → Int :=
  native_decl% "VerifiedKernel.AgentLoop.WaitExtension.natural"

/-- The runtime identity `WaitExtension.baseId` that every extension derives from. -/
abbrev waitBaseId : Term → String :=
  native_decl% "VerifiedKernel.AgentLoop.WaitExtension.baseId"

/-- The wait that `decide` builds for an extension of `step` milliseconds. -/
def extendedWait (wait now : Term) (step : Int) : Term :=
  wait
    |>.put (b "wait_id") (b (waitBaseId wait ++ "-x" ++ toString (waitNatural wait "extensions" + 1)))
    |>.put (b "extended_from") (b (waitBaseId wait))
    |>.put (b "deadline_ms") (i (integerValue now + step))
    |>.put (b "extended_ms") (i (waitNatural wait "extended_ms" + step))
    |>.put (b "extensions") (i (waitNatural wait "extensions" + 1))

theorem waitNatural_nonneg (wait : Term) (key : String) : 0 ≤ waitNatural wait key := by
  unfold waitNatural
  unfold_native "VerifiedKernel.AgentLoop.WaitExtension.natural"
  split
  · split <;> omega
  · exact Int.le_refl 0

theorem waitNatural_of_get {wait : Term} {key : String} {n : Int} (h : wait.get (b key) = i n)
    (nonneg : 0 ≤ n) : waitNatural wait key = n := by
  unfold waitNatural
  unfold_native "VerifiedKernel.AgentLoop.WaitExtension.natural"
  rw [h]
  simp [nonneg]

/-- The extension branch of `decide` after the timeout is read. -/
theorem extend_branch {wait busy now ceiling w' : Term} {timeout : Int}
    (h : (if (decide (min timeout (max (integerValue ceiling - waitNatural wait "extended_ms") 0) < 1000) ||
          busy != a "true") = true then a "wake"
        else Term.tuple [a "extend", extendedWait wait now
          (min timeout (max (integerValue ceiling - waitNatural wait "extended_ms") 0))]) =
      .tuple [a "extend", w']) :
    busy = a "true" ∧ ∃ step : Int, 1000 ≤ step ∧ waitNatural wait "extended_ms" + step ≤ integerValue ceiling ∧
      w' = extendedWait wait now step := by
  split at h
  · cases h
  rename_i open_
  simp only [Bool.or_eq_true, decide_eq_true_eq, not_or] at open_
  obtain ⟨large, busy_⟩ := open_
  have busy_ : busy = a "true" := by
    apply atom_beq_true
    cases hs : (busy == a "true") <;> simp_all [bne]
  refine ⟨busy_, _, Int.not_lt.mp large, ?_, ?_⟩
  · have := Int.not_lt.mp large
    omega
  · simp only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] at h
    exact h.symm

/-- The shape of an extension. `decide` extends only a `wait_for` map while a
delegate is busy. The step is at least one second and stays inside the ceiling. -/
theorem decide_extend {wait busy now ceiling w' : Term}
    (h : VerifiedKernel.AgentLoop.WaitExtension.decide wait busy now ceiling = .tuple [a "extend", w']) :
    wait.isMap = true ∧ wait.get (b "source") = b "wait_for" ∧ busy = a "true" ∧
      ∃ step : Int, 1000 ≤ step ∧ waitNatural wait "extended_ms" + step ≤ integerValue ceiling ∧
        w' = extendedWait wait now step := by
  unfold VerifiedKernel.AgentLoop.WaitExtension.decide at h
  by_cases gate : (!wait.isMap || wait.get (b "source") != b "wait_for") = true
  · rw [if_pos gate] at h
    cases h
  rw [if_neg gate] at h
  simp only [Bool.or_eq_true, Bool.not_eq_true', not_or, Bool.not_eq_false] at gate
  obtain ⟨isMap, source⟩ := gate
  have source : wait.get (b "source") = b "wait_for" := by
    apply binary_beq_true
    cases hs : (wait.get (b "source") == b "wait_for") <;> simp_all [bne]
  dsimp only at h
  refine ⟨isMap, source, ?_⟩
  split at h
  · exact extend_branch h
  · exact extend_branch h

theorem put_isMap (v key x : Term) : (v.put key x).isMap = true := by
  cases v <;> rfl

theorem fromUTF8!_toUTF8 (s : String) : String.fromUTF8! s.toUTF8 = s := by
  unfold String.fromUTF8!
  split
  · rfl
  · rename_i invalid
    exact absurd s.isValidUTF8 invalid

theorem toUTF8_isEmpty {s : String} (nonempty : s ≠ "") : s.toUTF8.isEmpty = false := by
  cases h : s.toUTF8.isEmpty
  · rfl
  · exfalso
    apply nonempty
    apply String.toByteArray_inj.mp
    apply ByteArray.ext
    simp only [ByteArray.isEmpty, beq_iff_eq] at h
    have size : s.toByteArray.data.size = 0 := h
    simp [Array.eq_empty_of_size_eq_zero size]

theorem get_put_same_binary (v x : Term) (key : String) : (v.put (b key) x).get (b key) = x := by
  cases v <;> simp [Term.put, Term.get, binary_key_beq]

section ExtendedFields
variable (wait now : Term) (step : Int)

theorem extendedWait_extensions :
    (extendedWait wait now step).get (b "extensions") = i (waitNatural wait "extensions" + 1) := by
  unfold extendedWait
  exact get_put_same_binary _ _ _

theorem extendedWait_extended :
    (extendedWait wait now step).get (b "extended_ms") = i (waitNatural wait "extended_ms" + step) := by
  unfold extendedWait
  rw [get_put_binary_other _ _ (by decide)]
  exact get_put_same_binary _ _ _

theorem extendedWait_deadline :
    (extendedWait wait now step).get (b "deadline_ms") = i (integerValue now + step) := by
  unfold extendedWait
  rw [get_put_binary_other _ _ (by decide), get_put_binary_other _ _ (by decide)]
  exact get_put_same_binary _ _ _

theorem extendedWait_from :
    (extendedWait wait now step).get (b "extended_from") = b (waitBaseId wait) := by
  unfold extendedWait
  rw [get_put_binary_other _ _ (by decide), get_put_binary_other _ _ (by decide),
    get_put_binary_other _ _ (by decide)]
  exact get_put_same_binary _ _ _

theorem extendedWait_source :
    (extendedWait wait now step).get (b "source") = wait.get (b "source") := by
  unfold extendedWait
  rw [get_put_binary_other _ _ (by decide), get_put_binary_other _ _ (by decide),
    get_put_binary_other _ _ (by decide), get_put_binary_other _ _ (by decide),
    get_put_binary_other _ _ (by decide)]

theorem extendedWait_isMap : (extendedWait wait now step).isMap = true := by
  unfold extendedWait
  exact put_isMap _ _ _

theorem extendedWait_base (nonempty : waitBaseId wait ≠ "") :
    waitBaseId (extendedWait wait now step) = waitBaseId wait := by
  unfold waitBaseId
  unfold_native "VerifiedKernel.AgentLoop.WaitExtension.baseId"
  have from_ := extendedWait_from wait now step
  unfold waitBaseId at from_ nonempty
  rw [from_]
  simp only [b, Term.text, toUTF8_isEmpty nonempty, Bool.false_eq_true, ↓reduceIte]
  exact fromUTF8!_toUTF8 _

end ExtendedFields

/-- `wait_extension_budget`: one extension of a `wait_for` wait. The delegate
is busy. `extended_ms` grows by at least one second and stays inside the
ceiling. The new deadline is at least one second after `now`. The extension
count grows by one, and the chain identity is stable. -/
theorem wait_extension_budget {wait busy now ceiling w' : Term}
    (h : VerifiedKernel.AgentLoop.WaitExtension.decide wait busy now ceiling = .tuple [a "extend", w']) :
    wait.get (b "source") = b "wait_for" ∧ busy = a "true" ∧
      w'.isMap = true ∧ w'.get (b "source") = b "wait_for" ∧
      waitNatural w' "extended_ms" ≤ integerValue ceiling ∧
      waitNatural wait "extended_ms" + 1000 ≤ waitNatural w' "extended_ms" ∧
      integerValue now + 1000 ≤ integerValue (w'.get (b "deadline_ms")) ∧
      waitNatural w' "extensions" = waitNatural wait "extensions" + 1 ∧
      w'.get (b "extended_from") = b (waitBaseId wait) ∧
      (waitBaseId wait ≠ "" → waitBaseId w' = waitBaseId wait) := by
  obtain ⟨_, source, busy_, step, large, inside, rfl⟩ := decide_extend h
  have natural := waitNatural_nonneg wait "extended_ms"
  have extended := waitNatural_of_get (extendedWait_extended wait now step) (by omega)
  have count := waitNatural_of_get (extendedWait_extensions wait now step)
    (by have := waitNatural_nonneg wait "extensions"; omega)
  refine ⟨source, busy_, extendedWait_isMap .., by rw [extendedWait_source, source], ?_, ?_, ?_, count,
    extendedWait_from .., fun nonempty => extendedWait_base _ _ _ nonempty⟩
  · omega
  · omega
  · rw [extendedWait_deadline]
    simp only [integerValue]
    omega

/-- A wait chain: each wait is the extension of the one before it. Every
extension decision reads a ceiling of at most `C`. -/
inductive ExtensionChain (C : Int) : Term → Nat → Term → Prop
  | done (wait : Term) : ExtensionChain C wait 0 wait
  | extend {wait next last busy now ceiling : Term} {n : Nat}
      (bounded : integerValue ceiling ≤ C)
      (extended : VerifiedKernel.AgentLoop.WaitExtension.decide wait busy now ceiling =
        .tuple [a "extend", next])
      (rest : ExtensionChain C next n last) : ExtensionChain C wait (n + 1) last

theorem extension_chain_growth {C : Int} {wait last : Term} {n : Nat}
    (chain : ExtensionChain C wait n last) :
    waitNatural wait "extended_ms" + 1000 * n ≤ waitNatural last "extended_ms" ∧
      (0 < n → waitNatural last "extended_ms" ≤ C) := by
  induction chain with
  | done => simp
  | @extend _ _ _ _ _ _ n bounded extended rest ih =>
    obtain ⟨_, _, _, _, inside, grows, _⟩ := wait_extension_budget extended
    refine ⟨?_, fun _ => ?_⟩
    · have := ih.1
      push_cast
      omega
    · cases n with
      | zero =>
        cases rest
        omega
      | succ n => exact ih.2 (by omega)

/-- At most `ceiling / 1000` extensions per wait chain. -/
theorem extensions_bounded {C : Int} {wait last : Term} {n : Nat}
    (chain : ExtensionChain C wait n last) : 1000 * (n : Int) ≤ max C 0 := by
  have ⟨grows, inside⟩ := extension_chain_growth chain
  have start := waitNatural_nonneg wait "extended_ms"
  cases n with
  | zero => omega
  | succ n =>
    have := inside (by omega)
    omega

end VerifiedKernel.Session.Loop.Budget
