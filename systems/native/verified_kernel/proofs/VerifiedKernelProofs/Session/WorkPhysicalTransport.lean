import VerifiedKernelProofs.Session.WorkPhysicalInvariant

namespace VerifiedKernel.Session.ArchivePublication
open Data WorkConservation
set_option Elab.async false

/-- Transport every physical work fact, including catalog records outside a chosen ghost history. -/
theorem physical_work_transport {before after : Objects} {state next : Term}
    (extension : ObjectsExtend before after)
    (owner : next.get (a "agent_id") = state.get (a "agent_id"))
    (session : next.get (a "session_id") = state.get (a "session_id"))
    (catalog : ∀ value ∈ wrap ((state.get (a "segment_catalog")).default (list [])),
      value ∈ wrap ((next.get (a "segment_catalog")).default (list [])))
    (live : ∀ item, ValueSemantics.Represented state [] item → PhysicalIdentityFact after next (.work item)) :
    ∀ item, PhysicalIdentityFact before state (.work item) → PhysicalIdentityFact after next (.work item) := by
  intro item present
  rcases present with present | ⟨record, recorded, projected, projection, stored⟩
  · exact live item present
  · refine Or.inr ⟨record, recorded, projected, projection, ?_⟩
    rw [owner, session]
    exact (stored.mono extension).catalog_mono catalog

theorem physical_work_equivalent {objects : Objects} {state next : Term} {owner session : ByteArray}
    {catalog : List Term} (codec : ValueSemantics.Equivalent state next)
    (owned : state.get (a "agent_id") = .binary owner) (identified : state.get (a "session_id") = .binary session)
    (read : state.get (a "segment_catalog") = list catalog) (valid : ∀ value ∈ catalog, validSegment value = true) :
    ∀ item, PhysicalIdentityFact objects state (.work item) → PhysicalIdentityFact objects next (.work item) := by
  have nextOwner := codec.get (a "agent_id")
  have nextSession := codec.get (a "session_id")
  rw [owned] at nextOwner
  rw [identified] at nextSession
  apply physical_work_transport (fun _ _ stored => stored)
    (nextOwner.binary.trans owned.symm) (nextSession.binary.trans identified.symm)
  · intro value member
    simpa only [codec.catalog read valid, read] using member
  · exact fun item present => Or.inl (codec.represents present)

theorem physical_work_objects {before after : Objects} {state : Term}
    (extension : ObjectsExtend before after) :
    ∀ item, PhysicalIdentityFact before state (.work item) → PhysicalIdentityFact after state (.work item) :=
  physical_work_transport extension rfl rfl (fun _ member => member) (fun _ present => Or.inl present)

end VerifiedKernel.Session.ArchivePublication

namespace VerifiedKernel.Session.WorkConservation.ValueSemantics
open Data
set_option Elab.async false

theorem live_represents {state item : Term} {sealed : List Term} (present : Represented state [] item) :
    Represented state sealed item := by
  rcases present with queued | live | ⟨record, member, _⟩
  · exact Or.inl queued
  · exact Or.inr (Or.inl live)
  · cases member

end VerifiedKernel.Session.WorkConservation.ValueSemantics
