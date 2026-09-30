import VerifiedKernelProofs.Session.WorkLedgerRuntime

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 1000000
set_option Elab.async false

theorem transcriptLog_ledger_absent {s e t key : Term} {j r : List Term}
    (absent : IdentityAbsent (s.get (a "input_dedupe")) key)
    (different : ∀ inserted ∈ [e.get (b "source_message_id"), e.get (b "dedupe_key")].filter (!missing ·),
      (inserted == key) = false)
    (h : transcriptLog s e j = .ok (t, r)) : IdentityAbsent (t.get (a "input_dedupe")) key := by
  unfold transcriptLog at h
  obtain ⟨source, _, sourceRead, h⟩ := bind_ok h
  have sourceEq := (access_ok sourceRead).1
  subst source
  obtain ⟨dedupeKey, _, dedupeKeyRead, h⟩ := bind_ok h
  have dedupeKeyEq := (access_ok dedupeKeyRead).1
  subst dedupeKey
  obtain ⟨ledger, _, ledgerRead, h⟩ := bind_ok h
  have ledgerEq := field_value ledgerRead
  subst ledger
  obtain ⟨hit, _, _, h⟩ := bind_ok h
  split at h
  · rw [pure_ok h]; exact absent
  · repeat'
      fail_if_success (bind_head_is h [addDedupe]; change (addDedupe _ _ >>= _) _ = _ at h)
      first
        | (obtain ⟨_, _, _, h⟩ := bind_ok h)
        | split at h
        | dsimp only at h
    all_goals
      obtain ⟨dedupe, _, dedupeRead, h⟩ := bind_ok h
      have kept := addDedupe_preserves_absence absent different dedupeRead
      obtain ⟨updated, _, written, h⟩ := bind_ok h
      have finalFrame := bumpHwm_ledger_frame h
      obtain ⟨_, written⟩ := write_cons written
      rw [finalFrame, pure_ok written, get_put_same]
      exact kept

theorem transcriptLog_checked_ledger_absent {s e t : Term} {key : ByteArray} {groups : List (List Term)}
    {j r before after : List Term}
    (kind : e.get (b "type") = b "session_log_message")
    (checked : Command.inputIdentityGroups e before = .ok (groups, after))
    (different : ∀ inserted ∈ groups.flatten, (inserted == .binary key) = false)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) (.binary key))
    (h : transcriptLog s e j = .ok (t, r)) : IdentityAbsent (t.get (a "input_dedupe")) (.binary key) := by
  unfold Command.inputIdentityGroups at checked
  simp +decide only [kind] at checked
  have groupsEq := pure_ok checked
  subst groups
  apply transcriptLog_ledger_absent absent ?_ h
  apply uniq_avoids_binary
  intro inserted member
  exact different inserted (by simpa using member)

theorem deliveryDedupe_ledger_absent {ledger id key next : Term} {j r : List Term}
    (absent : IdentityAbsent ledger key)
    (different : (id == nil) = false → (id == key) = false)
    (h : deliveryDedupe ledger id j = .ok (next, r)) : IdentityAbsent next key := by
  unfold deliveryDedupe at h
  cases missing : id == nil
  · simp only [missing, Bool.false_eq_true, ↓reduceIte] at h
    exact setPut_preserves_absence absent (different missing) h
  · simp only [missing, ↓reduceIte] at h
    rw [pure_ok h]; exact absent

theorem transcriptDelivery_ledger_absent {s e t key : Term} {j r : List Term}
    (absent : IdentityAbsent (s.get (a "input_dedupe")) key)
    (different : ∀ inserted ∈ [e.get (b "source_message_id"), e.get (b "dedupe_key")].filter (· != nil),
      (inserted == key) = false)
    (h : transcriptDelivery s e j = .ok (t, r)) : IdentityAbsent (t.get (a "input_dedupe")) key := by
  unfold transcriptDelivery at h
  split at h
  · rw [pure_ok h]; exact absent
  · obtain ⟨source, _, sourceRead, h⟩ := bind_ok h
    have sourceEq := (access_ok sourceRead).1
    subst source
    obtain ⟨dedupeKey, _, dedupeKeyRead, h⟩ := bind_ok h
    have dedupeKeyEq := (access_ok dedupeKeyRead).1
    subst dedupeKey
    repeat'
      fail_if_success (bind_field_is h "input_dedupe"; change (field s "input_dedupe" >>= _) _ = _ at h)
      first
        | (obtain ⟨_, _, _, h⟩ := bind_ok h)
        | split at h
        | (generalize e.get (b "billing_context") = context at h; split at h)
        | dsimp only at h
    all_goals
      obtain ⟨ledger, _, ledgerRead, h⟩ := bind_ok h
      have ledgerEq := field_value ledgerRead
      subst ledger
      obtain ⟨first, _, firstRead, h⟩ := bind_ok h
      have firstKept := deliveryDedupe_ledger_absent absent (fun missing =>
        different _ (List.mem_filter.mpr ⟨List.mem_cons_self, by simp only [bne, missing, Bool.not_false]⟩)) firstRead
      obtain ⟨dedupe, _, dedupeRead, h⟩ := bind_ok h
      have kept := deliveryDedupe_ledger_absent firstKept (fun missing =>
        different _ (List.mem_filter.mpr ⟨List.mem_cons_of_mem _ List.mem_cons_self,
          by simp only [bne, missing, Bool.not_false]⟩)) dedupeRead
      repeat'
        fail_if_success (bind_head_is h [write]; change (write _ _ >>= _) _ = _ at h)
        first
          | (obtain ⟨_, _, _, h⟩ := bind_ok h)
          | split at h
          | dsimp only at h
      all_goals
        obtain ⟨updated, _, written, h⟩ := bind_ok h
        have finalFrame : LedgerFrame updated t := by ledger_frame_walk h
        obtain ⟨_, written⟩ := write_cons written
        obtain ⟨_, written⟩ := write_cons written
        have writtenFrame := write_field_frame (key := "input_dedupe") written rfl
        rw [finalFrame, writtenFrame, get_put_same]
        exact kept

theorem transcriptDelivery_checked_ledger_absent {s e t : Term} {key : ByteArray} {groups : List (List Term)}
    {j r before after : List Term}
    (kind : e.get (b "type") = b "delivery")
    (checked : Command.inputIdentityGroups e before = .ok (groups, after))
    (different : ∀ inserted ∈ groups.flatten, (inserted == .binary key) = false)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) (.binary key))
    (h : transcriptDelivery s e j = .ok (t, r)) : IdentityAbsent (t.get (a "input_dedupe")) (.binary key) := by
  unfold Command.inputIdentityGroups at checked
  simp +decide only [kind] at checked
  cases queued : e.get (b "from_queue") == a "true"
  · have same : t = s := by
      have result : (t, r) = (s, j) := by
        simpa only [transcriptDelivery, bne, queued, Bool.not_false, ↓reduceIte, pure_ok_iff] using h
      exact (Prod.mk.inj result).1
    rw [same]; exact absent
  · simp only [bne, queued, Bool.not_true, Bool.false_eq_true, ↓reduceIte] at checked
    have groupsEq := pure_ok checked
    subst groups
    apply transcriptDelivery_ledger_absent absent ?_ h
    apply uniq_avoids_binary
    intro inserted member
    exact different inserted (by simpa only [List.flatten_cons, List.flatten_nil, List.append_nil, bne] using member)

end VerifiedKernel.Session.WorkConservation
