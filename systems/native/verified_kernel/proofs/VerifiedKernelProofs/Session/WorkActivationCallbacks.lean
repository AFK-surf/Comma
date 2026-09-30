import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernelProofs.Session.WorkActivationEvents

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

def ActivationCallback : Term → Prop
  | .tuple [.binary phase, .tuple [.list [], _, _, _], _] =>
    phase = "activation_authorized".toUTF8 ∨ phase = "activation_entropy".toUTF8
  | .binary phase => phase = "activated".toUTF8
  | _ => False

def ActivationPostWrite : Term → Prop
  | .tuple [.binary fence, .tuple [.binary phase, _, _, _]] =>
    fence = "durable_fence".toUTF8 ∧ phase = "activation_written".toUTF8
  | _ => False

/-- Callback resources retain the empty materialization prefix and the mandatory post-write fence. -/
def ActivationCommandCallbacks : Term → Prop
  | .tuple [.atom "perform", .tuple [.atom "write", _, _], continuation] => ActivationPostWrite continuation
  | .tuple [.atom "perform", _, continuation] => ActivationCallback continuation
  | _ => True

theorem activated_callbacks {state details result : Term} {journal rest : List Term}
    (call : Command.activated state details journal = .ok (result, rest)) : ActivationCommandCallbacks result := by
  unfold Command.activated at call
  repeat' first
    | (rw [pure_ok call]; simp [ActivationCommandCallbacks, ActivationCallback, Command.perform, Command.finish, b, Term.text])
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

theorem commit_activation_callbacks {state session args events details checkpoint result : Term}
    {journal rest : List Term}
    (call : Command.commitActivation state session args events details checkpoint journal = .ok (result, rest)) :
    ActivationCommandCallbacks result := by
  unfold Command.commitActivation at call
  repeat' first
    | exact activated_callbacks call
    | exact (fail_ok call).elim
    | (rw [pure_ok call]; simp [ActivationCommandCallbacks, ActivationPostWrite, Command.perform, b, Term.text, list, a])
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

theorem retire_activation_callbacks {state session args result : Term} {journal rest : List Term}
    (call : Command.retireActivation state session args journal = .ok (result, rest)) : ActivationCommandCallbacks result := by
  unfold Command.retireActivation at call
  repeat' first
    | exact commit_activation_callbacks call
    | exact (fail_ok call).elim
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

theorem install_activation_callbacks {state session args candidate checkpoint result : Term} {journal rest : List Term}
    (call : Command.installActivation state session args candidate checkpoint journal = .ok (result, rest)) :
    ActivationCommandCallbacks result := by
  unfold Command.installActivation at call
  repeat' first
    | exact commit_activation_callbacks call
    | exact (fail_ok call).elim
    | (rw [pure_ok call]; trivial)
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

theorem authorized_activation_callbacks {state session hwm prompt active candidate result : Term}
    {journal rest : List Term}
    (call : Command.authorizedActivation state session (.tuple [list [], hwm, prompt, active])
      candidate journal = .ok (result, rest)) : ActivationCommandCallbacks result := by
  unfold Command.authorizedActivation at call
  repeat' first
    | trivial
    | exact commit_activation_callbacks call
    | exact install_activation_callbacks call
    | exact (fail_ok call).elim
    | (rw [pure_ok call]
       simp [ActivationCommandCallbacks, ActivationCallback, Command.perform, b, Term.text, list, a])
    | (rw [pure_ok call]; trivial)
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

theorem activate_callbacks {state hwm prompt active checkpoint result : Term} {journal rest : List Term}
    (call : Command.activate state (.tuple [list [], hwm, prompt, active]) checkpoint journal = .ok (result, rest)) :
    ActivationCommandCallbacks result := by
  unfold Command.activate at call
  repeat' first
    | exact authorized_activation_callbacks call
    | exact retire_activation_callbacks call
    | exact (fail_ok call).elim
    | (rw [pure_ok call]
       simp [ActivationCommandCallbacks, ActivationCallback, Command.perform, b, Term.text, list, a])
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

theorem activation_command_callbacks {state hwm prompt active checkpoint result : Term} {journal rest : List Term}
    (call : Command.start state (.tuple [a "activate", .tuple [list [], hwm, prompt, active], checkpoint])
      journal = .ok (result, rest)) : ActivationCommandCallbacks result := by
  apply activate_callbacks
  simpa +decide [Command.start] using call

theorem authorization_callbacks {state hwm prompt active candidate response result : Term}
    {journal rest : List Term}
    (call : Command.resume state
      (.tuple [.tuple [b "activation_authorized", .tuple [list [], hwm, prompt, active], candidate], response])
      journal = .ok (result, rest)) : ActivationCommandCallbacks result := by
  simp +decide only [Command.resume, Command.resumeCommitted, b, Term.text, ↓reduceIte] at call
  repeat' first
    | exact authorized_activation_callbacks call
    | exact retire_activation_callbacks call
    | exact (fail_ok call).elim
    | (rw [pure_ok call]; trivial)
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

theorem entropy_callbacks {state hwm prompt active candidate response result : Term}
    {journal rest : List Term}
    (call : Command.resume state
      (.tuple [.tuple [b "activation_entropy", .tuple [list [], hwm, prompt, active], candidate], response])
      journal = .ok (result, rest)) : ActivationCommandCallbacks result := by
  simp +decide only [Command.resume, Command.resumeCommitted, b, Term.text, ↓reduceIte] at call
  repeat' first
    | exact install_activation_callbacks call
    | exact (fail_ok call).elim
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

theorem activation_callback_safe {state continuation response result : Term} {journal rest : List Term}
    (callback : ActivationCallback continuation)
    (call : Command.resume state (.tuple [continuation, response]) journal = .ok (result, rest)) :
    ActivationCommandEvents result ∧ ActivationCommandCallbacks result := by
  unfold ActivationCallback at callback
  split at callback
  · rcases callback with rfl | rfl
    · exact ⟨activation_authorization_events call, authorization_callbacks call⟩
    · exact ⟨activation_entropy_events call, entropy_callbacks call⟩
  · subst callback
    simp +decide only [Command.resume, Command.resumeCommitted, b, Term.text, ↓reduceIte] at call
    rw [pure_ok call]
    exact ⟨True.intro, True.intro⟩
  · contradiction

end VerifiedKernel.Session.WorkConservation
