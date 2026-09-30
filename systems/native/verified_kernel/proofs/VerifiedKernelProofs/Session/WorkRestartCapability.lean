import VerifiedKernelProofs.Session.WorkRestartContext

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

abbrev restartFailRunning : Term → Term → Term :=
  native_decl% "VerifiedKernel.Session.Restart.failRunning"

abbrev restartResumeCapability : Term → Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Restart.resumeCapability"

theorem restart_fail_running_ordinary {context record : Term} (safe : RestartContextReady context) :
    RestartOutputOrdinary (restartFailRunning context record) := by
  unfold restartFailRunning
  unfold_native "VerifiedKernel.Session.Restart.failRunning"
  exact RestartOutputOrdinary.perform (by solve_restart_context)
    (by simp +decide [RestartPhaseFor, get_put_binary_same])

theorem restart_capability_ordinary {state context observation output : Term} {journal rest : List Term}
    (safe : RestartContextReady context)
    (events : RawOrdinaryBatch (wrap (observation.get (b "events"))))
    (call : restartResumeCapability state context observation journal = .ok (output, rest)) :
    RestartOutputOrdinary output := by
  have appended := safe.add_items (name := "capability_events") events (by decide)
  unfold restartResumeCapability at call
  unfold_execution_head call
  repeat' first
    | (execution_head_is call "Pure.pure"; rw [pure_ok call]
       first
         | exact RestartOutputOrdinary.perform (by solve_restart_context)
             (by simp +decide [RestartPhaseFor, get_put_binary_same])
         | (apply restart_fail_running_ordinary; solve_restart_context))
    | (execution_head_is call "VerifiedKernel.Session.Restart.next"
       exact restart_next_ordinary (by solve_restart_context) call)
    | (execution_head_is call "Bind.bind"
       have bound := bind_ok call; clear call; rcases bound with ⟨_, _, _, call⟩)
    | dsimp only at call
    | split at call

end VerifiedKernel.Session.WorkConservation
