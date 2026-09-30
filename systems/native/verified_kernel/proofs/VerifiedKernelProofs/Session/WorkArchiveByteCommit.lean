import VerifiedKernelProofs.Session.WorkArchiveByteTrace
import VerifiedKernelProofs.Session.WorkNativeStoreCommit

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication CommandDriver
set_option Elab.async false

/-- Publication changes the current archive bytes before the hot CAS. A failed or
lost CAS reply does not undo these objects. The source cursor remains captured. -/
theorem archive_publication_cas_reachable {versions : VersionBytes}
    {before : ByteResidentWorld} {past : List ByteResidentWorld} {published : ByteStore}
    {source : CapturedRevision} {staged : PendingRevision.Cursor}
    {records : List Term} {ceiling line : Int} {final : ArchivePublication.Output}
    {event outcome : Term} {after : HotStore} {etag : ByteArray}
    (roundtrip : ∀ value bytes, ETF.encode value = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok decoded ∧ ValueSemantics.Equivalent value decoded)
    (prior : ByteResidentReachable versions before past)
    (member : source ∈ before.captured)
    (window : StorageQuery.archiveWindow source.cursor.candidate.working [] =
      .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0)
    (publication : BytePublicationTrace
      (ArchivePublication.start source.cursor.candidate.working (i line)) before.archive final published)
    (emitted : final.2 = .tuple [a "advance", event])
    (written : PendingRevision.Execution
      (PendingRevision.resident (some source.cursor.candidate.pack) (a "write")
        (.tuple [list [event], nil])) staged)
    (native : NativeFenceSubmission staged)
    (cas : HotCAS before.hot
      (.tuple [a "cas", native.requestedKey, native.requestedBytes, native.requestedBase])
      (.tuple [a "ok", .binary etag, outcome]) after)
    (tokens : after.versioned versions) :
    ∃ nextPast, ByteResidentReachable versions
      ⟨after, published,
        ⟨source.owner, source.session, .committed native.stamped (.binary etag)⟩ :: before.captured⟩ nextPast := by
  obtain ⟨publishedPast, reached⟩ := publication.resident prior
  refine ⟨_, .next reached (.hot rfl ?_)⟩
  exact native_store_commit member
    (publication.staging roundtrip window positive emitted written) native cas tokens

end VerifiedKernel.Session.WorkConservation.CurrentExecution
