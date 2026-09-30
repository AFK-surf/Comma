import VerifiedKernelProofs.Session.WorkKernelHistory

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

def ArchiveInvariant (state : Term) : Prop :=
  ∃ catalog : List Term, ∃ watermark : Int,
    state.get (a "segment_catalog") = list catalog ∧
    state.get (a "archived_through") = i watermark ∧
    ∀ value ∈ catalog, validSegment value = true

theorem InitialFields.archive {state : Term} (initial : InitialFields state) : ArchiveInvariant state :=
  ⟨[], 0, initial.catalog, initial.archived, by simp⟩

theorem ArchiveInvariant.fields {state next : Term}
    (catalog : next.get (a "segment_catalog") = state.get (a "segment_catalog"))
    (watermark : next.get (a "archived_through") = state.get (a "archived_through"))
    (before : ArchiveInvariant state) : ArchiveInvariant next := by
  obtain ⟨entries, through, read, base, valid⟩ := before
  exact ⟨entries, through, catalog.trans read, watermark.trans base, valid⟩

theorem ArchiveInvariant.normalize {state next : Term} {journal rest : List Term}
    (before : ArchiveInvariant state) (call : Lifecycle.normalize state journal = .ok (next, rest)) :
    ArchiveInvariant next := by
  obtain ⟨catalog, watermark, read, through, valid⟩ := before
  have fields := normalize_archive_fields read through valid call
  exact ⟨catalog, watermark, fields.1, fields.2, valid⟩

theorem ArchiveInvariant.prepare {state next : Term} {journal rest : List Term}
    (before : ArchiveInvariant state) (format : state.get (a "storage_format") = i 3)
    (call : Lifecycle.prepareWrite state journal = .ok (.tuple [a "ok", next], rest)) :
    ArchiveInvariant next := by
  obtain ⟨catalog, watermark, read, through, valid⟩ := before
  have fields := prepareWrite_archive_fields format read through valid call
  exact ⟨catalog, watermark, fields.1, fields.2, valid⟩

theorem ArchiveInvariant.persist {state next : Term} {journal rest : List Term}
    (before : ArchiveInvariant state) (call : Lifecycle.persistable state journal = .ok (next, rest)) :
    ArchiveInvariant next :=
  before.fields (persistable_archive_fields call).1 (persistable_archive_fields call).2

theorem ArchiveInvariant.equivalent {state next : Term}
    (before : ArchiveInvariant state) (codec : ValueSemantics.Equivalent state next) : ArchiveInvariant next := by
  obtain ⟨catalog, watermark, read, through, valid⟩ := before
  have base := codec.get (a "archived_through")
  rw [through] at base
  exact ⟨catalog, watermark, codec.catalog read valid, base.integer, valid⟩

theorem ArchiveInvariant.advance {state event next : Term} {journal rest : List Term}
    (before : ArchiveInvariant state) (call : archiveAdvance state event journal = .ok (next, rest)) :
    ArchiveInvariant next := by
  rcases archiveAdvance_storage_fields call with same | ⟨catalog, watermark, permuted, read, through, _⟩
  · rwa [same]
  · refine ⟨catalog, watermark, read, through, ?_⟩
    intro value member
    exact (List.mem_filter.mp (permuted.mem_iff.mp member)).2

end VerifiedKernel.Session.WorkConservation
