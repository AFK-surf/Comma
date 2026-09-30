import VerifiedKernelProofs.Session.WorkCurrentRecordFence

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

theorem HotCAS.landed_read {before after : HotStore} {key base etag outcome : Term} {bytes : ByteArray}
    (cas : HotCAS before (.tuple [a "cas", key, .binary bytes, base]) (.tuple [a "ok", etag, outcome]) after) :
    HotRead after key bytes etag := by
  cases cas
  simp [HotRead, HotStore.replace]

theorem persistable_physical_identity_iff {objects : Objects} {state snapshot : Term}
    {fact : IdentityFact} {journal rest : List Term}
    (persisted : Lifecycle.persistable state journal = .ok (snapshot, rest)) :
    PhysicalIdentityFact objects snapshot fact ↔ PhysicalIdentityFact objects state fact := by
  cases fact with
  | work item => exact persistable_physical_work_iff persisted
  | record reference =>
    have fields := persistable_work_fields persisted
    have catalog := (persistable_archive_fields persisted).1
    have owner : snapshot.get (a "agent_id") = state.get (a "agent_id") := persistable_owner persisted
    have session := (persistable_queue_frame persisted).2.2.2.1
    simp only [PhysicalIdentityFact, ContainsRecord, fields.2, catalog, owner, session]

/-- A retained cursor uses the bytes written by its earlier CAS. Its volatile fields need not equal the snapshot. -/
theorem HotCAS.retained_fact {framing : CodecFraming} {objects : Objects}
    {observed before after : HotStore} {versions : VersionBytes} {owner session bytes newBytes : ByteArray}
    {key etag state snapshot result : Term} {sealed journal rest : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (persisted : Lifecycle.persistable state journal = .ok (snapshot, rest))
    (encoded : ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes)
    (stored : HotRead observed key bytes etag)
    (presentToken : etag ≠ nil)
    (observedVersioned : observed.versioned versions) (currentVersioned : before.versioned versions)
    (codec : SnapshotCodec)
    (cas : HotCAS before (.tuple [a "cas", key, .binary newBytes, etag]) result after) :
    ∀ fact, before.fact objects key fact → PhysicalIdentityFact objects state fact := by
  intro fact present
  obtain ⟨currentEtag, currentBytes, decoded, read, decoding, physical⟩ := present
  have actual := HotCAS.read_base_bytes observedVersioned currentVersioned stored presentToken cas
  have same := Option.some.inj (actual.symm.trans read)
  have bytesEq := congrArg HotObject.bytes same
  change bytes = currentBytes at bytesEq
  subst currentBytes
  have equivalent := codec snapshot bytes decoded encoded decoding
  have snapshotHistory := history.persist persisted
  have decodedHistory := snapshotHistory.decode decoding equivalent
  exact (persistable_physical_identity_iff persisted).mp
    (decodedHistory.decode_identity equivalent.symm physical)

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

/-- The stamped resident cursor and the stored snapshot come from the same actual fence, before any reply. -/
theorem WriteSubmission.retained_origin {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {cursor : PendingRevision.Cursor} {continuation etag outcome : Term} {sealed : List Term} {before after : HotStore}
    (trace : WriteSubmission cursor continuation)
    (history : PhysicalHistory framing objects owner session cursor.working sealed)
    (cas : HotCAS before (.tuple [a "cas", trace.requestedKey, trace.requestedBytes, trace.requestedBase])
      (.tuple [a "ok", etag, outcome]) after) :
    PhysicalHistory framing objects owner session trace.stamped sealed ∧
      ∃ snapshot bytes journal rest,
        Lifecycle.persistable trace.stamped journal = .ok (snapshot, rest) ∧
        ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
        HotRead after trace.key bytes etag := by
  have encoded := trace.encoded
  unfold fencingCursor at encoded
  rw [encode_captured] at encoded
  obtain ⟨saved, inner, _⟩ := accept_fence_cas_capture encoded
  obtain ⟨stampedHistory, snapshot, bytes, rest, persisted, encoding, issued, _⟩ :=
    RevisionFence.candidate_encoded_history history (raw_fence_prepared trace.preparation)
      (raw_fence_stamped trace.metadata) inner
  have applied : HotCAS before (.tuple [a "cas", trace.key, .binary bytes, cursor.etag])
      (.tuple [a "ok", etag, outcome]) after := by
    rwa [issued] at cas
  exact ⟨stampedHistory, snapshot, bytes, _, rest, persisted, encoding, applied.landed_read⟩

end VerifiedKernel.Session.CommandDriver
