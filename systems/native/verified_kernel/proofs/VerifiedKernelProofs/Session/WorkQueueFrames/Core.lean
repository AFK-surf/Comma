import VerifiedKernelProofs.Session.WorkAllocation
import VerifiedKernelProofs.Proof.NativeProducerTactic

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 4000000
set_option Elab.async false

def QueueFrame (s t : Term) : Prop :=
  t.get (a "input_queue") = s.get (a "input_queue") ∧
  t.get (a "next_queue_id") = s.get (a "next_queue_id") ∧
  t.get (a "queue_ack_id") = s.get (a "queue_ack_id") ∧
  t.get (a "session_id") = s.get (a "session_id") ∧
  t.get (a "storage_format") = s.get (a "storage_format")

theorem queue_frame_refl (s : Term) : QueueFrame s s := ⟨rfl, rfl, rfl, rfl, rfl⟩

theorem queue_frame_trans {s t u : Term} (left : QueueFrame s t) (right : QueueFrame t u) :
    QueueFrame s u := ⟨right.1.trans left.1, right.2.1.trans left.2.1,
      right.2.2.1.trans left.2.2.1, right.2.2.2.1.trans left.2.2.2.1,
      right.2.2.2.2.trans left.2.2.2.2⟩

theorem write_queue_frame {s t : Term} {entries : List (String × Term)} {j r : List Term}
    (h : write s entries j = .ok (t, r))
    (queue : entries.all (fun entry => entry.1 != "input_queue") = true)
    (next : entries.all (fun entry => entry.1 != "next_queue_id") = true)
    (ack : entries.all (fun entry => entry.1 != "queue_ack_id") = true)
    (session : entries.all (fun entry => entry.1 != "session_id") = true)
    (format : entries.all (fun entry => entry.1 != "storage_format") = true) : QueueFrame s t :=
  ⟨write_field_frame h queue, write_field_frame h next, write_field_frame h ack,
    write_field_frame h session, write_field_frame h format⟩

theorem write_queue_frame_step {s t : Term} {entries : List (String × Term)} {j r : List Term} :
    write s entries j = .ok (t, r) ↔ Except.ok (t, r) = write s entries j ∧
      (entries.all (fun entry => entry.1 != "input_queue") = true →
       entries.all (fun entry => entry.1 != "next_queue_id") = true →
       entries.all (fun entry => entry.1 != "queue_ack_id") = true →
       entries.all (fun entry => entry.1 != "session_id") = true →
       entries.all (fun entry => entry.1 != "storage_format") = true → QueueFrame s t) :=
  step_iff write_queue_frame

syntax "queue_frame_step" ident : tactic
macro_rules
  | `(tactic| queue_frame_step $h:ident) => do
    -- Select the execution summary before inspecting its arguments.
    let steps ← (transcriptSteps ++ [`mergePredicate, `microcompactIds, `microcompact, `archiveAdvance]).mapM (fun name => do
      let lemma := Lean.mkIdent (name.appendAfter "_queue_frame")
      let head := Lean.Syntax.mkStrLit ("VerifiedKernel.Session." ++ name.toString)
      `(tactic| (execution_head_is $h $head:str
                 refine queue_frame_trans ($lemma:ident $h) ?_)))
    let writes ← `(tactic| (execution_head_is $h "VerifiedKernel.Data.write"
                            refine queue_frame_trans (write_queue_frame $h rfl rfl rfl rfl rfl) ?_))
    let alternatives := (writes :: steps).toArray
    `(tactic| first $[| $alternatives:tactic]*)

syntax "queue_frame_walk" ident : tactic
macro_rules
  | `(tactic| queue_frame_walk $h:ident) => do
  let hx := Lean.mkIdent `hx
  let hl := Lean.mkIdent `hl
  let rfl := Lean.mkIdent `rfl
  `(tactic| repeat' first
      | (head_is $h [Pure.pure]; simp only [pure_ok_iff] at $h:ident; cases $h:ident; exact queue_frame_refl _)
      | (head_is $h [argumentError, inspectedError, VerifiedKernel.fail]
         simp only [argumentError, inspectedError, fail_ok_iff] at $h:ident)
      | (queue_frame_step $h; exact queue_frame_refl _)
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
           | queue_frame_step $hx
           | (split at $hx:ident <;> first
               | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
               | queue_frame_step $hx
               | ((repeat (fail_if_success queue_frame_step $hx; obtain ⟨_, _, _, $hx:ident⟩ := bind_ok $hx))
                  queue_frame_step $hx)
               | skip)
           | skip)
      | dsimp only at $h:ident)

theorem appendFields_queue_frame {s e m t : Term} {j r : List Term} (h : appendFields s e m j = .ok (t, r)) :
    QueueFrame s t := by
  unfold appendFields at h
  queue_frame_walk h


theorem appendFields_queue_frame_step {s e m t : Term} {j r : List Term} :
    appendFields s e m j = .ok (t, r) ↔ Except.ok (t, r) = appendFields s e m j ∧ QueueFrame s t :=
  step_iff appendFields_queue_frame


theorem bumpHwm_queue_frame {s hwm t : Term} {j r : List Term} (h : bumpHwm s hwm j = .ok (t, r)) :
    QueueFrame s t := by
  unfold bumpHwm at h
  queue_frame_walk h


theorem bumpHwm_queue_frame_step {s hwm t : Term} {j r : List Term} :
    bumpHwm s hwm j = .ok (t, r) ↔ Except.ok (t, r) = bumpHwm s hwm j ∧ QueueFrame s t :=
  step_iff bumpHwm_queue_frame


theorem appendMessage_queue_frame {s e m t : Term} {j r : List Term} (h : appendMessage s e m j = .ok (t, r)) :
    QueueFrame s t := by
  unfold appendMessage at h
  queue_frame_walk h


theorem appendMessage_queue_frame_step {s e m t : Term} {j r : List Term} :
    appendMessage s e m j = .ok (t, r) ↔ Except.ok (t, r) = appendMessage s e m j ∧ QueueFrame s t :=
  step_iff appendMessage_queue_frame


theorem noteResult_queue_frame {s tool input status errorClass message content t : Term} {j r : List Term}
    (h : noteResult s tool input status errorClass message content j = .ok (t, r)) :
    QueueFrame s t := by
  unfold noteResult at h
  queue_frame_walk h


theorem noteResult_queue_frame_step {s tool input status errorClass message content t : Term} {j r : List Term} :
    noteResult s tool input status errorClass message content j = .ok (t, r) ↔ Except.ok (t, r) = noteResult s tool input status errorClass message content j ∧ QueueFrame s t :=
  step_iff noteResult_queue_frame


theorem noteAsyncResult_queue_frame {s existing e status t : Term} {j r : List Term}
    (h : noteAsyncResult s existing e status j = .ok (t, r)) : QueueFrame s t := by
  unfold noteAsyncResult at h
  queue_frame_walk h


theorem noteAsyncResult_queue_frame_step {s existing e status t : Term} {j r : List Term} :
    noteAsyncResult s existing e status j = .ok (t, r) ↔ Except.ok (t, r) = noteAsyncResult s existing e status j ∧ QueueFrame s t :=
  step_iff noteAsyncResult_queue_frame


theorem asyncStart_queue_frame {s e t : Term} {j r : List Term} (h : asyncStart s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold asyncStart at h
  queue_frame_walk h


theorem asyncStart_queue_frame_step {s e t : Term} {j r : List Term} :
    asyncStart s e j = .ok (t, r) ↔ Except.ok (t, r) = asyncStart s e j ∧ QueueFrame s t :=
  step_iff asyncStart_queue_frame


theorem asyncTerminal_queue_frame {s e status t : Term} {j r : List Term}
    (h : asyncTerminal s e status j = .ok (t, r)) : QueueFrame s t := by
  unfold asyncTerminal at h
  queue_frame_walk h


theorem asyncTerminal_queue_frame_step {s e status t : Term} {j r : List Term} :
    asyncTerminal s e status j = .ok (t, r) ↔ Except.ok (t, r) = asyncTerminal s e status j ∧ QueueFrame s t :=
  step_iff asyncTerminal_queue_frame


theorem resetFresh_queue_frame {s m t : Term} {j r : List Term} (h : resetFresh s m j = .ok (t, r)) :
    QueueFrame s t := by
  unfold resetFresh at h
  queue_frame_walk h


theorem resetFresh_queue_frame_step {s m t : Term} {j r : List Term} :
    resetFresh s m j = .ok (t, r) ↔ Except.ok (t, r) = resetFresh s m j ∧ QueueFrame s t :=
  step_iff resetFresh_queue_frame


theorem addObligation_queue_frame {s raw t : Term} {j r : List Term} (h : addObligation s raw j = .ok (t, r)) :
    QueueFrame s t := by
  unfold addObligation at h
  queue_frame_walk h


theorem addObligation_queue_frame_step {s raw t : Term} {j r : List Term} :
    addObligation s raw j = .ok (t, r) ↔ Except.ok (t, r) = addObligation s raw j ∧ QueueFrame s t :=
  step_iff addObligation_queue_frame


theorem obligationResolve_queue_frame {s key t : Term} {j r : List Term}
    (h : obligationResolve s key j = .ok (t, r)) : QueueFrame s t := by
  unfold obligationResolve at h
  queue_frame_walk h


theorem obligationResolve_queue_frame_step {s key t : Term} {j r : List Term} :
    obligationResolve s key j = .ok (t, r) ↔ Except.ok (t, r) = obligationResolve s key j ∧ QueueFrame s t :=
  step_iff obligationResolve_queue_frame


theorem obligationCard_queue_frame {s conversation limit t : Term} {j r : List Term}
    (h : obligationCard s conversation limit j = .ok (t, r)) : QueueFrame s t := by
  unfold obligationCard at h
  queue_frame_walk h


theorem obligationCard_queue_frame_step {s conversation limit t : Term} {j r : List Term} :
    obligationCard s conversation limit j = .ok (t, r) ↔ Except.ok (t, r) = obligationCard s conversation limit j ∧ QueueFrame s t :=
  step_iff obligationCard_queue_frame


theorem replyRepair_queue_frame {s e t : Term} {j r : List Term} (h : replyRepair s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold replyRepair at h
  queue_frame_walk h


theorem replyRepair_queue_frame_step {s e t : Term} {j r : List Term} :
    replyRepair s e j = .ok (t, r) ↔ Except.ok (t, r) = replyRepair s e j ∧ QueueFrame s t :=
  step_iff replyRepair_queue_frame


theorem replyIntent_queue_frame {s e t : Term} {j r : List Term} (h : replyIntent s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold replyIntent at h
  queue_frame_walk h


theorem replyIntent_queue_frame_step {s e t : Term} {j r : List Term} :
    replyIntent s e j = .ok (t, r) ↔ Except.ok (t, r) = replyIntent s e j ∧ QueueFrame s t :=
  step_iff replyIntent_queue_frame


theorem retireIntent_queue_frame {s e t : Term} {j r : List Term} (h : retireIntent s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold retireIntent at h
  queue_frame_walk h


theorem retireIntent_queue_frame_step {s e t : Term} {j r : List Term} :
    retireIntent s e j = .ok (t, r) ↔ Except.ok (t, r) = retireIntent s e j ∧ QueueFrame s t :=
  step_iff retireIntent_queue_frame


theorem activationStarted_queue_frame {s raw t : Term} {j r : List Term}
    (h : activationStarted s raw j = .ok (t, r)) : QueueFrame s t := by
  unfold activationStarted at h
  queue_frame_walk h


theorem activationStarted_queue_frame_step {s raw t : Term} {j r : List Term} :
    activationStarted s raw j = .ok (t, r) ↔ Except.ok (t, r) = activationStarted s raw j ∧ QueueFrame s t :=
  step_iff activationStarted_queue_frame


theorem activationFinished_queue_frame {s identity t : Term} {j r : List Term}
    (h : activationFinished s identity j = .ok (t, r)) : QueueFrame s t := by
  unfold activationFinished at h
  queue_frame_walk h


theorem activationFinished_queue_frame_step {s identity t : Term} {j r : List Term} :
    activationFinished s identity j = .ok (t, r) ↔ Except.ok (t, r) = activationFinished s identity j ∧ QueueFrame s t :=
  step_iff activationFinished_queue_frame


theorem sessionAck_queue_frame {s e t : Term} {j r : List Term} (h : sessionAck s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold sessionAck at h
  queue_frame_walk h


theorem sessionAck_queue_frame_step {s e t : Term} {j r : List Term} :
    sessionAck s e j = .ok (t, r) ↔ Except.ok (t, r) = sessionAck s e j ∧ QueueFrame s t :=
  step_iff sessionAck_queue_frame


theorem pruneResultRefs_queue_frame {s t : Term} {j r : List Term} (h : pruneResultRefs s j = .ok (t, r)) :
    QueueFrame s t := by
  unfold pruneResultRefs at h
  queue_frame_walk h


theorem pruneResultRefs_queue_frame_step {s t : Term} {j r : List Term} :
    pruneResultRefs s j = .ok (t, r) ↔ Except.ok (t, r) = pruneResultRefs s j ∧ QueueFrame s t :=
  step_iff pruneResultRefs_queue_frame


theorem waitClear_queue_frame {s e t : Term} {j r : List Term} (h : waitClear s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold waitClear at h
  queue_frame_walk h


theorem waitClear_queue_frame_step {s e t : Term} {j r : List Term} :
    waitClear s e j = .ok (t, r) ↔ Except.ok (t, r) = waitClear s e j ∧ QueueFrame s t :=
  step_iff waitClear_queue_frame


theorem statusTransition_queue_frame {s e t : Term} {j r : List Term} (h : statusTransition s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold statusTransition at h
  queue_frame_walk h


theorem statusTransition_queue_frame_step {s e t : Term} {j r : List Term} :
    statusTransition s e j = .ok (t, r) ↔ Except.ok (t, r) = statusTransition s e j ∧ QueueFrame s t :=
  step_iff statusTransition_queue_frame


theorem activityTransition_queue_frame {s e t : Term} {j r : List Term}
    (h : activityTransition s e j = .ok (t, r)) : QueueFrame s t := by
  unfold activityTransition at h
  queue_frame_walk h


theorem activityTransition_queue_frame_step {s e t : Term} {j r : List Term} :
    activityTransition s e j = .ok (t, r) ↔ Except.ok (t, r) = activityTransition s e j ∧ QueueFrame s t :=
  step_iff activityTransition_queue_frame


theorem metadataCreated_queue_frame {s e t : Term} {j r : List Term} (h : metadataCreated s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold metadataCreated at h
  queue_frame_walk h


theorem metadataCreated_queue_frame_step {s e t : Term} {j r : List Term} :
    metadataCreated s e j = .ok (t, r) ↔ Except.ok (t, r) = metadataCreated s e j ∧ QueueFrame s t :=
  step_iff metadataCreated_queue_frame


theorem metadataPrompt_queue_frame {s e t : Term} {j r : List Term} (h : metadataPrompt s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold metadataPrompt at h
  queue_frame_walk h


theorem metadataPrompt_queue_frame_step {s e t : Term} {j r : List Term} :
    metadataPrompt s e j = .ok (t, r) ↔ Except.ok (t, r) = metadataPrompt s e j ∧ QueueFrame s t :=
  step_iff metadataPrompt_queue_frame


theorem metadataUpdate_queue_frame {s e t : Term} {j r : List Term} (h : metadataUpdate s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold metadataUpdate at h
  queue_frame_walk h


theorem metadataUpdate_queue_frame_step {s e t : Term} {j r : List Term} :
    metadataUpdate s e j = .ok (t, r) ↔ Except.ok (t, r) = metadataUpdate s e j ∧ QueueFrame s t :=
  step_iff metadataUpdate_queue_frame


theorem stampWorkReasons_queue_frame {s e t : Term} {j r : List Term} (h : stampWorkReasons s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold stampWorkReasons at h
  queue_frame_walk h


theorem stampWorkReasons_queue_frame_step {s e t : Term} {j r : List Term} :
    stampWorkReasons s e j = .ok (t, r) ↔ Except.ok (t, r) = stampWorkReasons s e j ∧ QueueFrame s t :=
  step_iff stampWorkReasons_queue_frame


theorem stampAgentId_queue_frame {s e t : Term} {j r : List Term} (h : stampAgentId s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold stampAgentId at h
  simp only [ite_ok_iff] at h
  queue_frame_walk h


theorem stampAgentId_queue_frame_step {s e t : Term} {j r : List Term} :
    stampAgentId s e j = .ok (t, r) ↔ Except.ok (t, r) = stampAgentId s e j ∧ QueueFrame s t :=
  step_iff stampAgentId_queue_frame


theorem stampRuntimeEpoch_queue_frame {s e t : Term} {j r : List Term} (h : stampRuntimeEpoch s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold stampRuntimeEpoch at h
  simp only [ite_ok_iff] at h
  queue_frame_walk h


theorem stampRuntimeEpoch_queue_frame_step {s e t : Term} {j r : List Term} :
    stampRuntimeEpoch s e j = .ok (t, r) ↔ Except.ok (t, r) = stampRuntimeEpoch s e j ∧ QueueFrame s t :=
  step_iff stampRuntimeEpoch_queue_frame


theorem stampRuntimeNode_queue_frame {s e t : Term} {j r : List Term} (h : stampRuntimeNode s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold stampRuntimeNode at h
  simp only [ite_ok_iff] at h
  queue_frame_walk h


theorem stampRuntimeNode_queue_frame_step {s e t : Term} {j r : List Term} :
    stampRuntimeNode s e j = .ok (t, r) ↔ Except.ok (t, r) = stampRuntimeNode s e j ∧ QueueFrame s t :=
  step_iff stampRuntimeNode_queue_frame


theorem stampActivityRevision_queue_frame {s e t : Term} {j r : List Term} (h : stampActivityRevision s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold stampActivityRevision at h
  simp only [ite_ok_iff] at h
  queue_frame_walk h


theorem stampActivityRevision_queue_frame_step {s e t : Term} {j r : List Term} :
    stampActivityRevision s e j = .ok (t, r) ↔ Except.ok (t, r) = stampActivityRevision s e j ∧ QueueFrame s t :=
  step_iff stampActivityRevision_queue_frame


theorem stampStorageRevision_queue_frame {s e t : Term} {j r : List Term} (h : stampStorageRevision s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold stampStorageRevision at h
  simp only [ite_ok_iff] at h
  queue_frame_walk h


theorem stampStorageRevision_queue_frame_step {s e t : Term} {j r : List Term} :
    stampStorageRevision s e j = .ok (t, r) ↔ Except.ok (t, r) = stampStorageRevision s e j ∧ QueueFrame s t :=
  step_iff stampStorageRevision_queue_frame


theorem stampFlushId_queue_frame {s e t : Term} {j r : List Term} (h : stampFlushId s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold stampFlushId at h
  simp only [ite_ok_iff] at h
  queue_frame_walk h


theorem stampFlushId_queue_frame_step {s e t : Term} {j r : List Term} :
    stampFlushId s e j = .ok (t, r) ↔ Except.ok (t, r) = stampFlushId s e j ∧ QueueFrame s t :=
  step_iff stampFlushId_queue_frame


theorem stampWorkIndexToken_queue_frame {s e t : Term} {j r : List Term} (h : stampWorkIndexToken s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold stampWorkIndexToken at h
  simp only [ite_ok_iff] at h
  queue_frame_walk h


theorem stampWorkIndexToken_queue_frame_step {s e t : Term} {j r : List Term} :
    stampWorkIndexToken s e j = .ok (t, r) ↔ Except.ok (t, r) = stampWorkIndexToken s e j ∧ QueueFrame s t :=
  step_iff stampWorkIndexToken_queue_frame


theorem sessionStamp_queue_frame {s e t : Term} {j r : List Term} (h : sessionStamp s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold sessionStamp at h
  queue_frame_walk h


theorem sessionStamp_queue_frame_step {s e t : Term} {j r : List Term} :
    sessionStamp s e j = .ok (t, r) ↔ Except.ok (t, r) = sessionStamp s e j ∧ QueueFrame s t :=
  step_iff sessionStamp_queue_frame


theorem bumpHwmEvent_queue_frame {s e t : Term} {j r : List Term} (h : bumpHwmEvent s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold bumpHwmEvent at h
  queue_frame_walk h


theorem bumpHwmEvent_queue_frame_step {s e t : Term} {j r : List Term} :
    bumpHwmEvent s e j = .ok (t, r) ↔ Except.ok (t, r) = bumpHwmEvent s e j ∧ QueueFrame s t :=
  step_iff bumpHwmEvent_queue_frame


theorem compactionFailure_queue_frame {s e t : Term} {j r : List Term}
    (h : compactionFailure s e j = .ok (t, r)) : QueueFrame s t := by
  unfold compactionFailure at h
  queue_frame_walk h


theorem compactionFailure_queue_frame_step {s e t : Term} {j r : List Term} :
    compactionFailure s e j = .ok (t, r) ↔ Except.ok (t, r) = compactionFailure s e j ∧ QueueFrame s t :=
  step_iff compactionFailure_queue_frame


theorem compactionRecovery_queue_frame {s e t : Term} {j r : List Term}
    (h : compactionRecovery s e j = .ok (t, r)) : QueueFrame s t := by
  unfold compactionRecovery at h
  queue_frame_walk h


theorem compactionRecovery_queue_frame_step {s e t : Term} {j r : List Term} :
    compactionRecovery s e j = .ok (t, r) ↔ Except.ok (t, r) = compactionRecovery s e j ∧ QueueFrame s t :=
  step_iff compactionRecovery_queue_frame


theorem progressStep_queue_frame {s e t : Term} {j r : List Term} (h : progressStep s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold progressStep at h
  queue_frame_walk h


theorem progressStep_queue_frame_step {s e t : Term} {j r : List Term} :
    progressStep s e j = .ok (t, r) ↔ Except.ok (t, r) = progressStep s e j ∧ QueueFrame s t :=
  step_iff progressStep_queue_frame


theorem pruneCompactResults_queue_frame {s t : Term} {j r : List Term}
    (h : pruneCompactResults s j = .ok (t, r)) : QueueFrame s t := by
  unfold pruneCompactResults at h
  queue_frame_walk h


theorem pruneCompactResults_queue_frame_step {s t : Term} {j r : List Term} :
    pruneCompactResults s j = .ok (t, r) ↔ Except.ok (t, r) = pruneCompactResults s j ∧ QueueFrame s t :=
  step_iff pruneCompactResults_queue_frame


theorem recomputeContext_queue_frame {s t : Term} {j r : List Term} (h : recomputeContext s j = .ok (t, r)) :
    QueueFrame s t := by
  unfold recomputeContext at h
  queue_frame_walk h


theorem recomputeContext_queue_frame_step {s t : Term} {j r : List Term} :
    recomputeContext s j = .ok (t, r) ↔ Except.ok (t, r) = recomputeContext s j ∧ QueueFrame s t :=
  step_iff recomputeContext_queue_frame

set_option backward.split false in
/-- Compaction preserves the queue and its ownership fields through each state update. -/
theorem historyCompaction_queue_frame {s e t : Term} {provider : Bool} {j r : List Term}
    (h : historyCompaction s e provider j = .ok (t, r)) : QueueFrame s t := by
  unfold historyCompaction at h
  repeat' first
    | (execution_head_is h "VerifiedKernel.Session.recomputeContext"
       exact recomputeContext_queue_frame h)
    | (execution_head_is h "Pure.pure"
       have same := pure_ok h
       subst t
       exact queue_frame_refl _)
    | (execution_head_is h "Bind.bind"
       have bound := bind_ok h
       clear h
       obtain ⟨value, _, prior, h⟩ := bound
       first
         | (execution_head_is prior "VerifiedKernel.Data.write"
            refine queue_frame_trans (write_queue_frame prior rfl rfl rfl rfl rfl) ?_)
         | (execution_head_is prior "VerifiedKernel.Session.pruneResultRefs"
            refine queue_frame_trans (pruneResultRefs_queue_frame prior) ?_)
         | (execution_head_is prior "VerifiedKernel.Session.pruneCompactResults"
            refine queue_frame_trans (pruneCompactResults_queue_frame prior) ?_)
         | (execution_head_is prior "Pure.pure"
            have same := pure_ok prior
            subst value)
         | skip)
    | dsimp only at h
    | split at h


theorem historyCompaction_queue_frame_step {s e t : Term} {provider : Bool} {j r : List Term} :
    historyCompaction s e provider j = .ok (t, r) ↔ Except.ok (t, r) = historyCompaction s e provider j ∧ QueueFrame s t :=
  step_iff historyCompaction_queue_frame


set_option backward.split false in
theorem compactResult_queue_frame {s e t : Term} {j r : List Term} (h : compactResult s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold compactResult at h
  repeat' first
    | (execution_head_is h "VerifiedKernel.Session.pruneCompactResults"
       exact pruneCompactResults_queue_frame h)
    | (execution_head_is h "Bind.bind"
       have bound := bind_ok h
       clear h
       obtain ⟨value, _, prior, h⟩ := bound
       first
         | (execution_head_is prior "VerifiedKernel.Data.write"
            refine queue_frame_trans (write_queue_frame prior rfl rfl rfl rfl rfl) ?_)
         | (execution_head_is prior "Pure.pure"
            have same := pure_ok prior
            subst value)
         | skip)
    | dsimp only at h
    | split at h


theorem compactResult_queue_frame_step {s e t : Term} {j r : List Term} :
    compactResult s e j = .ok (t, r) ↔ Except.ok (t, r) = compactResult s e j ∧ QueueFrame s t :=
  step_iff compactResult_queue_frame


theorem storedResult_queue_frame {s e t : Term} {j r : List Term} (h : storedResult s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold storedResult at h
  queue_frame_walk h


theorem storedResult_queue_frame_step {s e t : Term} {j r : List Term} :
    storedResult s e j = .ok (t, r) ↔ Except.ok (t, r) = storedResult s e j ∧ QueueFrame s t :=
  step_iff storedResult_queue_frame


theorem transcriptToolResult_queue_frame {s e t : Term} {j r : List Term}
    (h : transcriptToolResult s e j = .ok (t, r)) : QueueFrame s t := by
  unfold transcriptToolResult at h
  queue_frame_walk h


theorem transcriptToolResult_queue_frame_step {s e t : Term} {j r : List Term} :
    transcriptToolResult s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptToolResult s e j ∧ QueueFrame s t :=
  step_iff transcriptToolResult_queue_frame


theorem transcriptAssistant_queue_frame {s e t : Term} {j r : List Term}
    (h : transcriptAssistant s e j = .ok (t, r)) : QueueFrame s t := by
  unfold transcriptAssistant at h
  queue_frame_walk h


theorem transcriptAssistant_queue_frame_step {s e t : Term} {j r : List Term} :
    transcriptAssistant s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptAssistant s e j ∧ QueueFrame s t :=
  step_iff transcriptAssistant_queue_frame


theorem transcriptLog_queue_frame {s e t : Term} {j r : List Term} (h : transcriptLog s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold transcriptLog at h
  queue_frame_walk h


theorem transcriptLog_queue_frame_step {s e t : Term} {j r : List Term} :
    transcriptLog s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptLog s e j ∧ QueueFrame s t :=
  step_iff transcriptLog_queue_frame


theorem transcriptSeed_queue_frame {s e t : Term} {j r : List Term} (h : transcriptSeed s e j = .ok (t, r)) :
    QueueFrame s t := by
  unfold transcriptSeed at h
  queue_frame_walk h


theorem transcriptSeed_queue_frame_step {s e t : Term} {j r : List Term} :
    transcriptSeed s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptSeed s e j ∧ QueueFrame s t :=
  step_iff transcriptSeed_queue_frame


theorem afterEvent_queue_frame {previous next e t : Term} {j r : List Term}
    (h : afterEvent previous next e j = .ok (t, r)) : QueueFrame next t := by
  unfold afterEvent at h
  queue_frame_walk h


theorem afterEvent_queue_frame_step {previous next e t : Term} {j r : List Term} :
    afterEvent previous next e j = .ok (t, r) ↔ Except.ok (t, r) = afterEvent previous next e j ∧ QueueFrame next t :=
  step_iff afterEvent_queue_frame


/-- Compose the Session operations of `runtimeAppend` (`runtimeAppend_ops`). This is much
cheaper than a walk over every branch of `runtimeAppend`. -/
theorem runtimeAppend_queue_frame {s e t : Term} {j r : List Term} (h : runtimeAppend s e j = .ok (t, r)) :
    QueueFrame s t := by
  obtain ⟨_, _, _, _, _, _, _, _, _, _, _, _, _, _, appended, written, bumped, reset⟩ := runtimeAppend_ops h
  exact queue_frame_trans (appendFields_queue_frame appended) (queue_frame_trans (write_queue_frame written rfl rfl rfl rfl rfl)
    (queue_frame_trans (bumpHwm_queue_frame bumped) (resetFresh_queue_frame reset)))


theorem runtimeAppend_queue_frame_step {s e t : Term} {j r : List Term} :
    runtimeAppend s e j = .ok (t, r) ↔ Except.ok (t, r) = runtimeAppend s e j ∧ QueueFrame s t :=
  step_iff runtimeAppend_queue_frame


theorem transcriptRuntime_queue_frame {s e t : Term} {j r : List Term}
    (h : transcriptRuntime s e j = .ok (t, r)) : QueueFrame s t := by
  unfold transcriptRuntime at h
  queue_frame_walk h


theorem transcriptRuntime_queue_frame_step {s e t : Term} {j r : List Term} :
    transcriptRuntime s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptRuntime s e j ∧ QueueFrame s t :=
  step_iff transcriptRuntime_queue_frame


/-- Compose the Session operations of `transcriptDelivery` (`transcriptDelivery_ops`). This is
much cheaper than a walk over every branch of `transcriptDelivery`. -/
theorem transcriptDelivery_queue_frame {s e t : Term} {j r : List Term}
    (h : transcriptDelivery s e j = .ok (t, r)) : QueueFrame s t := by
  rcases transcriptDelivery_ops h with rfl | ⟨_, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, appended, written, obligated, bumped, reset⟩
  · exact queue_frame_refl _
  · exact queue_frame_trans (appendFields_queue_frame appended) (queue_frame_trans (write_queue_frame written rfl rfl rfl rfl rfl)
      (queue_frame_trans (addObligation_queue_frame obligated) (queue_frame_trans (bumpHwm_queue_frame bumped) (resetFresh_queue_frame reset))))


theorem transcriptDelivery_queue_frame_step {s e t : Term} {j r : List Term} :
    transcriptDelivery s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptDelivery s e j ∧ QueueFrame s t :=
  step_iff transcriptDelivery_queue_frame

end VerifiedKernel.Session.WorkConservation
