import VerifiedKernelProofs.Session.WorkPhysicalHistory

namespace VerifiedKernel.Session.RevisionFence
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem candidate_physical_history {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {cursor : PendingRevision.Cursor} {sealed observations : List Term}
    {key preparedState stamped token reasons activity revision flush epoch node saved request result restored etag : Term}
    {durable : HotSnapshots}
    (history : PhysicalHistory framing objects owner session cursor.working sealed)
    (preparation : Preparation cursor key
      (resident (some cursor.pack) (a "start") (.tuple [key, list observations])) preparedState)
    (metadata : MetadataExecution cursor key
      (resident (some (prepared cursor key preparedState)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) stamped)
    (encoded : resident (some (.tuple [a "session_fence_stamped", cursor.pack, key, stamped]))
      (a "encode") nil = (some saved, request))
    (primitive : SnapshotCASMeaning request result durable)
    (resumed : resident (some saved) (a "cas_result") result = (some restored, .tuple [a "ok", etag])) :
    restored = stamped ∧ PhysicalHistory framing objects owner session stamped sealed ∧
      ∃ snapshot bytes,
        Lifecycle.persistable stamped [] = .ok (snapshot, []) ∧
        ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
        request = .tuple [a "cas", key, .binary bytes, cursor.etag] ∧ durable key etag snapshot ∧
        PhysicalHistory framing objects owner session snapshot sealed := by
  obtain ⟨journal, rest, preparedCall⟩ := start_prepares preparation
  have preparedHistory := history.prepare preparedCall
  have stampedHistory := preparedHistory.metadata (metadata_executes metadata)
    (fun event member => (metadata_admitted token reasons activity revision flush epoch node event member).1)
    (fun event member => (metadata_admitted token reasons activity revision flush epoch node event member).2)
  obtain ⟨same, snapshot, bytes, persisted, encoding, requestEq, committed⟩ := confirmed_capture encoded primitive resumed
  exact ⟨same, stampedHistory, snapshot, bytes, persisted, encoding, requestEq, committed, stampedHistory.persist persisted⟩

end VerifiedKernel.Session.RevisionFence

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication

theorem PhysicalHistory.identity_physical {framing : CodecFraming} {objects : Objects}
    {owner session source : ByteArray} {state : Term} {sealed : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (present : IdentityPresent (state.get (a "input_dedupe")) (.binary source)) :
    PhysicalIdentitySupported objects state source :=
  identity_supported_physical history.invariant.images (history.invariant.history.identity_supported present)

end VerifiedKernel.Session.WorkConservation
