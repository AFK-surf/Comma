import VerifiedKernelProofs.Session.WorkKernelHistory
import VerifiedKernelProofs.Proof.CatalogFrameTactic

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

def CatalogFrame (state next : Term) : Prop := ArchivePublication.ArchiveFrame state next

theorem catalog_frame_refl (state : Term) : CatalogFrame state state := ⟨rfl, rfl, rfl⟩

theorem catalog_frame_trans {state middle next : Term} (first : CatalogFrame state middle) (last : CatalogFrame middle next) :
    CatalogFrame state next := ArchivePublication.ArchiveFrame.trans first last

theorem write_catalog_frame {state next : Term} {fields : List (String × Term)} {journal rest : List Term}
    (call : write state fields journal = .ok (next, rest))
    (safe : fields.all (fun pair => pair.1 != "segment_catalog") = true)
    (watermark : fields.all (fun pair => pair.1 != "archived_through") = true)
    (session : fields.all (fun pair => pair.1 != "session_id") = true) : CatalogFrame state next :=
  ⟨write_field_frame call safe, write_field_frame call watermark, write_field_frame call session⟩

theorem write_catalog_frame_step {state next : Term} {fields : List (String × Term)} {journal rest : List Term} :
    write state fields journal = .ok (next, rest) ↔ Except.ok (next, rest) = write state fields journal ∧
      (fields.all (fun pair => pair.1 != "segment_catalog") = true →
        fields.all (fun pair => pair.1 != "archived_through") = true →
        fields.all (fun pair => pair.1 != "session_id") = true → CatalogFrame state next) := step_iff write_catalog_frame

catalog_rule appendFields (state event message)
catalog_rule bumpHwm (state hwm)
catalog_rule appendMessage (state event message)
catalog_rule noteResult (state tool input status errorClass message content)
catalog_rule noteAsyncResult (state existing event status)
catalog_rule asyncStart (state event)
catalog_rule asyncTerminal (state event status)
catalog_rule resetFresh (state message)
catalog_rule addObligation (state raw)
catalog_rule obligationResolve (state key)
catalog_rule obligationCard (state conversation limit)
catalog_rule replyRepair (state event)
catalog_rule replyIntent (state event)
catalog_rule retireIntent (state event)
catalog_rule activationStarted (state raw)
catalog_rule activationFinished (state identity)
catalog_rule sessionAck (state event)
catalog_rule pruneResultRefs (state)
catalog_rule waitClear (state event)
catalog_rule statusTransition (state event)
catalog_rule activityTransition (state event)
catalog_rule metadataCreated (state event)
catalog_rule conversationSourceAdvance (state event)
catalog_rule metadataPrompt (state event)
catalog_rule metadataUpdate (state event)
catalog_rule stampWorkReasons (state event)
catalog_rule stampAgentId (state event)
catalog_rule stampRuntimeEpoch (state event)
catalog_rule stampRuntimeNode (state event)
catalog_rule stampActivityRevision (state event)
catalog_rule stampStorageRevision (state event)
catalog_rule stampFlushId (state event)
catalog_rule stampWorkIndexToken (state event)
catalog_rule sessionStamp (state event)
catalog_rule bumpHwmEvent (state event)
catalog_rule compactionFailure (state event)
catalog_rule compactionRecovery (state event)
catalog_rule progressStep (state event)
catalog_rule pruneCompactResults (state)
catalog_rule recomputeContext (state)

theorem historyCompaction_catalog_frame {state event next : Term} {provider : Bool} {journal rest : List Term}
    (call : historyCompaction state event provider journal = .ok (next, rest)) : CatalogFrame state next := by
  unfold historyCompaction at call
  catalog_frame_walk call

theorem historyCompaction_catalog_frame_step {state event next : Term} {provider : Bool} {journal rest : List Term} :
    historyCompaction state event provider journal = .ok (next, rest) ↔
      Except.ok (next, rest) = historyCompaction state event provider journal ∧ CatalogFrame state next :=
  step_iff historyCompaction_catalog_frame

catalog_rule compactResult (state event)
catalog_rule storedResult (state event)
catalog_rule transcriptToolResult (state event)
catalog_rule transcriptAssistant (state event)
catalog_rule transcriptLog (state event)
catalog_rule runtimeAppend (state event)
catalog_rule transcriptRuntime (state event)
catalog_rule transcriptDelivery (state event)
catalog_rule transcriptSeed (state event)
catalog_rule queueAppend (state event)
catalog_rule queueAck (state event)
catalog_rule queueConsume (state event)
catalog_rule sessionEvent (state event)
theorem mergePredicate_catalog_frame {state kind through replacement extra next : Term} {journal rest : List Term}
    (call : mergePredicate state kind through replacement extra journal = .ok (next, rest)) : CatalogFrame state next := by
  unfold mergePredicate at call
  repeat' first
    | exact write_catalog_frame call rfl rfl rfl
    | split at call
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)

theorem mergePredicate_catalog_frame_step {state kind through replacement extra next : Term} {journal rest : List Term} :
    mergePredicate state kind through replacement extra journal = .ok (next, rest) ↔
      Except.ok (next, rest) = mergePredicate state kind through replacement extra journal ∧ CatalogFrame state next :=
  step_iff mergePredicate_catalog_frame

theorem microcompactIds_catalog_frame {state replacement event next : Term} {ids journal rest : List Term}
    (call : microcompactIds state ids replacement event journal = .ok (next, rest)) : CatalogFrame state next := by
  unfold microcompactIds at call
  catalog_frame_walk call

theorem microcompactIds_catalog_frame_step {state replacement event next : Term} {ids journal rest : List Term} :
    microcompactIds state ids replacement event journal = .ok (next, rest) ↔
      Except.ok (next, rest) = microcompactIds state ids replacement event journal ∧ CatalogFrame state next :=
  step_iff microcompactIds_catalog_frame

catalog_rule microcompact (state event)

theorem afterEvent_catalog_frame {previous state event next : Term} {journal rest : List Term}
    (call : afterEvent previous state event journal = .ok (next, rest)) : CatalogFrame state next := by
  unfold afterEvent at call
  catalog_frame_walk call

theorem afterEvent_catalog_frame_step {previous state event next : Term} {journal rest : List Term} :
    afterEvent previous state event journal = .ok (next, rest) ↔
      Except.ok (next, rest) = afterEvent previous state event journal ∧ CatalogFrame state next :=
  step_iff afterEvent_catalog_frame

end VerifiedKernel.Session.WorkConservation
