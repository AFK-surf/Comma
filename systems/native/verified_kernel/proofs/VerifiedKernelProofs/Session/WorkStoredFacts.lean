import VerifiedKernelProofs.Session.WorkCurrentStorage
import VerifiedKernelProofs.Session.WorkPhysicalTransport
import VerifiedKernelProofs.Session.WorkPhysicalPreservation

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

/-- A current object's decoded bytes and archive objects contain this work fact. -/
def HotStore.work (store : HotStore) (objects : Objects) (key item : Term) : Prop :=
  ∃ etag bytes state, HotRead store key bytes etag ∧
    ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, state]) ∧
    PhysicalIdentityFact objects state (.work item)

theorem HotRead.work {store : HotStore} {objects : Objects} {key etag state item : Term} {bytes : ByteArray}
    (read : HotRead store key bytes etag)
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, state])) :
    store.work objects key item ↔ PhysicalIdentityFact objects state (.work item) := by
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

theorem HotStore.work_objects {store : HotStore} {before after : Objects} {key item : Term}
    (extension : ObjectsExtend before after) (present : store.work before key item) : store.work after key item := by
  obtain ⟨etag, bytes, state, read, decoded, present⟩ := present
  exact ⟨etag, bytes, state, read, decoded, physical_work_objects extension item present⟩

theorem HotCAS.other_work {before after : HotStore} {objects : Objects}
    {key base result other item : Term} {bytes : ByteArray}
    (cas : HotCAS before (.tuple [a "cas", key, .binary bytes, base]) result after)
    (different : other ≠ key) (present : before.work objects other item) : after.work objects other item := by
  obtain ⟨etag, storedBytes, state, read, decoded, present⟩ := present
  refine ⟨etag, storedBytes, state, ?_, decoded, present⟩
  change after other = some ⟨etag, storedBytes⟩
  rw [cas.only_requested_key.2 other different]
  exact read

theorem HotCAS.absent_preserves {before after : HotStore} {objects : Objects}
    {key result : Term} {bytes : ByteArray}
    (cas : HotCAS before (.tuple [a "cas", key, .binary bytes, nil]) result after) :
    ∀ other item, before.work objects other item → after.work objects other item := by
  intro other item present
  by_cases same : other = key
  · subst other
    obtain ⟨etag, storedBytes, state, read, _, _⟩ := present
    rcases cas.only_requested_key.1 with absent | ⟨impossible, _⟩
    · change before key = some _ at read
      rw [absent.2] at read
      cases read
    · exact (impossible rfl).elim
  · exact cas.other_work same present

theorem HotStore.current_work {framing : CodecFraming} {objects : Objects} {store : HotStore}
    {owner session bytes : ByteArray} {key etag state decodedState item : Term} {sealed : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (current : store.current key etag state)
    (encoded : ETF.encode (.tuple [a "comma_internal_session", i 3, state]) = .ok bytes)
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
    (codec : ValueSemantics.Equivalent state decodedState)
    (present : PhysicalIdentityFact objects state (.work item)) : store.work objects key item := by
  obtain ⟨storedBytes, read, storedEncoding⟩ := current
  have bytesEq := Except.ok.inj (storedEncoding.symm.trans encoded)
  subst storedBytes
  obtain ⟨catalog, watermark, catalogRead, through, valid⟩ := history.invariant.archive
  exact ⟨etag, bytes, decodedState, read, decoded,
    physical_work_equivalent codec history.invariant.owned history.invariant.identified catalogRead valid item present⟩

theorem HotRead.snapshot_work {framing : CodecFraming} {objects : Objects} {store : HotStore}
    {owner session bytes : ByteArray} {key etag state decodedState item : Term} {sealed : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (read : HotRead store key bytes etag)
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
    (codec : ValueSemantics.Equivalent state decodedState)
    (present : store.work objects key item) : PhysicalIdentityFact objects state (.work item) :=
  (history.decode decoded codec).decode_physical codec.symm item ((read.work decoded).mp present)

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

/-- Persisting clears volatile fields, but keeps exactly the same physical work facts. -/
theorem persistable_physical_work_iff {objects : Objects} {state snapshot item : Term}
    {journal rest : List Term}
    (persisted : Lifecycle.persistable state journal = .ok (snapshot, rest)) :
    PhysicalIdentityFact objects snapshot (.work item) ↔ PhysicalIdentityFact objects state (.work item) := by
  have fields := persistable_work_fields persisted
  have catalog := (persistable_archive_fields persisted).1
  have owner : snapshot.get (a "agent_id") = state.get (a "agent_id") := persistable_owner persisted
  have session := (persistable_queue_frame persisted).2.2.2.1
  simp only [PhysicalIdentityFact, ValueSemantics.Represented, ContainsRecord,
    fields.1, fields.2, catalog, owner, session]

end VerifiedKernel.Session.WorkConservation
