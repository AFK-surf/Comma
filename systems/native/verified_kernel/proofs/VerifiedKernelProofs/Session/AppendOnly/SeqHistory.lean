import VerifiedKernelProofs.Session.AppendOnly.SeqRuntime

/-!
The `seq` invariant across the history reducer that shortens the transcript:
`archive_advance`.
-/

namespace VerifiedKernel.Session
open Data

set_option maxHeartbeats 4000000
set_option Elab.async false

theorem archiveAdvance_seq {s e t : Term} {j r : List Term} (h : archiveAdvance s e j = .ok (t, r)) :
    SeqStep s t := by
  rintro ⟨xs, n, hread, hlast, hstamped, hsorted⟩
  unfold archiveAdvance at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  · simp only [pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨rfl, -⟩ := h
    exact ⟨xs, n, hread, hlast, hstamped, hsorted⟩
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  · simp only [pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨rfl, -⟩ := h
    exact ⟨xs, n, hread, hlast, hstamped, hsorted⟩
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  · simp only [pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨rfl, -⟩ := h
    exact ⟨xs, n, hread, hlast, hstamped, hsorted⟩
  try dsimp only at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, hx, h⟩ := bind_ok h
  simp only [field, fetch_ok_iff] at hx
  obtain ⟨_, _, rfl, _⟩ := hx
  rw [hread, default_list] at h
  obtain ⟨_, _, hmap, h⟩ := bind_ok h
  rw [enumMap_list_pure] at hmap
  simp only [Except.ok.injEq, Prod.mk.injEq] at hmap
  obtain ⟨rfl, rfl⟩ := hmap
  obtain ⟨kept, _, hfilter, h⟩ := bind_ok h
  have sub := filterM_sublist _ _ hfilter
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨advanced, _, hwrite, h⟩ := bind_ok h
  obtain ⟨pruned, _, hprune, h⟩ := bind_ok h
  have step : SeqSorted advanced :=
    ⟨kept, n, write_get_key "messages" hwrite rfl, by rw [lastSeq, write_frame_key "last_seq" hwrite (by keys_absent)]; exact hlast,
      fun m hm => hstamped m (sub.subset hm), hsorted.sublist sub⟩
  exact recomputeContext_seq h (pruneResultRefs_seq hprune step)

theorem archiveAdvance_sstep {s e t : Term} {j r : List Term} :
    archiveAdvance s e j = .ok (t, r) ↔ Except.ok (t, r) = archiveAdvance s e j ∧ SeqStep s t :=
  step_iff archiveAdvance_seq

end VerifiedKernel.Session
