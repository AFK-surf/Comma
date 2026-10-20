import VerifiedKernelProofs.Provider.AnthropicTags
import VerifiedKernelProofs.Provider.AnthropicCache
import VerifiedKernelProofs.Provider.Answered
import VerifiedKernelProofs.Provider.Body

/-!
The Anthropic projection keeps the projection of a closed history as a prefix of its messages.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

set_option maxHeartbeats 4000000

theorem TurnRole.anthropic_leading {m : Term} (role : TurnRole m) :
    member (openaiRole m) ["system", "summary", "runtime"] = false := by
  rcases role with h | h <;> rw [h] <;> simp (config := {decide := true}) [text_beq_text]

theorem Answered.drop_takeWhile {p : Term → Bool} {L : List Term} (h : Answered L) :
    Answered (L.drop (L.takeWhile p).length) := by
  have split : L.takeWhile p ++ L.drop (L.takeWhile p).length = L := by
    conv => rhs; rw [← List.take_append_drop (L.takeWhile p).length L]
    rw [← List.prefix_iff_eq_take.mp (List.takeWhile_prefix p)]
  rw [← split] at h
  exact Answered.append_right h

/-- **Anthropic prefix.** Both requests send the same system text, and the messages of a closed
history are a prefix of the messages of that history followed by more messages. -/
theorem anthropicParts_append {H E : List Term} {model v₀ v₁ : Term} {j₀ j₁ k₀ k₁ : List Term}
    (turn : ∃ m ∈ H, TurnRole m) (matched : Matched H)
    (h₀ : anthropicParts H model j₀ = .ok (v₀, k₀)) (h₁ : anthropicParts (H ++ E) model j₁ = .ok (v₁, k₁)) :
    ∃ sys ms₀ ms₁ t₀ t₁, v₀ = .tuple [sys, list ms₀, t₀] ∧ v₁ = .tuple [sys, list ms₁, t₁] ∧ ms₀ <+: ms₁ := by
  unfold anthropicParts at h₀ h₁
  simp only [Session.bind_ok_iff] at h₀ h₁
  obtain ⟨s₀, ja, hs₀, t₀, jb, ht₀, h₀⟩ := h₀
  obtain ⟨s₁, ja', hs₁, t₁, jb', ht₁, h₁⟩ := h₁
  obtain ⟨vH, T, jH, hsynH, rfl, ⟨m, mvH, role⟩, -, -⟩ :=
    syntheticRuntime_append turn (matched_closed true matched) hs₁
  have := (syntheticRuntime.stateless H true true).same hs₀ hsynH
  subst this
  have leadStop : ∃ x ∈ s₀, (fun m => member (openaiRole m) ["system", "summary", "runtime"]) x = false :=
    ⟨m, mvH, role.anthropic_leading⟩
  rw [takeWhile_append_of_false leadStop] at ht₁ h₁
  have texts := (Stateless.mapM (fun _ => by stateless) _).same ht₀ ht₁
  subst texts
  rw [drop_append_of_le (takeWhile_length_le _ _)] at h₁
  -- The tags of the history leave no tool use pending.
  have tagsClosed : ∀ {tss j k}, List.mapM (fun x => anthropicMessage x model)
      (s₀.drop (s₀.takeWhile (fun m => member (openaiRole m) ["system", "summary", "runtime"])).length) j
        = .ok (tss, k) → ∀ c ∈ tss.flatten.foldl anthPendingStep [], c = nil := by
    intro tss j k htags
    exact anthPending_closed _ (anthropic_tags_answered
      (syntheticRuntime_matched turn matched hsynH).answeredEq.drop_takeWhile htags)
  split at h₀ <;> split at h₁ <;> (try contradiction)
  all_goals
    obtain ⟨sys₀, _, hsys₀, h₀⟩ := Session.bind_ok_iff.mp h₀
    obtain ⟨sys₁, _, hsys₁, h₁⟩ := Session.bind_ok_iff.mp h₁
    obtain ⟨tss₀, _, htss₀, h₀⟩ := Session.bind_ok_iff.mp h₀
    obtain ⟨tss₁, _, htss₁, h₁⟩ := Session.bind_ok_iff.mp h₁
    obtain ⟨tH, tT, _, htH, -, rfl⟩ := mapM_append_ok htss₁
    have := (Stateless.mapM (fun _ => by stateless) _).same htss₀ htH
    subst this
    obtain ⟨zs, hzs⟩ := adjacentAnthropic_append tss₀.flatten tT.flatten (tagsClosed htss₀)
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h₀ h₁
    rw [h₀.1, h₁.1, List.flatten_append, hzs]
  · simp only [Session.pure_ok_iff, Prod.mk.injEq] at hsys₀ hsys₁
    rw [hsys₀.1, hsys₁.1]
    exact ⟨_, _, _, _, _, rfl, rfl, ⟨zs.map Prod.snd, by simp⟩⟩
  · have := (Provider.join.stateless _ _).same hsys₀ hsys₁
    subst this
    exact ⟨_, _, _, _, _, rfl, rfl, ⟨zs.map Prod.snd, by simp⟩⟩

/-- The Anthropic body before its streaming or effort setting. -/
def anthropicBase (cfg msgs sys specs : Term) : Term :=
  putOptional (putOptional (putOptional (obj [("model", cfg.get (a "model")),
    ("max_tokens", coalesce [cfg.get (a "max_tokens"), i 4096]), ("messages", msgs)]) "system" sys) "tools" specs)
    "thinking" (Request.anthropicThinking cfg)

theorem anthropic_body_parts {cfg : Term} {msgs tools : List Term} {mode : String} {v : Term} {j k : List Term}
    (h : Request.body "anthropic" cfg msgs tools mode j = .ok (v, k)) :
    ∃ x defs, (∃ j' k', anthropicParts msgs (cfg.get (a "model")) j' = .ok (x, k')) ∧
      (∃ j' k', (tools.mapM (toolSpec "anthropic")) j' = .ok (defs, k')) ∧
      ∀ sys ms t, x = .tuple [sys, list ms, t] → ∃ sys' specs out,
        Request.cache sys (if tools.isEmpty then nil else list defs) (list ms) (cfg.get (a "prompt_caching")) t =
          .tuple [sys', specs, list out] ∧
        ∀ kk ∈ ["messages", "system", "tools"], Provider.get v kk = Provider.get (anthropicBase cfg (list out) sys' specs) kk := by
  unfold Request.body at h
  simp (config := {decide := true}) only [↓reduceIte] at h
  obtain ⟨defs, j₁, hdefs, h⟩ := Session.bind_ok_iff.mp h
  obtain ⟨x, j₂, hx, h⟩ := Session.bind_ok_iff.mp h
  refine ⟨x, defs, ⟨_, _, hx⟩, ⟨_, _, hdefs⟩, ?_⟩
  rintro sys ms t rfl
  obtain ⟨sys', specs, out, hc, -⟩ := cache_erase sys (if tools.isEmpty then nil else list defs) ms
    (cfg.get (a "prompt_caching")) t
  refine ⟨sys', specs, out, hc, ?_⟩
  intro kk hkk
  simp only at h
  rw [hc] at h
  simp only at h
  have tailKeys : kk ≠ "stream" ∧ kk ≠ "output_config" := by
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hkk
    rcases hkk with rfl | rfl | rfl <;> decide
  split at h
  · simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    rw [h.1, pget_put_other _ _ (Ne.symm tailKeys.1)]; rfl
  · simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    rw [h.1]
    split
    · rw [pget_put_other _ _ (Ne.symm tailKeys.2)]; rfl
    · rfl

theorem cache_out_erase {s t e tr s' t' : Term} {ms out : List Term}
    (h : Request.cache s t (list ms) e tr = .tuple [s', t', list out]) :
    out.map eraseMessage = ms.map eraseMessage := by
  obtain ⟨s₂, t₂, out₂, h₂, erase, -⟩ := cache_erase s t ms e tr
  rw [h] at h₂
  simp only [Term.tuple.injEq, List.cons.injEq, and_true] at h₂
  have e : out = out₂ := by have := h₂.2.2; simp only [list, Term.list.injEq] at this; exact this
  rw [e]; exact erase

theorem cache_head_same {s t e tr tr' s₁ t₁ s₂ t₂ : Term} {ms ms' out out' : List Term}
    (h : Request.cache s t (list ms) e tr = .tuple [s₁, t₁, list out])
    (h' : Request.cache s t (list ms') e tr' = .tuple [s₂, t₂, list out']) : s₂ = s₁ ∧ t₂ = t₁ := by
  obtain ⟨s₃, t₃, out₃, h₃, -, -, same, -⟩ := cache_erase s t ms e tr
  rw [h] at h₃
  simp only [Term.tuple.injEq, List.cons.injEq, and_true] at h₃
  obtain ⟨out₄, h₄⟩ := same ms' tr'
  rw [h'] at h₄
  simp only [Term.tuple.injEq, List.cons.injEq, and_true] at h₄
  exact ⟨h₄.1.trans h₃.1.symm, h₄.2.1.trans h₃.2.1.symm⟩

theorem anthropicBase_messages (cfg msgs sys specs : Term) :
    Provider.get (anthropicBase cfg msgs sys specs) "messages" = msgs := by
  unfold anthropicBase
  rw [pget_putOptional_other _ _ (by decide), pget_putOptional_other _ _ (by decide),
    pget_putOptional_other _ _ (by decide)]
  simp (config := {decide := true}) [get_obj_cons_ne]

theorem anthropicBase_head (cfg msgs msgs' sys specs : Term) {k : String} (hk : k ≠ "messages") :
    Provider.get (anthropicBase cfg msgs sys specs) k = Provider.get (anthropicBase cfg msgs' sys specs) k := by
  unfold anthropicBase
  apply pget_putOptional_congr
  apply pget_putOptional_congr
  apply pget_putOptional_congr
  by_cases hm : k = "model"
  · subst hm; simp
  · by_cases ht : k = "max_tokens"
    · subst ht
      rw [get_obj_cons_ne _ _ (by decide : "model" ≠ "max_tokens"),
        get_obj_cons_ne _ _ (by decide : "model" ≠ "max_tokens")]
      simp
    · rw [get_obj_cons_ne _ _ (Ne.symm hm), get_obj_cons_ne _ _ (Ne.symm hm),
        get_obj_cons_ne _ _ (Ne.symm ht), get_obj_cons_ne _ _ (Ne.symm ht),
        get_obj_cons_ne _ _ (Ne.symm hk), get_obj_cons_ne _ _ (Ne.symm hk)]

/-- **Anthropic request prefix.** Both requests send the same system text and tools, and after
cache markers are erased, the messages of the closed history `H` are a prefix of the messages of
`H ++ X`. -/
theorem body_anthropic_prefix {cfg : Term} {H X tools : List Term} {mode : String} {b₀ b₁ : Term}
    {j₀ j₁ k₀ k₁ : List Term}
    (turn : ∃ m ∈ H, TurnRole m) (matched : Matched H)
    (h₀ : Request.body "anthropic" cfg H tools mode j₀ = .ok (b₀, k₀))
    (h₁ : Request.body "anthropic" cfg (H ++ X) tools mode j₁ = .ok (b₁, k₁)) :
    headOf "anthropic" b₁ = headOf "anthropic" b₀ ∧ messagesOf "anthropic" b₀ <+: messagesOf "anthropic" b₁ := by
  obtain ⟨x₀, d₀, ⟨_, _, hx₀⟩, ⟨_, _, hd₀⟩, get₀⟩ := anthropic_body_parts h₀
  obtain ⟨x₁, d₁, ⟨_, _, hx₁⟩, ⟨_, _, hd₁⟩, get₁⟩ := anthropic_body_parts h₁
  have := (Stateless.mapM (fun _ => by stateless) _).same hd₀ hd₁
  subst this
  obtain ⟨sys, ms₀, ms₁, t₀, t₁, rfl, rfl, pre⟩ := anthropicParts_append turn matched hx₀ hx₁
  obtain ⟨sys₀', specs₀, out₀, hc₀, g₀⟩ := get₀ _ _ _ rfl
  obtain ⟨sys₁', specs₁, out₁, hc₁, g₁⟩ := get₁ _ _ _ rfl
  obtain ⟨rfl, rfl⟩ := cache_head_same hc₀ hc₁
  unfold headOf messagesOf
  simp (config := {decide := true}) only [↓reduceIte]
  refine ⟨?_, ?_⟩
  · rw [g₀ "system" (by decide), g₀ "tools" (by decide), g₁ "system" (by decide), g₁ "tools" (by decide),
      anthropicBase_head _ _ (list out₀) _ _ (by decide : "system" ≠ "messages"),
      anthropicBase_head _ _ (list out₀) _ _ (by decide : "tools" ≠ "messages")]
  · rw [g₀ "messages" (by decide), g₁ "messages" (by decide), anthropicBase_messages, anthropicBase_messages,
      items_list, items_list, cache_out_erase hc₀, cache_out_erase hc₁]
    exact pre.map _

end VerifiedKernel.ProviderLoop
