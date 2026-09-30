import VerifiedKernelProofs.Session.WorkCanonical

namespace VerifiedKernel.Session.WorkConservation
open Data

theorem compact_binary_keys (pairs : List (String × Term)) : BinaryKeys (Command.compact pairs) := by
  simp [Command.compact, BinaryKeys, List.all_map, b, Term.text, Term.isBinary]

theorem inputEvent_binary_keys {session source payload now event : Term} {j r : List Term}
    (h : Command.inputEvent session source payload now j = .ok (event, r)) : BinaryKeys event := by
  unfold Command.inputEvent at h
  repeat obtain ⟨_, _, _, h⟩ := bind_ok h
  rw [pure_ok h]
  exact compact_binary_keys _

theorem preInputEvent_binary_keys (session payload : Term) :
    BinaryKeys (Command.preInputEvent session payload) := compact_binary_keys _

theorem initialAttrs_binary_keys {payload attrs : Term} {j r : List Term}
    (h : Command.initialAttrs payload j = .ok (attrs, r)) : BinaryKeys attrs := by
  unfold Command.initialAttrs at h
  repeat obtain ⟨_, _, _, h⟩ := bind_ok h
  rw [pure_ok h]
  exact compact_binary_keys _

/-- The public input command constructs canonical trailing events before calling admission. -/
theorem input_generated_keys {s args result : Term} {j r : List Term}
    (h : Command.input s args j = .ok (result, r)) :
    result = Command.duplicateInput ∨
    result = Command.finish (.tuple [a "error", a "saturated"]) ∨
    ∃ entry trailing before,
      (∀ event ∈ trailing, BinaryKeys event) ∧
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
      obtain ⟨attrs, _, attrsRead, h⟩ := bind_ok h
      obtain ⟨event, _, eventRead, h⟩ := bind_ok h
      refine Or.inr (Or.inr ⟨_, _, _, ?_, h⟩)
      intro current member
      simp only [List.mem_append, List.mem_singleton] at member
      rcases member with (created | pre) | main
      · split at created
        · have same : current = Command.timestampLifecycle
              ((attrs.put (b "type") (b "session_created")).put (b "session_id") session)
              (integerValue (i (integerValue time / 1000))) := by
            simpa using created
          rw [same]
          exact timestampLifecycle_binary_keys _
            (binary_keys_put _ _ _ (binary_keys_put _ _ _ (initialAttrs_binary_keys attrsRead)))
        · simp at created
      · obtain ⟨payload, _, same⟩ := List.mem_map.mp pre
        subst current
        exact preInputEvent_binary_keys _ _
      · subst current
        exact inputEvent_binary_keys eventRead
  · exact (fail_ok h).elim

/-- The pending write batch, optionally preceded by the separate workspace effect. -/
def InputStart (result : Term) (batch : List Term) (notifyInput : Bool := true) : Prop :=
  result = Command.writeInput (list batch) notifyInput ∨
  ∃ operation metadata workspace billing,
    result = Command.perform (.tuple [a "workspace", operation, metadata, workspace, billing])
      (.tuple [b "input_workspace", list batch, Term.bool notifyInput])

theorem commit_input_start {s entry result : Term} {trailing j r : List Term} {notifyInput : Bool}
    (trailingKeys : ∀ event ∈ trailing, BinaryKeys event)
    (h : Command.commitInput s entry trailing notifyInput j = .ok (result, r)) :
    result = Command.finish (.tuple [a "error", a "invalid_delivery_events"]) ∨
    ∃ batch, InputStart result batch notifyInput ∧ (∀ event ∈ batch, BinaryKeys event) ∧
      batch.all Command.inputEventAllowed = true := by
  unfold Command.commitInput at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨events, _, read, h⟩ := bind_ok h
  split at h
  · exact Or.inl (pure_ok h)
  · rename_i allowed
    have admitted : (events ++ trailing).all Command.inputEventAllowed = true := by simpa using allowed
    have keys : ∀ event ∈ events ++ trailing, BinaryKeys event := by
      intro event member
      rcases List.mem_append.mp member with first | last
      · exact inputEvents_binary_keys read event first
      · exact trailingKeys event last
    obtain ⟨distinct, _, _, h⟩ := bind_ok h
    cases distinct with
    | false => exact Or.inl (pure_ok h)
    | true =>
      let workspace := fun event : Term => [b "vfs_write", b "vfs_delete", b "vfs_copy"].contains (event.get (b "type"))
      let batch := events.filter (fun event => !workspace event) ++ trailing
      have subset : ∀ event ∈ batch, event ∈ events ++ trailing := by
        intro event member
        rcases List.mem_append.mp member with first | last
        · exact List.mem_append_left _ (List.mem_filter.mp first).1
        · exact List.mem_append_right _ last
      have batchKeys := fun event member => keys event (subset event member)
      have batchAllowed : batch.all Command.inputEventAllowed = true :=
        List.all_eq_true.mpr (fun event member => List.all_eq_true.mp admitted event (subset event member))
      apply Or.inr
      refine ⟨batch, ?_, batchKeys, batchAllowed⟩
      simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h
      split at h
      · exact Or.inl (pure_ok h)
      · repeat' first
          | (exact (fail_ok h).elim)
          | (have same := pure_ok h; exact Or.inr ⟨_, _, _, _, same⟩)
          | split at h
          | (obtain ⟨_, _, _, h⟩ := bind_ok h)
          | dsimp only at h

/-- Admission and key normalization are consequences of the public input command. -/
theorem input_start {s args result : Term} {j r : List Term}
    (h : Command.input s args j = .ok (result, r)) :
    result = Command.duplicateInput ∨
    result = Command.finish (.tuple [a "error", a "saturated"]) ∨
    result = Command.finish (.tuple [a "error", a "invalid_delivery_events"]) ∨
    ∃ batch, InputStart result batch ∧ (∀ event ∈ batch, BinaryKeys event) ∧
      batch.all Command.inputEventAllowed = true := by
  rcases input_generated_keys h with duplicate | saturated | ⟨entry, trailing, before, keys, committed⟩
  · exact Or.inl duplicate
  · exact Or.inr (Or.inl saturated)
  · exact Or.inr (Or.inr (commit_input_start keys committed))

end VerifiedKernel.Session.WorkConservation
