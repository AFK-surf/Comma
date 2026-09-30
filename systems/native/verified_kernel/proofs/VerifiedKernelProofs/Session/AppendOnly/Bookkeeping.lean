import VerifiedKernelProofs.Order
import VerifiedKernelProofs.Session.AppendOnly.State
import VerifiedKernelProofs.Session.AppendOnly.SessionEvent

/-!
Transcript proofs for queue, metadata, fact, history and stored-result reducers.
-/

namespace VerifiedKernel.Session
open Data

set_option maxHeartbeats 4000000
set_option Elab.async false

theorem pruneResultRefs_extends {s t : Term} {j r : List Term} (h : pruneResultRefs s j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold pruneResultRefs at h
  transcript_walk h

theorem pruneResultRefs_step {s t : Term} {j r : List Term} :
    pruneResultRefs s j = .ok (t, r) ↔ Except.ok (t, r) = pruneResultRefs s j ∧ TranscriptExtends s t :=
  step_iff pruneResultRefs_extends

theorem waitClear_extends {s e t : Term} {j r : List Term} (h : waitClear s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold waitClear at h
  transcript_walk h

theorem waitClear_step {s e t : Term} {j r : List Term} :
    waitClear s e j = .ok (t, r) ↔ Except.ok (t, r) = waitClear s e j ∧ TranscriptExtends s t :=
  step_iff waitClear_extends

theorem queueAppend_extends {s e t : Term} {j r : List Term} (h : queueAppend s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold queueAppend at h
  transcript_walk h

theorem queueAppend_step {s e t : Term} {j r : List Term} :
    queueAppend s e j = .ok (t, r) ↔ Except.ok (t, r) = queueAppend s e j ∧ TranscriptExtends s t :=
  step_iff queueAppend_extends

theorem queueAck_extends {s e t : Term} {j r : List Term} (h : queueAck s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold queueAck at h
  transcript_walk h

theorem queueAck_step {s e t : Term} {j r : List Term} :
    queueAck s e j = .ok (t, r) ↔ Except.ok (t, r) = queueAck s e j ∧ TranscriptExtends s t :=
  step_iff queueAck_extends

theorem queueConsume_extends {s e t : Term} {j r : List Term} (h : queueConsume s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold queueConsume at h
  transcript_walk h

theorem queueConsume_step {s e t : Term} {j r : List Term} :
    queueConsume s e j = .ok (t, r) ↔ Except.ok (t, r) = queueConsume s e j ∧ TranscriptExtends s t :=
  step_iff queueConsume_extends

theorem statusTransition_extends {s e t : Term} {j r : List Term} (h : statusTransition s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold statusTransition at h
  transcript_walk h

theorem statusTransition_step {s e t : Term} {j r : List Term} :
    statusTransition s e j = .ok (t, r) ↔ Except.ok (t, r) = statusTransition s e j ∧ TranscriptExtends s t :=
  step_iff statusTransition_extends

theorem activityTransition_extends {s e t : Term} {j r : List Term}
    (h : activityTransition s e j = .ok (t, r)) : TranscriptExtends s t := by
  unfold activityTransition at h
  transcript_walk h

theorem activityTransition_step {s e t : Term} {j r : List Term} :
    activityTransition s e j = .ok (t, r) ↔ Except.ok (t, r) = activityTransition s e j ∧ TranscriptExtends s t :=
  step_iff activityTransition_extends

theorem metadataCreated_extends {s e t : Term} {j r : List Term} (h : metadataCreated s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold metadataCreated at h
  transcript_walk h

theorem metadataCreated_step {s e t : Term} {j r : List Term} :
    metadataCreated s e j = .ok (t, r) ↔ Except.ok (t, r) = metadataCreated s e j ∧ TranscriptExtends s t :=
  step_iff metadataCreated_extends

theorem metadataPrompt_extends {s e t : Term} {j r : List Term} (h : metadataPrompt s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold metadataPrompt at h
  transcript_walk h

theorem metadataPrompt_step {s e t : Term} {j r : List Term} :
    metadataPrompt s e j = .ok (t, r) ↔ Except.ok (t, r) = metadataPrompt s e j ∧ TranscriptExtends s t :=
  step_iff metadataPrompt_extends

theorem metadataUpdate_extends {s e t : Term} {j r : List Term} (h : metadataUpdate s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold metadataUpdate at h
  transcript_walk h

theorem metadataUpdate_step {s e t : Term} {j r : List Term} :
    metadataUpdate s e j = .ok (t, r) ↔ Except.ok (t, r) = metadataUpdate s e j ∧ TranscriptExtends s t :=
  step_iff metadataUpdate_extends

theorem stampWorkReasons_extends {s e t : Term} {j r : List Term} (h : stampWorkReasons s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold stampWorkReasons at h
  transcript_walk h

theorem stampWorkReasons_step {s e t : Term} {j r : List Term} :
    stampWorkReasons s e j = .ok (t, r) ↔ Except.ok (t, r) = stampWorkReasons s e j ∧ TranscriptExtends s t :=
  step_iff stampWorkReasons_extends

theorem stampAgentId_extends {s e t : Term} {j r : List Term} (h : stampAgentId s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold stampAgentId at h
  simp only [ite_ok_iff] at h
  transcript_walk h

theorem stampAgentId_step {s e t : Term} {j r : List Term} :
    stampAgentId s e j = .ok (t, r) ↔ Except.ok (t, r) = stampAgentId s e j ∧ TranscriptExtends s t :=
  step_iff stampAgentId_extends

theorem stampRuntimeEpoch_extends {s e t : Term} {j r : List Term} (h : stampRuntimeEpoch s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold stampRuntimeEpoch at h
  simp only [ite_ok_iff] at h
  transcript_walk h

theorem stampRuntimeEpoch_step {s e t : Term} {j r : List Term} :
    stampRuntimeEpoch s e j = .ok (t, r) ↔ Except.ok (t, r) = stampRuntimeEpoch s e j ∧ TranscriptExtends s t :=
  step_iff stampRuntimeEpoch_extends

theorem stampRuntimeNode_extends {s e t : Term} {j r : List Term} (h : stampRuntimeNode s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold stampRuntimeNode at h
  simp only [ite_ok_iff] at h
  transcript_walk h

theorem stampRuntimeNode_step {s e t : Term} {j r : List Term} :
    stampRuntimeNode s e j = .ok (t, r) ↔ Except.ok (t, r) = stampRuntimeNode s e j ∧ TranscriptExtends s t :=
  step_iff stampRuntimeNode_extends

theorem stampActivityRevision_extends {s e t : Term} {j r : List Term} (h : stampActivityRevision s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold stampActivityRevision at h
  simp only [ite_ok_iff] at h
  transcript_walk h

theorem stampActivityRevision_step {s e t : Term} {j r : List Term} :
    stampActivityRevision s e j = .ok (t, r) ↔ Except.ok (t, r) = stampActivityRevision s e j ∧ TranscriptExtends s t :=
  step_iff stampActivityRevision_extends

theorem stampStorageRevision_extends {s e t : Term} {j r : List Term} (h : stampStorageRevision s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold stampStorageRevision at h
  simp only [ite_ok_iff] at h
  transcript_walk h

theorem stampStorageRevision_step {s e t : Term} {j r : List Term} :
    stampStorageRevision s e j = .ok (t, r) ↔ Except.ok (t, r) = stampStorageRevision s e j ∧ TranscriptExtends s t :=
  step_iff stampStorageRevision_extends

theorem stampFlushId_extends {s e t : Term} {j r : List Term} (h : stampFlushId s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold stampFlushId at h
  simp only [ite_ok_iff] at h
  transcript_walk h

theorem stampFlushId_step {s e t : Term} {j r : List Term} :
    stampFlushId s e j = .ok (t, r) ↔ Except.ok (t, r) = stampFlushId s e j ∧ TranscriptExtends s t :=
  step_iff stampFlushId_extends

theorem stampWorkIndexToken_extends {s e t : Term} {j r : List Term} (h : stampWorkIndexToken s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold stampWorkIndexToken at h
  simp only [ite_ok_iff] at h
  transcript_walk h

theorem stampWorkIndexToken_step {s e t : Term} {j r : List Term} :
    stampWorkIndexToken s e j = .ok (t, r) ↔ Except.ok (t, r) = stampWorkIndexToken s e j ∧ TranscriptExtends s t :=
  step_iff stampWorkIndexToken_extends

theorem sessionStamp_extends {s e t : Term} {j r : List Term} (h : sessionStamp s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold sessionStamp at h
  transcript_walk h

theorem sessionStamp_step {s e t : Term} {j r : List Term} :
    sessionStamp s e j = .ok (t, r) ↔ Except.ok (t, r) = sessionStamp s e j ∧ TranscriptExtends s t :=
  step_iff sessionStamp_extends

theorem bumpHwmEvent_extends {s e t : Term} {j r : List Term} (h : bumpHwmEvent s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold bumpHwmEvent at h
  transcript_walk h

theorem bumpHwmEvent_step {s e t : Term} {j r : List Term} :
    bumpHwmEvent s e j = .ok (t, r) ↔ Except.ok (t, r) = bumpHwmEvent s e j ∧ TranscriptExtends s t :=
  step_iff bumpHwmEvent_extends

theorem compactionFailure_extends {s e t : Term} {j r : List Term}
    (h : compactionFailure s e j = .ok (t, r)) : TranscriptExtends s t := by
  unfold compactionFailure at h
  transcript_walk h

theorem compactionFailure_step {s e t : Term} {j r : List Term} :
    compactionFailure s e j = .ok (t, r) ↔ Except.ok (t, r) = compactionFailure s e j ∧ TranscriptExtends s t :=
  step_iff compactionFailure_extends

theorem compactionRecovery_extends {s e t : Term} {j r : List Term}
    (h : compactionRecovery s e j = .ok (t, r)) : TranscriptExtends s t := by
  unfold compactionRecovery at h
  transcript_walk h

theorem compactionRecovery_step {s e t : Term} {j r : List Term} :
    compactionRecovery s e j = .ok (t, r) ↔ Except.ok (t, r) = compactionRecovery s e j ∧ TranscriptExtends s t :=
  step_iff compactionRecovery_extends

theorem sessionEvent_extends {s e t : Term} {j r : List Term} (h : sessionEvent s e j = .ok (t, r)) :
    TranscriptExtends s t :=
  extends_of_frame ((sessionEvent_fields h).2 "messages" rfl)

theorem sessionEvent_step {s e t : Term} {j r : List Term} :
    sessionEvent s e j = .ok (t, r) ↔ Except.ok (t, r) = sessionEvent s e j ∧ TranscriptExtends s t :=
  step_iff sessionEvent_extends

theorem progressStep_extends {s e t : Term} {j r : List Term} (h : progressStep s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold progressStep at h
  transcript_walk h

theorem progressStep_step {s e t : Term} {j r : List Term} :
    progressStep s e j = .ok (t, r) ↔ Except.ok (t, r) = progressStep s e j ∧ TranscriptExtends s t :=
  step_iff progressStep_extends

theorem pruneCompactResults_extends {s t : Term} {j r : List Term}
    (h : pruneCompactResults s j = .ok (t, r)) : TranscriptExtends s t := by
  unfold pruneCompactResults at h
  transcript_walk h

theorem pruneCompactResults_step {s t : Term} {j r : List Term} :
    pruneCompactResults s j = .ok (t, r) ↔ Except.ok (t, r) = pruneCompactResults s j ∧ TranscriptExtends s t :=
  step_iff pruneCompactResults_extends

theorem recomputeContext_extends {s t : Term} {j r : List Term} (h : recomputeContext s j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold recomputeContext at h
  transcript_walk h

theorem recomputeContext_step {s t : Term} {j r : List Term} :
    recomputeContext s j = .ok (t, r) ↔ Except.ok (t, r) = recomputeContext s j ∧ TranscriptExtends s t :=
  step_iff recomputeContext_extends

/-- Compaction moves watermarks and summaries; it never rewrites the message list. -/
theorem historyCompaction_extends {s e t : Term} {provider : Bool} {j r : List Term}
    (h : historyCompaction s e provider j = .ok (t, r)) : TranscriptExtends s t := by
  unfold historyCompaction at h
  transcript_walk h

theorem historyCompaction_step {s e t : Term} {provider : Bool} {j r : List Term} :
    historyCompaction s e provider j = .ok (t, r) ↔ Except.ok (t, r) = historyCompaction s e provider j ∧ TranscriptExtends s t :=
  step_iff historyCompaction_extends

theorem compactResult_extends {s e t : Term} {j r : List Term} (h : compactResult s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold compactResult at h
  transcript_walk h

theorem compactResult_step {s e t : Term} {j r : List Term} :
    compactResult s e j = .ok (t, r) ↔ Except.ok (t, r) = compactResult s e j ∧ TranscriptExtends s t :=
  step_iff compactResult_extends

theorem storedResult_extends {s e t : Term} {j r : List Term} (h : storedResult s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold storedResult at h
  transcript_walk h

theorem storedResult_step {s e t : Term} {j r : List Term} :
    storedResult s e j = .ok (t, r) ↔ Except.ok (t, r) = storedResult s e j ∧ TranscriptExtends s t :=
  step_iff storedResult_extends

end VerifiedKernel.Session
