import VerifiedKernelProofs.Session.WorkPresentationProducers
import VerifiedKernelProofs.Proof.NativeProducerTactic

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

abbrev guardPrepareNative : Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Settlement.guardPrepare"

abbrev guardCleanupNative : Op :=
  native_decl% "VerifiedKernel.Session.Settlement.guardCleanupEvents"

theorem guard_prepare_event_ordinary {state binding output : Term} {journal rest : List Term}
    (call : guardPrepareNative state binding journal = .ok (output, rest)) :
    output = nil ∨ OrdinaryBatch [output] := by
  unfold guardPrepareNative at call
  unfold_execution_head call
  repeat' first
    | (execution_head_is call "Pure.pure"; rw [pure_ok call]; left; rfl)
    | (execution_head_is call "Pure.pure"; rw [pure_ok call]; right
       simp only [OrdinaryBatch, List.mem_singleton, forall_eq]
       constructor
       · rfl
       · simp +decide [OrdinaryKind, Term.get, b, Term.text])
    | (execution_head_is call "Bind.bind"
       have bound := bind_ok call; clear call; rcases bound with ⟨_, _, _, call⟩)
    | dsimp only at call
    | split at call

theorem guard_cleanup_events_ordinary {state result now output : Term} {journal rest : List Term}
    (call : guardCleanupNative state (.tuple [result, now]) journal = .ok (output, rest)) :
    output = nil ∨ ∃ events, output = list events ∧ OrdinaryBatch events := by
  unfold guardCleanupNative at call
  unfold_execution_head call
  repeat' first
    | (execution_head_is call "Pure.pure"; rw [pure_ok call]; left; rfl)
    | (execution_head_is call "Pure.pure"; rw [pure_ok call]; right; refine ⟨_, rfl, ?_⟩
       exact ordinary_nil)
    | (execution_head_is call "Pure.pure"; rw [pure_ok call]; right; refine ⟨_, rfl, ?_⟩
       simp only [OrdinaryBatch, List.mem_singleton, forall_eq]
       constructor
       · rfl
       · simp +decide [OrdinaryKind, Term.get, b, Term.text])
    | (execution_head_is call "Pure.pure"; rw [pure_ok call]; right; refine ⟨_, rfl, ?_⟩
       intro event member
       obtain ⟨source, _, rfl⟩ := List.mem_map.mp member
       split
       all_goals simp +decide [OrdinaryKind, BinaryKeys, Term.get, b, Term.text, Term.isBinary])
    | (execution_head_is call "Bind.bind"
       have bound := bind_ok call; clear call; rcases bound with ⟨_, _, _, call⟩)
    | dsimp only at call
    | split at call

end VerifiedKernel.Session.WorkConservation
