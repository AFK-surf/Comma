import VerifiedKernelProofs.Session.WorkArchiveCatalog

namespace VerifiedKernel.Session.ArchivePublication
open Data WorkConservation
set_option Elab.async false

theorem pruneResultRefs_catalog {s t : Term} {j r : List Term}
    (h : pruneResultRefs s j = .ok (t, r)) : t.get (a "segment_catalog") = s.get (a "segment_catalog") := by
  unfold pruneResultRefs at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  · rw [pure_ok h]
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    exact write_field_frame h rfl

theorem recomputeContext_catalog {s t : Term} {j r : List Term}
    (h : recomputeContext s j = .ok (t, r)) : t.get (a "segment_catalog") = s.get (a "segment_catalog") := by
  unfold recomputeContext at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  exact write_field_frame h rfl

theorem pruneResultRefs_field {s t : Term} {key : String} {j r : List Term}
    (different : key ≠ "async_result_refs")
    (h : pruneResultRefs s j = .ok (t, r)) : t.get (a key) = s.get (a key) := by
  unfold pruneResultRefs at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  · rw [pure_ok h]
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    exact write_field_frame h (by simp [Ne.symm different])

theorem recomputeContext_field {s t : Term} {key : String} {j r : List Term}
    (different : key ≠ "live_context_bytes")
    (h : recomputeContext s j = .ok (t, r)) : t.get (a key) = s.get (a key) := by
  unfold recomputeContext at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  exact write_field_frame h (by simp [Ne.symm different])

theorem archiveAdvance_storage_fields {s e t : Term} {j r : List Term}
    (h : archiveAdvance s e j = .ok (t, r)) :
    t = s ∨ ∃ (catalog : List Term) (watermark : Int),
      catalog.Perm ((wrap (e.get (b "segments"))).filter validSegment) ∧
      t.get (a "segment_catalog") = list catalog ∧ t.get (a "archived_through") = i watermark ∧
      t.get (a "agent_id") = s.get (a "agent_id") ∧ t.get (a "session_id") = s.get (a "session_id") := by
  unfold archiveAdvance at h
  obtain ⟨through, _, _, h⟩ := bind_ok h
  obtain ⟨segments, _, segmentRead, h⟩ := bind_ok h
  have segmentsEq := (access_ok segmentRead).1
  split at h
  · exact Or.inl (pure_ok h)
  · rename_i admitted
    simp only [Bool.or_eq_true, Bool.not_eq_true', not_or, Bool.not_eq_false] at admitted
    obtain ⟨watermark, integerEq⟩ := isInteger_exists admitted.2
    subst through
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    split at h
    · exact Or.inl (pure_ok h)
    · obtain ⟨_, _, _, h⟩ := bind_ok h
      obtain ⟨_, _, _, h⟩ := bind_ok h
      split at h
      · exact Or.inl (pure_ok h)
      · obtain ⟨catalog, _, sorted, h⟩ := bind_ok h
        obtain ⟨_, _, _, h⟩ := bind_ok h
        obtain ⟨_, _, _, h⟩ := bind_ok h
        obtain ⟨_, _, _, h⟩ := bind_ok h
        obtain ⟨_, _, _, h⟩ := bind_ok h
        obtain ⟨_, _, _, h⟩ := bind_ok h
        obtain ⟨_, _, _, h⟩ := bind_ok h
        obtain ⟨_, _, _, h⟩ := bind_ok h
        obtain ⟨_, _, _, h⟩ := bind_ok h
        obtain ⟨_, _, _, h⟩ := bind_ok h
        obtain ⟨advanced, _, written, h⟩ := bind_ok h
        obtain ⟨pruned, _, prunedCall, h⟩ := bind_ok h
        have frame : ∀ key : String, key ≠ "live_context_bytes" → key ≠ "async_result_refs" →
            t.get (a key) = advanced.get (a key) := by
          intro key context refs
          exact (recomputeContext_field context h).trans (pruneResultRefs_field refs prunedCall)
        refine Or.inr ⟨catalog, watermark, ?_, ?_, ?_, ?_, ?_⟩
        · rw [← segmentsEq]
          exact sortBy_permutation sorted
        · rw [recomputeContext_catalog h, pruneResultRefs_catalog prunedCall]
          exact write_get_key "segment_catalog" written rfl
        · rw [frame "archived_through" (by decide) (by decide)]
          exact write_get_key "archived_through" written rfl
        · exact (frame "agent_id" (by decide) (by decide)).trans (write_field_frame written rfl)
        · exact (frame "session_id" (by decide) (by decide)).trans (write_field_frame written rfl)

theorem archiveAdvance_catalog {s e t : Term} {j r : List Term}
    (h : archiveAdvance s e j = .ok (t, r)) :
    t = s ∨ ∃ catalog, catalog.Perm ((wrap (e.get (b "segments"))).filter validSegment) ∧
      t.get (a "segment_catalog") = list catalog := by
  rcases archiveAdvance_storage_fields h with unchanged | ⟨catalog, _, permuted, read, _⟩
  · exact Or.inl unchanged
  · exact Or.inr ⟨catalog, permuted, read⟩

theorem archiveAdvance_keeps_published_catalog {s e t : Term} {j r : List Term}
    (filterExact : (wrap (e.get (b "segments"))).filter validSegment = wrap (e.get (b "segments")))
    (h : archiveAdvance s e j = .ok (t, r)) :
    t = s ∨ ∀ value ∈ wrap (e.get (b "segments")), value ∈ wrap (t.get (a "segment_catalog")) := by
  rcases archiveAdvance_catalog h with unchanged | ⟨catalog, permuted, stored⟩
  · exact Or.inl unchanged
  · apply Or.inr
    intro value member
    rw [stored]
    exact permuted.mem_iff.mpr (by rwa [filterExact])

/-- Removed input facts are reachable through the actual post-reduction catalog, not merely orphan objects. -/
theorem published_archive_catalog_input {state event next : Term} {records live : List Term}
    {base ceiling line : Int} {before after : Objects} {final : Output} {j r : List Term}
    (framing : CodecFraming) (sorted : SeqSorted state)
    (numeric : (state.get (a "archived_through")).default (i 0) = i base) (nonnegative : base ≥ 0)
    (initial : StateCatalogBacked before state)
    (catalog : ∀ value ∈ wrap ((state.get (a "segment_catalog")).default (list [])), validSegment value = true)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0)
    (execution : Execution (start state (i line)) before final after)
    (emitted : final.2 = .tuple [a "advance", event])
    (read : state.get (a "messages") = list live)
    (reduced : archiveAdvance state event j = .ok (next, r)) :
    next = state ∨ ∃ (dropped kept : List Term),
      live = dropped ++ kept ∧ next.get (a "messages") = list kept ∧
      ∀ item record, record ∈ dropped → ValueSemantics.Recorded item record →
        ∃ stored count actual,
          entry stored count ∈ wrap (next.get (a "segment_catalog")) ∧
          after (key (state.get (a "agent_id")) (state.get (a "session_id"))
            ((stored.head?.getD nil).get (a "seq"))) stored ∧ actual ∈ stored ∧
          ValueSemantics.Equivalent (queueWorkProjection item)
            ((actual.get (a "data")).get (b "accepted_input")) := by
  have exactFilter := publication_catalog_filter_exact framing numeric nonnegative initial catalog window positive execution emitted
  rcases archiveAdvance_keeps_published_catalog exactFilter reduced with unchanged | included
  · exact Or.inl unchanged
  · obtain ⟨dropped, kept, partition, afterRead, projections⟩ :=
      published_archive_removed_projections sorted numeric nonnegative initial window positive execution emitted read reduced
    refine Or.inr ⟨dropped, kept, partition, afterRead, ?_⟩
    intro item record member recorded
    obtain ⟨projected, projection, backed⟩ := projections record member
    obtain ⟨stored, count, actual, listed, fact, present, same⟩ := backed.catalog_mono included
    exact ⟨stored, count, actual, listed, fact, present,
      (projection.input_fact recorded).trans ((same.get (a "data")).get (b "accepted_input"))⟩

end VerifiedKernel.Session.ArchivePublication
