import VerifiedKernelProofs.Session.WorkPhysicalArchive
import VerifiedKernelProofs.Session.WorkCurrentFence

namespace VerifiedKernel.Session.RevisionFence
open Data WorkConservation ArchivePublication
set_option Elab.async false

/-- Publication, its actual resident write, and CAS retain old work in physical storage. No reply premise is required. -/
theorem archive_current_facts {framing : CodecFraming} {objects nextObjects : Objects} {owner session : ByteArray}
    {cursor staged : PendingRevision.Cursor} {sealed records observations : List Term}
    {before after : HotStore} {ceiling line : Int} {final : ArchivePublication.Output}
    {event key preparedState stamped token reasons activity revision flush epoch node saved request result : Term}
    (history : PhysicalHistory framing objects owner session cursor.working sealed)
    (window : StorageQuery.archiveWindow cursor.working [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0)
    (publication : ArchivePublication.Execution (start cursor.working (i line)) objects final nextObjects)
    (emitted : final.2 = .tuple [a "advance", event])
    (written : PendingRevision.Execution
      (PendingRevision.resident (some cursor.pack) (a "write") (.tuple [list [event], nil])) staged)
    (preparation : Preparation staged key
      (resident (some staged.pack) (a "start") (.tuple [key, list observations])) preparedState)
    (metadata : MetadataExecution staged key
      (resident (some (prepared staged key preparedState)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) stamped)
    (encoded : resident (some (.tuple [a "session_fence_stamped", staged.pack, key, stamped]))
      (a "encode") nil = (some saved, request))
    (cas : HotCAS before request result after) :
    key = StorageAddress.key owner session ∧ ∃ dropped etag snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      request = .tuple [a "cas", key, .binary bytes, cursor.etag] ∧ after.current key etag snapshot ∧
      PhysicalHistory framing nextObjects owner session snapshot (sealed ++ dropped) ∧
      ∀ item, PhysicalIdentityFact objects cursor.working (.work item) →
        PhysicalIdentityFact nextObjects snapshot (.work item) := by
  obtain ⟨_, etagEq, dropped, stagedHistory, archiveKept, _⟩ :=
    PendingRevision.archive_write_physical_history history window positive publication emitted written
  obtain ⟨addressed, etag, snapshot, bytes, encoding, requestEq, stored, snapshotHistory, _, kept⟩ :=
    candidate_current_facts stagedHistory preparation metadata encoded cas
  obtain ⟨_, _, _, _, _, _, applied⟩ := PendingRevision.write_executes written
  change ResidentBatch cursor.working [event] staged.working at applied
  have archived := history.publish_resident_physical window positive publication emitted applied
  refine ⟨addressed, dropped, etag, snapshot, bytes, encoding, ?_, stored, snapshotHistory, ?_⟩
  · simpa only [etagEq] using requestEq
  · intro item represented
    exact kept item (archived item represented)

end VerifiedKernel.Session.RevisionFence
