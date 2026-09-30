import VerifiedKernelProofs.Session.WorkPhysicalCommit

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

/-- One current hot object. Historical versions are not members of this store. -/
structure HotObject where
  etag : Term
  bytes : ByteArray

abbrev HotStore := Term → Option HotObject

noncomputable def HotStore.replace (store : HotStore) (key : Term) (value : HotObject) : HotStore := by
  classical
  exact fun other => if other = key then some value else store other

def HotStore.current (store : HotStore) : HotSnapshots := fun key etag snapshot =>
  ∃ bytes, store key = some ⟨etag, bytes⟩ ∧
    ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes

def HotStore.matches (store : HotStore) (key base : Term) : Prop :=
  (base = nil ∧ store key = none) ∨ (base ≠ nil ∧ ∃ value, store key = some value ∧ value.etag = base)

/-- The storage primitive's atomic successful CAS. It makes no application-level preservation claim. -/
inductive HotCAS : HotStore → Term → Term → HotStore → Prop where
  | accepted (before : HotStore) (key base : Term) (bytes : ByteArray) (etag outcome : Term)
      (condition : before.matches key base) :
      HotCAS before (.tuple [a "cas", key, .binary bytes, base]) (.tuple [a "ok", etag, outcome])
        (before.replace key ⟨etag, bytes⟩)

theorem HotCAS.snapshot_meaning {before after : HotStore} {request result : Term}
    (step : HotCAS before request result after) : SnapshotCASMeaning request result after.current := by
  cases step with
  | accepted issued base bytes version outcome condition =>
    intro key expected encoded snapshot etag status requestEq encoding resultEq
    simp only [Term.tuple.injEq, Term.binary.injEq, List.cons.injEq, and_true, true_and] at requestEq resultEq
    obtain ⟨rfl, rfl, rfl⟩ := requestEq
    obtain ⟨rfl, rfl⟩ := resultEq
    exact ⟨bytes, by simp [HotStore.replace], encoding⟩

theorem HotCAS.only_requested_key {before after : HotStore} {key base result : Term} {bytes : ByteArray}
    (step : HotCAS before (.tuple [a "cas", key, .binary bytes, base]) result after) :
    before.matches key base ∧ ∀ other, other ≠ key → after other = before other := by
  cases step with
  | accepted key base bytes etag outcome condition =>
    exact ⟨condition, fun other different => by simp [HotStore.replace, different]⟩

/-- The applied write creates this current candidate, independently of reply delivery. -/
theorem HotCAS.current_candidate {before after : HotStore} {key base result snapshot : Term} {bytes : ByteArray}
    (cas : HotCAS before (.tuple [a "cas", key, .binary bytes, base]) result after)
    (encoded : ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes) :
    ∃ etag, after.current key etag snapshot := by
  cases cas with
  | accepted key base bytes etag outcome condition =>
    exact ⟨etag, bytes, by simp [HotStore.replace], encoded⟩

theorem HotStore.current_revision_unique {store : HotStore} {key left right one two : Term}
    (first : store.current key left one) (second : store.current key right two) : left = right := by
  obtain ⟨bytes, stored, _⟩ := first
  obtain ⟨otherBytes, sameKey, _⟩ := second
  have same := Option.some.inj (stored.symm.trans sameKey)
  exact congrArg HotObject.etag same

theorem HotStore.overwritten_not_current {store : HotStore} {key previous next snapshot : Term} {bytes : ByteArray}
    (different : previous ≠ next) : ¬ (store.replace key ⟨next, bytes⟩).current key previous snapshot := by
  rintro ⟨oldBytes, stored, _⟩
  have same : (HotObject.mk next bytes) = ⟨previous, oldBytes⟩ := by
    simpa only [HotStore.replace, ↓reduceIte, Option.some.injEq] using stored
  exact different (congrArg HotObject.etag same).symm

/-- A read observes the bytes and ETag of the same current object. -/
def HotRead (store : HotStore) (key : Term) (bytes : ByteArray) (etag : Term) : Prop :=
  store key = some ⟨etag, bytes⟩

theorem HotRead.snapshot_bytes {store : HotStore} {key etag snapshot : Term} {bytes : ByteArray}
    (read : HotRead store key bytes etag) (current : store.current key etag snapshot) :
    ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes := by
  obtain ⟨storedBytes, stored, encoded⟩ := current
  have same := congrArg HotObject.bytes (Option.some.inj (read.symm.trans stored))
  change bytes = storedBytes at same
  simpa only [same] using encoded

end VerifiedKernel.Session.WorkConservation
