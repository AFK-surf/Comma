import VerifiedKernelProofs.RequestPrefix.Stateless

/-!
The message list of a provider dispatch.

`Session.Request.dispatch` sends the stored prompt, then the Session context, then the request
input (the delta messages), with attachments inlined. Nothing else enters the request.
-/

namespace VerifiedKernel.RequestPrefix
open Data

set_option maxHeartbeats 4000000

/-- The prompt message that `prepend` puts first. -/
def promptHead (prompt : Term) : List Term :=
  if (prompt.isBinary && prompt != b "") = true then [Session.Request.summary prompt] else []

theorem prepend_ok {msgs prompt v : Term} {j k : List Term}
    (h : Session.Request.prepend msgs prompt j = .ok (v, k)) :
    ∃ xs, msgs = list xs ∧ v = list (promptHead prompt ++ xs) := by
  unfold Session.Request.prepend at h
  obtain ⟨xs, j₁, hxs, h⟩ := Session.bind_ok_iff.mp h
  have : msgs = list xs := by
    unfold asList at hxs
    split at hxs
    · simp only [Session.pure_ok_iff, Prod.mk.injEq] at hxs; rw [hxs.1]; rfl
    · simp [Session.fail_ok_iff] at hxs
  refine ⟨xs, this, ?_⟩
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
  rw [h.1, promptHead]
  split <;> simp_all

theorem asList_ok {t : Term} {xs : List Term} {j k : List Term} (h : asList t j = .ok (xs, k)) : t = list xs := by
  unfold asList at h
  split at h
  · simp only [Session.pure_ok_iff, Prod.mk.injEq] at h; rw [h.1]; rfl
  · simp [Session.fail_ok_iff] at h

/-- `build` sends the prompt, the context `C`, and request input `X`. -/
theorem build_messages {state ctx delta prompt : Term} {msgs : List Term} {j k : List Term}
    (h : Session.Request.build state (.tuple [ctx, delta, prompt]) j = .ok (msgs, k)) :
    ∃ C X, ctx = list C ∧ msgs = promptHead prompt ++ (C ++ X) := by
  unfold Session.Request.build at h
  simp only [Session.bind_ok_iff] at h
  obtain ⟨d, _, -, dl, _, -, dd, _, -, C, _, hC, Dl, _, -, m, _, hm, h⟩ := h
  obtain ⟨xs, hxs, rfl⟩ := prepend_ok hm
  refine ⟨C, Dl, asList_ok hC, ?_⟩
  have hx : xs = C ++ Dl := by
    have := hxs.symm
    injection this
  have := asList_ok h
  rw [hx] at this
  injection this with e
  exact e.symm

end VerifiedKernel.RequestPrefix
