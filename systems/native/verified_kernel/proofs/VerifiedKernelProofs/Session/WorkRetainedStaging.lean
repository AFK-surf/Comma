import VerifiedKernelProofs.Session.WorkRetainedCursor
import VerifiedKernelProofs.Session.WorkStagedExecution

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication CommandDriver
set_option Elab.async false

theorem Staging.retained_landed {framing : CodecFraming} {objects nextObjects : Objects}
    {observed before after : HotStore} {versions : VersionBytes} {owner session bytes : ByteArray}
    {state snapshot key etag continuation result : Term} {sealed journal rest : List Term} {next : Revision.Cursor}
    (history : PhysicalHistory framing objects owner session state sealed)
    (persisted : Lifecycle.persistable state journal = .ok (snapshot, rest))
    (encoded : ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes)
    (stored : HotRead observed key bytes etag) (presentToken : etag ≠ nil)
    (address : key = StorageAddress.key owner session)
    (staging : Staging objects (.committed state etag) nextObjects next)
    (write : WriteSubmission next.candidate continuation)
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (currentLineage : before.lineage framing objects)
    (observedVersioned : observed.versioned versions) (currentVersioned : before.versioned versions)
    (cas : HotCAS before
      (.tuple [a "cas", write.requestedKey, write.requestedBytes, write.requestedBase]) result after) :
    after.lineage framing nextObjects ∧ ObjectsExtend objects nextObjects ∧
      ∀ other fact, before.fact objects other fact → after.fact nextObjects other fact := by
  obtain ⟨stagedToken, extension, nextSealed, nextHistory, stageKept⟩ := staging.identities history
  obtain ⟨addressed, committed, nextSnapshot, nextBytes, nextEncoding, issued, current, snapshotHistory, kept⟩ :=
    write.current_identities nextHistory cas
  have sameKey : write.key = key := addressed.trans address.symm
  change next.candidate.etag = etag at stagedToken
  rw [sameKey, stagedToken] at issued
  have applied : HotCAS before (.tuple [a "cas", key, .binary nextBytes, etag]) result after := by
    rwa [issued] at cas
  rw [sameKey] at current
  refine ⟨applied.lineage (HotStore.lineage_objects currentLineage extension) address nextEncoding snapshotHistory,
    extension, ?_⟩
  intro other fact existing
  by_cases same : other = key
  · subst other
    obtain ⟨decoded, decoding⟩ := roundtrip nextSnapshot nextBytes nextEncoding
    apply HotStore.current_fact snapshotHistory current nextEncoding decoding (codec _ _ _ nextEncoding decoding)
    exact kept fact (stageKept fact (HotCAS.retained_fact history persisted encoded stored presentToken
      observedVersioned currentVersioned codec applied fact existing))
  · exact applied.other_fact same (HotStore.fact_objects extension existing)

end VerifiedKernel.Session.WorkConservation.CurrentExecution
