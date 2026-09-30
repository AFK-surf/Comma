import VerifiedKernelProofs.Session.WorkRecoveryAdmission
import VerifiedKernelProofs.Session.WorkDriverTimestamp
import VerifiedKernelProofs.Session.WorkDriverFencedBatch

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

/-- Recovery's write and timestamp callback retain the initial native revision and recovery scope. -/
theorem recovery_initial_write {context : Context} {args checkpoint saved : Term}
    {observations events : List Term}
    (trace : ObservationTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "recover", args, checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list events])) :
    ∃ hwm scope, OrdinaryBatch events ∧
      saved = .tuple [a "session_command_driver_write", context.pack,
        .tuple [b "durable_fence", .tuple [b "recovered", scope]], list events, hwm] := by
  rw [start_captured] at trace
  have terminal : QueryTerminal (some saved, .tuple [a "validate_write", list events]) := by
    simp [QueryTerminal, a]
  obtain ⟨journal, result, rest, call, _, remaining⟩ := observations_successful_query trace terminal
  rcases recovery_start (args := args) call with ⟨outcome, returned⟩ | ⟨original, hwm, scope, batch, issued⟩
  · rw [returned] at remaining
    have impossible := remaining.fixed (by simp [issue, Command.finish, a])
    simp [issue, Command.finish, a] at impossible
  · rw [issued] at remaining
    change ObservationTrace (issueWrite context (.tuple [b "durable_fence", .tuple [b "recovered", scope]]) original hwm) _ at remaining
    obtain ⟨batch, savedEq⟩ := ordinary_write_observations batch remaining
    exact ⟨hwm, scope, batch, savedEq⟩

theorem recovery_initial_no_effect {context : Context} {args checkpoint saved request : Term}
    {observations : List Term}
    (trace : ObservationTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "recover", args, checkpoint], list observations]))
      (some saved, .tuple [a "effect", request])) : False := by
  rw [start_captured] at trace
  have terminal : QueryTerminal (some saved, .tuple [a "effect", request]) := by simp [QueryTerminal, a]
  obtain ⟨journal, result, rest, call, _, remaining⟩ := observations_successful_query trace terminal
  rcases recovery_start (args := args) call with ⟨outcome, returned⟩ | ⟨original, hwm, scope, batch, issued⟩
  · rw [returned] at remaining
    have impossible := remaining.fixed (by simp [issue, Command.finish, a])
    simp [issue, Command.finish, a] at impossible
  · rw [issued] at remaining
    exact write_observations_no_effect remaining

theorem recovery_admission_captured {context : Context} {args checkpoint saved : Term}
    {observations events : List Term}
    (trace : AdmissionTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "recover", args, checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list events])) :
    ∃ hwm scope, OrdinaryBatch events ∧
      saved = .tuple [a "session_command_driver_write", context.pack,
        .tuple [b "durable_fence", .tuple [b "recovered", scope]], list events, hwm] := by
  rcases trace.first_effect with direct | ⟨_, _, _, impossible, _⟩
  · exact recovery_initial_write direct
  · exact (recovery_initial_no_effect impossible).elim

theorem recovery_raw_admission_applied {context : Context} {args checkpoint saved continuation : Term}
    {observations events : List Term} {final : PendingRevision.Cursor}
    (admission : AdmissionTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "recover", args, checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list events]))
    (write : BatchTrace (resident (some saved) (a "write_result") (a "ok")) (writeFenced final continuation)) :
    ∃ hwm scope, OrdinaryBatch events ∧ continuation = .tuple [b "recovered", scope] ∧
      PendingRevision.Execution
        (PendingRevision.resident (some context.candidate.pack) (a "write") (.tuple [list events, hwm])) final := by
  obtain ⟨hwm, scope, batch, savedEq⟩ := recovery_admission_captured admission
  rw [savedEq, write_captured] at write
  have valid := fenced_batch_start_valid context (.tuple [b "recovered", scope]) events hwm
  have same := fenced_batch_continuation (fenced_batch_output_preserved write valid)
  rw [same] at write
  have execution := Revision.execution_pending (fenced_batch_reflect (fenced_batch_trace_reflect valid write))
  rw [Revision.write_captured] at execution
  exact ⟨hwm, scope, batch, same, execution⟩

end VerifiedKernel.Session.CommandDriver
