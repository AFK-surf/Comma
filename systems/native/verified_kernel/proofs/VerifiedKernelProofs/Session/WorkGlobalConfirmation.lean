import VerifiedKernelProofs.Session.WorkStoreExecution

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication CommandDriver
set_option Elab.async false

/-- A delayed duplicate return still has its original fact in the current physical store. -/
theorem Reachable.duplicate_durable {framing : CodecFraming} {versions : VersionBytes}
    {current observed : World} {past : List World} {source : ByteArray}
    {entry born checkpoint saved confirmed args : Term} {observations : List Term}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (execution : Reachable versions current past) (earlier : observed ∈ current :: past)
    (read : ReadCall observed.hot)
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source)
    (admission : AdmissionTrace
      (CommandDriver.resident (some read.context.pack) (a "start")
        (.tuple [.tuple [a "input", .tuple [entry, born], checkpoint], list observations]))
      (some saved, .tuple [a "fence"]))
    (fence : CommandDriver.resident (some saved) (a "fence_clean") args = (some confirmed, .tuple [a "committed"])) :
    (∃ event fact, IdentityFactOrigin event source fact ∧ current.fact read.objectKey fact) ∧
      CommandDriver.resident (some confirmed) (a "next") nil =
        (some read.context.pack, .tuple [a "return", .tuple [a "ok", a "duplicate"], nil]) := by
  obtain ⟨earlierPast, prior⟩ := execution.earlier earlier
  have lineage := ((prior.invariant (framing := framing) codec roundtrip).1 observed List.mem_cons_self).1
  obtain ⟨⟨event, fact, origin, stored⟩, returned⟩ := read.duplicate lineage codec sourceValue admission fence
  exact ⟨⟨event, fact, origin, execution.fact_conserved (framing := framing) codec roundtrip earlier stored⟩, returned⟩

theorem Reachable.input_confirmation_durable {framing : CodecFraming} {versions : VersionBytes}
    {before observed current : World} {after : HotStore} {beforePast past : List World}
    {result confirmed : Term}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (prior : Reachable versions before beforePast) (readEarlier : observed ∈ before :: beforePast)
    (call : ReadInputSubmission observed.hot)
    (cas : HotCAS before.hot call.request result after)
    (resumed : CommandDriver.resident (some call.input.casCursor) (a "cas_result") result =
      (some confirmed, .tuple [a "committed"]))
    (execution : Reachable versions current past)
    (landedEarlier : (World.mk after before.objects) ∈ current :: past) :
    ∃ etag event now first last item,
      Command.inputEvent (call.context.candidate.working.get (a "session_id")) (.binary call.source)
        (RoundQuery.atomFirst call.entry "payload") now first = .ok (event, last) ∧
      MainInputFact event call.source item ∧ current.work call.objectKey item ∧
      CommandDriver.resident (some confirmed) (a "next") nil = inputNotification call.input.stamped etag call.input.events ∧
      (∀ response : DurableConfirmation.Result,
        CommandDriver.resident (inputNotification call.input.stamped etag call.input.events).1
          (a "effect_result") response.wire =
          (some (Revision.Cursor.committed call.input.stamped etag).pack,
            .tuple [a "return", .tuple [a "ok", a "committed"], nil])) := by
  have invariant := prior.invariant (framing := framing) codec roundtrip
  obtain ⟨snapshot, sealed, currentRead, history, equivalent⟩ := SessionDomain.ReadRevision.read_lineage
    (invariant.1 observed readEarlier).1 codec call.started call.read call.decoded call.loaded
  let episode : InputEpisode call.context call.entry call.born call.checkpoint :=
    { toInputSubmission := call.input, result, confirmed, resumed }
  obtain ⟨etag, next, bytes, event, now, first, last, item, _, encoded, stored, nextHistory,
    generated, fact, canonical, notified, returned, kept⟩ :=
    read_input_current_work (invariant.1 observed readEarlier).2
      (invariant.1 before List.mem_cons_self).2 history currentRead call.started call.read call.decoded
      equivalent call.loaded episode cas call.sourceValue
  obtain ⟨decoded, decoding⟩ := roundtrip next bytes encoded
  have present := (kept decoded decoding (codec _ _ _ encoded decoding)).1
  exact ⟨etag, event, now, first, last, item, generated, fact,
    execution.work_conserved (framing := framing) codec roundtrip landedEarlier present, notified, returned⟩

end VerifiedKernel.Session.WorkConservation.CurrentExecution
