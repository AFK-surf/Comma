import VerifiedKernelProofs.Session.WorkReceiptInvariant

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem fork_receipt_origin {messages : List Term} {ledger key : Term} {journal rest : List Term}
    (call : Fork.forkDedupe messages journal = .ok (ledger, rest))
    (present : IdentityPresent ledger key) :
    ∃ message ∈ messages, ∃ field ∈ forkIdentityFields, (message.get field == key) = true := by
  unfold Fork.forkDedupe at call
  obtain ⟨keys, _, collected, call⟩ := bind_ok call
  rw [pure_ok call] at present
  change ((uniq (keys.filter (!missing ·))).map (fun inserted => (inserted, list []))).any
    (fun pair => pair.1 == key) = true at present
  obtain ⟨pair, included, same⟩ := List.any_eq_true.mp present
  obtain ⟨inserted, member, rfl⟩ := List.mem_map.mp included
  have original := (List.mem_filter.mp (uniq_receipt_subset _ inserted member)).1
  obtain ⟨message, included, field, allowed, identity⟩ :=
    (fork_identity_fold_origin collected original).resolve_left (by simp)
  exact ⟨message, included, field, allowed, identity ▸ same⟩

end VerifiedKernel.Session.WorkConservation
