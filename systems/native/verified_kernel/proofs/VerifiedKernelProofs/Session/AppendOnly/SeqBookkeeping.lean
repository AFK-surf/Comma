import VerifiedKernelProofs.Session.AppendOnly.SeqState
import VerifiedKernelProofs.Session.AppendOnly.SessionEvent

/-!
The `seq` invariant across queue, metadata, fact, history and stored-result reducers.
-/

namespace VerifiedKernel.Session
open Data

set_option maxHeartbeats 4000000
set_option Elab.async false


theorem pruneResultRefs_seq {s t : Term} {j r : List Term} (h : pruneResultRefs s j = .ok (t, r)) :
    SeqStep s t := by
  unfold pruneResultRefs at h
  sorted_walk h

theorem pruneResultRefs_sstep {s t : Term} {j r : List Term} :
    pruneResultRefs s j = .ok (t, r) ↔ Except.ok (t, r) = pruneResultRefs s j ∧ SeqStep s t :=
  step_iff pruneResultRefs_seq

theorem waitClear_seq {s e t : Term} {j r : List Term} (h : waitClear s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold waitClear at h
  sorted_walk h

theorem waitClear_sstep {s e t : Term} {j r : List Term} :
    waitClear s e j = .ok (t, r) ↔ Except.ok (t, r) = waitClear s e j ∧ SeqStep s t :=
  step_iff waitClear_seq

theorem queueAppend_seq {s e t : Term} {j r : List Term} (h : queueAppend s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold queueAppend at h
  sorted_walk h

theorem queueAppend_sstep {s e t : Term} {j r : List Term} :
    queueAppend s e j = .ok (t, r) ↔ Except.ok (t, r) = queueAppend s e j ∧ SeqStep s t :=
  step_iff queueAppend_seq

theorem queueAck_seq {s e t : Term} {j r : List Term} (h : queueAck s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold queueAck at h
  sorted_walk h

theorem queueAck_sstep {s e t : Term} {j r : List Term} :
    queueAck s e j = .ok (t, r) ↔ Except.ok (t, r) = queueAck s e j ∧ SeqStep s t :=
  step_iff queueAck_seq

theorem queueConsume_seq {s e t : Term} {j r : List Term} (h : queueConsume s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold queueConsume at h
  sorted_walk h

theorem queueConsume_sstep {s e t : Term} {j r : List Term} :
    queueConsume s e j = .ok (t, r) ↔ Except.ok (t, r) = queueConsume s e j ∧ SeqStep s t :=
  step_iff queueConsume_seq

theorem statusTransition_seq {s e t : Term} {j r : List Term} (h : statusTransition s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold statusTransition at h
  sorted_walk h

theorem statusTransition_sstep {s e t : Term} {j r : List Term} :
    statusTransition s e j = .ok (t, r) ↔ Except.ok (t, r) = statusTransition s e j ∧ SeqStep s t :=
  step_iff statusTransition_seq

theorem activityTransition_seq {s e t : Term} {j r : List Term}
    (h : activityTransition s e j = .ok (t, r)) : SeqStep s t := by
  unfold activityTransition at h
  sorted_walk h

theorem activityTransition_sstep {s e t : Term} {j r : List Term} :
    activityTransition s e j = .ok (t, r) ↔ Except.ok (t, r) = activityTransition s e j ∧ SeqStep s t :=
  step_iff activityTransition_seq

theorem metadataCreated_seq {s e t : Term} {j r : List Term} (h : metadataCreated s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold metadataCreated at h
  sorted_walk h

theorem metadataCreated_sstep {s e t : Term} {j r : List Term} :
    metadataCreated s e j = .ok (t, r) ↔ Except.ok (t, r) = metadataCreated s e j ∧ SeqStep s t :=
  step_iff metadataCreated_seq

theorem metadataPrompt_seq {s e t : Term} {j r : List Term} (h : metadataPrompt s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold metadataPrompt at h
  sorted_walk h

theorem metadataPrompt_sstep {s e t : Term} {j r : List Term} :
    metadataPrompt s e j = .ok (t, r) ↔ Except.ok (t, r) = metadataPrompt s e j ∧ SeqStep s t :=
  step_iff metadataPrompt_seq

theorem metadataUpdate_seq {s e t : Term} {j r : List Term} (h : metadataUpdate s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold metadataUpdate at h
  sorted_walk h

theorem metadataUpdate_sstep {s e t : Term} {j r : List Term} :
    metadataUpdate s e j = .ok (t, r) ↔ Except.ok (t, r) = metadataUpdate s e j ∧ SeqStep s t :=
  step_iff metadataUpdate_seq

theorem stampWorkReasons_seq {s e t : Term} {j r : List Term} (h : stampWorkReasons s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold stampWorkReasons at h
  sorted_walk h

theorem stampWorkReasons_sstep {s e t : Term} {j r : List Term} :
    stampWorkReasons s e j = .ok (t, r) ↔ Except.ok (t, r) = stampWorkReasons s e j ∧ SeqStep s t :=
  step_iff stampWorkReasons_seq

theorem stampAgentId_seq {s e t : Term} {j r : List Term} (h : stampAgentId s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold stampAgentId at h
  simp only [ite_ok_iff] at h
  sorted_walk h

theorem stampAgentId_sstep {s e t : Term} {j r : List Term} :
    stampAgentId s e j = .ok (t, r) ↔ Except.ok (t, r) = stampAgentId s e j ∧ SeqStep s t :=
  step_iff stampAgentId_seq

theorem stampRuntimeEpoch_seq {s e t : Term} {j r : List Term} (h : stampRuntimeEpoch s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold stampRuntimeEpoch at h
  simp only [ite_ok_iff] at h
  sorted_walk h

theorem stampRuntimeEpoch_sstep {s e t : Term} {j r : List Term} :
    stampRuntimeEpoch s e j = .ok (t, r) ↔ Except.ok (t, r) = stampRuntimeEpoch s e j ∧ SeqStep s t :=
  step_iff stampRuntimeEpoch_seq

theorem stampRuntimeNode_seq {s e t : Term} {j r : List Term} (h : stampRuntimeNode s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold stampRuntimeNode at h
  simp only [ite_ok_iff] at h
  sorted_walk h

theorem stampRuntimeNode_sstep {s e t : Term} {j r : List Term} :
    stampRuntimeNode s e j = .ok (t, r) ↔ Except.ok (t, r) = stampRuntimeNode s e j ∧ SeqStep s t :=
  step_iff stampRuntimeNode_seq

theorem stampActivityRevision_seq {s e t : Term} {j r : List Term} (h : stampActivityRevision s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold stampActivityRevision at h
  simp only [ite_ok_iff] at h
  sorted_walk h

theorem stampActivityRevision_sstep {s e t : Term} {j r : List Term} :
    stampActivityRevision s e j = .ok (t, r) ↔ Except.ok (t, r) = stampActivityRevision s e j ∧ SeqStep s t :=
  step_iff stampActivityRevision_seq

theorem stampStorageRevision_seq {s e t : Term} {j r : List Term} (h : stampStorageRevision s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold stampStorageRevision at h
  simp only [ite_ok_iff] at h
  sorted_walk h

theorem stampStorageRevision_sstep {s e t : Term} {j r : List Term} :
    stampStorageRevision s e j = .ok (t, r) ↔ Except.ok (t, r) = stampStorageRevision s e j ∧ SeqStep s t :=
  step_iff stampStorageRevision_seq

theorem stampFlushId_seq {s e t : Term} {j r : List Term} (h : stampFlushId s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold stampFlushId at h
  simp only [ite_ok_iff] at h
  sorted_walk h

theorem stampFlushId_sstep {s e t : Term} {j r : List Term} :
    stampFlushId s e j = .ok (t, r) ↔ Except.ok (t, r) = stampFlushId s e j ∧ SeqStep s t :=
  step_iff stampFlushId_seq

theorem stampWorkIndexToken_seq {s e t : Term} {j r : List Term} (h : stampWorkIndexToken s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold stampWorkIndexToken at h
  simp only [ite_ok_iff] at h
  sorted_walk h

theorem stampWorkIndexToken_sstep {s e t : Term} {j r : List Term} :
    stampWorkIndexToken s e j = .ok (t, r) ↔ Except.ok (t, r) = stampWorkIndexToken s e j ∧ SeqStep s t :=
  step_iff stampWorkIndexToken_seq

theorem sessionStamp_seq {s e t : Term} {j r : List Term} (h : sessionStamp s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold sessionStamp at h
  sorted_walk h

theorem sessionStamp_sstep {s e t : Term} {j r : List Term} :
    sessionStamp s e j = .ok (t, r) ↔ Except.ok (t, r) = sessionStamp s e j ∧ SeqStep s t :=
  step_iff sessionStamp_seq

theorem bumpHwmEvent_seq {s e t : Term} {j r : List Term} (h : bumpHwmEvent s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold bumpHwmEvent at h
  sorted_walk h

theorem bumpHwmEvent_sstep {s e t : Term} {j r : List Term} :
    bumpHwmEvent s e j = .ok (t, r) ↔ Except.ok (t, r) = bumpHwmEvent s e j ∧ SeqStep s t :=
  step_iff bumpHwmEvent_seq

theorem compactionFailure_seq {s e t : Term} {j r : List Term}
    (h : compactionFailure s e j = .ok (t, r)) : SeqStep s t := by
  unfold compactionFailure at h
  sorted_walk h

theorem compactionFailure_sstep {s e t : Term} {j r : List Term} :
    compactionFailure s e j = .ok (t, r) ↔ Except.ok (t, r) = compactionFailure s e j ∧ SeqStep s t :=
  step_iff compactionFailure_seq

theorem compactionRecovery_seq {s e t : Term} {j r : List Term}
    (h : compactionRecovery s e j = .ok (t, r)) : SeqStep s t := by
  unfold compactionRecovery at h
  sorted_walk h

theorem compactionRecovery_sstep {s e t : Term} {j r : List Term} :
    compactionRecovery s e j = .ok (t, r) ↔ Except.ok (t, r) = compactionRecovery s e j ∧ SeqStep s t :=
  step_iff compactionRecovery_seq

theorem sessionEvent_seq {s e t : Term} {j r : List Term} (h : sessionEvent s e j = .ok (t, r)) :
    SeqStep s t := sessionEvent_seq_preserved h

theorem sessionEvent_sstep {s e t : Term} {j r : List Term} :
    sessionEvent s e j = .ok (t, r) ↔ Except.ok (t, r) = sessionEvent s e j ∧ SeqStep s t :=
  step_iff sessionEvent_seq

theorem progressStep_seq {s e t : Term} {j r : List Term} (h : progressStep s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold progressStep at h
  sorted_walk h

theorem progressStep_sstep {s e t : Term} {j r : List Term} :
    progressStep s e j = .ok (t, r) ↔ Except.ok (t, r) = progressStep s e j ∧ SeqStep s t :=
  step_iff progressStep_seq

theorem pruneCompactResults_seq {s t : Term} {j r : List Term}
    (h : pruneCompactResults s j = .ok (t, r)) : SeqStep s t := by
  unfold pruneCompactResults at h
  sorted_walk h

theorem pruneCompactResults_sstep {s t : Term} {j r : List Term} :
    pruneCompactResults s j = .ok (t, r) ↔ Except.ok (t, r) = pruneCompactResults s j ∧ SeqStep s t :=
  step_iff pruneCompactResults_seq

theorem recomputeContext_seq {s t : Term} {j r : List Term} (h : recomputeContext s j = .ok (t, r)) :
    SeqStep s t := by
  unfold recomputeContext at h
  sorted_walk h

theorem recomputeContext_sstep {s t : Term} {j r : List Term} :
    recomputeContext s j = .ok (t, r) ↔ Except.ok (t, r) = recomputeContext s j ∧ SeqStep s t :=
  step_iff recomputeContext_seq

/-- Compaction moves watermarks and summaries; it never rewrites the message list. -/
theorem historyCompaction_seq {s e t : Term} {provider : Bool} {j r : List Term}
    (h : historyCompaction s e provider j = .ok (t, r)) : SeqStep s t := by
  unfold historyCompaction at h
  sorted_walk h

theorem historyCompaction_sstep {s e t : Term} {provider : Bool} {j r : List Term} :
    historyCompaction s e provider j = .ok (t, r) ↔ Except.ok (t, r) = historyCompaction s e provider j ∧ SeqStep s t :=
  step_iff historyCompaction_seq

theorem compactResult_seq {s e t : Term} {j r : List Term} (h : compactResult s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold compactResult at h
  sorted_walk h

theorem compactResult_sstep {s e t : Term} {j r : List Term} :
    compactResult s e j = .ok (t, r) ↔ Except.ok (t, r) = compactResult s e j ∧ SeqStep s t :=
  step_iff compactResult_seq

theorem storedResult_seq {s e t : Term} {j r : List Term} (h : storedResult s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold storedResult at h
  sorted_walk h

theorem storedResult_sstep {s e t : Term} {j r : List Term} :
    storedResult s e j = .ok (t, r) ↔ Except.ok (t, r) = storedResult s e j ∧ SeqStep s t :=
  step_iff storedResult_seq

end VerifiedKernel.Session
