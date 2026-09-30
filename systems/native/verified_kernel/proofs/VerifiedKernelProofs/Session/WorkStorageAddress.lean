import VerifiedKernelProofs.Session.WorkPhysicalInput
import VerifiedKernelProofs.Session.WorkCurrentStorage

namespace VerifiedKernel.Session.StorageAddress
open Data WorkConservation
set_option Elab.async false

theorem agreed_key {state objectKey : Term} {agent session : ByteArray}
    (owner : state.get (a "agent_id") = .binary agent)
    (identified : state.get (a "session_id") = .binary session)
    (accepted : agrees state objectKey = true) : objectKey = key agent session := by
  simp only [agrees, owner, identified] at accepted
  exact beq_binary_right accepted

end VerifiedKernel.Session.StorageAddress

namespace VerifiedKernel.Session.StorageCommit
open Data WorkConservation
set_option Elab.async false

theorem prepared_address {state key base request : Term} {journal rest : List Term}
    (call : prepare state (.tuple [key, base]) journal = .ok (request, rest)) :
    StorageAddress.agrees state key = true := storage_commit_address call

end VerifiedKernel.Session.StorageCommit

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

/-- Actual CAS supplies the storage premise for a pure native episode. -/
def InputEpisode.with_cas {context : Context} {entry born checkpoint : Term} {before after : HotStore}
    (episode : InputEpisode context entry born checkpoint)
    (cas : HotCAS before (.tuple [a "cas", episode.requestedKey, episode.requestedBytes, episode.requestedBase])
      episode.result after) : InputCommitTrace context entry born checkpoint after.current :=
  { toInputEpisode := episode, primitive := cas.snapshot_meaning }

/-- The actual encoded request fixes the key and CAS base. The host's key is not a scope assumption. -/
theorem InputCommitTrace.scoped_address {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {context : Context} {entry born checkpoint : Term} {sealed : List Term} {durable : HotSnapshots}
    (trace : InputCommitTrace context entry born checkpoint durable)
    (history : PhysicalHistory framing objects owner session context.candidate.working sealed) :
    trace.key = StorageAddress.key owner session ∧ trace.requestedKey = trace.key ∧
      trace.requestedBase = trace.staged.etag := by
  obtain ⟨_, stampedHistory, _⟩ := trace.physical_history history
  have encoded := trace.encoded
  unfold fencingCursor at encoded
  rw [encode_captured] at encoded
  obtain ⟨_, inner, _⟩ := accept_fence_cas_capture encoded
  obtain ⟨_, _, started⟩ := RevisionFence.encode_capture inner
  obtain ⟨_, prepared⟩ := StorageCommit.start_capture started
  have addressed := StorageAddress.agreed_key stampedHistory.invariant.owned stampedHistory.invariant.identified
    (StorageCommit.prepared_address prepared)
  obtain ⟨_, bytes, _, _, _, requestEq, _⟩ := storage_commit_candidate prepared
  have fields : trace.requestedKey = trace.key ∧ trace.requestedBytes = .binary bytes ∧
      trace.requestedBase = trace.staged.etag := by
    simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using requestEq
  exact ⟨addressed, fields.1, fields.2.2⟩

end VerifiedKernel.Session.CommandDriver
