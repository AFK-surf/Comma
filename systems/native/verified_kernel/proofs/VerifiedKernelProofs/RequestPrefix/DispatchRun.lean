import VerifiedKernelProofs.RequestPrefix.Dispatch
import VerifiedKernelProofs.RequestPrefix.KeepsSession
import VerifiedKernelProofs.RequestPrefix.Inline

/-!
A provider dispatch sends the inlined prompt, Session context, and request input.
-/

namespace VerifiedKernel.RequestPrefix
open Data

set_option maxHeartbeats 4000000

theorem HostAnswers.stable {host : Term → Term} {J : List Term} (h : HostAnswers host J) : StableJournal J :=
  fun r v J' ok => (h r v J' ok).1

/-- The attachment watermark of a state. -/
def watermark (s : Term) : Term := (Session.RoundQuery.valueOf s "last_ack_message_id").default (i 0)

/-- A provider dispatch encodes the prompt, the context `C`, and request input `X`, each message
inlined by the host. -/
theorem dispatch_run {s delta cfg tools mode body : Term} {name : ByteArray}
    {pre : List (Term × Term)} {J J' : List Term} {host : Term → Term}
    (hJ : HostAnswers host J) (hpre : PrefetchSound host pre)
    (h : Session.Request.dispatch s (.tuple [delta, .binary name, cfg, tools, mode])
      pre J = .ok (body, J')) :
    ∃ prompt C X tools', (∃ hd j k, Session.ReplyQuery.promptSnapshot s nil j = .ok (.tuple [hd, prompt], k)) ∧
      (∃ j k, Session.Request.context s j = .ok (list C, k)) ∧ tools = list tools' ∧
      ∃ j k, Provider.Request.encodedBody (String.fromUTF8! name) cfg
        ((promptHead prompt ++ (C ++ X)).map (inlineOne host (watermark s))) tools'
        (String.fromUTF8! (Provider.bytes mode)) j = .ok (body, k) := by
  unfold Session.Request.dispatch at h
  have step := Session.bind_ok_iff.mp h; clear h; obtain ⟨snap, J₁, hsnap, h⟩ := step
  have e₁ := (Session.ReplyQuery.promptSnapshot.stateless s nil).keep hsnap
  subst e₁
  dsimp only at h
  split at h
  · rename_i hd prompt
    have step := Session.bind_ok_iff.mp h; clear h; obtain ⟨ctx, J₂, hctx, h⟩ := step
    have e₂ := (Session.Request.context.stateless s).keep hctx
    subst e₂
    have step := Session.bind_ok_iff.mp h; clear h; obtain ⟨msgs, J₃, hb, h⟩ := step
    have e₃ := (Session.Request.build.keeps s _).run hJ.stable hb
    subst e₃
    obtain ⟨C, X, rfl, hm⟩ := build_messages hb
    have step := Session.bind_ok_iff.mp h; clear h; obtain ⟨M, J₄, hM, h⟩ := step
    obtain ⟨eM, rfl⟩ := inline_map hJ hpre hM
    have neutral : (Term.binary name == a "neutral") = false := rfl
    rw [neutral] at h
    simp only [Bool.false_eq_true, ↓reduceIte] at h
    have step := Session.bind_ok_iff.mp h; clear h; obtain ⟨tl, J₅, htl, h⟩ := step
    refine ⟨prompt, C, X, tl, ?_, ⟨_, _, hctx⟩, asList_ok htl, ?_⟩
    · exact ⟨hd, _, _, hsnap⟩
    · rw [← hm]
      unfold watermark
      rw [← eM]
      exact ⟨_, _, h⟩
  · simp [Session.fail_ok_iff] at h

end VerifiedKernel.RequestPrefix
