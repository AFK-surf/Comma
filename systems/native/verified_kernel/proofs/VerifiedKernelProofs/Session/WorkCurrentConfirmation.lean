import VerifiedKernelProofs.Session.WorkCurrentLineage
import VerifiedKernelProofs.Session.WorkReadIdentity

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

/-- Confirmation facts come from the decoded current object and its actual archive catalog. -/
def HotStore.fact (store : HotStore) (objects : Objects) (key : Term) (fact : IdentityFact) : Prop :=
  ∃ etag bytes state, HotRead store key bytes etag ∧
    ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, state]) ∧ PhysicalIdentityFact objects state fact

theorem PhysicalHistory.decode_identity {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {sealed : List Term} {fact : IdentityFact}
    (history : PhysicalHistory framing objects owner session state sealed)
    (codec : ValueSemantics.Equivalent state next) (present : PhysicalIdentityFact objects state fact) :
    PhysicalIdentityFact objects next fact := by
  cases fact with
  | work item => exact history.decode_physical codec item present
  | record reference =>
    obtain ⟨record, equivalent, live | archived⟩ := present
    · obtain ⟨nextRecord, stored, related⟩ := codec.record live
      exact ⟨nextRecord, equivalent.trans related, Or.inl stored⟩
    · obtain ⟨catalog, watermark, read, through, valid⟩ := history.invariant.archive
      have owner := codec.get (a "agent_id")
      have session := codec.get (a "session_id")
      rw [history.invariant.owned] at owner
      rw [history.invariant.identified] at session
      refine ⟨record, equivalent, Or.inr ?_⟩
      simpa only [codec.catalog read valid, read, owner.binary, session.binary,
        history.invariant.owned, history.invariant.identified] using archived

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

/-- A duplicate confirms the original source fact, not the payload in the retry. -/
theorem ReadCall.duplicate {framing : CodecFraming} {objects : Objects} {store : HotStore}
    {source : ByteArray} {entry born checkpoint saved confirmed args : Term} {observations : List Term}
    (call : ReadCall store) (lineage : store.lineage framing objects) (codec : SnapshotCodec)
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source)
    (admission : AdmissionTrace
      (resident (some call.context.pack) (a "start")
        (.tuple [.tuple [a "input", .tuple [entry, born], checkpoint], list observations]))
      (some saved, .tuple [a "fence"]))
    (fence : resident (some saved) (a "fence_clean") args = (some confirmed, .tuple [a "committed"])) :
    (∃ event fact, IdentityFactOrigin event source fact ∧ store.fact objects call.objectKey fact) ∧
      resident (some confirmed) (a "next") nil =
        (some call.context.pack, .tuple [a "return", .tuple [a "ok", a "duplicate"], nil]) := by
  obtain ⟨snapshot, sealed, current, history, equivalent⟩ :=
    SessionDomain.ReadRevision.read_lineage lineage codec call.started call.read call.decoded call.loaded
  obtain ⟨_, ⟨event, fact, origin, present⟩, returned⟩ :=
    read_duplicate_physical history current call.started call.read call.decoded equivalent call.loaded
      sourceValue admission fence
  exact ⟨⟨event, fact, origin, .binary call.etag, call.bytes, call.decodedState,
    call.read, call.decoded, history.decode_identity equivalent present⟩, returned⟩

end VerifiedKernel.Session.CommandDriver
