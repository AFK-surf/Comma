import VerifiedKernelProofs.Session.WorkLedgerFrames.Core
import VerifiedKernelProofs.Session.WorkAllocation

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 4000000
set_option Elab.async false

/-- An admitted event outside the five identity writers leaves the ledger unchanged. -/
theorem admitted_inner_ledger_frame {s e t : Term} {j r : List Term}
    (allowed : Command.inputEventAllowed e = true)
    (notAppend : (e.get (b "type") == b "queue_append") = false)
    (notLog : (e.get (b "type") == b "session_log_message") = false)
    (notSeed : (e.get (b "type") == b "transcript_seed") = false)
    (notRuntime : (e.get (b "type") == b "runtime_message") = false)
    (notDelivery : (e.get (b "type") == b "delivery") = false)
    (h : inner s e j = .ok (t, r)) : LedgerFrame s t := by
  have excluded := InputAdmission.admitted_event_no_retirement (events := [e]) (event := e)
    (by simpa using allowed) (by simp)
  have notAck : (e.get (b "type") == b "queue_ack") = false :=
    Bool.eq_false_iff.mpr (fun h => excluded.1 (binary_beq_true h))
  have notConsume : (e.get (b "type") == b "queue_consume") = false :=
    Bool.eq_false_iff.mpr (fun h => excluded.2.1 (binary_beq_true h))
  have notArchive : (e.get (b "type") == b "archive_advance") = false :=
    Bool.eq_false_iff.mpr (fun h => excluded.2.2.1 (binary_beq_true h))
  have notCompact : (e.get (b "type") == b "session_microcompact") = false :=
    Bool.eq_false_iff.mpr (fun h => excluded.2.2.2 (binary_beq_true h))
  unfold inner at h
  simp only [notAppend, notLog, notSeed, notRuntime, notDelivery, notAck, notConsume, notArchive,
    notCompact, Bool.false_and, Bool.false_eq_true, ↓reduceIte, ite_ok_iff] at h
  ledger_frame_walk h

end VerifiedKernel.Session.WorkConservation
