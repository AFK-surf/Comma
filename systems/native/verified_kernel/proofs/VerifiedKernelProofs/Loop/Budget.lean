import VerifiedKernelProofs.Loop.Source
import VerifiedKernelProofs.Loop.WaitBudget
import VerifiedKernelProofs.Proof.TermComparison

/-! # Bounded autonomous work (property C of issue #2070)

## Model requests between credits

A credit is fresh input, a background completion or a wait expiry. The round
budget `input_round_streak` counts the assistant rounds since the last fresh
input. The guards read the count only while the transcript has a message
that is not acknowledged (`unsettledCount`). Three kernel rules close the
cycles that started the budget over with no credit:

* A retryable model failure does not acknowledge its source.
  `llm_failure_ack?` answers `true` only for a final failure, an exhausted
  model guard, or a source that a notice already reached
  (`TerminalTail.failureAck_final`). The failure ACK carries
  `keep_round_budget`, and `Replies.sessionAck` keeps the count for it.
* The local guard settlement and the runaway retirement end the turn. Their
  session event records the terminal ACK position. After their events apply,
  `needs_transcript_continuation?` answers `false` until the transcript moves
  (`TerminalTail.local_settlement_stops_continuation`,
  `TerminalTail.runaway_retirement_stops_continuation`). Other work, such as
  a retry deadline or a pending repair, can still activate the session.
* Only an unmarked ACK, a `delivery` or a `runtime_message` can clear the
  count (`RoundStreak.batch_rounds`).

`systems/apps/salix_agent/test/loop_budget_test.exs` drives these cycles
through `loop_step` and the kernel's `{:activate, facts}` decision.

The trace-level bound `model_requests_bounded` is not proven. On the host
model of `Host.lean` it does not hold with these credits: the model leaves
fast activations and host failures free (`RequestBound.requests_not_bounded`).
A proof needs host contracts for the activation plan, the fast activation,
the round facts, the tool results and the host-built events, and an invariant
for each settlement kind. `RequestBound.requests_le_grants` and
`ActivationGate.step_materialize_gate` are the proven parts of that argument.

## Internal steps: bounded by the re-entries

A loop step is internal when its last effect is `continue` or a `fact`
request. The host answers such an effect at once, with no model call and no
tool run. A rank on the machine phase drops at each internal step, except at
four re-entry points. Each re-entry is fixed by the effects or the phase of
the step output, so a step that does not take the re-entry branch is not a
re-entry:

* a provider-wait yield: the effects are exactly `write` and `continue`;
* a wait extension: a busy answer commits the extended wait and continues;
* a changed wait: a busy answer finds another wait than the one that the busy
  request recorded, and its only effect is `continue`;
* a repeated Router check: the output phase is `router` although the Router
  fact is already present.

`internal_chain_bounded` gives at most `4 · (r + 1)` steps for `r` re-entries
after the first step. The factor 4 covers the steps that follow a re-entry,
for example the `activation` step that reads the wait again after an
extension. With the kernel oracle, the Router check does not repeat
(`check_router_absent`), and the extensions are at most `ceiling / 1000`
when each one reads the wait that the one before it committed
(`extension_steps_bounded`, `WaitBudget.lean`).

This file counts yields and changed waits. `ActivationChain.lean` bounds them
on the host model: a yield clears the wait (`RoundFrames.yield_not_repeated`),
so only another writer can allow a second yield, and a changed wait needs a
read of a durable state that another writer changed. `activation_chain_bounded`
bounds an activation chain linearly in the environment writes, and
`model_chain_bounded` bounds a chain in the model-round phases by 4. -/

namespace VerifiedKernel.Session.Loop.Budget
open Data
open VerifiedKernel.Session.LoopProof
open VerifiedKernel.Session.WorkConservation
set_option Elab.async false

/-! ## A walk over kernel computations -/

/-- Every successful result of `m` satisfies `P`. -/
def Sat (P : Term → Prop) (m : KernelM Term) : Prop := ∀ j out j', m j = .ok (out, j') → P out

theorem Sat.bind {α : Type} {P : Term → Prop} {m : KernelM α} {k : α → KernelM Term}
    (h : ∀ x j j1, m j = .ok (x, j1) → Sat P (k x)) : Sat P (m >>= k) := by
  intro j out j' run
  obtain ⟨x, j1, first, second⟩ := bind_ok run
  exact h x j j1 first j1 out j' second

theorem Sat.pure {P : Term → Prop} {v : Term} (h : P v) : Sat P (Pure.pure v) := by
  intro j out j' run
  rw [pure_ok run]; exact h

theorem Sat.fail {P : Term → Prop} {kind : String} {args : List Term} : Sat P (fail kind args) := by
  intro j out j' run
  exact (fail_ok run).elim

theorem Sat.ite {P : Term → Prop} {c : Prop} [Decidable c] {A B : KernelM Term}
    (yes : c → Sat P A) (no : ¬c → Sat P B) : Sat P (if c then A else B) := by
  by_cases h : c
  · rw [if_pos h]; exact yes h
  · rw [if_neg h]; exact no h

theorem Sat.dite {P : Term → Prop} {c : Prop} [Decidable c] {A : c → KernelM Term} {B : ¬c → KernelM Term}
    (yes : ∀ h, Sat P (A h)) (no : ∀ h, Sat P (B h)) : Sat P (if h : c then A h else B h) := by
  by_cases h : c
  · rw [dif_pos h]; exact yes h
  · rw [dif_neg h]; exact no h

open Lean Elab Tactic Meta in
/-- One step of the walk: split a bind, an `if`, or a `match` of a `Sat` goal. -/
elab "sat_step" : tactic => withMainContext do
  let target ← instantiateMVars (← getMainTarget)
  let some (_, t) := (do let #[p, t] := target.getAppArgs | none
                         if target.isAppOf ``Sat then some (p, t) else none) | throwError "not a Sat goal"
  let t := t.consumeMData.headBeta
  let fn := t.getAppFn.consumeMData
  match fn with
  | .const name _ =>
    if name == ``Bind.bind then evalTactic (← `(tactic| (apply Sat.bind; intro _ _ _ _)))
    else if name == ``Pure.pure then evalTactic (← `(tactic| apply Sat.pure))
    else if name == ``VerifiedKernel.fail then evalTactic (← `(tactic| exact Sat.fail))
    else if name == ``ite then evalTactic (← `(tactic| (apply Sat.ite <;> intro _)))
    else if name == ``dite then evalTactic (← `(tactic| (apply Sat.dite <;> intro _)))
    else if (← isMatcher name) then evalTactic (← `(tactic| split))
    else if name == ``letFun then evalTactic (← `(tactic| dsimp only))
    else throwError "sat_step: unknown head {name}"
  | .letE .. => evalTactic (← `(tactic| dsimp only))
  | _ => throwError "sat_step: unknown shape {t}"

macro "sat_walk" : tactic => `(tactic| repeat' sat_step)

/-! ## Step outputs -/

/-- The machine of a step output `{machine, effects}`. -/
def outMachine : Term → Term
  | .tuple [m, _] => m
  | _ => nil

/-- The effects of a step output. -/
def outEffects : Term → List Term
  | .tuple [_, .list effs] => effs
  | _ => []

@[simp] theorem outEffects_tuple (m : Term) (effs : List Term) : outEffects (.tuple [m, list effs]) = effs := rfl
@[simp] theorem outMachine_tuple (m e : Term) : outMachine (.tuple [m, e]) = m := rfl

@[simp] theorem getLast?_cons_append_single (y z : Term) (xs : List Term) :
    (y :: (xs ++ [z])).getLast? = some z := by
  show ((y :: xs) ++ [z]).getLast? = some z
  exact List.getLast?_concat

/-- The last effect is `continue` or a `fact` request. -/
def Internal (out : Term) : Prop :=
  (outEffects out).getLast? = some (a "continue") ∨ ∃ v, (outEffects out).getLast? = some (.tuple [a "fact", v])

/-- An internal output has a machine phase in `S`. -/
def PhaseOut (S : List String) (out : Term) : Prop :=
  Internal out → ∃ p ∈ S, mkey (outMachine out) "phase" = b p

/-! Equations for the private effect builders of `Loop.lean`. -/

theorem result_eq (m : Term) (effs : List Term) :
    (native_decl% "VerifiedKernel.Session.Loop.result" : Term → List Term → Term) m effs =
      .tuple [m, list effs] := rfl
theorem phase_eq (m : Term) (name : String) :
    (native_decl% "VerifiedKernel.Session.Loop.phase" : Term → String → Term) m name =
      m.put (b "phase") (b name) := rfl
theorem commit_eq (events : List Term) (hwm mode : Term) :
    (native_decl% "VerifiedKernel.Session.Loop.commit" : List Term → Term → Term → Term) events hwm mode =
      .tuple [a "commit", list events, (if hwm == nil then list [] else list [.tuple [a "hwm", hwm]]), mode] := rfl
theorem stop_eq (outcome : Term) :
    (native_decl% "VerifiedKernel.Session.Loop.stop" : Term → Term) outcome = .tuple [a "stop", outcome] := rfl
theorem cont_eq : (native_decl% "VerifiedKernel.Session.Loop.cont" : Term) = a "continue" := rfl
theorem notify_eq (kind : String) (data : Term) :
    (native_decl% "VerifiedKernel.Session.Loop.notify" : String → Term → Term) kind data =
      .tuple [a "notify", a kind, data] := rfl
theorem fetch_eq (name : Term) :
    (native_decl% "VerifiedKernel.Session.Loop.fetch" : Term → Term) name = .tuple [a "fact", name] := rfl
theorem materialize_eq (mode : String) :
    (native_decl% "VerifiedKernel.Session.Loop.materialize" : String → Term) mode =
      .tuple [a "materialize", a mode] := rfl
theorem setTimer_eq (kind : String) (data : Term) :
    (native_decl% "VerifiedKernel.Session.Loop.setTimer" : String → Term → Term) kind data =
      .tuple [a "set_timer", a kind, data] := rfl

macro "loop_unfold" : tactic => `(tactic| (
  try simp only [result_eq, phase_eq, commit_eq, stop_eq, cont_eq, notify_eq, fetch_eq, materialize_eq,
    setTimer_eq]))

theorem mkey_put_phase (m : Term) (p : String) : mkey (m.put (b "phase") (b p)) "phase" = b p := by
  simp [mkey, put_isMap, get_put_same_binary]

theorem phaseOut_put {S : List String} {m e : Term} {p : String} (member : p ∈ S) :
    PhaseOut S (.tuple [m.put (b "phase") (b p), e]) :=
  fun _ => ⟨p, member, mkey_put_phase m p⟩

macro "leaf_out" : tactic => `(tactic| (loop_unfold; first
  | (refine phaseOut_put ?_; simp; done)
  | simp [PhaseOut, Internal, mkey, put_isMap, get_put_same_binary, get_put_binary_other]))


/-! ## Output facts of the loop helpers -/

theorem Sat.mono {P Q : Term → Prop} {m : KernelM Term} (h : Sat P m) (imp : ∀ out, P out → Q out) :
    Sat Q m := fun j out j' run => imp out (h j out j' run)

theorem Sat.use {P : Term → Prop} {m : KernelM Term} {j j' : List Term} {out : Term} (h : Sat P m)
    (run : m j = .ok (out, j')) : P out := h j out j' run

abbrev modelFailedN : Loop.Ask → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.modelFailed"
abbrev finalizeN : Loop.Ask → Term → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.finalize"
abbrev toolTurnN : Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.toolTurn"
abbrev modelFailureN : Loop.Ask → Term → Term → Term → Bool → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.modelFailure"

theorem modelFailed_out {ask : Loop.Ask} {state m : Term} : Sat (PhaseOut []) (modelFailedN ask state m) := by
  unfold modelFailedN
  unfold_native "VerifiedKernel.Session.Loop.modelFailed"
  sat_walk
  all_goals leaf_out

theorem finalize_out {ask : Loop.Ask} {state m t : Term} : Sat (PhaseOut []) (finalizeN ask state m t) := by
  unfold finalizeN
  unfold_native "VerifiedKernel.Session.Loop.finalize"
  sat_walk
  all_goals leaf_out

theorem toolTurn_out {m o : Term} : Sat (PhaseOut []) (toolTurnN m o) := by
  unfold toolTurnN
  unfold_native "VerifiedKernel.Session.Loop.toolTurn"
  sat_walk
  all_goals leaf_out

theorem modelFailure_out {ask : Loop.Ask} {state m info : Term} {recover : Bool} :
    Sat (PhaseOut ["model_failed"]) (modelFailureN ask state m info recover) := by
  unfold modelFailureN
  unfold_native "VerifiedKernel.Session.Loop.modelFailure"
  sat_walk
  all_goals leaf_out

theorem PhaseOut.weaken {S T : List String} {out : Term} (h : PhaseOut S out) (sub : S ⊆ T) :
    PhaseOut T out := fun internal => by
  obtain ⟨p, member, same⟩ := h internal
  exact ⟨p, sub member, same⟩

/-- Close a goal about a call to a helper with a known output lemma. -/
macro "sat_call " lem:term : tactic => `(tactic| first
  | exact Sat.mono $lem (fun _ o => PhaseOut.weaken o (by simp))
  | exact Sat.use (Sat.mono $lem (fun _ o => PhaseOut.weaken o (by simp))) ‹_›)

abbrev classifyN : Loop.Ask → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.classify"

theorem classify_out {ask : Loop.Ask} {state m : Term} :
    Sat (PhaseOut ["model_failed"]) (classifyN ask state m) := by
  unfold classifyN
  unfold_native "VerifiedKernel.Session.Loop.classify"
  sat_walk
  all_goals first
    | sat_call modelFailure_out
    | sat_call finalize_out
    | sat_call toolTurn_out
    | leaf_out

abbrev parkN : Loop.Ask → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.park"
abbrev outputCommittedN : Loop.Ask → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.outputCommitted"
abbrev guardNoticeN : Loop.Ask → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.guardNotice"
abbrev noticeCleanupN : Loop.Ask → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.noticeCleanup"
abbrev guardOutcomeN : Loop.Ask → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.guardOutcome"
abbrev continuationN : Loop.Ask → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.continuation"
abbrev finalStopN : Term → Term × List Term :=
  native_decl% "VerifiedKernel.Session.Loop.finalStop"

/-- The exact output shape of `park`: a `guard_notice` machine and a `continue`. -/
def ParkOut (out : Term) : Prop :=
  ∃ m' effs, out = .tuple [m', list effs] ∧ mkey m' "phase" = b "guard_notice" ∧
    effs.getLast? = some (a "continue")

theorem park_out {ask : Loop.Ask} {state m : Term} : Sat ParkOut (parkN ask state m) := by
  unfold parkN
  unfold_native "VerifiedKernel.Session.Loop.park"
  sat_walk
  all_goals
    loop_unfold
    exact ⟨_, _, rfl, by simp [mkey, put_isMap, get_put_same_binary], by simp⟩

theorem ParkOut.phaseOut {out : Term} {S : List String} (h : ParkOut out) (member : "guard_notice" ∈ S) :
    PhaseOut S out := by
  obtain ⟨m', effs, rfl, phase, _⟩ := h
  exact fun _ => ⟨_, member, phase⟩

/-- A park call: its output machine is in `guard_notice`, whatever effects precede it. -/
macro "park_leaf" : tactic => `(tactic| (
  obtain ⟨_, _, parked, phase, _⟩ := Sat.use park_out ‹_›
  cases parked
  loop_unfold
  simp only [PhaseOut, outMachine_tuple]
  exact fun _ => ⟨"guard_notice", by simp, phase⟩))

theorem outputCommitted_out {ask : Loop.Ask} {state m : Term} :
    Sat (PhaseOut ["guard_notice"]) (outputCommittedN ask state m) := by
  unfold outputCommittedN
  unfold_native "VerifiedKernel.Session.Loop.outputCommitted"
  sat_walk
  all_goals first
    | park_leaf
    | leaf_out

/-- The stop of a round: `guard_outcome` with `continue`, or `done` with a stop. -/
theorem finalStop_cases {m stopped : Term} {effs : List Term} (h : finalStopN m = (stopped, effs)) :
    (mkey stopped "phase" = b "guard_outcome" ∧ effs = [a "continue"]) ∨
      effs = [.tuple [a "stop", a "final"]] := by
  revert h
  unfold finalStopN
  unfold_native "VerifiedKernel.Session.Loop.finalStop"
  intro h
  split at h
  · left
    simp only [Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    loop_unfold
    simp [mkey, put_isMap, get_put_same_binary]
  · right
    simp only [Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    loop_unfold


theorem guardNotice_out {ask : Loop.Ask} {state m : Term} :
    Sat (PhaseOut ["guard_outcome", "notice_cleanup"]) (guardNoticeN ask state m) := by
  unfold guardNoticeN
  unfold_native "VerifiedKernel.Session.Loop.guardNotice"
  generalize hfs : (native_decl% "VerifiedKernel.Session.Loop.finalStop" : Term → Term × List Term) m = fs
  obtain ⟨stopped, effs⟩ := fs
  rcases finalStop_cases hfs with ⟨phase, rfl⟩ | rfl
  · dsimp only
    sat_walk
    all_goals first
      | (loop_unfold; simp [PhaseOut, Internal, phase]; done)
      | leaf_out
  · dsimp only
    sat_walk
    all_goals leaf_out

theorem noticeCleanup_out {ask : Loop.Ask} {state m : Term} : Sat (PhaseOut []) (noticeCleanupN ask state m) := by
  unfold noticeCleanupN
  unfold_native "VerifiedKernel.Session.Loop.noticeCleanup"
  sat_walk
  all_goals leaf_out

theorem guardOutcome_out {ask : Loop.Ask} {state m : Term} : Sat (PhaseOut []) (guardOutcomeN ask state m) := by
  unfold guardOutcomeN
  unfold_native "VerifiedKernel.Session.Loop.guardOutcome"
  sat_walk
  all_goals leaf_out

theorem continuation_out {ask : Loop.Ask} {state m : Term} :
    Sat (PhaseOut ["guard_notice", "async_boundary", "boundary_after_tools"]) (continuationN ask state m) := by
  unfold continuationN
  unfold_native "VerifiedKernel.Session.Loop.continuation"
  sat_walk
  all_goals first
    | park_leaf
    | leaf_out

/-! ## Term equality and field reads -/

theorem byteArray_beq_self (x : ByteArray) : (x == x) = true := by
  change (x.data == x.data) = true
  exact beq_iff_eq.mpr rfl

theorem zip_self_mem {xs : List Term} {pair : Term × Term} (member : pair ∈ xs.zip xs) :
    pair.1 = pair.2 ∧ pair.1 ∈ xs := by
  induction xs with
  | nil => cases member
  | cons y ys ih =>
    simp only [List.zip_cons_cons, List.mem_cons] at member
    rcases member with rfl | later
    · exact ⟨rfl, List.mem_cons_self⟩
    · obtain ⟨same, inner⟩ := ih later
      exact ⟨same, List.mem_cons_of_mem y inner⟩

theorem exactFuel_self : ∀ (fuel : Nat) (x : Term), x.depth ≤ fuel → Term.exactFuel fuel x x = true
  | 0, x, h => absurd h (by have := Term.depth_positive x; omega)
  | n + 1, x, h => by
    have zipSelf : ∀ xs : List Term, (xs.map Term.depth).foldl max 0 ≤ n →
        (xs.zip xs).all (fun pair => Term.exactFuel n pair.1 pair.2) = true := by
      intro xs bound
      apply List.all_eq_true.mpr
      intro pair member
      obtain ⟨same, inner⟩ := zip_self_mem member
      rw [← same]
      exact exactFuel_self n pair.1 (Nat.le_trans (Term.list_depth_member inner) bound)
    cases x with
    | integer v => simp [Term.exactFuel]
    | atom v => simp [Term.exactFuel]
    | binary v => simpa [Term.exactFuel] using byteArray_beq_self v
    | floatBits v => simp [Term.exactFuel]
    | tuple xs =>
      simp only [Term.depth] at h
      simp only [Term.exactFuel, beq_self_eq_true, Bool.true_and]
      exact zipSelf xs (by omega)
    | list xs =>
      simp only [Term.depth] at h
      simp only [Term.exactFuel, beq_self_eq_true, Bool.true_and]
      exact zipSelf xs (by omega)
    | map xs =>
      simp only [Term.depth] at h
      simp only [Term.exactFuel, beq_self_eq_true, Bool.true_and, List.all_eq_true, List.any_eq_true]
      intro pair member
      have bound := Term.map_depth_member member
      refine ⟨pair, member, ?_⟩
      simp only [Bool.and_eq_true]
      exact ⟨exactFuel_self n _ (by omega), exactFuel_self n _ (by omega)⟩
    | improper xs t =>
      simp only [Term.depth] at h
      simp only [Term.exactFuel, beq_self_eq_true, Bool.true_and, Bool.and_eq_true]
      exact ⟨exactFuel_self n t (by omega), zipSelf xs (by omega)⟩
    | bitstring v w => simpa [Term.exactFuel] using byteArray_beq_self v

theorem term_beq_self (x : Term) : (x == x) = true :=
  Term.beq_of_exactFuel (exactFuel_self x.depth x (Nat.le_refl _))

/-- A field read does not depend on the observations. -/
theorem field_det {state x y : Term} {name : String} {j j1 j' j2 : List Term}
    (first : field state name j = .ok (x, j1)) (second : field state name j' = .ok (y, j2)) : x = y := by
  unfold field fetch at first second
  by_cases isMap : (!state.isMap) = true
  · simp only [isMap, if_true] at first
    exact (fail_ok first).elim
  · simp only [isMap, Bool.false_eq_true, if_false] at first second
    by_cases has : state.has (a name) = true
    · simp only [has, if_true] at first second
      rw [pure_ok first, pure_ok second]
    · simp only [has, Bool.false_eq_true, if_false] at first
      exact (fail_ok first).elim

/-! ## Wait expiry -/

abbrev expireN : Term → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.expire"
abbrev waitSetEventN : Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.waitSetEvent"

theorem waitSetEvent_wait {state next event : Term} {j j' : List Term}
    (h : waitSetEventN state next j = .ok (event, j')) : event.get (b "wait") = next := by
  revert h
  unfold waitSetEventN
  unfold_native "VerifiedKernel.Session.Loop.waitSetEvent"
  intro h
  obtain ⟨sid, _, _, rest⟩ := bind_ok h
  rw [pure_ok rest]
  simp [Term.get, binary_key_beq]

/-- The effects of an activation-path wait extension to `next`. -/
def extendEffects (event next : Term) : List Term :=
  [.tuple [a "commit", list [event], list [], nil], .tuple [a "notify", a "wait_extended", .tuple [next, b "recovery"]],
    a "continue"]

/-- The internal outputs of `expire`: the changed-wait branch with exactly
`continue`, or an extension that commits the extended wait. -/
def ExpireOut (state m busy : Term) (out : Term) : Prop :=
  Internal out →
    (outEffects out = [a "continue"] ∧
      ∃ w, Returns (field state "wait") w ∧ (w != mkey m "expected") = true) ∨
    (∃ w now next event, Returns (field state "wait") w ∧
      VerifiedKernel.AgentLoop.WaitExtension.decide w busy now (fact m "ceiling_ms") = .tuple [a "extend", next] ∧
      outEffects out = extendEffects event next ∧ event.get (b "wait") = next)

theorem expire_out {state m busy : Term} : Sat (ExpireOut state m busy) (expireN state m busy) := by
  unfold expireN
  unfold_native "VerifiedKernel.Session.Loop.expire"
  sat_walk
  all_goals first
    | (intro _; left; loop_unfold
       exact ⟨rfl, _, ⟨_, _, ‹field state "wait" _ = _›⟩, ‹(_ != _) = true›⟩)
    | (intro _; right; loop_unfold
       refine ⟨_, _, _, _, ⟨_, _, ‹field state "wait" _ = _›⟩,
         ‹VerifiedKernel.AgentLoop.WaitExtension.decide _ _ _ _ = _›, ?_, waitSetEvent_wait ‹_›⟩
       simp [extendEffects, nil, atom_beq_self]; done)
    | (unfold ExpireOut; loop_unfold; simp [Internal])

abbrev expireEntryN : Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.expireEntry"

/-- An expiry entry is internal only when it asks for the busy fact. -/
def EntryOut (out : Term) : Prop := Internal out → mkey (outMachine out) "phase" = b "busy"

theorem not_extend_idle {w now ceiling next : Term} :
    VerifiedKernel.AgentLoop.WaitExtension.decide w (a "false") now ceiling ≠ .tuple [a "extend", next] := by
  intro decided
  obtain ⟨_, _, busy, _⟩ := decide_extend decided
  simp [a] at busy

theorem expireEntry_out {state m : Term} : Sat EntryOut (expireEntryN state m) := by
  unfold expireEntryN
  unfold_native "VerifiedKernel.Session.Loop.expireEntry"
  sat_walk
  · loop_unfold
    exact fun _ => mkey_put_phase _ _
  · rename_i w0 j0 j0' read0 _
    intro j out j' run
    intro internal
    rcases Sat.use expire_out run internal with ⟨_, w, ⟨_, _, read⟩, changed⟩ | ⟨_, _, _, _, _, decided, _⟩
    · -- The expected wait is the wait that this step read, so it has not changed.
      exfalso
      have same := field_det read read0
      subst same
      simp [mkey, put_isMap, get_put_same_binary, bne, term_beq_self] at changed
    · exact (not_extend_idle decided).elim

theorem mkey_put_ne (m v : Term) {k l : String} (h : k ≠ l) : mkey (m.put (b k) v) l = mkey m l := by
  rw [show mkey (m.put (b k) v) l = (m.put (b k) v).get (b l) by simp [mkey, put_isMap],
    get_put_binary_other _ _ h]
  cases m <;> simp [mkey, Term.get, Term.isMap, nil]

theorem mkey_put_same (m v : Term) (k : String) : mkey (m.put (b k) v) k = v := by
  simp [mkey, put_isMap, get_put_same_binary]

abbrev activationN : Loop.Ask → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.activation"
abbrev timeoutEntryN : Loop.Ask → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Loop.timeoutEntry"

/-- The internal outputs of `activation` for the router fact `r`. -/
def ActOut (ask : Loop.Ask) (state r : Term) (out : Term) : Prop :=
  Internal out →
    (mkey (outMachine out) "phase" = b "router" ∧ Returns (ask state "activation_next" r) (a "check_router")) ∨
    mkey (outMachine out) "phase" = b "busy" ∨
    (∃ es, outEffects out = [.tuple [a "write", list es], a "continue"])

theorem activation_out {ask : Loop.Ask} {state m : Term} :
    Sat (ActOut ask state (mkey m "router")) (activationN ask state m) := by
  unfold activationN
  unfold_native "VerifiedKernel.Session.Loop.activation"
  sat_walk
  all_goals first
    | exact (fail_ok ‹_›).elim
    | (loop_unfold
       intro _
       left
       refine ⟨mkey_put_phase _ _, ?_⟩
       rw [← mkey_put_ne m (b "activation") (show "phase" ≠ "router" by decide)]
       exact ⟨_, _, ‹_›⟩)
    | (loop_unfold; intro _; right; right; exact ⟨_, rfl⟩)
    | exact Sat.mono expireEntry_out (fun out entry internal => Or.inr (Or.inl (entry internal)))
    | (unfold ActOut; loop_unfold; simp [Internal])

/-- The internal outputs of an expiry entry from a fired wait timer. -/
theorem timeoutEntry_out {ask : Loop.Ask} {state m : Term} : Sat EntryOut (timeoutEntryN ask state m) := by
  unfold timeoutEntryN
  unfold_native "VerifiedKernel.Session.Loop.timeoutEntry"
  sat_walk
  · unfold EntryOut; loop_unfold; simp [Internal]
  · exact expireEntry_out

/-! ## The phase rank -/

/-- The rank of a phase. `router` is the Router fact that the machine holds. -/
def phaseRank (p router : Term) : Nat :=
  if p == b "activation" then (if router == nil then 3 else 2)
  else if p == b "continuation" || p == b "output_committed" then 3
  else if p == b "classify" || p == b "guard_notice" || p == b "notice_committed" || p == b "router" ||
    p == b "timeout" then 2
  else if p == b "model_failed" || p == b "boundary" || p == b "guard_outcome" || p == b "async_boundary" ||
    p == b "boundary_after_tools" || p == b "notice_cleanup" || p == b "busy" then 1
  else 0

/-- The rank of the machine that the next step reads. -/
def inRank (m : Term) : Nat := phaseRank (mkey m "phase") (mkey m "router")

theorem inRank_le (m : Term) : inRank m ≤ 3 := by
  unfold inRank phaseRank
  repeat' split
  all_goals omega

theorem inRank_of {m : Term} {p : String} (h : mkey m "phase" = b p) :
    inRank m = phaseRank (b p) (mkey m "router") := by
  simp [inRank, h]

/-! ## One internal step -/

theorem phase_of_beq {m : Term} {p : String}
    (h : ((native_decl% "VerifiedKernel.Session.Loop.key" : Term → String → Term) m "phase" == b p) = true) :
    mkey m "phase" = b p := binary_beq_true h

/-- A branch that runs a helper with a `PhaseOut` lemma: the rank drops. -/
macro "rank_leaf " m:term:max lem:term:max ph:str : tactic => `(tactic| (
  refine Sat.mono $lem (fun out po internal => Or.inl ?_)
  obtain ⟨p, mem, outPhase⟩ := po internal
  have inPhase : mkey $m "phase" = b $ph := phase_of_beq ‹(_ == b $ph) = true›
  rw [inRank_of outPhase, inRank_of inPhase]
  simp only [List.mem_cons, List.mem_nil_iff, or_false] at mem
  all_goals (rcases mem with h | h | h <;> subst_vars <;> simp (config := {decide := true}) [phaseRank, binary_key_beq])))


/-- A provider-wait yield: the step writes its yield events and re-enters
`activation`. -/
def YieldOut (out : Term) : Prop := ∃ es, outEffects out = [.tuple [a "write", list es], a "continue"]

/-- A wait extension: the step answers a busy fact, `decide` extends the wait
that the step read, and the step commits the extended wait and re-enters. -/
def ExtendOut (state m ev out : Term) : Prop :=
  ∃ v w now next event, ev = .tuple [a "fact", v] ∧ Returns (field state "wait") w ∧
    VerifiedKernel.AgentLoop.WaitExtension.decide w v now (fact m "ceiling_ms") = .tuple [a "extend", next] ∧
    outEffects out = extendEffects event next ∧ event.get (b "wait") = next

/-- A changed wait: the step answers the busy fact, the wait that it reads
differs from the wait that the busy request recorded, and its only effect is
`continue`. -/
def ChangedOut (state m ev out : Term) : Prop :=
  (∃ v, ev = .tuple [a "fact", v]) ∧ mkey m "phase" = b "busy" ∧ outEffects out = [a "continue"] ∧
    ∃ w, Returns (field state "wait") w ∧ (w != mkey m "expected") = true

/-- A repeated Router check: the output phase is `router`, and the step did
not start from an `activation` machine without a Router fact. That is, the
Router fact came from a `fact` answer or was already in the machine. -/
def RouterOut (ask : Loop.Ask) (state m ev out : Term) : Prop :=
  mkey (outMachine out) "phase" = b "router" ∧
    Returns (ask state "activation_next" (activationRouter m ev)) (a "check_router") ∧
    ¬ (ev = a "continue" ∧ (mkey m "router" == nil) = true)

/-- The four re-entry points of the activation phases. Each case fixes the
effects or the phase of the step output, so only the re-entry branch of the
loop satisfies it. -/
def Reentry (ask : Loop.Ask) (state m ev out : Term) : Prop :=
  YieldOut out ∨ ExtendOut state m ev out ∨ ChangedOut state m ev out ∨ RouterOut ask state m ev out

/-- The rank drops, or the step is a re-entry. -/
def RankStep (ask : Loop.Ask) (state m ev out : Term) : Prop :=
  Internal out → inRank (outMachine out) < inRank m ∨ Reentry ask state m ev out

/-- A `continue` step: the rank drops, or the step is a re-entry. -/
theorem step_continue_rank {ask : Loop.Ask} {state m : Term} :
    Sat (RankStep ask state m (a "continue")) (Loop.stepWith ask state (.tuple [m, a "continue"])) := by
  unfold Loop.stepWith
  dsimp only
  apply Sat.bind
  intro sid _ _ _
  simp only [a]
  sat_walk
  · rank_leaf m classify_out "classify"
  · -- activation
    have inPhase : mkey m "phase" = b "activation" := phase_of_beq ‹(_ == b "activation") = true›
    refine Sat.mono activation_out (fun out act internal => ?_)
    rcases act internal with ⟨outPhase, answered⟩ | outPhase | yield
    · by_cases none : (mkey m "router" == nil) = true
      · left
        rw [inRank_of outPhase, inRank_of inPhase]
        simp [phaseRank, binary_key_beq, none]
      · right; right; right; right
        exact ⟨outPhase, answered, fun both => none both.2⟩
    · left
      rw [inRank_of outPhase, inRank_of inPhase]
      simp (config := {decide := true}) only [phaseRank, if_false, if_true]
      split <;> omega
    · exact Or.inr (Or.inl yield)
  · -- timeout
    have inPhase : mkey m "phase" = b "timeout" := phase_of_beq ‹(_ == b "timeout") = true›
    refine Sat.mono timeoutEntry_out (fun out entry internal => Or.inl ?_)
    rw [inRank_of (entry internal), inRank_of inPhase]
    simp [phaseRank, binary_key_beq]
  · unfold RankStep; loop_unfold; simp [Internal]
  · rank_leaf m outputCommitted_out "output_committed"
  · rank_leaf m modelFailed_out "model_failed"
  · rank_leaf m guardNotice_out "guard_notice"
  · rank_leaf m noticeCleanup_out "notice_cleanup"
  · unfold RankStep; loop_unfold; simp [Internal]
  · -- notice_committed without async: the `finalStop` outcome
    have inPhase : mkey m "phase" = b "notice_committed" := phase_of_beq ‹(_ == b "notice_committed") = true›
    generalize hfs : (native_decl% "VerifiedKernel.Session.Loop.finalStop" : Term → Term × List Term) m = fs
    obtain ⟨stopped, effs⟩ := fs
    rcases finalStop_cases hfs with ⟨outPhase, rfl⟩ | rfl
    · intro _
      left
      loop_unfold
      rw [outMachine_tuple, inRank_of outPhase, inRank_of inPhase]
      simp [phaseRank, binary_key_beq]
    · unfold RankStep; loop_unfold; simp [Internal]
  · rank_leaf m guardOutcome_out "guard_outcome"
  · rank_leaf m continuation_out "continuation"
  · unfold RankStep; loop_unfold; simp [Internal]
  · unfold RankStep; loop_unfold; simp [Internal]

/-- A `fact` answer step: the rank drops, or the step is a re-entry. -/
theorem step_fact_rank {ask : Loop.Ask} {state m v : Term} :
    Sat (RankStep ask state m (.tuple [a "fact", v]))
      (Loop.stepWith ask state (.tuple [m, .tuple [a "fact", v]])) := by
  unfold Loop.stepWith
  dsimp only
  apply Sat.bind
  intro sid _ _ _
  simp only [a]
  sat_walk
  · -- router
    have inPhase : mkey m "phase" = b "router" := phase_of_beq ‹(_ == b "router") = true›
    refine Sat.mono activation_out (fun out act internal => ?_)
    rw [mkey_put_same] at act
    rcases act internal with ⟨outPhase, answered⟩ | outPhase | yield
    · right; right; right; right
      refine ⟨outPhase, answered, fun both => ?_⟩
      simp [a] at both
    · left
      rw [inRank_of outPhase, inRank_of inPhase]
      simp (config := {decide := true}) [phaseRank]
    · exact Or.inr (Or.inl yield)
  · -- busy
    have inPhase : mkey m "phase" = b "busy" := phase_of_beq ‹(_ == b "busy") = true›
    refine Sat.mono expire_out (fun out exp internal => ?_)
    rcases exp internal with ⟨only, changed⟩ | ⟨w, now, next, event, read, decided, effects, carried⟩
    · exact Or.inr (Or.inr (Or.inr (Or.inl ⟨⟨v, rfl⟩, inPhase, only, changed⟩)))
    · exact Or.inr (Or.inr (Or.inl ⟨v, w, now, next, event, rfl, read, decided, effects, carried⟩))

/-! ## Internal chains -/

/-- One loop step as the host ran it. -/
structure StepRec where
  state : Term
  machine : Term
  event : Term
  out : Term

/-- The step ran successfully on its state. -/
def StepRec.Runs (ask : Loop.Ask) (s : StepRec) : Prop :=
  ∃ j j', Loop.stepWith ask s.state (.tuple [s.machine, s.event]) j = .ok (s.out, j')

/-- The host answers an internal effect: `continue` with `continue`, and a
`fact` request with a `fact` answer. -/
def Follows (out ev : Term) : Prop :=
  ((outEffects out).getLast? = some (a "continue") ∧ ev = a "continue") ∨
    ∃ q v, (outEffects out).getLast? = some (.tuple [a "fact", q]) ∧ ev = .tuple [a "fact", v]

/-- Consecutive internal steps. Each step ends with an internal effect, the
next step reads the machine that the step returned, and its event answers the
internal effect. The state of each step is free: the host can apply its own
writes, commits and other writers between steps. -/
def InternalChain (ask : Loop.Ask) : List StepRec → Prop
  | [] => True
  | [s] => s.Runs ask ∧ Internal s.out
  | s :: t :: rest => s.Runs ask ∧ Internal s.out ∧ t.machine = outMachine s.out ∧
      Follows s.out t.event ∧ InternalChain ask (t :: rest)

open Classical in
/-- The number of re-entry steps. -/
noncomputable def reentries (ask : Loop.Ask) (steps : List StepRec) : Nat :=
  steps.countP (fun s => decide (Reentry ask s.state s.machine s.event s.out))

theorem InternalChain.tail {ask : Loop.Ask} {s : StepRec} {rest : List StepRec}
    (chain : InternalChain ask (s :: rest)) : InternalChain ask rest := by
  cases rest with
  | nil => trivial
  | cons t rest => exact chain.2.2.2.2

theorem InternalChain.head {ask : Loop.Ask} {s : StepRec} {rest : List StepRec}
    (chain : InternalChain ask (s :: rest)) : s.Runs ask ∧ Internal s.out := by
  cases rest with
  | nil => exact chain
  | cons t rest => exact ⟨chain.1, chain.2.1⟩

/-- A step whose event answers an internal effect drops the rank or re-enters. -/
theorem follow_rank {ask : Loop.Ask} {s : StepRec} (runs : s.Runs ask) (internal : Internal s.out)
    (answer : s.event = a "continue" ∨ ∃ v, s.event = .tuple [a "fact", v]) :
    inRank (outMachine s.out) < inRank s.machine ∨ Reentry ask s.state s.machine s.event s.out := by
  obtain ⟨j, j', run⟩ := runs
  rcases answer with same | ⟨v, same⟩
  · rw [same] at run ⊢
    exact step_continue_rank j s.out j' run internal
  · rw [same] at run ⊢
    exact step_fact_rank j s.out j' run internal

theorem follows_answer {out ev : Term} (h : Follows out ev) :
    ev = a "continue" ∨ ∃ v, ev = .tuple [a "fact", v] := by
  rcases h with ⟨_, same⟩ | ⟨_, v, _, same⟩
  · exact Or.inl same
  · exact Or.inr ⟨v, same⟩

open Classical in
/-- The potential: a chain whose first event answers an internal effect has at
most `rank + 4 · re-entries` steps. -/
theorem chain_potential {ask : Loop.Ask} :
    ∀ {steps : List StepRec} {s : StepRec}, steps.head? = some s → InternalChain ask steps →
      (s.event = a "continue" ∨ ∃ v, s.event = .tuple [a "fact", v]) →
      steps.length ≤ inRank s.machine + 4 * reentries ask steps
  | [], _, head, _, _ => by cases head
  | [t], s, head, chain, answer => by
    cases head
    obtain ⟨runs, internal⟩ := chain
    unfold reentries
    by_cases re : Reentry ask t.state t.machine t.event t.out
    · simp [re]
    · simp only [List.countP_singleton, re, decide_false, Bool.false_eq_true, if_false, List.length_singleton]
      rcases follow_rank runs internal answer with drop | re'
      · omega
      · exact absurd re' re
  | t :: u :: rest, s, head, chain, answer => by
    cases head
    obtain ⟨runs, internal, machine, follows, chain'⟩ := chain
    have ih := chain_potential (steps := u :: rest) (s := u) rfl chain' (follows_answer follows)
    have bound := inRank_le u.machine
    unfold reentries at ih ⊢
    rw [List.countP_cons, List.length_cons]
    by_cases re : Reentry ask t.state t.machine t.event t.out
    · simp only [re, decide_true, if_true]
      omega
    · simp only [re, decide_false, Bool.false_eq_true, if_false, Nat.add_zero]
      rcases follow_rank runs internal answer with drop | re'
      · rw [← machine] at drop
        omega
      · exact absurd re' re

/-- `internal_chain_bounded`: a chain of internal steps has at most
`4 · (r + 1)` steps, where `r` counts the re-entry steps after the first. The
first step can read any event. -/
theorem internal_chain_bounded {ask : Loop.Ask} {s : StepRec} {rest : List StepRec}
    (chain : InternalChain ask (s :: rest)) : (s :: rest).length ≤ 4 * (reentries ask rest + 1) := by
  cases rest with
  | nil => simp only [List.length_singleton]; omega
  | cons u rest =>
    obtain ⟨_, _, _, follows, chain'⟩ := chain
    have := chain_potential (steps := u :: rest) (s := u) rfl chain' (follows_answer follows)
    have bound := inRank_le u.machine
    simp only [List.length_cons] at this ⊢
    omega

/-! ## The Router check with the kernel oracle -/

abbrev activationNextN : Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Command.activationNext"

theorem lookup_activation_next :
    lookupOp queryTable (a "activation_next") = some activationNextN := rfl

theorem queryAsk_activation_next (state r : Term) :
    Loop.queryAsk state "activation_next" r = activationNextN state r := by
  unfold Loop.queryAsk
  rw [lookup_activation_next]

/-- `activation_next` asks for the Router fact only when the fact is absent. -/
theorem activationNext_check_router {state r : Term} :
    Sat (fun out => out = a "check_router" → (r == nil) = true) (activationNextN state r) := by
  unfold activationNextN
  unfold_native "VerifiedKernel.Session.Command.activationNext"
  sat_walk
  all_goals first
    | (intro _; assumption)
    | (intro h; simp [a] at h)

theorem check_router_absent {state r : Term}
    (answered : Returns (Loop.queryAsk state "activation_next" r) (a "check_router")) : (r == nil) = true := by
  obtain ⟨j, j', run⟩ := answered
  rw [queryAsk_activation_next] at run
  exact Sat.use activationNext_check_router run rfl

/-! ## Re-entry kinds with the kernel oracle -/

/-- A provider-wait yield step. -/
def YieldStep (s : StepRec) : Prop := YieldOut s.out

/-- A wait extension step. -/
def ExtendStep (s : StepRec) : Prop := ExtendOut s.state s.machine s.event s.out

/-- A step that re-enters on a changed wait. -/
def ChangedStep (s : StepRec) : Prop := ChangedOut s.state s.machine s.event s.out

open Classical in
noncomputable def countSteps (p : StepRec → Prop) (steps : List StepRec) : Nat :=
  steps.countP (fun s => decide (p s))

theorem countP_le_three {α : Type} {p q₁ q₂ q₃ : α → Bool} :
    ∀ {l : List α}, (∀ x ∈ l, p x = true → q₁ x = true ∨ q₂ x = true ∨ q₃ x = true) →
      l.countP p ≤ l.countP q₁ + l.countP q₂ + l.countP q₃
  | [], _ => by simp
  | x :: xs, h => by
    have ih := countP_le_three (l := xs) (fun y member => h y (List.mem_cons_of_mem x member))
    simp only [List.countP_cons]
    by_cases hp : p x = true
    · rcases h x List.mem_cons_self hp with h1 | h2 | h3
      · simp only [hp, h1, if_true]; split <;> split <;> omega
      · simp only [hp, h2, if_true]; split <;> split <;> omega
      · simp only [hp, h3, if_true]; split <;> split <;> omega
    · simp only [hp, Bool.false_eq_true, if_false]
      split <;> split <;> split <;> omega

theorem chain_tail_answers {ask : Loop.Ask} :
    ∀ {s : StepRec} {rest : List StepRec}, InternalChain ask (s :: rest) →
      ∀ t ∈ rest, t.event = a "continue" ∨ ∃ v, t.event = .tuple [a "fact", v]
  | _, [], _, t, member => by cases member
  | _, u :: rest, chain, t, member => by
    obtain ⟨_, _, _, follows, chain'⟩ := chain
    rcases List.mem_cons.mp member with same | later
    · rw [same]; exact follows_answer follows
    · exact chain_tail_answers chain' t later

/-- With the kernel oracle, a re-entry after the first step is a yield, an
extension or a changed wait. The Router check does not run again, because the
host answers the Router fact with a present value. -/
theorem reentry_kinds {s : StepRec}
    (answer : s.event = a "continue" ∨ ∃ v, s.event = .tuple [a "fact", v])
    (routerFact : ∀ v, s.event = .tuple [a "fact", v] → (v == nil) = false)
    (re : Reentry Loop.queryAsk s.state s.machine s.event s.out) :
    YieldStep s ∨ ExtendStep s ∨ ChangedStep s := by
  rcases re with yield | extend | changed | ⟨_, answered, notFirst⟩
  · exact Or.inl yield
  · exact Or.inr (Or.inl extend)
  · exact Or.inr (Or.inr changed)
  · exfalso
    have absent := check_router_absent answered
    rcases answer with same | ⟨v, same⟩
    · rw [same] at absent notFirst
      exact notFirst ⟨rfl, absent⟩
    · rw [same] at absent
      have present := routerFact v same
      simp only [activationRouter] at absent
      rw [absent] at present
      cases present

/-- `internal_chain_bounded` for the kernel oracle. Hypothesis: the host
answers each Router fact with a present value. The chain length is linear in
the yield, extension and changed-wait steps after the first step. Each of the
three is counted, not bounded, here. -/
theorem internal_chain_bounded_query {s : StepRec} {rest : List StepRec}
    (chain : InternalChain Loop.queryAsk (s :: rest))
    (routerFacts : ∀ t ∈ rest, ∀ v, t.event = .tuple [a "fact", v] → (v == nil) = false) :
    (s :: rest).length ≤
      4 * (countSteps YieldStep rest + countSteps ExtendStep rest + countSteps ChangedStep rest + 1) := by
  have bound := internal_chain_bounded chain
  have kinds : reentries Loop.queryAsk rest ≤
      countSteps YieldStep rest + countSteps ExtendStep rest + countSteps ChangedStep rest := by
    unfold reentries countSteps
    apply countP_le_three
    intro t member re
    simp only [decide_eq_true_eq] at re ⊢
    exact reentry_kinds (chain_tail_answers chain t member) (routerFacts t member) re
  omega

/-! ## Extension steps -/

/-- The next extension reads the wait that the previous extension committed:
the wait of the `wait_set` event in its commit. This is the host contract H1
(the commit lands before the next step reads the state) with the `wait_set`
reducer. -/
def WaitLinked (e e' : StepRec) : Prop :=
  ∀ event next w, outEffects e.out = extendEffects event next →
    Returns (field e'.state "wait") w → w = event.get (b "wait")

/-- Each extension step is linked to the next one. -/
def Linked : List StepRec → Prop
  | [] => True
  | [_] => True
  | e :: e' :: rest => WaitLinked e e' ∧ Linked (e' :: rest)

theorem extension_steps_chain {C : Int} :
    ∀ {e : StepRec} {es : List StepRec}, (∀ x ∈ e :: es, ExtendStep x) →
      (∀ x ∈ e :: es, integerValue (fact x.machine "ceiling_ms") ≤ C) →
      Linked (e :: es) →
      ∃ w last, Returns (field e.state "wait") w ∧ ExtensionChain C w (es.length + 1) last
  | e, [], extending, ceilings, _ => by
    obtain ⟨v, wait, now, next, event, _, read, decided, _⟩ := extending e List.mem_cons_self
    exact ⟨wait, next, read, .extend (ceilings e List.mem_cons_self) decided (.done next)⟩
  | e, e' :: es, extending, ceilings, linked => by
    obtain ⟨v, wait, now, next, event, _, read, decided, effects, carried⟩ := extending e List.mem_cons_self
    have rest := extension_steps_chain (e := e') (es := es)
      (fun x member => extending x (List.mem_cons_of_mem e member))
      (fun x member => ceilings x (List.mem_cons_of_mem e member)) linked.2
    obtain ⟨w', last, read', chain⟩ := rest
    have same := linked.1 event next w' effects read'
    rw [carried] at same
    subst same
    refine ⟨wait, last, read, ?_⟩
    simpa only [List.length_cons] using ExtensionChain.extend (ceilings e List.mem_cons_self) decided chain

open Classical in
/-- At most `C / 1000` extension steps when each extension reads the wait that
the previous one committed and every ceiling fact is at most `C`. -/
theorem extension_steps_bounded {C : Int} {steps : List StepRec}
    (linked : Linked (steps.filter (fun s => decide (ExtendStep s))))
    (ceilings : ∀ x ∈ steps, ExtendStep x → integerValue (fact x.machine "ceiling_ms") ≤ C) :
    1000 * (countSteps ExtendStep steps : Int) ≤ max C 0 := by
  unfold countSteps
  rw [List.countP_eq_length_filter]
  generalize hext : steps.filter (fun s => decide (ExtendStep s)) = ext at linked
  have members : ∀ x ∈ ext, ExtendStep x ∧ x ∈ steps := by
    intro x member
    rw [← hext, List.mem_filter] at member
    exact ⟨of_decide_eq_true member.2, member.1⟩
  cases ext with
  | nil => simp only [List.length_nil]; omega
  | cons e es =>
    obtain ⟨w, last, _, chain⟩ := extension_steps_chain (C := C) (e := e) (es := es)
      (fun x member => (members x member).1)
      (fun x member => ceilings x (members x member).2 (members x member).1) linked
    have := extensions_bounded chain
    simpa using this

open Classical in
/-- The internal chain bound with the wait extensions bounded by the ceiling.
Hypotheses: the host answers each Router fact with a present value, each
extension reads the wait that the previous extension committed (H1 with the
`wait_set` reducer), and each ceiling fact is at most `C`. Yields and changed
waits stay counted: this theorem does not bound them. -/
theorem internal_chain_bounded_wait {C : Int} {s : StepRec} {rest : List StepRec}
    (chain : InternalChain Loop.queryAsk (s :: rest))
    (routerFacts : ∀ t ∈ rest, ∀ v, t.event = .tuple [a "fact", v] → (v == nil) = false)
    (linked : Linked (rest.filter (fun t => decide (ExtendStep t))))
    (ceilings : ∀ x ∈ rest, ExtendStep x → integerValue (fact x.machine "ceiling_ms") ≤ C) :
    ((s :: rest).length : Int) ≤
      4 * ((countSteps YieldStep rest + countSteps ChangedStep rest + 1 : Nat) : Int) + 4 * (max C 0 / 1000) := by
  have total := internal_chain_bounded_query chain routerFacts
  have extensions := extension_steps_bounded linked ceilings
  push_cast at total ⊢
  omega

end VerifiedKernel.Session.Loop.Budget
