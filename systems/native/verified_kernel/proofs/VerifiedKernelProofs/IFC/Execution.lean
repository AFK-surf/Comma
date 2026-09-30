import VerifiedKernelProofs.IFC.Behavior

namespace VerifiedKernel.IFC.Execution
open VerifiedKernel.IFC.System Behavior
variable [System.Domain]

structure State (Value : Type) where
  labels : Ref → Label
  values : Store (Option Value)

/-- Each step records an effect result at its declared destination. Absence is
part of the result, so a trusted declaration also covers whether it is emitted.
The new cell can be a source for subsequent steps. -/
structure Command (Value : Type) where
  target : Ref
  action : Action (Option Value) Value

def advance (state : State Value) (command : Command Value) : State Value where
  labels ref := if ref = command.target then command.action.destination else state.labels ref
  values ref := if ref = command.target then command.action.expression.evaluate state.values else state.values ref

def LowEq (w : World) (observer : Principal) (left right : State Value) : Prop :=
  left.labels = right.labels ∧
  ∀ ref, Reads w observer (left.labels ref) → left.values ref = right.values ref

def ReleaseAgreement (released : Ref → Prop) (left right : State Value) : Prop :=
  ∀ ref, released ref → left.values ref = right.values ref

theorem advance_noninterference (same : LowEq w observer left right)
    (safe : ReleaseSafe w observer left.labels released command.action)
    (release : ReleaseAgreement released left right) :
    LowEq w observer (advance left command) (advance right command) ∧
    observe w observer command.action left.values = observe w observer command.action right.values := by
  have view : ViewEq w observer left.labels released left.values right.values := by
    intro ref hr
    rcases hr with readable | permitted
    · exact same.2 ref readable
    · exact release ref permitted
  refine ⟨⟨?_, ?_⟩, action_noninterference safe view⟩
  · simp only [advance, same.1]
  · intro ref readable
    by_cases target : ref = command.target
    · simp only [advance, target, ↓reduceIte] at readable ⊢
      apply command.action.expression.declared
      intro source member
      apply view source
      rcases safe readable source member with flow | allowed
      · exact Or.inl (flow observer readable)
      · exact Or.inr allowed
    · simp only [advance, target, ↓reduceIte] at readable ⊢
      exact same.2 ref readable

noncomputable def run (w : World) (observer : Principal) :
    State Value → List (Command Value) → State Value × List Value
  | state, [] => (state, [])
  | state, command :: rest =>
    let later := run w observer (advance state command) rest
    (later.1, observe w observer command.action state.values ++ later.2)

/-- Release equality is required only for each step's actual authorized
releases. It is checked against the evolving stores, not their initial values. -/
inductive Aligned (w : World) (observer : Principal) :
    State Value → State Value → List (Command Value) → Prop where
  | nil : Aligned w observer left right []
  | cons (released : Ref → Prop) :
      ReleaseSafe w observer left.labels released command.action →
      ReleaseAgreement released left right →
      Aligned w observer (advance left command) (advance right command) rest →
      Aligned w observer left right (command :: rest)

theorem run_noninterference (same : LowEq w observer left right)
    (aligned : Aligned w observer left right commands) :
    LowEq w observer (run w observer left commands).1 (run w observer right commands).1 ∧
    (run w observer left commands).2 = (run w observer right commands).2 := by
  induction aligned with
  | nil => exact ⟨same, rfl⟩
  | cons _ safe release _ ih =>
    obtain ⟨next, output⟩ := advance_noninterference same safe release
    obtain ⟨finalState, later⟩ := ih next
    exact ⟨finalState, by simp only [run, output, later]⟩

/-- The scheduler may choose subsequent commands from the current low view.
It need not choose the entire trace before execution starts. -/
structure Scheduler (Value : Type) (w : World) (observer : Principal) where
  next : State Value → Option (Command Value)
  publicControl : ∀ left right, LowEq w observer left right → next left = next right

noncomputable def execute (w : World) (observer : Principal)
    (scheduler : Scheduler Value w observer) : Nat → State Value → State Value × List Value
  | 0, state => (state, [])
  | fuel + 1, state => match scheduler.next state with
    | none => (state, [])
    | some command =>
      let later := execute w observer scheduler fuel (advance state command)
      (later.1, observe w observer command.action state.values ++ later.2)

theorem execute_noninterference
    (scheduler : Scheduler Value w observer)
    (safe : ∀ left right command, LowEq w observer left right → scheduler.next left = some command →
      ∃ released, ReleaseSafe w observer left.labels released command.action ∧
        ReleaseAgreement released left right)
    (same : LowEq w observer left right) :
    LowEq w observer (execute w observer scheduler fuel left).1 (execute w observer scheduler fuel right).1 ∧
    (execute w observer scheduler fuel left).2 = (execute w observer scheduler fuel right).2 := by
  induction fuel generalizing left right with
  | zero => exact ⟨same, rfl⟩
  | succ fuel ih =>
    have control := scheduler.publicControl left right same
    cases hn : scheduler.next left with
    | none => simp only [execute, ← control, hn]; exact ⟨same, trivial⟩
    | some command =>
      obtain ⟨released, safeH, release⟩ := safe left right command same hn
      obtain ⟨next, output⟩ := advance_noninterference same safeH release
      obtain ⟨finalState, later⟩ := ih next
      simp only [execute, ← control, hn]
      exact ⟨finalState, by simp only [output, later]⟩

end VerifiedKernel.IFC.Execution
