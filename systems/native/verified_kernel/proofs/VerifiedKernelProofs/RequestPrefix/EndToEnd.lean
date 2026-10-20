import VerifiedKernelProofs.RequestPrefix.Context
import VerifiedKernelProofs.RequestPrefix.DispatchRun
import VerifiedKernelProofs.Provider.RequestPrefix

/-!
# Consecutive provider requests share a prefix

Two provider dispatches of one Session, for states `s` and then `s'`, start with the same durable
history `D`: the stored prompt and the Session context of `s`, with attachments inlined. The
first request sends `D ++ X`, the second `D ++ X'`. With the request prefix theorem
(`ProviderLoop.request_prefix_stable`), both provider bodies start with the projection of `D`.

The states must agree on the window fields and the stored prompt (`SameWindow`), the transcript
must only grow, and attachment inlining must read the earlier messages the same way (`AckFrame`). The host must answer each request the same way in both dispatches
(`HostAnswers`, `PrefetchSound`).
-/

namespace VerifiedKernel.RequestPrefix
open Data

set_option maxHeartbeats 4000000

/-- Attachment inlining reads the context of `s` the same way at the watermark of `s'`. -/
def AckFrame (host : Term → Term) (s s' : Term) : Prop :=
  ∀ C j k, Session.Request.context s j = .ok (list C, k) →
    ∀ m ∈ C, inlineOne host (watermark s') m = inlineOne host (watermark s) m

theorem inlineOne_summary (host : Term → Term) (w p : Term) :
    inlineOne host w (Session.Request.summary p) = Session.Request.summary p := rfl

theorem inlineOne_promptHead (host : Term → Term) (w w' p : Term) :
    (promptHead p).map (inlineOne host w') = (promptHead p).map (inlineOne host w) := by
  unfold promptHead; split <;> simp [inlineOne_summary]

/-- **Durable history.** Both dispatches send the durable history `D` first. -/
theorem dispatch_prefix {s s' delta delta' cfg tools mode
      body body' : Term} {name : ByteArray} {xs ys : List Term} {pre pre' : List (Term × Term)}
    {J J' K K' : List Term} {host : Term → Term}
    (hJ : HostAnswers host J) (hJ' : HostAnswers host J') (hpre : PrefetchSound host pre)
    (hpre' : PrefetchSound host pre')
    (window : SameWindow s s') (stored : s'.get (a "system_prompt") = s.get (a "system_prompt"))
    (msgs : s.get (a "messages") = list xs) (msgs' : s'.get (a "messages") = list (xs ++ ys))
    (ack : AckFrame host s s')
    (h : Session.Request.dispatch s (.tuple [delta, .binary name, cfg, tools, mode]) pre J =
      .ok (body, K))
    (h' : Session.Request.dispatch s' (.tuple [delta', .binary name, cfg, tools, mode]) pre' J' =
      .ok (body', K')) :
    ∃ D X Y X' tools', tools = list tools' ∧
      (∃ j k, Provider.Request.encodedBody (String.fromUTF8! name) cfg (D ++ X) tools'
        (String.fromUTF8! (Provider.bytes mode)) j = .ok (body, k)) ∧
      (∃ j k, Provider.Request.encodedBody (String.fromUTF8! name) cfg (D ++ (Y ++ X')) tools'
        (String.fromUTF8! (Provider.bytes mode)) j = .ok (body', k)) ∧
      ∃ C C', (∃ j k, Session.Request.context s j = .ok (list C, k)) ∧
        (∃ j k, Session.Request.context s' j = .ok (list (C ++ C'), k)) ∧
        D = (promptHead (Session.ReplyQuery.presentTerm (s.get (a "system_prompt"))) ++ C).map
          (inlineOne host (watermark s)) ∧
        Y = C'.map (inlineOne host (watermark s')) := by
  obtain ⟨prompt, C, X, tl, ⟨hd, _, _, hsnap⟩, ⟨_, _, hctx⟩, rfl, ⟨_, _, hb⟩⟩ :=
    dispatch_run hJ hpre h
  obtain ⟨prompt', C', X', tl', ⟨hd', _, _, hsnap'⟩, ⟨_, _, hctx'⟩, et, ⟨_, _, hb'⟩⟩ :=
    dispatch_run hJ' hpre' h'
  injection et with et; subst et
  have ep := promptSnapshot_nil hsnap
  have ep' := promptSnapshot_nil hsnap'
  rw [stored] at ep'
  simp only [Term.tuple.injEq, List.cons.injEq, and_true] at ep ep'
  obtain ⟨-, rfl⟩ := ep
  obtain ⟨-, rfl⟩ := ep'
  obtain ⟨Y, rfl⟩ := context_append window msgs msgs' hctx hctx'
  refine ⟨(promptHead (Session.ReplyQuery.presentTerm (s.get (a "system_prompt"))) ++ C).map (inlineOne host (watermark s)),
    X.map (inlineOne host (watermark s)),
    Y.map (inlineOne host (watermark s')), X'.map (inlineOne host (watermark s')), tl, rfl, ?_, ?_,
    C, Y, ⟨_, _, hctx⟩, ⟨_, _, hctx'⟩, rfl, rfl⟩
  · rw [← List.map_append, List.append_assoc]; exact ⟨_, _, hb⟩
  · have hC : C.map (inlineOne host (watermark s')) = C.map (inlineOne host (watermark s)) :=
      List.map_congr_left (ack C _ _ hctx)
    have e : (promptHead (Session.ReplyQuery.presentTerm (s.get (a "system_prompt"))) ++ (C ++ Y ++ X')).map
          (inlineOne host (watermark s')) =
        (promptHead (Session.ReplyQuery.presentTerm (s.get (a "system_prompt"))) ++ C).map (inlineOne host (watermark s)) ++
          (Y ++ X').map (inlineOne host (watermark s')) := by
      simp only [List.map_append, List.append_assoc, hC, inlineOne_promptHead host (watermark s') (watermark s)
        (Session.ReplyQuery.presentTerm (s.get (a "system_prompt")))]
    rw [e, List.map_append (f := inlineOne host (watermark s')) (l₁ := Y) (l₂ := X')] at hb'
    exact ⟨_, _, hb'⟩

/-- What `encodedBody` gives `Request.body`: Anthropic lists as they are, other lists scrubbed. -/
def wire (protocol : String) (xs : List Term) : List Term :=
  if protocol == "anthropic" then xs else xs.map Provider.scrub

theorem wire_append (protocol : String) (xs ys : List Term) :
    wire protocol (xs ++ ys) = wire protocol xs ++ wire protocol ys := by
  unfold wire; split <;> simp

theorem encodedBody_run {protocol mode : String} {cfg body : Term} {msgs tools : List Term} {j k : List Term}
    (h : Provider.Request.encodedBody protocol cfg msgs tools mode j = .ok (body, k)) :
    ∃ b, (∃ j k, Provider.Request.body protocol cfg (wire protocol msgs) (wire protocol tools) mode j =
      .ok (b, k)) ∧ ∃ j k, Provider.encode (Provider.scrub b) j = .ok (body, k) := by
  unfold Provider.Request.encodedBody at h
  obtain ⟨b, j₁, hb, h⟩ := Session.bind_ok_iff.mp h
  exact ⟨b, ⟨_, _, by unfold wire; exact hb⟩, _, _, h⟩

/-- **Consecutive requests share a prefix.** Two dispatches of one Session send bodies `b₁` and
`b₂` (then scrubbed and JSON-encoded). If the durable history `D` is closed, both bodies have the
head of the projection `b₀` of `D` alone, and the messages of `b₀` are a prefix of the messages of
each. The messages after `D` (the context that `s'` adds and request-time input) need
no condition. -/
theorem consecutive_requests_share_prefix {s s' delta delta' cfg tools mode body body' : Term} {name : ByteArray} {xs : List Term} {pre pre' : List (Term × Term)}
    {J J' K K' : List Term} {host : Term → Term}
    (protocol : String.fromUTF8! name ∈ ["chat", "anthropic", "responses"])
    (hJ : HostAnswers host J) (hJ' : HostAnswers host J') (hpre : PrefetchSound host pre)
    (hpre' : PrefetchSound host pre')
    (window : SameWindow s s') (stored : s'.get (a "system_prompt") = s.get (a "system_prompt"))
    (msgs : s.get (a "messages") = list xs) (grown : Session.TranscriptExtends s s')
    (ack : AckFrame host s s')
    (h : Session.Request.dispatch s (.tuple [delta, .binary name, cfg, tools, mode]) pre J =
      .ok (body, K))
    (h' : Session.Request.dispatch s' (.tuple [delta', .binary name, cfg, tools, mode]) pre' J' =
      .ok (body', K')) :
    let pr := String.fromUTF8! name
    let md := String.fromUTF8! (Provider.bytes mode)
    ∃ D Y tools' b₁ b₂, tools = list tools' ∧
      (∃ X j k, Provider.Request.body pr cfg (wire pr (D ++ X)) (wire pr tools') md j = .ok (b₁, k)) ∧
      (∃ j k, Provider.encode (Provider.scrub b₁) j = .ok (body, k)) ∧
      (∃ X j k, Provider.Request.body pr cfg (wire pr (D ++ (Y ++ X))) (wire pr tools') md j = .ok (b₂, k)) ∧
      (∃ j k, Provider.encode (Provider.scrub b₂) j = .ok (body', k)) ∧
      (∃ C C', (∃ j k, Session.Request.context s j = .ok (list C, k)) ∧
        (∃ j k, Session.Request.context s' j = .ok (list (C ++ C'), k)) ∧
        D = (promptHead (Session.ReplyQuery.presentTerm (s.get (a "system_prompt"))) ++ C).map
          (inlineOne host (watermark s)) ∧
        Y = C'.map (inlineOne host (watermark s'))) ∧
      ∀ b₀ j k, Provider.Request.body pr cfg (wire pr D) (wire pr tools') md j = .ok (b₀, k) →
        ProviderLoop.ClosedHistory (wire pr D) →
        ProviderLoop.headOf pr b₁ = ProviderLoop.headOf pr b₀ ∧ ProviderLoop.headOf pr b₂ = ProviderLoop.headOf pr b₀ ∧
          ProviderLoop.messagesOf pr b₀ <+: ProviderLoop.messagesOf pr b₁ ∧
          ProviderLoop.messagesOf pr b₀ <+: ProviderLoop.messagesOf pr b₂ := by
  intro pr md
  obtain ⟨ys, msgs'⟩ := grown xs msgs
  obtain ⟨D, X, Y, X', tl, rfl, ⟨_, _, hb⟩, ⟨_, _, hb'⟩, durable⟩ :=
    dispatch_prefix hJ hJ' hpre hpre' window stored msgs msgs' ack h h'
  obtain ⟨b₁, ⟨_, _, hb₁⟩, e₁⟩ := encodedBody_run hb
  obtain ⟨b₂, ⟨_, _, hb₂⟩, e₂⟩ := encodedBody_run hb'
  refine ⟨D, Y, tl, b₁, b₂, rfl, ⟨X, _, _, hb₁⟩, e₁, ⟨X', _, _, hb₂⟩, e₂, durable, ?_⟩
  intro b₀ j k h₀ closed
  rw [wire_append] at hb₁ hb₂
  rw [wire_append] at hb₂
  exact ProviderLoop.request_prefix_stable protocol closed h₀ hb₁ hb₂

end VerifiedKernel.RequestPrefix

namespace VerifiedKernel.RequestPrefix

/-- With the same acknowledgment watermark, inlining reads every message the same way. -/
theorem AckFrame.of_watermark {host : Term → Term} {s s' : Term} (h : watermark s' = watermark s) :
    AckFrame host s s' := fun _ _ _ _ m _ => by rw [h]

end VerifiedKernel.RequestPrefix
