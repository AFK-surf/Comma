import VerifiedKernelProofs.Session.AppendOnly.SeqRuntime

/-!
The `seq` invariant across the history reducers that rewrite or shorten the transcript:
`session_microcompact` and `archive_advance`.
-/

namespace VerifiedKernel.Session
open Data

set_option maxHeartbeats 4000000
set_option Elab.async false

theorem mergePredicate_seq {s kind through replacement extra t : Term} {j r : List Term}
    (h : mergePredicate s kind through replacement extra j = .ok (t, r)) : SeqStep s t := by
  unfold mergePredicate at h
  sorted_walk h

theorem mergePredicate_sstep {s kind through replacement extra t : Term} {j r : List Term} :
    mergePredicate s kind through replacement extra j = .ok (t, r) ↔
      Except.ok (t, r) = mergePredicate s kind through replacement extra j ∧ SeqStep s t :=
  step_iff mergePredicate_seq

theorem microcompactIds_seq {s : Term} {ids : List Term} {replacement e t : Term} {j r : List Term}
    (h : microcompactIds s ids replacement e j = .ok (t, r)) : SeqStep s t := by
  unfold microcompactIds at h
  sorted_walk h

theorem microcompactIds_sstep {s : Term} {ids : List Term} {replacement e t : Term} {j r : List Term} :
    microcompactIds s ids replacement e j = .ok (t, r) ↔
      Except.ok (t, r) = microcompactIds s ids replacement e j ∧ SeqStep s t :=
  step_iff microcompactIds_seq

theorem get_put_binary (v x : Term) (raw : ByteArray) (k : String) :
    (Term.put v (Term.binary raw) x).get (Term.atom k) = v.get (Term.atom k) := by
  cases v with
  | map entries =>
    simp only [Term.put, Term.get, List.find?_cons]
    have head : (Term.binary raw == Term.atom k) = false := by simp [BEq.beq]
    rw [head]
    simp only
    rw [find?_filter_of_imp]
    intro e he
    have := atom_beq_true he
    simp [this, BEq.beq]
  | _ => simp [Term.put, Term.get, BEq.beq]

theorem microcompact_seq {s e t : Term} {j r : List Term} (h : microcompact s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold microcompact at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  try dsimp only at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, hx, h⟩ := bind_ok h
  simp only [field, fetch_ok_iff] at hx
  obtain ⟨_, _, rfl, _⟩ := hx
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  · split at h
    · exact mergePredicate_seq h
    · split at h
      · exact mergePredicate_seq h
      · exact microcompactIds_seq h
  · obtain ⟨_, _, hx, h⟩ := bind_ok h
    simp only [field, fetch_ok_iff] at hx
    obtain ⟨_, _, rfl, _⟩ := hx
    obtain ⟨ys, _, hmap, h⟩ := bind_ok h
    rintro ⟨xs, n, hread, hlast, hstamped, hsorted⟩
    rw [hread, default_list] at hmap
    have stamps := enumMap_stamps ?keep hmap
    case keep =>
      intro x y s' r' hxy
      repeat first
        | (obtain ⟨_, _, _, hxy⟩ := bind_ok hxy)
        | (dsimp only at hxy)
      rw [ite_ok_iff] at hxy
      rcases hxy with ⟨-, hxy⟩ | ⟨-, hxy⟩
      · unfold Data.put at hxy
        rw [ite_ok_iff] at hxy
        rcases hxy with ⟨-, hxy⟩ | ⟨-, hxy⟩
        · simp only [pure_ok_iff, Prod.mk.injEq] at hxy
          rw [hxy.1]
          split
          · exact get_put_other _ _ (by decide)
          · exact get_put_binary _ _ _ _
        · exact (fail_ok hxy).elim
      · simp only [pure_ok_iff, Prod.mk.injEq] at hxy
        rw [hxy.1]
    exact seq_of_map hread stamps (write_get_key "messages" h rfl) (write_frame_key "last_seq" h rfl)
      ⟨xs, n, hread, hlast, hstamped, hsorted⟩

theorem microcompact_sstep {s e t : Term} {j r : List Term} :
    microcompact s e j = .ok (t, r) ↔ Except.ok (t, r) = microcompact s e j ∧ SeqStep s t :=
  step_iff microcompact_seq

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
    ⟨kept, n, write_get_key "messages" hwrite rfl, by rw [lastSeq, write_frame_key "last_seq" hwrite rfl]; exact hlast,
      fun m hm => hstamped m (sub.subset hm), hsorted.sublist sub⟩
  exact recomputeContext_seq h (pruneResultRefs_seq hprune step)

theorem archiveAdvance_sstep {s e t : Term} {j r : List Term} :
    archiveAdvance s e j = .ok (t, r) ↔ Except.ok (t, r) = archiveAdvance s e j ∧ SeqStep s t :=
  step_iff archiveAdvance_seq

end VerifiedKernel.Session
