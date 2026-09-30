import VerifiedKernelProofs.Session.WorkResidentReceipts
import VerifiedKernelProofs.Session.WorkResidentLog
import VerifiedKernelProofs.Session.WorkFactProtocol

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication CommandDriver
set_option Elab.async false

structure TerminalReceipt where
  observer : FactProtocol.Observer
  confirmed : Term
  returnedCursor : Term
  result : Term

def TerminalReceipt.ReturnEquations (receipt : TerminalReceipt) : Prop :=
  CommandDriver.resident (some receipt.confirmed) (a "next") nil =
    (some receipt.returnedCursor, .tuple [a "return", receipt.result, nil])

structure DuplicateCall (before : ResidentWorld) where
  captured : CapturedRevision
  member : captured ∈ before.captured
  source : Term
  entry : Term
  born : Term
  checkpoint : Term
  saved : Term
  confirmed : Term
  args : Term
  observations : List Term
  sourceValue : RoundQuery.atomFirst entry "source_message_id" = source
  admission : AdmissionTrace
    (CommandDriver.resident (some captured.cursor.pack) (a "start")
      (.tuple [.tuple [a "input", .tuple [entry, born], checkpoint], list observations]))
    (some saved, .tuple [a "fence"])
  fence : CommandDriver.resident (some saved) (a "fence_clean") args =
    (some confirmed, .tuple [a "committed"])

structure DuplicateCall.Witness {before : ResidentWorld} (call : DuplicateCall before) where
  matched : Term
  event : Term
  fact : IdentityFact
  alias : InputSourceAlias call.source matched
  origin : ReceiptOrigin event matched fact
  backed : before.store.fact call.captured.key fact

noncomputable def DuplicateCall.witness {framing : CodecFraming} {versions : VersionBytes}
    {before : ResidentWorld} {past : List ResidentWorld} (call : DuplicateCall before)
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (prior : ResidentReachable versions before past) : call.Witness := by
  apply Classical.choice
  obtain ⟨⟨matched, event, fact, alias, origin, backed⟩, _⟩ := resident_duplicate_receipt_confirmation (framing := framing)
    codec roundtrip prior call.member call.sourceValue call.admission call.fence (.done _)
  exact ⟨⟨matched, event, fact, alias, origin, backed⟩⟩

noncomputable def DuplicateCall.receipt {framing : CodecFraming} {versions : VersionBytes}
    {before : ResidentWorld} {past : List ResidentWorld} (call : DuplicateCall before)
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (prior : ResidentReachable versions before past) : TerminalReceipt :=
  ⟨⟨call.captured.key, (call.witness (framing := framing) codec roundtrip prior).fact⟩,
    call.confirmed, call.captured.cursor.pack, .tuple [a "ok", a "duplicate"]⟩

structure LogLanding (versions : VersionBytes) (before : ResidentWorld) where
  captured : CapturedRevision
  member : captured ∈ before.captured
  entry : Term
  checkpoint : Term
  saved : Term
  continuation : Term
  observations : List Term
  events : List Term
  staged : PendingRevision.Cursor
  admission : AdmissionTrace
    (CommandDriver.resident (some captured.cursor.pack) (a "start")
      (.tuple [.tuple [a "log", entry, checkpoint], list observations]))
    (some saved, .tuple [a "validate_write", list events])
  write : BatchTrace (CommandDriver.resident (some saved) (a "write_result") (a "ok"))
    (writeFenced staged continuation)
  episode : WriteEpisode staged continuation
  after : HotStore
  etag : ByteArray
  outcome : Term
  reply : episode.result = .tuple [a "ok", .binary etag, outcome]
  cas : HotCAS before.store.hot
    (.tuple [a "cas", episode.requestedKey, episode.requestedBytes, episode.requestedBase]) episode.result after
  tokens : after.versioned versions

def LogLanding.world {versions : VersionBytes} {before : ResidentWorld}
    (call : LogLanding versions before) : ResidentWorld :=
  committedWorld before call.after before.store.objects call.captured.owner call.captured.session
    call.episode.stamped (.binary call.etag)

theorem LogLanding.step {versions : VersionBytes} {before : ResidentWorld}
    (call : LogLanding versions before) : ResidentStep versions before call.world :=
  .commit call.member (.log call.admission call.write) call.episode.toWriteSubmission
    (by rw [← call.reply]; exact call.cas) call.tokens

structure LogLanding.Witness {versions : VersionBytes} {before : ResidentWorld}
    (call : LogLanding versions before) where
  now : Term
  fact : IdentityFact
  token : Term
  origin : LogFactOrigin (logEvent (call.captured.cursor.candidate.working.get (a "session_id")) call.entry now) fact
  backed : call.world.store.fact call.captured.key fact
  returned : CommandDriver.resident (some call.episode.confirmed) (a "next") nil =
    (some (Revision.Cursor.committed call.episode.stamped token).pack,
      .tuple [a "return", .tuple [a "ok", a "committed"], nil])

noncomputable def LogLanding.witness {framing : CodecFraming} {versions : VersionBytes}
    {before : ResidentWorld} {past : List ResidentWorld} (call : LogLanding versions before)
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (prior : ResidentReachable versions before past) : call.Witness := by
  apply Classical.choice
  obtain ⟨_, now, fact, token, origin, backed, returned⟩ := resident_log_confirmation (framing := framing)
    codec roundtrip prior call.member call.admission call.write call.episode call.reply call.cas call.tokens (.done _)
  exact ⟨⟨now, fact, token, origin, backed, returned⟩⟩

noncomputable def LogLanding.receipt {framing : CodecFraming} {versions : VersionBytes}
    {before : ResidentWorld} {past : List ResidentWorld} (call : LogLanding versions before)
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (prior : ResidentReachable versions before past) : TerminalReceipt :=
  let witness := call.witness (framing := framing) codec roundtrip prior
  ⟨⟨call.captured.key, witness.fact⟩, call.episode.confirmed,
    (Revision.Cursor.committed call.episode.stamped witness.token).pack, .tuple [a "ok", a "committed"]⟩

end VerifiedKernel.Session.WorkConservation.CurrentExecution
