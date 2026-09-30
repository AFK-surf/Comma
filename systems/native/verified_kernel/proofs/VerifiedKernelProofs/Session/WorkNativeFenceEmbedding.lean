import VerifiedKernelProofs.Session.WorkActivationConfirmation

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

/-- The Store's direct fence loop embeds in the command wrapper without changing a request. -/
theorem native_preparation_embedding {cursor : PendingRevision.Cursor} {key state : Term}
    {output : RevisionFence.Output} (context : Context) (continuation : Term)
    (execution : RevisionFence.Preparation cursor key output state) :
    ObservationTrace (acceptFence context continuation output)
      (some (fencingCursor context continuation (RevisionFence.prepared cursor key state)),
        .tuple [a "prepared"]) := by
  induction execution with
  | done => exact .done _
  | @resume observations request observation final tail ih =>
    apply ObservationTrace.resume (observation := observation)
    cases context <;> exact ih

theorem native_metadata_embedding {cursor : PendingRevision.Cursor} {key state : Term}
    {output : RevisionFence.Output} (context : Context) (continuation : Term)
    (execution : RevisionFence.MetadataExecution cursor key output state) :
    BatchTrace (acceptFence context continuation output)
      (some (fencingCursor context continuation (stampedFence cursor key state)), .tuple [a "stamped"]) := by
  induction execution with
  | done => exact .done _
  | @run state event final events observations tail ih =>
    apply BatchTrace.run (observations := observations)
    cases context <;> exact ih
  | @resume token request observation final events tail ih =>
    apply BatchTrace.resume (observation := observation)
    cases context <;> exact ih

/-- Native resources from `start_revision_fence`, stamping, and encoding. No command admission is assumed. -/
structure NativeFenceSubmission (cursor : PendingRevision.Cursor) where
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
  preparation : RevisionFence.Preparation cursor key
    (RevisionFence.resident (some cursor.pack) (a "start") (.tuple [key, list observations])) preparedState
  metadata : RevisionFence.MetadataExecution cursor key
    (RevisionFence.resident (some (RevisionFence.prepared cursor key preparedState)) (a "stamp")
      (.tuple [token, reasons, activity, revision, flush, epoch, node])) stamped
  encoded : RevisionFence.resident (some (stampedFence cursor key stamped)) (a "encode") nil =
    (some casCursor, .tuple [a "cas", requestedKey, requestedBytes, requestedBase])

def NativeFenceSubmission.embed {cursor : PendingRevision.Cursor}
    (native : NativeFenceSubmission cursor) (continuation : Term) : WriteSubmission cursor continuation where
  key := native.key
  observations := native.observations
  preparedState := native.preparedState
  token := native.token
  reasons := native.reasons
  activity := native.activity
  revision := native.revision
  flush := native.flush
  epoch := native.epoch
  node := native.node
  stamped := native.stamped
  casCursor := fencingCursor (.pending cursor) continuation native.casCursor
  requestedKey := native.requestedKey
  requestedBytes := native.requestedBytes
  requestedBase := native.requestedBase
  preparation := by
    simpa only [writeFenced, fence_start_captured] using
      native_preparation_embedding (.pending cursor) continuation native.preparation
  metadata := by
    have lifted := native_metadata_embedding (.pending cursor) continuation native.metadata
    exact lifted
  encoded := by
    change acceptFence (.pending cursor) continuation
      (RevisionFence.resident (some (stampedFence cursor native.key native.stamped)) (a "encode") nil) = _
    rw [native.encoded]
    rfl

end VerifiedKernel.Session.CommandDriver
