import VerifiedKernelProofs.RequestPrefix.Stateless

/-!
The live window of a Session request only appends when the transcript only grows.

`Session.CompactionQuery.requestLiveMessages` reads the stored transcript, keeps the messages
above the compaction watermark that are not runtime events, and keeps a project-knowledge message
only where its content first appears. Each decision reads only earlier messages, so when the
transcript grows from `xs` to `xs ++ ys` under the same watermark, the window grows by appending.
-/

namespace VerifiedKernel.RequestPrefix
open Data ProviderLoop
open Session.CompactionQuery Session.StateQuery

set_option maxHeartbeats 4000000

/-! ### The stages of `requestLiveMessages` -/

/-- `requestLiveMessages` after the stored transcript is read. -/
def liveTail (watermark : Term) (stored : List Term) : KernelM Term := do
  let kept ← stored.filterM (fun message => greater ((message.get (a "id")).default (i 0)) watermark)
  let kept ← kept.filterM (fun message => do return (← messageRole message) != b "event")
  return list (← (← firstKnowledge kept).mapM modelMessage)

/-- `requestLiveMessages` restated with the named stages. -/
theorem requestLiveMessages_eq (state : Term) : requestLiveMessages state =
    liveTail ((state.get (a "compacted_through")).default (i 0))
      (listItems ((state.get (a "messages")).default (list []))) := rfl

theorem default_list (xs : List Term) (fallback : Term) : (list xs).default fallback = list xs := rfl

theorem knowledgeStep.stateless (st : List Term × List Term) (m : Term) :
    Stateless (knowledgeStep st m) := by stateless

/-! ### List runs -/

/-- `filterAuxM` prepends the kept elements, reversed, to its accumulator. -/
theorem filterAuxM_acc {α : Type} (p : α → KernelM Bool) : ∀ (xs acc : List α),
    List.filterAuxM p xs acc = (· ++ acc) <$> List.filterAuxM p xs []
  | [], acc => by simp [List.filterAuxM]
  | x :: xs, acc => by
    simp only [List.filterAuxM, map_bind]
    congr 1; funext bv
    rw [filterAuxM_acc p xs (cond bv _ _), filterAuxM_acc p xs (cond bv [x] [])]
    cases bv <;> simp [Functor.map_map]

theorem filterAuxM_append {α : Type} (p : α → KernelM Bool) : ∀ (xs ys acc : List α),
    List.filterAuxM p (xs ++ ys) acc = List.filterAuxM p xs acc >>= fun acc' => List.filterAuxM p ys acc'
  | [], ys, acc => by simp [List.filterAuxM]
  | x :: xs, ys, acc => by
    simp only [List.cons_append, List.filterAuxM, bind_assoc]
    congr 1; funext bv
    exact filterAuxM_append p xs ys _

theorem map_ok {α β : Type} {f : α → β} {m : KernelM α} {v : β} {j k : List Term}
    (h : (f <$> m) j = .ok (v, k)) : ∃ x, m j = .ok (x, k) ∧ v = f x := by
  rw [← bind_pure_comp] at h
  obtain ⟨x, j₁, hx, h⟩ := Session.bind_ok_iff.mp h
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
  obtain ⟨rfl, rfl⟩ := h
  exact ⟨x, hx, rfl⟩

/-- A filter over `xs ++ ys` filters `xs` and then `ys`. -/
theorem filterM_append_ok {α : Type} {p : α → KernelM Bool} {xs ys zs : List α} {j k : List Term}
    (h : (xs ++ ys).filterM p j = .ok (zs, k)) :
    ∃ as bs j₁, xs.filterM p j = .ok (as, j₁) ∧ ys.filterM p j₁ = .ok (bs, k) ∧ zs = as ++ bs := by
  unfold List.filterM at h ⊢
  rw [filterAuxM_append] at h
  have step := Session.bind_ok_iff.mp h; clear h; obtain ⟨r, j₂, hr, h⟩ := step
  have step := Session.bind_ok_iff.mp hr; clear hr; obtain ⟨A, j₁, hA, hr⟩ := step
  rw [filterAuxM_acc] at hr
  obtain ⟨B, hB, rfl⟩ := map_ok hr
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
  obtain ⟨rfl, rfl⟩ := h
  exact ⟨A.reverse, B.reverse, j₁, Session.bind_ok_iff.mpr ⟨A, j₁, hA, rfl⟩,
    Session.bind_ok_iff.mpr ⟨B, _, hB, rfl⟩, by simp⟩

/-! ### The knowledge fold -/

/-- A step of the knowledge fold keeps the output, maybe with the message in front. -/
theorem knowledgeStep_prepends {st st' : List Term × List Term} {m : Term} {j k : List Term}
    (h : knowledgeStep st m j = .ok (st', k)) : Prepends st'.2 st.2 := by
  unfold knowledgeStep at h
  exec_walk h
  all_goals first | exact Prepends.refl _ | exact Prepends.cons _ _

theorem foldlM_knowledge_prepends : ∀ {B : List Term} {st st' : List Term × List Term} {j k : List Term},
    B.foldlM knowledgeStep st j = .ok (st', k) → Prepends st'.2 st.2
  | [], st, st', j, k, h => by
    simp only [List.foldlM_nil, Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨rfl, -⟩ := h
    exact Prepends.refl _
  | m :: B, st, st', j, k, h => by
    rw [List.foldlM_cons] at h
    obtain ⟨c, j₁, hc, h⟩ := Session.bind_ok_iff.mp h
    exact (foldlM_knowledge_prepends h).trans (knowledgeStep_prepends hc)

/-- The window grows by appending when the stored transcript does. -/
theorem liveTail_append {W : Term} {Ms Ns : List Term} {L L' : Term} {j j' k k' : List Term}
    (h : liveTail W Ms j = .ok (L, k)) (h' : liveTail W (Ms ++ Ns) j' = .ok (L', k')) :
    ∃ ls zs, L = list ls ∧ L' = list (ls ++ zs) := by
  unfold liveTail firstKnowledge at h h'
  have step := Session.bind_ok_iff.mp h; clear h; obtain ⟨K0, j₁, hK0, h⟩ := step
  have step := Session.bind_ok_iff.mp h; clear h; obtain ⟨K, j₂, hK, h⟩ := step
  have step := Session.bind_ok_iff.mp h; clear h; obtain ⟨F, j₃, hF, h⟩ := step
  have step := Session.bind_ok_iff.mp h; clear h; obtain ⟨ls, j₅, hls, h⟩ := step
  have step := Session.bind_ok_iff.mp h'; clear h'; obtain ⟨K0', i₁, hK0', h'⟩ := step
  have step := Session.bind_ok_iff.mp h'; clear h'; obtain ⟨K', i₂, hK', h'⟩ := step
  have step := Session.bind_ok_iff.mp h'; clear h'; obtain ⟨F', i₃, hF', h'⟩ := step
  have step := Session.bind_ok_iff.mp h'; clear h'; obtain ⟨ls', i₅, hls', h'⟩ := step
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at h h'
  obtain ⟨A0, B0, l₁, hA0, hB0, rfl⟩ := filterM_append_ok hK0'
  have e := Stateless.same (Stateless.filterM (fun _ => by stateless) _) hK0 hA0
  subst e
  obtain ⟨A, B, l₂, hA, hB, rfl⟩ := filterM_append_ok hK'
  have e := Stateless.same (Stateless.filterM (fun _ => by stateless) _) hK hA
  subst e
  obtain ⟨st, j₄, hst, hF⟩ := Session.bind_ok_iff.mp hF
  obtain ⟨st', i₄, hst', hF'⟩ := Session.bind_ok_iff.mp hF'
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at hF hF'
  obtain ⟨rfl, -⟩ := hF
  obtain ⟨rfl, -⟩ := hF'
  rw [List.foldlM_append] at hst'
  obtain ⟨st₁, l₃, hst₁, hst₂⟩ := Session.bind_ok_iff.mp hst'
  have e := Stateless.same (Stateless.foldlM (fun _ _ => knowledgeStep.stateless _ _) _ _) hst hst₁
  subst e
  obtain ⟨D, hD⟩ := foldlM_knowledge_prepends hst₂
  rw [hD, List.reverse_append] at hls'
  obtain ⟨as, bs, l₅, has, hbs, rfl⟩ := mapM_append_ok hls'
  have e := Stateless.same (Stateless.mapM (fun _ => by stateless) _) hls has
  subst e
  exact ⟨ls, bs, h.1, h'.1⟩

/-! ### The live window -/

/-- `requestLiveMessages` only appends when the transcript only grows: two states whose
transcripts are `xs` and `xs ++ ys` and whose watermark agrees give windows where the second
extends the first. -/
theorem live_append {s s' : Term} {xs ys : List Term} {L L' : Term} {j j' k k' : List Term}
    (fields : ∀ key ∈ ["compacted_through"],
      s'.get (a key) = s.get (a key) ∧ s'.get (b key) = s.get (b key))
    (msgs : s.get (a "messages") = list xs) (msgs' : s'.get (a "messages") = list (xs ++ ys))
    (h : Session.CompactionQuery.requestLiveMessages s j = .ok (L, k))
    (h' : Session.CompactionQuery.requestLiveMessages s' j' = .ok (L', k')) :
    ∃ ls zs, L = list ls ∧ L' = list (ls ++ zs) := by
  have wm := (fields "compacted_through" (by simp)).1
  rw [requestLiveMessages_eq] at h h'
  rw [wm] at h'
  rw [msgs, default_list] at h
  rw [msgs', default_list] at h'
  exact liveTail_append h h'

end VerifiedKernel.RequestPrefix
