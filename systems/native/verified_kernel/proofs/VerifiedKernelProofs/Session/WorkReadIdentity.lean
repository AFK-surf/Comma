import VerifiedKernelProofs.Session.WorkReadRevision

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

theorem PhysicalHistory.normalized_identity_physical {framing : CodecFraming} {objects : Objects}
    {owner session bytes source : ByteArray} {snapshot decodedState loaded : Term} {sealed journal rest : List Term}
    (history : PhysicalHistory framing objects owner session snapshot sealed)
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
    (codec : ValueSemantics.Equivalent snapshot decodedState)
    (normalized : Lifecycle.normalize decodedState journal = .ok (loaded, rest))
    (present : IdentityPresent (loaded.get (a "input_dedupe")) (.binary source)) :
    PhysicalIdentitySupported objects snapshot source := by
  have logical := (history.decode decoded codec).invariant.history.invariant
  obtain ⟨live, _, read, _⟩ := logical.sorted
  obtain ⟨event, fact, origin, supported⟩ := normalize_identity_supported_before logical.ready read
    logical.header logical.supported normalized present
  exact identity_supported_physical history.invariant.images
    ⟨event, fact, origin, identity_fact_equivalent codec.symm supported⟩

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

/-- The duplicate return refers to a physical fact in the snapshot captured by the native read. -/
theorem read_duplicate_physical {framing : CodecFraming} {objects : Objects} {store : HotStore}
    {agent session bytes etag source : ByteArray}
    {snapshot decodedState pending objectKey cursor entry born checkpoint saved confirmed args : Term}
    {sealed readObservations observations : List Term}
    (history : PhysicalHistory framing objects agent session snapshot sealed)
    (current : store.current objectKey (.binary etag) snapshot)
    (started : SessionDomain.dispatch none (.tuple [i 1, a "session_read", i 1, a "start",
      .tuple [.binary agent, .binary session]]) =
      (some pending, SessionDomain.ReadRevision.response (.tuple [a "read", objectKey])))
    (read : HotRead store objectKey bytes (.binary etag))
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
    (codec : ValueSemantics.Equivalent snapshot decodedState)
    (loaded : SessionDomain.ReadRevision.LoadTrace
      (SessionDomain.dispatch (some pending) (.tuple [i 1, a "session_read", i 1, a "read_result",
        .tuple [.tuple [a "ok", .binary bytes, .binary etag], list readObservations]])) cursor)
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source)
    (admission : AdmissionTrace
      (resident (some cursor) (a "start")
        (.tuple [.tuple [a "input", .tuple [entry, born], checkpoint], list observations]))
      (some saved, .tuple [a "fence"]))
    (fence : resident (some saved) (a "fence_clean") args = (some confirmed, .tuple [a "committed"])) :
    objectKey = SessionDomain.ReadRevision.key agent session ∧
      PhysicalIdentitySupported objects snapshot source ∧
      resident (some confirmed) (a "next") nil =
        (some cursor, .tuple [a "return", .tuple [a "ok", a "duplicate"], nil]) := by
  obtain ⟨addressed, _, state, journal, rest, normalized, _, _, captured, _⟩ :=
    SessionDomain.ReadRevision.current_read_preserves history current started read decoded codec loaded
  rw [captured] at admission
  obtain ⟨savedEq, present⟩ := input_raw_duplicate sourceValue admission
  have fact := history.normalized_identity_physical decoded codec normalized present
  rw [savedEq] at fence
  obtain ⟨_, _, _, confirmedEq⟩ := clean_fence_capture fence
  refine ⟨addressed, fact, ?_⟩
  rw [confirmedEq, captured]
  exact duplicate_return_captured _ _

end VerifiedKernel.Session.CommandDriver
