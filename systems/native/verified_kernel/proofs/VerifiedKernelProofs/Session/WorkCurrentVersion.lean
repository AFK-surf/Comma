import VerifiedKernelProofs.Session.WorkCurrentStorage

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

/-- The storage token names bytes at one key. Repeated tokens may name identical bytes. -/
abbrev VersionBytes := Term → Term → Option ByteArray

def HotStore.versioned (store : HotStore) (versions : VersionBytes) : Prop :=
  ∀ key value, store key = some value → versions key value.etag = some value.bytes

theorem HotRead.version_bytes {store : HotStore} {versions : VersionBytes}
    {key etag : Term} {bytes : ByteArray} (versioned : store.versioned versions)
    (read : HotRead store key bytes etag) : versions key etag = some bytes :=
  versioned key ⟨etag, bytes⟩ read

/-- CAS success matches the captured bytes, even if other writers ran after the read. -/
theorem HotCAS.read_base_bytes {readStore before after : HotStore} {versions : VersionBytes}
    {key base result candidate : Term} {captured : ByteArray}
    (readVersioned : readStore.versioned versions) (currentVersioned : before.versioned versions)
    (read : HotRead readStore key captured base) (present : base ≠ nil)
    (cas : HotCAS before (.tuple [a "cas", key, candidate, base]) result after) :
    HotRead before key captured base := by
  have named := HotRead.version_bytes readVersioned read
  have condition : before.matches key base := by
    cases cas with
    | accepted key base bytes etag outcome condition => exact condition
  rcases condition with absent | ⟨_, value, current, sameVersion⟩
  · exact (present absent.1).elim
  · have currentName := currentVersioned key value current
    rw [sameVersion] at currentName
    have sameBytes := Option.some.inj (currentName.symm.trans named)
    cases value with
    | mk etag bytes =>
      change etag = base at sameVersion
      change bytes = captured at sameBytes
      subst etag bytes
      exact current

theorem HotStore.replace_versioned {store : HotStore} {versions : VersionBytes}
    {key etag : Term} {bytes : ByteArray} (before : store.versioned versions)
    (named : versions key etag = some bytes) : (store.replace key ⟨etag, bytes⟩).versioned versions := by
  classical
  intro other value current
  by_cases same : other = key
  · subst other
    have valueEq : HotObject.mk etag bytes = value := by
      simpa only [HotStore.replace, ↓reduceIte, Option.some.injEq] using current
    subst value
    exact named
  · have old : store other = some value := by simpa only [HotStore.replace, same, ↓reduceIte] using current
    exact before other value old

end VerifiedKernel.Session.WorkConservation
