import VerifiedKernelProofs.Session.WorkCurrentFence
import VerifiedKernelProofs.Session.WorkPhysicalInputPreservation
import VerifiedKernelProofs.Session.WorkPhysicalWrite
import VerifiedKernelProofs.Session.WorkInputTermPending

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

def InputSubmission.fence {context : Context} {entry born checkpoint : Term}
    (trace : InputSubmission context entry born checkpoint) :
    WriteSubmission trace.staged (inputFenceContinuation trace.events) :=
  { key := trace.key, observations := trace.prepareObservations, preparedState := trace.preparedState,
    token := trace.token, reasons := trace.reasons, activity := trace.activity, revision := trace.revision,
    flush := trace.flush, epoch := trace.epoch, node := trace.node, stamped := trace.stamped,
    casCursor := trace.casCursor, requestedKey := trace.requestedKey, requestedBytes := trace.requestedBytes,
    requestedBase := trace.requestedBase, preparation := trace.preparation, metadata := trace.metadata,
    encoded := trace.encoded }

def WriteEpisode.with_cas {cursor : PendingRevision.Cursor} {continuation : Term} {before after : HotStore}
    (episode : WriteEpisode cursor continuation)
    (cas : HotCAS before (.tuple [a "cas", episode.requestedKey, episode.requestedBytes, episode.requestedBase])
      episode.result after) : WriteCommitTrace cursor continuation after.current :=
  { toWriteEpisode := episode, primitive := cas.snapshot_meaning }

theorem WriteSubmission.current_facts {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {cursor : PendingRevision.Cursor} {continuation result : Term} {sealed : List Term} {before after : HotStore}
    (trace : WriteSubmission cursor continuation)
    (history : PhysicalHistory framing objects owner session cursor.working sealed)
    (cas : HotCAS before (.tuple [a "cas", trace.requestedKey, trace.requestedBytes, trace.requestedBase]) result after) :
    trace.key = StorageAddress.key owner session ∧ ∃ etag snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      (.tuple [a "cas", trace.requestedKey, trace.requestedBytes, trace.requestedBase] : Term) =
        .tuple [a "cas", trace.key, .binary bytes, cursor.etag] ∧
      after.current trace.key etag snapshot ∧ PhysicalHistory framing objects owner session snapshot sealed ∧
      ∀ item, PhysicalIdentityFact objects cursor.working (.work item) → PhysicalIdentityFact objects snapshot (.work item) := by
  have encoded := trace.encoded
  unfold fencingCursor at encoded
  rw [encode_captured] at encoded
  obtain ⟨saved, inner, _⟩ := accept_fence_cas_capture encoded
  obtain ⟨addressed, etag, snapshot, bytes, encoding, requestEq, stored, snapshotHistory, _, kept⟩ :=
    RevisionFence.candidate_current_facts history (raw_fence_prepared trace.preparation)
      (raw_fence_stamped trace.metadata) inner cas
  exact ⟨addressed, etag, snapshot, bytes, encoding, requestEq, stored, snapshotHistory, kept⟩

theorem InputSubmission.staged_physical {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {context : Context} {entry born checkpoint source : Term} {sealed : List Term}
    (trace : InputSubmission context entry born checkpoint)
    (history : PhysicalHistory framing objects owner session context.candidate.working sealed)
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = source) :
    trace.staged.baseline = context.candidate.baseline ∧ trace.staged.etag = context.candidate.etag ∧
      PhysicalHistory framing objects owner session trace.staged.working sealed ∧
      ∃ event now first last item,
        Command.inputEvent (context.candidate.working.get (a "session_id")) source
          (RoundQuery.atomFirst entry "payload") now first = .ok (event, last) ∧
        MainTermInputFact event source item ∧ CanonicalQueueItem item ∧
        PhysicalIdentityFact objects trace.staged.working (.work item) ∧
        ∀ old, PhysicalIdentityFact objects context.candidate.working (.work old) →
          PhysicalIdentityFact objects trace.staged.working (.work old) := by
  obtain ⟨journal, result, rest, input, started, write⟩ :=
    input_raw_admission_applied (input_admission_reflect trace.admission) trace.write
  have pendingWrite := Revision.execution_pending write
  rw [Revision.write_captured] at pendingWrite
  have stagedHistory := PendingRevision.input_write_physical_history history input started pendingWrite
  obtain ⟨baselineEq, etagEq, _, _, _, _, event, now, first, last, item, generated, fact, canonical, present⟩ :=
    PendingRevision.input_term_write_preserves sourceValue history.invariant.history.invariant.ready input started pendingWrite
  exact ⟨baselineEq, etagEq, stagedHistory, event, now, first, last, item, generated, fact, canonical,
    identity_fact_physical stagedHistory.invariant.images (present sealed),
    PendingRevision.input_write_physical_preserves history input started pendingWrite⟩

/-- The actual input candidate contains its work even if the CAS reply never reaches the caller. -/
theorem InputSubmission.current_facts {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {context : Context} {entry born checkpoint result source : Term} {sealed : List Term} {before after : HotStore}
    (trace : InputSubmission context entry born checkpoint)
    (history : PhysicalHistory framing objects owner session context.candidate.working sealed)
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = source)
    (cas : HotCAS before (.tuple [a "cas", trace.requestedKey, trace.requestedBytes, trace.requestedBase]) result after) :
    trace.key = StorageAddress.key owner session ∧ ∃ etag snapshot bytes event now first last item,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      (.tuple [a "cas", trace.requestedKey, trace.requestedBytes, trace.requestedBase] : Term) =
        .tuple [a "cas", trace.key, .binary bytes, context.candidate.etag] ∧
      after.current trace.key etag snapshot ∧ PhysicalHistory framing objects owner session snapshot sealed ∧
      Command.inputEvent (context.candidate.working.get (a "session_id")) source
        (RoundQuery.atomFirst entry "payload") now first = .ok (event, last) ∧
      MainTermInputFact event source item ∧ CanonicalQueueItem item ∧ PhysicalIdentityFact objects snapshot (.work item) ∧
      ∀ old, PhysicalIdentityFact objects context.candidate.working (.work old) → PhysicalIdentityFact objects snapshot (.work old) := by
  obtain ⟨_, etagEq, stagedHistory, event, now, first, last, item, generated, fact, canonical, present, oldKept⟩ :=
    trace.staged_physical history sourceValue
  have encoded := trace.encoded
  unfold fencingCursor at encoded
  rw [encode_captured] at encoded
  obtain ⟨saved, inner, _⟩ := accept_fence_cas_capture encoded
  obtain ⟨addressed, etag, snapshot, bytes, encoding, requestEq, stored, snapshotHistory, _, kept⟩ :=
    RevisionFence.candidate_current_facts stagedHistory (input_raw_fence_prepared trace.preparation)
      (input_raw_fence_stamped trace.metadata) inner cas
  rw [etagEq] at requestEq
  exact ⟨addressed, etag, snapshot, bytes, event, now, first, last, item, encoding, requestEq, stored, snapshotHistory,
    generated, fact, canonical, kept item present, fun old prior => kept old (oldKept old prior)⟩

end VerifiedKernel.Session.CommandDriver
