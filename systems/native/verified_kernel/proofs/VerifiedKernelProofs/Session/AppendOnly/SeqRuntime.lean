import VerifiedKernelProofs.Session.AppendOnly.SeqTranscript

/-!
The `seq` invariant across runtime messages and deliveries.
-/

namespace VerifiedKernel.Session
open Data

set_option maxHeartbeats 4000000
set_option Elab.async false


/-- Compose the Session operations of `runtimeAppend` (`runtimeAppend_ops`). This is much
cheaper than a walk over every branch of `runtimeAppend`. -/
theorem runtimeAppend_seq {s e t : Term} {j r : List Term} (h : runtimeAppend s e j = .ok (t, r)) :
    SeqStep s t := by
  obtain ⟨_, _, _, _, _, _, _, _, _, _, _, _, _, _, appended, written, bumped, reset⟩ := runtimeAppend_ops h
  exact seq_trans (appendFields_seq appended) (seq_trans (write_seq_frame written rfl)
    (seq_trans (bumpHwm_seq bumped) (resetFresh_seq reset)))

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

/-- Compose the Session operations of `transcriptDelivery` (`transcriptDelivery_ops`). This is
much cheaper than a walk over every branch of `transcriptDelivery`. -/
theorem transcriptDelivery_seq {s e t : Term} {j r : List Term}
    (h : transcriptDelivery s e j = .ok (t, r)) : SeqStep s t := by
  rcases transcriptDelivery_ops h with rfl | ⟨_, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, appended, written, obligated, bumped, reset⟩
  · exact seq_refl _
  · exact seq_trans (appendFields_seq appended) (seq_trans (write_seq_frame written rfl)
      (seq_trans (addObligation_seq obligated) (seq_trans (bumpHwm_seq bumped) (resetFresh_seq reset))))

theorem transcriptDelivery_sstep {s e t : Term} {j r : List Term} :
    transcriptDelivery s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptDelivery s e j ∧ SeqStep s t :=
  step_iff transcriptDelivery_seq

end VerifiedKernel.Session
