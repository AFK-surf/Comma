import VerifiedKernel.Session.Command
import VerifiedKernelProofs.Session.AppendOnly.Core

/-! Input confirmation follows the executable command continuation.
The host returns success only for a successful write or durable fence.
A working-state write is not a durable observation. Notification is observational.
The trace starts at `Command.writeInput`, not at a caller-forged continuation. -/

namespace VerifiedKernel.Session.DurableConfirmation
open Data

inductive Result where
  | ok
  | error (reason : Term)

def Result.wire : Result → Term
  | .ok => a "ok"
  | .error reason => .tuple [a "error", reason]

inductive Phase where
  | write | fence | notify | done | failed (reason : Term)

def output (events : Term) : Phase → Term
  | .write => Command.writeInput events
  | .fence => Command.perform (a "durable_fence") (.tuple [b "input_written", events])
  | .notify => Command.perform (.tuple [a "notify", b "input_accepted", events]) (b "input_notified")
  | .done => Command.finish (.tuple [a "ok", a "committed"])
  | .failed reason => Command.finish (.tuple [a "error", reason])

def continuation (events : Term) : Phase → Term
  | .write => .tuple [b "durable_fence", .tuple [b "input_written", events]]
  | .fence => .tuple [b "input_written", events]
  | .notify => b "input_notified"
  | _ => nil

def step : Phase → Result → Phase
  | .write, .ok => .fence
  | .fence, .ok => .notify
  | .write, .error reason | .fence, .error reason => .failed reason
  | .notify, _ => .done
  | phase, _ => phase

def Awaiting : Phase → Prop
  | .write | .fence | .notify => True
  | _ => False

/-- Every nonterminal transition is the actual Session command, for arbitrary state and observations. -/
theorem resume_refines (state events : Term) (phase : Phase) (result : Result)
    (waiting : Awaiting phase) :
    Command.resume state (.tuple [continuation events phase, result.wire]) =
      pure (output events (step phase result)) := by
  cases phase <;> cases result <;> try contradiction
  all_goals rfl

structure Monitor where
  phase : Phase := .write
  fences : Nat := 0
  confirmations : Nat := 0
  returns : Nat := 0

def advance (s : Monitor) (result : Result) : Monitor :=
  { phase := step s.phase result
    fences := s.fences + (match s.phase, result with | .fence, .ok => 1 | _, _ => 0)
    confirmations := s.confirmations + (match s.phase, result with | .fence, .ok => 1 | _, _ => 0)
    returns := s.returns + (match s.phase with | .notify => 1 | _ => 0) }

def Safe (s : Monitor) : Prop :=
  s.returns ≤ s.confirmations ∧ s.confirmations ≤ s.fences ∧ s.fences ≤ 1 ∧
  (match s.phase with
   | .write | .fence | .failed _ => s.fences = 0 ∧ s.confirmations = 0 ∧ s.returns = 0
   | .notify => s.fences = 1 ∧ s.confirmations = 1 ∧ s.returns = 0
   | .done => s.fences = 1 ∧ s.confirmations = 1 ∧ s.returns = 1)

theorem initial_safe : Safe {} := by simp [Safe]

theorem advance_safe (s : Monitor) (result : Result) (safe : Safe s) : Safe (advance s result) := by
  cases s with
  | mk phase fences confirmations returns =>
    cases phase <;> cases result <;> simp_all [Safe, advance, step] <;> omega

def run : Monitor → List Result → Monitor
  | s, [] => s
  | s, result :: rest => run (advance s result) rest

theorem run_safe (s : Monitor) (results : List Result) (safe : Safe s) : Safe (run s results) := by
  induction results generalizing s with
  | nil => exact safe
  | cons result rest ih => exact ih _ (advance_safe s result safe)

/-- Every finite prefix has a successful fence for each confirmation and committed return. -/
theorem all_traces_durable (results : List Result) :
    (run {} results).returns ≤ (run {} results).confirmations ∧
    (run {} results).confirmations ≤ (run {} results).fences := by
  have h := run_safe {} results initial_safe
  exact ⟨h.1, h.2.1⟩

/-- The monitor follows actual `resume` results, not an independent transition table. -/
theorem executable_step (s : Monitor) (state events : Term) (result : Result)
    (waiting : Awaiting s.phase) (safe : Safe s) :
    Command.resume state (.tuple [continuation events s.phase, result.wire]) =
      pure (output events (advance s result).phase) ∧ Safe (advance s result) :=
  ⟨resume_refines state events s.phase result waiting, advance_safe s result safe⟩

theorem write_success_is_not_confirmation (events state : Term) :
    Command.resume state (.tuple [continuation events .write, Result.ok.wire]) =
      pure (output events .fence) := resume_refines state events .write .ok trivial

theorem fence_failure_is_not_confirmation (events state reason : Term) :
    Command.resume state (.tuple [continuation events .fence, (Result.error reason).wire]) =
      pure (Command.finish (.tuple [a "error", reason])) :=
  resume_refines state events .fence (.error reason) trivial

/-- A trace of actual command responses. Only the pending continuation can resume. -/
inductive Executed (events : Term) : Monitor → Term → Prop where
  | initial : Executed events {} (Command.writeInput events)
  | next (previous : Executed events s (output events s.phase))
      (waiting : Awaiting s.phase) (state : Term) (result : Result) (j r : List Term)
      (resumed : Command.resume state (.tuple [continuation events s.phase, result.wire]) j = .ok (value, r)) :
      Executed events (advance s result) value

theorem executed_refines {events value : Term} {s : Monitor} (execution : Executed events s value) :
    value = output events s.phase ∧ Safe s := by
  induction execution with
  | initial => exact ⟨rfl, initial_safe⟩
  | next previous waiting state result j r resumed ih =>
    rw [resume_refines state _ _ result waiting] at resumed
    exact ⟨pure_ok resumed, advance_safe _ _ ih.2⟩

/-- The emitted event carries the exact batch whose fence succeeded. -/
theorem executable_confirmation_has_fence {events value : Term} {s : Monitor}
    (execution : Executed events s value)
    (confirmation : value = Command.perform (.tuple [a "notify", b "input_accepted", events]) (b "input_notified") ∨
      value = Command.finish (.tuple [a "ok", a "committed"])) : s.fences = 1 := by
  obtain ⟨valueEq, safe⟩ := executed_refines execution
  rw [valueEq] at confirmation
  cases phase : s.phase <;>
    simp [output, Command.writeInput, Command.perform, Command.finish, Data.a] at confirmation
  all_goals simp_all [Safe, output, Command.writeInput, Command.perform, Command.finish,
    Data.a, Data.b, Data.nil, Data.list, Term.text]

/-- The first success for any staged write requests its fence, regardless of the next continuation. -/
theorem staged_write_requires_fence (state next : Term) :
    Command.resume state (.tuple [.tuple [b "durable_fence", next], a "ok"]) =
      pure (Command.perform (a "durable_fence") next) := by rfl

/-- A failed activation commit returns an error and its checkpoint, not a draft-retirement effect. -/
theorem activation_failure_returns_error (state details checkpoint active reason : Term) :
    Command.resume state (.tuple [
      .tuple [b "activation_written", details, checkpoint, active], .tuple [a "error", reason]]) =
      pure (Command.finish (.tuple [a "error", .tuple [a "visible_reply_authorization_retry",
        if active.truthy then .tuple [a "visible_reply_pre_llm_error", a "round_status_activation", reason]
        else reason]]) checkpoint) := by rfl

end VerifiedKernel.Session.DurableConfirmation
