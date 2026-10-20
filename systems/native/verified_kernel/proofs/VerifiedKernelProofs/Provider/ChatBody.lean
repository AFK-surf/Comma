import VerifiedKernelProofs.Provider.Chat

/-!
The chat request body sends the chat messages and the tool definitions unchanged.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

set_option maxHeartbeats 4000000

/-- Every successful run of `m` returns a value with property `P`. -/
def Returns (P : Term → Prop) (m : KernelM Term) : Prop := ∀ j v k, m j = .ok (v, k) → P v

theorem Returns.pure {P : Term → Prop} {x : Term} (h : P x) : Returns P (Pure.pure x) := by
  intro j v k e
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at e
  exact e.1 ▸ h

theorem Returns.ite {P : Term → Prop} {c : Prop} [Decidable c] {t e : KernelM Term}
    (ht : Returns P t) (he : Returns P e) : Returns P (if c then t else e) := by
  split <;> assumption

/-- The chat body before its optional settings. -/
def chatBase (cfg msgs defs : Term) : Term :=
  putOptional (obj [("model", cfg.get (a "model")), ("messages", msgs)]) "tools" defs

/-- The body keeps the messages and tools of `base`. -/
def KeepsChat (base v : Term) : Prop := ∀ kk ∈ ["messages", "tools"], Provider.get v kk = Provider.get base kk

theorem KeepsChat.put {base v y : Term} {l : String} (hl : l ∉ ["messages", "tools"]) (h : KeepsChat base v) :
    KeepsChat base (v.put (b l) y) := fun kk hk => by
  rw [pget_put_other _ _ (by rintro rfl; exact hl hk)]; exact h kk hk

theorem KeepsChat.putOptional {base v y : Term} {l : String} (hl : l ∉ ["messages", "tools"]) (h : KeepsChat base v) :
    KeepsChat base (putOptional v l y) := fun kk hk => by
  rw [pget_putOptional_other _ _ (by rintro rfl; exact hl hk)]; exact h kk hk

theorem cap_not_key {c : Prop} [Decidable c] :
    (if c then "max_completion_tokens" else "max_tokens") ∉ ["messages", "tools"] := by
  split <;> decide

open Lean Elab Tactic Meta in
/-- One step on a `Returns` or `KeepsChat` goal, chosen by the head of its term. Matching by
head avoids unfolding the large body term. -/
elab "keeps_step" : tactic => withMainContext do
  let goal ← instantiateMVars (← getMainTarget)
  let run (t : TSyntax `tactic) : TacticM Unit := evalTactic t
  if goal.isAppOfArity ``Returns 2 then
    let m := goal.appArg!
    if m.isAppOf ``ite then run (← `(tactic| refine Returns.ite ?_ ?_))
    else if m.isAppOf ``Pure.pure then run (← `(tactic| refine Returns.pure ?_))
    else throwError "keeps_step: unexpected action"
  else if goal.isAppOfArity ``KeepsChat 2 then
    let v := goal.appArg!
    if v.isAppOf ``Term.put then run (← `(tactic| refine KeepsChat.put (by decide) ?_))
    else if v.isAppOfArity ``putOptional 3 then
      if v.getArg! 1 == mkStrLit "tools" then run (← `(tactic| exact fun _ _ => rfl))
      else if (v.getArg! 1).isStringLit then run (← `(tactic| refine KeepsChat.putOptional (by decide) ?_))
      else run (← `(tactic| refine KeepsChat.putOptional cap_not_key ?_))
    else throwError "keeps_step: unexpected body"
  else throwError "keeps_step: unexpected goal"

theorem chat_body_parts {cfg : Term} {msgs tools : List Term} {mode : String} {v : Term} {j k : List Term}
    (h : Request.body "chat" cfg msgs tools mode j = .ok (v, k)) :
    ∃ x defs, (∃ j' k', chat msgs (cfg.get (a "model")) j' = .ok (x, k')) ∧
      (∃ j' k', (tools.mapM (toolSpec "chat")) j' = .ok (defs, k')) ∧
      ∀ kk ∈ ["messages", "tools"],
        Provider.get v kk = Provider.get (chatBase cfg x (if tools.isEmpty then nil else list defs)) kk := by
  unfold Request.body at h
  simp (config := {decide := true}) only [↓reduceIte] at h
  obtain ⟨defs, j₁, hdefs, h⟩ := Session.bind_ok_iff.mp h
  obtain ⟨x, j₂, hx, h⟩ := Session.bind_ok_iff.mp h
  refine ⟨x, defs, ⟨_, _, hx⟩, ⟨_, _, hdefs⟩, ?_⟩
  refine (?_ : Returns (KeepsChat (chatBase cfg x (if tools.isEmpty then nil else list defs))) _) _ _ _ h
  repeat' keeps_step

theorem chatBase_messages (cfg x d : Term) : Provider.get (chatBase cfg x d) "messages" = x := by
  unfold chatBase
  rw [pget_putOptional_other _ _ (by decide), get_obj_cons_ne _ _ (by decide), get_obj_cons_same]

theorem chatBase_tools (cfg x x' d : Term) :
    Provider.get (chatBase cfg x d) "tools" = Provider.get (chatBase cfg x' d) "tools" := by
  unfold chatBase
  apply pget_putOptional_congr
  rw [get_obj_cons_ne _ _ (by decide), get_obj_cons_ne _ _ (by decide),
    get_obj_cons_ne _ _ (by decide), get_obj_cons_ne _ _ (by decide)]

/-- **Chat request prefix.** Both requests send the same tools, and the messages of the closed
history `H` are a prefix of the messages of `H ++ X`. -/
theorem body_chat_prefix {cfg : Term} {H X tools : List Term} {mode : String} {b₀ b₁ : Term}
    {j₀ j₁ k₀ k₁ : List Term}
    (turn : ∃ m ∈ H, TurnRole m)
    (matched : Matched H)
    (h₀ : Request.body "chat" cfg H tools mode j₀ = .ok (b₀, k₀))
    (h₁ : Request.body "chat" cfg (H ++ X) tools mode j₁ = .ok (b₁, k₁)) :
    headOf "chat" b₁ = headOf "chat" b₀ ∧ messagesOf "chat" b₀ <+: messagesOf "chat" b₁ := by
  obtain ⟨x₀, d₀, ⟨_, _, hx₀⟩, ⟨_, _, hd₀⟩, get₀⟩ := chat_body_parts h₀
  obtain ⟨x₁, d₁, ⟨_, _, hx₁⟩, ⟨_, _, hd₁⟩, get₁⟩ := chat_body_parts h₁
  have := (Stateless.mapM (fun _ => by stateless) _).same hd₀ hd₁
  subst this
  obtain ⟨o₀, o₁, rfl, rfl, pre⟩ := chat_append turn matched hx₀ hx₁
  unfold headOf messagesOf at *
  simp (config := {decide := true}) only [↓reduceIte]
  rw [get₀ "messages" (by decide), get₁ "messages" (by decide), chatBase_messages, chatBase_messages,
    items_list, items_list]
  refine ⟨?_, pre⟩
  rw [get₀ "tools" (by decide), get₁ "tools" (by decide), chatBase_tools]

end VerifiedKernel.ProviderLoop
