import VerifiedKernelProofs.Session.AppendOnly.SeqCore
import VerifiedKernelProofs.Proof.NativeProducerTactic

namespace VerifiedKernel.Session
open Data
open WorkConservation
set_option Elab.async false

def sessionEventWrittenKeys : List String :=
  ["context_overflow_recovery", "events", "last_seq", "llm_failure_streak", "input_queue",
    "runaway_unsettled_streak", "visible_reply_egress_facts", "terminal_reply_ack_hwm",
    "runtime_failure_reply", "last_activity_at"]

set_option backward.split false in
/-- Read-only binds do not change the Session. Compose the two actual writes explicitly. -/
theorem sessionEvent_fields {s e t : Term} {j r : List Term}
    (h : sessionEvent s e j = .ok (t, r)) :
    (∃ seq first last, add (lastSeq s) (i 1) first = .ok (seq, last) ∧
      t.get (a "last_seq") = seq) ∧
    (∀ key, sessionEventWrittenKeys.all (fun name => name != key) = true →
      t.get (a key) = s.get (a key)) := by
  unfold sessionEvent at h
  have bound := bind_ok h
  clear h
  obtain ⟨previous, _, read, h⟩ := bound
  have previousEq := (fetch_ok_iff.mp read).2.2.1
  subst previous
  have bound := bind_ok h
  clear h
  obtain ⟨seq, _, added, h⟩ := bound
  have preserved : ∀ key, sessionEventWrittenKeys.all (fun name => name != key) = true →
      s.get (a key) = s.get (a key) := fun _ _ => rfl
  repeat' first
    | (execution_head_is h "VerifiedKernel.Data.write"
       constructor
       · exact ⟨seq, _, _, added, write_get_key "last_seq" h rfl⟩
       · intro key outside
         exact (write_frame_key key h (by
           simp only [sessionEventWrittenKeys, List.all_cons, List.all_nil,
             Bool.and_true, Bool.and_eq_true] at outside ⊢
           exact outside.2)).trans (preserved key outside))
    | (execution_head_is h "Bind.bind"
       have bound := bind_ok h
       clear h
       obtain ⟨value, _, prior, h⟩ := bound
       first
         | (execution_head_is prior "VerifiedKernel.Data.write"
            have preserved : ∀ key, sessionEventWrittenKeys.all (fun name => name != key) = true →
                value.get (a key) = s.get (a key) := by
              intro key outside
              exact (write_frame_key key prior (by
                simp only [sessionEventWrittenKeys, List.all_cons, List.all_nil,
                  Bool.and_true, Bool.and_eq_true] at outside ⊢
                exact outside.1)).trans (preserved key outside))
         | (execution_head_is prior "Pure.pure"; have same := pure_ok prior; subst value)
         | skip)
    | dsimp only at h
    | split at h

set_option backward.split false in
theorem sessionEvent_retry_result {s e t : Term} {j r : List Term}
    (h : sessionEvent s e j = .ok (t, r)) :
    ∃ queue fact first last,
      markRetry (s.get (a "input_queue")) fact first = .ok (queue, last) ∧
      t.get (a "input_queue") = queue := by
  unfold sessionEvent at h
  repeat' first
    | (execution_head_is h "VerifiedKernel.Data.write"
       exact ⟨_, _, _, _, retry, write_get_key "input_queue" h rfl⟩)
    | (execution_head_is h "Bind.bind"
       have bound := bind_ok h
       clear h
       obtain ⟨value, _, prior, h⟩ := bound
       first
         | (execution_head_is prior "VerifiedKernel.Session.markRetry"
            have retry := prior
            rw [(fetch_ok_iff.mp queueRead).2.2.1] at retry)
         | (execution_head_is prior "VerifiedKernel.Data.field"
            have queueRead := prior)
         | skip)
    | dsimp only at h
    | split at h

theorem sessionEvent_seq_preserved {s e t : Term} {j r : List Term}
    (h : sessionEvent s e j = .ok (t, r)) : SeqStep s t := by
  obtain ⟨⟨seq, first, last, added, written⟩, frame⟩ := sessionEvent_fields h
  rintro ⟨xs, n, messages, watermark, stamps, ordered⟩
  rw [watermark, add_integer] at added
  simp only [Except.ok.injEq, Prod.mk.injEq] at added
  obtain ⟨rfl, _⟩ := added
  refine ⟨xs, n + 1, (frame "messages" rfl).trans messages, ?_, ?_, ordered⟩
  · rw [lastSeq, written, default_integer]
  · intro message member
    obtain ⟨stamp, same, bound⟩ := stamps message member
    exact ⟨stamp, same, Int.le_trans bound (Int.le_add_one (Int.le_refl n))⟩

end VerifiedKernel.Session
