import VerifiedKernelProofs.Session.WorkRestartCapability

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

/-- Callback producer obligation. This is not a storage, codec, or FFI primitive. -/
def RestartCallbackEvents (name : String) (observation : Term) : Prop :=
  match name with
  | "capability" => RawOrdinaryBatch (wrap (observation.get (b "events")))
  | "encode_missing" => RawOrdinaryBatch [observation]
  | "encode_external" | "encode_failed" => RawOrdinaryBatch (wrap observation)
  | "encode_recovered" => ∀ events handoff,
      observation = .tuple [events, handoff] → RawOrdinaryBatch (wrap events)
  | _ => True

theorem restart_saved_capability_ordinary {state context record output : Term} {journal rest : List Term}
    (safe : RestartContextReady context)
    (call : restartResumeCapability state (context.put (b "current") record)
      (context.get (b "capability_observation")) journal = .ok (output, rest)) :
    RestartOutputOrdinary output :=
  restart_capability_ordinary (safe.put_other (by simp +decide)) safe.2 call

syntax "solve_restart_resume_context " ident : tactic
macro_rules
  | `(tactic| solve_restart_resume_context $events:ident) => `(tactic|
    (first
       | assumption
       | exact RestartContextReady.capture (by solve_restart_resume_context $events) (by assumption)
       | exact RestartContextReady.add_items (by solve_restart_resume_context $events)
           (by first | assumption | exact $events _ _ rfl) (by decide)
       | exact RestartContextReady.put_other (by solve_restart_resume_context $events) (by simp +decide; done)
       | exact RestartContextReady.add_other (by solve_restart_resume_context $events) (by simp +decide; done)
       | (split <;> solve_restart_resume_context $events)))

theorem restart_resume_ordinary {state context observation output : Term} {name : String}
    {journal rest : List Term} (safe : RestartContextReady context)
    (phase : RestartPhaseFor name (context.get (b "phase")))
    (events : RestartCallbackEvents name observation)
    (call : Restart.resume state (.tuple [context, observation]) journal = .ok (output, rest)) :
    RestartOutputOrdinary output := by
  have savedEvents := safe.2
  unfold Restart.resume at call
  dsimp only at call
  unfold RestartPhaseFor at phase
  split at phase
  all_goals try contradiction
  all_goals simp only [RestartCallbackEvents] at events
  all_goals try (rcases phase with phase | phase)
  all_goals simp +decide only [phase, binary_key_beq, String.reduceBEq, ↓reduceIte,
    Bool.true_or, Bool.false_or] at call
  all_goals repeat' first
    | contradiction
    | (execution_head_is call "Pure.pure"; rw [pure_ok call]
       first
         | exact RestartOutputOrdinary.perform (by solve_restart_resume_context events)
             (by simp +decide [RestartPhaseFor, get_put_binary_same])
         | (apply restart_fail_running_ordinary; solve_restart_resume_context events)
         | exact .failed _)
    | (execution_head_is call "VerifiedKernel.Session.Restart.next"
       exact restart_next_ordinary (by solve_restart_resume_context events) call)
    | (execution_head_is call "VerifiedKernel.Session.Restart.resumeCapability"
       first
         | exact restart_capability_ordinary (by solve_restart_resume_context events) (by assumption) call
         | exact restart_saved_capability_ordinary (by solve_restart_resume_context events) call)
    | (execution_head_is call "VerifiedKernel.fail"; exact (fail_ok call).elim)
    | (have bound := bind_ok call; clear call; rcases bound with ⟨_, _, prior, call⟩
       try exact (fail_ok prior).elim)
    | dsimp only at call
    | split at call

end VerifiedKernel.Session.WorkConservation
