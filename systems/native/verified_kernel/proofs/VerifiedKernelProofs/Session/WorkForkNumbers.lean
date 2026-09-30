import VerifiedKernelProofs.Session.WorkInitialIdentity

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

def ForkStamps (key : Term) (records : List Term) (limit : Int) : Prop :=
  (∀ record ∈ records, ∃ n : Int, record.get key = i n ∧ n ≤ limit) ∧
    records.Pairwise (fun left right => integerValue (left.get key) ≤ integerValue (right.get key))

theorem ForkStamps.weaken {key : Term} {records : List Term} {limit next : Int}
    (stamped : ForkStamps key records limit) (bound : limit ≤ next) : ForkStamps key records next := by
  refine ⟨?_, stamped.2⟩
  intro record member
  obtain ⟨n, read, small⟩ := stamped.1 record member
  exact ⟨n, read, Int.le_trans small bound⟩

theorem ForkStamps.append {key record : Term} {records : List Term} {limit : Int}
    (stamped : ForkStamps key records limit) (read : record.get key = i (limit + 1)) :
    ForkStamps key (records ++ [record]) (limit + 1) := by
  constructor
  · intro value member
    rcases List.mem_append.mp member with old | new
    · exact (stamped.weaken (by omega)).1 value old
    · have equal : value = record := by simpa using new
      subst value
      exact ⟨limit + 1, read, by omega⟩
  · rw [List.pairwise_append]
    refine ⟨stamped.2, by simp, ?_⟩
    intro before beforeMember after afterMember
    have equal : after = record := by simpa using afterMember
    subst after
    obtain ⟨n, stamp, small⟩ := stamped.1 before beforeMember
    rw [stamp, read]
    change n ≤ limit + 1
    omega

abbrev ForkAccumulator := List Term × List Term × List Term × Term × Term

def forkNumberStep (acc : ForkAccumulator) (item : Term) : KernelM ForkAccumulator := do
  let (messages, facts, results, remap, n) := acc
  let .tuple [kind, original, record] := item | fail "invalid_term"
  let seq ← add n (i 1)
  let remap ← put remap original seq
  if kind == a "message" then
    return (messages ++ [← put record (a "seq") seq], facts, results, remap, seq)
  else if kind == a "fact" then
    return (messages, facts ++ [← put record (b "seq") seq], results, remap, seq)
  else
    return (messages, facts, results ++ [← put record (b "seq") seq], remap, seq)

theorem fork_number_factor (items : List Term) :
    Fork.renumber items = items.foldlM forkNumberStep ([], [], [], empty, i 0) := rfl

def ForkNumbered (acc : ForkAccumulator) : Prop :=
  ∃ n : Int, acc.2.2.2.2 = i n ∧ ForkStamps (a "seq") acc.1 n ∧
    ForkStamps (b "seq") acc.2.1 n ∧ ForkStamps (b "seq") acc.2.2.1 n

theorem fork_number_step {acc next : ForkAccumulator} {item : Term} {journal rest : List Term}
    (numbered : ForkNumbered acc) (call : forkNumberStep acc item journal = .ok (next, rest)) : ForkNumbered next := by
  obtain ⟨messages, facts, results, remap, last⟩ := acc
  obtain ⟨n, lastEq, messageStamps, factStamps, resultStamps⟩ := numbered
  change last = i n at lastEq
  subst last
  unfold forkNumberStep at call
  dsimp only at call
  split at call
  · obtain ⟨seq, _, added, call⟩ := bind_ok call
    rw [add_integer] at added
    have seqEq := (Prod.mk.inj (Except.ok.inj added)).1
    subst seq
    obtain ⟨mapped, _, _, call⟩ := bind_ok call
    split at call
    · obtain ⟨record, _, stamped, call⟩ := bind_ok call
      rw [pure_ok call]
      refine ⟨n + 1, rfl, messageStamps.append ?_, factStamps.weaken (by omega), resultStamps.weaken (by omega)⟩
      rw [put_ok stamped]
      exact get_put_same _ _ _
    · split at call
      · obtain ⟨record, _, stamped, call⟩ := bind_ok call
        rw [pure_ok call]
        refine ⟨n + 1, rfl, messageStamps.weaken (by omega), factStamps.append ?_, resultStamps.weaken (by omega)⟩
        rw [put_ok stamped]
        exact get_put_binary_same _ _ _
      · obtain ⟨record, _, stamped, call⟩ := bind_ok call
        rw [pure_ok call]
        refine ⟨n + 1, rfl, messageStamps.weaken (by omega), factStamps.weaken (by omega), resultStamps.append ?_⟩
        rw [put_ok stamped]
        exact get_put_binary_same _ _ _
  · exact (fail_ok call).elim

theorem fork_number_fold {items : List Term} {acc next : ForkAccumulator} {journal rest : List Term}
    (numbered : ForkNumbered acc) (call : items.foldlM forkNumberStep acc journal = .ok (next, rest)) : ForkNumbered next := by
  induction items generalizing acc journal with
  | nil => rw [pure_ok call]; exact numbered
  | cons item items ih =>
    rw [List.foldlM_cons] at call
    obtain ⟨middle, _, head, tail⟩ := bind_ok call
    exact ih (fork_number_step numbered head) tail

theorem fork_renumber_numbers {items : List Term} {next : ForkAccumulator} {journal rest : List Term}
    (call : Fork.renumber items journal = .ok (next, rest)) : ForkNumbered next := by
  rw [fork_number_factor] at call
  exact fork_number_fold ⟨0, rfl, by simp [ForkStamps], by simp [ForkStamps], by simp [ForkStamps]⟩ call

theorem remove_atom_field_frame {state next key : Term} {name : String} {journal rest : List Term}
    (different : (a name == key) = false)
    (call : remove state key journal = .ok (next, rest)) : next.get (a name) = state.get (a name) := by
  unfold remove at call
  split at call
  · rw [pure_ok call]
    simp only [Term.get]
    rw [find?_filter_of_imp]
    intro entry hit
    rw [atom_beq_true hit]
    simp [bne, different]
  · exact (fail_ok call).elim

theorem remap_runtime_seq_frame {message remap next : Term} {journal rest : List Term}
    (call : Fork.remapRuntimeSeq message remap journal = .ok (next, rest)) :
    next.get (a "seq") = message.get (a "seq") := by
  unfold Fork.remapRuntimeSeq at call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  split at call
  · split at call
    · rw [put_ok call]; exact get_put_other _ _ (by decide)
    · exact remove_atom_field_frame rfl call
  · obtain ⟨_, _, _, call⟩ := bind_ok call
    split at call
    · split at call
      · rw [put_ok call]; exact get_put_binary_atom _ _ _ _
      · exact remove_atom_field_frame rfl call
    · rw [pure_ok call]

theorem mapM_field_projection {f : Term → KernelM Term} {key : Term} {before after journal rest : List Term}
    (frame : ∀ state next journal rest, f state journal = .ok (next, rest) → next.get key = state.get key)
    (call : before.mapM f journal = .ok (after, rest)) : after.map (fun item => item.get key) = before.map (fun item => item.get key) := by
  induction before generalizing after journal rest with
  | nil => rw [pure_ok call]; rfl
  | cons item items ih =>
    rw [List.mapM_cons] at call
    obtain ⟨next, _, head, call⟩ := bind_ok call
    obtain ⟨tail, _, tailCall, call⟩ := bind_ok call
    rw [pure_ok call]
    simp only [List.map_cons, frame _ _ _ _ head, ih tailCall]

theorem remap_runtime_stamps {messages next journal rest : List Term} {remap : Term} {limit : Int}
    (stamps : ForkStamps (a "seq") messages limit)
    (call : messages.mapM (fun message => Fork.remapRuntimeSeq message remap) journal = .ok (next, rest)) :
    ForkStamps (a "seq") next limit := by
  have same := mapM_field_projection (key := a "seq") (fun _ _ _ _ read => remap_runtime_seq_frame read) call
  constructor
  · intro record member
    obtain ⟨original, included, before, after, read⟩ := mapM_outputs call record member
    obtain ⟨n, stamp, bounded⟩ := stamps.1 original included
    exact ⟨n, (remap_runtime_seq_frame read).trans stamp, bounded⟩
  · have ordered : (messages.map (fun record => integerValue (record.get (a "seq")))).Pairwise (· ≤ ·) :=
      List.pairwise_map.mpr stamps.2
    have numeric := congrArg (List.map integerValue) same
    simp only [List.map_map, Function.comp_def] at numeric
    rw [← numeric] at ordered
    exact List.pairwise_map.mp ordered

end VerifiedKernel.Session.WorkConservation
