import VerifiedKernelProofs.Session.WorkActivationAdmission
import VerifiedKernelProofs.Session.WorkDriverFencedBatch

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

theorem activation_post_write_shape {continuation : Term} (fenced : ActivationPostWrite continuation) :
    ∃ details checkpoint active,
      continuation = writeContinuation (.tuple [b "activation_written", details, checkpoint, active]) := by
  unfold ActivationPostWrite at fenced
  split at fenced
  · obtain ⟨rfl, rfl⟩ := fenced
    exact ⟨_, _, _, rfl⟩
  · contradiction

/-- The actual admission and batch loops retain the activation continuation and all accepted work. -/
theorem activation_raw_write_preserves {context : Context} {hwm prompt active checkpoint saved after : Term}
    {observations events : List Term} {final : PendingRevision.Cursor}
    (ready : QueueReady context.candidate.working)
    (admission : AdmissionTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "activate", .tuple [list [], hwm, prompt, active], checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list events]))
    (write : BatchTrace (resident (some saved) (a "write_result") (a "ok")) (writeFenced final after)) :
    (∃ details capturedCheckpoint capturedActive,
      after = .tuple [b "activation_written", details, capturedCheckpoint, capturedActive]) ∧
    final.baseline = context.candidate.baseline ∧ final.etag = context.candidate.etag ∧
    final.events = context.candidate.events ++ events ∧ QueueReady final.working ∧
    final.working.get (a "storage_format") = context.candidate.working.get (a "storage_format") ∧
    ∀ sealed item, ValueSemantics.Represented context.candidate.working sealed item →
      ValueSemantics.Represented final.working sealed item := by
  obtain ⟨continuation, capturedHwm, savedEq, batch, fenced⟩ := activation_admission_captured admission
  obtain ⟨details, capturedCheckpoint, capturedActive, rfl⟩ := activation_post_write_shape fenced
  rw [savedEq, write_captured] at write
  have valid := fenced_batch_start_valid context
    (.tuple [b "activation_written", details, capturedCheckpoint, capturedActive]) events capturedHwm
  have afterEq := fenced_batch_continuation (fenced_batch_output_preserved write valid)
  subst after
  have execution := Revision.execution_pending (fenced_batch_reflect (fenced_batch_trace_reflect valid write))
  rw [Revision.write_captured] at execution
  exact ⟨⟨details, capturedCheckpoint, capturedActive, rfl⟩,
    PendingRevision.activation_write_preserves ready batch execution⟩

end VerifiedKernel.Session.CommandDriver
