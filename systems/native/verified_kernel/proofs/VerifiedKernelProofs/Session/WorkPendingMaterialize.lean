import VerifiedKernelProofs.Session.WorkPendingInput
import VerifiedKernelProofs.Session.WorkRevisionFence

namespace VerifiedKernel.Session.PendingRevision
open Data WorkConservation
set_option Elab.async false

/-- The native write applies the planned retirement batch before its captured HWM update. -/
theorem materialize_write_preserves {cursor final : Cursor} {events j r : List Term}
    {limit : Int} {wake : Bool} {hwm : Term}
    (ready : QueueReady cursor.working)
    (planned : StateQuery.materialize cursor.working limit j =
      .ok (.tuple [list events, Term.bool wake, hwm], r))
    (execution : Execution
      (resident (some cursor.pack) (a "write") (.tuple [list events, hwm])) final) :
    final.baseline = cursor.baseline ∧ final.etag = cursor.etag ∧
      final.events = cursor.events ++ events ∧
      (∃ merged, mergeHwm cursor.hwm hwm [] = .ok (merged, []) ∧ final.hwm = merged) ∧
      QueueReady final.working ∧
      final.working.get (a "storage_format") = cursor.working.get (a "storage_format") ∧
      (∀ sealed item, ValueSemantics.Represented cursor.working sealed item →
        ValueSemantics.Represented final.working sealed item) := by
  obtain ⟨merged, merge, baselineEq, etagEq, eventsEq, hwmEq, applied⟩ := write_executes execution
  obtain ⟨middle, materialized, metadataBatch⟩ := resident_batch_append applied
  have middleReady := materialize_resident_ready ready planned materialized
  obtain ⟨keys, metadata⟩ := hwm_metadata hwm
  obtain ⟨finalReady, _, kept⟩ := ValueSemantics.metadata_work metadataBatch keys metadata middleReady
  exact ⟨baselineEq, etagEq, eventsEq, ⟨merged, merge, hwmEq⟩, finalReady,
    resident_batch_format applied, fun sealed item present =>
      kept sealed item (ValueSemantics.materialize_preserves ready planned materialized present)⟩

end VerifiedKernel.Session.PendingRevision

namespace VerifiedKernel.Session.RevisionFence
open Data WorkConservation
set_option Elab.async false

/-- Planned retirement preserves accepted work through the actual native write and snapshot CAS. -/
theorem materialize_durable {cursor staged : PendingRevision.Cursor}
    {hwm key preparedState stamped token reasons activity revision flush epoch node
      saved request result restored etag : Term}
    {limit : Int} {wake : Bool} {events journal rest observations : List Term}
    {durable : ArchivePublication.HotSnapshots}
    (ready : QueueReady cursor.working) (format : cursor.working.get (a "storage_format") = i 3)
    (planned : StateQuery.materialize cursor.working limit journal =
      .ok (.tuple [list events, Term.bool wake, hwm], rest))
    (write : PendingRevision.Execution
      (PendingRevision.resident (some cursor.pack) (a "write") (.tuple [list events, hwm])) staged)
    (preparation : Preparation staged key
      (resident (some staged.pack) (a "start") (.tuple [key, list observations])) preparedState)
    (metadata : MetadataExecution staged key
      (resident (some (prepared staged key preparedState)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) stamped)
    (encoded : resident (some (.tuple [a "session_fence_stamped", staged.pack, key, stamped]))
      (a "encode") nil = (some saved, request))
    (primitive : ArchivePublication.SnapshotCASMeaning request result durable)
    (resumed : resident (some saved) (a "cas_result") result = (some restored, .tuple [a "ok", etag])) :
    staged.baseline = cursor.baseline ∧ staged.etag = cursor.etag ∧
      staged.events = cursor.events ++ events ∧ restored = stamped ∧
      ∃ snapshot, durable key etag snapshot ∧ QueueReady snapshot ∧
        snapshot.get (a "storage_format") = i 3 ∧
        ∀ sealed item, ValueSemantics.Represented cursor.working sealed item →
          ValueSemantics.Represented snapshot sealed item := by
  obtain ⟨baselineEq, etagEq, eventsEq, _, stagedReady, stagedFormat, preserved⟩ :=
    PendingRevision.materialize_write_preserves ready planned write
  obtain ⟨restoredEq, snapshot, committed, snapshotReady, snapshotFormat, kept⟩ :=
    candidate_preserves stagedReady (stagedFormat.trans format) preparation metadata encoded primitive resumed
  exact ⟨baselineEq, etagEq, eventsEq, restoredEq, snapshot, committed, snapshotReady, snapshotFormat,
    fun sealed item present => kept sealed item (preserved sealed item present)⟩

end VerifiedKernel.Session.RevisionFence
