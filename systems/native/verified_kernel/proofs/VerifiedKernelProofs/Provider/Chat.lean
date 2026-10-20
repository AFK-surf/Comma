import VerifiedKernelProofs.Provider.ChatLoop
import VerifiedKernelProofs.Provider.ChatWire
import VerifiedKernelProofs.Provider.Anthropic

/-!
The chat projection keeps the projection of a closed history as a prefix of its messages.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

set_option maxHeartbeats 4000000

theorem flatMap_drop_sublist {α β : Type} (f : α → List β) (l : List α) (n : Nat) :
    List.Sublist ((l.drop n).flatMap f) (l.flatMap f) := by
  conv => rhs; rw [← List.take_append_drop n l]
  rw [List.flatMap_append]
  exact List.sublist_append_right _ _

theorem chat_run {msgs : List Term} {model v : Term} {j k : List Term} (h : chat msgs model j = .ok (v, k)) :
    ∃ s u st texts header out, (∃ j' k', syntheticRuntime msgs true false j' = .ok (s, k')) ∧
      (∃ j' k', uniqueChatCallIds s j' = .ok (u, k')) ∧
      (∃ j' k', ForIn.forIn (u.drop (chatLead u).length) ((∅ : CallMap Term), ([] : List Term), ([] : List Term), ([] : List Term))
        (chatBody model) j' = .ok (st, k')) ∧
      (∃ j' k', (chatLead u).mapM Content.systemText j' = .ok (texts, k')) ∧
      ((texts.filter (· != b "")).isEmpty = true → header = []) ∧
      ((texts.filter (· != b "")).isEmpty = false →
        ∃ c, (∃ j' k', join (texts.filter (· != b "")) "\n\n" j' = .ok (c, k')) ∧
          header = [obj [("role", b "system"), ("content", c)]]) ∧
      (∃ j' k', adjacentChat (header ++ flat st) j' = .ok (out, k')) ∧ v = list out := by
  unfold chat at h
  obtain ⟨s, j₁, hs, h⟩ := Session.bind_ok_iff.mp h
  obtain ⟨u, j₂, hu, h⟩ := Session.bind_ok_iff.mp h
  obtain ⟨st, j₃, hst, h⟩ := Session.bind_ok_iff.mp h
  obtain ⟨texts, j₄, ht, h⟩ := Session.bind_ok_iff.mp h
  change ForIn.forIn (u.drop (chatLead u).length) _ (chatBody model) _ = _ at hst
  split at h
  · rename_i e
    simp only [Session.bind_ok_iff, Session.pure_ok_iff, Prod.mk.injEq, pure_bind] at h
    obtain ⟨out, j₅, hout, rfl, -⟩ := h
    exact ⟨s, u, st, texts, [], out, ⟨_, _, hs⟩, ⟨_, _, hu⟩, ⟨_, _, hst⟩, ⟨_, _, ht⟩, fun _ => rfl,
      fun e' => absurd (e.symm.trans e') (by decide), ⟨_, _, hout⟩, rfl⟩
  · rename_i e
    simp only [Session.bind_ok_iff, Session.pure_ok_iff, Prod.mk.injEq, pure_bind] at h
    obtain ⟨c, j₅, hc, out, j₆, hout, rfl, -⟩ := h
    exact ⟨s, u, st, texts, _, out, ⟨_, _, hs⟩, ⟨_, _, hu⟩, ⟨_, _, hst⟩, ⟨_, _, ht⟩,
      fun e' => absurd e' e, fun _ => ⟨c, ⟨_, _, hc⟩, rfl⟩, ⟨_, _, hout⟩, rfl⟩

theorem forall₂_mem {α β : Type} {R : α → β → Prop} :
    ∀ {xs : List α} {ys : List β} {x : α}, List.Forall₂ R xs ys → x ∈ xs → ∃ y ∈ ys, R x y
  | _, _, _, .nil, hx => absurd hx List.not_mem_nil
  | _, _, x, .cons (a := a) r rest, hx => by
    rcases List.mem_cons.mp hx with rfl | hx
    · exact ⟨_, List.mem_cons_self .., r⟩
    · obtain ⟨y, hy, ry⟩ := forall₂_mem rest hx
      exact ⟨y, List.mem_cons_of_mem _ hy, ry⟩

theorem SameRole.turnRole {m m' : Term} (h : SameRole m m') (role : TurnRole m) : TurnRole m' := by
  unfold TurnRole at role ⊢; rw [h.1]; exact role

theorem forall₂_mem_right {α β : Type} {R : α → β → Prop} :
    ∀ {xs : List α} {ys : List β} {y : β}, List.Forall₂ R xs ys → y ∈ ys → ∃ x ∈ xs, R x y
  | _, _, _, .nil, hy => absurd hy List.not_mem_nil
  | _, _, y, .cons r rest, hy => by
    rcases List.mem_cons.mp hy with rfl | hy
    · exact ⟨_, List.mem_cons_self .., r⟩
    · obtain ⟨x, hx, rx⟩ := forall₂_mem_right rest hy
      exact ⟨x, List.mem_cons_of_mem _ hx, rx⟩

theorem TurnRole.chat_leading {m : Term} (h : TurnRole m) :
    member (openaiRole m) ["system", "summary", "runtime"] = false := by
  rcases h with h | h <;> rw [h] <;> rfl

/-- **Chat prefix.** The chat messages of a closed history are a prefix of the chat messages of
that history followed by any messages. -/
theorem chat_append {H E : List Term} {model v₀ v₁ : Term} {j₀ j₁ k₀ k₁ : List Term}
    (turn : ∃ m ∈ H, TurnRole m) (matched : Matched H)
    (h₀ : chat H model j₀ = .ok (v₀, k₀)) (h₁ : chat (H ++ E) model j₁ = .ok (v₁, k₁)) :
    ∃ out₀ out₁, v₀ = list out₀ ∧ v₁ = list out₁ ∧ out₀ <+: out₁ := by
  obtain ⟨s₀, u₀, st₀, tx₀, hd₀, o₀, ⟨_, _, hs₀⟩, ⟨_, _, hu₀⟩, ⟨_, _, hl₀⟩, ⟨_, _, ht₀⟩, he₀, hn₀, ⟨_, _, ho₀⟩, rfl⟩ :=
    chat_run h₀
  obtain ⟨s₁, u₁, st₁, tx₁, hd₁, o₁, ⟨_, _, hs₁⟩, ⟨_, _, hu₁⟩, ⟨_, _, hl₁⟩, ⟨_, _, ht₁⟩, he₁, hn₁, ⟨_, _, ho₁⟩, rfl⟩ :=
    chat_run h₁
  obtain ⟨vH, T, jH, hsynH, rfl, ⟨m, mvH, role⟩, -, -⟩ :=
    syntheticRuntime_append turn (matched_closed true matched) hs₁
  have := (syntheticRuntime.stateless H true false).same hs₀ hsynH
  subst this
  obtain ⟨⟨uE, rfl, -⟩, fH, distU, ansU⟩ := uniqueChatCallIds_append hu₁ hu₀
  obtain ⟨m', mu, sr⟩ := forall₂_mem fH mvH
  have lead : chatLead (u₀ ++ uE) = chatLead u₀ :=
    takeWhile_append_of_false ⟨m', mu, (sr.turnRole role).chat_leading⟩
  rw [lead, drop_append_of_le (by unfold chatLead; exact takeWhile_length_le _ _)] at hl₁
  rw [lead] at ht₁
  obtain ⟨sm, jm, hP, hE⟩ := forIn_append_ok (chatBody_yields model) hl₁
  have := (Stateless.forIn (fun x acc => chatBody.stateless model x acc) _ _).same hl₀ hP
  subst this
  have := (Stateless.mapM (fun _ => by stateless) _).same ht₀ ht₁
  subst this
  have hdr : hd₁ = hd₀ ∧ ChatHeader hd₀ := by
    cases e : (tx₀.filter (· != b "")).isEmpty
    · obtain ⟨c₀, ⟨_, _, hc₀⟩, rfl⟩ := hn₀ e
      obtain ⟨c₁, ⟨_, _, hc₁⟩, rfl⟩ := hn₁ e
      have := (Provider.join.stateless _ _).same hc₀ hc₁
      subst this
      exact ⟨rfl, Or.inr ⟨_, rfl⟩⟩
    · rw [he₀ e, he₁ e]
      exact ⟨rfl, Or.inl rfl⟩
  have ansIn : Answered (u₀.drop (chatLead u₀).length) :=
    Answered.drop_takeWhile (ansU (syntheticRuntime_matched turn matched hsynH))
  obtain ⟨D, hD⟩ := chatLoop_prefix hE (chatLoop_released hl₀ ansIn)
  rw [hdr.1, ← hD, ← List.append_assoc] at ho₁
  have inv := chatInv_loop hl₀ (chatInv_init ansIn)
  have distinctU : ((u₀.drop (chatLead u₀).length).flatMap callsOf).Pairwise
      fun x y => (CallKey.mk x == CallKey.mk y) = false := by
    exact List.Pairwise.sublist (flatMap_drop_sublist callsOf u₀ _) distU
  obtain ⟨cAns, cDist⟩ := chatInv_final inv hdr.2 distinctU
  exact ⟨o₀, o₁, rfl, rfl, adjacentChat_append cAns cDist ho₁ ho₀⟩

end VerifiedKernel.ProviderLoop
