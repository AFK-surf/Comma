import VerifiedKernelProofs.Session.WorkPhysicalFence

namespace VerifiedKernel.Session.WorkConservation.ValueSemantics
open Data
set_option Elab.async false

theorem Equivalent.rigid_list {values : List Term} {other : Term}
    (same : Equivalent (Data.list values) other)
    (rigid : ∀ value ∈ values, ∀ next, Equivalent value next → next = value) : other = Data.list values := by
  obtain ⟨next, read, length, related⟩ := same.list
  have equal : next = values := by
    apply List.ext_getElem length.symm
    intro index nextBound valueBound
    have field := related index
    simp only [List.getElem?_eq_getElem valueBound, List.getElem?_eq_getElem nextBound, Option.getD_some] at field
    exact rigid values[index] (List.getElem_mem valueBound) next[index] field
  rwa [equal] at read

theorem Equivalent.valid_segment {value next : Term}
    (valid : validSegment value = true) (same : Equivalent value next) : next = value := by
  unfold validSegment at valid
  split at valid
  · apply same.rigid_list
    intro value member next equivalent
    simp only [List.mem_cons, List.mem_nil_iff, or_false] at member
    rcases member with rfl | rfl | rfl | rfl
    all_goals exact equivalent.integer
  · cases valid

theorem Equivalent.catalog {state next : Term} {catalog : List Term}
    (same : Equivalent state next) (read : state.get (a "segment_catalog") = Data.list catalog)
    (valid : ∀ value ∈ catalog, validSegment value = true) : next.get (a "segment_catalog") = Data.list catalog := by
  have field := same.get (a "segment_catalog")
  rw [read] at field
  exact field.rigid_list (fun value member next equivalent => equivalent.valid_segment (valid value member))

end VerifiedKernel.Session.WorkConservation.ValueSemantics

namespace VerifiedKernel.Session.ArchivePublication
open Data WorkConservation
set_option Elab.async false

theorem SealedImagesBacked.fields {objects : Objects} {state next : Term} {sealed : List Term}
    (owner : next.get (a "agent_id") = state.get (a "agent_id"))
    (session : next.get (a "session_id") = state.get (a "session_id"))
    (catalog : next.get (a "segment_catalog") = state.get (a "segment_catalog"))
    (backed : SealedImagesBacked objects state sealed) : SealedImagesBacked objects next sealed := by
  simpa only [SealedImagesBacked, owner, session, catalog] using backed

theorem SealedImagesBacked.equivalent {objects : Objects} {state next : Term} {sealed catalog : List Term}
    {owner session : ByteArray}
    (same : ValueSemantics.Equivalent state next)
    (owned : state.get (a "agent_id") = .binary owner) (identified : state.get (a "session_id") = .binary session)
    (read : state.get (a "segment_catalog") = list catalog)
    (valid : ∀ value ∈ catalog, validSegment value = true)
    (backed : SealedImagesBacked objects state sealed) : SealedImagesBacked objects next sealed := by
  have nextOwner := same.get (a "agent_id")
  have nextSession := same.get (a "session_id")
  rw [owned] at nextOwner
  rw [identified] at nextSession
  exact backed.fields (nextOwner.binary.trans owned.symm) (nextSession.binary.trans identified.symm)
    ((same.catalog read valid).trans read.symm)

theorem SealedImagesBacked.normalize {objects : Objects} {state next : Term} {sealed catalog journal rest : List Term}
    {watermark : Int}
    (owned : state.get (a "agent_id") ≠ nil) (identified : state.get (a "session_id") ≠ nil)
    (read : state.get (a "segment_catalog") = list catalog)
    (through : state.get (a "archived_through") = i watermark)
    (valid : ∀ value ∈ catalog, validSegment value = true)
    (call : Lifecycle.normalize state journal = .ok (next, rest))
    (backed : SealedImagesBacked objects state sealed) : SealedImagesBacked objects next sealed :=
  backed.fields (normalize_owner owned call) (normalize_session_id identified call)
    ((normalize_archive_fields read through valid call).1.trans read.symm)

end VerifiedKernel.Session.ArchivePublication
