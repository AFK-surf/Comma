import VerifiedKernelProofs.Session.WorkPhysicalFence
import VerifiedKernelProofs.Session.WorkForkIdentity

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxRecDepth 4096
set_option maxHeartbeats 1000000

structure InitialFields (state : Term) : Prop where
  ready : QueueReady state
  format : state.get (a "storage_format") = i 3
  header : LedgerHeader state
  messages : ∃ records, state.get (a "messages") = list records
  catalog : state.get (a "segment_catalog") = list []
  archived : state.get (a "archived_through") = i 0

theorem normalize_fork_initial {entries : List (String × Term)} {records journal rest : List Term} {next : Term}
    (queue : entries.reverse.find? (fun pair => pair.1 == "input_queue") = some ("input_queue", list []))
    (allocator : entries.reverse.find? (fun pair => pair.1 == "next_queue_id") = some ("next_queue_id", i 1))
    (ack : entries.reverse.find? (fun pair => pair.1 == "queue_ack_id") = some ("queue_ack_id", i 0))
    (messages : entries.reverse.find? (fun pair => pair.1 == "messages") = some ("messages", list records))
    (format : entries.reverse.find? (fun pair => pair.1 == "storage_format") = some ("storage_format", i 3))
    (catalog : entries.all (fun pair => pair.1 != "segment_catalog") = true)
    (archived : entries.reverse.find? (fun pair => pair.1 == "archived_through") = some ("archived_through", i 0))
    (call : Lifecycle.normalize (Lifecycle.build entries) journal = .ok (next, rest)) : InitialFields next := by
  have ready : QueueReady (Lifecycle.build entries) :=
    ⟨queue_allocated_empty (build_value queue) (build_value allocator),
      ⟨[], 0, build_value queue, build_value ack, by simp⟩,
      by rw [build_value ack, build_value allocator]; decide⟩
  have initialMessages := build_value messages
  have filled := fillDefaults_get (key := "messages") (s := Lifecycle.build entries)
    (by rw [initialMessages]; intro impossible; cases impossible)
  have work := normalize_work ready call
  have nextMessages := work.2.2
  rw [filled, initialMessages] at nextMessages
  have initialCatalog : (Lifecycle.build entries).get (a "segment_catalog") = list [] := (build_get catalog).trans rfl
  have archive := ArchivePublication.normalize_archive_fields initialCatalog (build_value archived) (by simp) call
  exact ⟨work.1, normalize_format (build_value format) call, normalize_ledger_header call,
    ⟨records, nextMessages⟩, archive.1, archive.2⟩

theorem rebuild_refs_fork_initial {state next : Term} {journal rest : List Term}
    (initial : InitialFields state) (call : rebuildRefs state journal = .ok (next, rest)) : InitialFields next := by
  unfold rebuildRefs at call
  repeat
    fail_if_success (head_is call [write]; change write _ _ _ = .ok (next, rest) at call)
    obtain ⟨_, _, _, call⟩ := bind_ok call
  have frame : QueueFrame state next := write_queue_frame call rfl rfl rfl rfl rfl
  obtain ⟨messages, read⟩ := initial.messages
  refine ⟨queue_frame_ready frame initial.ready, frame.2.2.2.2.trans initial.format, ?_,
    ⟨messages, (write_field_frame call rfl).trans read⟩,
    (write_field_frame call rfl).trans initial.catalog, (write_field_frame call rfl).trans initial.archived⟩
  unfold LedgerHeader
  rw [write_field_frame (key := "input_dedupe") call rfl]
  exact initial.header

theorem fork_finish_initial {source session attrs next : Term} {copy : Bool}
    {messages facts results remapped clamped journal rest : List Term}
    {lastSeq lastAck forkThrough nextId created : Term}
    (call : forkFinish source session attrs copy messages facts results remapped clamped
      lastSeq lastAck forkThrough nextId created journal = .ok (next, rest)) : InitialFields next := by
  cases copy <;> unfold forkFinish at call <;> simp only [Bool.false_eq_true, ↓reduceIte] at call
  all_goals repeat
    fail_if_success (bind_head_is call [Lifecycle.normalize]; change (Lifecycle.normalize _ >>= _) _ = .ok (next, rest) at call)
    obtain ⟨_, _, _, call⟩ := bind_ok call
  all_goals
    obtain ⟨child, _, normalized, call⟩ := bind_ok call
    exact rebuild_refs_fork_initial (normalize_fork_initial rfl rfl rfl rfl rfl rfl rfl normalized) call

theorem current_fork_initial {source session attrs maxId next : Term} {journal rest : List Term}
    (call : Fork.currentFork source session attrs maxId journal = .ok (next, rest)) : InitialFields next := by
  rw [current_fork_factor] at call
  unfold forkSelection at call
  repeat' first
    | exact fork_finish_initial call
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

theorem modern_fork_initial {source args next : Term} {journal rest : List Term}
    (format : source.get (a "storage_format") = i 3)
    (call : Fork.fork source args journal = .ok (.tuple [a "ok", next], rest)) : InitialFields next := by
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
      exact current_fork_initial forked
  · exact (fail_ok call).elim

end VerifiedKernel.Session.WorkConservation
