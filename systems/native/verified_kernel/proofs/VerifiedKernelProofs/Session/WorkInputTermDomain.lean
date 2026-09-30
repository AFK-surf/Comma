import VerifiedKernelProofs.Session.WorkInputTermBatch

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem stringifyFuel_named_absent {fields : List (String × Term)} {key : String}
    {value : Term} {fuel : Nat} {j r : List Term}
    (different : ∀ pair ∈ fields, pair.1 ≠ key)
    (h : stringifyFuel fuel (.map (fields.map (fun pair => (b pair.1, pair.2)))) j =
      .ok (value, r)) : value.get (b key) = nil := by
  cases fuel with
  | zero => exact (fail_ok h).elim
  | succ fuel =>
    unfold stringifyFuel at h
    change enumFold _ empty (stringifyFieldStep fuel) j = .ok (value, r) at h
    exact (stringify_named_fold_frame different (enumFold_named_map h)).trans rfl

theorem stringify_compact_absent {fields : List (String × Term)} {key : String}
    {value : Term} {j r : List Term}
    (different : ∀ pair ∈ fields, pair.1 ≠ key)
    (h : stringify (Command.compact fields) j = .ok (value, r)) : value.get (b key) = nil := by
  unfold stringify at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  exact stringifyFuel_named_absent
    (fun pair member => different pair (List.mem_filter.mp member).1) h

theorem inputEvent_nil_fields {session payload now event : Term} {j r : List Term}
    (h : Command.inputEvent session nil payload now j = .ok (event, r)) :
    event.get (b "type") = b "queue_append" ∧ event.get (b "kind") = b "user_message" ∧
    event.get (b "dedupe_key") = nil ∧ event.get (b "source_message_id") = nil ∧
    ∃ fields : List (String × Term),
      event.get (b "payload") = Command.compact fields ∧
      ∀ pair ∈ fields, pair.1 ≠ "source_message_id" := by
  unfold Command.inputEvent at h
  repeat obtain ⟨_, _, _, h⟩ := bind_ok h
  have eventEq := pure_ok h
  subst event
  have drop (fields : List (String × Term)) :
      Command.compact (("source_message_id", nil) :: fields) = Command.compact fields := rfl
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  all_goals simp +decide [compact_lookup, compact_not_nil, drop]
  all_goals try rfl
  refine ⟨_, rfl, ?_⟩
  intro name value member
  simp only [List.mem_cons, List.mem_singleton, Prod.mk.injEq] at member
  rcases member with ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ |
    ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ <;> simp_all

theorem nil_input_not_appended {s t session payload now event : Term} {j r before after : List Term}
    (generated : Command.inputEvent session nil payload now before = .ok (event, after))
    (call : queueAppend s event j = .ok (t, r)) : False := by
  obtain ⟨_, kind, dedupe, outerSource, fields, body, different⟩ := inputEvent_nil_fields generated
  unfold queueAppend at call
  split at call
  · obtain ⟨_, _, failed, _⟩ := bind_ok call
    exact (fail_ok failed).elim
  · obtain ⟨unit, _, validated, call⟩ := bind_ok call
    cases unit
    rw [kind] at validated
    obtain ⟨normalized, keys, first, middle, last, normalizedRead, keysRead, nonempty⟩ :=
      validateQueue_identity_read validated
    rw [body] at normalizedRead
    change stringify (Command.compact fields) first = .ok (normalized, middle) at normalizedRead
    have innerSource := stringify_compact_absent different normalizedRead
    unfold queueKeys at keysRead
    obtain ⟨firstKey, _, firstRead, keysRead⟩ := bind_ok keysRead
    have firstEq := (access_ok firstRead).1.trans dedupe
    subst firstKey
    obtain ⟨secondKey, _, secondRead, keysRead⟩ := bind_ok keysRead
    have secondEq := (access_ok secondRead).1.trans outerSource
    subst secondKey
    obtain ⟨thirdKey, _, thirdRead, keysRead⟩ := bind_ok keysRead
    have thirdEq := (access_ok thirdRead).1.trans innerSource
    subst thirdKey
    have emptyKeys : keys = [] := pure_ok keysRead
    exact nonempty emptyKeys

theorem appended_input_nonnull {s t session payload now event source : Term} {j r before after : List Term}
    (generated : Command.inputEvent session source payload now before = .ok (event, after))
    (call : queueAppend s event j = .ok (t, r)) : (source == nil) = false := by
  cases isNil : source == nil with
  | false => rfl
  | true =>
    have same := atom_beq_true isNil
    rw [same] at generated
    exact (nil_input_not_appended generated call).elim

theorem resident_main_input_nonnull {s t payload now event source : Term} {j r observations : List Term}
    (generated : Command.inputEvent (s.get (a "session_id")) source payload now j = .ok (event, r))
    (execution : ResidentTrace (runTrusted s event observations) (.tuple [a "done", t])) :
    (source == nil) = false := by
  cases isNil : source == nil with
  | false => rfl
  | true =>
    have sameSource := atom_beq_true isNil
    rw [sameSource] at generated
    obtain ⟨reduced, normalized, before, after, prepared, activity⟩ := resident_execution_step execution
    cases normalized with
    | none => exact (prepareTrusted_canonical_not_skipped (inputEvent_binary_keys generated)
        (inputEvent_term_session generated) prepared).elim
    | some normalized =>
      obtain ⟨innerBefore, read, innerAfter, call⟩ := prepareTrusted_stringify prepared
      have same := shallowStringify_binary_keys (inputEvent_binary_keys generated) read
      subst normalized
      have kind := (inputEvent_nil_fields generated).1
      have append : queueAppend s event innerBefore = .ok (reduced, innerAfter) := by
        simpa +decide [inner, kind] using call
      exact (nil_input_not_appended generated append).elim

theorem resident_input_batch_nonnull {s t payload now event source : Term} {earlier j r : List Term}
    (generated : Command.inputEvent (s.get (a "session_id")) source payload now j = .ok (event, r))
    (execution : ResidentBatch s (earlier ++ [event]) t) : (source == nil) = false := by
  obtain ⟨middle, before, after⟩ := resident_batch_append execution
  cases after with
  | cons head tail =>
    have sid := resident_batch_session before
    have atMain : Command.inputEvent (middle.get (a "session_id")) source payload now j =
        .ok (event, r) := by rw [sid]; exact generated
    exact resident_main_input_nonnull atMain head

end VerifiedKernel.Session.WorkConservation
