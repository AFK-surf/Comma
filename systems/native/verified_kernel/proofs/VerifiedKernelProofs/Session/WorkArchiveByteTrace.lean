import VerifiedKernelProofs.Session.WorkArchiveByteExecution

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication
set_option Elab.async false

inductive BytePublicationTrace : ArchivePublication.Output → ByteStore →
    ArchivePublication.Output → ByteStore → Prop where
  | done (output : ArchivePublication.Output) (store : ByteStore) :
      BytePublicationTrace output store output store
  | respond {cursor : ArchivePublication.Cursor} {request result : Term}
      {before middle after : ByteStore} {final : ArchivePublication.Output}
      (primitive : ArchiveByteStep before request result middle)
      (tail : BytePublicationTrace (ArchivePublication.resume cursor result) middle final after) :
      BytePublicationTrace (some cursor, request) before final after
  | interleave {initial final : ArchivePublication.Output} {before after : ByteStore}
      {address : Term} {bytes : ByteArray} (absent : before address = none)
      (tail : BytePublicationTrace initial (insertArchiveBytes before address bytes) final after) :
      BytePublicationTrace initial before final after

theorem BytePublicationTrace.extension {initial final : ArchivePublication.Output} {before after : ByteStore}
    (trace : BytePublicationTrace initial before final after) : before.Extends after := by
  induction trace with
  | done => exact fun _ _ h => h
  | respond primitive _ ih => exact fun address bytes h => ih address bytes (primitive.extension address bytes h)
  | interleave absent _ ih =>
    exact fun address bytes h => ih address bytes (byte_insert_extends absent address bytes h)

/-- Rebase immutable observations to the final byte store; this does not reissue requests. -/
theorem BytePublicationTrace.at_final {initial final : ArchivePublication.Output} {before after : ByteStore}
    (roundtrip : ∀ value bytes, ETF.encode value = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok decoded ∧ ValueSemantics.Equivalent value decoded)
    (trace : BytePublicationTrace initial before final after) :
    ArchivePublication.Execution initial after.objects final after.objects := by
  induction trace with
  | done => exact .done _ _
  | respond primitive tail ih =>
    exact .step ((primitive.primitive roundtrip).in_extension tail.extension.objects) ih
  | interleave _ _ ih => exact ih

theorem BytePublicationTrace.resident {versions : VersionBytes} {initial final : ArchivePublication.Output}
    {before after : ByteStore} {hot : HotStore} {captured : List CapturedRevision}
    (trace : BytePublicationTrace initial before final after) {past : List ByteResidentWorld}
    (prior : ByteResidentReachable versions ⟨hot, before, captured⟩ past) :
    ∃ nextPast, ByteResidentReachable versions ⟨hot, after, captured⟩ nextPast := by
  induction trace generalizing past with
  | done => exact ⟨past, prior⟩
  | respond primitive _ ih => exact ih (.next prior primitive.resident)
  | interleave absent _ ih => exact ih (.next prior (.create absent))

theorem BytePublicationTrace.staging {before after : ByteStore} {cursor : Revision.Cursor}
    {next : PendingRevision.Cursor} {records : List Term} {ceiling line : Int}
    {final : ArchivePublication.Output} {event : Term}
    (roundtrip : ∀ value bytes, ETF.encode value = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok decoded ∧ ValueSemantics.Equivalent value decoded)
    (window : StorageQuery.archiveWindow cursor.candidate.working [] =
      .ok (.tuple [a "ok", list records, i ceiling], [])) (positive : line > 0)
    (trace : BytePublicationTrace (ArchivePublication.start cursor.candidate.working (i line)) before final after)
    (emitted : final.2 = .tuple [a "advance", event])
    (written : PendingRevision.Execution
      (PendingRevision.resident (some cursor.candidate.pack) (a "write") (.tuple [list [event], nil])) next) :
    Staging after.objects cursor after.objects (.pending next) :=
  .archive window positive (trace.at_final roundtrip) emitted written

end VerifiedKernel.Session.WorkConservation.CurrentExecution
