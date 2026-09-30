import VerifiedKernelProofs.Session.WorkLabelledSimulation
import VerifiedKernelProofs.Session.WorkNativeStoreCommit

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication CommandDriver
set_option Elab.async false

structure InputLanding (versions : VersionBytes) (before : ResidentWorld) where
  captured : CapturedRevision
  member : captured ∈ before.captured
  entry : Term
  born : Term
  checkpoint : Term
  source : Term
  sourceValue : RoundQuery.atomFirst entry "source_message_id" = source
  submission : InputSubmission captured.cursor entry born checkpoint
  after : HotStore
  etag : ByteArray
  outcome : Term
  cas : HotCAS before.store.hot
    (.tuple [a "cas", submission.requestedKey, submission.requestedBytes, submission.requestedBase])
    (.tuple [a "ok", .binary etag, outcome]) after
  tokens : after.versioned versions

def InputLanding.world {versions : VersionBytes} {before : ResidentWorld}
    (call : InputLanding versions before) : ResidentWorld :=
  committedWorld before call.after before.store.objects call.captured.owner call.captured.session
    call.submission.stamped (.binary call.etag)

theorem InputLanding.step {versions : VersionBytes} {before : ResidentWorld}
    (call : InputLanding versions before) : ResidentStep versions before call.world :=
  .commit call.member (.input call.submission) call.submission.fence call.cas call.tokens

/-- Ghost receipt of an issued input. It adds no runtime state, payload, or write. -/
structure InputReceipt where
  observer : FactProtocol.Observer
  casCursor : Term
  result : Term
  stamped : Term
  events : List Term

/-- Lean equations for notification intent. External execution and delivery are assumptions. -/
def InputReceipt.NotificationEquations (receipt : InputReceipt) : Prop :=
  ∃ confirmed token,
    CommandDriver.resident (some receipt.casCursor) (a "cas_result") receipt.result =
      (some confirmed, .tuple [a "committed"]) ∧
    CommandDriver.resident (some confirmed) (a "next") nil =
      inputNotification receipt.stamped token receipt.events

/-- Lean equations for the reply path. They do not establish an external occurrence. -/
def InputReceipt.ReturnEquations (receipt : InputReceipt) : Prop :=
  ∃ confirmed token, ∃ response : DurableConfirmation.Result,
    CommandDriver.resident (some receipt.casCursor) (a "cas_result") receipt.result =
      (some confirmed, .tuple [a "committed"]) ∧
    CommandDriver.resident (some confirmed) (a "next") nil =
      inputNotification receipt.stamped token receipt.events ∧
    CommandDriver.resident (inputNotification receipt.stamped token receipt.events).1
      (a "effect_result") response.wire =
      (some (Revision.Cursor.committed receipt.stamped token).pack,
        .tuple [a "return", .tuple [a "ok", a "committed"], nil])

theorem InputReceipt.ReturnEquations.notification {receipt : InputReceipt}
    (equations : receipt.ReturnEquations) : receipt.NotificationEquations := by
  obtain ⟨confirmed, token, response, committed, notification, returned⟩ := equations
  exact ⟨confirmed, token, committed, notification⟩

structure InputLanding.Witness {versions : VersionBytes} {before : ResidentWorld}
    (call : InputLanding versions before) where
  event : Term
  now : Term
  first : List Term
  last : List Term
  item : Term
  generated : Command.inputEvent (call.captured.cursor.candidate.working.get (a "session_id"))
    call.source (RoundQuery.atomFirst call.entry "payload") now first = .ok (event, last)
  origin : MainTermInputFact event call.source item
  canonical : CanonicalQueueItem item
  backed : call.world.store.work call.captured.key item

theorem InputLanding.has_witness {framing : CodecFraming} {versions : VersionBytes}
    {before : ResidentWorld} {past : List ResidentWorld}
    (call : InputLanding versions before) (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (prior : ResidentReachable versions before past) : Nonempty call.Witness := by
  have valid := (prior.conservation (framing := framing) codec roundtrip).1
  obtain ⟨sealed, history⟩ := (valid.2.2 call.captured call.member).1
  obtain ⟨address, token, snapshot, bytes, event, now, first, last, item,
    encoded, _, stored, snapshotHistory, generated, fact, canonical, physical, _⟩ :=
    call.submission.current_facts history call.sourceValue call.cas
  obtain ⟨decoded, decoding⟩ := roundtrip snapshot bytes encoded
  have landed := HotStore.current_work snapshotHistory stored encoded decoding
    (codec _ _ _ encoded decoding) physical
  rw [address] at landed
  exact ⟨⟨event, now, first, last, item, generated, fact, canonical, landed⟩⟩

noncomputable def InputLanding.witness {framing : CodecFraming} {versions : VersionBytes}
    {before : ResidentWorld} {past : List ResidentWorld}
    (call : InputLanding versions before) (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (prior : ResidentReachable versions before past) : call.Witness :=
  Classical.choice (call.has_witness (framing := framing) codec roundtrip prior)

noncomputable def InputLanding.receipt {framing : CodecFraming} {versions : VersionBytes}
    {before : ResidentWorld} {past : List ResidentWorld}
    (call : InputLanding versions before) (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (prior : ResidentReachable versions before past) : InputReceipt :=
  ⟨⟨call.captured.key, .work (call.witness (framing := framing) codec roundtrip prior).item⟩,
    call.submission.casCursor, .tuple [a "ok", .binary call.etag, call.outcome],
    call.submission.stamped, call.submission.events⟩

end VerifiedKernel.Session.WorkConservation.CurrentExecution
