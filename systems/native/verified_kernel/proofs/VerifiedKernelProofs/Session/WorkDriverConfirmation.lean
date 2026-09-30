import VerifiedKernelProofs.Session.WorkDriverRawMetadata
import VerifiedKernelProofs.Session.WorkDriverRawAdmission

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

def inputNotification (state etag : Term) (events : List Term) : Output :=
  (some (.tuple [a "session_command_driver_effect", (Revision.Cursor.committed state etag).pack,
    b "input_notified", .tuple [a "notify", b "input_accepted", list events]]),
    .tuple [a "effect", .tuple [a "notify", b "input_accepted", list events]])

theorem input_notifies_captured (state etag : Term) (events : List Term) :
    resident (some (.tuple [a "session_command_driver_confirmed", (Revision.Cursor.committed state etag).pack,
      inputFenceContinuation events])) (a "next") nil = inputNotification state etag events := rfl

theorem input_notification_returns (state etag : Term) (events : List Term)
    (response : DurableConfirmation.Result) :
    resident (inputNotification state etag events).1 (a "effect_result") response.wire =
      (some (Revision.Cursor.committed state etag).pack,
        .tuple [a "return", .tuple [a "ok", a "committed"], nil]) := by
  cases response <;> rfl

/-- The native input prefix through encoding. It does not require a CAS reply. -/
structure InputSubmission (context : Context) (entry born checkpoint : Term) where
  observations : List Term
  events : List Term
  writeCursor : Term
  staged : PendingRevision.Cursor
  key : Term
  prepareObservations : List Term
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
  admission : AdmissionTrace
    (resident (some context.pack) (a "start")
      (.tuple [.tuple [a "input", .tuple [entry, born], checkpoint], list observations]))
    (some writeCursor, .tuple [a "validate_write", list events])
  write : BatchTrace (resident (some writeCursor) (a "write_result") (a "ok")) (inputFenced staged events)
  preparation : ObservationTrace
    (resident (inputFenced staged events).1 (a "fence_start") (.tuple [key, list prepareObservations]))
    (some (fencingCursor (.pending staged) (inputFenceContinuation events)
      (RevisionFence.prepared staged key preparedState)), .tuple [a "prepared"])
  metadata : BatchTrace
    (resident (some (fencingCursor (.pending staged) (inputFenceContinuation events)
      (RevisionFence.prepared staged key preparedState))) (a "stamp")
      (.tuple [token, reasons, activity, revision, flush, epoch, node]))
    (some (fencingCursor (.pending staged) (inputFenceContinuation events) (stampedFence staged key stamped)),
      .tuple [a "stamped"])
  encoded : resident (some (fencingCursor (.pending staged) (inputFenceContinuation events)
    (stampedFence staged key stamped))) (a "encode") nil =
    (some casCursor, .tuple [a "cas", requestedKey, requestedBytes, requestedBase])

/-- A finite successful native input execution, including the actual CAS reply. -/
structure InputEpisode (context : Context) (entry born checkpoint : Term)
    extends InputSubmission context entry born checkpoint where
  result : Term
  confirmed : Term
  resumed : resident (some casCursor) (a "cas_result") result = (some confirmed, .tuple [a "committed"])

structure InputCommitTrace (context : Context) (entry born checkpoint : Term)
    (durable : ArchivePublication.HotSnapshots) extends InputEpisode context entry born checkpoint where
  primitive : ArchivePublication.SnapshotCASMeaning
    (.tuple [a "cas", requestedKey, requestedBytes, requestedBase]) result durable

/-- Native trace composition derives both the full input fact and the exact notification from the initial command. -/
theorem InputCommitTrace.confirms_same_input {context : Context} {entry born checkpoint : Term}
    {durable : ArchivePublication.HotSnapshots} {source : ByteArray}
    (trace : InputCommitTrace context entry born checkpoint durable)
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source)
    (ready : QueueReady context.candidate.working)
    (format : context.candidate.working.get (a "storage_format") = i 3) :
    trace.staged.baseline = context.candidate.baseline ∧ trace.staged.etag = context.candidate.etag ∧
      ∃ etag snapshot event now first last item,
        durable trace.key etag snapshot ∧ QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
        Command.inputEvent (context.candidate.working.get (a "session_id")) (.binary source)
          (RoundQuery.atomFirst entry "payload") now first = .ok (event, last) ∧
        MainInputFact event source item ∧ CanonicalQueueItem item ∧
        (∀ sealed, ValueSemantics.Represented snapshot sealed item) ∧
        (∀ sealed old, ValueSemantics.Represented context.candidate.working sealed old →
          ValueSemantics.Represented snapshot sealed old) ∧
        resident (some trace.confirmed) (a "next") nil = inputNotification trace.stamped etag trace.events ∧
        (∀ response : DurableConfirmation.Result,
          resident (inputNotification trace.stamped etag trace.events).1 (a "effect_result") response.wire =
            (some (Revision.Cursor.committed trace.stamped etag).pack,
              .tuple [a "return", .tuple [a "ok", a "committed"], nil])) := by
  obtain ⟨journal, result, rest, input, started, write⟩ :=
    input_raw_admission_applied (input_admission_reflect trace.admission) trace.write
  have preparation := input_raw_fence_prepared trace.preparation
  have metadata := input_raw_fence_stamped trace.metadata
  obtain ⟨baselineEq, etagEq, etag, snapshot, event, now, first, last, item,
    confirmed, stored, snapshotReady, snapshotFormat, generated, fact, canonical, present, preserved⟩ :=
    input_confirmation_durable sourceValue ready format input started write preparation metadata
      trace.encoded trace.primitive trace.resumed
  refine ⟨baselineEq, etagEq, etag, snapshot, event, now, first, last, item,
    stored, snapshotReady, snapshotFormat, generated, fact, canonical, present, preserved, ?_, ?_⟩
  · rw [confirmed]
    exact input_notifies_captured _ _ _
  · exact input_notification_returns _ _ _

end VerifiedKernel.Session.CommandDriver
