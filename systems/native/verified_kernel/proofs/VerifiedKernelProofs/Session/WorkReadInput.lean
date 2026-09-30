import VerifiedKernelProofs.Session.WorkStorageAddress
import VerifiedKernelProofs.Session.WorkReadRevision
import VerifiedKernelProofs.Session.WorkCurrentVersion
import VerifiedKernelProofs.Session.WorkReadPhysicalPreservation
import VerifiedKernelProofs.Session.WorkPhysicalInputPreservation

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

/-- The native read supplies the input command's state and baseline version, not a host reconstruction. -/
theorem read_input_physical {framing : CodecFraming} {objects : Objects} {store beforeCAS afterCAS : HotStore}
    {versions : VersionBytes}
    {agent session bytes etag source : ByteArray} {context : Context}
    {snapshot decodedState pending objectKey entry born checkpoint : Term}
    {sealed readObservations : List Term}
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
    objectKey = SessionDomain.ReadRevision.key agent session ∧ trace.key = objectKey ∧
      trace.requestedKey = objectKey ∧ trace.requestedBase = .binary etag ∧ trace.staged.etag = .binary etag ∧
      HotRead beforeCAS objectKey bytes (.binary etag) ∧
      ∃ committed snapshotAfter encodedBytes event now first last item,
        ETF.encode (.tuple [a "comma_internal_session", i 3, snapshotAfter]) = .ok encodedBytes ∧
        afterCAS.current objectKey committed snapshotAfter ∧
        PhysicalHistory framing objects agent session snapshotAfter sealed ∧
        Command.inputEvent (context.candidate.working.get (a "session_id")) (.binary source)
          (RoundQuery.atomFirst entry "payload") now first = .ok (event, last) ∧
        MainInputFact event source item ∧ CanonicalQueueItem item ∧
        PhysicalIdentityFact objects snapshotAfter (.work item) ∧
        (∀ old, PhysicalIdentityFact objects snapshot (.work old) →
          PhysicalIdentityFact objects snapshotAfter (.work old)) ∧
        resident (some trace.confirmed) (a "next") nil = inputNotification trace.stamped committed trace.events ∧
        (∀ response : DurableConfirmation.Result,
          resident (inputNotification trace.stamped committed trace.events).1 (a "effect_result") response.wire =
            (some (Revision.Cursor.committed trace.stamped committed).pack,
              .tuple [a "return", .tuple [a "ok", a "committed"], nil])) := by
  obtain ⟨addressed, state, captured, stateHistory, readKept⟩ :=
    SessionDomain.ReadRevision.current_read_history history current started read decoded codec loaded
  have contextEq : context = .committed state (.binary etag) := by
    apply Option.some.inj
    simpa only [Revision.unpack_pack] using congrArg Revision.unpack captured
  have contextHistory : PhysicalHistory framing objects agent session context.candidate.working sealed := by
    simpa only [contextEq, Revision.Cursor.candidate] using stateHistory
  let committedTrace := trace.with_cas cas
  obtain ⟨_, baseEq, committed, snapshotAfter, encodedBytes, event, now, first, last, item,
    encoded, persisted, stored, afterHistory, generated, fact, canonical, present, _, notified, returned⟩ :=
    committedTrace.physical_input contextHistory sourceValue
  change trace.staged.etag = context.candidate.etag at baseEq
  change afterCAS.current trace.key committed snapshotAfter at stored
  obtain ⟨writeAddress, issuedKey, issuedBase⟩ := committedTrace.scoped_address contextHistory
  have sameKey : trace.key = objectKey := writeAddress.trans addressed.symm
  have sameBase : trace.staged.etag = .binary etag := by
    simpa only [contextEq, Revision.Cursor.candidate] using baseEq
  have requestedKey : trace.requestedKey = objectKey := issuedKey.trans sameKey
  have requestedBase : trace.requestedBase = .binary etag := issuedBase.trans sameBase
  have actualBase : HotRead beforeCAS objectKey bytes (.binary etag) :=
    HotCAS.read_base_bytes readVersioned currentVersioned read (by intro impossible; cases impossible)
      (by simpa only [requestedKey, requestedBase] using cas)
  refine ⟨addressed, sameKey, requestedKey, requestedBase, sameBase, actualBase,
    committed, snapshotAfter, encodedBytes, event, now, first, last, item,
    encoded, ?_, afterHistory, generated, fact, canonical, present, ?_, notified, returned⟩
  · simpa only [sameKey] using stored
  · intro old represented
    apply committedTrace.physical_preserves contextHistory persisted old
    obtain ⟨physicalState, physicalCaptured, _, physicalKept⟩ :=
      SessionDomain.ReadRevision.current_read_physical_preserves history current started read decoded codec loaded
    have physicalContextEq : context = .committed physicalState (.binary etag) := by
      apply Option.some.inj
      simpa only [Revision.unpack_pack] using congrArg Revision.unpack physicalCaptured
    simpa only [physicalContextEq, Revision.Cursor.candidate] using physicalKept old represented

end VerifiedKernel.Session.CommandDriver
