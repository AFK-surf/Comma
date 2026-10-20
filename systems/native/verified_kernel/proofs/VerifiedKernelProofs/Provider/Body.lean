import VerifiedKernelProofs.Provider.Responses
import VerifiedKernelProofs.Provider.PrefixSpec

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

set_option maxHeartbeats 4000000

theorem forIn_putOptional_get {cfg : Term} :
    ∀ {keys : List String} {init s : Term} {j k : List Term},
      ForIn.forIn (m := KernelM) keys init (fun key s => pure (ForInStep.yield (putOptional s key (cfg.get (a key))))) j
        = .ok (s, k) →
      ∀ kk, kk ∉ keys → Provider.get s kk = Provider.get init kk
  | [], init, s, j, k, h, kk, _ => by
    obtain ⟨rfl, -⟩ := forIn_nil_ok h
    rfl
  | key :: keys, init, s, j, k, h, kk, hk => by
    rw [List.forIn_cons] at h
    simp only [Session.bind_ok_iff, Session.pure_ok_iff] at h
    obtain ⟨_, _, ⟨rfl, rfl⟩, h⟩ := h
    rw [forIn_putOptional_get h kk (fun m => hk (List.mem_cons_of_mem _ m))]
    exact get_putOptional_other _ _ (fun e => hk (e ▸ List.mem_cons_self ..))

/-- The Responses body before its optional settings. -/
def responsesBase (cfg input instr defs : Term) : Term :=
  putOptional (putOptional (obj [("model", cfg.get (a "model")), ("input", input)]) "instructions" instr) "tools" defs

theorem pget_putOptional_other (v x : Term) {k l : String} (h : l ≠ k) :
    Provider.get (putOptional v l x) k = Provider.get v k := get_putOptional_other v x h

theorem pget_putOptional_congr {m m' x : Term} {l k : String} (h : Provider.get m k = Provider.get m' k) :
    Provider.get (putOptional m l x) k = Provider.get (putOptional m' l x) k := by
  unfold putOptional
  split
  · exact h
  · by_cases e : l = k
    · subst e; simp
    · rw [pget_put_other _ _ e, pget_put_other _ _ e, h]

theorem responsesBase_input (cfg input instr defs : Term) :
    Provider.get (responsesBase cfg input instr defs) "input" = input := by
  unfold responsesBase
  rw [pget_putOptional_other _ _ (by decide), pget_putOptional_other _ _ (by decide)]
  simp (config := {decide := true}) [get_obj_cons_ne]

theorem responsesBase_head (cfg input input' instr defs : Term) {k : String} (hk : k ≠ "input") :
    Provider.get (responsesBase cfg input instr defs) k = Provider.get (responsesBase cfg input' instr defs) k := by
  unfold responsesBase
  apply pget_putOptional_congr
  apply pget_putOptional_congr
  by_cases hm : k = "model"
  · subst hm; simp
  · rw [get_obj_cons_ne _ _ (Ne.symm hm), get_obj_cons_ne _ _ (Ne.symm hm),
      get_obj_cons_ne _ _ (Ne.symm hk), get_obj_cons_ne _ _ (Ne.symm hk)]

theorem responses_body_parts {cfg : Term} {msgs tools : List Term} {mode : String} {v : Term} {j k : List Term}
    (h : Request.body "responses" cfg msgs tools mode j = .ok (v, k)) :
    ∃ x defs, (∃ j' k', responsesParts msgs j' = .ok (x, k')) ∧
      (∃ j' k', (tools.mapM (toolSpec "responses")) j' = .ok (defs, k')) ∧
      ∀ input instr, x = .tuple [input, instr] → ∀ kk ∈ ["input", "instructions", "tools"],
        Provider.get v kk = Provider.get (responsesBase cfg input instr (if tools.isEmpty then nil else list defs)) kk := by
  unfold Request.body at h
  simp (config := {decide := true}) only [↓reduceIte] at h
  obtain ⟨defs, j₁, hdefs, h⟩ := Session.bind_ok_iff.mp h
  obtain ⟨x, j₂, hx, h⟩ := Session.bind_ok_iff.mp h
  refine ⟨x, defs, ⟨_, _, hx⟩, ⟨_, _, hdefs⟩, ?_⟩
  rintro input instr rfl kk hkk
  simp only at h
  have notKey : kk ∉ ["store", "include", "context_management", "reasoning", "prompt_cache_key"] := by
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hkk ⊢
    rcases hkk with rfl | rfl | rfl <;> decide
  have tailKeys : kk ≠ "text" ∧ kk ≠ "max_output_tokens" ∧ kk ≠ "stream" := by
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hkk
    rcases hkk with rfl | rfl | rfl <;> decide
  split at h
  · simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    rw [h.1]; rfl
  · obtain ⟨s, j₃, hf, h⟩ := Session.bind_ok_iff.mp h
    have hs := forIn_putOptional_get hf kk notKey
    split at h <;> simp only [Session.pure_ok_iff, Prod.mk.injEq] at h <;> rw [h.1] <;> split <;>
      simp only [pget_put_other _ _ (Ne.symm tailKeys.1), pget_put_other _ _ (Ne.symm tailKeys.2.2),
        pget_putOptional_other _ _ (Ne.symm tailKeys.2.1), hs] <;> rfl

/-- **Responses request prefix.** Both requests send the same instructions and tools, and the
input of the closed history `H` is a prefix of the input of `H ++ X`. -/
theorem body_responses_prefix {cfg : Term} {H X tools : List Term} {mode : String} {b₀ b₁ : Term}
    {j₀ j₁ k₀ k₁ : List Term}
    (turn : ∃ m ∈ H, TurnRole m) (closed : (loopPart H).foldl (pendingStep false) [] = [])
    (h₀ : Request.body "responses" cfg H tools mode j₀ = .ok (b₀, k₀))
    (h₁ : Request.body "responses" cfg (H ++ X) tools mode j₁ = .ok (b₁, k₁)) :
    headOf "responses" b₁ = headOf "responses" b₀ ∧ messagesOf "responses" b₀ <+: messagesOf "responses" b₁ := by
  obtain ⟨x₀, d₀, ⟨_, _, hx₀⟩, ⟨_, _, hd₀⟩, get₀⟩ := responses_body_parts h₀
  obtain ⟨x₁, d₁, ⟨_, _, hx₁⟩, ⟨_, _, hd₁⟩, get₁⟩ := responses_body_parts h₁
  have := (Stateless.mapM (fun _ => by stateless) _).same hd₀ hd₁
  subst this
  obtain ⟨in₀, in₁, instr, rfl, rfl, pre⟩ := responsesParts_append turn closed hx₀ hx₁
  have g₀ := get₀ _ _ rfl
  have g₁ := get₁ _ _ rfl
  unfold headOf messagesOf
  simp (config := {decide := true}) only [↓reduceIte]
  refine ⟨?_, ?_⟩
  · rw [g₀ "instructions" (by decide), g₀ "tools" (by decide), g₁ "instructions" (by decide),
      g₁ "tools" (by decide), responsesBase_head _ _ (list in₀) _ _ (by decide : "instructions" ≠ "input"),
      responsesBase_head _ _ (list in₀) _ _ (by decide : "tools" ≠ "input")]
  · rw [g₀ "input" (by decide), g₁ "input" (by decide), responsesBase_input, responsesBase_input]
    exact pre

end VerifiedKernel.ProviderLoop
