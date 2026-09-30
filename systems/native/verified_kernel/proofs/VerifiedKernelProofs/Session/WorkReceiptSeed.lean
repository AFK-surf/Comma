import VerifiedKernelProofs.Session.WorkReceiptQueue
import VerifiedKernelProofs.Session.WorkSeedFact

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

/-- The source belongs to the same decoded seed entry that generated this record. -/
def SeedReceiptSource (event raw : Term) (source : Term) (record : Term) : Prop :=
  ∃ entry keys unstamped id seq before middle after messageBefore messageAfter,
    stringify raw before = .ok (entry, middle) ∧ seedKeys entry middle = .ok (keys, after) ∧
    ReceiptMatches source keys ∧ seedMessage event entry id messageBefore = .ok (unstamped, messageAfter) ∧
    record = unstamped.put (a "seq") seq

theorem seed_step_new_receipt_record {event raw : Term} {source : Term}
    {initial final : List Term × Term × Term × Bool × Term} {journal rest : List Term}
    (call : seedLedgerStep event initial raw journal = .ok (final, rest))
    (absent : IdentityAbsent initial.2.2.1 (source))
    (present : IdentityPresent final.2.2.1 (source)) :
    ∃ record ∈ final.1, SeedReceiptSource event raw source record := by
  obtain ⟨messages, next, ledger, any, seq⟩ := initial
  unfold seedLedgerStep at call
  obtain ⟨entry, _, entryRead, call⟩ := bind_ok call
  obtain ⟨keys, _, keysRead, call⟩ := bind_ok call
  obtain ⟨hit, _, _, call⟩ := bind_ok call
  split at call
  · rw [pure_ok call] at present
    change (ledger.get (a "map")).has (source) = true at present
    change (ledger.get (a "map")).has (source) = false at absent
    rw [absent] at present
    contradiction
  · obtain ⟨unstamped, _, messageRead, call⟩ := bind_ok call
    obtain ⟨sequence, _, _, call⟩ := bind_ok call
    obtain ⟨nextId, _, _, call⟩ := bind_ok call
    obtain ⟨dedupe, _, dedupeRead, call⟩ := bind_ok call
    rw [pure_ok call] at present ⊢
    rcases addDedupe_origin dedupeRead present with old | ⟨inserted, included, same⟩
    · change (ledger.get (a "map")).has (source) = true at old
      change (ledger.get (a "map")).has (source) = false at absent
      rw [absent] at old
      contradiction
    · exact ⟨unstamped.put (a "seq") sequence, List.mem_cons_self,
        entry, keys, unstamped, next, sequence, _, _, _, _, _, entryRead, keysRead, ⟨inserted, included, same⟩, messageRead, rfl⟩

theorem seed_fold_receipt_records {event : Term} {source : Term} {items : List Term}
    {initial final : List Term × Term × Term × Bool × Term} {journal rest : List Term}
    (call : items.foldlM (seedLedgerStep event) initial journal = .ok (final, rest))
    (present : IdentityPresent final.2.2.1 (source)) :
    IdentityPresent initial.2.2.1 (source) ∨
      ∃ raw ∈ items, ∃ record ∈ final.1, SeedReceiptSource event raw source record := by
  induction items generalizing initial journal with
  | nil => rw [pure_ok call] at present; exact Or.inl present
  | cons raw items ih =>
    rw [List.foldlM_cons] at call
    obtain ⟨next, _, head, tail⟩ := bind_ok call
    rcases ih tail with prior | ⟨original, included, record, stored, fact⟩
    · rcases identity_present_or_absent initial.2.2.1 (source) with old | absent
      · exact Or.inl old
      · obtain ⟨record, stored, fact⟩ := seed_step_new_receipt_record head absent prior
        exact Or.inr ⟨raw, List.mem_cons_self, record, seed_fold_keeps_records tail record stored, fact⟩
    · exact Or.inr ⟨original, List.mem_cons_of_mem _ included, record, stored, fact⟩

theorem seed_new_receipt_fact {state event next : Term} {source : Term} {journal rest : List Term}
    (call : transcriptSeed state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) (source))
    (present : IdentityPresent (next.get (a "input_dedupe")) (source)) :
    ∃ items raw record,
      enumeratedItems ((event.get (b "entries")).default (list [])) = some items ∧
      raw ∈ items ∧ ContainsRecord next record ∧ SeedReceiptSource event raw source record := by
  unfold transcriptSeed at call
  obtain ⟨input, _, inputRead, call⟩ := bind_ok call
  have inputEq := (access_ok inputRead).1
  subst input
  obtain ⟨nextId, _, _, call⟩ := bind_ok call
  obtain ⟨ledger, _, ledgerRead, call⟩ := bind_ok call
  have ledgerEq := field_value ledgerRead
  subst ledger
  obtain ⟨seq, _, _, call⟩ := bind_ok call
  obtain ⟨result, _, folded, call⟩ := bind_ok call
  change enumFold _ _ (seedLedgerStep event) _ = .ok (result, _) at folded
  obtain ⟨items, enumerated, folded⟩ := enumFold_actual_items folded
  obtain ⟨appended, finalId, dedupe, any, lastSeq⟩ := result
  obtain ⟨oldMessages, _, _, call⟩ := bind_ok call
  obtain ⟨messages, _, appendedRead, call⟩ := bind_ok call
  obtain ⟨prior, suffix, _, suffixEq, messagesEq, _⟩ := append_ok_iff.mp appendedRead
  have suffixSame := Term.list.inj suffixEq
  subst suffix
  subst messages
  repeat'
    fail_if_success (bind_head_is call [write]; change (write _ _ >>= _) _ = _ at call)
    first
      | (obtain ⟨_, _, _, call⟩ := bind_ok call)
      | split at call
      | dsimp only at call
  all_goals
    obtain ⟨updated, _, written, call⟩ := bind_ok call
    have finalLedger : LedgerFrame updated next := by ledger_frame_walk call
    have finalMessages : TranscriptExtends updated next := by transcript_walk call
    have ledgerWritten := written
    iterate 6 obtain ⟨_, ledgerWritten⟩ := write_cons ledgerWritten
    rw [finalLedger, pure_ok ledgerWritten, get_put_same] at present
    have initialAbsent : IdentityAbsent
        ((state.get (a "input_dedupe")).default (.map [(a "__struct__", a "Elixir.MapSet"), (a "map", empty)]))
        (source) := by
      unfold Term.default
      split
      · exact absent
      · rfl
    rcases seed_fold_receipt_records folded present with old | ⟨raw, included, record, stored, fact⟩
    · change IdentityPresent _ (source) at old
      unfold IdentityPresent at old
      unfold IdentityAbsent at initialAbsent
      rw [initialAbsent] at old
      contradiction
    · refine ⟨items, raw, record, enumerated, included, ?_, fact⟩
      apply record_survives finalMessages
      exact ⟨prior ++ appended.reverse, write_get written rfl,
        List.mem_append_right _ (List.mem_reverse.mpr stored)⟩

end VerifiedKernel.Session.WorkConservation
