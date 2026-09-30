import VerifiedKernelProofs.Session.WorkPendingInput

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

def TimestampFixed (event : Term) : Prop := ∀ now, Command.timestampLifecycle event now = event

theorem timestampLifecycle_fixed (event : Term) (now : Int) :
    TimestampFixed (Command.timestampLifecycle event now) := by
  intro later
  unfold Command.timestampLifecycle
  split
  · simp only [get_put_binary_same, i, Term.isInteger, Bool.not_true, Bool.and_false,
      Bool.false_eq_true, ↓reduceIte]
  · rename_i stable
    simp only [stable, ↓reduceIte]

theorem queue_event_timestamp_fixed {event : Term}
    (kind : event.get (b "type") = b "queue_append") : TimestampFixed event := by
  intro now
  simp +decide [Command.timestampLifecycle, kind]

theorem preInputEvent_timestamp_fixed (session payload : Term) :
    TimestampFixed (Command.preInputEvent session payload) := by
  apply queue_event_timestamp_fixed
  simp +decide [Command.preInputEvent, compact_lookup, List.find?_cons]

theorem inputEvent_timestamp_fixed {session source payload now event : Term} {j r : List Term}
    (h : Command.inputEvent session source payload now j = .ok (event, r)) : TimestampFixed event := by
  unfold Command.inputEvent at h
  repeat obtain ⟨_, _, _, h⟩ := bind_ok h
  rw [pure_ok h]
  apply queue_event_timestamp_fixed
  simp +decide [compact_lookup, List.find?_cons]

theorem inputEvents_timestamp_fixed {entry : Term} {events j r : List Term}
    (h : Command.inputEvents entry j = .ok (events, r)) : ∀ event ∈ events, TimestampFixed event := by
  unfold Command.inputEvents at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  rw [pure_ok h]
  intro event member
  obtain ⟨original, _, same⟩ := List.mem_map.mp member
  subst event
  exact timestampLifecycle_fixed _ _

theorem input_generated_timestamp_fixed {s args result : Term} {j r : List Term}
    (h : Command.input s args j = .ok (result, r)) :
    result = Command.duplicateInput ∨
    result = Command.finish (.tuple [a "error", a "saturated"]) ∨
    ∃ entry trailing before,
      (∀ event ∈ trailing, TimestampFixed event) ∧
      Command.commitInput s entry trailing true before = .ok (result, r) := by
  unfold Command.input at h
  split at h
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    split at h
    · exact Or.inl (pure_ok h)
    · exact Or.inr (Or.inl (pure_ok h))
    · obtain ⟨session, _, _, h⟩ := bind_ok h
      obtain ⟨time, _, _, h⟩ := bind_ok h
      obtain ⟨attrs, _, _, h⟩ := bind_ok h
      obtain ⟨event, _, eventRead, h⟩ := bind_ok h
      refine Or.inr (Or.inr ⟨_, _, _, ?_, h⟩)
      intro current member
      simp only [List.mem_append, List.mem_singleton] at member
      rcases member with (created | pre) | main
      · split at created
        · have same : current = Command.timestampLifecycle
              ((attrs.put (b "type") (b "session_created")).put (b "session_id") session)
              (integerValue (i (integerValue time / 1000))) := by simpa using created
          rw [same]
          exact timestampLifecycle_fixed _ _
        · simp at created
      · obtain ⟨payload, _, same⟩ := List.mem_map.mp pre
        subst current
        exact preInputEvent_timestamp_fixed _ _
      · subst current
        exact inputEvent_timestamp_fixed eventRead
  · exact (fail_ok h).elim

theorem commit_input_timestamp_fixed {state entry result : Term} {trailing batch journal rest : List Term}
    {notifyInput : Bool}
    (fixed : ∀ event ∈ trailing, TimestampFixed event)
    (call : Command.commitInput state entry trailing notifyInput journal = .ok (result, rest))
    (started : InputStart result batch notifyInput) : ∀ event ∈ batch, TimestampFixed event := by
  unfold Command.commitInput at call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨events, _, read, call⟩ := bind_ok call
  split at call
  · rw [pure_ok call] at started
    simp [InputStart, Command.finish, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · obtain ⟨distinct, _, _, call⟩ := bind_ok call
    cases distinct with
    | false =>
      rw [pure_ok call] at started
      simp [InputStart, Command.finish, Command.writeInput, Command.perform, a, b, list, Term.text] at started
    | true =>
      let workspace := fun event : Term => [b "vfs_write", b "vfs_delete", b "vfs_copy"].contains (event.get (b "type"))
      let actual := events.filter (fun event => !workspace event) ++ trailing
      have actualFixed : ∀ event ∈ actual, TimestampFixed event := by
        intro event member
        rcases List.mem_append.mp member with embedded | generated
        · exact inputEvents_timestamp_fixed read event (List.mem_filter.mp embedded).1
        · exact fixed event generated
      have actualStart : InputStart result actual notifyInput := by
        simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at call
        split at call
        · exact Or.inl (pure_ok call)
        · repeat' first
            | (exact (fail_ok call).elim)
            | (have same := pure_ok call; exact Or.inr ⟨_, _, _, _, same⟩)
            | split at call
            | (obtain ⟨_, _, _, call⟩ := bind_ok call)
            | dsimp only at call
      have same := input_start_unique actualStart started
      rw [← same]
      exact actualFixed

theorem input_timestamp_fixed {state args result : Term} {batch journal rest : List Term}
    (input : Command.input state args journal = .ok (result, rest))
    (started : InputStart result batch) : ∀ event ∈ batch, TimestampFixed event := by
  rcases input_generated_timestamp_fixed input with duplicate | saturated | ⟨entry, trailing, before, fixed, call⟩
  · rw [duplicate] at started
    simp [InputStart, Command.duplicateInput, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · rw [saturated] at started
    simp [InputStart, Command.finish, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · exact commit_input_timestamp_fixed fixed call started

theorem input_timestamp_batch_unchanged {state args result : Term} {batch journal rest : List Term} (now : Int)
    (input : Command.input state args journal = .ok (result, rest))
    (started : InputStart result batch) : batch.map (fun event => Command.timestampLifecycle event now) = batch := by
  calc
    batch.map (fun event => Command.timestampLifecycle event now) = batch.map id :=
      List.map_eq_map_iff.mpr (fun event member => input_timestamp_fixed input started event member now)
    _ = batch := List.map_id batch

theorem fixed_lifecycle_created_integer {event : Term} (fixed : TimestampFixed event)
    (kind : [b "session_created", b "status", b "activity_status", b "wait_set", b "wait_clear"].contains
      (event.get (b "type")) = true) : (event.get (b "created_at")).isInteger = true := by
  cases number : (event.get (b "created_at")).isInteger with
  | true => rfl
  | false =>
    have same := fixed 0
    simp only [Command.timestampLifecycle, kind, number, Bool.not_false, Bool.and_self, ↓reduceIte] at same
    have field := congrArg (fun value => value.get (b "created_at")) same
    rw [get_put_binary_same] at field
    rw [← field] at number
    cases number

theorem timestamped_input_write_executes {cursor final : PendingRevision.Cursor}
    {args result hwm : Term} {batch journal rest : List Term} (now : Int)
    (input : Command.input cursor.working args journal = .ok (result, rest))
    (started : InputStart result batch)
    (execution : PendingRevision.Execution
      (PendingRevision.resident (some cursor.pack) (a "write")
        (.tuple [list (batch.map (fun event => Command.timestampLifecycle event now)), hwm])) final) :
    PendingRevision.Execution
      (PendingRevision.resident (some cursor.pack) (a "write") (.tuple [list batch, hwm])) final := by
  rw [input_timestamp_batch_unchanged now input started] at execution
  exact execution

end VerifiedKernel.Session.WorkConservation
