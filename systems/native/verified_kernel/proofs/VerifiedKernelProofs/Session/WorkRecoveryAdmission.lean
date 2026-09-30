import VerifiedKernelProofs.Session.WorkOrdinaryWrite
import VerifiedKernelProofs.Session.WorkDriverQueryPrefix

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

def recoveryProgram (state checkpoint : Term) : KernelM Term := do
  let session ← field state "session_id"
  let now ← observe (a "time")
  match ← ReplyQuery.abortPendingReply state (.tuple [session, i (integerValue now / 1000)]) with
  | .tuple [.atom "ok", events, hwm, intent] =>
    return Command.perform (.tuple [a "write", events, list [.tuple [a "hwm", hwm]]])
      (.tuple [b "recovered", RoundQuery.atomFirst intent "scope"])
  | _ => return Command.finish (← Recovery.observeSession state checkpoint)

theorem recovery_program (state args checkpoint : Term) :
    Command.start state (.tuple [a "recover", args, checkpoint]) = recoveryProgram state checkpoint := by
  funext journal
  rfl

theorem abort_pending_reply_events {state session now result : Term} {journal rest : List Term}
    (call : ReplyQuery.abortPendingReply state (.tuple [session, now]) journal = .ok (result, rest)) :
    result = a "none" ∨ ∃ events hwm intent,
      result = .tuple [a "ok", list events, hwm, intent] ∧ OrdinaryBatch events := by
  unfold ReplyQuery.abortPendingReply at call
  obtain ⟨intent, _, _, call⟩ := bind_ok call
  split at call
  · exact Or.inl (pure_ok call)
  · refine Or.inr ⟨_, _, intent, pure_ok call, ?_⟩
    intro event member
    simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    rcases member with rfl | rfl | rfl
    all_goals exact ⟨rfl, by simp +decide [OrdinaryKind, Term.get, b, Term.text]⟩

theorem recovery_start {state args checkpoint result : Term} {journal rest : List Term}
    (call : Command.start state (.tuple [a "recover", args, checkpoint]) journal = .ok (result, rest)) :
    (∃ outcome, result = Command.finish outcome) ∨
    ∃ events hwm scope, OrdinaryBatch events ∧
      result = Command.perform (.tuple [a "write", list events, list [.tuple [a "hwm", hwm]]])
        (.tuple [b "recovered", scope]) := by
  rw [recovery_program] at call
  unfold recoveryProgram at call
  obtain ⟨session, _, _, call⟩ := bind_ok call
  obtain ⟨now, _, _, call⟩ := bind_ok call
  obtain ⟨aborted, _, observed, call⟩ := bind_ok call
  rcases abort_pending_reply_events observed with none | ⟨events, hwm, intent, same, batch⟩
  · rw [none] at call
    obtain ⟨outcome, _, _, call⟩ := bind_ok call
    exact Or.inl ⟨outcome, pure_ok call⟩
  · rw [same] at call
    exact Or.inr ⟨events, hwm, _, batch, pure_ok call⟩

end VerifiedKernel.Session.WorkConservation
