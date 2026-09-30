import VerifiedKernelProofs.Session.WorkKernelHistory
import VerifiedKernelProofs.Proof.OwnerControlFrameTactic

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

def OwnerControlFrame (state next : Term) : Prop := OwnerFrame state next

theorem owner_control_frame_refl (state : Term) : OwnerControlFrame state state := rfl

theorem owner_control_frame_trans {state middle next : Term} (first : OwnerControlFrame state middle)
    (last : OwnerControlFrame middle next) : OwnerControlFrame state next := last.trans first

theorem write_owner_control_frame {state next : Term} {fields : List (String × Term)} {journal rest : List Term}
    (call : write state fields journal = .ok (next, rest))
    (safe : fields.all (fun pair => pair.1 != "agent_id") = true) : OwnerControlFrame state next :=
  write_field_frame call safe

theorem write_owner_control_frame_step {state next : Term} {fields : List (String × Term)} {journal rest : List Term} :
    write state fields journal = .ok (next, rest) ↔ Except.ok (next, rest) = write state fields journal ∧
      (fields.all (fun pair => pair.1 != "agent_id") = true → OwnerControlFrame state next) := step_iff write_owner_control_frame

owner_control_rule appendFields (state event message)
owner_control_rule bumpHwm (state hwm)
owner_control_rule appendMessage (state event message)
owner_control_rule noteResult (state tool input status errorClass message content)
owner_control_rule noteAsyncResult (state existing event status)
owner_control_rule asyncStart (state event)
owner_control_rule asyncTerminal (state event status)
owner_control_rule resetFresh (state message)
owner_control_rule addObligation (state raw)
owner_control_rule obligationResolve (state key)
owner_control_rule obligationCard (state conversation limit)
owner_control_rule replyRepair (state event)
owner_control_rule replyIntent (state event)
owner_control_rule retireIntent (state event)
owner_control_rule activationStarted (state raw)
owner_control_rule activationFinished (state identity)
owner_control_rule sessionAck (state event)
owner_control_rule pruneResultRefs (state)
owner_control_rule waitClear (state event)
owner_control_rule statusTransition (state event)
owner_control_rule activityTransition (state event)
owner_control_rule metadataCreated (state event)
owner_control_rule metadataPrompt (state event)
owner_control_rule metadataUpdate (state event)
owner_control_rule stampWorkReasons (state event)
owner_control_rule stampRuntimeEpoch (state event)
owner_control_rule stampRuntimeNode (state event)
owner_control_rule stampActivityRevision (state event)
owner_control_rule stampStorageRevision (state event)
owner_control_rule stampFlushId (state event)
owner_control_rule stampWorkIndexToken (state event)
owner_control_rule bumpHwmEvent (state event)
owner_control_rule compactionFailure (state event)
owner_control_rule compactionRecovery (state event)
owner_control_rule progressStep (state event)
owner_control_rule pruneCompactResults (state)
owner_control_rule recomputeContext (state)

theorem historyCompaction_owner_control_frame {state event next : Term} {provider : Bool} {journal rest : List Term}
    (call : historyCompaction state event provider journal = .ok (next, rest)) : OwnerControlFrame state next := by
  unfold historyCompaction at call
  owner_control_frame_walk call

theorem historyCompaction_owner_control_frame_step {state event next : Term} {provider : Bool} {journal rest : List Term} :
    historyCompaction state event provider journal = .ok (next, rest) ↔
      Except.ok (next, rest) = historyCompaction state event provider journal ∧ OwnerControlFrame state next :=
  step_iff historyCompaction_owner_control_frame

owner_control_rule compactResult (state event)
owner_control_rule storedResult (state event)
owner_control_rule transcriptToolResult (state event)
owner_control_rule transcriptAssistant (state event)
owner_control_rule transcriptLog (state event)
owner_control_rule runtimeAppend (state event)
owner_control_rule transcriptRuntime (state event)
owner_control_rule transcriptDelivery (state event)
owner_control_rule transcriptSeed (state event)
owner_control_rule queueAppend (state event)
owner_control_rule queueAck (state event)
owner_control_rule queueConsume (state event)
owner_control_rule sessionEvent (state event)
theorem mergePredicate_owner_control_frame {state kind through replacement extra next : Term} {journal rest : List Term}
    (call : mergePredicate state kind through replacement extra journal = .ok (next, rest)) : OwnerControlFrame state next := by
  unfold mergePredicate at call
  repeat' first
    | exact write_owner_control_frame call rfl
    | split at call
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)

theorem mergePredicate_owner_control_frame_step {state kind through replacement extra next : Term} {journal rest : List Term} :
    mergePredicate state kind through replacement extra journal = .ok (next, rest) ↔
      Except.ok (next, rest) = mergePredicate state kind through replacement extra journal ∧ OwnerControlFrame state next :=
  step_iff mergePredicate_owner_control_frame

theorem microcompactIds_owner_control_frame {state replacement event next : Term} {ids journal rest : List Term}
    (call : microcompactIds state ids replacement event journal = .ok (next, rest)) : OwnerControlFrame state next := by
  unfold microcompactIds at call
  owner_control_frame_walk call

theorem microcompactIds_owner_control_frame_step {state replacement event next : Term} {ids journal rest : List Term} :
    microcompactIds state ids replacement event journal = .ok (next, rest) ↔
      Except.ok (next, rest) = microcompactIds state ids replacement event journal ∧ OwnerControlFrame state next :=
  step_iff microcompactIds_owner_control_frame

owner_control_rule microcompact (state event)

theorem afterEvent_owner_control_frame {previous state event next : Term} {journal rest : List Term}
    (call : afterEvent previous state event journal = .ok (next, rest)) : OwnerControlFrame state next := by
  unfold afterEvent at call
  owner_control_frame_walk call

theorem afterEvent_owner_control_frame_step {previous state event next : Term} {journal rest : List Term} :
    afterEvent previous state event journal = .ok (next, rest) ↔
      Except.ok (next, rest) = afterEvent previous state event journal ∧ OwnerControlFrame state next :=
  step_iff afterEvent_owner_control_frame

owner_control_rule capabilitySync (state event)
owner_control_rule archiveAdvance (state event)

end VerifiedKernel.Session.WorkConservation
