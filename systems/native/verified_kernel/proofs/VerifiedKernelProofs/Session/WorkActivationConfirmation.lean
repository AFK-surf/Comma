import VerifiedKernelProofs.Session.WorkActivationWrite
import VerifiedKernelProofs.Session.WorkDriverDurableBatch

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

/-- Each stage consumes the resource returned by the preceding native stage. -/
structure WriteSubmission (cursor : PendingRevision.Cursor) (continuation : Term) where
  key : Term
  observations : List Term
  preparedState : Term
  token : Term
  reasons : Term
  activity : Term
  revision : Term
  flush : Term
  epoch : Term
  node : Term
  stamped : Term
  casCursor : Term
  requestedKey : Term
  requestedBytes : Term
  requestedBase : Term
  preparation : ObservationTrace
    (resident (writeFenced cursor continuation).1 (a "fence_start") (.tuple [key, list observations]))
    (some (fencingCursor (.pending cursor) continuation
      (RevisionFence.prepared cursor key preparedState)), .tuple [a "prepared"])
  metadata : BatchTrace
    (resident (some (fencingCursor (.pending cursor) continuation
      (RevisionFence.prepared cursor key preparedState))) (a "stamp")
      (.tuple [token, reasons, activity, revision, flush, epoch, node]))
    (some (fencingCursor (.pending cursor) continuation (stampedFence cursor key stamped)), .tuple [a "stamped"])
  encoded : resident (some (fencingCursor (.pending cursor) continuation
    (stampedFence cursor key stamped))) (a "encode") nil =
    (some casCursor, .tuple [a "cas", requestedKey, requestedBytes, requestedBase])

structure WriteEpisode (cursor : PendingRevision.Cursor) (continuation : Term)
    extends WriteSubmission cursor continuation where
  result : Term
  confirmed : Term
  resumed : resident (some casCursor) (a "cas_result") result = (some confirmed, .tuple [a "committed"])

structure WriteCommitTrace (cursor : PendingRevision.Cursor) (continuation : Term)
    (durable : ArchivePublication.HotSnapshots) extends WriteEpisode cursor continuation where
  primitive : ArchivePublication.SnapshotCASMeaning
    (.tuple [a "cas", requestedKey, requestedBytes, requestedBase]) result durable

theorem WriteCommitTrace.preserves {cursor : PendingRevision.Cursor} {continuation : Term}
    {durable : ArchivePublication.HotSnapshots} (trace : WriteCommitTrace cursor continuation durable)
    (ready : QueueReady cursor.working) (format : cursor.working.get (a "storage_format") = i 3) :
    ∃ etag snapshot bytes,
      trace.confirmed = .tuple [a "session_command_driver_confirmed",
        (Revision.Cursor.committed trace.stamped etag).pack, continuation] ∧
      (.tuple [a "cas", trace.requestedKey, trace.requestedBytes, trace.requestedBase] : Term) =
        .tuple [a "cas", trace.key, .binary bytes, cursor.etag] ∧
      durable trace.key etag snapshot ∧ QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
      ∀ sealed item, ValueSemantics.Represented cursor.working sealed item →
        ValueSemantics.Represented snapshot sealed item :=
  issued_write_preserves ready format trace.preparation trace.metadata trace.encoded trace.primitive trace.resumed

structure ActivationCommitTrace (context : Context) (hwm prompt active checkpoint : Term)
    (durable : ArchivePublication.HotSnapshots) where
  observations : List Term
  events : List Term
  writeCursor : Term
  staged : PendingRevision.Cursor
  continuation : Term
  admission : AdmissionTrace
    (resident (some context.pack) (a "start")
      (.tuple [.tuple [a "activate", .tuple [list [], hwm, prompt, active], checkpoint], list observations]))
    (some writeCursor, .tuple [a "validate_write", list events])
  write : BatchTrace (resident (some writeCursor) (a "write_result") (a "ok")) (writeFenced staged continuation)
  fence : WriteCommitTrace staged continuation durable

/-- Activation retains accepted work in the exact snapshot behind the native confirmation. -/
theorem ActivationCommitTrace.confirms_preserved_work {context : Context} {hwm prompt active checkpoint : Term}
    {durable : ArchivePublication.HotSnapshots}
    (trace : ActivationCommitTrace context hwm prompt active checkpoint durable)
    (ready : QueueReady context.candidate.working)
    (format : context.candidate.working.get (a "storage_format") = i 3) :
    trace.staged.baseline = context.candidate.baseline ∧ trace.staged.etag = context.candidate.etag ∧
    ∃ etag snapshot bytes details capturedCheckpoint capturedActive,
      trace.continuation = .tuple [b "activation_written", details, capturedCheckpoint, capturedActive] ∧
      trace.fence.confirmed = .tuple [a "session_command_driver_confirmed",
        (Revision.Cursor.committed trace.fence.stamped etag).pack, trace.continuation] ∧
      (.tuple [a "cas", trace.fence.requestedKey, trace.fence.requestedBytes, trace.fence.requestedBase] : Term) =
        .tuple [a "cas", trace.fence.key, .binary bytes, context.candidate.etag] ∧
      durable trace.fence.key etag snapshot ∧ QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
      ∀ sealed item, ValueSemantics.Represented context.candidate.working sealed item →
        ValueSemantics.Represented snapshot sealed item := by
  obtain ⟨⟨details, capturedCheckpoint, capturedActive, continuationEq⟩,
    baselineEq, etagEq, _, stagedReady, stagedFormat, stagedWork⟩ :=
    activation_raw_write_preserves ready trace.admission trace.write
  obtain ⟨etag, snapshot, bytes, confirmedEq, issued, stored, snapshotReady, snapshotFormat, kept⟩ :=
    trace.fence.preserves stagedReady (stagedFormat.trans format)
  rw [etagEq] at issued
  exact ⟨baselineEq, etagEq, etag, snapshot, bytes, details, capturedCheckpoint, capturedActive,
    continuationEq, confirmedEq, issued, stored, snapshotReady, snapshotFormat,
    fun sealed item present => kept sealed item (stagedWork sealed item present)⟩

end VerifiedKernel.Session.CommandDriver
