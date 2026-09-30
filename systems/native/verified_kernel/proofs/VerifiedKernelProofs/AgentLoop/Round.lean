import VerifiedKernel.AgentLoop.Round
import VerifiedKernelProofs.AgentLoop.Trace

namespace VerifiedKernel.AgentLoop.Round

def transition (state : State) (event : Event) : State × List Command :=
  let result := step state event
  (result.1, [result.2])

def trace (state : State) (events : List Event) : State × List Command :=
  runTrace transition state events

/-- Ghost history counters. They observe kernel decisions and phase-qualified
    acknowledgements; they are not additional production state. A committed
    observation denotes a successful synchronous commit supplied by the adapter,
    not an arbitrary mailbox acknowledgement or a theorem about storage. -/
structure Monitor where
  state : State := .ready
  activations : Nat := 0
  intentCommits : Nat := 0
  executions : Nat := 0
  resultCommits : Nat := 0
  continuations : Nat := 0
  deriving Repr

def advance (history : Monitor) (event : Event) : Monitor :=
  let result := step history.state event
  { state := result.1
    activations := history.activations + if history.state = .ready ∧ event = .start then 1 else 0
    intentCommits := history.intentCommits + if history.state = .awaitIntent ∧ event = .committed then 1 else 0
    executions := history.executions + if result.2 = .executeTools then 1 else 0
    resultCommits := history.resultCommits + if history.state = .awaitResults ∧ event = .committed then 1 else 0
    continuations := history.continuations + if result.2 = .continue then 1 else 0 }

def runMonitor : Monitor → List Event → Monitor
  | history, [] => history
  | history, event :: rest => runMonitor (advance history event) rest

def PhaseCounts (history : Monitor) : Prop :=
  match history.state with
  | .ready => history.activations = 0 ∧ history.intentCommits = 0 ∧ history.executions = 0 ∧
      history.resultCommits = 0 ∧ history.continuations = 0
  | .awaitIntent => history.activations = 1 ∧ history.intentCommits = 0 ∧ history.executions = 0 ∧
      history.resultCommits = 0 ∧ history.continuations = 0
  | .awaitTools | .awaitResults => history.activations = 1 ∧ history.intentCommits = 1 ∧
      history.executions = 1 ∧ history.resultCommits = 0 ∧ history.continuations = 0
  | .settled => history.continuations = 1
  | .failed => True

def Safe (history : Monitor) : Prop :=
  history.activations ≤ 1 ∧ history.intentCommits ≤ history.activations ∧
  history.executions ≤ history.intentCommits ∧ history.resultCommits ≤ history.executions ∧
  history.continuations ≤ history.resultCommits ∧ PhaseCounts history

theorem initial_safe : Safe ({} : Monitor) := by
  simp [Safe, PhaseCounts]

theorem advance_safe (history : Monitor) (event : Event) (safe : Safe history) :
    Safe (advance history event) := by
  cases history with
  | mk state activations intentCommits executions resultCommits continuations =>
    cases state <;> cases event <;> simp_all [Safe, PhaseCounts, advance, step] <;> omega

/-- No event-order premise: duplicates, premature acknowledgements, irrelevant
    events, and events after terminal states are all included. -/
theorem runMonitor_safe (history : Monitor) (events : List Event) (safe : Safe history) :
    Safe (runMonitor history events) := by
  induction events generalizing history with
  | nil => exact safe
  | cons event rest ih => exact ih (advance history event) (advance_safe history event safe)

theorem all_traces_safe (events : List Event) : Safe (runMonitor {} events) :=
  runMonitor_safe {} events initial_safe

def occurrences (command : Command) (commands : List Command) : Nat :=
  commands.countP (fun item => item == command)

theorem monitor_command_counts (history : Monitor) (events : List Event) :
    (runMonitor history events).executions = history.executions + occurrences .executeTools (trace history.state events).2 ∧
    (runMonitor history events).continuations = history.continuations + occurrences .continue (trace history.state events).2 := by
  induction events generalizing history with
  | nil => simp [runMonitor, trace, runTrace, occurrences]
  | cons event rest ih =>
    have later := ih (advance history event)
    cases state : history.state <;> cases event <;>
      simp_all [runMonitor, trace, runTrace, transition, advance, step,
        occurrences, List.countP_cons, BEq.beq, Nat.add_assoc, Nat.add_comm] <;> decide

/-- Each ready-start activation authorizes at most one execute command and one
    continuation. Resetting the initial state creates a separate activation and
    is not an event accepted by this transition table. -/
theorem commands_at_most_once (events : List Event) :
    occurrences .executeTools (trace .ready events).2 ≤ 1 ∧
    occurrences .continue (trace .ready events).2 ≤ 1 := by
  have safe := all_traces_safe events
  have counts := monitor_command_counts ({} : Monitor) events
  simp only [Safe] at safe
  simp only [Nat.zero_add] at counts
  omega

theorem execute_requires_committed (state : State) (event : Event)
    (execute : (step state event).2 = .executeTools) :
    state = .awaitIntent ∧ event = .committed := by
  cases state <;> cases event <;> simp_all [step]

theorem continue_requires_committed (state : State) (event : Event)
    (continues : (step state event).2 = .continue) :
    state = .awaitResults ∧ event = .committed := by
  cases state <;> cases event <;> simp_all [step]

/-- Every prefix has observed enough successful phase-qualified commits for
    its execute and continue commands. This does not prove commit truthfulness. -/
theorem commit_history_precedes_commands (events : List Event) :
    (runMonitor {} events).executions ≤ (runMonitor {} events).intentCommits ∧
    (runMonitor {} events).continuations ≤ (runMonitor {} events).resultCommits := by
  have safe := all_traces_safe events
  exact ⟨safe.2.2.1, safe.2.2.2.2.1⟩

theorem settled_absorbing (event : Event) : step .settled event = (.settled, .ignore) := by
  cases event <;> rfl

theorem failed_absorbing (event : Event) : step .failed event = (.failed, .ignore) := by
  cases event <;> rfl

theorem terminal_trace (state : State) (terminal : state = .settled ∨ state = .failed)
    (events : List Event) :
    trace state events = (state, List.replicate events.length Command.ignore) := by
  induction events with
  | nil => rfl
  | cons event rest ih =>
    rcases terminal with rfl | rfl <;>
      simp [trace, runTrace, transition, settled_absorbing, failed_absorbing,
        List.replicate_succ] at ih ⊢
    all_goals exact ⟨congrArg Prod.fst ih, congrArg Prod.snd ih⟩

end VerifiedKernel.AgentLoop.Round
