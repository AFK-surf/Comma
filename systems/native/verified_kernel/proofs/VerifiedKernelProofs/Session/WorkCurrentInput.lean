import VerifiedKernelProofs.Session.WorkReadInput
import VerifiedKernelProofs.Session.WorkStoredFacts

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

/-- A concurrent input CAS preserves facts in its current pre-state, not only its earlier read snapshot. -/
theorem read_input_current_work {framing : CodecFraming} {objects : Objects} {store beforeCAS afterCAS : HotStore}
    {versions : VersionBytes} {agent session bytes etag source : ByteArray} {context : Context}
    {snapshot decodedState pending objectKey entry born checkpoint : Term} {sealed readObservations : List Term}
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
    (trace : InputEpisode context entry born checkpoint)
    (cas : HotCAS beforeCAS (.tuple [a "cas", trace.requestedKey, trace.requestedBytes, trace.requestedBase])
      trace.result afterCAS)
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source) :
    ∃ committed snapshotAfter encodedBytes event now first last item,
      objectKey = StorageAddress.key agent session ∧
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshotAfter]) = .ok encodedBytes ∧
      afterCAS.current objectKey committed snapshotAfter ∧
      PhysicalHistory framing objects agent session snapshotAfter sealed ∧
      Command.inputEvent (context.candidate.working.get (a "session_id")) (.binary source)
        (RoundQuery.atomFirst entry "payload") now first = .ok (event, last) ∧
      MainInputFact event source item ∧ CanonicalQueueItem item ∧
      resident (some trace.confirmed) (a "next") nil = inputNotification trace.stamped committed trace.events ∧
      (∀ response : DurableConfirmation.Result,
        resident (inputNotification trace.stamped committed trace.events).1 (a "effect_result") response.wire =
          (some (Revision.Cursor.committed trace.stamped committed).pack,
            .tuple [a "return", .tuple [a "ok", a "committed"], nil])) ∧
      ∀ decodedAfter,
        ETF.decode encodedBytes = .ok (.tuple [a "comma_internal_session", i 3, decodedAfter]) →
        ValueSemantics.Equivalent snapshotAfter decodedAfter →
        afterCAS.work objects objectKey item ∧
          ∀ old, beforeCAS.work objects objectKey old → afterCAS.work objects objectKey old := by
  obtain ⟨addressed, _, _, _, _, actualBase, committed, snapshotAfter, encodedBytes, event, now, first, last, item,
    encoded, stored, afterHistory, generated, fact, canonical, present, kept, notified, returned⟩ :=
    read_input_physical readVersioned currentVersioned history current started read decoded codec loaded trace cas sourceValue
  refine ⟨committed, snapshotAfter, encodedBytes, event, now, first, last, item, addressed,
    encoded, stored, afterHistory, generated, fact, canonical, notified, returned, ?_⟩
  intro decodedAfter decodedNew codecNew
  refine ⟨HotStore.current_work afterHistory stored encoded decodedNew codecNew present, ?_⟩
  intro old existing
  exact HotStore.current_work afterHistory stored encoded decodedNew codecNew
    (kept old (actualBase.snapshot_work history decoded codec existing))

end VerifiedKernel.Session.CommandDriver
