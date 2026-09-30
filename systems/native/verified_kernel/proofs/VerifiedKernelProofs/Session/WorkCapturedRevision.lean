import VerifiedKernelProofs.Session.WorkRetainedStaging

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication CommandDriver
set_option Elab.async false

/-- A proof projection of a captured native revision, not a runtime registry. -/
structure CapturedRevision where
  owner : ByteArray
  session : ByteArray
  cursor : Revision.Cursor

def CapturedRevision.key (captured : CapturedRevision) : Term := StorageAddress.key captured.owner captured.session

/-- This transfer property is an inductive invariant, derived at actual reads and landed fences. -/
def CapturedRevision.Valid (framing : CodecFraming) (objects : Objects) (versions : VersionBytes)
    (captured : CapturedRevision) : Prop :=
  (∃ sealed, PhysicalHistory framing objects captured.owner captured.session captured.cursor.candidate.working sealed) ∧
  ∀ extended, ObjectsExtend objects extended → ∀ before after : HotStore, ∀ bytes : ByteArray, ∀ result : Term,
    before.versioned versions →
    HotCAS before (.tuple [a "cas", captured.key, .binary bytes, captured.cursor.candidate.etag]) result after →
    ∀ fact, before.fact extended captured.key fact →
      PhysicalIdentityFact extended captured.cursor.candidate.working fact

theorem CapturedRevision.Valid.objects {framing : CodecFraming} {objects extended : Objects}
    {versions : VersionBytes} {captured : CapturedRevision}
    (valid : captured.Valid framing objects versions) (extension : ObjectsExtend objects extended) :
    captured.Valid framing extended versions := by
  obtain ⟨⟨sealed, history⟩, transfer⟩ := valid
  exact ⟨⟨sealed, history.objects extension⟩,
    fun later next => transfer later (fun key records h => next key records (extension key records h))⟩

def capturedRead {store : HotStore} (read : ReadCall store) : CapturedRevision :=
  ⟨read.agent, read.session, read.context⟩

theorem captured_read_valid {framing : CodecFraming} {objects : Objects} {versions : VersionBytes}
    {store : HotStore} (read : ReadCall store) (codec : SnapshotCodec)
    (lineage : store.lineage framing objects) (versioned : store.versioned versions) :
    (capturedRead read).Valid framing objects versions := by
  obtain ⟨sealed, history, token⟩ := read.history lineage codec
  refine ⟨⟨sealed, history⟩, ?_⟩
  intro extended extension before after bytes result currentVersioned cas fact present
  have address := (SessionDomain.ReadRevision.start_captured read.started).1
  change read.objectKey = StorageAddress.key read.agent read.session at address
  change HotCAS before (.tuple [a "cas", StorageAddress.key read.agent read.session,
    .binary bytes, read.context.candidate.etag]) result after at cas
  rw [← address, token] at cas
  change before.fact extended (StorageAddress.key read.agent read.session) fact at present
  rw [← address] at present
  exact read.current_fact (HotStore.lineage_objects lineage extension) codec versioned currentVersioned cas fact present

theorem retained_captured_valid {framing : CodecFraming} {objects : Objects} {versions : VersionBytes}
    {store : HotStore} {owner session bytes : ByteArray} {state snapshot key etag : Term}
    {sealed journal rest : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (persisted : Lifecycle.persistable state journal = .ok (snapshot, rest))
    (encoded : ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes)
    (stored : HotRead store key bytes etag) (presentToken : etag ≠ nil)
    (address : key = StorageAddress.key owner session) (versioned : store.versioned versions)
    (codec : SnapshotCodec) :
    (CapturedRevision.mk owner session (.committed state etag)).Valid framing objects versions := by
  refine ⟨⟨sealed, history⟩, ?_⟩
  intro extended extension before after newBytes result currentVersioned cas fact present
  change HotCAS before (.tuple [a "cas", StorageAddress.key owner session, .binary newBytes, etag]) result after at cas
  change before.fact extended (StorageAddress.key owner session) fact at present
  rw [← address] at cas present
  exact HotCAS.retained_fact (history.objects extension) persisted encoded stored presentToken
    versioned currentVersioned codec cas fact present

theorem CapturedRevision.Valid.landed {framing : CodecFraming} {objects nextObjects : Objects}
    {versions : VersionBytes} {before after : HotStore} {captured : CapturedRevision}
    {next : Revision.Cursor} {continuation result : Term}
    (valid : captured.Valid framing objects versions)
    (staging : Staging objects captured.cursor nextObjects next)
    (write : WriteSubmission next.candidate continuation) (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (lineage : before.lineage framing objects) (versioned : before.versioned versions)
    (cas : HotCAS before (.tuple [a "cas", write.requestedKey, write.requestedBytes, write.requestedBase]) result after) :
    after.lineage framing nextObjects ∧ ObjectsExtend objects nextObjects ∧
      ∀ key fact, before.fact objects key fact → after.fact nextObjects key fact := by
  obtain ⟨sealed, history⟩ := valid.1
  obtain ⟨token, extension, nextSealed, nextHistory, staged⟩ := staging.identities history
  obtain ⟨address, etag, snapshot, bytes, encoded, issued, stored, snapshotHistory, kept⟩ :=
    write.current_identities nextHistory cas
  rw [address, token] at issued
  have applied : HotCAS before
      (.tuple [a "cas", captured.key, .binary bytes, captured.cursor.candidate.etag]) result after := by
    rwa [issued] at cas
  rw [address] at stored
  refine ⟨applied.lineage (HotStore.lineage_objects lineage extension) rfl encoded snapshotHistory, extension, ?_⟩
  intro key fact present
  by_cases same : key = captured.key
  · subst key
    obtain ⟨decoded, decoding⟩ := roundtrip snapshot bytes encoded
    exact HotStore.current_fact snapshotHistory stored encoded decoding (codec _ _ _ encoded decoding)
      (kept fact (staged fact (valid.2 objects (fun _ _ h => h) before after bytes result versioned applied fact present)))
  · exact applied.other_fact same (HotStore.fact_objects extension present)

theorem landed_captured_valid {framing : CodecFraming} {objects : Objects} {versions : VersionBytes}
    {before after : HotStore} {owner session : ByteArray} {cursor : PendingRevision.Cursor}
    {continuation etag outcome : Term} {sealed : List Term}
    (write : WriteSubmission cursor continuation)
    (history : PhysicalHistory framing objects owner session cursor.working sealed)
    (cas : HotCAS before (.tuple [a "cas", write.requestedKey, write.requestedBytes, write.requestedBase])
      (.tuple [a "ok", etag, outcome]) after)
    (presentToken : etag ≠ nil) (tokens : after.versioned versions) (codec : SnapshotCodec) :
    (CapturedRevision.mk owner session (.committed write.stamped etag)).Valid framing objects versions := by
  obtain ⟨stampedHistory, snapshot, bytes, journal, rest, persisted, encoded, stored⟩ :=
    write.retained_origin history cas
  obtain ⟨address, _⟩ := write.current_identities history cas
  exact retained_captured_valid stampedHistory persisted encoded stored presentToken address tokens codec

end VerifiedKernel.Session.WorkConservation.CurrentExecution
