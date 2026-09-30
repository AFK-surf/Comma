import VerifiedKernelProofs.Session.DurableConfirmation

namespace VerifiedKernel.Session.InputAdmission
open Data Command

/-- Rejection returns before either the workspace request or the Session write request. -/
theorem commit_input_rejects {state entry agent session : Term} {events trailing : List Term}
    {notifyInput : Bool} {j j₁ j₂ j₃ : List Term}
    (agentRead : field state "agent_id" j = .ok (agent, j₁))
    (sessionRead : field state "session_id" j₁ = .ok (session, j₂))
    (eventsRead : inputEvents entry j₂ = .ok (events, j₃))
    (rejected : (events ++ trailing).all inputEventAllowed = false) :
    commitInput state entry trailing notifyInput j =
      .ok (finish (.tuple [a "error", a "invalid_delivery_events"]), j₃) := by
  simp only [commitInput, bind, StateT.bind, Except.bind, agentRead, sessionRead, eventsRead,
    rejected, Bool.not_false, ↓reduceIte, Pure.pure, StateT.pure, Except.pure]

/-- Every successful command result either rejects the batch or checked its normalized events. -/
theorem commit_input_requires_admission {state entry result : Term} {trailing : List Term}
    {notifyInput : Bool} {j r : List Term}
    (h : commitInput state entry trailing notifyInput j = .ok (result, r)) :
    result = finish (.tuple [a "error", a "invalid_delivery_events"]) ∨
      ∃ events j₁ j₂, inputEvents entry j₁ = .ok (events, j₂) ∧
        (events ++ trailing).all inputEventAllowed = true := by
  unfold commitInput at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨events, j₂, read, h⟩ := bind_ok h
  split at h
  · exact Or.inl (pure_ok h)
  · rename_i allowed
    exact Or.inr ⟨events, _, j₂, read, by simpa using allowed⟩

/-- An identity collision returns before either write effect, without consuming its source identity. -/
theorem commit_input_rejects_collision {state entry agent session : Term} {events trailing : List Term}
    {notifyInput : Bool} {j j₁ j₂ j₃ j₄ : List Term}
    (agentRead : field state "agent_id" j = .ok (agent, j₁))
    (sessionRead : field state "session_id" j₁ = .ok (session, j₂))
    (eventsRead : inputEvents entry j₂ = .ok (events, j₃))
    (allowed : (events ++ trailing).all inputEventAllowed = true)
    (collision : inputIdentitiesDistinct (events ++ trailing) j₃ = .ok (false, j₄)) :
    commitInput state entry trailing notifyInput j =
      .ok (finish (.tuple [a "error", a "invalid_delivery_events"]), j₄) := by
  simp only [commitInput, bind, StateT.bind, Except.bind, agentRead, sessionRead, eventsRead,
    allowed, Bool.not_true, Bool.false_eq_true, ↓reduceIte, collision, Bool.not_false,
    Pure.pure, StateT.pure, Except.pure]

/-- Non-rejection requires the identity check on the complete normalized and generated batch. -/
theorem commit_input_requires_distinct {state entry result : Term} {trailing : List Term}
    {notifyInput : Bool} {j r : List Term}
    (h : commitInput state entry trailing notifyInput j = .ok (result, r)) :
    result = finish (.tuple [a "error", a "invalid_delivery_events"]) ∨
      ∃ events j₁ j₂ j₃, inputEvents entry j₁ = .ok (events, j₂) ∧
        (events ++ trailing).all inputEventAllowed = true ∧
        inputIdentitiesDistinct (events ++ trailing) j₂ = .ok (true, j₃) := by
  unfold commitInput at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨events, j₂, read, h⟩ := bind_ok h
  split at h
  · exact Or.inl (pure_ok h)
  · rename_i allowed
    obtain ⟨distinct, j₃, checked, h⟩ := bind_ok h
    cases distinct with
    | false => exact Or.inl (pure_ok h)
    | true => exact Or.inr ⟨events, _, j₂, j₃, read, by simpa using allowed, checked⟩

/-- A checked delivery batch contains neither queue retirement nor destructive history events. -/
theorem admitted_event_no_retirement {events : List Term} {event : Term}
    (allowed : events.all inputEventAllowed = true) (member : event ∈ events) :
    event.get (b "type") ≠ b "queue_ack" ∧
    event.get (b "type") ≠ b "queue_consume" ∧
    event.get (b "type") ≠ b "archive_advance" ∧
    event.get (b "type") ≠ b "session_microcompact" := by
  have h := List.all_eq_true.mp allowed event member
  unfold inputEventAllowed at h
  repeat' apply And.intro
  all_goals intro eq; rw [eq] at h; simp +decide at h

end VerifiedKernel.Session.InputAdmission
