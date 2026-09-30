import VerifiedKernelProofs.Session.WorkLogFact

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem delivery_new_identity_fact {state event next : Term} {source : ByteArray} {journal rest : List Term}
    (call : transcriptDelivery state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) (.binary source))
    (present : IdentityPresent (next.get (a "input_dedupe")) (.binary source)) :
    ∃ record, RecordWitness event record ∧ ContainsRecord next record ∧
      (record.get (a "source_message_id") = .binary source ∨ record.get (a "dedupe_key") = .binary source) ∧
      record.get (a "content") = event.get (b "content") ∧
      record.get (a "accepted_input") = event.get (b "accepted_input") := by
  have queued : event.get (b "from_queue") = a "true" := by
    cases same : (event.get (b "from_queue") == a "true") with
    | true => exact atom_beq_true same
    | false =>
      simp only [transcriptDelivery, bne, same, Bool.not_false, ↓reduceIte] at call
      exact (new_identity_not_same absent present (pure_ok call)).elim
  obtain ⟨record, witness, stored, _, sourceField, aliasField, content, input, _⟩ := delivery_stores_fields queued call
  have origin := identity_origin_of_absence
    (fun before different => transcriptDelivery_ledger_absent before different call) present
  rcases origin with old | ⟨inserted, included, same⟩
  · unfold IdentityAbsent at absent
    unfold IdentityPresent at old
    rw [absent] at old
    contradiction
  · have equal := beq_binary_right same
    subst inserted
    have fields := (List.mem_filter.mp included).1
    simp only [List.mem_cons, List.not_mem_nil, or_false] at fields
    exact ⟨record, witness, stored, fields.elim
      (fun same => Or.inl (sourceField.trans same.symm))
      (fun same => Or.inr (aliasField.trans same.symm)), content, input⟩

theorem runtime_keys_binary_member {event : Term} {keys journal rest : List Term} {source : ByteArray}
    (call : runtimeKeys event journal = .ok (keys, rest)) (member : .binary source ∈ keys) :
    event.get (b "dedupe_key") = .binary source ∨ event.get (b "source_message_id") = .binary source ∨
      event.get (b "runtime_message_id") = .binary source := by
  unfold runtimeKeys at call
  obtain ⟨dedupe, _, dedupeRead, call⟩ := bind_ok call
  have dedupeEq := (access_ok dedupeRead).1
  subst dedupe
  obtain ⟨src, _, sourceRead, call⟩ := bind_ok call
  have sourceEq := (access_ok sourceRead).1
  subst src
  obtain ⟨runtime, _, runtimeRead, call⟩ := bind_ok call
  have runtimeEq := (access_ok runtimeRead).1
  subst runtime
  rw [pure_ok call] at member
  have fields := (List.mem_filter.mp ((uniq_binary_member _ source).mp member)).1
  simpa only [List.mem_cons, List.not_mem_nil, or_false, eq_comm] using fields

theorem runtime_new_identity_keys {state event next : Term} {source : ByteArray} {journal rest : List Term}
    (call : transcriptRuntime state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) (.binary source))
    (present : IdentityPresent (next.get (a "input_dedupe")) (.binary source)) :
    ∃ keys before after, runtimeKeys event before = .ok (keys, after) ∧ .binary source ∈ keys := by
  classical
  apply Classical.byContradiction
  intro missing
  have gone := transcriptRuntime_ledger_absent absent (by
    intro keys before after read inserted included
    cases same : (inserted == .binary source) with
    | false => rfl
    | true =>
      have equal := beq_binary_right same
      subst inserted
      exact (missing ⟨keys, before, after, read, included⟩).elim) call
  unfold IdentityAbsent at gone
  unfold IdentityPresent at present
  rw [gone] at present
  contradiction

theorem runtime_new_identity_record {state event next : Term} {source : ByteArray} {journal rest : List Term}
    (call : transcriptRuntime state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) (.binary source))
    (present : IdentityPresent (next.get (a "input_dedupe")) (.binary source)) :
    ∃ record, RecordWitness event record ∧ ContainsRecord next record ∧ RuntimeIdentityFields event record := by
  have changed := new_identity_not_same absent present
  unfold transcriptRuntime at call
  repeat' first
    | exact runtime_append_stores_identity call
    | exact (changed (pure_ok call)).elim
    | exact (fail_ok call).elim
    | unfold argumentError at call
    | split at call
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | dsimp only at call

/-- Runtime identities retain the actual alias, source, or runtime ID and the reducer's content fallback. -/
theorem runtime_new_identity_fact {state event next : Term} {source : ByteArray} {journal rest : List Term}
    (call : transcriptRuntime state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) (.binary source))
    (present : IdentityPresent (next.get (a "input_dedupe")) (.binary source)) :
    ∃ record, RecordWitness event record ∧ ContainsRecord next record ∧
      (record.get (a "dedupe_key") = .binary source ∨ record.get (a "source_message_id") = .binary source ∨
        record.get (a "runtime_message_id") = .binary source) ∧
      record.get (a "content") = (event.get (b "content")).default (event.get (b "summary")) ∧
      record.get (a "accepted_input") = event.get (b "accepted_input") := by
  obtain ⟨record, witness, stored, ⟨_, runtimeField, sourceField, content, input, _⟩, aliasField⟩ :=
    runtime_new_identity_record call absent present
  obtain ⟨keys, before, after, read, member⟩ := runtime_new_identity_keys call absent present
  refine ⟨record, witness, stored, ?_, content, input⟩
  rcases runtime_keys_binary_member read member with aliasEq | sourceEq | runtimeEq
  · exact Or.inl (aliasField.trans aliasEq)
  · exact Or.inr (Or.inl (sourceField.trans sourceEq))
  · exact Or.inr (Or.inr (runtimeField.trans runtimeEq))

end VerifiedKernel.Session.WorkConservation
