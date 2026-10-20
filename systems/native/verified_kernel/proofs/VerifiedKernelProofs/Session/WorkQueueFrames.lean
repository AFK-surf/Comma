import VerifiedKernelProofs.Session.WorkQueueFrames.Core
import VerifiedKernelProofs.Session.WorkAllocation

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 4000000
set_option Elab.async false

theorem archiveAdvance_queue_frame {s e t : Term} {j r : List Term}
    (h : archiveAdvance s e j = .ok (t, r)) : QueueFrame s t := by
  unfold archiveAdvance at h
  queue_frame_walk h

theorem archiveAdvance_queue_frame_step {s e t : Term} {j r : List Term} :
    archiveAdvance s e j = .ok (t, r) ↔ Except.ok (t, r) = archiveAdvance s e j ∧ QueueFrame s t :=
  step_iff archiveAdvance_queue_frame

theorem queue_frame_allocated {s t : Term} (frame : QueueFrame s t) (allocated : QueueAllocated s) :
    QueueAllocated t := by
  simpa only [QueueAllocated, frame.1, frame.2.1] using allocated

/-- Only queue operations and retry facts can change the queue or its allocator. -/
theorem inner_queue_frame {s e t : Term} {j r : List Term}
    (notAppend : (e.get (b "type") == b "queue_append") = false)
    (notAck : (e.get (b "type") == b "queue_ack") = false)
    (notConsume : (e.get (b "type") == b "queue_consume") = false)
    (notFact : (e.get (b "type") == b "session_event") = false)
    (h : inner s e j = .ok (t, r)) : QueueFrame s t := by
  unfold inner at h
  simp only [notAppend, notAck, notConsume, notFact, Bool.false_and, Bool.false_eq_true,
    ↓reduceIte, ite_ok_iff] at h
  queue_frame_walk h

end VerifiedKernel.Session.WorkConservation
