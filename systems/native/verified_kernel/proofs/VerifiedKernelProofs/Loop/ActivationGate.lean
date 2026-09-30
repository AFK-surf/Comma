import VerifiedKernelProofs.Loop.ActivationChain

/-! # The activation gate of a model round (property C)

The loop hands the session to a model round with `{:materialize, :run}`. This
module proves the kernel checks behind that effect:

* `activation_materialize_run`: the activation step emits `materialize run`
  only when `activation_next` answered `run` or `resume`.
* `activationNext_gate`: `run` needs `has_unprocessed_stable_work?`, and
  `resume` needs an integer retry deadline or `needs_transcript_continuation?`.
* `step_materialize_run`: a loop step ends with `{:materialize, :run}` only
  through the activation helper. The other helpers do not end with that
  effect (`NoRun`).
* `step_materialize_gate`: with the kernel oracle, that step read one of the
  three answers above on the step state.
* `stableWork_guards`, `needsContinuation_guards`, `retryAt_guard`,
  `modelGuard_round`: each of these reads the model guards, and it answers
  `true` (or a deadline) only when the guards that it reads answered `false`.

The guards read their caps as configuration observations. These theorems
state what the evaluation observed. They do not fix the configured values:
with a cap answer of 0 or less, a guard is off. -/

namespace VerifiedKernel.Session.Loop.Gate
open Data
open VerifiedKernel.Session.LoopProof
set_option Elab.async false
set_option maxHeartbeats 1000000

/-- Every successful result of `m` satisfies `P`. -/
def SatA {α : Type} (P : α → Prop) (m : KernelM α) : Prop := ∀ j out j', m j = .ok (out, j') → P out

theorem SatA.bind {α β : Type} {P : β → Prop} {m : KernelM α} {k : α → KernelM β}
    (h : ∀ x j j1, m j = .ok (x, j1) → SatA P (k x)) : SatA P (m >>= k) := by
  intro j out j' run
  obtain ⟨x, j1, first, second⟩ := bind_ok run
  exact h x j j1 first j1 out j' second

theorem SatA.pure {α : Type} {P : α → Prop} {v : α} (h : P v) : SatA P (Pure.pure v) := by
  intro j out j' run
  rw [pure_ok run]; exact h

theorem SatA.fail {α : Type} {P : α → Prop} {kind : String} {args : List Term} : SatA P (fail kind args) := by
  intro j out j' run
  exact (fail_ok run).elim

theorem SatA.ite {α : Type} {P : α → Prop} {c : Prop} [Decidable c] {A B : KernelM α}
    (yes : c → SatA P A) (no : ¬c → SatA P B) : SatA P (if c then A else B) := by
  by_cases h : c
  · rw [if_pos h]; exact yes h
  · rw [if_neg h]; exact no h

theorem SatA.dite {α : Type} {P : α → Prop} {c : Prop} [Decidable c] {A : c → KernelM α} {B : ¬c → KernelM α}
    (yes : ∀ h, SatA P (A h)) (no : ∀ h, SatA P (B h)) : SatA P (if h : c then A h else B h) := by
  by_cases h : c
  · rw [dif_pos h]; exact yes h
  · rw [dif_neg h]; exact no h

open Lean Elab Tactic Meta in
/-- One step of the walk: split a bind, an `if`, or a `match` of a `SatA` goal. -/
elab "sata_step" : tactic => withMainContext do
  let target ← instantiateMVars (← getMainTarget)
  unless target.isAppOf ``SatA do throwError "not a SatA goal"
  let t := target.appArg!.consumeMData.headBeta
  let fn := t.getAppFn.consumeMData
  match fn with
  | .const name _ =>
    if name == ``Bind.bind then evalTactic (← `(tactic| (apply SatA.bind; intro _ _ _ _)))
    else if name == ``Pure.pure then evalTactic (← `(tactic| apply SatA.pure))
    else if name == ``VerifiedKernel.fail then evalTactic (← `(tactic| exact SatA.fail))
    else if name == ``ite then evalTactic (← `(tactic| (apply SatA.ite <;> intro _)))
    else if name == ``dite then evalTactic (← `(tactic| (apply SatA.dite <;> intro _)))
    else if (← isMatcher name) then evalTactic (← `(tactic| split))
    else if name == ``letFun then evalTactic (← `(tactic| dsimp only))
    else throwError "sata_step: unknown head {name}"
  | .letE .. => evalTactic (← `(tactic| dsimp only))
  | _ => throwError "sata_step: unknown shape {t}"

macro "sata_walk" : tactic => `(tactic| repeat' sata_step)

/-- The computation can answer `true`. -/
def Holds (m : KernelM Bool) : Prop := ∃ j j', m j = .ok (true, j')

/-- The computation can answer `false`. -/
def Fails (m : KernelM Bool) : Prop := ∃ j j', m j = .ok (false, j')

theorem SatA.self_fails {m : KernelM Bool} : SatA (fun v => v = false → Fails m) m := by
  intro j out j' run h
  subst h
  exact ⟨j, j', run⟩

theorem SatA.mono {α : Type} {P Q : α → Prop} {m : KernelM α} (h : SatA P m) (imp : ∀ v, P v → Q v) :
    SatA Q m := fun j out j' run => imp out (h j out j' run)

theorem SatA.const {α : Type} {m : KernelM α} {P : α → Prop} (q : ∀ v, P v) : SatA P m := by
  intro j out j' run
  exact q out

theorem fails_or {m : KernelM Bool} {x y : Bool} {j j' : List Term} (run : m j = .ok (x, j'))
    (h : ¬ (x || y) = true) : Fails m := by
  cases x
  · exact ⟨j, j', run⟩
  · simp at h

theorem fails_not {m : KernelM Bool} {x : Bool} {j j' : List Term} (run : m j = .ok (x, j'))
    (h : ¬ x = true) : Fails m := by
  cases x
  · exact ⟨j, j', run⟩
  · simp at h

theorem or_false_left {x y : Bool} (h : ¬ (x || y) = true) : x = false := by
  cases x <;> simp_all

/-! ## The guards -/

/-- `model_guard_exhausted?` answers `false` only after the round budget
check answered `false`. -/
theorem modelGuard_round {s : Term} :
    SatA (fun v => v = false → Fails (StateQuery.roundBudgetExhausted s)) (StateQuery.modelGuardExhausted s) := by
  unfold StateQuery.modelGuardExhausted
  sata_walk
  all_goals first
    | exact SatA.self_fails
    | (intro h; cases h; done)

/-- `has_unprocessed_stable_work?` answers `true` only after the failure cap
and the model guards answered `false`. -/
theorem stableWork_guards {s : Term} :
    SatA (fun v => v = true → Fails (StateQuery.failuresExhausted s) ∧ Fails (StateQuery.modelGuardExhausted s))
      (StateQuery.hasUnprocessedStableWork s) := by
  unfold StateQuery.hasUnprocessedStableWork
  sata_walk
  all_goals first
    | (intro h; cases h; done)
    | (intro _
       exact ⟨fails_or ‹StateQuery.failuresExhausted s _ = _› ‹_›,
         fails_not ‹StateQuery.modelGuardExhausted s _ = _› ‹_›⟩)
    | (refine SatA.const (fun _ _ => ?_)
       exact ⟨fails_or ‹StateQuery.failuresExhausted s _ = _› ‹_›,
         fails_not ‹StateQuery.modelGuardExhausted s _ = _› ‹_›⟩)

theorem continuationRunnable_guards {s : Term} :
    SatA (fun v => v = true → Fails (StateQuery.failuresExhausted s) ∧ Fails (StateQuery.modelGuardExhausted s))
      (StateQuery.continuationRunnable s) := by
  unfold StateQuery.continuationRunnable
  sata_walk
  all_goals first
    | (intro h; cases h; done)
    | (intro _
       exact ⟨fails_or ‹StateQuery.failuresExhausted s _ = _› ‹_›,
         fails_not ‹StateQuery.modelGuardExhausted s _ = _› ‹_›⟩)

/-- `needs_transcript_continuation?` answers `true` only through
`continuation_runnable?`, which reads the failure cap and the model guards. -/
theorem needsContinuation_guards {s : Term} :
    SatA (fun v => v = true → Fails (StateQuery.failuresExhausted s) ∧ Fails (StateQuery.modelGuardExhausted s))
      (StateQuery.needsContinuation s) := by
  unfold StateQuery.needsContinuation
  sata_walk
  all_goals first
    | (intro h; cases h; done)
    | exact continuationRunnable_guards

/-- An integer retry deadline needs a failure cap that answered `false`. -/
theorem retryAt_guard {s : Term} :
    SatA (fun d => d.isInteger = true → Fails (StateQuery.failuresExhausted s)) (StateQuery.retryAt s) := by
  unfold StateQuery.retryAt
  sata_walk
  all_goals first
    | (intro h; simp [nil, Term.isInteger] at h; done)
    | (intro _; exact fails_or ‹StateQuery.failuresExhausted s _ = _› ‹_›)

/-! ## The activation decision -/

/-- What `activation_next` needs for `run` and `resume`. -/
def GateOut (s v : Term) : Prop :=
  (v = a "run" → Holds (StateQuery.hasUnprocessedStableWork s)) ∧
  (v = a "resume" → (∃ d j j', StateQuery.retryAt s j = .ok (d, j') ∧ d.isInteger = true) ∨
    Holds (StateQuery.needsContinuation s))

/-- `activationNext_gate`: `activation_next` answers `run` only after
`has_unprocessed_stable_work?` answered `true`, and `resume` only after an
integer retry deadline or `needs_transcript_continuation?` answered `true`. -/
theorem activationNext_gate {s r : Term} : SatA (GateOut s) (Budget.activationNextN s r) := by
  unfold Budget.activationNextN
  unfold_native "VerifiedKernel.Session.Command.activationNext"
  sata_walk
  all_goals
    subst_vars
    refine ⟨fun h => ?_, fun h => ?_⟩
  all_goals first
    | (simp [a] at h; done)
    | exact ⟨_, _, ‹StateQuery.hasUnprocessedStableWork s _ = _›⟩
    | exact Or.inr ⟨_, _, ‹StateQuery.needsContinuation s _ = _›⟩
    | exact Or.inl ⟨_, _, _, ‹StateQuery.retryAt s _ = _›, ‹_›⟩

/-! ## The loop's activation helper -/

/-- The effect that hands the session to a model round. -/
def materializeRun : Term := .tuple [a "materialize", a "run"]

theorem expire_no_run {state m busy : Term} :
    SatA (fun out => (Budget.outEffects out).getLast? ≠ some materializeRun) (Budget.expireN state m busy) := by
  unfold Budget.expireN
  unfold_native "VerifiedKernel.Session.Loop.expire"
  sata_walk
  all_goals (loop_unfold; simp [Budget.outEffects_tuple, materializeRun, a])

theorem expireEntry_no_run {state m : Term} :
    SatA (fun out => (Budget.outEffects out).getLast? ≠ some materializeRun) (Budget.expireEntryN state m) := by
  unfold Budget.expireEntryN
  unfold_native "VerifiedKernel.Session.Loop.expireEntry"
  sata_walk
  · loop_unfold; simp [Budget.outEffects_tuple, materializeRun, a]
  · exact expire_no_run

/-- `activation_materialize_run`: the activation helper of the loop ends with
`{:materialize, :run}` only when `activation_next` answered `run` or
`resume` for the Router fact of the machine. -/
theorem activation_materialize_run {ask : Loop.Ask} {state m : Term} :
    SatA (fun out => (Budget.outEffects out).getLast? = some materializeRun →
        ∃ v, Returns (ask state "activation_next" (mkey m "router")) v ∧ (v = a "run" ∨ v = a "resume"))
      (Budget.activationN ask state m) := by
  unfold Budget.activationN
  unfold_native "VerifiedKernel.Session.Loop.activation"
  sata_walk
  all_goals first
    | exact SatA.fail
    | (loop_unfold
       exact SatA.mono expireEntry_no_run (fun out none eq => absurd eq none))
    | (loop_unfold
       intro h
       first
         | (simp [Budget.outEffects_tuple, materializeRun, a] at h; done)
         | (refine ⟨_, ?_, Or.inl rfl⟩
            rw [← Budget.mkey_put_ne m (b "activation") (show "phase" ≠ "router" by decide)]
            exact ⟨_, _, ‹_›⟩)
         | (refine ⟨_, ?_, Or.inr rfl⟩
            rw [← Budget.mkey_put_ne m (b "activation") (show "phase" ≠ "router" by decide)]
            exact ⟨_, _, ‹_›⟩))

/-! ## Only the activation helper hands a round to the model -/

/-- The output does not end with `{:materialize, :run}`. -/
def NoRun (out : Term) : Prop := (Budget.outEffects out).getLast? ≠ some materializeRun

abbrev finalRecordN : Loop.Ask → Term → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.finalRecord"
abbrev intentRecordN : Term → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.intentRecord"
abbrev toolsDoneN : Loop.Ask → Term → Term → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.toolsDone"
abbrev resultsStoredN : Loop.Ask → Term → Term → Term → Term → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.resultsStored"

theorem last_append_continue {pre effs : List Term} (last : effs.getLast? = some (a "continue")) :
    (pre ++ effs).getLast? ≠ some materializeRun := by
  cases effs with
  | nil => simp at last
  | cons x xs =>
    have : (pre ++ x :: xs).getLast? = (x :: xs).getLast? := by
      simp [List.getLast?_append, List.getLast?_cons]
    rw [this, last]
    simp [materializeRun, a]

macro "norun_leaf" : tactic => `(tactic| first
  | exact SatA.fail
  | (loop_unfold; simp [NoRun, Budget.outEffects_tuple, materializeRun, a]; done)
  | (obtain ⟨_, _, parked, _, last⟩ := Budget.Sat.use Budget.park_out ‹_›
     cases parked
     loop_unfold
     simp only [NoRun, Budget.outEffects_tuple, wrap]
     exact last_append_continue last))

theorem modelFailure_no_run {ask : Loop.Ask} {state m info : Term} {recover : Bool} :
    SatA NoRun (Budget.modelFailureN ask state m info recover) := by
  unfold Budget.modelFailureN
  unfold_native "VerifiedKernel.Session.Loop.modelFailure"
  sata_walk
  all_goals norun_leaf

theorem finalize_no_run {ask : Loop.Ask} {state m t : Term} : SatA NoRun (Budget.finalizeN ask state m t) := by
  unfold Budget.finalizeN
  unfold_native "VerifiedKernel.Session.Loop.finalize"
  sata_walk
  all_goals norun_leaf

theorem toolTurn_no_run {m o : Term} : SatA NoRun (Budget.toolTurnN m o) := by
  unfold Budget.toolTurnN
  unfold_native "VerifiedKernel.Session.Loop.toolTurn"
  sata_walk
  all_goals norun_leaf

theorem classify_no_run {ask : Loop.Ask} {state m : Term} : SatA NoRun (Budget.classifyN ask state m) := by
  unfold Budget.classifyN
  unfold_native "VerifiedKernel.Session.Loop.classify"
  sata_walk
  all_goals first
    | norun_leaf
    | exact modelFailure_no_run
    | exact finalize_no_run
    | exact toolTurn_no_run

theorem modelFailed_no_run {ask : Loop.Ask} {state m : Term} : SatA NoRun (Budget.modelFailedN ask state m) := by
  unfold Budget.modelFailedN
  unfold_native "VerifiedKernel.Session.Loop.modelFailed"
  sata_walk
  all_goals norun_leaf

theorem outputCommitted_no_run {ask : Loop.Ask} {state m : Term} :
    SatA NoRun (Budget.outputCommittedN ask state m) := by
  unfold Budget.outputCommittedN
  unfold_native "VerifiedKernel.Session.Loop.outputCommitted"
  sata_walk
  all_goals norun_leaf

theorem finalStop_no_run {m stopped : Term} {effs : List Term} (h : Budget.finalStopN m = (stopped, effs))
    (pre : List Term) : (pre ++ effs).getLast? ≠ some materializeRun := by
  rcases Budget.finalStop_cases h with ⟨_, rfl⟩ | rfl
  · simp [materializeRun, a, List.getLast?_append]
  · simp [materializeRun, a, List.getLast?_append]

theorem guardNotice_no_run {ask : Loop.Ask} {state m : Term} : SatA NoRun (Budget.guardNoticeN ask state m) := by
  unfold Budget.guardNoticeN
  unfold_native "VerifiedKernel.Session.Loop.guardNotice"
  generalize hfs : (native_decl% "VerifiedKernel.Session.Loop.finalStop" : Term → Term × List Term) m = fs
  obtain ⟨stopped, effs⟩ := fs
  dsimp only
  sata_walk
  all_goals first
    | norun_leaf
    | (loop_unfold
       simp only [NoRun, Budget.outEffects_tuple]
       first
         | exact finalStop_no_run hfs []
         | exact finalStop_no_run hfs [_])

theorem noticeCleanup_no_run {ask : Loop.Ask} {state m : Term} : SatA NoRun (Budget.noticeCleanupN ask state m) := by
  unfold Budget.noticeCleanupN
  unfold_native "VerifiedKernel.Session.Loop.noticeCleanup"
  sata_walk
  all_goals first
    | norun_leaf
    | (loop_unfold; simp [NoRun, Budget.outEffects_tuple, materializeRun, a, List.getLast?_append])

theorem guardOutcome_no_run {ask : Loop.Ask} {state m : Term} : SatA NoRun (Budget.guardOutcomeN ask state m) := by
  unfold Budget.guardOutcomeN
  unfold_native "VerifiedKernel.Session.Loop.guardOutcome"
  sata_walk
  all_goals norun_leaf

theorem continuation_no_run {ask : Loop.Ask} {state m : Term} : SatA NoRun (Budget.continuationN ask state m) := by
  unfold Budget.continuationN
  unfold_native "VerifiedKernel.Session.Loop.continuation"
  sata_walk
  all_goals first
    | norun_leaf
    | (loop_unfold; simp [NoRun, Budget.outEffects_tuple, materializeRun, a, List.getLast?_append])

theorem finalRecord_no_run {ask : Loop.Ask} {state m r : Term} : SatA NoRun (finalRecordN ask state m r) := by
  unfold finalRecordN
  unfold_native "VerifiedKernel.Session.Loop.finalRecord"
  sata_walk
  all_goals first
    | norun_leaf
    | exact finalize_no_run
    | (loop_unfold; simp [NoRun, Budget.outEffects_tuple, materializeRun, a, List.getLast?_append])

theorem intentRecord_no_run {state m r : Term} : SatA NoRun (intentRecordN state m r) := by
  unfold intentRecordN
  unfold_native "VerifiedKernel.Session.Loop.intentRecord"
  sata_walk
  all_goals first
    | norun_leaf
    | exact toolTurn_no_run
    | (loop_unfold; simp [NoRun, Budget.outEffects_tuple, materializeRun, a, List.getLast?_append])

theorem toolsDone_no_run {ask : Loop.Ask} {state m results async : Term} :
    SatA NoRun (toolsDoneN ask state m results async) := by
  unfold toolsDoneN
  unfold_native "VerifiedKernel.Session.Loop.toolsDone"
  sata_walk
  all_goals norun_leaf

theorem resultsStored_no_run {ask : Loop.Ask} {state m events hwm base stored : Term} :
    SatA NoRun (resultsStoredN ask state m events hwm base stored) := by
  unfold resultsStoredN
  unfold_native "VerifiedKernel.Session.Loop.resultsStored"
  sata_walk
  all_goals first
    | norun_leaf
    | (loop_unfold; simp [NoRun, Budget.outEffects_tuple, materializeRun, a, List.getLast?_append])

theorem timeoutEntry_no_run {ask : Loop.Ask} {state m : Term} : SatA NoRun (Budget.timeoutEntryN ask state m) := by
  unfold Budget.timeoutEntryN
  unfold_native "VerifiedKernel.Session.Loop.timeoutEntry"
  sata_walk
  all_goals first
    | norun_leaf
    | exact expireEntry_no_run

/-! ## The loop step -/

/-- The step answer from the activation check of a round. -/
def RunAnswered (ask : Loop.Ask) (state out : Term) : Prop :=
  (Budget.outEffects out).getLast? = some materializeRun →
    ∃ r v, Returns (ask state "activation_next" r) v ∧ (v = a "run" ∨ v = a "resume")

theorem activation_answered {ask : Loop.Ask} {state m : Term} :
    SatA (RunAnswered ask state) (Budget.activationN ask state m) :=
  SatA.mono activation_materialize_run (fun _ h last => (h last).elim fun v ⟨ret, run⟩ => ⟨_, v, ret, run⟩)

theorem norun_answered {ask : Loop.Ask} {state : Term} {m : KernelM Term} (h : SatA NoRun m) :
    SatA (RunAnswered ask state) m :=
  SatA.mono h (fun _ none last => absurd last none)

/-- `step_materialize_run`: a loop step ends with `{:materialize, :run}` only
when the activation check of that step read `activation_next` on the step
state and the answer was `run` or `resume`. -/
theorem step_materialize_run {ask : Loop.Ask} {state args : Term} :
    SatA (RunAnswered ask state) (Loop.stepWith ask state args) := by
  unfold Loop.stepWith
  sata_walk
  all_goals first
    | exact SatA.fail
    | exact activation_answered
    | exact norun_answered classify_no_run
    | exact norun_answered timeoutEntry_no_run
    | exact norun_answered outputCommitted_no_run
    | exact norun_answered modelFailed_no_run
    | exact norun_answered guardNotice_no_run
    | exact norun_answered noticeCleanup_no_run
    | exact norun_answered guardOutcome_no_run
    | exact norun_answered continuation_no_run
    | exact norun_answered modelFailure_no_run
    | exact norun_answered finalRecord_no_run
    | exact norun_answered intentRecord_no_run
    | exact norun_answered toolsDone_no_run
    | exact norun_answered resultsStored_no_run
    | exact norun_answered (SatA.mono expire_no_run (fun _ h => h))
    | (loop_unfold; simp [RunAnswered, Budget.outEffects_tuple, materializeRun, a]; done)
    | (loop_unfold
       intro last
       exact absurd last (finalStop_no_run (m := _) (stopped := (Budget.finalStopN _).1) (effs := (Budget.finalStopN _).2) rfl [_]))

/-- `step_materialize_gate`: with the kernel oracle, a loop step ends with
`{:materialize, :run}` only when `has_unprocessed_stable_work?` answered
`true`, a retry deadline was an integer, or `needs_transcript_continuation?`
answered `true`, each on the step state. -/
theorem step_materialize_gate {state args : Term} :
    SatA (fun out => (Budget.outEffects out).getLast? = some materializeRun →
        Holds (StateQuery.hasUnprocessedStableWork state) ∨
        (∃ d j j', StateQuery.retryAt state j = .ok (d, j') ∧ d.isInteger = true) ∨
        Holds (StateQuery.needsContinuation state))
      (Loop.stepWith Loop.queryAsk state args) := by
  refine SatA.mono step_materialize_run (fun out answered last => ?_)
  obtain ⟨r, v, ⟨j, j', ret⟩, run⟩ := answered last
  rw [Budget.queryAsk_activation_next] at ret
  have gate := activationNext_gate j v j' ret
  rcases run with rfl | rfl
  · exact Or.inl (gate.1 rfl)
  · rcases gate.2 rfl with retry | cont
    · exact Or.inr (Or.inl retry)
    · exact Or.inr (Or.inr cont)

end VerifiedKernel.Session.Loop.Gate
