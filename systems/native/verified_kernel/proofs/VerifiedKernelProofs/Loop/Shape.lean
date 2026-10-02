import VerifiedKernelProofs.Loop.Source
import VerifiedKernelProofs.Session.AppendOnly.Core
import VerifiedKernelProofs.Session.WorkAllocation

/-! # Loop shape and effect sources

`step_shape`: every successful step returns a machine and an effect list of
notifications, at most one commit, non-blocking effects, and one blocking
effect. This holds for every query oracle.

`step_commit_source`, `step_dispatch_source` and `step_write_source`: for the
kernel oracle, every `commit`, `run_tools` and `write` effect has the source
that `Loop/Source.lean` names. `step_dispatch_after_commit`: a model-turn
dispatch follows the intent commit of the same step. -/

namespace VerifiedKernel.Session.LoopProof
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

open Lean Elab Tactic in
/-- `unfold_native_at "Full.Private.Name" h` unfolds a private runtime helper in `h`. -/
elab "unfold_native_at " requested:str h:ident : tactic => do
  let id := mkIdent (← WorkConservation.nativeDecl requested.getString)
  evalTactic (← `(tactic| unfold $id:ident at $h:ident))

/-- `loop% name`: the runtime helper `VerifiedKernel.Session.Loop.name`, private or not. -/
syntax "loop% " ident : term
macro_rules
  | `(loop% $n) => `(native_decl% $(Lean.quote ("VerifiedKernel.Session.Loop." ++ n.getId.eraseMacroScopes.toString)))

/-- `unfold_loop name` unfolds the runtime helper `Loop.name` in `h`. -/
syntax "unfold_loop " ident : tactic
macro_rules
  | `(tactic| unfold_loop $n) => do
    let h := Lean.mkIdent `h
    `(tactic| unfold_native_at $(Lean.quote ("VerifiedKernel.Session.Loop." ++ n.getId.eraseMacroScopes.toString)) $h)

/-! ## Shape predicates -/

/-- Non-blocking effects, then one blocking effect. -/
inductive TailShape : List Term → Prop
  | last {e : Term} : Blocking e → TailShape [e]
  | cons {e : Term} {rest : List Term} : AfterCommit e → TailShape rest → TailShape (e :: rest)

/-- Notifications, then an optional commit, then a `TailShape`. -/
inductive HeadShape : List Term → Prop
  | tail {effects : List Term} : TailShape effects → HeadShape effects
  | commit {e : Term} {rest : List Term} : effectKind e = .commit → TailShape rest → HeadShape (e :: rest)
  | notify {e : Term} {rest : List Term} : effectKind e = .notify → HeadShape rest → HeadShape (e :: rest)

theorem TailShape.split {effects : List Term} (h : TailShape effects) :
    ∃ mid last, effects = mid ++ [last] ∧ (∀ e ∈ mid, AfterCommit e) ∧ Blocking last := by
  induction h with
  | last blocking => exact ⟨[], _, rfl, by simp, blocking⟩
  | cons after _ ih =>
    obtain ⟨mid, last, rfl, mids, blocking⟩ := ih
    refine ⟨_ :: mid, last, rfl, ?_, blocking⟩
    intro e member
    rcases List.mem_cons.mp member with rfl | member
    · exact after
    · exact mids e member

theorem HeadShape.stepShape {effects : List Term} (h : HeadShape effects) : StepShape effects := by
  induction h with
  | tail t =>
    obtain ⟨mid, last, rfl, mids, blocking⟩ := t.split
    exact ⟨[], none, mid, last, by simp, by simp, by simp, mids, blocking⟩
  | @commit e rest kind t =>
    obtain ⟨mid, last, rfl, mids, blocking⟩ := t.split
    refine ⟨[], some e, mid, last, by simp, by simp, ?_, mids, blocking⟩
    intro e member
    simp only [Option.toList_some, List.mem_singleton] at member
    subst member
    exact kind
  | @notify e rest kind _ ih =>
    obtain ⟨pre, commit, mid, last, rfl, pres, commits, mids, blocking⟩ := ih
    refine ⟨e :: pre, commit, mid, last, by simp, ?_, commits, mids, blocking⟩
    intro e member
    rcases List.mem_cons.mp member with rfl | member
    · exact kind
    · exact pres e member

theorem HeadShape.notifies {xs ys : List Term} (kinds : ∀ e ∈ xs, effectKind e = .notify)
    (h : HeadShape ys) : HeadShape (xs ++ ys) := by
  induction xs with
  | nil => exact h
  | cons x xs ih =>
    exact HeadShape.notify (kinds x (by simp)) (ih (fun e member => kinds e (by simp [member])))

/-- A step result with a well-shaped effect list. -/
def ShapeOut (out : Term) : Prop := ∃ machine effects, out = .tuple [machine, list effects] ∧ HeadShape effects

syntax "solve_head" : tactic
macro_rules
  | `(tactic| solve_head) => `(tactic|
    (repeat' first
      | exact TailShape.last (by rfl)
      | exact HeadShape.tail (TailShape.last (by rfl))
      | refine HeadShape.notify (by rfl) ?_
      | refine HeadShape.commit (by rfl) ?_
      | refine TailShape.cons (Or.inl (by rfl)) ?_
      | refine TailShape.cons (Or.inr (Or.inl (by rfl))) ?_
      | refine TailShape.cons (Or.inr (Or.inr (Or.inl (by rfl)))) ?_
      | refine TailShape.cons (Or.inr (Or.inr (Or.inr (by rfl)))) ?_
      | split
      | simp only [List.append_eq, List.cons_append, List.nil_append]
      | refine HeadShape.tail ?_))

/-- Split the kernel execution `h` into its branches. Each bound action stays as a hypothesis. -/
syntax "run_split" : tactic
macro_rules
  | `(tactic| run_split) => do
    let h := Lean.mkIdent `h
    let prior := Lean.mkIdent `prior
    `(tactic|
    (repeat' first
      | (head_is $h [VerifiedKernel.fail, argumentError, inspectedError]; exact (fail_ok $h).elim)
      | (execution_head_is $h "Pure.pure"
         have returned := pure_ok $h
         clear $h
         subst returned)
      | (execution_head_is $h "Bind.bind"
         have bound := bind_ok $h
         clear $h
         rcases bound with ⟨_, _, $prior:ident, $h:ident⟩
         try (head_is $prior [VerifiedKernel.fail, argumentError, inspectedError]; exact (fail_ok $prior).elim)
         try (execution_head_is $prior "Pure.pure"
              have returned := pure_ok $prior
              clear $prior
              subst returned))
      | (execution_head_is $h "ite"
         have branch := ite_ok_iff.mp $h
         clear $h
         rcases branch with ⟨_, $h:ident⟩ | ⟨_, $h:ident⟩)
      | dsimp only at $h:ident
      | split at $h:ident))

syntax "close_shape" : tactic
macro_rules
  | `(tactic| close_shape) => `(tactic| (refine ⟨_, _, rfl, ?_⟩; solve_head; done))

/-! ## Helper shapes -/

theorem guardOutcome_shape {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop% guardOutcome) ask state machine j = .ok (out, j')) : ShapeOut out := by
  unfold_loop guardOutcome
  run_split
  all_goals close_shape

theorem park_shape {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop% park) ask state machine j = .ok (out, j')) : ShapeOut out := by
  unfold_loop park
  run_split
  all_goals close_shape

theorem guardNotice_shape {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop% guardNotice) ask state machine j = .ok (out, j')) : ShapeOut out := by
  unfold_loop guardNotice
  unfold_loop finalStop
  run_split
  all_goals close_shape

theorem noticeCleanup_shape {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop% noticeCleanup) ask state machine j = .ok (out, j')) : ShapeOut out := by
  unfold_loop noticeCleanup
  run_split
  all_goals close_shape

theorem finalize_shape {ask : Loop.Ask} {state machine terminal out : Term} {j j' : List Term}
    (h : (loop% finalize) ask state machine terminal j = .ok (out, j')) : ShapeOut out := by
  unfold_loop finalize
  run_split
  all_goals close_shape

theorem finalRecord_shape {ask : Loop.Ask} {state machine record out : Term} {j j' : List Term}
    (h : (loop% finalRecord) ask state machine record j = .ok (out, j')) : ShapeOut out := by
  unfold_loop finalRecord
  run_split
  all_goals first
    | close_shape
    | exact finalize_shape (by assumption)

theorem modelFailure_shape {ask : Loop.Ask} {state machine info out : Term} {recover : Bool}
    {j j' : List Term}
    (h : (loop% modelFailure) ask state machine info recover j = .ok (out, j')) : ShapeOut out := by
  unfold_loop modelFailure
  run_split
  all_goals close_shape

theorem modelFailed_shape {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop% modelFailed) ask state machine j = .ok (out, j')) : ShapeOut out := by
  unfold_loop modelFailed
  run_split
  all_goals close_shape

theorem shape_after_park {next parked : Term} {prefix_ : List Term}
    (kinds : ∀ e ∈ prefix_, effectKind e = .notify)
    (parkOut : ShapeOut (.tuple [next, parked])) : ShapeOut (.tuple [next, list (prefix_ ++ wrap parked)]) := by
  obtain ⟨m, effs, same, shape⟩ := parkOut
  simp only [Term.tuple.injEq, List.cons.injEq, and_true] at same
  obtain ⟨rfl, rfl⟩ := same
  exact ⟨_, _, rfl, HeadShape.notifies kinds shape⟩

theorem outputCommitted_shape {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop% outputCommitted) ask state machine j = .ok (out, j')) : ShapeOut out := by
  unfold_loop outputCommitted
  run_split
  all_goals first
    | (refine ⟨_, _, rfl, HeadShape.notifies ?_ ?_⟩
       · intro e member
         obtain ⟨x, _, rfl⟩ := List.mem_map.mp member
         split <;> rfl
       · solve_head; done)
    | (apply shape_after_park _ (park_shape prior)
       intro e member
       obtain ⟨x, _, rfl⟩ := List.mem_map.mp member
       split <;> rfl)

theorem toolTurn_shape {machine outcome out : Term} {j j' : List Term}
    (h : (loop% toolTurn) machine outcome j = .ok (out, j')) : ShapeOut out := by
  unfold_loop toolTurn
  run_split
  all_goals close_shape

theorem intentRecord_shape {state machine record out : Term} {j j' : List Term}
    (h : (loop% intentRecord) state machine record j = .ok (out, j')) : ShapeOut out := by
  unfold_loop intentRecord
  run_split
  all_goals first
    | close_shape
    | exact toolTurn_shape (by assumption)

theorem toolsDone_shape {ask : Loop.Ask} {state machine results async out : Term} {j j' : List Term}
    (h : (loop% toolsDone) ask state machine results async j = .ok (out, j')) : ShapeOut out := by
  unfold_loop toolsDone
  run_split
  all_goals close_shape

theorem resultsStored_shape {ask : Loop.Ask} {state machine events hwm base stored out : Term}
    {j j' : List Term}
    (h : (loop% resultsStored) ask state machine events hwm base stored j = .ok (out, j')) : ShapeOut out := by
  unfold_loop resultsStored
  run_split
  all_goals close_shape

theorem continuation_shape {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop% continuation) ask state machine j = .ok (out, j')) : ShapeOut out := by
  unfold_loop continuation
  run_split
  all_goals first
    | close_shape
    | (apply shape_after_park _ (park_shape prior)
       split <;>
       · intro e member
         simp only [List.nil_append, List.cons_append, List.mem_cons, List.not_mem_nil, or_false] at member
         rcases member with rfl | rfl | rfl <;> rfl)

theorem decide_cases {wait busy now ceiling d : Term}
    (hd : AgentLoop.WaitExtension.decide wait busy now ceiling = d) :
    d = a "wake" ∨ ∃ next, d = .tuple [a "extend", next] := by
  subst hd
  unfold AgentLoop.WaitExtension.decide
  repeat' first
    | exact Or.inl rfl
    | exact Or.inr ⟨_, rfl⟩
    | split
    | dsimp only

/-- Split a `WaitExtension.decide` match in `h` into its wake and extend cases. -/
syntax "split_decide" : tactic
macro_rules
  | `(tactic| split_decide) => do
    let h := Lean.mkIdent `h
    let hd := Lean.mkIdent `hd
    `(tactic| (generalize $hd:ident : AgentLoop.WaitExtension.decide _ _ _ _ = d at $h:ident
               rcases decide_cases $hd with rfl | ⟨_, rfl⟩ <;> dsimp only [a] at $h:ident))

theorem expire_shape {state machine busy out : Term} {j j' : List Term}
    (h : (loop% expire) state machine busy j = .ok (out, j')) : ShapeOut out := by
  unfold_loop expire
  run_split
  all_goals try close_shape
  all_goals split_decide
  all_goals run_split
  all_goals close_shape

theorem expireEntry_shape {state machine out : Term} {j j' : List Term}
    (h : (loop% expireEntry) state machine j = .ok (out, j')) : ShapeOut out := by
  unfold_loop expireEntry
  run_split
  all_goals first
    | close_shape
    | exact expire_shape h

theorem activation_shape {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop% activation) ask state machine j = .ok (out, j')) : ShapeOut out := by
  unfold_loop activation
  run_split
  all_goals first
    | close_shape
    | exact expireEntry_shape h

theorem timeoutEntry_shape {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop% timeoutEntry) ask state machine j = .ok (out, j')) : ShapeOut out := by
  unfold_loop timeoutEntry
  run_split
  all_goals first
    | close_shape
    | exact expireEntry_shape h

theorem parts_shape (r : Term) : ∃ k c cl pm tm, (loop% parts) r = .tuple [k, c, cl, pm, tm] := by
  unfold_native "VerifiedKernel.Session.Loop.parts"
  split <;> exact ⟨_, _, _, _, _, rfl⟩

/-- Expose the response parts and the `TurnOutcome.classify` decision of `classify`. -/
syntax "open_classify" : tactic
macro_rules
  | `(tactic| open_classify) => do
    let h := Lean.mkIdent `h
    let hp := Lean.mkIdent `hp
    `(tactic| (unfold_loop classify
               obtain ⟨_, _, _, _, _, $hp:ident⟩ := parts_shape ((loop% key) _ "response")
               rw [$hp:ident] at $h:ident
               dsimp only at $h:ident
               run_split
               all_goals try (generalize hc : AgentLoop.TurnOutcome.classify _ = c at $h:ident; run_split)))

theorem classify_shape {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop% classify) ask state machine j = .ok (out, j')) : ShapeOut out := by
  open_classify
  all_goals first
    | exact modelFailure_shape h
    | exact finalize_shape h
    | exact toolTurn_shape h
    | exact modelFailure_shape prior
    | exact finalize_shape prior
    | exact toolTurn_shape prior

theorem step_shape_out {ask : Loop.Ask} {state args out : Term} {j j' : List Term}
    (h : Loop.stepWith ask state args j = .ok (out, j')) : ShapeOut out := by
  unfold Loop.stepWith at h
  unfold_loop finalStop
  run_split
  -- Select the helper lemma by the execution head. A failed `exact` against another helper
  -- unfolds both helper bodies before it fails.
  all_goals first
    | close_shape
    | (execution_head_is h "VerifiedKernel.Session.Loop.guardNotice"
       exact guardNotice_shape h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.modelFailure"
       exact modelFailure_shape h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.finalRecord"
       exact finalRecord_shape h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.intentRecord"
       exact intentRecord_shape h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.toolsDone"
       exact toolsDone_shape h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.resultsStored"
       exact resultsStored_shape h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.activation"
       exact activation_shape h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.timeoutEntry"
       exact timeoutEntry_shape h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.expire"
       exact expire_shape h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.classify"
       exact classify_shape h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.outputCommitted"
       exact outputCommitted_shape h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.modelFailed"
       exact modelFailed_shape h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.noticeCleanup"
       exact noticeCleanup_shape h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.guardOutcome"
       exact guardOutcome_shape h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.continuation"
       exact continuation_shape h)

/-- Every successful step returns a machine and an effect list of notifications,
at most one commit, non-blocking effects, and one blocking effect. This holds
for every query oracle. -/
theorem step_shape {ask : Loop.Ask} {state args out : Term} {j j' : List Term}
    (h : Loop.stepWith ask state args j = .ok (out, j')) :
    ∃ machine' effects, out = .tuple [machine', list effects] ∧ StepShape effects := by
  obtain ⟨machine', effects, same, shape⟩ := step_shape_out h
  exact ⟨machine', effects, same, shape.stepShape⟩

/-! ## Sources -/

/-- The leading atom of an effect. -/
def effectName : Term → String
  | .tuple (.atom n :: _) => n
  | .atom n => n
  | _ => ""

/-- A commit, `run_tools` or `write` effect has its source. -/
def ElemSourced (state machine event e : Term) : Prop :=
  (∀ events opts mode, e = commitEffect events opts mode → CommitSource state machine event events opts mode) ∧
  (∀ calls flags, e = runToolsEffect calls flags → DispatchSource state machine event calls flags) ∧
  (∀ events, e = writeEffect events → WriteSource state machine event events)

def Sourced (state machine event : Term) (effects : List Term) : Prop :=
  ∀ e ∈ effects, ElemSourced state machine event e

def SourcedOut (state machine event out : Term) : Prop :=
  ∃ machine' effects, out = .tuple [machine', list effects] ∧ Sourced state machine event effects

theorem elem_plain {state machine event e : Term} (hc : effectName e ≠ "commit")
    (hr : effectName e ≠ "run_tools") (hw : effectName e ≠ "write") :
    ElemSourced state machine event e := by
  refine ⟨fun _ _ _ he => ?_, fun _ _ he => ?_, fun _ he => ?_⟩ <;> subst he
  · exact absurd rfl hc
  · exact absurd rfl hr
  · exact absurd rfl hw

/-- `elem_named n rfl` for an effect whose leading atom is `n`. -/
theorem elem_named {state machine event e : Term} (n : String) (named : effectName e = n)
    (hc : n ≠ "commit") (hr : n ≠ "run_tools") (hw : n ≠ "write") :
    ElemSourced state machine event e := by
  subst named
  exact elem_plain hc hr hw

theorem elem_commit {state machine event opts mode : Term} {events : List Term}
    (source : CommitSource state machine event events opts mode) :
    ElemSourced state machine event (commitEffect events opts mode) := by
  refine ⟨fun _ _ _ he => ?_, fun _ _ he => ?_, fun _ he => ?_⟩
  · simp only [commitEffect, Term.tuple.injEq, List.cons.injEq, and_true] at he
    obtain ⟨_, he, rfl, rfl⟩ := he
    injection he with he
    subst he
    exact source
  · exact absurd (show "commit" = "run_tools" from congrArg effectName he) (by decide)
  · exact absurd (show "commit" = "write" from congrArg effectName he) (by decide)

theorem elem_run_tools {state machine event calls flags : Term}
    (source : DispatchSource state machine event calls flags) :
    ElemSourced state machine event (runToolsEffect calls flags) := by
  refine ⟨fun _ _ _ he => ?_, fun _ _ he => ?_, fun _ he => ?_⟩
  · exact absurd (show "run_tools" = "commit" from congrArg effectName he) (by decide)
  · simp only [runToolsEffect, Term.tuple.injEq, List.cons.injEq, and_true] at he
    obtain ⟨_, rfl, rfl⟩ := he
    exact source
  · exact absurd (show "run_tools" = "write" from congrArg effectName he) (by decide)

theorem elem_write {state machine event : Term} {events : List Term}
    (source : WriteSource state machine event events) :
    ElemSourced state machine event (writeEffect events) := by
  refine ⟨fun _ _ _ he => ?_, fun _ _ he => ?_, fun _ he => ?_⟩
  · exact absurd (show "write" = "commit" from congrArg effectName he) (by decide)
  · exact absurd (show "write" = "run_tools" from congrArg effectName he) (by decide)
  · simp only [writeEffect, Term.tuple.injEq, List.cons.injEq, and_true] at he
    obtain ⟨_, he⟩ := he
    injection he with he
    subst he
    exact source

theorem Sourced.nil {state machine event : Term} : Sourced state machine event [] := by
  intro _ member; cases member

theorem Sourced.cons {state machine event e : Term} {rest : List Term}
    (head : ElemSourced state machine event e) (tail : Sourced state machine event rest) :
    Sourced state machine event (e :: rest) := by
  intro x member
  rcases List.mem_cons.mp member with rfl | member
  · exact head
  · exact tail x member

theorem Sourced.append {state machine event : Term} {xs ys : List Term}
    (left : Sourced state machine event xs) (right : Sourced state machine event ys) :
    Sourced state machine event (xs ++ ys) := by
  intro x member
  rcases List.mem_append.mp member with member | member
  · exact left x member
  · exact right x member

syntax "solve_sourced" : tactic
macro_rules
  | `(tactic| solve_sourced) => `(tactic|
    (repeat' first
      | exact Sourced.nil
      | refine Sourced.cons (elem_named "notify" rfl (by decide) (by decide) (by decide)) ?_
      | refine Sourced.cons (elem_named "continue" rfl (by decide) (by decide) (by decide)) ?_
      | refine Sourced.cons (elem_named "stop" rfl (by decide) (by decide) (by decide)) ?_
      | refine Sourced.cons (elem_named "build_record" rfl (by decide) (by decide) (by decide)) ?_
      | refine Sourced.cons (elem_named "store_results" rfl (by decide) (by decide) (by decide)) ?_
      | refine Sourced.cons (elem_named "commit_planned_results" rfl (by decide) (by decide) (by decide)) ?_
      | refine Sourced.cons (elem_named "fact" rfl (by decide) (by decide) (by decide)) ?_
      | refine Sourced.cons (elem_named "materialize" rfl (by decide) (by decide) (by decide)) ?_
      | refine Sourced.cons (elem_named "set_timer" rfl (by decide) (by decide) (by decide)) ?_
      | refine Sourced.cons (elem_named "cancel_timer" rfl (by decide) (by decide) (by decide)) ?_
      | refine Sourced.cons ?_ ?_
      | split
      | simp only [List.append_eq, List.cons_append, List.nil_append]))

syntax "close_sourced" : tactic
macro_rules
  | `(tactic| close_sourced) => `(tactic| (refine ⟨_, _, rfl, ?_⟩; solve_sourced; done))

theorem notify_sourced {state machine event : Term} {xs : List Term}
    (kinds : ∀ e ∈ xs, effectName e = "notify") : Sourced state machine event xs :=
  fun e member => elem_named "notify" (kinds e member) (by decide) (by decide) (by decide)

theorem guardOutcome_sourced {ask : Loop.Ask} {state machine event m out : Term} {j j' : List Term}
    (h : (loop% guardOutcome) ask state m j = .ok (out, j')) : SourcedOut state machine event out := by
  unfold_loop guardOutcome
  run_split
  all_goals close_sourced

theorem park_sourced {ask : Loop.Ask} {state machine event m out : Term} {j j' : List Term}
    (h : (loop% park) ask state m j = .ok (out, j')) : SourcedOut state machine event out := by
  unfold_loop park
  run_split
  all_goals close_sourced

theorem finalize_sourced {ask : Loop.Ask} {state machine event m terminal out : Term} {j j' : List Term}
    (h : (loop% finalize) ask state m terminal j = .ok (out, j')) : SourcedOut state machine event out := by
  unfold_loop finalize
  run_split
  all_goals close_sourced

theorem modelFailed_sourced {ask : Loop.Ask} {state machine event m out : Term} {j j' : List Term}
    (h : (loop% modelFailed) ask state m j = .ok (out, j')) : SourcedOut state machine event out := by
  unfold_loop modelFailed
  run_split
  all_goals close_sourced

theorem toolTurn_sourced {state machine event m outcome out : Term} {j j' : List Term}
    (h : (loop% toolTurn) m outcome j = .ok (out, j')) : SourcedOut state machine event out := by
  unfold_loop toolTurn
  run_split
  all_goals close_sourced

theorem toolsDone_sourced {ask : Loop.Ask} {state machine event m results async out : Term} {j j' : List Term}
    (h : (loop% toolsDone) ask state m results async j = .ok (out, j')) : SourcedOut state machine event out := by
  unfold_loop toolsDone
  run_split
  all_goals close_sourced

theorem sourced_after_park {state machine event next parked : Term} {prefix_ : List Term}
    (kinds : ∀ e ∈ prefix_, effectName e = "notify")
    (parkOut : SourcedOut state machine event (.tuple [next, parked])) :
    SourcedOut state machine event (.tuple [next, list (prefix_ ++ wrap parked)]) := by
  obtain ⟨m, effs, same, sourced⟩ := parkOut
  simp only [Term.tuple.injEq, List.cons.injEq, and_true] at same
  obtain ⟨rfl, rfl⟩ := same
  exact ⟨_, _, rfl, Sourced.append (notify_sourced kinds) sourced⟩

theorem outputCommitted_sourced {ask : Loop.Ask} {state machine event m out : Term} {j j' : List Term}
    (h : (loop% outputCommitted) ask state m j = .ok (out, j')) : SourcedOut state machine event out := by
  unfold_loop outputCommitted
  run_split
  all_goals first
    | (refine ⟨_, _, rfl, Sourced.append (notify_sourced ?_) ?_⟩
       · intro e member
         obtain ⟨x, _, rfl⟩ := List.mem_map.mp member
         split <;> rfl
       · solve_sourced; done)
    | (apply sourced_after_park _ (park_sourced prior)
       intro e member
       obtain ⟨x, _, rfl⟩ := List.mem_map.mp member
       split <;> rfl)

theorem continuation_sourced {ask : Loop.Ask} {state machine event m out : Term} {j j' : List Term}
    (h : (loop% continuation) ask state m j = .ok (out, j')) : SourcedOut state machine event out := by
  unfold_loop continuation
  run_split
  all_goals first
    | close_sourced
    | (apply sourced_after_park _ (park_sourced prior)
       split <;>
       · intro e member
         simp only [List.nil_append, List.cons_append, List.mem_cons, List.not_mem_nil, or_false] at member
         rcases member with rfl | rfl | rfl <;> rfl)

theorem not_not_true {x : Bool} (h : ¬(!x) = true) : x = true := by cases x <;> simp_all

theorem not_true_false {x : Bool} (h : ¬x = true) : x = false := by cases x <;> simp_all

open WorkConservation (binary_key_beq get_put_binary_other)

theorem mkey_eq_get (m : Term) (k : String) : mkey m k = m.get (b k) := by
  unfold mkey; cases m <;> rfl

theorem loop_key_mkey (m : Term) (k : String) : (loop% key) m k = mkey m k := rfl

theorem loop_fact (m : Term) (k : String) : (loop% fact) m k = fact m k := rfl

theorem loop_phase_put (m : Term) (n : String) : (loop% phase) m n = m.put (b "phase") (b n) := rfl

theorem get_put_same (m v : Term) (k : String) : (m.put (b k) v).get (b k) = v := by
  cases m <;> simp [Term.put, Term.get, binary_key_beq]

theorem mkey_put_other (m v : Term) {k k' : String} (ne : k ≠ k') : mkey (m.put (b k) v) k' = mkey m k' := by
  rw [mkey_eq_get, mkey_eq_get]; exact get_put_binary_other _ _ ne

theorem mkey_put_same (m v : Term) (k : String) : mkey (m.put (b k) v) k = v := by
  rw [mkey_eq_get]; exact get_put_same _ _ _

theorem ne_nil_of_not_isEmpty {xs : List Term} (h : ¬xs.isEmpty = true) : xs ≠ [] := by
  intro same; subst same; exact h rfl

/-- Normalize machine reads: rewrite the private `key`, `fact` and `phase` to
`mkey`, `fact` and `put`, and read through puts of other keys. -/
syntax "machine_norm" : tactic
macro_rules
  | `(tactic| machine_norm) => `(tactic|
    (try simp (disch := decide) only [loop_key_mkey, loop_fact, loop_phase_put, mkey_put_same,
      mkey_put_other] at *))

theorem noticeCleanup_sourced {state machine event out : Term} {j j' : List Term}
    (entry : event = a "continue" ∧ phaseIs machine "notice_cleanup")
    (h : (loop% noticeCleanup) Loop.queryAsk state machine j = .ok (out, j')) :
    SourcedOut state machine event out := by
  unfold_loop noticeCleanup
  run_split
  all_goals refine ⟨_, _, rfl, ?_⟩
  all_goals solve_sourced
  all_goals machine_norm
  all_goals first
    | (refine elem_commit ?_
       obtain ⟨rfl, _⟩ := asList_ok_iff.mp prior
       exact CommitSource.noticeCleanup _ _ entry ⟨_, _, ‹_›⟩ (ne_nil_of_not_isEmpty ‹_›))
    | (refine elem_run_tools ?_
       obtain ⟨rfl, _⟩ := asList_ok_iff.mp prior
       exact DispatchSource.notice _ _ entry ⟨_, _, ‹_›⟩ ‹_›)

theorem host_admission_ok {events : List Term} {u : Unit} {j j' : List Term}
    (h : Loop.admitHostEvents events j = .ok (u, j')) : Loop.hostEventsList events = a "ok" := by
  unfold Loop.admitHostEvents at h
  run_split
  rename_i passed
  exact atom_beq_true (by simpa [bne] using passed)

theorem fresh_ok {state record : Term} {x : Bool} {j j' : List Term}
    (h : (loop% fresh) state record j = .ok (x, j')) :
    ∃ nmid, FieldIs state "next_message_id" nmid ∧ x = (mkey record "base" == nmid) := by
  unfold_loop fresh
  run_split
  exact ⟨_, ⟨_, _, ‹_›⟩, rfl⟩

theorem runawayUnsettled_ok {sid aid content nonce x : Term} {j j' : List Term}
    (h : (loop% runawayUnsettled) sid aid content nonce j = .ok (x, j')) :
    ∃ eventId created, x = unsettledEvent eventId aid (contentBytes content) created := by
  unfold_loop runawayUnsettled
  run_split
  exact ⟨_, _, rfl⟩

theorem runawayReset_ok {sid aid calls nonce x : Term} {j j' : List Term}
    (h : (loop% runawayReset) sid aid calls nonce j = .ok (x, j')) :
    ∃ eventId created, x = resetEvent eventId aid (i (wrap calls).length) created := by
  unfold_loop runawayReset
  run_split
  exact ⟨_, _, rfl⟩

theorem truthy_ok {ask : Loop.Ask} {state args : Term} {name : String} {x : Bool} {j j' : List Term}
    (h : (loop% truthy) ask state name args j = .ok (x, j')) :
    ∃ v j'', ask state name args j = .ok (v, j'') ∧ x = v.truthy := by
  unfold_loop truthy
  run_split
  exact ⟨_, _, ‹_›, rfl⟩

theorem finishHwm_other {opts aid : Term} (other : ∀ head h, opts = list [.tuple [head, h]] → False) :
    finishHwm opts aid = aid := by
  unfold finishHwm
  split
  · exact (other _ _ rfl).elim
  · rfl

theorem fresh_true {state record : Term} {x : Bool} {j j' : List Term}
    (h : (loop% fresh) state record j = .ok (x, j')) (passed : ¬(!x) = true) :
    ∃ nmid, FieldIs state "next_message_id" nmid ∧ (mkey record "base" == nmid) = true := by
  obtain ⟨nmid, field, rfl⟩ := fresh_ok h
  exact ⟨nmid, field, not_not_true passed⟩

theorem finalRecord_sourced {state machine event record out : Term} {j j' : List Term}
    (entry : event = .tuple [a "record", record]) (phase : phaseIs machine "final_record")
    (h : (loop% finalRecord) Loop.queryAsk state machine record j = .ok (out, j')) :
    SourcedOut state machine event out := by
  unfold_loop finalRecord
  run_split
  all_goals first
    | exact finalize_sourced h
    | exact finalize_sourced prior
    | skip
  all_goals refine ⟨_, _, rfl, ?_⟩
  all_goals solve_sourced
  all_goals refine elem_commit ?_
  all_goals
    obtain ⟨nmid, hn, fresh⟩ := fresh_true (hyp% (loop% fresh) _ _ _ = _) ‹_›
    obtain ⟨eid, created, rfl⟩ := runawayUnsettled_ok (hyp% (loop% runawayUnsettled) _ _ _ _ _ = _)
    have committed := (asList_ok_iff.mp (hyp% asList _ _ = _)).1
    have checked := host_admission_ok (hyp% Loop.admitHostEvents _ _ = _)
  all_goals first
    | exact CommitSource.finalOutput _ _ _ _ _ _ _ _ _ _ _ _ entry phase hn fresh checked rfl ⟨_, _, ‹_›⟩
        ⟨_, _, (hyp% Loop.queryAsk _ "finish_output" _ _ = _)⟩
        (Or.inl ⟨‹_›, _, _, _, (hyp% Loop.queryAsk _ "onboarding_settlement" _ _ = _)⟩) committed
    | exact CommitSource.finalOutput _ _ _ _ _ _ _ _ _ _ _ _ entry phase hn fresh checked rfl ⟨_, _, ‹_›⟩
        ⟨_, _, (hyp% Loop.queryAsk _ "finish_output" _ _ = _)⟩ (Or.inr ⟨not_true_false ‹_›, rfl⟩) committed
    | (have source := CommitSource.finalOutput _ _ _ _ _ _ _ _ _ _ _ _ entry phase hn fresh checked rfl
          ⟨_, _, ‹_›⟩ ⟨_, _, (hyp% Loop.queryAsk _ "finish_output" _ _ = _)⟩
          (Or.inl ⟨‹_›, _, _, _, (hyp% Loop.queryAsk _ "onboarding_settlement" _ _ = _)⟩) committed
       rw [finishHwm_other ‹_›] at source
       exact source)
    | (have source := CommitSource.finalOutput _ _ _ _ _ _ _ _ _ _ _ _ entry phase hn fresh checked rfl
          ⟨_, _, ‹_›⟩ ⟨_, _, (hyp% Loop.queryAsk _ "finish_output" _ _ = _)⟩ (Or.inr ⟨not_true_false ‹_›, rfl⟩)
          committed
       rw [finishHwm_other ‹_›] at source
       exact source)

theorem guardNotice_sourced {state machine event out : Term} {j j' : List Term}
    (entry : GuardEntry machine event)
    (h : (loop% guardNotice) Loop.queryAsk state (guardMachine machine event) j = .ok (out, j')) :
    SourcedOut state machine event out := by
  unfold_loop guardNotice
  unfold_loop finalStop
  run_split
  all_goals first
    | close_sourced
    | (refine ⟨_, _, rfl, ?_⟩; solve_sourced)
  all_goals refine elem_commit ?_
  · obtain ⟨rfl, _⟩ := asList_ok_iff.mp (hyp% asList _ _ = _)
    exact CommitSource.guardRetire _ entry ⟨_, _, ‹_›⟩
  · obtain ⟨rfl, _⟩ := asList_ok_iff.mp (hyp% asList _ _ = _)
    exact CommitSource.guardLocal _ _ entry ⟨_, _, ‹_›⟩ (not_true_false ‹_›) ⟨_, _, ‹_›⟩
  · exact CommitSource.notice _ _ _ _ _ _ _ _ entry ⟨_, _, ‹_›⟩ (not_true_false ‹_›) ⟨_, _, ‹_›⟩
      (not_true_false ‹_›) ⟨_, _, ‹_›⟩ (not_true_false ‹_›) (not_not_true ‹_›) ⟨_, _, ‹_›⟩ ⟨_, _, ‹_›⟩
      ⟨_, _, ‹_›⟩ (not_not_true ‹_›) ⟨_, _, ‹_›⟩ (not_not_true ‹_›)

theorem modelFailure_sourced {state machine event m info out : Term} {recover : Bool} {j j' : List Term}
    (entry : FailureEntry machine event)
    (round : mkey m "round" = failureRound machine event)
    (overflowEntry : recover = true →
      (event = a "continue" ∧ phaseIs machine "classify") ∧ mkey m "round" = mkey machine "round")
    (h : (loop% modelFailure) Loop.queryAsk state m info recover j = .ok (out, j')) :
    SourcedOut state machine event out := by
  unfold_loop modelFailure
  run_split
  all_goals refine ⟨_, _, rfl, ?_⟩
  all_goals solve_sourced
  all_goals refine elem_commit ?_
  · have cond := (hyp% (recover && _ && _) = true)
    simp only [Bool.and_eq_true, Bool.not_eq_true'] at cond
    obtain ⟨entry', hround⟩ := overflowEntry cond.1.1
    exact CommitSource.overflow _ (i ((loop% ackHwm) m)) _ _ _ _ _ entry' ⟨_, _, (hyp% field state "session_id" _ = _)⟩
      (by rw [← hround] <;> rfl) ⟨_, _, (hyp% field state "context_overflow_recovery" _ = _)⟩ cond.2
      ⟨_, _, (hyp% field state "summary_sequence" _ = _)⟩ ⟨_, _, (hyp% field state "compacted_through" _ = _)⟩
  all_goals
    obtain ⟨v, _, hv, hx⟩ := truthy_ok prior
    subst hx
    have src := CommitSource.modelFailure _ (i ((loop% ackHwm) m)) _ _ _ _ _ v entry ⟨_, _, (hyp% field state "session_id" _ = _)⟩
      (by rw [← round] <;> rfl) ⟨_, _, (hyp% Loop.queryAsk _ "llm_retry_metadata" _ _ = _)⟩
      ⟨_, _, (hyp% Command.project _ _ _ = _)⟩ ⟨_, _, hv⟩
  all_goals first
    | (simp only [(hyp% Term.truthy _ = true), ‹integerValue _ > 0›, ↓reduceIte] at src; exact src)
    | (simp only [(hyp% Term.truthy _ = true), ‹¬integerValue _ > 0›, ↓reduceIte] at src; exact src)
    | (simp only [not_true_false ‹¬Term.truthy _ = true›, ‹integerValue _ > 0›, ↓reduceIte,
         Bool.false_eq_true, List.append_nil] at src; exact src)
    | (simp only [not_true_false ‹¬Term.truthy _ = true›, ‹¬integerValue _ > 0›, ↓reduceIte,
         Bool.false_eq_true, List.append_nil] at src; exact src)

theorem advance_ok {m m' : Term} {event : AgentLoop.Round.Event} {expected : AgentLoop.Round.Command}
    {j j' : List Term} (h : (loop% advance) m event expected j = .ok (m', j')) :
    (AgentLoop.Round.step (decodeRoundOf (mkey m "rstate")) event).2 = expected ∧
      m' = m.put (b "rstate") ((loop% encodeRound) (AgentLoop.Round.step (decodeRoundOf (mkey m "rstate")) event).1) := by
  unfold_loop advance
  run_split
  rename_i same
  refine ⟨?_, rfl⟩
  change (AgentLoop.Round.step ((loop% decodeRound) ((loop% key) m "rstate")) event).2 = expected
  revert same
  cases (AgentLoop.Round.step ((loop% decodeRound) ((loop% key) m "rstate")) event).2 <;>
    cases expected <;> decide

theorem decode_encode (s : AgentLoop.Round.State) : decodeRoundOf ((loop% encodeRound) s) = s := by
  cases s <;> decide

theorem intentRecord_sourced {state machine event record out : Term} {j j' : List Term}
    (entry : event = .tuple [a "record", record]) (phase : phaseIs machine "intent")
    (h : (loop% intentRecord) state machine record j = .ok (out, j')) :
    SourcedOut state machine event out := by
  unfold_loop intentRecord
  run_split
  all_goals first
    | exact toolTurn_sourced h
    | exact toolTurn_sourced prior
    | skip
  all_goals refine ⟨_, _, rfl, ?_⟩
  all_goals solve_sourced
  all_goals
    obtain ⟨nmid, hn, fresh⟩ := fresh_true (hyp% (loop% fresh) _ _ _ = _) ‹_›
    have checked : Loop.hostEventsList (intentEvents record) = a "ok" := host_admission_ok ‹_›
    obtain ⟨r1, rfl⟩ := advance_ok (hyp% (loop% advance) machine _ _ _ = _)
    obtain ⟨r2, rfl⟩ := advance_ok (hyp% (loop% advance) _ _ _ _ = _)
    rw [mkey_put_same, decode_encode] at r2
  all_goals first
    | (refine elem_commit ?_
       have src := CommitSource.intent (machine := machine) (event := event) record _ entry phase hn fresh
         checked r1 r2
       first
         | (have hc : (mkey record "admission").isMap = true := ‹_›
            simp only [intentEvents, intentHwm, hc, ↓reduceIte] at src
            exact src)
         | (have hc : (mkey record "admission").isMap = false := not_true_false ‹_›
            simp only [intentEvents, intentHwm, hc, ↓reduceIte, Bool.false_eq_true] at src
            exact src))
    | (refine elem_run_tools ?_
       machine_norm
       exact DispatchSource.modelTurn record _ _ entry phase hn fresh checked)

theorem resultsStored_sourced {state machine event events hwm base stored out : Term} {j j' : List Term}
    (entry : event = .tuple [a "results_stored", events, hwm, base, stored])
    (phase : phaseIs machine "results" ∨ phaseIs machine "results_only" ∨ phaseIs machine "notice_results")
    (h : (loop% resultsStored) Loop.queryAsk state machine events hwm base stored j = .ok (out, j')) :
    SourcedOut state machine event out := by
  unfold_loop resultsStored
  run_split
  all_goals refine ⟨_, _, rfl, ?_⟩
  all_goals solve_sourced
  all_goals refine elem_commit ?_
  all_goals
    obtain ⟨_, _, rfl⟩ := runawayUnsettled_ok (hyp% (loop% runawayUnsettled) _ _ _ _ _ = _)
    obtain ⟨_, _, rfl⟩ := runawayReset_ok (hyp% (loop% runawayReset) _ _ _ _ _ = _)
    obtain ⟨_, _, _, rfl⟩ := truthy_ok (hyp% (loop% truthy) _ _ _ _ _ = _)
    obtain ⟨rfl, _⟩ := asList_ok_iff.mp (hyp% asList _ _ = _)
    exact CommitSource.settle _ _ _ _ _ _ _ _ _ _ _ _ entry phase ⟨_, _, (hyp% field state "next_message_id" _ = _)⟩
      (not_true_false ‹_›) (host_admission_ok ‹_›) ⟨_, _, (hyp% field state "session_id" _ = _)⟩ ⟨_, _, ‹_›⟩

/-- Where the timeout event that `expire` commits comes from. -/
def TimeoutFact (state machine event ev : Term) : Prop :=
  (∃ waitId source, ((∃ facts, event = .tuple [a "wait_timeout", waitId, source, facts]) ∨
      (event = a "continue" ∧ phaseIs machine "timeout" ∧
        waitId = mkey machine "wait_id" ∧ source = mkey machine "source")) ∧
    Answers state "wait_timeout_event" (.tuple [waitId, source]) ev ∧ (ev == nil) = false) ∨
  (∃ value, CarriedEntry machine event value ∧ mkey machine "entry" = b "wait_timeout" ∧
    ev = mkey machine "timeout_event")

theorem waitSetEvent_ok {state wait x : Term} {j j' : List Term}
    (h : (loop% waitSetEvent) state wait j = .ok (x, j')) :
    ∃ sid, FieldIs state "session_id" sid ∧ x = waitSetEvent sid wait := by
  unfold_loop waitSetEvent
  run_split
  exact ⟨_, ⟨_, _, ‹_›⟩, rfl⟩

theorem timeout_commit {state machine event ev : Term} (fact : TimeoutFact state machine event ev) :
    CommitSource state machine event [ev] (list []) nil := by
  rcases fact with ⟨waitId, source, entry, answer, present⟩ | ⟨value, entry, timer, rfl⟩
  · exact CommitSource.waitTimeoutFresh waitId source ev entry answer present
  · exact CommitSource.waitTimeoutCarried value entry timer

theorem expire_sourced {state machine event m busy out : Term} {j j' : List Term}
    (entry : WaitEntry machine event)
    (round : mkey m "round" = entryRound machine event)
    (timeout : mkey m "entry" = b "wait_timeout" → TimeoutFact state machine event (mkey m "timeout_event"))
    (h : (loop% expire) state m busy j = .ok (out, j')) :
    SourcedOut state machine event out := by
  unfold_loop expire
  run_split
  all_goals try split_decide
  all_goals run_split
  all_goals refine ⟨_, _, rfl, ?_⟩
  all_goals solve_sourced
  all_goals refine elem_commit ?_
  all_goals first
    | exact (‹∀ next, _ = Term.tuple [Term.atom "extend", next] → False› _ ‹_ = Term.tuple [a "extend", _]›).elim
    | (obtain ⟨sid, session, rfl⟩ := waitSetEvent_ok (hyp% (loop% waitSetEvent) _ _ _ = _)
       exact CommitSource.waitExtend sid _ busy _ _ _ entry session ⟨_, _, (hyp% field state "wait" _ = _)⟩
         (by rw [← round] <;> rfl) hd)
    | exact timeout_commit (timeout (WorkConservation.binary_beq_true ‹_›))

syntax "put_norm" : tactic
macro_rules
  | `(tactic| put_norm) => `(tactic|
    (try simp (disch := decide) only [loop_key_mkey, loop_phase_put, mkey_put_same, mkey_put_other]))

theorem expireEntry_sourced {state machine event m out : Term} {j j' : List Term}
    (entry : WaitEntry machine event)
    (round : mkey m "round" = entryRound machine event)
    (timeout : mkey m "entry" = b "wait_timeout" → TimeoutFact state machine event (mkey m "timeout_event"))
    (h : (loop% expireEntry) state m j = .ok (out, j')) :
    SourcedOut state machine event out := by
  unfold_loop expireEntry
  run_split
  all_goals first
    | close_sourced
    | exact expire_sourced entry (by put_norm; exact round) (by put_norm; exact timeout) h

theorem activation_sourced {state machine event m out : Term} {j j' : List Term}
    (entry : ActivationEntry machine event)
    (round : mkey m "round" = entryRound machine event)
    (router : mkey m "router" = activationRouter machine event)
    (timeout : mkey m "entry" = b "wait_timeout" → TimeoutFact state machine event (mkey m "timeout_event"))
    (h : (loop% activation) Loop.queryAsk state m j = .ok (out, j')) :
    SourcedOut state machine event out := by
  have hr : (loop% key) ((loop% phase) m "activation") "router" = activationRouter machine event := by
    put_norm; exact router
  unfold_loop activation
  rw [hr] at h
  run_split
  all_goals first
    | close_sourced
    | exact expireEntry_sourced (Or.inl entry) (by put_norm; exact round) (by put_norm; exact timeout) h
    | (refine ⟨_, _, rfl, ?_⟩
       solve_sourced
       refine elem_write ?_
       obtain ⟨rfl, _⟩ := asList_ok_iff.mp (hyp% asList _ _ = _)
       exact WriteSource.yield _ _ _ _ _ entry ⟨_, _, (hyp% Loop.queryAsk _ "activation_next" _ _ = _)⟩
         ⟨_, _, (hyp% Loop.queryAsk _ "wait_identity" _ _ = _)⟩ ⟨_, _, (hyp% field state "next_message_id" _ = _)⟩
         ⟨_, _, (hyp% field state "last_ack_message_id" _ = _)⟩
         ⟨_, _, (hyp% Loop.queryAsk _ "active_human_source_ids" _ _ = _)⟩
         ⟨_, _, (hyp% Loop.queryAsk _ "provider_wait_yield_events" _ _ = _)⟩ (ne_nil_of_not_isEmpty ‹_›))

theorem timeoutEntry_sourced {state machine event m out : Term} {j j' : List Term}
    (entry : (∃ facts, event = .tuple [a "wait_timeout", mkey m "wait_id", mkey m "source", facts]) ∨
      (event = a "continue" ∧ phaseIs machine "timeout" ∧ m = machine))
    (round : mkey m "round" = entryRound machine event)
    (h : (loop% timeoutEntry) Loop.queryAsk state m j = .ok (out, j')) :
    SourcedOut state machine event out := by
  have wait : WaitEntry machine event := by
    rcases entry with ⟨facts, same⟩ | ⟨same, phase, _⟩
    · exact Or.inr (Or.inl ⟨_, _, _, same⟩)
    · exact Or.inr (Or.inr (Or.inl ⟨same, phase⟩))
  unfold_loop timeoutEntry
  run_split
  all_goals first
    | close_sourced
    | (refine expireEntry_sourced wait (by put_norm; exact round) (fun _ => ?_) h
       put_norm
       refine Or.inl ⟨_, _, ?_, ⟨_, _, (hyp% Loop.queryAsk _ "wait_timeout_event" _ _ = _)⟩, not_true_false ‹_›⟩
       rcases entry with ⟨facts, same⟩ | ⟨same, phase, rfl⟩
       · exact Or.inl ⟨facts, same⟩
       · exact Or.inr ⟨same, phase, rfl, rfl⟩)

theorem classify_sourced {state machine event out : Term} {j j' : List Term}
    (entry : event = a "continue" ∧ phaseIs machine "classify")
    (h : (loop% classify) Loop.queryAsk state machine j = .ok (out, j')) :
    SourcedOut state machine event out := by
  have round : ∀ m', mkey m' "round" = mkey machine "round" →
      mkey m' "round" = failureRound machine event := by
    intro m' same; rw [same, entry.1]; rfl
  open_classify
  all_goals first
    | exact finalize_sourced h
    | exact toolTurn_sourced h
    | exact finalize_sourced prior
    | exact toolTurn_sourced prior
    | exact modelFailure_sourced (Or.inl entry) (round _ (by put_norm)) (fun _ => ⟨entry, by put_norm⟩) h
    | exact modelFailure_sourced (Or.inl entry) (round _ (by put_norm)) (fun _ => ⟨entry, by put_norm⟩) prior

theorem binary_ne {s t : String} (h : s ≠ t) : b s ≠ b t := by
  intro same
  have left := WorkConservation.binary_key_beq s t
  rw [same, WorkConservation.binary_key_beq] at left
  simp only [beq_self_eq_true] at left
  exact h (beq_iff_eq.mp left.symm)

theorem step_sourced_out {state machine event out : Term} {j j' : List Term}
    (h : Loop.stepWith Loop.queryAsk state (.tuple [machine, event]) j = .ok (out, j')) :
    SourcedOut state machine event out := by
  unfold Loop.stepWith at h
  unfold_loop finalStop
  run_split
  -- Select the helper lemma by the execution head. A failed `exact` against another helper
  -- unfolds both helper bodies before it fails.
  all_goals first
    | close_sourced
    | (execution_head_is h "VerifiedKernel.Session.Loop.guardNotice"
       exact guardNotice_sourced (Or.inl ⟨_, rfl⟩) h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.modelFailure"
       exact modelFailure_sourced (Or.inr ⟨_, _, rfl⟩) (by put_norm <;> rfl)
         (fun hf => (Bool.false_ne_true hf).elim) h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.finalRecord"
       exact finalRecord_sourced rfl (WorkConservation.binary_beq_true (hyp% (_ == b "final_record") = true)) h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.intentRecord"
       exact intentRecord_sourced rfl (WorkConservation.binary_beq_true (hyp% (_ == b "intent") = true)) h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.toolsDone"
       exact toolsDone_sourced h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.resultsStored"
       (refine resultsStored_sourced rfl ?_ h
        have cond := (hyp% ((_ == b "results" || _ == b "results_only") || _ == b "notice_results") = true)
        simp only [Bool.or_eq_true] at cond
        rcases cond with (same | same) | same
        · exact Or.inl (WorkConservation.binary_beq_true same)
        · exact Or.inr (Or.inl (WorkConservation.binary_beq_true same))
        · exact Or.inr (Or.inr (WorkConservation.binary_beq_true same))))
    | (execution_head_is h "VerifiedKernel.Session.Loop.activation"
       exact activation_sourced (Or.inl ⟨_, rfl⟩) rfl rfl
         (fun he => absurd (he.symm.trans rfl) (binary_ne (by decide))) h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.timeoutEntry"
       exact timeoutEntry_sourced (Or.inl ⟨_, rfl⟩) rfl h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.activation"
       (have phase : phaseIs machine "router" := WorkConservation.binary_beq_true (hyp% (_ == b "router") = true)
        refine activation_sourced (Or.inr (Or.inr ⟨_, rfl, phase⟩)) (by put_norm <;> rfl) (by put_norm <;> rfl)
          (fun he => ?_) h
        put_norm
        simp (disch := decide) only [mkey_put_other] at he
        exact Or.inr ⟨_, Or.inl ⟨rfl, Or.inr phase⟩, he, rfl⟩))
    | (execution_head_is h "VerifiedKernel.Session.Loop.expire"
       (have phase : phaseIs machine "busy" := WorkConservation.binary_beq_true (hyp% (_ == b "busy") = true)
        exact expire_sourced (Or.inr (Or.inr (Or.inr ⟨_, rfl, phase⟩))) rfl
          (fun he => Or.inr ⟨_, Or.inl ⟨rfl, Or.inl phase⟩, he, rfl⟩) h))
    | (execution_head_is h "VerifiedKernel.Session.Loop.classify"
       exact classify_sourced ⟨rfl, WorkConservation.binary_beq_true (hyp% (_ == b "classify") = true)⟩ h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.activation"
       (have phase : phaseIs machine "activation" := WorkConservation.binary_beq_true (hyp% (_ == b "activation") = true)
        refine activation_sourced (Or.inr (Or.inl ⟨rfl, phase⟩)) (by put_norm <;> rfl) (by put_norm <;> rfl)
          (fun he => ?_) h
        put_norm
        exact Or.inr ⟨nil, Or.inr ⟨rfl, phase⟩, he, rfl⟩))
    | (execution_head_is h "VerifiedKernel.Session.Loop.timeoutEntry"
       exact timeoutEntry_sourced (Or.inr ⟨rfl, WorkConservation.binary_beq_true (hyp% (_ == b "timeout") = true), rfl⟩)
         (by put_norm <;> rfl) h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.outputCommitted"
       exact outputCommitted_sourced h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.modelFailed"
       exact modelFailed_sourced h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.guardNotice"
       exact guardNotice_sourced (Or.inr ⟨rfl, WorkConservation.binary_beq_true (hyp% (_ == b "guard_notice") = true)⟩) h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.noticeCleanup"
       exact noticeCleanup_sourced ⟨rfl, WorkConservation.binary_beq_true (hyp% (_ == b "notice_cleanup") = true)⟩ h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.guardOutcome"
       exact guardOutcome_sourced h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.continuation"
       exact continuation_sourced h)
    | (refine ⟨_, _, rfl, ?_⟩
       solve_sourced
       refine elem_commit ?_
       first
         | exact CommitSource.boundaryIdle _ "boundary" rfl
             (WorkConservation.binary_beq_true (hyp% (_ == b "boundary") = true)) (Or.inl rfl) ⟨_, _, prior⟩
         | exact CommitSource.boundaryIdle _ "async_boundary" rfl
             (WorkConservation.binary_beq_true (hyp% (_ == b "async_boundary") = true)) (Or.inr (Or.inl rfl))
             ⟨_, _, prior⟩
         | exact CommitSource.boundaryIdle _ "boundary_after_tools" rfl
             (WorkConservation.binary_beq_true (hyp% (_ == b "boundary_after_tools") = true)) (Or.inr (Or.inr rfl))
             ⟨_, _, prior⟩)

theorem result_inj {m m' : Term} {xs ys : List Term}
    (h : Term.tuple [m, list xs] = Term.tuple [m', list ys]) : xs = ys := by
  simp only [list, Term.tuple.injEq, List.cons.injEq, Term.list.injEq, and_true] at h
  exact h.2

theorem step_sources {state machine event machine' : Term} {effects : List Term}
    (h : StepOK Loop.queryAsk state machine event machine' effects) : Sourced state machine event effects := by
  obtain ⟨j, j', h⟩ := h
  obtain ⟨m, effs, same, sourced⟩ := step_sourced_out h
  cases result_inj same
  exact sourced

/-- Every commit of a kernel step has a `CommitSource`. -/
theorem step_commit_source {state machine event machine' opts mode : Term} {effects events : List Term}
    (h : StepOK Loop.queryAsk state machine event machine' effects)
    (mem : commitEffect events opts mode ∈ effects) : CommitSource state machine event events opts mode :=
  (step_sources h _ mem).1 _ _ _ rfl

/-- Every `run_tools` effect of a kernel step has a `DispatchSource`. -/
theorem step_dispatch_source {state machine event machine' calls flags : Term} {effects : List Term}
    (h : StepOK Loop.queryAsk state machine event machine' effects)
    (mem : runToolsEffect calls flags ∈ effects) : DispatchSource state machine event calls flags :=
  (step_sources h _ mem).2.1 _ _ rfl

/-- Every `write` effect of a kernel step has a `WriteSource`. -/
theorem step_write_source {state machine event machine' : Term} {effects events : List Term}
    (h : StepOK Loop.queryAsk state machine event machine' effects)
    (mem : writeEffect events ∈ effects) : WriteSource state machine event events :=
  (step_sources h _ mem).2.2 _ rfl

theorem toolTurn_no_dispatch {m outcome out machine' calls flags : Term} {effects : List Term} {j j' : List Term}
    (h : (loop% toolTurn) m outcome j = .ok (out, j')) (same : out = .tuple [machine', list effects])
    (mem : runToolsEffect calls flags ∈ effects) : False := by
  unfold_loop toolTurn
  run_split
  cases result_inj same
  simp only [List.mem_cons, List.not_mem_nil, or_false] at mem
  rcases mem with same | same
  · exact absurd (show "run_tools" = "notify" from congrArg effectName same) (by decide)
  · exact absurd (show "run_tools" = "build_record" from congrArg effectName same) (by decide)

theorem intentRecord_head {state machine record out machine' calls flags : Term} {effects : List Term}
    {j j' : List Term}
    (h : (loop% intentRecord) state machine record j = .ok (out, j')) (same : out = .tuple [machine', list effects])
    (mem : runToolsEffect calls flags ∈ effects) :
    effects.head? = some (commitEffect (intentEvents record) (hwmOpts (intentHwm record)) (intentMode record)) := by
  unfold_loop intentRecord
  run_split
  all_goals first
    | exact (toolTurn_no_dispatch h same mem).elim
    | exact (toolTurn_no_dispatch prior same mem).elim
    | skip
  all_goals
    cases result_inj same
    obtain ⟨_, rfl⟩ := advance_ok (hyp% (loop% advance) machine _ _ _ = _)
    obtain ⟨_, rfl⟩ := advance_ok (hyp% (loop% advance) _ _ _ _ = _)
  all_goals
    simp only [List.head?_cons, Option.some.injEq]
    unfold intentEvents intentHwm
    have same : (loop% key) record "admission" = mkey record "admission" := rfl
    simp only [same]
    split <;> rfl

/-- A model-turn dispatch follows the intent commit of the same step: the
commit of the record's intent events is the step's first effect. -/
theorem step_dispatch_after_commit {state machine record machine' calls flags : Term} {effects : List Term}
    (h : StepOK Loop.queryAsk state machine (.tuple [a "record", record]) machine' effects)
    (mem : runToolsEffect calls flags ∈ effects) :
    effects.head? = some (commitEffect (intentEvents record) (hwmOpts (intentHwm record)) (intentMode record)) := by
  have phase : phaseIs machine "intent" := by
    cases step_dispatch_source h mem with
    | modelTurn _ _ _ entry phase => exact phase
    | notice _ _ entry => cases entry.1
  obtain ⟨j, j', h⟩ := h
  generalize hv : Term.tuple [a "record", record] = event at h
  unfold Loop.stepWith at h
  run_split
  all_goals try (exfalso; simp [a] at hv; done)
  all_goals first
    | (simp only [a, Term.tuple.injEq, List.cons.injEq, and_true, true_and] at hv
       subst hv
       exact intentRecord_head h rfl mem)
    | (exfalso
       have other := WorkConservation.binary_beq_true (hyp% (_ == b "final_record") = true)
       exact binary_ne (by decide) (phase.symm.trans other))

/-- `Loop.step` is `stepWith` with the kernel oracle. -/
theorem step_eq : Loop.step = Loop.stepWith Loop.queryAsk := rfl

end VerifiedKernel.Session.LoopProof
