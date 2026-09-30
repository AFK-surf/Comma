import VerifiedKernelProofs.Session.WorkPhysicalRecords

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

theorem HotRead.fact {store : HotStore} {objects : Objects} {key etag state : Term} {bytes : ByteArray}
    {fact : IdentityFact} (read : HotRead store key bytes etag)
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, state])) :
    store.fact objects key fact ↔ PhysicalIdentityFact objects state fact := by
  constructor
  · rintro ⟨otherEtag, otherBytes, otherState, otherRead, otherDecode, present⟩
    have cells := Option.some.inj (read.symm.trans otherRead)
    have bytesEq := congrArg HotObject.bytes cells
    change bytes = otherBytes at bytesEq
    subst otherBytes
    have stateEq : state = otherState := by
      simpa only [Except.ok.injEq, Term.tuple.injEq, List.cons.injEq, and_true, true_and]
        using decoded.symm.trans otherDecode
    subst otherState
    exact present
  · exact fun present => ⟨etag, bytes, state, read, decoded, present⟩

theorem HotStore.fact_objects {store : HotStore} {before after : Objects} {key : Term} {fact : IdentityFact}
    (extension : ObjectsExtend before after) (present : store.fact before key fact) : store.fact after key fact := by
  obtain ⟨etag, bytes, state, read, decoded, present⟩ := present
  exact ⟨etag, bytes, state, read, decoded, physical_identity_objects extension present⟩

theorem HotCAS.other_fact {before after : HotStore} {objects : Objects}
    {key base result other : Term} {fact : IdentityFact} {bytes : ByteArray}
    (cas : HotCAS before (.tuple [a "cas", key, .binary bytes, base]) result after)
    (different : other ≠ key) (present : before.fact objects other fact) : after.fact objects other fact := by
  obtain ⟨etag, storedBytes, state, read, decoded, present⟩ := present
  refine ⟨etag, storedBytes, state, ?_, decoded, present⟩
  change after other = some ⟨etag, storedBytes⟩
  rw [cas.only_requested_key.2 other different]
  exact read

theorem HotCAS.absent_preserves_fact {before after : HotStore} {objects : Objects}
    {key result : Term} {bytes : ByteArray}
    (cas : HotCAS before (.tuple [a "cas", key, .binary bytes, nil]) result after) :
    ∀ other fact, before.fact objects other fact → after.fact objects other fact := by
  intro other fact present
  by_cases same : other = key
  · subst other
    obtain ⟨etag, storedBytes, state, read, _, _⟩ := present
    rcases cas.only_requested_key.1 with absent | ⟨impossible, _⟩
    · change before key = some _ at read
      rw [absent.2] at read
      cases read
    · exact (impossible rfl).elim
  · exact cas.other_fact same present

theorem HotStore.current_fact {framing : CodecFraming} {objects : Objects} {store : HotStore}
    {owner session bytes : ByteArray} {key etag state decodedState : Term} {fact : IdentityFact} {sealed : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (current : store.current key etag state)
    (encoded : ETF.encode (.tuple [a "comma_internal_session", i 3, state]) = .ok bytes)
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
    (codec : ValueSemantics.Equivalent state decodedState)
    (present : PhysicalIdentityFact objects state fact) : store.fact objects key fact := by
  obtain ⟨storedBytes, read, storedEncoding⟩ := current
  have bytesEq := Except.ok.inj (storedEncoding.symm.trans encoded)
  subst storedBytes
  exact ⟨etag, bytes, decodedState, read, decoded, history.decode_identity codec present⟩

theorem PhysicalHistory.normalize_fact {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {fact : IdentityFact} {sealed journal rest : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (normalized : Lifecycle.normalize state journal = .ok (next, rest))
    (present : PhysicalIdentityFact objects state fact) : PhysicalIdentityFact objects next fact := by
  cases fact with
  | work item => exact history.normalize_physical normalized item present
  | record reference => exact history.normalize_records normalized reference present

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem ReadCall.current_fact {store before after : HotStore} {framing : CodecFraming} {objects : Objects}
    {versions : VersionBytes} {candidate result : Term}
    (call : ReadCall store) (valid : store.lineage framing objects) (codec : SnapshotCodec)
    (readVersioned : store.versioned versions) (currentVersioned : before.versioned versions)
    (cas : HotCAS before (.tuple [a "cas", call.objectKey, candidate, .binary call.etag]) result after) :
    ∀ fact, before.fact objects call.objectKey fact →
      PhysicalIdentityFact objects call.context.candidate.working fact := by
  obtain ⟨snapshot, sealed, current, history, equivalent⟩ :=
    SessionDomain.ReadRevision.read_lineage valid codec call.started call.read call.decoded call.loaded
  obtain ⟨_, _, state, journal, rest, normalized, _, _, captured, _⟩ :=
    SessionDomain.ReadRevision.current_read_preserves history current call.started call.read call.decoded equivalent call.loaded
  have contextEq : call.context = .committed state (.binary call.etag) := by
    apply Option.some.inj
    simpa only [Revision.unpack_pack] using congrArg Revision.unpack captured
  have currentRead := HotCAS.read_base_bytes readVersioned currentVersioned call.read
    (by intro impossible; cases impossible) cas
  intro fact existing
  have present := (history.decode call.decoded equivalent).normalize_fact normalized
    ((currentRead.fact call.decoded).mp existing)
  simpa only [contextEq, Revision.Cursor.candidate] using present

end VerifiedKernel.Session.CommandDriver
