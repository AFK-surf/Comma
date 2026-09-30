import VerifiedKernelProofs.Loop.Discharge

/-! # The model-failure ACK keeps the round budget

The round budget `input_round_streak` counts assistant rounds since the last
fresh input. An advancing ACK clears it, except an ACK that carries
`keep_round_budget`. The loop marks the ACK of a model failure, so a failed
model request does not start the budget over. -/

namespace VerifiedKernel.Session.LoopDischarge
open Data
set_option Elab.async false

set_option backward.split false in
/-- An ACK marked `keep_round_budget` leaves the round count unchanged. -/
theorem sessionAck_keeps_rounds {s e t : Term} {j r : List Term}
    (call : sessionAck s e j = .ok (t, r))
    (marked : ∀ j', Data.event e "keep_round_budget" j' = .ok (a "true", j')) :
    t.get (a "input_round_streak") = s.get (a "input_round_streak") := by
  unfold sessionAck at call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨advanced, _, _, call⟩ := bind_ok call
  split at call
  · rw [pure_ok call]
  obtain ⟨keep, _, kread, call⟩ := bind_ok call
  rw [marked] at kread
  cases kread
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨current, _, read, call⟩ := bind_ok call
  simp only [field, fetch_ok_iff] at read
  obtain ⟨_, _, same, _⟩ := read
  obtain ⟨_, _, _, call⟩ := bind_ok call
  have kept := write_last
    (pre := [("last_ack_message_id", _), ("provider_reply_obligations", _), ("active_source_message_ids", _),
      ("visible_reply_activation_scope", _), ("visible_reply_egress_facts", _), ("runaway_unsettled_streak", _)])
    call rfl
  rw [kept, ← same]
  have self : (a "true" == a "true") = true := by decide
  simp [clearedWhen, self]

/-- The loop's model-failure ACK carries the mark. -/
theorem failureAck_marked (sid hwm : Term) (j : List Term) :
    Data.event (LoopProof.failureAckEvent sid hwm) "keep_round_budget" j = .ok (a "true", j) := by
  rfl

/-- Applying the loop's model-failure ACK (the only ACK of
`CommitSource.modelFailure`) leaves the round count unchanged. -/
theorem failureAck_keeps_rounds {s t sid hwm : Term} {j r : List Term}
    (call : sessionAck s (LoopProof.failureAckEvent sid hwm) j = .ok (t, r)) :
    t.get (a "input_round_streak") = s.get (a "input_round_streak") :=
  sessionAck_keeps_rounds call (failureAck_marked sid hwm)

end VerifiedKernel.Session.LoopDischarge
