import VerifiedKernelProofs.Session.WorkFrames
import VerifiedKernelProofs.Session.InputAdmission
import VerifiedKernelProofs.Session.AppendOnly.SessionEvent

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 4000000
set_option Elab.async false

def LedgerFrame (s t : Term) : Prop := t.get (a "input_dedupe") = s.get (a "input_dedupe")

theorem ledger_frame_refl (s : Term) : LedgerFrame s s := rfl

theorem ledger_frame_trans {s t u : Term} (left : LedgerFrame s t) (right : LedgerFrame t u) :
    LedgerFrame s u := right.trans left

theorem write_ledger_frame {s t : Term} {entries : List (String × Term)} {j r : List Term}
    (h : write s entries j = .ok (t, r))
    (allowed : entries.all (fun entry => entry.1 != "input_dedupe") = true) : LedgerFrame s t :=
  write_field_frame h allowed

theorem write_ledger_frame_step {s t : Term} {entries : List (String × Term)} {j r : List Term} :
    write s entries j = .ok (t, r) ↔ Except.ok (t, r) = write s entries j ∧
      (entries.all (fun entry => entry.1 != "input_dedupe") = true → LedgerFrame s t) :=
  step_iff write_ledger_frame

syntax "ledger_frame_step" ident : tactic
macro_rules
  | `(tactic| ledger_frame_step $h:ident) =>
    `(tactic| first
      | (head_is $h [write]; simp only [write_ledger_frame_step] at $h:ident; obtain ⟨_, kept⟩ := $h
         refine ledger_frame_trans (kept rfl) ?_)
      | (head_step $h "_ledger_frame_step"; obtain ⟨_, kept⟩ := $h; refine ledger_frame_trans kept ?_))

syntax "ledger_frame_walk" ident : tactic
macro_rules
  | `(tactic| ledger_frame_walk $h:ident) => do
  let hx := Lean.mkIdent `hx
  let hl := Lean.mkIdent `hl
  let rfl := Lean.mkIdent `rfl
  `(tactic| repeat' first
      | (head_is $h [Pure.pure]; simp only [pure_ok_iff] at $h:ident; cases $h:ident; exact ledger_frame_refl _)
      | (head_is $h [argumentError, inspectedError, VerifiedKernel.fail]
         simp only [argumentError, inspectedError, fail_ok_iff] at $h:ident)
      | (ledger_frame_step $h; exact ledger_frame_refl _)
      | split at $h:ident
      | (generalize Term.get _ _ = discriminant at $h:ident; split at $h:ident)
      | (generalize List.filter _ _ = discriminant at $h:ident; split at $h:ident)
      | (generalize List.find? _ _ = discriminant at $h:ident; split at $h:ident)
      | (obtain ⟨_, $h:ident⟩ | ⟨_, $h:ident⟩ := ($h : _ ∨ _))
      | ((obtain ⟨_, _, $hx:ident, $h:ident⟩ := bind_ok $h)
         first
           | (head_is $hx [field, fetch]; simp only [field, fetch_ok_iff] at $hx:ident
              obtain ⟨_, _, $rfl:ident, _⟩ := $hx)
           | (head_is $hx [Data.append]; simp only [append_ok_iff] at $hx:ident
              obtain ⟨_, _, $hl:ident, _, $rfl:ident, _⟩ := $hx)
           | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
           | ledger_frame_step $hx
           | (split at $hx:ident <;> first
               | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
               | ledger_frame_step $hx
               | ((repeat (fail_if_success ledger_frame_step $hx; obtain ⟨_, _, _, $hx:ident⟩ := bind_ok $hx))
                  ledger_frame_step $hx)
               | skip)
           | skip)
      | dsimp only at $h:ident)

theorem appendFields_ledger_frame {s e m t : Term} {j r : List Term} (h : appendFields s e m j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold appendFields at h
  ledger_frame_walk h


theorem appendFields_ledger_frame_step {s e m t : Term} {j r : List Term} :
    appendFields s e m j = .ok (t, r) ↔ Except.ok (t, r) = appendFields s e m j ∧ LedgerFrame s t :=
  step_iff appendFields_ledger_frame


theorem bumpHwm_ledger_frame {s hwm t : Term} {j r : List Term} (h : bumpHwm s hwm j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold bumpHwm at h
  ledger_frame_walk h


theorem bumpHwm_ledger_frame_step {s hwm t : Term} {j r : List Term} :
    bumpHwm s hwm j = .ok (t, r) ↔ Except.ok (t, r) = bumpHwm s hwm j ∧ LedgerFrame s t :=
  step_iff bumpHwm_ledger_frame


theorem appendMessage_ledger_frame {s e m t : Term} {j r : List Term} (h : appendMessage s e m j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold appendMessage at h
  ledger_frame_walk h


theorem appendMessage_ledger_frame_step {s e m t : Term} {j r : List Term} :
    appendMessage s e m j = .ok (t, r) ↔ Except.ok (t, r) = appendMessage s e m j ∧ LedgerFrame s t :=
  step_iff appendMessage_ledger_frame


theorem noteResult_ledger_frame {s tool input status errorClass message content t : Term} {j r : List Term}
    (h : noteResult s tool input status errorClass message content j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold noteResult at h
  ledger_frame_walk h


theorem noteResult_ledger_frame_step {s tool input status errorClass message content t : Term} {j r : List Term} :
    noteResult s tool input status errorClass message content j = .ok (t, r) ↔ Except.ok (t, r) = noteResult s tool input status errorClass message content j ∧ LedgerFrame s t :=
  step_iff noteResult_ledger_frame


theorem noteAsyncResult_ledger_frame {s existing e status t : Term} {j r : List Term}
    (h : noteAsyncResult s existing e status j = .ok (t, r)) : LedgerFrame s t := by
  unfold noteAsyncResult at h
  ledger_frame_walk h


theorem noteAsyncResult_ledger_frame_step {s existing e status t : Term} {j r : List Term} :
    noteAsyncResult s existing e status j = .ok (t, r) ↔ Except.ok (t, r) = noteAsyncResult s existing e status j ∧ LedgerFrame s t :=
  step_iff noteAsyncResult_ledger_frame


theorem asyncStart_ledger_frame {s e t : Term} {j r : List Term} (h : asyncStart s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold asyncStart at h
  ledger_frame_walk h


theorem asyncStart_ledger_frame_step {s e t : Term} {j r : List Term} :
    asyncStart s e j = .ok (t, r) ↔ Except.ok (t, r) = asyncStart s e j ∧ LedgerFrame s t :=
  step_iff asyncStart_ledger_frame


theorem asyncTerminal_ledger_frame {s e status t : Term} {j r : List Term}
    (h : asyncTerminal s e status j = .ok (t, r)) : LedgerFrame s t := by
  unfold asyncTerminal at h
  ledger_frame_walk h


theorem asyncTerminal_ledger_frame_step {s e status t : Term} {j r : List Term} :
    asyncTerminal s e status j = .ok (t, r) ↔ Except.ok (t, r) = asyncTerminal s e status j ∧ LedgerFrame s t :=
  step_iff asyncTerminal_ledger_frame


theorem resetFresh_ledger_frame {s m t : Term} {j r : List Term} (h : resetFresh s m j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold resetFresh at h
  ledger_frame_walk h


theorem resetFresh_ledger_frame_step {s m t : Term} {j r : List Term} :
    resetFresh s m j = .ok (t, r) ↔ Except.ok (t, r) = resetFresh s m j ∧ LedgerFrame s t :=
  step_iff resetFresh_ledger_frame


theorem addObligation_ledger_frame {s raw t : Term} {j r : List Term} (h : addObligation s raw j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold addObligation at h
  ledger_frame_walk h


theorem addObligation_ledger_frame_step {s raw t : Term} {j r : List Term} :
    addObligation s raw j = .ok (t, r) ↔ Except.ok (t, r) = addObligation s raw j ∧ LedgerFrame s t :=
  step_iff addObligation_ledger_frame


theorem obligationResolve_ledger_frame {s key t : Term} {j r : List Term}
    (h : obligationResolve s key j = .ok (t, r)) : LedgerFrame s t := by
  unfold obligationResolve at h
  ledger_frame_walk h


theorem obligationResolve_ledger_frame_step {s key t : Term} {j r : List Term} :
    obligationResolve s key j = .ok (t, r) ↔ Except.ok (t, r) = obligationResolve s key j ∧ LedgerFrame s t :=
  step_iff obligationResolve_ledger_frame


theorem obligationCard_ledger_frame {s conversation limit t : Term} {j r : List Term}
    (h : obligationCard s conversation limit j = .ok (t, r)) : LedgerFrame s t := by
  unfold obligationCard at h
  ledger_frame_walk h


theorem obligationCard_ledger_frame_step {s conversation limit t : Term} {j r : List Term} :
    obligationCard s conversation limit j = .ok (t, r) ↔ Except.ok (t, r) = obligationCard s conversation limit j ∧ LedgerFrame s t :=
  step_iff obligationCard_ledger_frame


theorem replyRepair_ledger_frame {s e t : Term} {j r : List Term} (h : replyRepair s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold replyRepair at h
  ledger_frame_walk h


theorem replyRepair_ledger_frame_step {s e t : Term} {j r : List Term} :
    replyRepair s e j = .ok (t, r) ↔ Except.ok (t, r) = replyRepair s e j ∧ LedgerFrame s t :=
  step_iff replyRepair_ledger_frame


theorem replyIntent_ledger_frame {s e t : Term} {j r : List Term} (h : replyIntent s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold replyIntent at h
  ledger_frame_walk h


theorem replyIntent_ledger_frame_step {s e t : Term} {j r : List Term} :
    replyIntent s e j = .ok (t, r) ↔ Except.ok (t, r) = replyIntent s e j ∧ LedgerFrame s t :=
  step_iff replyIntent_ledger_frame


theorem retireIntent_ledger_frame {s e t : Term} {j r : List Term} (h : retireIntent s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold retireIntent at h
  ledger_frame_walk h


theorem retireIntent_ledger_frame_step {s e t : Term} {j r : List Term} :
    retireIntent s e j = .ok (t, r) ↔ Except.ok (t, r) = retireIntent s e j ∧ LedgerFrame s t :=
  step_iff retireIntent_ledger_frame


theorem activationStarted_ledger_frame {s raw t : Term} {j r : List Term}
    (h : activationStarted s raw j = .ok (t, r)) : LedgerFrame s t := by
  unfold activationStarted at h
  ledger_frame_walk h


theorem activationStarted_ledger_frame_step {s raw t : Term} {j r : List Term} :
    activationStarted s raw j = .ok (t, r) ↔ Except.ok (t, r) = activationStarted s raw j ∧ LedgerFrame s t :=
  step_iff activationStarted_ledger_frame


theorem activationFinished_ledger_frame {s identity t : Term} {j r : List Term}
    (h : activationFinished s identity j = .ok (t, r)) : LedgerFrame s t := by
  unfold activationFinished at h
  ledger_frame_walk h


theorem activationFinished_ledger_frame_step {s identity t : Term} {j r : List Term} :
    activationFinished s identity j = .ok (t, r) ↔ Except.ok (t, r) = activationFinished s identity j ∧ LedgerFrame s t :=
  step_iff activationFinished_ledger_frame


theorem sessionAck_ledger_frame {s e t : Term} {j r : List Term} (h : sessionAck s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold sessionAck at h
  ledger_frame_walk h


theorem sessionAck_ledger_frame_step {s e t : Term} {j r : List Term} :
    sessionAck s e j = .ok (t, r) ↔ Except.ok (t, r) = sessionAck s e j ∧ LedgerFrame s t :=
  step_iff sessionAck_ledger_frame


theorem pruneResultRefs_ledger_frame {s t : Term} {j r : List Term} (h : pruneResultRefs s j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold pruneResultRefs at h
  ledger_frame_walk h


theorem pruneResultRefs_ledger_frame_step {s t : Term} {j r : List Term} :
    pruneResultRefs s j = .ok (t, r) ↔ Except.ok (t, r) = pruneResultRefs s j ∧ LedgerFrame s t :=
  step_iff pruneResultRefs_ledger_frame


theorem waitClear_ledger_frame {s e t : Term} {j r : List Term} (h : waitClear s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold waitClear at h
  ledger_frame_walk h


theorem waitClear_ledger_frame_step {s e t : Term} {j r : List Term} :
    waitClear s e j = .ok (t, r) ↔ Except.ok (t, r) = waitClear s e j ∧ LedgerFrame s t :=
  step_iff waitClear_ledger_frame


theorem statusTransition_ledger_frame {s e t : Term} {j r : List Term} (h : statusTransition s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold statusTransition at h
  ledger_frame_walk h


theorem statusTransition_ledger_frame_step {s e t : Term} {j r : List Term} :
    statusTransition s e j = .ok (t, r) ↔ Except.ok (t, r) = statusTransition s e j ∧ LedgerFrame s t :=
  step_iff statusTransition_ledger_frame


theorem activityTransition_ledger_frame {s e t : Term} {j r : List Term}
    (h : activityTransition s e j = .ok (t, r)) : LedgerFrame s t := by
  unfold activityTransition at h
  ledger_frame_walk h


theorem activityTransition_ledger_frame_step {s e t : Term} {j r : List Term} :
    activityTransition s e j = .ok (t, r) ↔ Except.ok (t, r) = activityTransition s e j ∧ LedgerFrame s t :=
  step_iff activityTransition_ledger_frame


theorem metadataCreated_ledger_frame {s e t : Term} {j r : List Term} (h : metadataCreated s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold metadataCreated at h
  ledger_frame_walk h


theorem metadataCreated_ledger_frame_step {s e t : Term} {j r : List Term} :
    metadataCreated s e j = .ok (t, r) ↔ Except.ok (t, r) = metadataCreated s e j ∧ LedgerFrame s t :=
  step_iff metadataCreated_ledger_frame


theorem metadataPrompt_ledger_frame {s e t : Term} {j r : List Term} (h : metadataPrompt s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold metadataPrompt at h
  ledger_frame_walk h


theorem metadataPrompt_ledger_frame_step {s e t : Term} {j r : List Term} :
    metadataPrompt s e j = .ok (t, r) ↔ Except.ok (t, r) = metadataPrompt s e j ∧ LedgerFrame s t :=
  step_iff metadataPrompt_ledger_frame


theorem metadataUpdate_ledger_frame {s e t : Term} {j r : List Term} (h : metadataUpdate s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold metadataUpdate at h
  ledger_frame_walk h


theorem metadataUpdate_ledger_frame_step {s e t : Term} {j r : List Term} :
    metadataUpdate s e j = .ok (t, r) ↔ Except.ok (t, r) = metadataUpdate s e j ∧ LedgerFrame s t :=
  step_iff metadataUpdate_ledger_frame


theorem stampWorkReasons_ledger_frame {s e t : Term} {j r : List Term} (h : stampWorkReasons s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold stampWorkReasons at h
  ledger_frame_walk h


theorem stampWorkReasons_ledger_frame_step {s e t : Term} {j r : List Term} :
    stampWorkReasons s e j = .ok (t, r) ↔ Except.ok (t, r) = stampWorkReasons s e j ∧ LedgerFrame s t :=
  step_iff stampWorkReasons_ledger_frame


theorem stampAgentId_ledger_frame {s e t : Term} {j r : List Term} (h : stampAgentId s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold stampAgentId at h
  simp only [ite_ok_iff] at h
  ledger_frame_walk h


theorem stampAgentId_ledger_frame_step {s e t : Term} {j r : List Term} :
    stampAgentId s e j = .ok (t, r) ↔ Except.ok (t, r) = stampAgentId s e j ∧ LedgerFrame s t :=
  step_iff stampAgentId_ledger_frame


theorem stampRuntimeEpoch_ledger_frame {s e t : Term} {j r : List Term} (h : stampRuntimeEpoch s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold stampRuntimeEpoch at h
  simp only [ite_ok_iff] at h
  ledger_frame_walk h


theorem stampRuntimeEpoch_ledger_frame_step {s e t : Term} {j r : List Term} :
    stampRuntimeEpoch s e j = .ok (t, r) ↔ Except.ok (t, r) = stampRuntimeEpoch s e j ∧ LedgerFrame s t :=
  step_iff stampRuntimeEpoch_ledger_frame


theorem stampRuntimeNode_ledger_frame {s e t : Term} {j r : List Term} (h : stampRuntimeNode s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold stampRuntimeNode at h
  simp only [ite_ok_iff] at h
  ledger_frame_walk h


theorem stampRuntimeNode_ledger_frame_step {s e t : Term} {j r : List Term} :
    stampRuntimeNode s e j = .ok (t, r) ↔ Except.ok (t, r) = stampRuntimeNode s e j ∧ LedgerFrame s t :=
  step_iff stampRuntimeNode_ledger_frame


theorem stampActivityRevision_ledger_frame {s e t : Term} {j r : List Term} (h : stampActivityRevision s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold stampActivityRevision at h
  simp only [ite_ok_iff] at h
  ledger_frame_walk h


theorem stampActivityRevision_ledger_frame_step {s e t : Term} {j r : List Term} :
    stampActivityRevision s e j = .ok (t, r) ↔ Except.ok (t, r) = stampActivityRevision s e j ∧ LedgerFrame s t :=
  step_iff stampActivityRevision_ledger_frame


theorem stampStorageRevision_ledger_frame {s e t : Term} {j r : List Term} (h : stampStorageRevision s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold stampStorageRevision at h
  simp only [ite_ok_iff] at h
  ledger_frame_walk h


theorem stampStorageRevision_ledger_frame_step {s e t : Term} {j r : List Term} :
    stampStorageRevision s e j = .ok (t, r) ↔ Except.ok (t, r) = stampStorageRevision s e j ∧ LedgerFrame s t :=
  step_iff stampStorageRevision_ledger_frame


theorem stampFlushId_ledger_frame {s e t : Term} {j r : List Term} (h : stampFlushId s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold stampFlushId at h
  simp only [ite_ok_iff] at h
  ledger_frame_walk h


theorem stampFlushId_ledger_frame_step {s e t : Term} {j r : List Term} :
    stampFlushId s e j = .ok (t, r) ↔ Except.ok (t, r) = stampFlushId s e j ∧ LedgerFrame s t :=
  step_iff stampFlushId_ledger_frame


theorem stampWorkIndexToken_ledger_frame {s e t : Term} {j r : List Term} (h : stampWorkIndexToken s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold stampWorkIndexToken at h
  simp only [ite_ok_iff] at h
  ledger_frame_walk h


theorem stampWorkIndexToken_ledger_frame_step {s e t : Term} {j r : List Term} :
    stampWorkIndexToken s e j = .ok (t, r) ↔ Except.ok (t, r) = stampWorkIndexToken s e j ∧ LedgerFrame s t :=
  step_iff stampWorkIndexToken_ledger_frame


theorem sessionStamp_ledger_frame {s e t : Term} {j r : List Term} (h : sessionStamp s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold sessionStamp at h
  ledger_frame_walk h


theorem sessionStamp_ledger_frame_step {s e t : Term} {j r : List Term} :
    sessionStamp s e j = .ok (t, r) ↔ Except.ok (t, r) = sessionStamp s e j ∧ LedgerFrame s t :=
  step_iff sessionStamp_ledger_frame


theorem bumpHwmEvent_ledger_frame {s e t : Term} {j r : List Term} (h : bumpHwmEvent s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold bumpHwmEvent at h
  ledger_frame_walk h


theorem bumpHwmEvent_ledger_frame_step {s e t : Term} {j r : List Term} :
    bumpHwmEvent s e j = .ok (t, r) ↔ Except.ok (t, r) = bumpHwmEvent s e j ∧ LedgerFrame s t :=
  step_iff bumpHwmEvent_ledger_frame


theorem compactionFailure_ledger_frame {s e t : Term} {j r : List Term}
    (h : compactionFailure s e j = .ok (t, r)) : LedgerFrame s t := by
  unfold compactionFailure at h
  ledger_frame_walk h


theorem compactionFailure_ledger_frame_step {s e t : Term} {j r : List Term} :
    compactionFailure s e j = .ok (t, r) ↔ Except.ok (t, r) = compactionFailure s e j ∧ LedgerFrame s t :=
  step_iff compactionFailure_ledger_frame


theorem compactionRecovery_ledger_frame {s e t : Term} {j r : List Term}
    (h : compactionRecovery s e j = .ok (t, r)) : LedgerFrame s t := by
  unfold compactionRecovery at h
  ledger_frame_walk h


theorem compactionRecovery_ledger_frame_step {s e t : Term} {j r : List Term} :
    compactionRecovery s e j = .ok (t, r) ↔ Except.ok (t, r) = compactionRecovery s e j ∧ LedgerFrame s t :=
  step_iff compactionRecovery_ledger_frame


theorem progressStep_ledger_frame {s e t : Term} {j r : List Term} (h : progressStep s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold progressStep at h
  ledger_frame_walk h


theorem progressStep_ledger_frame_step {s e t : Term} {j r : List Term} :
    progressStep s e j = .ok (t, r) ↔ Except.ok (t, r) = progressStep s e j ∧ LedgerFrame s t :=
  step_iff progressStep_ledger_frame


theorem pruneCompactResults_ledger_frame {s t : Term} {j r : List Term}
    (h : pruneCompactResults s j = .ok (t, r)) : LedgerFrame s t := by
  unfold pruneCompactResults at h
  ledger_frame_walk h


theorem pruneCompactResults_ledger_frame_step {s t : Term} {j r : List Term} :
    pruneCompactResults s j = .ok (t, r) ↔ Except.ok (t, r) = pruneCompactResults s j ∧ LedgerFrame s t :=
  step_iff pruneCompactResults_ledger_frame


theorem recomputeContext_ledger_frame {s t : Term} {j r : List Term} (h : recomputeContext s j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold recomputeContext at h
  ledger_frame_walk h


theorem recomputeContext_ledger_frame_step {s t : Term} {j r : List Term} :
    recomputeContext s j = .ok (t, r) ↔ Except.ok (t, r) = recomputeContext s j ∧ LedgerFrame s t :=
  step_iff recomputeContext_ledger_frame

/-- Compaction moves watermarks and summaries; it never rewrites the message list. -/

theorem historyCompaction_ledger_frame {s e t : Term} {provider : Bool} {j r : List Term}
    (h : historyCompaction s e provider j = .ok (t, r)) : LedgerFrame s t := by
  unfold historyCompaction at h
  ledger_frame_walk h


theorem historyCompaction_ledger_frame_step {s e t : Term} {provider : Bool} {j r : List Term} :
    historyCompaction s e provider j = .ok (t, r) ↔ Except.ok (t, r) = historyCompaction s e provider j ∧ LedgerFrame s t :=
  step_iff historyCompaction_ledger_frame


theorem compactResult_ledger_frame {s e t : Term} {j r : List Term} (h : compactResult s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold compactResult at h
  ledger_frame_walk h


theorem compactResult_ledger_frame_step {s e t : Term} {j r : List Term} :
    compactResult s e j = .ok (t, r) ↔ Except.ok (t, r) = compactResult s e j ∧ LedgerFrame s t :=
  step_iff compactResult_ledger_frame


theorem storedResult_ledger_frame {s e t : Term} {j r : List Term} (h : storedResult s e j = .ok (t, r)) :
    LedgerFrame s t := by
  unfold storedResult at h
  ledger_frame_walk h


theorem storedResult_ledger_frame_step {s e t : Term} {j r : List Term} :
    storedResult s e j = .ok (t, r) ↔ Except.ok (t, r) = storedResult s e j ∧ LedgerFrame s t :=
  step_iff storedResult_ledger_frame


theorem transcriptToolResult_ledger_frame {s e t : Term} {j r : List Term}
    (h : transcriptToolResult s e j = .ok (t, r)) : LedgerFrame s t := by
  unfold transcriptToolResult at h
  ledger_frame_walk h


theorem transcriptToolResult_ledger_frame_step {s e t : Term} {j r : List Term} :
    transcriptToolResult s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptToolResult s e j ∧ LedgerFrame s t :=
  step_iff transcriptToolResult_ledger_frame


theorem transcriptAssistant_ledger_frame {s e t : Term} {j r : List Term}
    (h : transcriptAssistant s e j = .ok (t, r)) : LedgerFrame s t := by
  unfold transcriptAssistant at h
  ledger_frame_walk h


theorem transcriptAssistant_ledger_frame_step {s e t : Term} {j r : List Term} :
    transcriptAssistant s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptAssistant s e j ∧ LedgerFrame s t :=
  step_iff transcriptAssistant_ledger_frame


theorem afterEvent_ledger_frame {previous next e t : Term} {j r : List Term}
    (h : afterEvent previous next e j = .ok (t, r)) : LedgerFrame next t := by
  unfold afterEvent at h
  ledger_frame_walk h


theorem afterEvent_ledger_frame_step {previous next e t : Term} {j r : List Term} :
    afterEvent previous next e j = .ok (t, r) ↔ Except.ok (t, r) = afterEvent previous next e j ∧ LedgerFrame next t :=
  step_iff afterEvent_ledger_frame


theorem sessionEvent_ledger_frame {s e t : Term} {j r : List Term}
    (h : sessionEvent s e j = .ok (t, r)) : LedgerFrame s t :=
  (sessionEvent_fields h).2 "input_dedupe" rfl

theorem sessionEvent_ledger_frame_step {s e t : Term} {j r : List Term} :
    sessionEvent s e j = .ok (t, r) ↔ Except.ok (t, r) = sessionEvent s e j ∧ LedgerFrame s t :=
  step_iff sessionEvent_ledger_frame

end VerifiedKernel.Session.WorkConservation
