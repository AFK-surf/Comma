import VerifiedKernelProofs.Session.WorkNormalization

namespace VerifiedKernel.Session.WorkConservation
open Data

/-- A successful append cannot remove an earlier canonical queue item, including on deduplication. -/
theorem queueAppend_keeps_queue {s e t : Term} {items : List Term} {j r : List Term}
    (read : s.get (a "input_queue") = list items)
    (canonical : ∀ item ∈ items, CanonicalQueueItem item)
    (h : queueAppend s e j = .ok (t, r)) :
    ∃ kept, t.get (a "input_queue") = list kept ∧ items ⊆ kept := by
  unfold queueAppend at h
  split at h
  · obtain ⟨_, _, failed, _⟩ := bind_ok h
    simp only [fail_ok_iff] at failed
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨hit, _, _, h⟩ := bind_ok h
    cases hit with
    | true =>
      have eq := pure_ok h
      subst t
      exact ⟨items, read, List.Subset.refl _⟩
    | false =>
      iterate 6 obtain ⟨_, _, _, h⟩ := bind_ok h
      obtain ⟨raw, _, rawRead, h⟩ := bind_ok h
      obtain ⟨normalized, _, normalizedRead, h⟩ := bind_ok h
      have rawValue : raw = list items := by
        simp only [field, fetch_ok_iff] at rawRead
        exact rawRead.2.2.1.trans read
      rw [rawValue] at normalizedRead
      have perm := normalizeQueue_permutation canonical normalizedRead
      iterate 6 obtain ⟨_, _, _, h⟩ := bind_ok h
      obtain ⟨_, h⟩ := write_cons h
      have frame := write_field_frame (key := "input_queue") h rfl
      refine ⟨_, frame.trans (get_put_same _ _ _), ?_⟩
      intro item member
      exact List.mem_append_left _ (perm.mem_iff.mpr member)

end VerifiedKernel.Session.WorkConservation
