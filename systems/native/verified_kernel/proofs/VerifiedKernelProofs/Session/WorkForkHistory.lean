import VerifiedKernelProofs.Session.WorkForkNumbers

namespace VerifiedKernel.Session.WorkConservation
open Data ReloadSequence
set_option Elab.async false
set_option maxRecDepth 4096
set_option maxHeartbeats 1000000

theorem normalize_fork_history {entries : List (String × Term)} {messages facts results journal rest : List Term}
    {next : Term} {n : Int}
    (messageRead : entries.reverse.find? (fun pair => pair.1 == "messages") = some ("messages", list messages))
    (factRead : entries.reverse.find? (fun pair => pair.1 == "events") = some ("events", list facts))
    (resultRead : entries.reverse.find? (fun pair => pair.1 == "async_results") = some ("async_results", list results))
    (lastRead : entries.reverse.find? (fun pair => pair.1 == "last_seq") = some ("last_seq", i n))
    (messageStamps : ForkStamps (a "seq") messages n)
    (factStamps : ForkStamps (b "seq") facts n) (resultStamps : ForkStamps (b "seq") results n)
    (call : Lifecycle.normalize (Lifecycle.build entries) journal = .ok (next, rest)) :
    SeqSorted next ∧ HistoryNumbers next := by
  have last : lastSeq (Lifecycle.build entries) = i n := by rw [lastSeq, build_value lastRead, default_integer]
  have sorted : SeqSorted (Lifecycle.build entries) :=
    ⟨messages, n, build_value messageRead, last, messageStamps.1, messageStamps.2⟩
  have numeric {records : List Term} {key : Term} (stamps : ForkStamps key records n) : NumericRecords (list records) key := by
    refine ⟨records, rfl, ?_⟩
    intro record member
    obtain ⟨value, read, _⟩ := stamps.1 record member
    exact ⟨value, by rw [read, default_integer]⟩
  have numbers : HistoryNumbers (Lifecycle.build entries) := by
    unfold HistoryNumbers
    rw [build_value messageRead, build_value factRead, build_value resultRead]
    exact ⟨numeric messageStamps, numeric factStamps, numeric resultStamps, n, last⟩
  exact normalize_sequence numbers sorted call

theorem rebuild_refs_history {state next : Term} {journal rest : List Term}
    (history : SeqSorted state ∧ HistoryNumbers state)
    (call : rebuildRefs state journal = .ok (next, rest)) : SeqSorted next ∧ HistoryNumbers next := by
  unfold rebuildRefs at call
  repeat
    fail_if_success (head_is call [write]; change write _ _ _ = .ok (next, rest) at call)
    obtain ⟨_, _, _, call⟩ := bind_ok call
  have messages := write_field_frame (key := "messages") call rfl
  have facts := write_field_frame (key := "events") call rfl
  have results := write_field_frame (key := "async_results") call rfl
  have last := write_field_frame (key := "last_seq") call rfl
  simpa only [SeqSorted, HistoryNumbers, lastSeq, messages, facts, results, last] using history

theorem fork_finish_history {source session attrs next : Term} {copy : Bool}
    {messages facts results remapped clamped journal rest : List Term} {n : Int}
    {lastAck forkThrough nextId created : Term}
    (messageStamps : ForkStamps (a "seq") messages n)
    (factStamps : ForkStamps (b "seq") facts n) (resultStamps : ForkStamps (b "seq") results n)
    (call : forkFinish source session attrs copy messages facts results remapped clamped
      (i n) lastAck forkThrough nextId created journal = .ok (next, rest)) : SeqSorted next ∧ HistoryNumbers next := by
  cases copy <;> unfold forkFinish at call <;> simp only [Bool.false_eq_true, ↓reduceIte] at call
  all_goals repeat
    fail_if_success (bind_head_is call [Lifecycle.normalize]; change (Lifecycle.normalize _ >>= _) _ = .ok (next, rest) at call)
    obtain ⟨_, _, _, call⟩ := bind_ok call
  all_goals
    obtain ⟨child, _, normalized, call⟩ := bind_ok call
    exact rebuild_refs_history
      (normalize_fork_history rfl rfl rfl rfl messageStamps factStamps resultStamps normalized) call

theorem current_fork_history {source session attrs maxId next : Term} {journal rest : List Term}
    (call : Fork.currentFork source session attrs maxId journal = .ok (next, rest)) : SeqSorted next ∧ HistoryNumbers next := by
  rw [current_fork_factor] at call
  unfold forkSelection at call
  repeat'
    fail_if_success (bind_head_is call [Fork.renumber]; change (Fork.renumber _ >>= _) _ = .ok (next, rest) at call)
    first
      | (obtain ⟨_, _, _, call⟩ := bind_ok call)
      | dsimp only at call
      | split at call
  all_goals
    obtain ⟨numbered, _, renumbered, call⟩ := bind_ok call
    obtain ⟨messages, facts, results, remap, last⟩ := numbered
    obtain ⟨n, lastEq, messageStamps, factStamps, resultStamps⟩ := fork_renumber_numbers renumbered
    change last = i n at lastEq
    subst last
    dsimp only at call
    obtain ⟨remapped, _, remappedCall, call⟩ := bind_ok call
    have stamps := remap_runtime_stamps messageStamps remappedCall
    repeat' first
      | exact fork_finish_history stamps factStamps resultStamps call
      | (obtain ⟨_, _, _, call⟩ := bind_ok call)
      | split at call
      | dsimp only at call

theorem modern_fork_history {source args next : Term} {journal rest : List Term}
    (format : source.get (a "storage_format") = i 3)
    (call : Fork.fork source args journal = .ok (.tuple [a "ok", next], rest)) : SeqSorted next ∧ HistoryNumbers next := by
  unfold Fork.fork at call
  split at call
  · obtain ⟨maxId, _, _, call⟩ := bind_ok call
    obtain ⟨stored, _, storedRead, call⟩ := bind_ok call
    have storedEq := (field_value storedRead).trans format
    subst stored
    simp only [show ((i 3).isInteger && decide (integerValue (i 3) ≥ 2)) = true from rfl, ↓reduceIte] at call
    obtain ⟨compacted, _, _, call⟩ := bind_ok call
    obtain ⟨below, _, _, call⟩ := bind_ok call
    rcases ite_ok_iff.mp call with ⟨_, rejected⟩ | ⟨_, accepted⟩
    · have impossible := pure_ok rejected
      simp [a] at impossible
    · obtain ⟨child, _, forked, returned⟩ := bind_ok accepted
      have equal : next = child := by
        simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using pure_ok returned
      rw [equal]
      exact current_fork_history forked
  · exact (fail_ok call).elim

end VerifiedKernel.Session.WorkConservation
