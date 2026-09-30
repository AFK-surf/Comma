import VerifiedKernelProofs.Session.WorkResidentExecution

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication CommandDriver
set_option Elab.async false

inductive ResidentTrace (versions : VersionBytes) : ResidentWorld → ResidentWorld → Prop where
  | done (world : ResidentWorld) : ResidentTrace versions world world
  | next {before middle after : ResidentWorld}
      (step : ResidentStep versions before middle) (tail : ResidentTrace versions middle after) :
      ResidentTrace versions before after

theorem ResidentTrace.preserves {framing : CodecFraming} {versions : VersionBytes}
    {before after : ResidentWorld}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (valid : ResidentInvariant framing versions before) (trace : ResidentTrace versions before after) :
    ResidentInvariant framing versions after ∧
      ∀ key fact, before.store.fact key fact → after.store.fact key fact := by
  induction trace with
  | done => exact ⟨valid, fun _ _ h => h⟩
  | next step tail ih =>
    obtain ⟨middle, _, kept⟩ := step.invariant codec roundtrip valid
    obtain ⟨last, remaining⟩ := ih middle
    exact ⟨last, fun key fact present => remaining key fact (kept key fact present)⟩

theorem ResidentTrace.reachable {versions : VersionBytes} {before after : ResidentWorld} {past : List ResidentWorld}
    (prior : ResidentReachable versions before past) (trace : ResidentTrace versions before after) :
    ∃ history, ResidentReachable versions after history := by
  induction trace generalizing past with
  | done => exact ⟨past, prior⟩
  | next step tail ih => exact ih (.next prior step)

def committedWorld (before : ResidentWorld) (after : HotStore) (objects : Objects)
    (owner session : ByteArray) (state etag : Term) : ResidentWorld :=
  ⟨⟨after, objects⟩, ⟨owner, session, .committed state etag⟩ :: before.captured⟩

/-- The confirmation's CAS is an explicit edge of the same execution as every later writer. -/
theorem resident_input_confirmation {framing : CodecFraming} {versions : VersionBytes}
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
      CommandDriver.resident (some episode.confirmed) (a "next") nil =
        inputNotification episode.stamped committed episode.events ∧
      (∀ response : DurableConfirmation.Result,
        CommandDriver.resident (inputNotification episode.stamped committed episode.events).1 (a "effect_result") response.wire =
          (some (Revision.Cursor.committed episode.stamped committed).pack,
            .tuple [a "return", .tuple [a "ok", a "committed"], nil])) := by
  have valid := (prior.conservation (framing := framing) codec roundtrip).1
  obtain ⟨sealed, history⟩ := (valid.2.2 captured member).1
  have committedCAS := cas
  rw [reply] at committedCAS
  have step : ResidentStep versions before
      (committedWorld before after before.store.objects captured.owner captured.session episode.stamped (.binary etag)) :=
    .commit member (.input episode.toInputSubmission) episode.toInputSubmission.fence committedCAS tokens
  have landedValid := (step.invariant codec roundtrip valid).1
  obtain ⟨address, committed, snapshot, bytes, event, now, first, last, item,
    encoded, issued, stored, snapshotHistory, generated, fact, canonical, present, _⟩ :=
    episode.toInputSubmission.current_facts history sourceValue cas
  obtain ⟨decoded, decoding⟩ := roundtrip snapshot bytes encoded
  have landed := HotStore.current_work snapshotHistory stored encoded decoding (codec _ _ _ encoded decoding) present
  rw [address] at landed
  have kept := (later.preserves codec roundtrip landedValid).2 captured.key (.work item) landed
  obtain ⟨confirmedToken, _, _, confirmed, _, _, _, _⟩ :=
    issued_confirmation episode.encoded cas.snapshot_meaning episode.resumed
  refine ⟨later.reachable (.next prior step), event, now, first, last, item, confirmedToken,
    generated, fact, canonical, kept, ?_, ?_⟩
  · rw [confirmed]
    exact input_notifies_captured _ _ _
  · exact input_notification_returns _ _ _

end VerifiedKernel.Session.WorkConservation.CurrentExecution
