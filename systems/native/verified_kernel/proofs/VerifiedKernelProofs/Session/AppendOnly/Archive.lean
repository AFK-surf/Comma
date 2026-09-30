import VerifiedKernelProofs.Order
import VerifiedKernelProofs.Session.AppendOnly.Core

/-!
`archive_advance` is the one event that shortens the transcript. This file proves that it only
removes a prefix: for a transcript of plain messages stamped with nondecreasing integer `seq`
values, the new message list is a suffix of the old one, and every removed message sits at or
below the event's `archived_through` watermark.
-/

namespace VerifiedKernel.Session
open Data

set_option maxHeartbeats 4000000
set_option Elab.async false

/-- `f` answers `b` for `m` without consuming observations. -/
def Runs (f : Term → KernelM Bool) (m : Term) (b : Bool) : Prop := ∀ s, f m s = .ok (b, s)

theorem filterAuxM_keep_all (f : Term → KernelM Bool) (l acc : List Term) {s r res : List Term}
    (keep : ∀ m ∈ l, Runs f m true) (h : List.filterAuxM f l acc s = .ok (res, r)) :
    res = l.reverse ++ acc := by
  induction l generalizing acc s with
  | nil =>
    simp only [List.filterAuxM, pure_ok_iff, Prod.mk.injEq] at h
    exact h.1
  | cons m rest ih =>
    simp only [List.filterAuxM] at h
    obtain ⟨_, _, hm, h⟩ := bind_ok h
    rw [keep m (List.mem_cons_self ..)] at hm
    simp only [Except.ok.injEq, Prod.mk.injEq] at hm
    obtain ⟨rfl, rfl⟩ := hm
    rw [ih (keep := fun n hn => keep n (List.mem_cons_of_mem _ hn)) (h := h)]
    simp

/-- A filter whose verdict, once `true`, stays `true` along the list keeps a suffix. -/
theorem filterAuxM_suffix (f : Term → KernelM Bool) (l acc : List Term) {s r res : List Term}
    (decided : ∀ m ∈ l, ∃ b, Runs f m b)
    (mono : l.Pairwise (fun m n => Runs f m true → Runs f n true))
    (h : List.filterAuxM f l acc s = .ok (res, r)) :
    ∃ dropped kept, l = dropped ++ kept ∧ res = kept.reverse ++ acc ∧
      (∀ m ∈ dropped, Runs f m false) ∧ (∀ m ∈ kept, Runs f m true) := by
  induction l generalizing acc s with
  | nil =>
    simp only [List.filterAuxM, pure_ok_iff, Prod.mk.injEq] at h
    exact ⟨[], [], rfl, by simp [h.1], by simp, by simp⟩
  | cons m rest ih =>
    simp only [List.filterAuxM] at h
    obtain ⟨_, _, hm, h⟩ := bind_ok h
    obtain ⟨b, hb⟩ := decided m (List.mem_cons_self ..)
    rw [hb] at hm
    simp only [Except.ok.injEq, Prod.mk.injEq] at hm
    obtain ⟨rfl, rfl⟩ := hm
    rw [List.pairwise_cons] at mono
    cases b with
    | true =>
      have keep : ∀ n ∈ rest, Runs f n true := fun n hn => mono.1 n hn hb
      refine ⟨[], m :: rest, rfl, ?_, by simp, ?_⟩
      · rw [filterAuxM_keep_all f rest _ keep h]
        simp
      · intro n hn
        rcases List.mem_cons.mp hn with rfl | hn
        · exact hb
        · exact keep n hn
    | false =>
      obtain ⟨dropped, kept, hl, hres, hdrop, hkeep⟩ :=
        ih (decided := fun n hn => decided n (List.mem_cons_of_mem _ hn)) (mono := mono.2) (h := h)
      refine ⟨m :: dropped, kept, by rw [hl]; rfl, hres, ?_, hkeep⟩
      intro n hn
      rcases List.mem_cons.mp hn with rfl | hn
      · exact hb
      · exact hdrop n hn

theorem filterM_suffix (f : Term → KernelM Bool) (l : List Term) {s r : List Term} {res : List Term}
    (decided : ∀ m ∈ l, ∃ b, Runs f m b)
    (mono : l.Pairwise (fun m n => Runs f m true → Runs f n true))
    (h : List.filterM f l s = .ok (res, r)) :
    ∃ dropped kept, l = dropped ++ kept ∧ res = kept ∧
      (∀ m ∈ dropped, Runs f m false) ∧ (∀ m ∈ kept, Runs f m true) := by
  unfold List.filterM at h
  obtain ⟨_, _, haux, h⟩ := bind_ok h
  obtain ⟨dropped, kept, hl, hres, hdrop, hkeep⟩ := filterAuxM_suffix f l [] decided mono haux
  simp only [pure_ok_iff, Prod.mk.injEq] at h
  refine ⟨dropped, kept, hl, ?_, hdrop, hkeep⟩
  rw [h.1, hres]
  simp

theorem access_plain {v key : Term} (plain : (v.isMap && !v.has (a "__struct__")) = true) (s : List Term) :
    access v key s = .ok (v.get key, s) := by
  unfold access
  simp [plain, Pure.pure, StateT.pure, Except.pure]

theorem isInteger_exists {v : Term} (h : v.isInteger = true) : ∃ k : Int, v = .integer k := by
  cases v <;> simp [Term.isInteger] at h ⊢

/-- The archive filter's verdict on a plain message with an integer `seq`. -/
theorem archive_runs (i : Int) {m : Term} {k : Int} (plain : (m.isMap && !m.has (a "__struct__")) = true)
    (hk : m.get (a "seq") = .integer k) :
    Runs (fun message => do
      let seq ← access message (a "seq")
      if seq.isInteger then greater seq (.integer i) else pure true) m (decide (i < k)) := by
  intro s
  simp [Bind.bind, StateT.bind, access_plain plain, hk, Except.bind, greater_integer, Term.isInteger]

theorem pruneResultRefs_frame {s t : Term} {j r : List Term} (h : pruneResultRefs s j = .ok (t, r)) :
    t.get (a "messages") = s.get (a "messages") := by
  unfold pruneResultRefs at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  · simp only [pure_ok_iff, Prod.mk.injEq] at h
    rw [h.1]
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    exact write_frame h rfl

theorem recomputeContext_frame {s t : Term} {j r : List Term} (h : recomputeContext s j = .ok (t, r)) :
    t.get (a "messages") = s.get (a "messages") := by
  unfold recomputeContext at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  exact write_frame h rfl

/-- `archive_advance` keeps a suffix of the transcript. Every removed message has an integer
`seq` at or below the event's `archived_through`; the early-return branches remove nothing. -/
theorem archiveAdvance_suffix {s e t : Term} {j r : List Term} {xs : List Term}
    (read : s.get (a "messages") = .list xs)
    (plain : ∀ m ∈ xs, (m.isMap && !m.has (a "__struct__")) = true)
    (stamped : ∀ m ∈ xs, ∃ k : Int, m.get (a "seq") = .integer k)
    (sorted : xs.Pairwise (fun m n => integerValue (m.get (a "seq")) ≤ integerValue (n.get (a "seq"))))
    (h : archiveAdvance s e j = .ok (t, r)) :
    ∃ dropped kept, xs = dropped ++ kept ∧ t.get (a "messages") = .list kept ∧
      ∀ m ∈ dropped, integerValue (m.get (a "seq")) ≤ integerValue (e.get (b "archived_through")) := by
  unfold archiveAdvance at h
  replace h := bind_ok h
  obtain ⟨through, _, hthrough, h⟩ := h
  replace h := bind_ok h
  obtain ⟨segments, _, _, h⟩ := h
  obtain ⟨hthrough_eq, -⟩ := access_ok hthrough
  split at h
  · simp only [pure_ok_iff, Prod.mk.injEq] at h
    exact ⟨[], xs, rfl, by rw [h.1, read], by simp⟩
  rename_i hkinds
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  · simp only [pure_ok_iff, Prod.mk.injEq] at h
    exact ⟨[], xs, rfl, by rw [h.1, read], by simp⟩
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  · simp only [pure_ok_iff, Prod.mk.injEq] at h
    exact ⟨[], xs, rfl, by rw [h.1, read], by simp⟩
  simp only [Bool.or_eq_true, Bool.not_eq_true', not_or, Bool.not_eq_false] at hkinds
  obtain ⟨i, hi⟩ := isInteger_exists hkinds.2
  subst hi
  try dsimp only at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, hread, h⟩ := bind_ok h
  simp only [field, fetch_ok_iff] at hread
  obtain ⟨_, _, rfl, _⟩ := hread
  rw [read, default_list] at h
  obtain ⟨_, _, hmap, h⟩ := bind_ok h
  rw [enumMap_list_pure] at hmap
  simp only [Except.ok.injEq, Prod.mk.injEq] at hmap
  obtain ⟨rfl, rfl⟩ := hmap
  obtain ⟨kept0, _, hfilter, h⟩ := bind_ok h
  have decided : ∀ m ∈ xs, ∃ b, Runs (fun message => do
      let seq ← access message (a "seq")
      if seq.isInteger then greater seq (.integer i) else pure true) m b := by
    intro m hm
    obtain ⟨k, hk⟩ := stamped m hm
    exact ⟨_, archive_runs i (plain m hm) hk⟩
  have mono : xs.Pairwise (fun m n => Runs (fun message => do
      let seq ← access message (a "seq")
      if seq.isInteger then greater seq (.integer i) else pure true) m true → Runs (fun message => do
      let seq ← access message (a "seq")
      if seq.isInteger then greater seq (.integer i) else pure true) n true) := by
    refine List.Pairwise.imp_of_mem ?_ sorted
    intro m n hm hn hle hkeep
    obtain ⟨km, hkm⟩ := stamped m hm
    obtain ⟨kn, hkn⟩ := stamped n hn
    have runm := archive_runs i (plain m hm) hkm
    have runn := archive_runs i (plain n hn) hkn
    have : decide (i < km) = true := by
      have := (hkeep []).symm.trans (runm [])
      simpa using this
    rw [hkm, hkn] at hle
    simp only [integerValue] at hle
    have : decide (i < kn) = true := by
      simp only [decide_eq_true_eq] at this ⊢
      exact Int.lt_of_lt_of_le this hle
    rw [this] at runn
    exact runn
  obtain ⟨dropped, kept, hxs, rfl, hdrop, -⟩ := filterM_suffix _ xs decided mono hfilter
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨advanced, _, hwrite, h⟩ := bind_ok h
  obtain ⟨pruned, _, hprune, h⟩ := bind_ok h
  refine ⟨dropped, _, hxs, ?_, ?_⟩
  · rw [recomputeContext_frame h, pruneResultRefs_frame hprune, write_get hwrite rfl]
    rfl
  · intro m hm
    obtain ⟨k, hk⟩ := stamped m (by rw [hxs]; exact List.mem_append_left _ hm)
    have plainm := plain m (by rw [hxs]; exact List.mem_append_left _ hm)
    have := (hdrop m hm []).symm.trans (archive_runs i plainm hk [])
    simp only [Except.ok.injEq, Prod.mk.injEq] at this
    rw [hk, ← hthrough_eq]
    simpa [integerValue] using this.1

end VerifiedKernel.Session
