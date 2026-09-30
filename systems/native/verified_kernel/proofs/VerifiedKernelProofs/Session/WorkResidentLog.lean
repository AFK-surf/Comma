import VerifiedKernelProofs.Session.WorkResidentTrace
import VerifiedKernelProofs.Session.WorkLogWrite

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication CommandDriver
set_option Elab.async false

/-- The log return names the original physical fact, including nonbinary-key retries. -/
theorem resident_log_confirmation {framing : CodecFraming} {versions : VersionBytes}
    {before current : ResidentWorld} {past : List ResidentWorld} {after : HotStore}
    {captured : CapturedRevision} {entry checkpoint saved continuation outcome : Term}
    {observations events : List Term} {staged : PendingRevision.Cursor} {etag : ByteArray}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (prior : ResidentReachable versions before past) (member : captured ∈ before.captured)
    (admission : AdmissionTrace
      (CommandDriver.resident (some captured.cursor.pack) (a "start")
        (.tuple [.tuple [a "log", entry, checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list events]))
    (write : BatchTrace (CommandDriver.resident (some saved) (a "write_result") (a "ok"))
      (writeFenced staged continuation))
    (episode : WriteEpisode staged continuation)
    (reply : episode.result = .tuple [a "ok", .binary etag, outcome])
    (cas : HotCAS before.store.hot
      (.tuple [a "cas", episode.requestedKey, episode.requestedBytes, episode.requestedBase]) episode.result after)
    (tokens : after.versioned versions)
    (later : ResidentTrace versions
      (committedWorld before after before.store.objects captured.owner captured.session episode.stamped (.binary etag)) current) :
    (∃ history, ResidentReachable versions current history) ∧
    ∃ now fact committed,
      LogFactOrigin (logEvent (captured.cursor.candidate.working.get (a "session_id")) entry now) fact ∧
      current.store.fact captured.key fact ∧
      CommandDriver.resident (some episode.confirmed) (a "next") nil =
        (some (Revision.Cursor.committed episode.stamped committed).pack,
          .tuple [a "return", .tuple [a "ok", a "committed"], nil]) := by
  have valid := (prior.conservation (framing := framing) codec roundtrip).1
  obtain ⟨sealed, history⟩ := (valid.2.2 captured member).1
  obtain ⟨continuationEq, stagedHistory, now, fact, origin, physical⟩ := log_raw_write_fact history admission write
  subst continuation
  have committedCAS := cas
  rw [reply] at committedCAS
  have step : ResidentStep versions before
      (committedWorld before after before.store.objects captured.owner captured.session episode.stamped (.binary etag)) :=
    .commit member (.log admission write) episode.toWriteSubmission committedCAS tokens
  have landedValid := (step.invariant codec roundtrip valid).1
  obtain ⟨address, token, snapshot, bytes, encoded, _, stored, snapshotHistory, kept⟩ :=
    episode.toWriteSubmission.current_identities stagedHistory cas
  obtain ⟨decoded, decoding⟩ := roundtrip snapshot bytes encoded
  have landed := HotStore.current_fact snapshotHistory stored encoded decoding
    (codec _ _ _ encoded decoding) (kept fact physical)
  rw [address] at landed
  have currentFact := (later.preserves codec roundtrip landedValid).2 captured.key fact landed
  obtain ⟨confirmedToken, _, _, confirmed, _, _, _, _⟩ :=
    issued_confirmation episode.encoded cas.snapshot_meaning episode.resumed
  refine ⟨later.reachable (.next prior step), now, fact, confirmedToken, origin, currentFact, ?_⟩
  rw [confirmed]
  rfl

end VerifiedKernel.Session.WorkConservation.CurrentExecution
