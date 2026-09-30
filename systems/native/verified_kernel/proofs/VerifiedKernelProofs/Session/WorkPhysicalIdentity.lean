import VerifiedKernelProofs.Session.WorkIdentityReload

namespace VerifiedKernel.Session.ArchivePublication
open Data WorkConservation
set_option Elab.async false

def PhysicalIdentityFact (objects : Objects) (state : Term) : IdentityFact → Prop
  | .work item => ValueSemantics.Represented state [] item ∨
      ∃ record, ValueSemantics.Recorded item record ∧
        RecordImageBacked objects (state.get (a "agent_id")) (state.get (a "session_id"))
          (wrap ((state.get (a "segment_catalog")).default (list []))) record
  | .record reference => ∃ record, ValueSemantics.Equivalent reference record ∧
      (ContainsRecord state record ∨
        RecordImageBacked objects (state.get (a "agent_id")) (state.get (a "session_id"))
          (wrap ((state.get (a "segment_catalog")).default (list []))) record)

def PhysicalIdentitySupported (objects : Objects) (state : Term) (source : ByteArray) : Prop :=
  ∃ event fact, IdentityFactOrigin event source fact ∧ PhysicalIdentityFact objects state fact

theorem identity_fact_physical {objects : Objects} {state : Term} {sealed : List Term} {fact : IdentityFact}
    (backed : SealedImagesBacked objects state sealed) (present : IdentityFactPresent state sealed fact) :
    PhysicalIdentityFact objects state fact := by
  cases fact with
  | work item =>
    rcases present with queued | live | ⟨record, member, recorded⟩
    · exact Or.inl (Or.inl queued)
    · exact Or.inl (Or.inr (Or.inl live))
    · exact Or.inr ⟨record, recorded, backed record member⟩
  | record reference =>
    obtain ⟨record, stored, same⟩ := present
    exact ⟨record, same, stored.imp id (backed record)⟩

theorem identity_supported_physical {objects : Objects} {state : Term} {sealed : List Term} {source : ByteArray}
    (backed : SealedImagesBacked objects state sealed) (supported : IdentitySupported state sealed source) :
    PhysicalIdentitySupported objects state source := by
  obtain ⟨event, fact, origin, present⟩ := supported
  exact ⟨event, fact, origin, identity_fact_physical backed present⟩

end VerifiedKernel.Session.ArchivePublication

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem loaded_duplicate_physical {resident : Option Term}
    {snapshot loaded entry born checkpoint saved confirmed key etag args : Term}
    {bytes source : ByteArray} {observations sealed live : List Term}
    {durable : HotSnapshots} {objects : Objects}
    (durableSnapshot : durable key etag snapshot)
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, snapshot]))
    (ready : QueueReady snapshot) (messages : snapshot.get (a "messages") = list live)
    (header : LedgerHeader snapshot) (supported : LedgerSupported snapshot sealed)
    (backed : SealedImagesBacked objects snapshot sealed)
    (reload : ReloadTrace
      (SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]))
      (some loaded, .tuple [i 1, a "ok", .tuple [a "done"]]))
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source)
    (admission : AdmissionTrace
      (CommandDriver.resident (some (Revision.Cursor.committed loaded etag).pack) (a "start")
        (.tuple [.tuple [a "input", .tuple [entry, born], checkpoint], list observations]))
      (some saved, .tuple [a "fence"]))
    (fence : CommandDriver.resident (some saved) (a "fence_clean") args =
      (some confirmed, .tuple [a "committed"])) :
    durable key etag snapshot ∧ PhysicalIdentitySupported objects snapshot source ∧
      CommandDriver.resident (some confirmed) (a "next") nil =
        (some (Revision.Cursor.committed loaded etag).pack,
          .tuple [a "return", .tuple [a "ok", a "duplicate"], nil]) := by
  obtain ⟨savedEq, present⟩ := input_raw_duplicate sourceValue admission
  have fact := load_identity_supported_before decoded ready messages header supported reload present
  rw [savedEq] at fence
  obtain ⟨state, revision, contextEq, confirmedEq⟩ := clean_fence_capture fence
  refine ⟨durableSnapshot, identity_supported_physical backed fact, ?_⟩
  rw [confirmedEq]
  exact duplicate_return_captured loaded etag

end VerifiedKernel.Session.CommandDriver
