import VerifiedKernelProofs.Session.WorkActivationAdmission
import VerifiedKernelProofs.Session.WorkDriverQueryPrefix
import VerifiedKernelProofs.Session.WorkOrdinaryWrite

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem ordinary_timestamp_batch {events : List Term} (now : Int) (batch : OrdinaryBatch events) :
    OrdinaryBatch (events.map (fun event => Command.timestampLifecycle event now)) := by
  intro event member
  obtain ⟨original, originalMember, rfl⟩ := List.mem_map.mp member
  refine ⟨timestampLifecycle_binary_keys now (batch original originalMember).1, ?_⟩
  have kind : (Command.timestampLifecycle original now).get (b "type") = original.get (b "type") := by
    unfold Command.timestampLifecycle
    split
    · exact get_put_binary_other _ _ (by decide)
    · rfl
  rw [kind]
  exact (batch original originalMember).2

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

theorem ordinary_write_observations {context : Context} {continuation hwm saved : Term}
    {original events : List Term} (batch : OrdinaryBatch original)
    (trace : ObservationTrace (issueWrite context continuation original hwm)
      (some saved, .tuple [a "validate_write", list events])) :
    OrdinaryBatch events ∧
      saved = .tuple [a "session_command_driver_write", context.pack, continuation, list events, hwm] := by
  unfold issueWrite at trace
  split at trace
  · generalize finished : (some saved, Term.tuple [a "validate_write", list events]) = final at trace
    cases trace with
    | done => simp [a] at finished
    | resume tail =>
      rw [← finished] at tail
      rw [activation_timestamp_response] at tail
      split at tail
      · have same := tail.fixed (by simp [preparedWrite, a])
        simp only [preparedWrite, Prod.mk.injEq, Option.some.injEq, Term.tuple.injEq,
          List.cons.injEq, and_true, true_and, list, Term.list.injEq] at same
        obtain ⟨savedEq, eventEq⟩ := same
        rw [eventEq]
        exact ⟨ordinary_timestamp_batch _ batch, savedEq⟩
      · have same := tail.fixed (by simp [invalid, RevisionFence.invalid, a])
        cases congrArg Prod.fst same
  · have same := trace.fixed (by simp [preparedWrite, a])
    simp only [preparedWrite, Prod.mk.injEq, Option.some.injEq, Term.tuple.injEq,
      List.cons.injEq, and_true, true_and, list, Term.list.injEq] at same
    obtain ⟨savedEq, eventEq⟩ := same
    subst events
    exact ⟨batch, savedEq⟩

theorem write_observations_no_effect {context : Context} {continuation hwm saved request : Term}
    {events : List Term}
    (trace : ObservationTrace (issueWrite context continuation events hwm)
      (some saved, .tuple [a "effect", request])) : False := by
  unfold issueWrite at trace
  split at trace
  · generalize finished : (some saved, Term.tuple [a "effect", request]) = final at trace
    cases trace with
    | done => simp [a] at finished
    | resume tail =>
      rw [← finished, activation_timestamp_response] at tail
      split at tail
      · have same := tail.fixed (by simp [preparedWrite, a])
        simp [preparedWrite, a] at same
      · have same := tail.fixed (by simp [invalid, RevisionFence.invalid, a])
        cases congrArg Prod.fst same
  · have same := trace.fixed (by simp [preparedWrite, a])
    simp [preparedWrite, a] at same

end VerifiedKernel.Session.CommandDriver
