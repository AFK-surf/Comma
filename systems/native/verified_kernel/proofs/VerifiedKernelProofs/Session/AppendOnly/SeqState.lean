import VerifiedKernelProofs.Session.AppendOnly.SeqCore

/-!
The `seq` invariant across the append primitives, async settlement, and reply bookkeeping.
-/

namespace VerifiedKernel.Session
open Data

set_option maxHeartbeats 4000000
set_option Elab.async false


theorem appendFields_seq {s e m t : Term} {j r : List Term} (h : appendFields s e m j = .ok (t, r)) :
    SeqStep s t := by
  unfold appendFields at h
  sorted_walk h

theorem appendFields_sstep {s e m t : Term} {j r : List Term} :
    appendFields s e m j = .ok (t, r) ↔ Except.ok (t, r) = appendFields s e m j ∧ SeqStep s t :=
  step_iff appendFields_seq

theorem bumpHwm_seq {s hwm t : Term} {j r : List Term} (h : bumpHwm s hwm j = .ok (t, r)) :
    SeqStep s t := by
  unfold bumpHwm at h
  sorted_walk h

theorem bumpHwm_sstep {s hwm t : Term} {j r : List Term} :
    bumpHwm s hwm j = .ok (t, r) ↔ Except.ok (t, r) = bumpHwm s hwm j ∧ SeqStep s t :=
  step_iff bumpHwm_seq

theorem appendMessage_seq {s e m t : Term} {j r : List Term} (h : appendMessage s e m j = .ok (t, r)) :
    SeqStep s t := by
  unfold appendMessage at h
  sorted_walk h

theorem appendMessage_sstep {s e m t : Term} {j r : List Term} :
    appendMessage s e m j = .ok (t, r) ↔ Except.ok (t, r) = appendMessage s e m j ∧ SeqStep s t :=
  step_iff appendMessage_seq

theorem noteResult_seq {s tool input status errorClass message content t : Term} {j r : List Term}
    (h : noteResult s tool input status errorClass message content j = .ok (t, r)) :
    SeqStep s t := by
  unfold noteResult at h
  sorted_walk h

theorem noteResult_sstep {s tool input status errorClass message content t : Term} {j r : List Term} :
    noteResult s tool input status errorClass message content j = .ok (t, r) ↔ Except.ok (t, r) = noteResult s tool input status errorClass message content j ∧ SeqStep s t :=
  step_iff noteResult_seq

theorem noteAsyncResult_seq {s existing e status t : Term} {j r : List Term}
    (h : noteAsyncResult s existing e status j = .ok (t, r)) : SeqStep s t := by
  unfold noteAsyncResult at h
  sorted_walk h

theorem noteAsyncResult_sstep {s existing e status t : Term} {j r : List Term} :
    noteAsyncResult s existing e status j = .ok (t, r) ↔ Except.ok (t, r) = noteAsyncResult s existing e status j ∧ SeqStep s t :=
  step_iff noteAsyncResult_seq

theorem asyncStart_seq {s e t : Term} {j r : List Term} (h : asyncStart s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold asyncStart at h
  sorted_walk h

theorem asyncStart_sstep {s e t : Term} {j r : List Term} :
    asyncStart s e j = .ok (t, r) ↔ Except.ok (t, r) = asyncStart s e j ∧ SeqStep s t :=
  step_iff asyncStart_seq

theorem asyncTerminal_seq {s e status t : Term} {j r : List Term}
    (h : asyncTerminal s e status j = .ok (t, r)) : SeqStep s t := by
  unfold asyncTerminal at h
  sorted_walk h

theorem asyncTerminal_sstep {s e status t : Term} {j r : List Term} :
    asyncTerminal s e status j = .ok (t, r) ↔ Except.ok (t, r) = asyncTerminal s e status j ∧ SeqStep s t :=
  step_iff asyncTerminal_seq

theorem resetFresh_seq {s m t : Term} {j r : List Term} (h : resetFresh s m j = .ok (t, r)) :
    SeqStep s t := by
  unfold resetFresh at h
  sorted_walk h

theorem resetFresh_sstep {s m t : Term} {j r : List Term} :
    resetFresh s m j = .ok (t, r) ↔ Except.ok (t, r) = resetFresh s m j ∧ SeqStep s t :=
  step_iff resetFresh_seq

theorem addObligation_seq {s raw t : Term} {j r : List Term} (h : addObligation s raw j = .ok (t, r)) :
    SeqStep s t := by
  unfold addObligation at h
  sorted_walk h

theorem addObligation_sstep {s raw t : Term} {j r : List Term} :
    addObligation s raw j = .ok (t, r) ↔ Except.ok (t, r) = addObligation s raw j ∧ SeqStep s t :=
  step_iff addObligation_seq

theorem obligationResolve_seq {s key t : Term} {j r : List Term}
    (h : obligationResolve s key j = .ok (t, r)) : SeqStep s t := by
  unfold obligationResolve at h
  sorted_walk h

theorem obligationResolve_sstep {s key t : Term} {j r : List Term} :
    obligationResolve s key j = .ok (t, r) ↔ Except.ok (t, r) = obligationResolve s key j ∧ SeqStep s t :=
  step_iff obligationResolve_seq

theorem obligationCard_seq {s conversation limit t : Term} {j r : List Term}
    (h : obligationCard s conversation limit j = .ok (t, r)) : SeqStep s t := by
  unfold obligationCard at h
  sorted_walk h

theorem obligationCard_sstep {s conversation limit t : Term} {j r : List Term} :
    obligationCard s conversation limit j = .ok (t, r) ↔ Except.ok (t, r) = obligationCard s conversation limit j ∧ SeqStep s t :=
  step_iff obligationCard_seq

theorem replyRepair_seq {s e t : Term} {j r : List Term} (h : replyRepair s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold replyRepair at h
  sorted_walk h

theorem replyRepair_sstep {s e t : Term} {j r : List Term} :
    replyRepair s e j = .ok (t, r) ↔ Except.ok (t, r) = replyRepair s e j ∧ SeqStep s t :=
  step_iff replyRepair_seq

theorem replyIntent_seq {s e t : Term} {j r : List Term} (h : replyIntent s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold replyIntent at h
  sorted_walk h

theorem replyIntent_sstep {s e t : Term} {j r : List Term} :
    replyIntent s e j = .ok (t, r) ↔ Except.ok (t, r) = replyIntent s e j ∧ SeqStep s t :=
  step_iff replyIntent_seq

theorem retireIntent_seq {s e t : Term} {j r : List Term} (h : retireIntent s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold retireIntent at h
  sorted_walk h

theorem retireIntent_sstep {s e t : Term} {j r : List Term} :
    retireIntent s e j = .ok (t, r) ↔ Except.ok (t, r) = retireIntent s e j ∧ SeqStep s t :=
  step_iff retireIntent_seq

theorem activationStarted_seq {s raw t : Term} {j r : List Term}
    (h : activationStarted s raw j = .ok (t, r)) : SeqStep s t := by
  unfold activationStarted at h
  sorted_walk h

theorem activationStarted_sstep {s raw t : Term} {j r : List Term} :
    activationStarted s raw j = .ok (t, r) ↔ Except.ok (t, r) = activationStarted s raw j ∧ SeqStep s t :=
  step_iff activationStarted_seq

theorem activationFinished_seq {s identity t : Term} {j r : List Term}
    (h : activationFinished s identity j = .ok (t, r)) : SeqStep s t := by
  unfold activationFinished at h
  sorted_walk h

theorem activationFinished_sstep {s identity t : Term} {j r : List Term} :
    activationFinished s identity j = .ok (t, r) ↔ Except.ok (t, r) = activationFinished s identity j ∧ SeqStep s t :=
  step_iff activationFinished_seq

theorem sessionAck_seq {s e t : Term} {j r : List Term} (h : sessionAck s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold sessionAck at h
  sorted_walk h

theorem sessionAck_sstep {s e t : Term} {j r : List Term} :
    sessionAck s e j = .ok (t, r) ↔ Except.ok (t, r) = sessionAck s e j ∧ SeqStep s t :=
  step_iff sessionAck_seq

end VerifiedKernel.Session
