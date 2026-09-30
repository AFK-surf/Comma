import VerifiedKernel.Session.Revision
import VerifiedKernelProofs.Session.WorkPendingRevision
import VerifiedKernelProofs.Session.WorkRevisionFence

namespace VerifiedKernel.Session.Revision
open Data WorkConservation
set_option Elab.async false

theorem unpack_pack (cursor : Cursor) : unpack cursor.pack = some cursor := by
  cases cursor <;> rfl

theorem init_captures (state etag : Term) :
    resident (some state) (a "init") etag =
      (some (Cursor.committed state etag).pack, .tuple [a "done"]) := rfl

theorem working_captured (cursor : Cursor) :
    resident (some cursor.pack) (a "working") nil =
      (some cursor.candidate.working,
        .tuple [a "revision", cursor.candidate.etag, Term.bool cursor.isPending]) := by
  cases cursor <;> rfl

theorem baseline_captured (cursor : Cursor) :
    resident (some cursor.pack) (a "baseline") nil =
      (some cursor.baseline.pack, .tuple [a "done"]) := by
  cases cursor <;> rfl

theorem fresh_captures (state : Term) :
    resident (some state) (a "fresh") nil =
      (some (Cursor.fresh state).pack, .tuple [a "done"]) := rfl

theorem fresh_requires_commit (state : Term) :
    (Cursor.fresh state).isPending = true ∧ (Cursor.fresh state).candidate.etag = nil := ⟨rfl, rfl⟩

theorem absent_baseline_stays_fresh (cursor : PendingRevision.Cursor) (absent : cursor.etag = nil) :
    (Cursor.pending cursor).baseline = .fresh cursor.baseline := by
  simp [Cursor.baseline, absent]
  rfl

theorem write_captured (cursor : Cursor) (events : List Term) (hwm : Term) :
    resident (some cursor.pack) (a "write") (.tuple [list events, hwm]) =
      PendingRevision.resident (some cursor.candidate.pack) (a "write") (.tuple [list events, hwm]) := by
  cases cursor <;> rfl

inductive Execution : Output → PendingRevision.Cursor → Prop where
  | done (cursor : PendingRevision.Cursor) : Execution (some cursor.pack, .tuple [a "done"]) cursor
  | run {cursor : PendingRevision.Cursor} {state event : Term} {events observations : List Term}
      {final : PendingRevision.Cursor}
      (tail : Execution (resident
        (some (.tuple [a "session_pending_batch", cursor.pack, BatchExecution.pending state (event :: events)]))
        (a "run") (list observations)) final) :
      Execution (some (.tuple [a "session_pending_batch", cursor.pack, BatchExecution.pending state (event :: events)]),
        .tuple [a "next"]) final
  | resume {cursor : PendingRevision.Cursor} {token request observation : Term} {events : List Term}
      {final : PendingRevision.Cursor}
      (tail : Execution (resident
        (some (.tuple [a "session_pending_batch", cursor.pack, BatchExecution.observing token events]))
        (a "resume") observation) final) :
      Execution (some (.tuple [a "session_pending_batch", cursor.pack, BatchExecution.observing token events]),
        .tuple [a "observe", request]) final

theorem execution_pending {output : Output} {final : PendingRevision.Cursor}
    (execution : Execution output final) : PendingRevision.Execution output final := by
  induction execution with
  | done cursor => exact .done cursor
  | run _ ih => exact .run ih
  | resume _ ih => exact .resume ih

/-- A completed native write uses the captured working state and retains the original baseline and ETag. -/
theorem write_executes {cursor : Cursor} {final : PendingRevision.Cursor} {events : List Term} {hwm : Term}
    (execution : Execution
      (resident (some cursor.pack) (a "write") (.tuple [list events, hwm])) final) :
    ∃ merged, PendingRevision.mergeHwm cursor.candidate.hwm hwm [] = .ok (merged, []) ∧
      final.baseline = cursor.candidate.baseline ∧ final.etag = cursor.candidate.etag ∧
      final.events = cursor.candidate.events ++ events ∧ final.hwm = merged ∧
      ResidentBatch cursor.candidate.working (events ++ PendingRevision.hwmEvents hwm) final.working := by
  have pending := execution_pending execution
  rw [write_captured] at pending
  exact PendingRevision.write_executes pending

theorem write_is_pending (final : PendingRevision.Cursor) :
    unpack final.pack = some (.pending final) ∧ (Cursor.pending final).isPending = true := ⟨rfl, rfl⟩

/-- Resuming a captured CAS returns the exact candidate as a committed native revision. -/
theorem cas_commits (state etag outcome : Term) :
    RevisionFence.resident
      (some (.tuple [a "session_fence_cas", .tuple [a "storage_commit_pending", state]]))
      (a "cas_revision") (.tuple [a "ok", etag, outcome]) =
      (some (Cursor.committed state etag).pack, .tuple [a "committed"]) := rfl

theorem cas_rejected (state : Term) :
    RevisionFence.resident
      (some (.tuple [a "session_fence_cas", .tuple [a "storage_commit_pending", state]]))
      (a "cas_revision") (.tuple [a "error", a "precondition_failed"]) =
      (some state, .tuple [a "error", a "precondition_failed"]) := rfl

theorem cas_result_capture {state result committed : Term}
    (resumed : committedResult (StorageCommit.resident
      (some (.tuple [a "storage_commit_pending", state])) (a "resume") result) =
      (some committed, .tuple [a "committed"])) :
    ∃ etag, committed = (Cursor.committed state etag).pack ∧
      StorageCommit.resident (some (.tuple [a "storage_commit_pending", state])) (a "resume") result =
        (some state, .tuple [a "ok", etag]) := by
  simp only [StorageCommit.resident, a] at resumed
  split at resumed
  · rename_i response finished
    unfold StorageCommit.finish at finished
    split at finished
    · rename_i original etag outcome
      rw [pure_ok finished] at resumed
      have packed : (Cursor.committed state etag).pack = committed :=
        Option.some.inj (congrArg Prod.fst resumed)
      exact ⟨etag, packed.symm, rfl⟩
    · rw [pure_ok finished] at resumed
      simp [committedResult, a] at resumed
    · rw [pure_ok finished] at resumed
      simp [committedResult, a] at resumed
    · exact (fail_ok finished).elim
  · simp [committedResult, a] at resumed

theorem confirmed_raw {cursor : PendingRevision.Cursor} {key state saved request result committed : Term}
    (encoded : RevisionFence.resident
      (some (.tuple [a "session_fence_stamped", cursor.pack, key, state]))
      (a "encode") nil = (some saved, request))
    (resumed : RevisionFence.resident (some saved) (a "cas_revision") result =
      (some committed, .tuple [a "committed"])) :
    ∃ etag, committed = (Cursor.committed state etag).pack ∧
      RevisionFence.resident (some saved) (a "cas_result") result = (some state, .tuple [a "ok", etag]) := by
  obtain ⟨commit, same, started⟩ := RevisionFence.encode_capture encoded
  obtain ⟨captured, _⟩ := StorageCommit.start_capture started
  rw [same, captured] at resumed ⊢
  exact cas_result_capture resumed

theorem confirmed_revision {cursor : PendingRevision.Cursor}
    {key state saved request result committed : Term} {durable : ArchivePublication.HotSnapshots}
    (encoded : RevisionFence.resident
      (some (.tuple [a "session_fence_stamped", cursor.pack, key, state]))
      (a "encode") nil = (some saved, request))
    (primitive : ArchivePublication.SnapshotCASMeaning request result durable)
    (resumed : RevisionFence.resident (some saved) (a "cas_revision") result =
      (some committed, .tuple [a "committed"])) :
    ∃ etag snapshot bytes, committed = (Cursor.committed state etag).pack ∧
      Lifecycle.persistable state [] = .ok (snapshot, []) ∧
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      request = .tuple [a "cas", key, .binary bytes, cursor.etag] ∧ durable key etag snapshot := by
  obtain ⟨etag, packed, raw⟩ := confirmed_raw encoded resumed
  obtain ⟨_, snapshot, bytes, persisted, encodedBytes, requested, stored⟩ :=
    RevisionFence.confirmed_capture encoded primitive raw
  exact ⟨etag, snapshot, bytes, packed, persisted, encodedBytes, requested, stored⟩

end VerifiedKernel.Session.Revision
