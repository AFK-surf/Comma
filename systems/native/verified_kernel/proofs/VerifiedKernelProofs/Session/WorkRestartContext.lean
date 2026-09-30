import VerifiedKernelProofs.Session.WorkRestartProducers

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

abbrev restartNext : Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Restart.next"

def RestartContextReady (context : Term) : Prop :=
  RestartContextOrdinary context ∧
    RawOrdinaryBatch (wrap ((context.get (b "capability_observation")).get (b "events")))

theorem RestartContextReady.put_other {context value : Term} {name : String}
    (safe : RestartContextReady context)
    (outside : ∀ key ∈ ["missing_events", "external_events", "recovered_events", "failure_events",
      "capability_events", "capability_observation"], name ≠ key) :
    RestartContextReady (context.put (b name) value) := by
  constructor
  · apply safe.1.put_other
    intro key member
    apply outside key
    exact List.mem_append_left ["capability_observation"] member
  · rw [get_put_binary_other _ _ (outside _ (by simp))]
    exact safe.2

theorem RestartContextReady.add_other {context : Term} {name : String} {items : List Term}
    (safe : RestartContextReady context)
    (outside : ∀ key ∈ ["missing_events", "external_events", "recovered_events", "failure_events",
      "capability_events", "capability_observation"], name ≠ key) :
    RestartContextReady (restartAddItems context name items) := by
  unfold restartAddItems
  unfold_native "VerifiedKernel.Session.Restart.addItems"
  exact safe.put_other outside

theorem RestartContextReady.add_items {context : Term} {name : String} {items : List Term}
    (safe : RestartContextReady context) (added : RawOrdinaryBatch items)
    (different : name ≠ "capability_observation") :
    RestartContextReady (restartAddItems context name items) := by
  refine ⟨safe.1.add_items added, ?_⟩
  unfold restartAddItems
  unfold_native "VerifiedKernel.Session.Restart.addItems"
  rw [get_put_binary_other _ _ different]
  exact safe.2

theorem RestartContextReady.capture {context observation : Term}
    (safe : RestartContextReady context)
    (events : RawOrdinaryBatch (wrap (observation.get (b "events")))) :
    RestartContextReady (context.put (b "capability_observation") observation) := by
  refine ⟨safe.1.put_other (by simp +decide), ?_⟩
  rw [get_put_binary_same]
  exact events

def RestartPhaseFor (name : String) (phase : Term) : Prop :=
  match name with
  | "capability" => phase = b "missing_pending" ∨ phase = b "running_pending"
  | "encode_external" => phase = b "external_encoded" ∨ phase = b "missing_capability_encoded"
  | "guidance" => phase = b "guidance"
  | "encode_missing" => phase = b "missing_encoded"
  | "staged_result" => phase = b "staged"
  | "encode_recovered" => phase = b "recovered_encoded"
  | "encode_failed" => phase = b "failed_encoded"
  | _ => False

inductive RestartOutputOrdinary : Term → Prop where
  | perform {name : String} {args context : Term} (safe : RestartContextReady context)
      (phase : RestartPhaseFor name (context.get (b "phase"))) :
      RestartOutputOrdinary (.tuple [a "perform", .tuple [b name, args], context])
  | finished {events : List Term} {nextId : Term} (safe : RawOrdinaryBatch events) :
      RestartOutputOrdinary (.tuple [a "return", .tuple [list events, nextId]])
  | failed (reason : Term) :
      RestartOutputOrdinary (.tuple [a "return", .tuple [a "error", reason]])

syntax "solve_restart_context" : tactic
macro_rules
  | `(tactic| solve_restart_context) => `(tactic|
    (first
       | assumption
       | exact RestartContextReady.put_other (by solve_restart_context) (by simp +decide; done)
       | exact RestartContextReady.add_other (by solve_restart_context) (by simp +decide; done)
       | (split <;> solve_restart_context)))

theorem restart_next_ordinary {state context output : Term} {journal rest : List Term}
    (safe : RestartContextReady context)
    (call : restartNext state context journal = .ok (output, rest)) :
    RestartOutputOrdinary output := by
  unfold restartNext at call
  unfold_execution_head call
  cases missing : restartGetList context "missing" <;>
    cases external : restartGetList context "external_todo" <;>
    cases running : restartGetList context "running"
  all_goals simp only [restartGetList] at missing external running
  all_goals rw [missing] at call
  all_goals try rw [external] at call
  all_goals try rw [running] at call
  all_goals repeat' first
    | (execution_head_is call "Pure.pure"; rw [pure_ok call]
       exact RestartOutputOrdinary.perform (by solve_restart_context)
         (by simp +decide [RestartPhaseFor, get_put_binary_same]))
    | (execution_head_is call "VerifiedKernel.Session.Restart.finalPlan"
       obtain ⟨events, nextId, same, batch⟩ := restart_final_plan_events_ordinary safe.1 call
       rw [same]; exact .finished batch)
    | (execution_head_is call "Bind.bind"
       have bound := bind_ok call; clear call; rcases bound with ⟨_, _, _, call⟩)
    | dsimp only at call
    | split at call

theorem restart_start_ordinary {state live recovery output : Term} {journal rest : List Term}
    (call : Restart.start state (.tuple [live, recovery]) journal = .ok (output, rest)) :
    RestartOutputOrdinary output := by
  unfold Restart.start at call
  obtain ⟨scan, _, _, call⟩ := bind_ok call
  obtain ⟨nextId, _, _, call⟩ := bind_ok call
  apply restart_next_ordinary (call := call)
  constructor
  · intro key member
    simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    rcases member with rfl | rfl | rfl | rfl | rfl
    all_goals
      unfold restartGetList
      unfold_native "VerifiedKernel.Session.Restart.getList"
      simp +decide [Term.get, b, Term.text, wrap, list, RawOrdinaryBatch]
  · simp +decide [Term.get, b, Term.text, wrap, list, RawOrdinaryBatch]

end VerifiedKernel.Session.WorkConservation
