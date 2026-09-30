import VerifiedKernelProofs.Session.WorkCurrentLineage
import VerifiedKernelProofs.Session.WorkCurrentActivation
import VerifiedKernelProofs.Session.WorkPhysicalPlanPreservation
import VerifiedKernelProofs.Session.WorkPhysicalArchive
import VerifiedKernelProofs.Session.WorkArchiveInterleaving
import VerifiedKernelProofs.Session.WorkPhysicalPlanRecords
import VerifiedKernelProofs.Session.WorkCurrentRecordFence
import VerifiedKernelProofs.Session.WorkDriverLog
import VerifiedKernelProofs.Session.WorkDriverRecovery
import VerifiedKernelProofs.Session.WorkRawOrdinary

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication CommandDriver
set_option Elab.async false

/-- Local native execution before a fence. Storage extension records actual archive publication. -/
inductive Staging : Objects → Revision.Cursor → Objects → Revision.Cursor → Prop where
  | unchanged (objects : Objects) (cursor : Revision.Cursor) : Staging objects cursor objects cursor
  | plan {objects : Objects} {cursor : Revision.Cursor} {next : PendingRevision.Cursor}
      {mode outcome : Term} {observations : List Term}
      (call : Revision.PlanTrace
        (Revision.resident (some cursor.pack) (a "plan") (.tuple [mode, list observations]))
        (Revision.planned next outcome)) : Staging objects cursor objects (.pending next)
  | input {objects : Objects} {cursor : Revision.Cursor} {entry born checkpoint : Term}
      (call : InputSubmission cursor entry born checkpoint) :
      Staging objects cursor objects (.pending call.staged)
  | ordinary {objects : Objects} {cursor : Revision.Cursor} {next : PendingRevision.Cursor}
      {events : List Term} {hwm : Term}
      (batch : RawOrdinaryBatch events)
      (write : PendingRevision.Execution
        (PendingRevision.resident (some cursor.candidate.pack) (a "write") (.tuple [list events, hwm])) next) :
      Staging objects cursor objects (.pending next)
  | log {objects : Objects} {cursor : Revision.Cursor} {next : PendingRevision.Cursor}
      {entry checkpoint saved continuation : Term} {observations events : List Term}
      (admission : AdmissionTrace
        (CommandDriver.resident (some cursor.pack) (a "start")
          (.tuple [.tuple [a "log", entry, checkpoint], list observations]))
        (some saved, .tuple [a "validate_write", list events]))
      (write : BatchTrace (CommandDriver.resident (some saved) (a "write_result") (a "ok"))
        (writeFenced next continuation)) : Staging objects cursor objects (.pending next)
  | activate {objects : Objects} {cursor : Revision.Cursor} {next : PendingRevision.Cursor}
      {hwm prompt active checkpoint saved continuation : Term} {observations events : List Term}
      (admission : AdmissionTrace
        (CommandDriver.resident (some cursor.pack) (a "start")
          (.tuple [.tuple [a "activate", .tuple [list [], hwm, prompt, active], checkpoint], list observations]))
        (some saved, .tuple [a "validate_write", list events]))
      (write : BatchTrace (CommandDriver.resident (some saved) (a "write_result") (a "ok"))
        (writeFenced next continuation)) : Staging objects cursor objects (.pending next)
  | archive {objects nextObjects : Objects} {cursor : Revision.Cursor} {next : PendingRevision.Cursor}
      {records : List Term} {ceiling line : Int} {final : ArchivePublication.Output} {event : Term}
      (window : StorageQuery.archiveWindow cursor.candidate.working [] =
        .ok (.tuple [a "ok", list records, i ceiling], [])) (positive : line > 0)
      (publication : ArchivePublication.Execution (start cursor.candidate.working (i line)) objects final nextObjects)
      (emitted : final.2 = .tuple [a "advance", event])
      (written : PendingRevision.Execution
        (PendingRevision.resident (some cursor.candidate.pack) (a "write") (.tuple [list [event], nil])) next) :
      Staging objects cursor nextObjects (.pending next)
  | trans {first middle last : Objects} {start midway finish : Revision.Cursor}
      (prior : Staging first start middle midway) (suffix : Staging middle midway last finish) :
      Staging first start last finish

theorem Staging.recovery {objects : Objects} {cursor : Revision.Cursor} {next : PendingRevision.Cursor}
    {args checkpoint saved continuation : Term} {observations events : List Term}
    (admission : AdmissionTrace
      (CommandDriver.resident (some cursor.pack) (a "start")
        (.tuple [.tuple [a "recover", args, checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list events]))
    (write : BatchTrace (CommandDriver.resident (some saved) (a "write_result") (a "ok"))
      (writeFenced next continuation)) : Staging objects cursor objects (.pending next) := by
  obtain ⟨hwm, scope, batch, _, executed⟩ := recovery_raw_admission_applied admission write
  exact .ordinary batch.raw executed

/-- A publication may finish before unrelated storage steps. Only its immutable evidence is rebased. -/
theorem Staging.archive_published_earlier {objects published current : Objects}
    {cursor : Revision.Cursor} {next : PendingRevision.Cursor} {records : List Term}
    {ceiling line : Int} {final : ArchivePublication.Output} {event : Term}
    (window : StorageQuery.archiveWindow cursor.candidate.working [] =
      .ok (.tuple [a "ok", list records, i ceiling], [])) (positive : line > 0)
    (publication : ArchivePublication.Execution (start cursor.candidate.working (i line)) objects final published)
    (extension : ObjectsExtend published current) (emitted : final.2 = .tuple [a "advance", event])
    (written : PendingRevision.Execution
      (PendingRevision.resident (some cursor.candidate.pack) (a "write") (.tuple [list [event], nil])) next) :
    Staging current cursor current (.pending next) :=
  .archive window positive (publication.in_extension extension) emitted written

theorem Staging.physical {framing : CodecFraming} {objects nextObjects : Objects}
    {owner session : ByteArray} {cursor next : Revision.Cursor} {sealed : List Term}
    (execution : Staging objects cursor nextObjects next)
    (history : PhysicalHistory framing objects owner session cursor.candidate.working sealed) :
    next.candidate.etag = cursor.candidate.etag ∧ ObjectsExtend objects nextObjects ∧
      ∃ nextSealed, PhysicalHistory framing nextObjects owner session next.candidate.working nextSealed ∧
      ∀ item, PhysicalIdentityFact objects cursor.candidate.working (.work item) →
        PhysicalIdentityFact nextObjects next.candidate.working (.work item) := by
  induction execution generalizing sealed with
  | unchanged => exact ⟨rfl, fun _ _ h => h, sealed, history, fun _ h => h⟩
  | plan call =>
    exact ⟨(Revision.plan_preserves history.invariant.history.invariant.ready call).2.1,
      fun _ _ h => h, sealed, Revision.plan_physical_history history call,
      Revision.plan_physical_preserves history call⟩
  | input call =>
    obtain ⟨journal, result, rest, input, started, write⟩ :=
      input_raw_admission_applied (input_admission_reflect call.admission) call.write
    have pending := Revision.execution_pending write
    rw [Revision.write_captured] at pending
    have nextHistory := PendingRevision.input_write_physical_history history input started pending
    obtain ⟨_, _, _, etagEq, _, _, _⟩ := PendingRevision.write_executes pending
    exact ⟨etagEq, fun _ _ h => h, sealed, nextHistory,
      PendingRevision.input_write_physical_preserves history input started pending⟩
  | log admission write =>
    obtain ⟨_, journal, result, rest, call, started, pending⟩ := log_raw_admission_applied admission write
    obtain ⟨_, _, _, etagEq, _, _, applied⟩ := PendingRevision.write_executes pending
    obtain ⟨middle, inputBatch, metadataBatch⟩ := resident_batch_append applied
    obtain ⟨canonical, allowed⟩ := started_log_admitted call started
    have middleHistory := history.admitted inputBatch canonical allowed
    obtain ⟨keys, metadata⟩ := PendingRevision.hwm_metadata nil
    exact ⟨etagEq, fun _ _ h => h, sealed, middleHistory.metadata metadataBatch keys metadata,
      fun item present => middleHistory.metadata_physical metadataBatch keys metadata item
        (history.admitted_physical inputBatch canonical allowed item present)⟩
  | ordinary batch write =>
    obtain ⟨token, nextHistory, kept⟩ := PendingRevision.raw_ordinary_write_physical history batch write
    exact ⟨token, fun _ _ h => h, sealed, nextHistory, fun item present => kept (.work item) present⟩
  | activate admission write =>
    obtain ⟨nextHistory, kept⟩ := activation_raw_write_physical history admission write
    exact ⟨(activation_raw_write_preserves history.invariant.history.invariant.ready admission write).2.2.1,
      fun _ _ h => h, sealed, nextHistory, kept⟩
  | archive window positive publication emitted written =>
    obtain ⟨_, etagEq, dropped, nextHistory, _⟩ :=
      PendingRevision.archive_write_physical_history history window positive publication emitted written
    obtain ⟨_, _, _, _, _, _, applied⟩ := PendingRevision.write_executes written
    exact ⟨etagEq, execution_objects_extend publication, _, nextHistory,
      history.publish_resident_physical window positive publication emitted applied⟩
  | trans prior suffix first second =>
    obtain ⟨firstToken, firstObjects, middleSealed, middleHistory, firstKept⟩ := first history
    obtain ⟨secondToken, secondObjects, nextSealed, nextHistory, secondKept⟩ := second middleHistory
    exact ⟨secondToken.trans firstToken, fun key records h => secondObjects key records (firstObjects key records h),
      nextSealed, nextHistory, fun item h => secondKept item (firstKept item h)⟩

theorem Staging.records {framing : CodecFraming} {objects nextObjects : Objects}
    {owner session : ByteArray} {cursor next : Revision.Cursor} {sealed : List Term}
    (execution : Staging objects cursor nextObjects next)
    (history : PhysicalHistory framing objects owner session cursor.candidate.working sealed) :
    ∀ reference, PhysicalIdentityFact objects cursor.candidate.working (.record reference) →
      PhysicalIdentityFact nextObjects next.candidate.working (.record reference) := by
  induction execution generalizing sealed with
  | unchanged => exact fun _ h => h
  | plan call => exact Revision.plan_records history call
  | input call =>
    obtain ⟨journal, result, rest, input, started, write⟩ :=
      input_raw_admission_applied (input_admission_reflect call.admission) call.write
    have pending := Revision.execution_pending write
    rw [Revision.write_captured] at pending
    obtain ⟨_, _, _, _, _, _, applied⟩ := PendingRevision.write_executes pending
    obtain ⟨middle, inputBatch, metadataBatch⟩ := resident_batch_append applied
    obtain ⟨canonical, allowed⟩ := started_input_admitted input started
    obtain ⟨keys, metadata⟩ := PendingRevision.hwm_metadata _
    exact fun reference present => (history.admitted inputBatch canonical allowed).metadata_records
      metadataBatch keys metadata reference (history.admitted_records inputBatch canonical allowed reference present)
  | log admission write =>
    obtain ⟨_, journal, result, rest, call, started, pending⟩ := log_raw_admission_applied admission write
    obtain ⟨_, _, _, _, _, _, applied⟩ := PendingRevision.write_executes pending
    obtain ⟨middle, inputBatch, metadataBatch⟩ := resident_batch_append applied
    obtain ⟨canonical, allowed⟩ := started_log_admitted call started
    obtain ⟨keys, metadata⟩ := PendingRevision.hwm_metadata nil
    exact fun reference present => (history.admitted inputBatch canonical allowed).metadata_records
      metadataBatch keys metadata reference (history.admitted_records inputBatch canonical allowed reference present)
  | ordinary batch write =>
    obtain ⟨_, _, kept⟩ := PendingRevision.raw_ordinary_write_physical history batch write
    exact fun reference present => kept (.record reference) present
  | @activate objects cursor next hwm prompt active checkpoint saved continuation observations events admission write =>
    obtain ⟨capturedContinuation, capturedHwm, savedEq, batch, fenced⟩ := activation_admission_captured admission
    obtain ⟨details, capturedCheckpoint, capturedActive, rfl⟩ := activation_post_write_shape fenced
    rw [savedEq, write_captured] at write
    have valid := fenced_batch_start_valid cursor
      (.tuple [b "activation_written", details, capturedCheckpoint, capturedActive]) events capturedHwm
    have afterEq := fenced_batch_continuation (fenced_batch_output_preserved write valid)
    rw [afterEq] at write
    have executed := Revision.execution_pending (fenced_batch_reflect (fenced_batch_trace_reflect valid write))
    rw [Revision.write_captured] at executed
    obtain ⟨_, _, _, _, _, _, applied⟩ := PendingRevision.write_executes executed
    obtain ⟨middle, activationBatch, metadataBatch⟩ := resident_batch_append applied
    have canonical := fun event member => (batch event member).1
    have safe := fun event member => activation_nonretiring (batch event member).2
    have owner := activation_batch_owner activationBatch batch
    have middleHistory := history.nonretiring activationBatch canonical safe owner
    obtain ⟨keys, metadata⟩ := PendingRevision.hwm_metadata capturedHwm
    exact fun reference present => middleHistory.metadata_records metadataBatch keys metadata reference
      (history.nonretiring_records activationBatch canonical safe owner reference present)
  | archive window positive publication emitted written =>
    obtain ⟨_, _, _, _, _, _, applied⟩ := PendingRevision.write_executes written
    exact history.publish_records window positive publication emitted applied
  | trans prior suffix first second =>
    obtain ⟨_, _, middleSealed, middleHistory, _⟩ := prior.physical history
    exact fun reference present => second middleHistory reference (first history reference present)

theorem Staging.identities {framing : CodecFraming} {objects nextObjects : Objects}
    {owner session : ByteArray} {cursor next : Revision.Cursor} {sealed : List Term}
    (execution : Staging objects cursor nextObjects next)
    (history : PhysicalHistory framing objects owner session cursor.candidate.working sealed) :
    next.candidate.etag = cursor.candidate.etag ∧ ObjectsExtend objects nextObjects ∧
      ∃ nextSealed, PhysicalHistory framing nextObjects owner session next.candidate.working nextSealed ∧
      ∀ fact, PhysicalIdentityFact objects cursor.candidate.working fact →
        PhysicalIdentityFact nextObjects next.candidate.working fact := by
  obtain ⟨etag, extension, nextSealed, nextHistory, kept⟩ := execution.physical history
  refine ⟨etag, extension, nextSealed, nextHistory, ?_⟩
  intro fact present
  cases fact with
  | work item => exact kept item present
  | record reference => exact execution.records history reference present

theorem Staging.landed {framing : CodecFraming} {objects nextObjects : Objects}
    {readStore before after : HotStore} {versions : VersionBytes} {next : Revision.Cursor}
    {continuation result : Term}
    (read : ReadCall readStore) (staging : Staging objects read.context nextObjects next)
    (write : WriteSubmission next.candidate continuation)
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (readLineage : readStore.lineage framing objects) (currentLineage : before.lineage framing objects)
    (readVersioned : readStore.versioned versions) (currentVersioned : before.versioned versions)
    (cas : HotCAS before
      (.tuple [a "cas", write.requestedKey, write.requestedBytes, write.requestedBase]) result after) :
    after.lineage framing nextObjects ∧ ObjectsExtend objects nextObjects ∧
      ∀ key fact, before.fact objects key fact → after.fact nextObjects key fact := by
  obtain ⟨sealed, history, readToken⟩ := read.history readLineage codec
  obtain ⟨stagedToken, extension, nextSealed, nextHistory, stageKept⟩ := staging.identities history
  obtain ⟨addressed, etag, snapshot, bytes, encoded, issued, stored, snapshotHistory, kept⟩ :=
    write.current_identities nextHistory cas
  have readAddress := (SessionDomain.ReadRevision.start_captured read.started).1
  have sameKey : write.key = read.objectKey := addressed.trans readAddress.symm
  rw [sameKey, stagedToken, readToken] at issued
  have applied : HotCAS before (.tuple [a "cas", read.objectKey, .binary bytes, .binary read.etag]) result after := by
    rwa [issued] at cas
  have sameStored := stored
  rw [sameKey] at sameStored
  refine ⟨applied.lineage (HotStore.lineage_objects currentLineage extension) readAddress encoded snapshotHistory,
    extension, ?_⟩
  intro key fact existing
  by_cases same : key = read.objectKey
  · subst key
    obtain ⟨decoded, decoding⟩ := roundtrip snapshot bytes encoded
    apply HotStore.current_fact snapshotHistory sameStored encoded decoding (codec _ _ _ encoded decoding)
    exact kept fact (stageKept fact (read.current_fact readLineage codec readVersioned currentVersioned applied fact existing))
  · exact applied.other_fact same (HotStore.fact_objects extension existing)

end VerifiedKernel.Session.WorkConservation.CurrentExecution
