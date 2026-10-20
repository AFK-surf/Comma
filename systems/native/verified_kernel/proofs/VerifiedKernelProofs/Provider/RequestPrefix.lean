import VerifiedKernelProofs.Provider.ChatBody

/-!
# Provider request prefix stability

A provider caches a request prefix. This file states when two requests of one conversation share
the projection of their common history as that prefix.

The history `H` is closed (`ClosedHistory`): it has a conversation turn, and each result answers
the newest waiting call with its id, with no call left waiting (`Matched`). A request sends
`H ++ X`, for any `X`. Then the request head is the head of the
projection of `H` alone, and the messages of that projection are a prefix of the request
messages.

Provider assumptions (outside Lean): Anthropic cache markers do not take part in prefix
matching, and a string content equals one text block with that text. Chat and Responses cache
a prefix of the message array.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

/-- The history whose projection is the cacheable prefix. -/
structure ClosedHistory (H : List Term) : Prop where
  turn : ∃ m ∈ H, TurnRole m
  matched : Matched H

/-- **Request extension.** A request for `H ++ X` starts with the projection of `H`: the same
head, and the messages of `H` as a prefix. `X` is any list of messages. -/
theorem request_extends {protocol mode : String} {cfg : Term} {H X tools : List Term} {b₀ b₁ : Term}
    {j₀ j₁ k₀ k₁ : List Term} (hp : protocol ∈ ["chat", "anthropic", "responses"])
    (closed : ClosedHistory H)
    (h₀ : Request.body protocol cfg H tools mode j₀ = .ok (b₀, k₀))
    (h₁ : Request.body protocol cfg (H ++ X) tools mode j₁ = .ok (b₁, k₁)) :
    headOf protocol b₁ = headOf protocol b₀ ∧ messagesOf protocol b₀ <+: messagesOf protocol b₁ := by
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hp
  rcases hp with rfl | rfl | rfl
  · exact body_chat_prefix closed.turn closed.matched h₀ h₁
  · exact body_anthropic_prefix closed.turn closed.matched h₀ h₁
  · exact body_responses_prefix closed.turn (matched_closed false closed.matched) h₀ h₁

/-- **Request prefix stability.** This request sends `H ++ X`, and the next request sends
`H ++ E`. Both start with the projection `b₀` of `H`. -/
theorem request_prefix_stable {protocol mode : String} {cfg : Term} {H X E tools : List Term}
    {b₀ b₁ b₂ : Term} {j₀ j₁ j₂ k₀ k₁ k₂ : List Term} (hp : protocol ∈ ["chat", "anthropic", "responses"])
    (closed : ClosedHistory H)
    (h₀ : Request.body protocol cfg H tools mode j₀ = .ok (b₀, k₀))
    (h₁ : Request.body protocol cfg (H ++ X) tools mode j₁ = .ok (b₁, k₁))
    (h₂ : Request.body protocol cfg (H ++ E) tools mode j₂ = .ok (b₂, k₂)) :
    headOf protocol b₁ = headOf protocol b₀ ∧ headOf protocol b₂ = headOf protocol b₀ ∧
      messagesOf protocol b₀ <+: messagesOf protocol b₁ ∧ messagesOf protocol b₀ <+: messagesOf protocol b₂ := by
  obtain ⟨head₁, pre₁⟩ := request_extends hp closed h₀ h₁
  obtain ⟨head₂, pre₂⟩ := request_extends hp closed h₀ h₂
  exact ⟨head₁, head₂, pre₁, pre₂⟩

end VerifiedKernel.ProviderLoop
