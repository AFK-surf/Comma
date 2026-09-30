import VerifiedKernelProofs.Session.AppendOnly.Core

/-!
Transcript proofs for the append primitives, async settlement, and reply bookkeeping.
-/

namespace VerifiedKernel.Session
open Data

set_option maxHeartbeats 4000000
set_option Elab.async false

theorem appendFields_extends {s e m t : Term} {j r : List Term} (h : appendFields s e m j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold appendFields at h
  transcript_walk h

theorem appendFields_step {s e m t : Term} {j r : List Term} :
    appendFields s e m j = .ok (t, r) ↔ Except.ok (t, r) = appendFields s e m j ∧ TranscriptExtends s t :=
  step_iff appendFields_extends

theorem bumpHwm_extends {s hwm t : Term} {j r : List Term} (h : bumpHwm s hwm j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold bumpHwm at h
  transcript_walk h

theorem bumpHwm_step {s hwm t : Term} {j r : List Term} :
    bumpHwm s hwm j = .ok (t, r) ↔ Except.ok (t, r) = bumpHwm s hwm j ∧ TranscriptExtends s t :=
  step_iff bumpHwm_extends

theorem appendMessage_extends {s e m t : Term} {j r : List Term} (h : appendMessage s e m j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold appendMessage at h
  transcript_walk h

theorem appendMessage_step {s e m t : Term} {j r : List Term} :
    appendMessage s e m j = .ok (t, r) ↔ Except.ok (t, r) = appendMessage s e m j ∧ TranscriptExtends s t :=
  step_iff appendMessage_extends

theorem noteResult_extends {s tool input status errorClass message content t : Term} {j r : List Term}
    (h : noteResult s tool input status errorClass message content j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold noteResult at h
  transcript_walk h

theorem noteResult_step {s tool input status errorClass message content t : Term} {j r : List Term} :
    noteResult s tool input status errorClass message content j = .ok (t, r) ↔ Except.ok (t, r) = noteResult s tool input status errorClass message content j ∧ TranscriptExtends s t :=
  step_iff noteResult_extends

theorem noteAsyncResult_extends {s existing e status t : Term} {j r : List Term}
    (h : noteAsyncResult s existing e status j = .ok (t, r)) : TranscriptExtends s t := by
  unfold noteAsyncResult at h
  transcript_walk h

theorem noteAsyncResult_step {s existing e status t : Term} {j r : List Term} :
    noteAsyncResult s existing e status j = .ok (t, r) ↔ Except.ok (t, r) = noteAsyncResult s existing e status j ∧ TranscriptExtends s t :=
  step_iff noteAsyncResult_extends

theorem asyncStart_extends {s e t : Term} {j r : List Term} (h : asyncStart s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold asyncStart at h
  transcript_walk h

theorem asyncStart_step {s e t : Term} {j r : List Term} :
    asyncStart s e j = .ok (t, r) ↔ Except.ok (t, r) = asyncStart s e j ∧ TranscriptExtends s t :=
  step_iff asyncStart_extends

theorem asyncTerminal_extends {s e status t : Term} {j r : List Term}
    (h : asyncTerminal s e status j = .ok (t, r)) : TranscriptExtends s t := by
  unfold asyncTerminal at h
  transcript_walk h

theorem asyncTerminal_step {s e status t : Term} {j r : List Term} :
    asyncTerminal s e status j = .ok (t, r) ↔ Except.ok (t, r) = asyncTerminal s e status j ∧ TranscriptExtends s t :=
  step_iff asyncTerminal_extends

theorem resetFresh_extends {s m t : Term} {j r : List Term} (h : resetFresh s m j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold resetFresh at h
  transcript_walk h

theorem resetFresh_step {s m t : Term} {j r : List Term} :
    resetFresh s m j = .ok (t, r) ↔ Except.ok (t, r) = resetFresh s m j ∧ TranscriptExtends s t :=
  step_iff resetFresh_extends

theorem addObligation_extends {s raw t : Term} {j r : List Term} (h : addObligation s raw j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold addObligation at h
  transcript_walk h

theorem addObligation_step {s raw t : Term} {j r : List Term} :
    addObligation s raw j = .ok (t, r) ↔ Except.ok (t, r) = addObligation s raw j ∧ TranscriptExtends s t :=
  step_iff addObligation_extends

theorem obligationResolve_extends {s key t : Term} {j r : List Term}
    (h : obligationResolve s key j = .ok (t, r)) : TranscriptExtends s t := by
  unfold obligationResolve at h
  transcript_walk h

theorem obligationResolve_step {s key t : Term} {j r : List Term} :
    obligationResolve s key j = .ok (t, r) ↔ Except.ok (t, r) = obligationResolve s key j ∧ TranscriptExtends s t :=
  step_iff obligationResolve_extends

theorem obligationCard_extends {s conversation limit t : Term} {j r : List Term}
    (h : obligationCard s conversation limit j = .ok (t, r)) : TranscriptExtends s t := by
  unfold obligationCard at h
  transcript_walk h

theorem obligationCard_step {s conversation limit t : Term} {j r : List Term} :
    obligationCard s conversation limit j = .ok (t, r) ↔ Except.ok (t, r) = obligationCard s conversation limit j ∧ TranscriptExtends s t :=
  step_iff obligationCard_extends

theorem replyRepair_extends {s e t : Term} {j r : List Term} (h : replyRepair s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold replyRepair at h
  transcript_walk h

theorem replyRepair_step {s e t : Term} {j r : List Term} :
    replyRepair s e j = .ok (t, r) ↔ Except.ok (t, r) = replyRepair s e j ∧ TranscriptExtends s t :=
  step_iff replyRepair_extends

theorem replyIntent_extends {s e t : Term} {j r : List Term} (h : replyIntent s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold replyIntent at h
  transcript_walk h

theorem replyIntent_step {s e t : Term} {j r : List Term} :
    replyIntent s e j = .ok (t, r) ↔ Except.ok (t, r) = replyIntent s e j ∧ TranscriptExtends s t :=
  step_iff replyIntent_extends

theorem retireIntent_extends {s e t : Term} {j r : List Term} (h : retireIntent s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold retireIntent at h
  transcript_walk h

theorem retireIntent_step {s e t : Term} {j r : List Term} :
    retireIntent s e j = .ok (t, r) ↔ Except.ok (t, r) = retireIntent s e j ∧ TranscriptExtends s t :=
  step_iff retireIntent_extends

theorem activationStarted_extends {s raw t : Term} {j r : List Term}
    (h : activationStarted s raw j = .ok (t, r)) : TranscriptExtends s t := by
  unfold activationStarted at h
  transcript_walk h

theorem activationStarted_step {s raw t : Term} {j r : List Term} :
    activationStarted s raw j = .ok (t, r) ↔ Except.ok (t, r) = activationStarted s raw j ∧ TranscriptExtends s t :=
  step_iff activationStarted_extends

theorem activationFinished_extends {s identity t : Term} {j r : List Term}
    (h : activationFinished s identity j = .ok (t, r)) : TranscriptExtends s t := by
  unfold activationFinished at h
  transcript_walk h

theorem activationFinished_step {s identity t : Term} {j r : List Term} :
    activationFinished s identity j = .ok (t, r) ↔ Except.ok (t, r) = activationFinished s identity j ∧ TranscriptExtends s t :=
  step_iff activationFinished_extends

theorem sessionAck_extends {s e t : Term} {j r : List Term} (h : sessionAck s e j = .ok (t, r)) :
    TranscriptExtends s t := by
  unfold sessionAck at h
  transcript_walk h

theorem sessionAck_step {s e t : Term} {j r : List Term} :
    sessionAck s e j = .ok (t, r) ↔ Except.ok (t, r) = sessionAck s e j ∧ TranscriptExtends s t :=
  step_iff sessionAck_extends

end VerifiedKernel.Session
