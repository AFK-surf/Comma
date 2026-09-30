import VerifiedKernelProofs.Session.WorkArchiveInterleaving

namespace VerifiedKernel.Session.ArchivePublication
open Data WorkConservation
set_option Elab.async false

/-- Current ETF bytes after the trusted storage codec decompresses the object body. -/
abbrev ByteStore := Term → Option ByteArray

/-- Equivalent decoded views of one current immutable byte object, not historical snapshot membership. -/
def ByteStore.objects (store : ByteStore) : Objects := fun address records =>
  ∃ bytes decoded, store address = some bytes ∧ ETF.decode bytes = .ok decoded ∧
    ValueSemantics.Equivalent (list records) decoded

def ByteStore.Extends (before after : ByteStore) : Prop :=
  ∀ address bytes, before address = some bytes → after address = some bytes

theorem ByteStore.Extends.objects {before after : ByteStore} (extension : before.Extends after) :
    ObjectsExtend before.objects after.objects := by
  rintro address records ⟨bytes, decoded, stored, decoding, equivalent⟩
  exact ⟨bytes, decoded, extension address bytes stored, decoding, equivalent⟩

/-- Storage callbacks refer to the bytes at their requested address. Business preservation is not a premise. -/
def ByteObservations (after : ByteStore) (request result : Term) : Prop :=
  (∀ agent session first records,
    request = .tuple [a "read_segment", agent, session, first] →
    result = .tuple [a "ok", list records] →
    ∃ bytes, after (key agent session first) = some bytes ∧ ETF.decode bytes = .ok (list records)) ∧
  (∀ agent session first bytes,
    request = .tuple [a "create_segment", agent, session, first, .binary bytes] →
    (result = a "created" ∨ result = a "landed") → after (key agent session first) = some bytes) ∧
  (∀ agent session first requestedBytes records,
    request = .tuple [a "create_segment", agent, session, first, .binary requestedBytes] →
    result = .tuple [a "exists", list records] →
    ∃ bytes, after (key agent session first) = some bytes ∧ ETF.decode bytes = .ok (list records))

theorem byte_observations_refine {before after : ByteStore} {request result : Term}
    (extension : before.Extends after) (observations : ByteObservations after request result)
    (roundtrip : ∀ value bytes, ETF.encode value = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok decoded ∧ ValueSemantics.Equivalent value decoded)
    (comparison : CodecMeaning request result) :
    PrimitiveStep before.objects after.objects request result := by
  refine ⟨extension.objects, ?_, ?_, ?_, comparison⟩
  · intro agent session first records requested returned
    obtain ⟨bytes, stored, decoded⟩ := observations.1 agent session first records requested returned
    exact ⟨bytes, list records, stored, decoded, ValueSemantics.Equivalent.refl _⟩
  · intro agent session first bytes records requested encoded returned
    obtain ⟨decoded, decoding, equivalent⟩ := roundtrip (list records) bytes encoded
    exact ⟨bytes, decoded, observations.2.1 agent session first bytes requested returned, decoding, equivalent⟩
  · intro agent session first bytes records requested returned
    obtain ⟨storedBytes, stored, decoded⟩ := observations.2.2 agent session first bytes records requested returned
    exact ⟨storedBytes, list records, stored, decoded, ValueSemantics.Equivalent.refl _⟩

theorem byte_objects_same_address {store : ByteStore} {address : Term} {left right : List Term}
    (first : store.objects address left) (second : store.objects address right) :
    ValueSemantics.Equivalent (list left) (list right) := by
  obtain ⟨bytes, decoded, stored, decoding, equivalent⟩ := first
  obtain ⟨otherBytes, otherDecoded, otherStored, otherDecoding, otherEquivalent⟩ := second
  have same := Option.some.inj (stored.symm.trans otherStored)
  subst otherBytes
  have same := Except.ok.inj (decoding.symm.trans otherDecoding)
  subst otherDecoded
  exact equivalent.trans otherEquivalent.symm

end VerifiedKernel.Session.ArchivePublication
