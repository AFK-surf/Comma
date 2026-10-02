import VerifiedKernelProofs.Session.WorkAllocation
import VerifiedKernelProofs.Proof.NativeProducerTactic

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 4000000
set_option Elab.async false

/-- The two history lists outside the transcript sequence invariant. -/
def AuxiliaryFrame (s t : Term) : Prop :=
  t.get (a "events") = s.get (a "events") ∧
  t.get (a "async_results") = s.get (a "async_results")

theorem auxiliary_frame_refl (s : Term) : AuxiliaryFrame s s := ⟨rfl, rfl⟩

theorem auxiliary_frame_trans {s t u : Term} (left : AuxiliaryFrame s t) (right : AuxiliaryFrame t u) :
    AuxiliaryFrame s u := ⟨right.1.trans left.1, right.2.trans left.2⟩

theorem write_auxiliary_frame {s t : Term} {entries : List (String × Term)} {j r : List Term}
    (h : write s entries j = .ok (t, r))
    (events : entries.all (fun entry => entry.1 != "events") = true)
    (results : entries.all (fun entry => entry.1 != "async_results") = true) : AuxiliaryFrame s t :=
  ⟨write_field_frame h events, write_field_frame h results⟩

theorem write_auxiliary_frame_step {s t : Term} {entries : List (String × Term)} {j r : List Term} :
    write s entries j = .ok (t, r) ↔ Except.ok (t, r) = write s entries j ∧
      (entries.all (fun entry => entry.1 != "events") = true →
       entries.all (fun entry => entry.1 != "async_results") = true → AuxiliaryFrame s t) :=
  step_iff write_auxiliary_frame

syntax "auxiliary_frame_step" ident : tactic
macro_rules
  | `(tactic| auxiliary_frame_step $h:ident) => do
    -- Select the execution summary before inspecting its arguments.
    let steps ← (transcriptSteps ++ [`mergePredicate, `microcompactIds, `microcompact, `archiveAdvance]).mapM (fun name => do
      let lemma := Lean.mkIdent (name.appendAfter "_auxiliary_frame")
      let head := Lean.Syntax.mkStrLit ("VerifiedKernel.Session." ++ name.toString)
      `(tactic| (execution_head_is $h $head:str
                 refine auxiliary_frame_trans ($lemma:ident $h) ?_)))
    let writes ← `(tactic| (execution_head_is $h "VerifiedKernel.Data.write"
                            refine auxiliary_frame_trans (write_auxiliary_frame $h rfl rfl) ?_))
    let alternatives := (writes :: steps).toArray
    `(tactic| first $[| $alternatives:tactic]*)

syntax "auxiliary_frame_walk" ident : tactic
macro_rules
  | `(tactic| auxiliary_frame_walk $h:ident) => do
  let hx := Lean.mkIdent `hx
  let hl := Lean.mkIdent `hl
  let rfl := Lean.mkIdent `rfl
  `(tactic| repeat' first
      | (head_is $h [Pure.pure]; simp only [pure_ok_iff] at $h:ident; cases $h:ident; exact auxiliary_frame_refl _)
      | (head_is $h [argumentError, inspectedError, VerifiedKernel.fail]
         simp only [argumentError, inspectedError, fail_ok_iff] at $h:ident)
      | (auxiliary_frame_step $h; exact auxiliary_frame_refl _)
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
           | auxiliary_frame_step $hx
           | (split at $hx:ident <;> first
               | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
               | auxiliary_frame_step $hx
               | ((repeat (fail_if_success auxiliary_frame_step $hx; obtain ⟨_, _, _, $hx:ident⟩ := bind_ok $hx))
                  auxiliary_frame_step $hx)
               | skip)
           | skip)
      | dsimp only at $h:ident)

theorem appendFields_auxiliary_frame {s e m t : Term} {j r : List Term} (h : appendFields s e m j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold appendFields at h
  auxiliary_frame_walk h

theorem appendFields_auxiliary_frame_step {s e m t : Term} {j r : List Term} :
    appendFields s e m j = .ok (t, r) ↔ Except.ok (t, r) = appendFields s e m j ∧ AuxiliaryFrame s t :=
  step_iff appendFields_auxiliary_frame

theorem bumpHwm_auxiliary_frame {s hwm t : Term} {j r : List Term} (h : bumpHwm s hwm j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold bumpHwm at h
  auxiliary_frame_walk h

theorem bumpHwm_auxiliary_frame_step {s hwm t : Term} {j r : List Term} :
    bumpHwm s hwm j = .ok (t, r) ↔ Except.ok (t, r) = bumpHwm s hwm j ∧ AuxiliaryFrame s t :=
  step_iff bumpHwm_auxiliary_frame

theorem appendMessage_auxiliary_frame {s e m t : Term} {j r : List Term} (h : appendMessage s e m j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold appendMessage at h
  auxiliary_frame_walk h

theorem appendMessage_auxiliary_frame_step {s e m t : Term} {j r : List Term} :
    appendMessage s e m j = .ok (t, r) ↔ Except.ok (t, r) = appendMessage s e m j ∧ AuxiliaryFrame s t :=
  step_iff appendMessage_auxiliary_frame

theorem noteResult_auxiliary_frame {s tool input status errorClass message content t : Term} {j r : List Term}
    (h : noteResult s tool input status errorClass message content j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold noteResult at h
  auxiliary_frame_walk h

theorem noteResult_auxiliary_frame_step {s tool input status errorClass message content t : Term} {j r : List Term} :
    noteResult s tool input status errorClass message content j = .ok (t, r) ↔ Except.ok (t, r) = noteResult s tool input status errorClass message content j ∧ AuxiliaryFrame s t :=
  step_iff noteResult_auxiliary_frame

theorem noteAsyncResult_auxiliary_frame {s existing e status t : Term} {j r : List Term}
    (h : noteAsyncResult s existing e status j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold noteAsyncResult at h
  auxiliary_frame_walk h

theorem noteAsyncResult_auxiliary_frame_step {s existing e status t : Term} {j r : List Term} :
    noteAsyncResult s existing e status j = .ok (t, r) ↔ Except.ok (t, r) = noteAsyncResult s existing e status j ∧ AuxiliaryFrame s t :=
  step_iff noteAsyncResult_auxiliary_frame

theorem asyncStart_auxiliary_frame {s e t : Term} {j r : List Term} (h : asyncStart s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold asyncStart at h
  auxiliary_frame_walk h

theorem asyncStart_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    asyncStart s e j = .ok (t, r) ↔ Except.ok (t, r) = asyncStart s e j ∧ AuxiliaryFrame s t :=
  step_iff asyncStart_auxiliary_frame

theorem resetFresh_auxiliary_frame {s m t : Term} {j r : List Term} (h : resetFresh s m j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold resetFresh at h
  auxiliary_frame_walk h

theorem resetFresh_auxiliary_frame_step {s m t : Term} {j r : List Term} :
    resetFresh s m j = .ok (t, r) ↔ Except.ok (t, r) = resetFresh s m j ∧ AuxiliaryFrame s t :=
  step_iff resetFresh_auxiliary_frame

theorem addObligation_auxiliary_frame {s raw t : Term} {j r : List Term} (h : addObligation s raw j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold addObligation at h
  auxiliary_frame_walk h

theorem addObligation_auxiliary_frame_step {s raw t : Term} {j r : List Term} :
    addObligation s raw j = .ok (t, r) ↔ Except.ok (t, r) = addObligation s raw j ∧ AuxiliaryFrame s t :=
  step_iff addObligation_auxiliary_frame

theorem obligationResolve_auxiliary_frame {s key t : Term} {j r : List Term}
    (h : obligationResolve s key j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold obligationResolve at h
  auxiliary_frame_walk h

theorem obligationResolve_auxiliary_frame_step {s key t : Term} {j r : List Term} :
    obligationResolve s key j = .ok (t, r) ↔ Except.ok (t, r) = obligationResolve s key j ∧ AuxiliaryFrame s t :=
  step_iff obligationResolve_auxiliary_frame

theorem obligationCard_auxiliary_frame {s conversation limit t : Term} {j r : List Term}
    (h : obligationCard s conversation limit j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold obligationCard at h
  auxiliary_frame_walk h

theorem obligationCard_auxiliary_frame_step {s conversation limit t : Term} {j r : List Term} :
    obligationCard s conversation limit j = .ok (t, r) ↔ Except.ok (t, r) = obligationCard s conversation limit j ∧ AuxiliaryFrame s t :=
  step_iff obligationCard_auxiliary_frame

theorem replyIntent_auxiliary_frame {s e t : Term} {j r : List Term} (h : replyIntent s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold replyIntent at h
  auxiliary_frame_walk h

theorem replyIntent_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    replyIntent s e j = .ok (t, r) ↔ Except.ok (t, r) = replyIntent s e j ∧ AuxiliaryFrame s t :=
  step_iff replyIntent_auxiliary_frame

theorem retireIntent_auxiliary_frame {s e t : Term} {j r : List Term} (h : retireIntent s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold retireIntent at h
  auxiliary_frame_walk h

theorem retireIntent_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    retireIntent s e j = .ok (t, r) ↔ Except.ok (t, r) = retireIntent s e j ∧ AuxiliaryFrame s t :=
  step_iff retireIntent_auxiliary_frame

theorem activationStarted_auxiliary_frame {s raw t : Term} {j r : List Term}
    (h : activationStarted s raw j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold activationStarted at h
  auxiliary_frame_walk h

theorem activationStarted_auxiliary_frame_step {s raw t : Term} {j r : List Term} :
    activationStarted s raw j = .ok (t, r) ↔ Except.ok (t, r) = activationStarted s raw j ∧ AuxiliaryFrame s t :=
  step_iff activationStarted_auxiliary_frame

theorem activationFinished_auxiliary_frame {s identity t : Term} {j r : List Term}
    (h : activationFinished s identity j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold activationFinished at h
  auxiliary_frame_walk h

theorem activationFinished_auxiliary_frame_step {s identity t : Term} {j r : List Term} :
    activationFinished s identity j = .ok (t, r) ↔ Except.ok (t, r) = activationFinished s identity j ∧ AuxiliaryFrame s t :=
  step_iff activationFinished_auxiliary_frame

theorem sessionAck_auxiliary_frame {s e t : Term} {j r : List Term} (h : sessionAck s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold sessionAck at h
  auxiliary_frame_walk h

theorem sessionAck_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    sessionAck s e j = .ok (t, r) ↔ Except.ok (t, r) = sessionAck s e j ∧ AuxiliaryFrame s t :=
  step_iff sessionAck_auxiliary_frame

theorem pruneResultRefs_auxiliary_frame {s t : Term} {j r : List Term} (h : pruneResultRefs s j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold pruneResultRefs at h
  auxiliary_frame_walk h

theorem pruneResultRefs_auxiliary_frame_step {s t : Term} {j r : List Term} :
    pruneResultRefs s j = .ok (t, r) ↔ Except.ok (t, r) = pruneResultRefs s j ∧ AuxiliaryFrame s t :=
  step_iff pruneResultRefs_auxiliary_frame

theorem waitClear_auxiliary_frame {s e t : Term} {j r : List Term} (h : waitClear s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold waitClear at h
  auxiliary_frame_walk h

theorem waitClear_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    waitClear s e j = .ok (t, r) ↔ Except.ok (t, r) = waitClear s e j ∧ AuxiliaryFrame s t :=
  step_iff waitClear_auxiliary_frame

theorem statusTransition_auxiliary_frame {s e t : Term} {j r : List Term} (h : statusTransition s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold statusTransition at h
  auxiliary_frame_walk h

theorem statusTransition_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    statusTransition s e j = .ok (t, r) ↔ Except.ok (t, r) = statusTransition s e j ∧ AuxiliaryFrame s t :=
  step_iff statusTransition_auxiliary_frame

theorem activityTransition_auxiliary_frame {s e t : Term} {j r : List Term}
    (h : activityTransition s e j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold activityTransition at h
  auxiliary_frame_walk h

theorem activityTransition_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    activityTransition s e j = .ok (t, r) ↔ Except.ok (t, r) = activityTransition s e j ∧ AuxiliaryFrame s t :=
  step_iff activityTransition_auxiliary_frame

theorem metadataCreated_auxiliary_frame {s e t : Term} {j r : List Term} (h : metadataCreated s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold metadataCreated at h
  auxiliary_frame_walk h

theorem metadataCreated_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    metadataCreated s e j = .ok (t, r) ↔ Except.ok (t, r) = metadataCreated s e j ∧ AuxiliaryFrame s t :=
  step_iff metadataCreated_auxiliary_frame

theorem metadataPrompt_auxiliary_frame {s e t : Term} {j r : List Term} (h : metadataPrompt s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold metadataPrompt at h
  auxiliary_frame_walk h

theorem metadataPrompt_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    metadataPrompt s e j = .ok (t, r) ↔ Except.ok (t, r) = metadataPrompt s e j ∧ AuxiliaryFrame s t :=
  step_iff metadataPrompt_auxiliary_frame

theorem metadataUpdate_auxiliary_frame {s e t : Term} {j r : List Term} (h : metadataUpdate s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold metadataUpdate at h
  auxiliary_frame_walk h

theorem metadataUpdate_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    metadataUpdate s e j = .ok (t, r) ↔ Except.ok (t, r) = metadataUpdate s e j ∧ AuxiliaryFrame s t :=
  step_iff metadataUpdate_auxiliary_frame

theorem stampWorkReasons_auxiliary_frame {s e t : Term} {j r : List Term} (h : stampWorkReasons s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold stampWorkReasons at h
  auxiliary_frame_walk h

theorem stampWorkReasons_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    stampWorkReasons s e j = .ok (t, r) ↔ Except.ok (t, r) = stampWorkReasons s e j ∧ AuxiliaryFrame s t :=
  step_iff stampWorkReasons_auxiliary_frame

theorem stampAgentId_auxiliary_frame {s e t : Term} {j r : List Term} (h : stampAgentId s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold stampAgentId at h
  simp only [ite_ok_iff] at h
  auxiliary_frame_walk h

theorem stampAgentId_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    stampAgentId s e j = .ok (t, r) ↔ Except.ok (t, r) = stampAgentId s e j ∧ AuxiliaryFrame s t :=
  step_iff stampAgentId_auxiliary_frame

theorem stampRuntimeEpoch_auxiliary_frame {s e t : Term} {j r : List Term} (h : stampRuntimeEpoch s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold stampRuntimeEpoch at h
  simp only [ite_ok_iff] at h
  auxiliary_frame_walk h

theorem stampRuntimeEpoch_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    stampRuntimeEpoch s e j = .ok (t, r) ↔ Except.ok (t, r) = stampRuntimeEpoch s e j ∧ AuxiliaryFrame s t :=
  step_iff stampRuntimeEpoch_auxiliary_frame

theorem stampRuntimeNode_auxiliary_frame {s e t : Term} {j r : List Term} (h : stampRuntimeNode s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold stampRuntimeNode at h
  simp only [ite_ok_iff] at h
  auxiliary_frame_walk h

theorem stampRuntimeNode_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    stampRuntimeNode s e j = .ok (t, r) ↔ Except.ok (t, r) = stampRuntimeNode s e j ∧ AuxiliaryFrame s t :=
  step_iff stampRuntimeNode_auxiliary_frame

theorem stampActivityRevision_auxiliary_frame {s e t : Term} {j r : List Term} (h : stampActivityRevision s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold stampActivityRevision at h
  simp only [ite_ok_iff] at h
  auxiliary_frame_walk h

theorem stampActivityRevision_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    stampActivityRevision s e j = .ok (t, r) ↔ Except.ok (t, r) = stampActivityRevision s e j ∧ AuxiliaryFrame s t :=
  step_iff stampActivityRevision_auxiliary_frame

theorem stampStorageRevision_auxiliary_frame {s e t : Term} {j r : List Term} (h : stampStorageRevision s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold stampStorageRevision at h
  simp only [ite_ok_iff] at h
  auxiliary_frame_walk h

theorem stampStorageRevision_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    stampStorageRevision s e j = .ok (t, r) ↔ Except.ok (t, r) = stampStorageRevision s e j ∧ AuxiliaryFrame s t :=
  step_iff stampStorageRevision_auxiliary_frame

theorem stampFlushId_auxiliary_frame {s e t : Term} {j r : List Term} (h : stampFlushId s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold stampFlushId at h
  simp only [ite_ok_iff] at h
  auxiliary_frame_walk h

theorem stampFlushId_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    stampFlushId s e j = .ok (t, r) ↔ Except.ok (t, r) = stampFlushId s e j ∧ AuxiliaryFrame s t :=
  step_iff stampFlushId_auxiliary_frame

theorem stampWorkIndexToken_auxiliary_frame {s e t : Term} {j r : List Term} (h : stampWorkIndexToken s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold stampWorkIndexToken at h
  simp only [ite_ok_iff] at h
  auxiliary_frame_walk h

theorem stampWorkIndexToken_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    stampWorkIndexToken s e j = .ok (t, r) ↔ Except.ok (t, r) = stampWorkIndexToken s e j ∧ AuxiliaryFrame s t :=
  step_iff stampWorkIndexToken_auxiliary_frame

theorem sessionStamp_auxiliary_frame {s e t : Term} {j r : List Term} (h : sessionStamp s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold sessionStamp at h
  auxiliary_frame_walk h

theorem sessionStamp_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    sessionStamp s e j = .ok (t, r) ↔ Except.ok (t, r) = sessionStamp s e j ∧ AuxiliaryFrame s t :=
  step_iff sessionStamp_auxiliary_frame

theorem bumpHwmEvent_auxiliary_frame {s e t : Term} {j r : List Term} (h : bumpHwmEvent s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold bumpHwmEvent at h
  auxiliary_frame_walk h

theorem bumpHwmEvent_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    bumpHwmEvent s e j = .ok (t, r) ↔ Except.ok (t, r) = bumpHwmEvent s e j ∧ AuxiliaryFrame s t :=
  step_iff bumpHwmEvent_auxiliary_frame

theorem compactionFailure_auxiliary_frame {s e t : Term} {j r : List Term}
    (h : compactionFailure s e j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold compactionFailure at h
  auxiliary_frame_walk h

theorem compactionFailure_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    compactionFailure s e j = .ok (t, r) ↔ Except.ok (t, r) = compactionFailure s e j ∧ AuxiliaryFrame s t :=
  step_iff compactionFailure_auxiliary_frame

theorem progressStep_auxiliary_frame {s e t : Term} {j r : List Term} (h : progressStep s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold progressStep at h
  auxiliary_frame_walk h

theorem progressStep_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    progressStep s e j = .ok (t, r) ↔ Except.ok (t, r) = progressStep s e j ∧ AuxiliaryFrame s t :=
  step_iff progressStep_auxiliary_frame

theorem pruneCompactResults_auxiliary_frame {s t : Term} {j r : List Term}
    (h : pruneCompactResults s j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold pruneCompactResults at h
  auxiliary_frame_walk h

theorem pruneCompactResults_auxiliary_frame_step {s t : Term} {j r : List Term} :
    pruneCompactResults s j = .ok (t, r) ↔ Except.ok (t, r) = pruneCompactResults s j ∧ AuxiliaryFrame s t :=
  step_iff pruneCompactResults_auxiliary_frame

theorem recomputeContext_auxiliary_frame {s t : Term} {j r : List Term} (h : recomputeContext s j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold recomputeContext at h
  auxiliary_frame_walk h

theorem recomputeContext_auxiliary_frame_step {s t : Term} {j r : List Term} :
    recomputeContext s j = .ok (t, r) ↔ Except.ok (t, r) = recomputeContext s j ∧ AuxiliaryFrame s t :=
  step_iff recomputeContext_auxiliary_frame

set_option backward.split false in
/-- Compaction retains the fact and async-result record lists. -/
theorem historyCompaction_auxiliary_frame {s e t : Term} {provider : Bool} {j r : List Term}
    (h : historyCompaction s e provider j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold historyCompaction at h
  repeat' first
    | (execution_head_is h "VerifiedKernel.Session.recomputeContext"
       exact recomputeContext_auxiliary_frame h)
    | (execution_head_is h "Pure.pure"
       have same := pure_ok h
       subst t
       exact auxiliary_frame_refl _)
    | (execution_head_is h "Bind.bind"
       have bound := bind_ok h
       clear h
       obtain ⟨value, _, prior, h⟩ := bound
       first
         | (execution_head_is prior "VerifiedKernel.Data.write"
            refine auxiliary_frame_trans (write_auxiliary_frame prior rfl rfl) ?_)
         | (execution_head_is prior "VerifiedKernel.Session.pruneResultRefs"
            refine auxiliary_frame_trans (pruneResultRefs_auxiliary_frame prior) ?_)
         | (execution_head_is prior "VerifiedKernel.Session.pruneCompactResults"
            refine auxiliary_frame_trans (pruneCompactResults_auxiliary_frame prior) ?_)
         | (execution_head_is prior "Pure.pure"
            have same := pure_ok prior
            subst value)
         | skip)
    | dsimp only at h
    | split at h

theorem historyCompaction_auxiliary_frame_step {s e t : Term} {provider : Bool} {j r : List Term} :
    historyCompaction s e provider j = .ok (t, r) ↔ Except.ok (t, r) = historyCompaction s e provider j ∧ AuxiliaryFrame s t :=
  step_iff historyCompaction_auxiliary_frame

theorem transcriptToolResult_auxiliary_frame {s e t : Term} {j r : List Term}
    (h : transcriptToolResult s e j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold transcriptToolResult at h
  auxiliary_frame_walk h

theorem transcriptToolResult_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    transcriptToolResult s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptToolResult s e j ∧ AuxiliaryFrame s t :=
  step_iff transcriptToolResult_auxiliary_frame

theorem transcriptAssistant_auxiliary_frame {s e t : Term} {j r : List Term}
    (h : transcriptAssistant s e j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold transcriptAssistant at h
  auxiliary_frame_walk h

theorem transcriptAssistant_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    transcriptAssistant s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptAssistant s e j ∧ AuxiliaryFrame s t :=
  step_iff transcriptAssistant_auxiliary_frame

theorem transcriptLog_auxiliary_frame {s e t : Term} {j r : List Term} (h : transcriptLog s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold transcriptLog at h
  auxiliary_frame_walk h

theorem transcriptLog_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    transcriptLog s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptLog s e j ∧ AuxiliaryFrame s t :=
  step_iff transcriptLog_auxiliary_frame

theorem transcriptSeed_auxiliary_frame {s e t : Term} {j r : List Term} (h : transcriptSeed s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  unfold transcriptSeed at h
  auxiliary_frame_walk h

theorem transcriptSeed_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    transcriptSeed s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptSeed s e j ∧ AuxiliaryFrame s t :=
  step_iff transcriptSeed_auxiliary_frame

theorem afterEvent_auxiliary_frame {previous next e t : Term} {j r : List Term}
    (h : afterEvent previous next e j = .ok (t, r)) : AuxiliaryFrame next t := by
  unfold afterEvent at h
  auxiliary_frame_walk h

theorem afterEvent_auxiliary_frame_step {previous next e t : Term} {j r : List Term} :
    afterEvent previous next e j = .ok (t, r) ↔ Except.ok (t, r) = afterEvent previous next e j ∧ AuxiliaryFrame next t :=
  step_iff afterEvent_auxiliary_frame

/-- Compose the Session operations of `runtimeAppend` (`runtimeAppend_ops`). This is much
cheaper than a walk over every branch of `runtimeAppend`. -/
theorem runtimeAppend_auxiliary_frame {s e t : Term} {j r : List Term} (h : runtimeAppend s e j = .ok (t, r)) :
    AuxiliaryFrame s t := by
  obtain ⟨_, _, _, _, _, _, _, _, _, _, _, _, _, _, appended, written, bumped, reset⟩ := runtimeAppend_ops h
  exact auxiliary_frame_trans (appendFields_auxiliary_frame appended) (auxiliary_frame_trans (write_auxiliary_frame written rfl rfl)
    (auxiliary_frame_trans (bumpHwm_auxiliary_frame bumped) (resetFresh_auxiliary_frame reset)))

theorem runtimeAppend_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    runtimeAppend s e j = .ok (t, r) ↔ Except.ok (t, r) = runtimeAppend s e j ∧ AuxiliaryFrame s t :=
  step_iff runtimeAppend_auxiliary_frame

theorem transcriptRuntime_auxiliary_frame {s e t : Term} {j r : List Term}
    (h : transcriptRuntime s e j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold transcriptRuntime at h
  auxiliary_frame_walk h

theorem transcriptRuntime_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    transcriptRuntime s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptRuntime s e j ∧ AuxiliaryFrame s t :=
  step_iff transcriptRuntime_auxiliary_frame

/-- Compose the Session operations of `transcriptDelivery` (`transcriptDelivery_ops`). This is
much cheaper than a walk over every branch of `transcriptDelivery`. -/
theorem transcriptDelivery_auxiliary_frame {s e t : Term} {j r : List Term}
    (h : transcriptDelivery s e j = .ok (t, r)) : AuxiliaryFrame s t := by
  rcases transcriptDelivery_ops h with rfl | ⟨_, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, appended, written, obligated, bumped, reset⟩
  · exact auxiliary_frame_refl _
  · exact auxiliary_frame_trans (appendFields_auxiliary_frame appended) (auxiliary_frame_trans (write_auxiliary_frame written rfl rfl)
      (auxiliary_frame_trans (addObligation_auxiliary_frame obligated) (auxiliary_frame_trans (bumpHwm_auxiliary_frame bumped) (resetFresh_auxiliary_frame reset))))

theorem transcriptDelivery_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    transcriptDelivery s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptDelivery s e j ∧ AuxiliaryFrame s t :=
  step_iff transcriptDelivery_auxiliary_frame


theorem queueAppend_auxiliary_frame {s e t : Term} {j r : List Term}
    (h : queueAppend s e j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold queueAppend at h
  auxiliary_frame_walk h

theorem queueAppend_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    queueAppend s e j = .ok (t, r) ↔ Except.ok (t, r) = queueAppend s e j ∧ AuxiliaryFrame s t :=
  step_iff queueAppend_auxiliary_frame


theorem queueAck_auxiliary_frame {s e t : Term} {j r : List Term}
    (h : queueAck s e j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold queueAck at h
  auxiliary_frame_walk h

theorem queueAck_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    queueAck s e j = .ok (t, r) ↔ Except.ok (t, r) = queueAck s e j ∧ AuxiliaryFrame s t :=
  step_iff queueAck_auxiliary_frame


theorem queueConsume_auxiliary_frame {s e t : Term} {j r : List Term}
    (h : queueConsume s e j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold queueConsume at h
  auxiliary_frame_walk h

theorem queueConsume_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    queueConsume s e j = .ok (t, r) ↔ Except.ok (t, r) = queueConsume s e j ∧ AuxiliaryFrame s t :=
  step_iff queueConsume_auxiliary_frame

theorem mergePredicate_auxiliary_frame {s kind through replacement extra t : Term} {j r : List Term}
    (h : mergePredicate s kind through replacement extra j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold mergePredicate at h
  repeat' first
    | exact ⟨write_field_frame h rfl, write_field_frame h rfl⟩
    | split at h
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)

theorem mergePredicate_auxiliary_frame_step {s kind through replacement extra t : Term} {j r : List Term} :
    mergePredicate s kind through replacement extra j = .ok (t, r) ↔
      Except.ok (t, r) = mergePredicate s kind through replacement extra j ∧ AuxiliaryFrame s t :=
  step_iff mergePredicate_auxiliary_frame

theorem microcompactIds_auxiliary_frame {s replacement e t : Term} {ids j r : List Term}
    (h : microcompactIds s ids replacement e j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold microcompactIds at h
  repeat' first
    | exact ⟨write_field_frame h rfl, write_field_frame h rfl⟩
    | split at h
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)

theorem microcompactIds_auxiliary_frame_step {s replacement e t : Term} {ids j r : List Term} :
    microcompactIds s ids replacement e j = .ok (t, r) ↔
      Except.ok (t, r) = microcompactIds s ids replacement e j ∧ AuxiliaryFrame s t :=
  step_iff microcompactIds_auxiliary_frame

theorem microcompact_auxiliary_frame {s e t : Term} {j r : List Term}
    (h : microcompact s e j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold microcompact at h
  auxiliary_frame_walk h

theorem microcompact_auxiliary_frame_step {s e t : Term} {j r : List Term} :
    microcompact s e j = .ok (t, r) ↔ Except.ok (t, r) = microcompact s e j ∧ AuxiliaryFrame s t :=
  step_iff microcompact_auxiliary_frame

end VerifiedKernel.Session.WorkConservation
