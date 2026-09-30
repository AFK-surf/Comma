import VerifiedKernelProofs.Session.WorkLedgerOrigins
import VerifiedKernel.Session.Fork

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

def forkIdentityFields : List Term :=
  [a "source_message_id", b "source_message_id", a "dedupe_key", b "dedupe_key",
    a "runtime_message_id", b "runtime_message_id"]

def forkIdentityStep (acc : List Term) (message : Term) : KernelM (List Term) := do
  if !message.isMap then return acc
  return acc ++ [← access message (a "source_message_id"), ← access message (b "source_message_id"),
    ← access message (a "dedupe_key"), ← access message (b "dedupe_key"),
    ← access message (a "runtime_message_id"), ← access message (b "runtime_message_id")]

theorem fork_identity_step_origin {acc keys : List Term} {message key : Term} {journal rest : List Term}
    (call : forkIdentityStep acc message journal = .ok (keys, rest)) (member : key ∈ keys) :
    key ∈ acc ∨ ∃ field ∈ forkIdentityFields, message.get field = key := by
  unfold forkIdentityStep at call
  split at call
  · rw [pure_ok call] at member
    exact Or.inl member
  · obtain ⟨one, _, readOne, call⟩ := bind_ok call
    obtain ⟨two, _, readTwo, call⟩ := bind_ok call
    obtain ⟨three, _, readThree, call⟩ := bind_ok call
    obtain ⟨four, _, readFour, call⟩ := bind_ok call
    obtain ⟨five, _, readFive, call⟩ := bind_ok call
    obtain ⟨six, _, readSix, call⟩ := bind_ok call
    rw [pure_ok call] at member
    rcases List.mem_append.mp member with old | added
    · exact Or.inl old
    · right
      simp only [List.mem_cons, List.not_mem_nil, or_false] at added
      rcases added with rfl | rfl | rfl | rfl | rfl | rfl
      · exact ⟨a "source_message_id", by simp [forkIdentityFields], (access_ok readOne).1.symm⟩
      · exact ⟨b "source_message_id", by simp [forkIdentityFields], (access_ok readTwo).1.symm⟩
      · exact ⟨a "dedupe_key", by simp [forkIdentityFields], (access_ok readThree).1.symm⟩
      · exact ⟨b "dedupe_key", by simp [forkIdentityFields], (access_ok readFour).1.symm⟩
      · exact ⟨a "runtime_message_id", by simp [forkIdentityFields], (access_ok readFive).1.symm⟩
      · exact ⟨b "runtime_message_id", by simp [forkIdentityFields], (access_ok readSix).1.symm⟩

theorem fork_identity_fold_origin {messages acc keys : List Term} {key : Term} {journal rest : List Term}
    (call : messages.foldlM forkIdentityStep acc journal = .ok (keys, rest)) (member : key ∈ keys) :
    key ∈ acc ∨ ∃ message ∈ messages, ∃ field ∈ forkIdentityFields, message.get field = key := by
  induction messages generalizing acc journal with
  | nil => rw [pure_ok call] at member; exact Or.inl member
  | cons message messages ih =>
    rw [List.foldlM_cons] at call
    obtain ⟨next, _, head, tail⟩ := bind_ok call
    rcases ih tail with previous | ⟨source, included, field, allowed, found⟩
    · rcases fork_identity_step_origin head previous with original | ⟨field, allowed, found⟩
      · exact Or.inl original
      · exact Or.inr ⟨message, List.mem_cons_self, field, allowed, found⟩
    · exact Or.inr ⟨source, List.mem_cons_of_mem _ included, field, allowed, found⟩

/-- A fork copies identity evidence only from records that the actual fork supplied to its ledger builder. -/
theorem fork_dedupe_origin {messages : List Term} {ledger : Term} {source : ByteArray} {journal rest : List Term}
    (call : Fork.forkDedupe messages journal = .ok (ledger, rest))
    (present : IdentityPresent ledger (.binary source)) :
    ∃ message ∈ messages, ∃ field ∈ forkIdentityFields, message.get field = .binary source := by
  unfold Fork.forkDedupe at call
  obtain ⟨keys, _, collected, call⟩ := bind_ok call
  rw [pure_ok call] at present
  change ((uniq (keys.filter (!missing ·))).map (fun key => (key, list []))).any
    (fun pair => pair.1 == .binary source) = true at present
  obtain ⟨pair, included, same⟩ := List.any_eq_true.mp present
  obtain ⟨key, keyMember, rfl⟩ := List.mem_map.mp included
  have equal := beq_binary_right same
  dsimp only at equal
  subst key
  have original := (List.mem_filter.mp ((uniq_binary_member _ source).mp keyMember)).1
  exact (fork_identity_fold_origin collected original).resolve_left (by simp)

end VerifiedKernel.Session.WorkConservation
