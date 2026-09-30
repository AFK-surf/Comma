import VerifiedKernelProofs.Session.WorkResidentTrace

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication CommandDriver
set_option Elab.async false

def CapturedRevision.Durable (world : World) (captured : CapturedRevision) : Prop :=
  ∀ source, IdentityPresent (captured.cursor.candidate.working.get (a "input_dedupe")) (.binary source) →
    ∃ event fact, IdentityFactOrigin event source fact ∧ world.fact captured.key fact

theorem CapturedRevision.Durable.preserves {before after : World} {captured : CapturedRevision}
    (durable : captured.Durable before)
    (kept : ∀ key fact, before.fact key fact → after.fact key fact) : captured.Durable after := by
  intro source present
  obtain ⟨event, fact, origin, stored⟩ := durable source present
  exact ⟨event, fact, origin, kept _ _ stored⟩

set_option maxRecDepth 4096 in
theorem captured_read_durable {framing : CodecFraming} {world : World}
    (read : ReadCall world.hot) (lineage : world.hot.lineage framing world.objects) (codec : SnapshotCodec) :
    (capturedRead read).Durable world := by
  intro source present
  obtain ⟨snapshot, sealed, current, history, equivalent⟩ :=
    SessionDomain.ReadRevision.read_lineage lineage codec read.started read.read read.decoded read.loaded
  obtain ⟨address, _, state, journal, rest, normalized, _, _, captured, _⟩ :=
    SessionDomain.ReadRevision.current_read_preserves history current read.started read.read read.decoded equivalent read.loaded
  have contextEq : read.context = .committed state (.binary read.etag) := by
    apply Option.some.inj
    simpa only [Revision.unpack_pack] using congrArg Revision.unpack captured
  change IdentityPresent (read.context.candidate.working.get (a "input_dedupe")) (.binary source) at present
  rw [contextEq] at present
  obtain ⟨event, fact, origin, stored⟩ := history.normalized_identity_physical read.decoded equivalent normalized present
  refine ⟨event, fact, origin, .binary read.etag, read.bytes, read.decodedState, ?_, read.decoded,
    history.decode_identity equivalent stored⟩
  change read.objectKey = StorageAddress.key read.agent read.session at address
  change HotRead world.hot (StorageAddress.key read.agent read.session) read.bytes (.binary read.etag)
  simpa only [address] using read.read

theorem landed_captured_durable {framing : CodecFraming} {objects : Objects} {before after : HotStore}
    {owner session : ByteArray} {cursor : PendingRevision.Cursor} {continuation etag outcome : Term}
    {sealed : List Term} (write : WriteSubmission cursor continuation)
    (history : PhysicalHistory framing objects owner session cursor.working sealed)
    (cas : HotCAS before (.tuple [a "cas", write.requestedKey, write.requestedBytes, write.requestedBase])
      (.tuple [a "ok", etag, outcome]) after)
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded])) :
    (CapturedRevision.mk owner session (.committed write.stamped etag)).Durable ⟨after, objects⟩ := by
  intro source present
  obtain ⟨stampedHistory, snapshot, bytes, journal, rest, persisted, encoded, stored⟩ := write.retained_origin history cas
  obtain ⟨event, fact, origin, supported⟩ := stampedHistory.invariant.history.invariant.supported source present
  have physical := identity_fact_physical stampedHistory.invariant.images supported
  have snapshotFact := (persistable_physical_identity_iff persisted).mpr physical
  obtain ⟨decoded, decoding⟩ := roundtrip snapshot bytes encoded
  obtain ⟨address, _⟩ := write.current_identities history cas
  refine ⟨event, fact, origin, etag, bytes, decoded, ?_, decoding,
    (stampedHistory.persist persisted).decode_identity (codec _ _ _ encoded decoding) snapshotFact⟩
  change HotRead after (StorageAddress.key owner session) bytes etag
  rwa [← address]

def ResidentDurable (world : ResidentWorld) : Prop :=
  ∀ captured ∈ world.captured, captured.Durable world.store

theorem ResidentStep.durable {framing : CodecFraming} {versions : VersionBytes} {before after : ResidentWorld}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (valid : ResidentInvariant framing versions before) (durable : ResidentDurable before)
    (step : ResidentStep versions before after) : ResidentDurable after := by
  have carried : ∀ captured ∈ before.captured, captured.Durable after.store :=
    fun captured member => (durable captured member).preserves (step.invariant codec roundtrip valid).2.2
  cases step with
  | birth born persisted encoded cas tokens =>
    have history := born.physical valid.2.2
    intro captured member
    rcases List.mem_cons.mp member with rfl | old
    · intro source present
      obtain ⟨event, fact, origin, supported⟩ := history.invariant.history.invariant.supported source present
      have physical := identity_fact_physical history.invariant.images supported
      have persistedFact := (persistable_physical_identity_iff persisted).mpr physical
      obtain ⟨decoded, decoding⟩ := roundtrip _ _ encoded
      obtain ⟨token, current⟩ := cas.current_candidate encoded
      exact ⟨event, fact, origin, HotStore.current_fact (history.persist persisted)
        current encoded decoding (codec _ _ _ encoded decoding) persistedFact⟩
    · exact carried captured old
  | read call =>
    intro captured member
    rcases List.mem_cons.mp member with rfl | old
    · exact captured_read_durable call valid.1 codec
    · exact carried captured old
  | create created write cas tokens =>
    intro captured member
    rcases List.mem_cons.mp member with rfl | old
    · exact landed_captured_durable (framing := framing) write (.create created) cas codec roundtrip
    · exact carried captured old
  | fork captured forked write cas tokens =>
    obtain ⟨sealed, history⟩ := (valid.2.2 _ captured).1
    intro captured member
    rcases List.mem_cons.mp member with rfl | old
    · exact landed_captured_durable write (history.fork forked) cas codec roundtrip
    · exact carried captured old
  | commit captured staging write cas tokens =>
    obtain ⟨sealed, history⟩ := (valid.2.2 _ captured).1
    obtain ⟨_, _, nextSealed, nextHistory, _⟩ := staging.identities history
    intro captured member
    rcases List.mem_cons.mp member with rfl | old
    · exact landed_captured_durable write nextHistory cas codec roundtrip
    · exact carried captured old
  | objects => exact carried
  | unchanged => exact carried
  | forget included => exact fun captured member => carried captured (included captured member)

theorem ResidentReachable.durable {framing : CodecFraming} {versions : VersionBytes}
    {world : ResidentWorld} {past : List ResidentWorld}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (execution : ResidentReachable versions world past) : ResidentDurable world := by
  induction execution with
  | initial => intro captured member; cases member
  | next prior step ih => exact step.durable codec roundtrip (prior.conservation (framing := framing) codec roundtrip).1 ih

theorem resident_duplicate_confirmation {framing : CodecFraming} {versions : VersionBytes}
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
    (∃ event fact, IdentityFactOrigin event source fact ∧ current.store.fact captured.key fact) ∧
      CommandDriver.resident (some confirmed) (a "next") nil =
        (some captured.cursor.pack, .tuple [a "return", .tuple [a "ok", a "duplicate"], nil]) := by
  obtain ⟨savedEq, present⟩ := input_raw_duplicate sourceValue admission
  obtain ⟨event, fact, origin, stored⟩ := (prior.durable (framing := framing) codec roundtrip) captured member source present
  have valid := (prior.conservation (framing := framing) codec roundtrip).1
  refine ⟨⟨event, fact, origin, (later.preserves codec roundtrip valid).2 _ _ stored⟩, ?_⟩
  rw [savedEq] at fence
  obtain ⟨state, etag, contextEq, confirmedEq⟩ := clean_fence_capture fence
  rw [confirmedEq, contextEq]
  exact duplicate_return_captured _ _

end VerifiedKernel.Session.WorkConservation.CurrentExecution
