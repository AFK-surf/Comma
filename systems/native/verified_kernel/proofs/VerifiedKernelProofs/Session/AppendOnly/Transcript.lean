import VerifiedKernelProofs.Session.AppendOnly.Bookkeeping

/-!
Transcript proofs for the tool-result, assistant, log and seed events, and activity bookkeeping.
-/

namespace VerifiedKernel.Session
open Data

set_option maxHeartbeats 4000000
set_option Elab.async false

theorem transcriptToolResult_extends {s e t : Term} {j r : List Term}
    (h : transcriptToolResult s e j = .ok (t, r)) : TranscriptExtends s t := by
  unfold transcriptToolResult at h
  transcript_walk h

theorem transcriptToolResult_step {s e t : Term} {j r : List Term} :
    transcriptToolResult s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptToolResult s e j ∧ TranscriptExtends s t :=
  step_iff transcriptToolResult_extends

theorem transcriptAssistant_extends {s e t : Term} {j r : List Term}
    (h : transcriptAssistant s e j = .ok (t, r)) : TranscriptExtends s t := by
  unfold transcriptAssistant at h
  transcript_walk h

theorem transcriptAssistant_step {s e t : Term} {j r : List Term} :
    transcriptAssistant s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptAssistant s e j ∧ TranscriptExtends s t :=
  step_iff transcriptAssistant_extends

theorem transcriptLog_extends {s e t : Term} {j r : List Term} (h : transcriptLog s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold transcriptLog at h
  transcript_walk h

theorem transcriptLog_step {s e t : Term} {j r : List Term} :
    transcriptLog s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptLog s e j ∧ TranscriptExtends s t :=
  step_iff transcriptLog_extends

theorem transcriptSeed_extends {s e t : Term} {j r : List Term} (h : transcriptSeed s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold transcriptSeed at h
  transcript_walk h

theorem transcriptSeed_step {s e t : Term} {j r : List Term} :
    transcriptSeed s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptSeed s e j ∧ TranscriptExtends s t :=
  step_iff transcriptSeed_extends

theorem afterEvent_extends {previous next e t : Term} {j r : List Term}
    (h : afterEvent previous next e j = .ok (t, r)) : TranscriptExtends next t := by
  unfold afterEvent at h
  transcript_walk h

theorem afterEvent_step {previous next e t : Term} {j r : List Term} :
    afterEvent previous next e j = .ok (t, r) ↔ Except.ok (t, r) = afterEvent previous next e j ∧ TranscriptExtends next t :=
  step_iff afterEvent_extends

end VerifiedKernel.Session
