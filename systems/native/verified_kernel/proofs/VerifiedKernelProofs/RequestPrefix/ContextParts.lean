import VerifiedKernelProofs.RequestPrefix.Dispatch

/-!
The stages of `Session.Request.context`, and the state fields that its window stages read.
-/

namespace VerifiedKernel.RequestPrefix
open Data

set_option maxHeartbeats 4000000

/-- Two states hold the same value under the atom and binary key `k`. -/
def SameKey (s s' : Term) (k : String) : Prop :=
  s'.has (a k) = s.has (a k) ∧ s'.get (a k) = s.get (a k) ∧ s'.get (b k) = s.get (b k)

theorem context_parts {s v : Term} {j k : List Term} (h : Session.Request.context s j = .ok (v, k)) :
    ∃ pre live S C, (∃ j k, Session.CompactionQuery.contextPrefix s j = .ok (list pre, k)) ∧
      (∃ j k, Session.CompactionQuery.requestLiveMessages s j = .ok (list live, k)) ∧
      (∃ j k, Session.Presentation.sanitizeContext (pre ++ live) j = .ok (list S, k)) ∧
      (∃ j k, S.mapM (fun m => Session.RequestPage.fit Session.Request.annotate m >>= Session.Request.annotate) j =
        .ok (C, k)) ∧ v = list C := by
  unfold Session.Request.context at h
  simp only [Session.bind_ok_iff, Session.pure_ok_iff, Prod.mk.injEq] at h
  obtain ⟨p, _, hp, pl, _, hpl, l, _, hl, ll, _, hll, St, _, hS, S, _, hSl, C, _, hC, rfl, -⟩ := h
  obtain rfl := asList_ok hpl
  obtain rfl := asList_ok hll
  obtain rfl := asList_ok hSl
  exact ⟨pl, ll, S, C, ⟨_, _, hp⟩, ⟨_, _, hl⟩, ⟨_, _, hS⟩, ⟨_, _, hC⟩, rfl⟩

theorem promptSnapshot_nil {s v : Term} {j k : List Term} (h : Session.ReplyQuery.promptSnapshot s nil j = .ok (v, k)) :
    v = .tuple [list [], Session.ReplyQuery.presentTerm (s.get (a "system_prompt"))] := by
  unfold Session.ReplyQuery.promptSnapshot at h
  have hnil : Session.ReplyQuery.presentTerm nil = nil := by
    unfold Session.ReplyQuery.presentTerm; split <;> rfl
  simp only [hnil] at h
  rw [if_pos (by simp [Term.beq_self])] at h
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
  exact h.1

theorem field_ok_congr {s s' v : Term} {k : String} {j j' : List Term} (hm : s'.isMap = s.isMap)
    (h : SameKey s s' k) (ok : field s' k j = .ok (v, j')) : field s k j = .ok (v, j') := by
  unfold field fetch at ok ⊢
  rw [hm, h.1, h.2.1] at ok
  split at ok
  · simp [Session.fail_ok_iff] at ok
  · rw [if_neg ‹_›]
    split at ok
    · rw [if_pos ‹_›]; exact ok
    · simp [Session.fail_ok_iff] at ok

theorem contextPrefix_congr {s s' r : Term} {j k : List Term} (hm : s'.isMap = s.isMap)
    (hc : SameKey s s' "provider_compaction") (hs : SameKey s s' "summary")
    (h : Session.CompactionQuery.contextPrefix s' j = .ok (r, k)) :
    Session.CompactionQuery.contextPrefix s j = .ok (r, k) := by
  unfold Session.CompactionQuery.contextPrefix at h ⊢
  obtain ⟨it, j₁, hit, h⟩ := Session.bind_ok_iff.mp h
  refine Session.bind_ok_iff.mpr ⟨it, j₁, ?_, ?_⟩
  · unfold Session.CompactionQuery.providerCompactionItems at hit ⊢
    obtain ⟨c, j₂, hc', hit⟩ := Session.bind_ok_iff.mp hit
    exact Session.bind_ok_iff.mpr ⟨c, j₂, field_ok_congr hm hc hc', hit⟩
  · try dsimp only at h ⊢
    by_cases t : it.truthy = true
    · simp only [t, ↓reduceIte] at h ⊢; exact h
    · simp only [t, Bool.false_eq_true, ↓reduceIte] at h ⊢
      obtain ⟨sm, j₂, hsm, h⟩ := Session.bind_ok_iff.mp h
      exact Session.bind_ok_iff.mpr ⟨sm, j₂, field_ok_congr hm hs hsm, h⟩

end VerifiedKernel.RequestPrefix
