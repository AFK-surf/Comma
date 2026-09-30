import VerifiedKernelProofs.Session.WorkCurrentSubmission
import VerifiedKernelProofs.Session.WorkCurrentInput

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem read_input_submission_current_work {framing : CodecFraming} {objects : Objects}
    {store beforeCAS afterCAS : HotStore} {versions : VersionBytes}
    {agent session bytes etag source : ByteArray} {context : Context}
    {snapshot decodedState pending objectKey entry born checkpoint result : Term} {sealed readObservations : List Term}
    (readVersioned : store.versioned versions) (currentVersioned : beforeCAS.versioned versions)
    (history : PhysicalHistory framing objects agent session snapshot sealed)
    (current : store.current objectKey (.binary etag) snapshot)
    (started : SessionDomain.dispatch none (.tuple [i 1, a "session_read", i 1, a "start",
      .tuple [.binary agent, .binary session]]) =
      (some pending, SessionDomain.ReadRevision.response (.tuple [a "read", objectKey])))
    (read : HotRead store objectKey bytes (.binary etag))
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
    (codec : ValueSemantics.Equivalent snapshot decodedState)
    (loaded : SessionDomain.ReadRevision.LoadTrace
      (SessionDomain.dispatch (some pending) (.tuple [i 1, a "session_read", i 1, a "read_result",
        .tuple [.tuple [a "ok", .binary bytes, .binary etag], list readObservations]])) context.pack)
    (trace : InputSubmission context entry born checkpoint)
    (cas : HotCAS beforeCAS (.tuple [a "cas", trace.requestedKey, trace.requestedBytes, trace.requestedBase]) result afterCAS)
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source) :
    objectKey = StorageAddress.key agent session ∧
    ∃ committed snapshotAfter encodedBytes event now first last item,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshotAfter]) = .ok encodedBytes ∧
      (.tuple [a "cas", trace.requestedKey, trace.requestedBytes, trace.requestedBase] : Term) =
        .tuple [a "cas", objectKey, .binary encodedBytes, .binary etag] ∧
      afterCAS.current objectKey committed snapshotAfter ∧
      PhysicalHistory framing objects agent session snapshotAfter sealed ∧
      Command.inputEvent (context.candidate.working.get (a "session_id")) (.binary source)
        (RoundQuery.atomFirst entry "payload") now first = .ok (event, last) ∧
      MainInputFact event source item ∧ CanonicalQueueItem item ∧
      ∀ decodedAfter,
        ETF.decode encodedBytes = .ok (.tuple [a "comma_internal_session", i 3, decodedAfter]) →
        ValueSemantics.Equivalent snapshotAfter decodedAfter →
        afterCAS.work objects objectKey item ∧
          ∀ old, beforeCAS.work objects objectKey old → afterCAS.work objects objectKey old := by
  obtain ⟨addressed, _, _, _, _⟩ :=
    SessionDomain.ReadRevision.current_read_history history current started read decoded codec loaded
  obtain ⟨state, captured, stateHistory, readKept⟩ :=
    SessionDomain.ReadRevision.current_read_physical_preserves history current started read decoded codec loaded
  have contextEq : context = .committed state (.binary etag) := by
    apply Option.some.inj
    simpa only [Revision.unpack_pack] using congrArg Revision.unpack captured
  have contextHistory : PhysicalHistory framing objects agent session context.candidate.working sealed := by
    simpa only [contextEq, Revision.Cursor.candidate] using stateHistory
  obtain ⟨writeAddress, committed, snapshotAfter, encodedBytes, event, now, first, last, item,
    encoded, issued, stored, afterHistory, generated, fact, canonical, present, kept⟩ :=
    trace.current_facts contextHistory sourceValue cas
  have sameKey : trace.key = objectKey := writeAddress.trans addressed.symm
  have baseEq : context.candidate.etag = .binary etag := by rw [contextEq]; rfl
  rw [sameKey, baseEq] at issued
  have actualBase : HotRead beforeCAS objectKey bytes (.binary etag) :=
    HotCAS.read_base_bytes readVersioned currentVersioned read (by intro impossible; cases impossible)
      (by rw [issued] at cas; exact cas)
  rw [sameKey] at stored
  refine ⟨addressed, committed, snapshotAfter, encodedBytes, event, now, first, last, item,
    encoded, issued, stored, afterHistory, generated, fact, canonical, ?_⟩
  intro decodedAfter decodedNew codecNew
  refine ⟨HotStore.current_work afterHistory stored encoded decodedNew codecNew present, ?_⟩
  intro old existing
  apply HotStore.current_work afterHistory stored encoded decodedNew codecNew
  apply kept old
  have presentRead := readKept old (actualBase.snapshot_work history decoded codec existing)
  simpa only [contextEq, Revision.Cursor.candidate] using presentRead

end VerifiedKernel.Session.CommandDriver
