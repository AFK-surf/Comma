import VerifiedKernelProofs.Session.WorkLedgerWriters

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 1000000
set_option Elab.async false

theorem runtimeAppend_ledger_absent {s e t key : Term} {j r : List Term}
    (absent : IdentityAbsent (s.get (a "input_dedupe")) key)
    (avoids : ∀ keys before after, runtimeKeys e before = .ok (keys, after) →
      ∀ inserted ∈ keys, (inserted == key) = false)
    (h : runtimeAppend s e j = .ok (t, r)) : IdentityAbsent (t.get (a "input_dedupe")) key := by
  unfold runtimeAppend at h
  obtain ⟨keys, _, keysRead, h⟩ := bind_ok h
  have different := avoids keys _ _ keysRead
  repeat'
    fail_if_success (bind_field_is h "input_dedupe"; change (field s "input_dedupe" >>= _) _ = _ at h)
    first
      | (obtain ⟨_, _, _, h⟩ := bind_ok h)
      | split at h
      | dsimp only at h
  all_goals
    obtain ⟨ledger, _, ledgerRead, h⟩ := bind_ok h
    have ledgerEq := field_value ledgerRead
    subst ledger
    obtain ⟨dedupe, _, dedupeRead, h⟩ := bind_ok h
    have kept := addDedupe_preserves_absence absent different dedupeRead
    try split at h
    all_goals
      obtain ⟨_, _, _, h⟩ := bind_ok h
      obtain ⟨updated, _, written, h⟩ := bind_ok h
      have finalFrame : LedgerFrame updated t := by ledger_frame_walk h
      obtain ⟨_, written⟩ := write_cons written
      have writtenFrame := write_field_frame (key := "input_dedupe") written rfl
      rw [finalFrame, writtenFrame, get_put_same]
      exact kept

theorem transcriptRuntime_ledger_absent {s e t key : Term} {j r : List Term}
    (absent : IdentityAbsent (s.get (a "input_dedupe")) key)
    (avoids : ∀ keys before after, runtimeKeys e before = .ok (keys, after) →
      ∀ inserted ∈ keys, (inserted == key) = false)
    (h : transcriptRuntime s e j = .ok (t, r)) : IdentityAbsent (t.get (a "input_dedupe")) key := by
  unfold transcriptRuntime at h
  repeat' first
    | exact runtimeAppend_ledger_absent absent avoids h
    | (rw [pure_ok h]; exact absent)
    | exact (fail_ok h).elim
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)
    | split at h
    | dsimp only at h

theorem transcriptRuntime_checked_ledger_absent {s e t key : Term} {groups : List (List Term)}
    {j r before after : List Term}
    (kind : e.get (b "type") = b "runtime_message")
    (checked : Command.inputIdentityGroups e before = .ok (groups, after))
    (different : ∀ inserted ∈ groups.flatten, (inserted == key) = false)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) key)
    (h : transcriptRuntime s e j = .ok (t, r)) : IdentityAbsent (t.get (a "input_dedupe")) key := by
  unfold Command.inputIdentityGroups at checked
  simp +decide only [kind] at checked
  cases queued : e.get (b "from_queue") == a "true" <;>
    cases provider : e.get (b "from_context_provider") == a "true"
  all_goals simp only [bne, queued, provider, Bool.not_true, Bool.not_false, Bool.false_and,
    Bool.true_and, Bool.false_eq_true, ↓reduceIte] at checked
  · have same : t = s := by
      have result : (t, r) = (s, j) := by
        simpa only [transcriptRuntime, bne, queued, provider, Bool.not_false, Bool.true_and,
          ↓reduceIte, pure_ok_iff] using h
      exact (Prod.mk.inj result).1
    rw [same]; exact absent
  all_goals
    obtain ⟨keys, _, keysRead, checked⟩ := bind_ok checked
    have groupsEq := pure_ok checked
    subst groups
    apply transcriptRuntime_ledger_absent absent ?_ h
    intro other first last otherRead
    have same := deterministic_runtimeKeys e _ _ _ _ _ _ keysRead otherRead
    subst other
    intro inserted member
    exact different inserted (by simpa using member)

end VerifiedKernel.Session.WorkConservation
