import VerifiedKernelProofs.Session.WorkPresentationRecoveryProducers
import VerifiedKernelProofs.Session.WorkNoWakeOrdinary

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

abbrev restartGetList : Term → String → List Term :=
  native_decl% "VerifiedKernel.Session.Restart.getList"

abbrev restartQueue : Term → Term → Term → Term → Term :=
  native_decl% "VerifiedKernel.Session.Restart.queue"

abbrev restartFinalPlan : Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Restart.finalPlan"

abbrev restartAddItems : Term → String → List Term → Term :=
  native_decl% "VerifiedKernel.Session.Restart.addItems"

def RestartContextOrdinary (context : Term) : Prop :=
  ∀ key ∈ ["missing_events", "external_events", "recovered_events", "failure_events", "capability_events"],
    RawOrdinaryBatch (restartGetList context key)

theorem RestartContextOrdinary.put_other {context value : Term} {name : String}
    (safe : RestartContextOrdinary context)
    (outside : ∀ key ∈ ["missing_events", "external_events", "recovered_events", "failure_events", "capability_events"],
      name ≠ key) : RestartContextOrdinary (context.put (b name) value) := by
  intro key member
  have before := safe key member
  unfold restartGetList at before ⊢
  unfold_native "VerifiedKernel.Session.Restart.getList"
  rw [get_put_binary_other _ _ (outside key member)]
  exact before

theorem RestartContextOrdinary.add_items {context : Term} {name : String} {items : List Term}
    (safe : RestartContextOrdinary context) (added : RawOrdinaryBatch items) :
    RestartContextOrdinary (restartAddItems context name items) := by
  intro key member
  have before := safe key member
  unfold restartAddItems
  unfold_native "VerifiedKernel.Session.Restart.addItems"
  by_cases same : name = key
  · subst name
    change RawOrdinaryBatch (wrap ((context.put (b key)
      (list (restartGetList context key ++ items))).get (b key)))
    rw [get_put_binary_same]
    exact raw_ordinary_append.mpr ⟨before, added⟩
  · change RawOrdinaryBatch (wrap ((context.put (b name)
      (list (restartGetList context name ++ items))).get (b key)))
    rw [get_put_binary_other _ _ same]
    exact before

theorem RestartContextOrdinary.add_other {context : Term} {name : String} {items : List Term}
    (safe : RestartContextOrdinary context)
    (outside : ∀ key ∈ ["missing_events", "external_events", "recovered_events", "failure_events", "capability_events"],
      name ≠ key) : RestartContextOrdinary (restartAddItems context name items) := by
  unfold restartAddItems
  unfold_native "VerifiedKernel.Session.Restart.addItems"
  exact safe.put_other outside

theorem restart_queue_ordinary (session identity payload now : Term) :
    OrdinaryBatch [restartQueue session identity payload now] := by
  unfold restartQueue
  unfold_native "VerifiedKernel.Session.Restart.queue"
  simp only [OrdinaryBatch, List.mem_singleton, forall_eq]
  constructor
  · rfl
  · simp +decide [OrdinaryKind, Term.get, b, Term.text]

syntax "solve_restart_batch " ident : tactic
macro_rules
  | `(tactic| solve_restart_batch $safe:ident) => `(tactic|
    (repeat' first
       | assumption
       | exact $safe _ (by simp)
       | apply raw_ordinary_append.mpr
       | apply raw_ordinary_pair.mpr
       | exact (restart_queue_ordinary _ _ _ _).raw
       | exact (status_event_ordinary _).raw
       | exact ordinary_nil.raw
       | apply And.intro
       | split))

set_option backward.split false in
theorem restart_final_plan_events_ordinary {state context output : Term} {journal rest : List Term}
    (safe : RestartContextOrdinary context)
    (call : restartFinalPlan state context journal = .ok (output, rest)) :
    ∃ events nextId, output = .tuple [a "return", .tuple [list events, nextId]] ∧
      RawOrdinaryBatch events := by
  unfold restartFinalPlan at call
  unfold_execution_head call
  repeat' first
    | (execution_head_is call "Pure.pure"
       rw [pure_ok call]; refine ⟨_, _, rfl, ?_⟩; assumption)
    | exact (fail_ok call).elim
    | (execution_head_is call "Bind.bind"
       have bound := bind_ok call; clear call; rcases bound with ⟨value, _, prior, call⟩
       first
         | (execution_head_is prior "VerifiedKernel.Session.Presentation.recoveredCompletion"
            rcases recovered_completion_events_ordinary
              (raw_ordinary_no_wake_map (by solve_restart_batch safe) _) prior with
              ⟨events, same, batch⟩
            subst value)
         -- Classify each generated sub-batch before processing the continuation.
         | (have batch : RawOrdinaryBatch value := by
              repeat' first
                | (execution_head_is prior "Pure.pure"
                   rw [pure_ok prior]; solve_restart_batch safe)
                | exact (fail_ok prior).elim
                | (execution_head_is prior "Bind.bind"
                   obtain ⟨_, _, _, prior⟩ := bind_ok prior)
                | dsimp only at prior
                | split at prior)
         | (execution_head_is prior "Pure.pure"; have same := pure_ok prior; cases same)
         | skip)
    | dsimp only at call
    | split at call

end VerifiedKernel.Session.WorkConservation
