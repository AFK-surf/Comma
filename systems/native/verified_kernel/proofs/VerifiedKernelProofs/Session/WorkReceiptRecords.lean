import VerifiedKernelProofs.Session.WorkRecordLedgerFacts

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

/-- Receipt lookup uses the kernel's equality, including nonbinary keys. -/
def ReceiptMatches (key : Term) (fields : List Term) : Prop :=
  ∃ inserted ∈ fields, (inserted == key) = true

theorem fallback_receipt_subset (items seen : List Term) :
    ∀ key ∈ items.foldl fallbackIdentityStep seen, key ∈ seen ∨ key ∈ items := by
  induction items generalizing seen with
  | nil => exact fun _ member => Or.inl member
  | cons value items ih =>
    intro key member
    rcases ih _ key member with old | added
    · unfold fallbackIdentityStep at old
      split at old
      · exact Or.inl old
      · rcases List.mem_append.mp old with prior | equal
        · exact Or.inl prior
        · exact Or.inr (List.mem_cons.mpr (Or.inl (List.mem_singleton.mp equal)))
    · exact Or.inr (List.mem_cons_of_mem _ added)

theorem uniq_receipt_subset (items : List Term) : ∀ key ∈ uniq items, key ∈ items := by
  by_cases binary : items.all Term.isBinary = true
  · exact (uniq_binary_subset binary).subset
  · unfold uniq
    rw [if_neg binary]
    exact fun key member => (fallback_receipt_subset items [] key member).resolve_left (by simp)

theorem new_receipt_not_same {before after key : Term}
    (absent : IdentityAbsent (before.get (a "input_dedupe")) key)
    (present : IdentityPresent (after.get (a "input_dedupe")) key) : after ≠ before := by
  intro same
  subst after
  unfold IdentityAbsent at absent
  unfold IdentityPresent at present
  rw [absent] at present
  contradiction

theorem log_new_receipt_fact {state event next key : Term} {journal rest : List Term}
    (call : transcriptLog state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) key)
    (present : IdentityPresent (next.get (a "input_dedupe")) key) :
    ∃ record, RecordWitness event record ∧ ContainsRecord next record ∧
      ReceiptMatches key [record.get (a "source_message_id"), record.get (a "dedupe_key")] ∧
      LogFactFields event record := by
  rcases log_record_or_duplicate call with ⟨_, same⟩ | ⟨record, witness, stored, fields⟩
  · exact (new_receipt_not_same absent present same).elim
  · have origin := identity_origin_of_absence
      (fun before different => transcriptLog_ledger_absent before different call) present
    rcases origin with old | ⟨inserted, included, matched⟩
    · unfold IdentityAbsent at absent
      unfold IdentityPresent at old
      rw [absent] at old
      contradiction
    · refine ⟨record, witness, stored, ⟨inserted, ?_, matched⟩, fields⟩
      rw [fields.1, fields.2.1]
      exact (List.mem_filter.mp included).1

theorem delivery_new_receipt_fact {state event next key : Term} {journal rest : List Term}
    (call : transcriptDelivery state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) key)
    (present : IdentityPresent (next.get (a "input_dedupe")) key) :
    ∃ record, RecordWitness event record ∧ ContainsRecord next record ∧
      ReceiptMatches key [record.get (a "source_message_id"), record.get (a "dedupe_key")] ∧
      record.get (a "content") = event.get (b "content") ∧
      record.get (a "accepted_input") = event.get (b "accepted_input") := by
  have queued : event.get (b "from_queue") = a "true" := by
    cases same : (event.get (b "from_queue") == a "true") with
    | true => exact atom_beq_true same
    | false =>
      simp only [transcriptDelivery, bne, same, Bool.not_false, ↓reduceIte] at call
      exact (new_receipt_not_same absent present (pure_ok call)).elim
  obtain ⟨record, witness, stored, _, sourceField, aliasField, content, input, _⟩ := delivery_stores_fields queued call
  have origin := identity_origin_of_absence
    (fun before different => transcriptDelivery_ledger_absent before different call) present
  rcases origin with old | ⟨inserted, included, matched⟩
  · unfold IdentityAbsent at absent
    unfold IdentityPresent at old
    rw [absent] at old
    contradiction
  · refine ⟨record, witness, stored, ⟨inserted, ?_, matched⟩, content, input⟩
    rw [sourceField, aliasField]
    exact (List.mem_filter.mp included).1

theorem runtime_new_receipt_keys {state event next key : Term} {journal rest : List Term}
    (call : transcriptRuntime state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) key)
    (present : IdentityPresent (next.get (a "input_dedupe")) key) :
    ∃ keys before after, runtimeKeys event before = .ok (keys, after) ∧ ReceiptMatches key keys := by
  classical
  apply Classical.byContradiction
  intro missing
  have gone := transcriptRuntime_ledger_absent absent (by
    intro keys before after read inserted included
    cases same : (inserted == key) with
    | false => rfl
    | true => exact (missing ⟨keys, before, after, read, inserted, included, same⟩).elim) call
  unfold IdentityAbsent at gone
  unfold IdentityPresent at present
  rw [gone] at present
  contradiction

theorem runtime_new_receipt_record {state event next key : Term} {journal rest : List Term}
    (call : transcriptRuntime state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) key)
    (present : IdentityPresent (next.get (a "input_dedupe")) key) :
    ∃ record, RecordWitness event record ∧ ContainsRecord next record ∧ RuntimeIdentityFields event record := by
  have changed := new_receipt_not_same absent present
  unfold transcriptRuntime at call
  repeat' first
    | exact runtime_append_stores_identity call
    | exact (changed (pure_ok call)).elim
    | exact (fail_ok call).elim
    | unfold argumentError at call
    | split at call
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | dsimp only at call

end VerifiedKernel.Session.WorkConservation
