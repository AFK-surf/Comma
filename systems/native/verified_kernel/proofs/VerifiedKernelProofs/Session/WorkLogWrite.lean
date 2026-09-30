import VerifiedKernelProofs.Session.WorkLogPhysical
import VerifiedKernelProofs.Session.WorkDriverLog
import VerifiedKernelProofs.Session.WorkPhysicalWrite

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem log_raw_write_fact {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {context : Context} {entry checkpoint saved continuation : Term}
    {observations events sealed : List Term} {final : PendingRevision.Cursor}
    (history : PhysicalHistory framing objects owner session context.candidate.working sealed)
    (admission : AdmissionTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "log", entry, checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list events]))
    (write : BatchTrace (resident (some saved) (a "write_result") (a "ok")) (writeFenced final continuation)) :
    continuation = b "log_written" ∧
    PhysicalHistory framing objects owner session final.working sealed ∧
    ∃ now fact, LogFactOrigin (logEvent (context.candidate.working.get (a "session_id")) entry now) fact ∧
      PhysicalIdentityFact objects final.working fact := by
  obtain ⟨continuationEq, journal, result, rest, call, started, pending⟩ := log_raw_admission_applied admission write
  rcases log_main_start call with invalidRole | invalidInput | ⟨now, earlier, selected, before, after, actual, _⟩
  · rw [invalidRole] at started
    simp [InputStart, Command.finish, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · rw [invalidInput] at started
    simp [InputStart, Command.finish, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · have same := input_start_unique actual started
    subst events
    obtain ⟨canonical, allowed⟩ := started_log_admitted call started
    obtain ⟨_, _, _, _, _, _, applied⟩ := PendingRevision.write_executes pending
    obtain ⟨logged, inputBatch, metadataBatch⟩ := resident_batch_append applied
    obtain ⟨priorState, prefixBatch, logBatch⟩ := resident_batch_append inputBatch
    have prefixHistory := history.admitted prefixBatch
      (fun e h => canonical e (List.mem_append_left _ h))
      (fun e h => allowed e (List.mem_append_left _ h))
    have sessionEq := prefixHistory.invariant.identified.trans history.invariant.identified.symm
    have routedBatch := logBatch
    rw [← sessionEq] at routedBatch
    obtain ⟨fact, origin, stored⟩ := prefixHistory.log_singleton routedBatch
    rw [sessionEq] at origin
    have loggedHistory := history.admitted inputBatch canonical allowed
    obtain ⟨keys, kinds⟩ := PendingRevision.hwm_metadata nil
    refine ⟨continuationEq, loggedHistory.metadata metadataBatch keys kinds, now, fact, origin, ?_⟩
    cases fact with
    | work item => exact loggedHistory.metadata_physical metadataBatch keys kinds item stored
    | record value => exact loggedHistory.metadata_records metadataBatch keys kinds value stored

end VerifiedKernel.Session.CommandDriver
