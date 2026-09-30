import VerifiedKernelProofs.Session.WorkProductRefinement

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication CommandDriver
set_option Elab.async false

theorem resident_log_refinement {framing : CodecFraming} {versions : VersionBytes}
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
      ConfirmationRefines current.store ⟨captured.key, fact⟩ ∧
      CommandDriver.resident (some episode.confirmed) (a "next") nil =
        (some (Revision.Cursor.committed episode.stamped committed).pack,
          .tuple [a "return", .tuple [a "ok", a "committed"], nil]) := by
  obtain ⟨⟨history, execution⟩, now, fact, token, origin, backed, returned⟩ :=
    resident_log_confirmation (framing := framing) codec roundtrip prior member admission write episode reply cas tokens later
  exact ⟨⟨history, execution⟩, now, fact, token, origin, backed,
    matching_confirmation_refines (framing := framing) codec roundtrip execution backed, returned⟩

theorem resident_input_refinement {framing : CodecFraming} {versions : VersionBytes}
    {before current : ResidentWorld} {past : List ResidentWorld} {after : HotStore}
    {captured : CapturedRevision} {entry born checkpoint outcome : Term} {source etag : ByteArray}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (prior : ResidentReachable versions before past) (member : captured ∈ before.captured)
    (episode : InputEpisode captured.cursor entry born checkpoint)
    (reply : episode.result = .tuple [a "ok", .binary etag, outcome])
    (cas : HotCAS before.store.hot
      (.tuple [a "cas", episode.requestedKey, episode.requestedBytes, episode.requestedBase]) episode.result after)
    (tokens : after.versioned versions)
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source)
    (later : ResidentTrace versions
      (committedWorld before after before.store.objects captured.owner captured.session episode.stamped (.binary etag)) current) :
    (∃ history, ResidentReachable versions current history) ∧
    ∃ event now first last item committed,
      Command.inputEvent (captured.cursor.candidate.working.get (a "session_id")) (.binary source)
        (RoundQuery.atomFirst entry "payload") now first = .ok (event, last) ∧
      MainInputFact event source item ∧ CanonicalQueueItem item ∧
      current.store.work captured.key item ∧
      ConfirmationRefines current.store ⟨captured.key, .work item⟩ ∧
      CommandDriver.resident (some episode.confirmed) (a "next") nil =
        inputNotification episode.stamped committed episode.events ∧
      (∀ response : DurableConfirmation.Result,
        CommandDriver.resident (inputNotification episode.stamped committed episode.events).1 (a "effect_result") response.wire =
          (some (Revision.Cursor.committed episode.stamped committed).pack,
            .tuple [a "return", .tuple [a "ok", a "committed"], nil])) := by
  obtain ⟨⟨history, execution⟩, event, now, first, last, item, token,
    generated, fact, canonical, backed, notified, returned⟩ :=
    resident_input_confirmation (framing := framing) codec roundtrip prior member episode reply cas tokens sourceValue later
  exact ⟨⟨history, execution⟩, event, now, first, last, item, token, generated, fact, canonical, backed,
    matching_confirmation_refines (framing := framing) codec roundtrip execution backed, notified, returned⟩

theorem resident_duplicate_refinement {framing : CodecFraming} {versions : VersionBytes}
    {before current : ResidentWorld} {past : List ResidentWorld} {captured : CapturedRevision}
    {source : ByteArray} {entry born checkpoint saved confirmed args : Term} {observations : List Term}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (prior : ResidentReachable versions before past) (member : captured ∈ before.captured)
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source)
    (admission : AdmissionTrace
      (CommandDriver.resident (some captured.cursor.pack) (a "start")
        (.tuple [.tuple [a "input", .tuple [entry, born], checkpoint], list observations]))
      (some saved, .tuple [a "fence"]))
    (fence : CommandDriver.resident (some saved) (a "fence_clean") args = (some confirmed, .tuple [a "committed"]))
    (later : ResidentTrace versions before current) :
    (∃ event fact, IdentityFactOrigin event source fact ∧ current.store.fact captured.key fact ∧
      ConfirmationRefines current.store ⟨captured.key, fact⟩) ∧
      CommandDriver.resident (some confirmed) (a "next") nil =
        (some captured.cursor.pack, .tuple [a "return", .tuple [a "ok", a "duplicate"], nil]) := by
  obtain ⟨⟨event, fact, origin, backed⟩, returned⟩ :=
    resident_duplicate_confirmation (framing := framing) codec roundtrip prior member sourceValue admission fence later
  obtain ⟨history, execution⟩ := later.reachable prior
  exact ⟨⟨event, fact, origin, backed,
    matching_confirmation_refines (framing := framing) codec roundtrip execution backed⟩, returned⟩

end VerifiedKernel.Session.WorkConservation.CurrentExecution
