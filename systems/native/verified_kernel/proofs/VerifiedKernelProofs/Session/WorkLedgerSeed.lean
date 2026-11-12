import VerifiedKernelProofs.Session.WorkLedgerTranscript

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 1000000
set_option Elab.async false

def seedIdentityKeys (raw : Term) : KernelM (List Term) := do
  seedKeys (← stringify raw)

def seedLedgerStep (event : Term) (acc : List Term × Term × Term × Bool × Term) (raw : Term) :
    KernelM (List Term × Term × Term × Bool × Term) := do
  let (messages, next, seen, any, seq) := acc
  let entry ← stringify raw
  let keys ← seedKeys entry
  if ← dedupeHit seen keys then return (messages, next, seen, any, seq)
  let unstamped ← seedMessage event entry next
  let sequence ← add seq (i 1)
  let message := unstamped.put (a "seq") sequence
  return (message :: messages, ← add next (i 1), ← addDedupe seen keys, true, sequence)

theorem seedLedgerStep_absent {e raw key : Term} {initial final : List Term × Term × Term × Bool × Term}
    {j r : List Term}
    (absent : IdentityAbsent initial.2.2.1 key)
    (avoids : ∀ entry keys before middle after,
      stringify raw before = .ok (entry, middle) → seedKeys entry middle = .ok (keys, after) →
      ∀ inserted ∈ keys, (inserted == key) = false)
    (h : seedLedgerStep e initial raw j = .ok (final, r)) : IdentityAbsent final.2.2.1 key := by
  obtain ⟨messages, next, ledger, any, seq⟩ := initial
  unfold seedLedgerStep at h
  obtain ⟨entry, _, entryRead, h⟩ := bind_ok h
  obtain ⟨keys, _, keysRead, h⟩ := bind_ok h
  have different := avoids entry keys _ _ _ entryRead keysRead
  obtain ⟨hit, _, _, h⟩ := bind_ok h
  split at h
  · rw [pure_ok h]; exact absent
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨dedupe, _, dedupeRead, h⟩ := bind_ok h
    rw [pure_ok h]
    exact addDedupe_preserves_absence absent different dedupeRead

theorem seedLedgerFold_absent {items : List Term} {e key : Term}
    {initial final : List Term × Term × Term × Bool × Term} {checked : List (List Term)}
    {j r before after : List Term}
    (absent : IdentityAbsent initial.2.2.1 key)
    (different : ∀ inserted ∈ checked.flatten, (inserted == key) = false)
    (guard : items.mapM seedIdentityKeys before = .ok (checked, after))
    (h : items.foldlM (seedLedgerStep e) initial j = .ok (final, r)) : IdentityAbsent final.2.2.1 key := by
  induction items generalizing initial checked j before after with
  | nil => rw [pure_ok h]; exact absent
  | cons raw items ih =>
    rw [List.mapM_cons] at guard
    rw [List.foldlM_cons] at h
    obtain ⟨keys, _, headGuard, guard⟩ := bind_ok guard
    obtain ⟨rest, _, tailGuard, guard⟩ := bind_ok guard
    rw [pure_ok guard] at different
    unfold seedIdentityKeys at headGuard
    obtain ⟨entry, _, entryRead, keysRead⟩ := bind_ok headGuard
    obtain ⟨next, _, head, tail⟩ := bind_ok h
    apply ih ?_ ?_ tailGuard tail
    · apply seedLedgerStep_absent absent ?_ head
      intro other otherKeys first middle last otherEntry otherRead inserted member
      have same := stringify_same_results entryRead otherEntry
      subst other
      have same := deterministic_seedKeys entry _ _ _ _ _ _ keysRead otherRead
      subst otherKeys
      exact different inserted (by simpa only [List.flatten_cons] using List.mem_append_left rest.flatten member)
    · intro inserted member
      exact different inserted (by simpa only [List.flatten_cons] using List.mem_append_right keys member)

theorem transcriptSeed_checked_ledger_absent {s e t key : Term} {groups : List (List Term)}
    {j r before after : List Term}
    (kind : e.get (b "type") = b "transcript_seed")
    (checked : Command.inputIdentityGroups e before = .ok (groups, after))
    (different : ∀ inserted ∈ groups.flatten, (inserted == key) = false)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) key)
    (h : transcriptSeed s e j = .ok (t, r)) : IdentityAbsent (t.get (a "input_dedupe")) key := by
  unfold Command.inputIdentityGroups StorageDelta.identityGroups at checked
  simp +decide only [kind] at checked
  obtain ⟨items, _, itemsRead, checked⟩ := bind_ok checked
  have inputList := (asList_ok_iff.mp itemsRead).1
  change items.mapM seedIdentityKeys _ = .ok (groups, after) at checked
  unfold transcriptSeed at h
  obtain ⟨input, _, inputRead, h⟩ := bind_ok h
  have inputEq := (access_ok inputRead).1
  subst input
  obtain ⟨next, _, _, h⟩ := bind_ok h
  obtain ⟨ledger, _, ledgerRead, h⟩ := bind_ok h
  have ledgerEq := field_value ledgerRead
  subst ledger
  obtain ⟨seq, _, _, h⟩ := bind_ok h
  obtain ⟨result, _, folded, h⟩ := bind_ok h
  change enumFold _ _ (seedLedgerStep e) _ = .ok (result, _) at folded
  rw [inputList] at folded
  obtain ⟨actual, ledgerFold, sameItems⟩ := enumFold_ok folded
  simp only [sameItems items rfl] at ledgerFold
  have initialAbsent : IdentityAbsent
      ((s.get (a "input_dedupe")).default (.map [(a "__struct__", a "Elixir.MapSet"), (a "map", empty)])) key := by
    unfold Term.default
    split
    · exact absent
    · rfl
  have kept := seedLedgerFold_absent initialAbsent different checked ledgerFold
  obtain ⟨appended, nextId, dedupe, any, lastSeq⟩ := result
  repeat'
    fail_if_success (bind_head_is h [write]; change (write _ _ >>= _) _ = _ at h)
    first
      | (obtain ⟨_, _, _, h⟩ := bind_ok h)
      | split at h
      | dsimp only at h
  all_goals
    obtain ⟨updated, _, written, h⟩ := bind_ok h
    have finalFrame : LedgerFrame updated t := by ledger_frame_walk h
    iterate 6 obtain ⟨_, written⟩ := write_cons written
    rw [finalFrame, pure_ok written, get_put_same]
    exact kept

end VerifiedKernel.Session.WorkConservation
