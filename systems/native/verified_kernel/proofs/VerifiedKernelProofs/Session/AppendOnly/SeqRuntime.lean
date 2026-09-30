import VerifiedKernelProofs.Session.AppendOnly.SeqTranscript

/-!
The `seq` invariant across runtime messages and deliveries.
-/

namespace VerifiedKernel.Session
open Data

set_option maxHeartbeats 4000000
set_option Elab.async false


theorem runtimeAppend_seq {s e t : Term} {j r : List Term} (h : runtimeAppend s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold runtimeAppend at h
  sorted_walk h

theorem runtimeAppend_sstep {s e t : Term} {j r : List Term} :
    runtimeAppend s e j = .ok (t, r) ↔ Except.ok (t, r) = runtimeAppend s e j ∧ SeqStep s t :=
  step_iff runtimeAppend_seq

theorem transcriptRuntime_seq {s e t : Term} {j r : List Term}
    (h : transcriptRuntime s e j = .ok (t, r)) : SeqStep s t := by
  unfold transcriptRuntime at h
  sorted_walk h

theorem transcriptRuntime_sstep {s e t : Term} {j r : List Term} :
    transcriptRuntime s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptRuntime s e j ∧ SeqStep s t :=
  step_iff transcriptRuntime_seq

theorem transcriptDelivery_seq {s e t : Term} {j r : List Term}
    (h : transcriptDelivery s e j = .ok (t, r)) : SeqStep s t := by
  unfold transcriptDelivery at h
  sorted_walk h

theorem transcriptDelivery_sstep {s e t : Term} {j r : List Term} :
    transcriptDelivery s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptDelivery s e j ∧ SeqStep s t :=
  step_iff transcriptDelivery_seq

end VerifiedKernel.Session
