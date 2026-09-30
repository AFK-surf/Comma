import VerifiedKernelProofs.Session.WorkInputAdmissionActual
import VerifiedKernelProofs.Session.WorkInputTimestamp

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

def logEvent (session entry now : Term) : Term :=
  let payload := RoundQuery.atomFirst entry "payload"
  Command.compact [("type", b "session_log_message"), ("session_id", session),
    ("message_id", RoundQuery.atomFirst payload "message_id"), ("role", b "event"),
    ("content", RoundQuery.atomFirst payload "content"),
    ("source_message_id", RoundQuery.atomFirst entry "source_message_id"),
    ("dedupe_key", RoundQuery.atomFirst payload "dedupe_key"),
    ("created_at", (RoundQuery.atomFirst payload "created_at").default (i (integerValue now / 1000)))]

def logProgram (state entry : Term) : KernelM Term := do
  let role := RoundQuery.atomFirst (RoundQuery.atomFirst entry "payload") "role"
  if [b "user", b "runtime", a "user", a "runtime"].contains role then
    return Command.finish (.tuple [a "error", .tuple [a "invalid_session_log_role", role]])
  let session ← field state "session_id"
  let now ← observe (a "time")
  Command.commitInput state entry [logEvent session entry now] false

/-- Definitional equality checks this factorization against the actual public command. -/
theorem log_program (state entry checkpoint : Term) :
    Command.start state (.tuple [a "log", entry, checkpoint]) = logProgram state entry := by
  funext journal
  rfl

theorem log_generated {state entry checkpoint result : Term} {journal rest : List Term}
    (call : Command.start state (.tuple [a "log", entry, checkpoint]) journal = .ok (result, rest)) :
    result = Command.finish (.tuple [a "error", .tuple [a "invalid_session_log_role",
      RoundQuery.atomFirst (RoundQuery.atomFirst entry "payload") "role"]]) ∨
    ∃ session now before, session = state.get (a "session_id") ∧
      Command.commitInput state entry [logEvent session entry now] false before = .ok (result, rest) := by
  rw [log_program] at call
  unfold logProgram at call
  split at call
  · exact Or.inl (pure_ok call)
  · obtain ⟨session, _, sessionRead, call⟩ := bind_ok call
    obtain ⟨now, before, _, call⟩ := bind_ok call
    have sessionEq : session = state.get (a "session_id") := by
      simp only [field, fetch_ok_iff] at sessionRead
      exact sessionRead.2.2.1
    exact Or.inr ⟨session, now, before, sessionEq, call⟩

theorem log_start {state entry checkpoint result : Term} {journal rest : List Term}
    (call : Command.start state (.tuple [a "log", entry, checkpoint]) journal = .ok (result, rest)) :
    result = Command.finish (.tuple [a "error", .tuple [a "invalid_session_log_role",
      RoundQuery.atomFirst (RoundQuery.atomFirst entry "payload") "role"]]) ∨
    result = Command.finish (.tuple [a "error", a "invalid_delivery_events"]) ∨
    ∃ batch, InputStart result batch false ∧ (∀ event ∈ batch, BinaryKeys event) ∧
      batch.all Command.inputEventAllowed = true := by
  rcases log_generated call with invalid | ⟨session, now, before, _, committed⟩
  · exact Or.inl invalid
  · apply Or.inr
    apply commit_input_start (h := committed)
    intro event member
    have same := List.mem_singleton.mp member
    subst event
    exact compact_binary_keys _

theorem log_main_start {state entry checkpoint result : Term} {journal rest : List Term}
    (call : Command.start state (.tuple [a "log", entry, checkpoint]) journal = .ok (result, rest)) :
    result = Command.finish (.tuple [a "error", .tuple [a "invalid_session_log_role",
      RoundQuery.atomFirst (RoundQuery.atomFirst entry "payload") "role"]]) ∨
    result = Command.finish (.tuple [a "error", a "invalid_delivery_events"]) ∨
    ∃ now earlier selected before after,
      InputStart result (selected ++ [logEvent (state.get (a "session_id")) entry now]) false ∧
      (∀ current ∈ earlier, BinaryKeys current) ∧
      (∀ current ∈ earlier, Command.inputEventAllowed current = true) ∧
      (∀ current ∈ selected, current ∈ earlier) ∧
      Command.inputIdentitiesDistinct (earlier ++ [logEvent (state.get (a "session_id")) entry now]) before =
        .ok (true, after) := by
  rcases log_generated call with invalid | ⟨session, now, _, sessionEq, committed⟩
  · exact Or.inl invalid
  · rw [sessionEq] at committed
    change Command.commitInput state entry ([] ++ [logEvent (state.get (a "session_id")) entry now]) false _ = _ at committed
    rcases commit_input_main_start (by simp) committed with invalid | ⟨earlier, selected, before, after, accepted⟩
    · exact Or.inr (Or.inl invalid)
    · exact Or.inr (Or.inr ⟨now, earlier, selected, before, after, accepted⟩)

theorem started_log_admitted {state entry checkpoint result : Term} {journal rest batch : List Term}
    (call : Command.start state (.tuple [a "log", entry, checkpoint]) journal = .ok (result, rest))
    (started : InputStart result batch false) :
    (∀ event ∈ batch, BinaryKeys event) ∧ (∀ event ∈ batch, Command.inputEventAllowed event = true) := by
  rcases log_start call with invalidRole | invalidInput | ⟨actual, actualStart, keys, allowed⟩
  · rw [invalidRole] at started
    simp [InputStart, Command.finish, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · rw [invalidInput] at started
    simp [InputStart, Command.finish, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · have same := input_start_unique actualStart started
    subst actual
    exact ⟨keys, List.all_eq_true.mp allowed⟩

theorem log_event_timestamp_fixed (session entry now : Term) :
    TimestampFixed (logEvent session entry now) := by
  intro later
  simp +decide [Command.timestampLifecycle, logEvent, compact_lookup, List.find?_cons]

theorem log_timestamp_fixed {state entry checkpoint result : Term} {journal rest batch : List Term}
    (call : Command.start state (.tuple [a "log", entry, checkpoint]) journal = .ok (result, rest))
    (started : InputStart result batch false) : ∀ event ∈ batch, TimestampFixed event := by
  rcases log_generated call with invalid | ⟨session, now, before, _, committed⟩
  · rw [invalid] at started
    simp [InputStart, Command.finish, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · apply commit_input_timestamp_fixed (call := committed) (started := started)
    intro event member
    have same := List.mem_singleton.mp member
    subst event
    exact log_event_timestamp_fixed _ _ _

end VerifiedKernel.Session.WorkConservation
