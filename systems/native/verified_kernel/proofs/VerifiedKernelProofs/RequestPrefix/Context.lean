import VerifiedKernelProofs.RequestPrefix.ContextParts
import VerifiedKernelProofs.RequestPrefix.Live
import VerifiedKernelProofs.RequestPrefix.Sanitize

/-!
The Session context only grows when the transcript only grows.

`Session.Request.context` reads the compaction prefix and the live window, shows user-reportable
failures by their public summary, and fits each message. Between two states whose window fields
agree and whose transcript only grows, the context of the first state is a prefix of the context
of the second.
-/

namespace VerifiedKernel.RequestPrefix
open Data

set_option maxHeartbeats 4000000

/-- The state fields that select the window and its prefix agree. -/
def SameWindow (s s' : Term) : Prop :=
  s'.isMap = s.isMap ∧
    ∀ k ∈ ["provider_compaction", "summary", "compacted_through"], SameKey s s' k

/-- **Context extension.** The context of `s` is a prefix of the context of `s'`. -/
theorem context_append {s s' : Term} {xs ys C C' : List Term} {j j' k k' : List Term}
    (window : SameWindow s s') (msgs : s.get (a "messages") = list xs)
    (msgs' : s'.get (a "messages") = list (xs ++ ys))
    (h : Session.Request.context s j = .ok (list C, k)) (h' : Session.Request.context s' j' = .ok (list C', k')) :
    C <+: C' := by
  obtain ⟨hm, keys⟩ := window
  have key : ∀ k ∈ ["provider_compaction", "summary", "compacted_through"],
      SameKey s s' k := keys
  obtain ⟨pre, live, S, D, ⟨_, _, hpre⟩, ⟨_, _, hlive⟩, ⟨_, _, hS⟩, ⟨_, _, hD⟩, hv⟩ :=
    context_parts h
  obtain ⟨pre', live', S', D', ⟨_, _, hpre'⟩, ⟨_, _, hlive'⟩, ⟨_, _, hS'⟩, ⟨_, _, hD'⟩, hv'⟩ :=
    context_parts h'
  injection hv with hv; subst hv
  injection hv' with hv'; subst hv'
  -- The prefixes agree.
  have epre := (Session.CompactionQuery.contextPrefix.stateless s).same hpre
    (contextPrefix_congr hm (key _ (by simp)) (key _ (by simp)) hpre')
  injection epre with epre; subst epre
  -- The live window grows.
  obtain ⟨ls, zs, el, el'⟩ := live_append (s := s) (s' := s')
    (fun key hk => by
      simp only [List.mem_cons, List.not_mem_nil, or_false] at hk
      rcases hk with rfl; exact ⟨(keys _ (by simp)).2.1, (keys _ (by simp)).2.2⟩)
    msgs msgs' hlive hlive'
  injection el with el; subst el
  injection el' with el'; subst el'
  rw [← List.append_assoc] at hS'
  obtain ⟨xsA, xsB, eA, eAB⟩ := sanitize_append hS' hS
  injection eA with eA; subst eA
  injection eAB with eAB; subst eAB
  obtain ⟨dA, dB, _, hA, -, rfl⟩ := ProviderLoop.mapM_append_ok hD'
  have := (Stateless.mapM (fun m => by stateless) _).same hD hA
  subst this
  exact List.prefix_append _ _

end VerifiedKernel.RequestPrefix
