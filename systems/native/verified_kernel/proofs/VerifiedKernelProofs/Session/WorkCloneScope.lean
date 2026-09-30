import VerifiedKernelProofs.Session.WorkPhysicalInvariant

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

def cloneOwnerEvent (owner : ByteArray) : Term :=
  .map [(b "type", b "session_stamp"), (b "agent_id", .binary owner)]

theorem clone_owner_event_keys (owner : ByteArray) : BinaryKeys (cloneOwnerEvent owner) := by
  rfl

theorem clone_owner_event_kind (owner : ByteArray) :
    (cloneOwnerEvent owner).get (b "type") = b "session_stamp" := by rfl

theorem clone_owner_event_nonretiring (owner : ByteArray) : NonRetiring (cloneOwnerEvent owner) := by
  unfold NonRetiring
  rw [clone_owner_event_kind]
  exact ⟨no_binary_tag rfl, no_binary_tag rfl, no_binary_tag rfl⟩

theorem clone_stamp_owner {state next : Term} {owner : ByteArray} {journal rest : List Term}
    (call : sessionStamp state (cloneOwnerEvent owner) journal = .ok (next, rest)) :
    next.get (a "agent_id") = .binary owner := by
  unfold sessionStamp at call
  obtain ⟨initial, _, first, call⟩ := bind_ok call
  have owned : initial.get (a "agent_id") = .binary owner := by
    unfold stampAgentId at first
    simp only [show (cloneOwnerEvent owner).has (b "agent_id") = true from rfl, ↓reduceIte] at first
    obtain ⟨value, _, read, first⟩ := bind_ok first
    have valueEq := (access_ok read).1
    obtain ⟨_, first⟩ := write_cons first
    rw [pure_ok first, get_put_same]
    exact valueEq
  obtain ⟨_, _, step, call⟩ := bind_ok call
  have owned := (stampRuntimeEpoch_owner step).trans owned
  obtain ⟨_, _, step, call⟩ := bind_ok call
  have owned := (stampRuntimeNode_owner step).trans owned
  obtain ⟨_, _, step, call⟩ := bind_ok call
  have owned := (stampActivityRevision_owner step).trans owned
  obtain ⟨_, _, step, call⟩ := bind_ok call
  have owned := (stampStorageRevision_owner step).trans owned
  obtain ⟨_, _, step, call⟩ := bind_ok call
  have owned := (stampFlushId_owner step).trans owned
  obtain ⟨_, _, step, call⟩ := bind_ok call
  have owned := (stampWorkIndexToken_owner step).trans owned
  exact (stampWorkReasons_owner call).trans owned

theorem clone_owner_batch {state next : Term} {owner : ByteArray}
    (execution : ResidentBatch state [cloneOwnerEvent owner] next) :
    next.get (a "agent_id") = .binary owner := by
  cases execution with
  | cons head tail =>
    cases tail
    obtain ⟨reduced, normalized, journal, rest, prepared, activity⟩ := resident_execution_step head
    have executed : ∃ first last, inner state (cloneOwnerEvent owner) first = .ok (reduced, last) := by
      cases normalized with
      | some event =>
        obtain ⟨_, read, _, call⟩ := prepareTrusted_stringify prepared
        have same := shallowStringify_binary_keys (clone_owner_event_keys owner) read
        subst event
        exact ⟨_, _, call⟩
      | none =>
        unfold prepareTrusted at prepared
        simp only [bind_ok_iff, ite_ok_iff, fail_ok_iff, false_and, and_false, exists_false, false_or,
          or_false, pure_ok_iff, Prod.mk.injEq, reduceCtorEq, and_true] at prepared
        obtain ⟨_, _, event, _, read, mismatch, _⟩ := prepared
        have same := shallowStringify_binary_keys (clone_owner_event_keys owner) read
        subst event
        have impossible : ((cloneOwnerEvent owner).get (b "session_id")).isBinary = false := rfl
        simp only [impossible, Bool.false_and, Bool.false_eq_true] at mismatch
    obtain ⟨first, last, call⟩ := executed
    have actual : sessionStamp state (cloneOwnerEvent owner) first = .ok (reduced, last) := by
      simpa +decide [inner, clone_owner_event_kind] using call
    exact (activity "agent_id" (by decide) (by decide)).trans (clone_stamp_owner actual)

theorem PhysicalInvariant.clone_owner {objects : Objects} {oldOwner owner session : ByteArray}
    {state next : Term}
    (before : PhysicalInvariant objects oldOwner session state [])
    (emptyCatalog : state.get (a "segment_catalog") = list [])
    (execution : ResidentBatch state [cloneOwnerEvent owner] next) :
    PhysicalInvariant objects owner session next [] := by
  have canonical : ∀ event ∈ [cloneOwnerEvent owner], BinaryKeys event := by
    simpa using clone_owner_event_keys owner
  have safe : ∀ event ∈ [cloneOwnerEvent owner], NonRetiring event := by
    simpa using clone_owner_event_nonretiring owner
  have fields := batch_catalog_frame execution canonical (fun event member => binary_ne_false (safe event member).2.2)
  refine ⟨.nonretiring before.history execution canonical safe, fields.archive before.archive,
    before.nonnegative.fields fields.2.1, ?_, ?_, clone_owner_batch execution,
    fields.2.2.trans before.identified⟩
  · intro entry member
    rw [fields.1, emptyCatalog] at member
    simp [list, Term.default, Term.truthy, wrap] at member
  · simp [SealedImagesBacked]

end VerifiedKernel.Session.WorkConservation
