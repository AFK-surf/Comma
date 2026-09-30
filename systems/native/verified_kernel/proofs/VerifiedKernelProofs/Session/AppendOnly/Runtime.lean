import VerifiedKernelProofs.Session.AppendOnly.Transcript

/-!
Transcript proofs for runtime messages and deliveries.
-/

namespace VerifiedKernel.Session
open Data

set_option maxHeartbeats 4000000
set_option Elab.async false

theorem runtimeAppend_extends {s e t : Term} {j r : List Term} (h : runtimeAppend s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold runtimeAppend at h
  transcript_walk h

theorem runtimeAppend_step {s e t : Term} {j r : List Term} :
    runtimeAppend s e j = .ok (t, r) ↔ Except.ok (t, r) = runtimeAppend s e j ∧ TranscriptExtends s t :=
  step_iff runtimeAppend_extends

theorem transcriptRuntime_extends {s e t : Term} {j r : List Term}
    (h : transcriptRuntime s e j = .ok (t, r)) : TranscriptExtends s t := by
  unfold transcriptRuntime at h
  transcript_walk h

theorem transcriptRuntime_step {s e t : Term} {j r : List Term} :
    transcriptRuntime s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptRuntime s e j ∧ TranscriptExtends s t :=
  step_iff transcriptRuntime_extends

theorem transcriptDelivery_extends {s e t : Term} {j r : List Term}
    (h : transcriptDelivery s e j = .ok (t, r)) : TranscriptExtends s t := by
  unfold transcriptDelivery at h
  transcript_walk h

theorem transcriptDelivery_step {s e t : Term} {j r : List Term} :
    transcriptDelivery s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptDelivery s e j ∧ TranscriptExtends s t :=
  step_iff transcriptDelivery_extends

end VerifiedKernel.Session
