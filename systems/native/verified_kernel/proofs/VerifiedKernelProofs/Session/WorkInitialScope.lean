import VerifiedKernelProofs.Session.WorkKernelHistory

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxRecDepth 4096
set_option maxHeartbeats 1000000

theorem normalize_built_scope {entries : List (String × Term)} {owner session : ByteArray}
    {next : Term} {journal rest : List Term}
    (owned : entries.reverse.find? (fun pair => pair.1 == "agent_id") = some ("agent_id", .binary owner))
    (identified : entries.reverse.find? (fun pair => pair.1 == "session_id") = some ("session_id", .binary session))
    (call : Lifecycle.normalize (Lifecycle.build entries) journal = .ok (next, rest)) :
    next.get (a "agent_id") = .binary owner ∧ next.get (a "session_id") = .binary session := by
  have ownerRead := build_value owned
  have sessionRead := build_value identified
  exact ⟨(normalize_owner (by rw [ownerRead]; intro impossible; cases impossible) call).trans ownerRead,
    (normalize_session_id (by rw [sessionRead]; intro impossible; cases impossible) call).trans sessionRead⟩

theorem create_scope {state attrs next : Term} {owner session : ByteArray} {journal rest : List Term}
    (call : Lifecycle.create state (.tuple [.binary owner, .binary session, attrs]) journal = .ok (next, rest)) :
    next.get (a "agent_id") = .binary owner ∧ next.get (a "session_id") = .binary session := by
  unfold Lifecycle.create at call
  dsimp only at call
  repeat
    fail_if_success (head_is call [Lifecycle.normalize]; change Lifecycle.normalize _ _ = .ok (next, rest) at call)
    obtain ⟨_, _, _, call⟩ := bind_ok call
  exact normalize_built_scope rfl rfl call

theorem rebuild_refs_scope {state next : Term} {journal rest : List Term}
    (call : rebuildRefs state journal = .ok (next, rest)) :
    next.get (a "agent_id") = state.get (a "agent_id") ∧
      next.get (a "session_id") = state.get (a "session_id") := by
  unfold rebuildRefs at call
  repeat
    fail_if_success (head_is call [write]; change write _ _ _ = .ok (next, rest) at call)
    obtain ⟨_, _, _, call⟩ := bind_ok call
  exact ⟨write_field_frame call rfl, write_field_frame call rfl⟩

theorem fork_finish_scope {source attrs next : Term} {owner session : ByteArray} {copy : Bool}
    {messages facts results remapped clamped journal rest : List Term}
    {lastSeq lastAck forkThrough nextId created : Term}
    (owned : source.get (a "agent_id") = .binary owner)
    (call : forkFinish source (.binary session) attrs copy messages facts results remapped clamped
      lastSeq lastAck forkThrough nextId created journal = .ok (next, rest)) :
    next.get (a "agent_id") = .binary owner ∧ next.get (a "session_id") = .binary session := by
  cases copy <;> unfold forkFinish at call <;> simp only [Bool.false_eq_true, ↓reduceIte] at call
  all_goals
    obtain ⟨agent, _, agentRead, call⟩ := bind_ok call
    have same := (field_value agentRead).trans owned
    subst agent
    repeat
      fail_if_success (bind_head_is call [Lifecycle.normalize]; change (Lifecycle.normalize _ >>= _) _ = .ok (next, rest) at call)
      obtain ⟨_, _, _, call⟩ := bind_ok call
    obtain ⟨child, _, normalized, call⟩ := bind_ok call
    have scope := normalize_built_scope rfl rfl normalized
    have frame := rebuild_refs_scope call
    exact ⟨frame.1.trans scope.1, frame.2.trans scope.2⟩

theorem current_fork_scope {source attrs maxId next : Term} {owner session : ByteArray} {journal rest : List Term}
    (owned : source.get (a "agent_id") = .binary owner)
    (call : Fork.currentFork source (.binary session) attrs maxId journal = .ok (next, rest)) :
    next.get (a "agent_id") = .binary owner ∧ next.get (a "session_id") = .binary session := by
  rw [current_fork_factor] at call
  unfold forkSelection at call
  repeat' first
    | exact fork_finish_scope owned call
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

theorem modern_fork_scope {source attrs next : Term} {owner session : ByteArray} {journal rest : List Term}
    (owned : source.get (a "agent_id") = .binary owner) (format : source.get (a "storage_format") = i 3)
    (call : Fork.fork source (.tuple [.binary session, attrs]) journal = .ok (.tuple [a "ok", next], rest)) :
    next.get (a "agent_id") = .binary owner ∧ next.get (a "session_id") = .binary session := by
  unfold Fork.fork at call
  dsimp only at call
  obtain ⟨maxId, _, _, call⟩ := bind_ok call
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
    exact current_fork_scope owned forked

end VerifiedKernel.Session.WorkConservation
