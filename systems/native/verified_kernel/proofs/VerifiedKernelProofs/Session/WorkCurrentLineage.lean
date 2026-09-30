import VerifiedKernelProofs.Session.WorkCurrentReadSubmission

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

/-- The codec boundary retains values, field presence, and sequence order. -/
def SnapshotCodec : Prop := ∀ snapshot bytes decoded,
  ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
  ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]) →
  ValueSemantics.Equivalent snapshot decoded

/-- Each occupied key has a history for its current bytes, not an earlier version. -/
def HotStore.lineage (store : HotStore) (framing : CodecFraming) (objects : Objects) : Prop :=
  ∀ key value, store key = some value → ∃ owner session snapshot sealed,
    key = StorageAddress.key owner session ∧
    ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok value.bytes ∧
    PhysicalHistory framing objects owner session snapshot sealed

theorem HotStore.empty_lineage (framing : CodecFraming) (objects : Objects) :
    HotStore.lineage (fun _ => none) framing objects := by
  intro key value absent
  cases absent

theorem HotStore.lineage_objects {store : HotStore} {framing : CodecFraming} {before after : Objects}
    (valid : store.lineage framing before) (extension : ObjectsExtend before after) :
    store.lineage framing after := by
  intro key value present
  obtain ⟨owner, session, snapshot, sealed, addressed, encoded, history⟩ := valid key value present
  exact ⟨owner, session, snapshot, sealed, addressed, encoded, history.objects extension⟩

theorem HotCAS.lineage {before after : HotStore} {framing : CodecFraming} {objects : Objects}
    {owner session bytes : ByteArray} {key base result snapshot : Term} {sealed : List Term}
    (valid : before.lineage framing objects)
    (addressed : key = StorageAddress.key owner session)
    (encoded : ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes)
    (history : PhysicalHistory framing objects owner session snapshot sealed)
    (cas : HotCAS before (.tuple [a "cas", key, .binary bytes, base]) result after) :
    after.lineage framing objects := by
  cases cas with
  | accepted key base bytes etag outcome condition =>
    intro other value current
    by_cases same : other = key
    · subst other
      have eq : HotObject.mk etag bytes = value := by
        simpa only [HotStore.replace, ↓reduceIte, Option.some.injEq] using current
      subst value
      exact ⟨owner, session, snapshot, sealed, addressed, encoded, history⟩
    · apply valid other value
      simpa only [HotStore.replace, same, ↓reduceIte] using current

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.SessionDomain.ReadRevision
open Data Session.WorkConservation Session.ArchivePublication
set_option Elab.async false

/-- Successful load checks scope. This needs no collision-free hash assumption. -/
theorem read_lineage {framing : CodecFraming} {objects : Objects} {store : HotStore}
    {agent session bytes etag : ByteArray} {decodedState pending objectKey cursor : Term}
    {observations : List Term}
    (valid : store.lineage framing objects) (codec : SnapshotCodec)
    (started : SessionDomain.dispatch none (.tuple [i 1, a "session_read", i 1, a "start",
      .tuple [.binary agent, .binary session]]) = (some pending, response (.tuple [a "read", objectKey])))
    (read : HotRead store objectKey bytes (.binary etag))
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
    (loaded : LoadTrace
      (SessionDomain.dispatch (some pending) (.tuple [i 1, a "session_read", i 1, a "read_result",
        .tuple [.tuple [a "ok", .binary bytes, .binary etag], list observations]])) cursor) :
    ∃ snapshot sealed,
      store.current objectKey (.binary etag) snapshot ∧
      PhysicalHistory framing objects agent session snapshot sealed ∧
      ValueSemantics.Equivalent snapshot decodedState := by
  obtain ⟨owner, identity, snapshot, sealed, _, encoded, history⟩ := valid objectKey _ read
  have equivalent := codec snapshot bytes decodedState encoded decoded
  obtain ⟨addressed, _, captured⟩ := start_captured started
  have trace := loaded
  rw [captured, addressed] at trace
  obtain ⟨state, journal, rest, normalized, owned, identified, _, _⟩ :=
    read_result_normalizes decoded (equivalent.ready history.invariant.history.invariant.ready) trace
  have invariant := ((history.decode decoded equivalent).normalize normalized).invariant
  have ownerEq := Term.binary.inj (invariant.owned.symm.trans owned)
  have sessionEq := Term.binary.inj (invariant.identified.symm.trans identified)
  subst owner identity
  exact ⟨snapshot, sealed, ⟨bytes, read, encoded⟩, history, equivalent⟩

end VerifiedKernel.SessionDomain.ReadRevision

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

/-- A public read and input submission. No preservation premise is part of this call. -/
structure ReadCall (store : HotStore) where
  agent : ByteArray
  session : ByteArray
  bytes : ByteArray
  etag : ByteArray
  context : Context
  decodedState : Term
  pending : Term
  objectKey : Term
  observations : List Term
  started : SessionDomain.dispatch none (.tuple [i 1, a "session_read", i 1, a "start",
    .tuple [.binary agent, .binary session]]) =
    (some pending, SessionDomain.ReadRevision.response (.tuple [a "read", objectKey]))
  read : HotRead store objectKey bytes (.binary etag)
  decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState])
  loaded : SessionDomain.ReadRevision.LoadTrace
    (SessionDomain.dispatch (some pending) (.tuple [i 1, a "session_read", i 1, a "read_result",
      .tuple [.tuple [a "ok", .binary bytes, .binary etag], list observations]])) context.pack

theorem ReadCall.history {store : HotStore} {framing : CodecFraming} {objects : Objects}
    (call : ReadCall store) (valid : store.lineage framing objects) (codec : SnapshotCodec) :
    ∃ sealed, PhysicalHistory framing objects call.agent call.session call.context.candidate.working sealed ∧
      call.context.candidate.etag = .binary call.etag := by
  obtain ⟨snapshot, sealed, current, history, equivalent⟩ :=
    SessionDomain.ReadRevision.read_lineage valid codec call.started call.read call.decoded call.loaded
  obtain ⟨_, state, captured, stateHistory, _⟩ :=
    SessionDomain.ReadRevision.current_read_history history current call.started call.read
      call.decoded equivalent call.loaded
  have contextEq : call.context = .committed state (.binary call.etag) := by
    apply Option.some.inj
    simpa only [Revision.unpack_pack] using congrArg Revision.unpack captured
  exact ⟨sealed, by simpa only [contextEq, Revision.Cursor.candidate] using stateHistory,
    by rw [contextEq]; rfl⟩

theorem ReadCall.current_work {store before after : HotStore} {framing : CodecFraming} {objects : Objects}
    {versions : VersionBytes} {candidate result : Term}
    (call : ReadCall store) (valid : store.lineage framing objects) (codec : SnapshotCodec)
    (readVersioned : store.versioned versions) (currentVersioned : before.versioned versions)
    (cas : HotCAS before (.tuple [a "cas", call.objectKey, candidate, .binary call.etag]) result after) :
    ∀ item, before.work objects call.objectKey item →
      PhysicalIdentityFact objects call.context.candidate.working (.work item) := by
  obtain ⟨snapshot, sealed, current, history, equivalent⟩ :=
    SessionDomain.ReadRevision.read_lineage valid codec call.started call.read call.decoded call.loaded
  obtain ⟨state, captured, stateHistory, kept⟩ :=
    SessionDomain.ReadRevision.current_read_physical_preserves history current call.started call.read
      call.decoded equivalent call.loaded
  have contextEq : call.context = .committed state (.binary call.etag) := by
    apply Option.some.inj
    simpa only [Revision.unpack_pack] using congrArg Revision.unpack captured
  have currentRead := HotCAS.read_base_bytes readVersioned currentVersioned call.read
    (by intro impossible; cases impossible) cas
  intro item existing
  have present := kept item (currentRead.snapshot_work history call.decoded equivalent existing)
  simpa only [contextEq, Revision.Cursor.candidate] using present

structure ReadInputSubmission (store : HotStore) extends ReadCall store where
  source : ByteArray
  entry : Term
  born : Term
  checkpoint : Term
  input : InputSubmission context entry born checkpoint
  sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source

def ReadInputSubmission.request {store : HotStore} (call : ReadInputSubmission store) : Term :=
  .tuple [a "cas", call.input.requestedKey, call.input.requestedBytes, call.input.requestedBase]

/-- Current-store lineage supplies every local history hypothesis at a landed input CAS. -/
theorem ReadInputSubmission.landed {framing : CodecFraming} {objects : Objects}
    {readStore before after : HotStore} {versions : VersionBytes} {result : Term}
    (call : ReadInputSubmission readStore)
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (readLineage : readStore.lineage framing objects) (currentLineage : before.lineage framing objects)
    (readVersioned : readStore.versioned versions) (currentVersioned : before.versioned versions)
    (cas : HotCAS before call.request result after) :
    after.lineage framing objects ∧
    (∀ key item, before.work objects key item → after.work objects key item) ∧
    ∃ event now first last item,
      Command.inputEvent (call.context.candidate.working.get (a "session_id")) (.binary call.source)
        (RoundQuery.atomFirst call.entry "payload") now first = .ok (event, last) ∧
      MainInputFact event call.source item ∧ CanonicalQueueItem item ∧
      after.work objects call.objectKey item := by
  obtain ⟨snapshot, sealed, current, history, equivalent⟩ :=
    SessionDomain.ReadRevision.read_lineage readLineage codec call.started call.read call.decoded call.loaded
  obtain ⟨addressed, committed, next, bytes, event, now, first, last, item,
    encoded, issued, stored, nextHistory, generated, fact, canonical, kept⟩ :=
    read_input_submission_current_work readVersioned currentVersioned history current
      call.started call.read call.decoded equivalent call.loaded call.input cas call.sourceValue
  obtain ⟨decoded, decoding⟩ := roundtrip next bytes encoded
  obtain ⟨present, preserves⟩ := kept decoded decoding (codec next bytes decoded encoded decoding)
  have applied : HotCAS before
      (.tuple [a "cas", call.objectKey, .binary bytes, .binary call.etag]) result after := by
    change HotCAS before
      (.tuple [a "cas", call.input.requestedKey, call.input.requestedBytes, call.input.requestedBase]) result after at cas
    rwa [issued] at cas
  refine ⟨applied.lineage currentLineage addressed encoded nextHistory, ?_,
    event, now, first, last, item, generated, fact, canonical, present⟩
  intro key old existing
  by_cases same : key = call.objectKey
  · subst key
    exact preserves old existing
  · exact applied.other_work same existing

end VerifiedKernel.Session.CommandDriver
