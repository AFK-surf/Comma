import VerifiedKernelProofs.Session.WorkLedger
import VerifiedKernelProofs.Session.WorkLedgerFrames
import VerifiedKernelProofs.Session.WorkMaterializeRouting

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 4000000
set_option Elab.async false

theorem queueAppend_ledger_absent {s e t key : Term} {j r : List Term}
    (absent : IdentityAbsent (s.get (a "input_dedupe")) key)
    (avoids : ∀ payload keys before middle after,
      stringify ((e.get (b "payload")).default empty) before = .ok (payload, middle) →
      queueKeys e payload (e.get (b "kind")) middle = .ok (keys, after) →
      ∀ inserted ∈ keys, (inserted == key) = false)
    (h : queueAppend s e j = .ok (t, r)) : IdentityAbsent (t.get (a "input_dedupe")) key := by
  unfold queueAppend at h
  split at h
  · obtain ⟨_, _, failed, _⟩ := bind_ok h
    exact (fail_ok failed).elim
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨raw, _, rawRead, h⟩ := bind_ok h
    have rawEq := (access_ok rawRead).1
    subst raw
    obtain ⟨payload, _, payloadRead, h⟩ := bind_ok h
    obtain ⟨keys, _, keysRead, h⟩ := bind_ok h
    have different := avoids payload keys _ _ _ payloadRead keysRead
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨ledger, _, ledgerRead, h⟩ := bind_ok h
    have ledgerEq := field_value ledgerRead
    subst ledger
    obtain ⟨hit, _, _, h⟩ := bind_ok h
    split at h
    · rw [pure_ok h]; exact absent
    · repeat
        (fail_if_success (bind_head_is h [addDedupe]; change (addDedupe _ _ >>= _) _ = _ at h)
         obtain ⟨_, _, _, h⟩ := bind_ok h)
      obtain ⟨dedupe, _, dedupeRead, h⟩ := bind_ok h
      have kept := addDedupe_preserves_absence absent different dedupeRead
      obtain ⟨_, _, _, h⟩ := bind_ok h
      obtain ⟨_, _, _, h⟩ := bind_ok h
      obtain ⟨_, h⟩ := write_cons h
      obtain ⟨_, h⟩ := write_cons h
      obtain ⟨_, h⟩ := write_cons h
      have frame := write_field_frame (key := "input_dedupe") h rfl
      rw [frame, get_put_same]
      exact kept

theorem queueAppend_checked_ledger_absent {s e t key : Term} {groups : List (List Term)}
    {j r before after : List Term}
    (kind : (e.get (b "type") == b "queue_append") = true)
    (checked : Command.inputIdentityGroups e before = .ok (groups, after))
    (different : ∀ inserted ∈ groups.flatten, (inserted == key) = false)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) key)
    (h : queueAppend s e j = .ok (t, r)) : IdentityAbsent (t.get (a "input_dedupe")) key := by
  unfold Command.inputIdentityGroups at checked
  simp only [kind, ↓reduceIte] at checked
  obtain ⟨payload, _, payloadRead, checked⟩ := bind_ok checked
  obtain ⟨keys, _, keysRead, checked⟩ := bind_ok checked
  have groupsEq := pure_ok checked
  subst groups
  apply queueAppend_ledger_absent absent ?_ h
  intro other otherKeys first middle last otherPayload otherRead
  have same := stringify_same_results payloadRead otherPayload
  subst other
  have same := deterministic_queueKeys e payload (e.get (b "kind")) _ _ _ _ _ _ keysRead otherRead
  subst otherKeys
  intro inserted member
  exact different inserted (by simpa using member)

end VerifiedKernel.Session.WorkConservation
