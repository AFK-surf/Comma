import VerifiedKernelProofs.Session.WorkLedgerFacts
import VerifiedKernelProofs.Session.WorkRecordFields

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

def LogFactFields (event record : Term) : Prop :=
  record.get (a "source_message_id") = event.get (b "source_message_id") ∧
  record.get (a "dedupe_key") = event.get (b "dedupe_key") ∧
  record.get (a "content") = event.get (b "content")

theorem dedupeHit_present {ledger : Term} {keys journal rest : List Term}
    (call : dedupeHit ledger keys journal = .ok (true, rest)) :
    ∃ key ∈ keys, IdentityPresent ledger key := by
  induction keys generalizing journal with
  | nil => have impossible := pure_ok call; cases impossible
  | cons key keys ih =>
    unfold dedupeHit at call
    obtain ⟨found, _, read, call⟩ := bind_ok call
    cases found with
    | true => exact ⟨key, List.mem_cons_self, (setMember_value read).symm⟩
    | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at call
      obtain ⟨key, member, present⟩ := ih call
      exact ⟨key, List.mem_cons_of_mem _ member, present⟩

theorem log_record_or_duplicate {state event next : Term} {journal rest : List Term}
    (call : transcriptLog state event journal = .ok (next, rest)) :
    ((∃ key ∈ [event.get (b "source_message_id"), event.get (b "dedupe_key")].filter (!missing ·),
      IdentityPresent (state.get (a "input_dedupe")) key) ∧ next = state) ∨
    ∃ record, RecordWitness event record ∧ ContainsRecord next record ∧ LogFactFields event record := by
  unfold transcriptLog at call
  obtain ⟨src, _, sourceRead, call⟩ := bind_ok call
  have sourceEq := (access_ok sourceRead).1
  subst src
  obtain ⟨key, _, keyRead, call⟩ := bind_ok call
  have keyEq := (access_ok keyRead).1
  subst key
  obtain ⟨ledger, _, ledgerRead, call⟩ := bind_ok call
  have ledgerEq := field_value ledgerRead
  subst ledger
  obtain ⟨hit, _, hitRead, call⟩ := bind_ok call
  split at call
  · rename_i found
    have hitEq : hit = true := by simpa using found
    subst hit
    exact Or.inl ⟨dedupeHit_present hitRead, pure_ok call⟩
  · apply Or.inr
    repeat'
      fail_if_success (bind_head_is call [appendFields]; change (appendFields _ _ _ >>= _) _ = .ok (next, rest) at call)
      first
        | (obtain ⟨value, _, read, call⟩ := bind_ok call
           try (have same := (access_ok read).1; subst value))
        | split at call
        | dsimp only at call
    all_goals
      obtain ⟨appended, _, appendCall, call⟩ := bind_ok call
      obtain ⟨messages, seq, before, written⟩ := appendFields_stores appendCall
      refine ⟨_, ⟨state, appended, _, _, _, seq, appendCall, ⟨messages, before, written⟩, rfl⟩, ?_, ?_⟩
      · exact record_survives (by transcript_walk call)
          ⟨messages ++ [_], written, List.mem_append_right _ (by simp)⟩
      · refine ⟨?_, ?_, ?_⟩
        all_goals
          rw [get_put_other _ _ (by decide)]
          rw [merge_present_frame (trace_fields_keys (by assumption)) (by decide) (by assumption)]
          rw [present_lookup]
          simp +decide [List.find?_cons, atom_beq]
          split
          · rfl
          · rename_i missing
            exact (bne_nil_false missing).symm

theorem log_new_identity_record {state event next : Term} {source : ByteArray} {journal rest : List Term}
    (call : transcriptLog state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) (.binary source))
    (present : IdentityPresent (next.get (a "input_dedupe")) (.binary source)) :
    ∃ record, RecordWitness event record ∧ ContainsRecord next record ∧ LogFactFields event record := by
  rcases log_record_or_duplicate call with ⟨_, same⟩ | stored
  · exact (new_identity_not_same absent present same).elim
  · exact stored

/-- A new log identity names an actual stored log record with the same source or alias and content. -/
theorem log_new_identity_fact {state event next : Term} {source : ByteArray} {journal rest : List Term}
    (call : transcriptLog state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) (.binary source))
    (present : IdentityPresent (next.get (a "input_dedupe")) (.binary source)) :
    ∃ record, RecordWitness event record ∧ ContainsRecord next record ∧
      (record.get (a "source_message_id") = .binary source ∨ record.get (a "dedupe_key") = .binary source) ∧
      record.get (a "content") = event.get (b "content") := by
  obtain ⟨record, witness, stored, sourceField, aliasField, content⟩ := log_new_identity_record call absent present
  have origin := identity_origin_of_absence
    (fun before different => transcriptLog_ledger_absent before different call) present
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
      (fun same => Or.inr (aliasField.trans same.symm)), content⟩

end VerifiedKernel.Session.WorkConservation
