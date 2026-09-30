import VerifiedKernelProofs.Session.WorkInput

namespace VerifiedKernel.Session.WorkConservation
open Data

theorem frontier_write (source : Term) (events : List Term) (notifyInput : Bool) :
    Command.withConversationFrontier source (Command.writeInput (list events) notifyInput) =
      Command.writeInput (list (events ++ [Command.conversationFrontier source])) notifyInput := by
  cases notifyInput <;>
    simp +decide [Command.withConversationFrontier, Command.writeInput, Command.perform,
      list, a, b, Term.text]

theorem frontier_input_start {result source : Term} {events : List Term} {notifyInput : Bool}
    (started : InputStart result events notifyInput) :
    InputStart (Command.withConversationFrontier source result)
      (events ++ [Command.conversationFrontier source]) notifyInput := by
  rcases started with rfl | ⟨operation, metadata, workspace, billing, rfl⟩
  · exact Or.inl (frontier_write _ _ _)
  · apply Or.inr
    refine ⟨operation, metadata, workspace, billing, ?_⟩
    simp +decide [Command.withConversationFrontier, Command.perform, a, b, list, Term.text]

theorem frontier_binary_keys (source : Term) : BinaryKeys (Command.conversationFrontier source) := by
  simp [Command.conversationFrontier, BinaryKeys, b, Term.text, Term.isBinary]

/-- Staging retains the exact atomic input/frontier batch. Its continuation
returns working state, rather than a durable input acknowledgment. -/
theorem staged_frontier_write (source : Term) (events : List Term) (notifyInput : Bool) :
    Command.stageConversationResult
      (Command.withConversationFrontier source (Command.writeInput (list events) notifyInput)) =
    .tuple [a "perform",
      .tuple [a "write", list (events ++ [Command.conversationFrontier source]), list []],
      .tuple [b "conversation_staged", list (events ++ [Command.conversationFrontier source])]] := by
  rw [frontier_write]
  cases notifyInput <;>
    simp +decide [Command.stageConversationResult, Command.writeInput, Command.perform, list, a, b, Term.text]

def ConversationInputResult (result : Term) : Prop :=
  result = Command.duplicateInput ∨
  result = Command.finish (.tuple [a "error", a "conversation_source_gap"]) ∨
  result = Command.finish (.tuple [a "error", a "saturated"]) ∨
  result = Command.finish (.tuple [a "error", a "invalid_delivery_events"]) ∨
  ∃ events source notifyInput,
    InputStart result (events ++ [Command.conversationFrontier source]) notifyInput ∧
    (∀ event ∈ events, BinaryKeys event) ∧ events.all Command.inputEventAllowed = true

theorem frontier_commit {s entry pending source : Term} {j r : List Term} {notifyInput : Bool}
    (h : Command.commitInput s entry [] notifyInput j = .ok (pending, r)) :
    ConversationInputResult (Command.withConversationFrontier source pending) := by
  rcases commit_input_start (by simp) h with invalid | ⟨events, started, keys, allowed⟩
  · subst pending
    exact Or.inr (Or.inr (Or.inr (Or.inl rfl)))
  · exact Or.inr (Or.inr (Or.inr (Or.inr
      ⟨events, source, notifyInput, frontier_input_start started, keys, allowed⟩)))

theorem conversation_input_atomic_frontier {s args result : Term} {j r : List Term}
    (h : Command.conversationInput s args j = .ok (result, r)) :
    ConversationInputResult result := by
  unfold Command.conversationInput at h
  split at h
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    split at h
    · exact Or.inr (Or.inl (pure_ok h))
    · split at h
      · exact Or.inl (pure_ok h)
      · split at h
        · obtain ⟨pending, _, read, h⟩ := bind_ok h
          rw [pure_ok h]
          exact frontier_commit read
        · obtain ⟨original, _, inputRead, h⟩ := bind_ok h
          split at h
          · obtain ⟨pending, _, read, h⟩ := bind_ok h
            rw [pure_ok h]
            exact frontier_commit read
          · rename_i notDuplicate
            obtain ⟨pending, _, read, h⟩ := bind_ok h
            rw [pure_ok h, pure_ok read]
            rcases input_start inputRead with duplicate | saturated | invalid |
              ⟨events, started, keys, allowed⟩
            · subst original
              simp +decide [Command.isDuplicateInput, Command.duplicateInput,
                Command.perform, a, b, Term.text] at notDuplicate
            · subst original
              exact Or.inr (Or.inr (Or.inl rfl))
            · subst original
              exact Or.inr (Or.inr (Or.inr (Or.inl rfl)))
            · exact Or.inr (Or.inr (Or.inr (Or.inr
                ⟨events, _, true, frontier_input_start started, keys, allowed⟩)))
  · exact (fail_ok h).elim

end VerifiedKernel.Session.WorkConservation
