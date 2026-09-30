import VerifiedKernelProofs.Session.WorkBatchExecution
import VerifiedKernel.Session.PendingRevision

namespace VerifiedKernel.Session.PendingRevision
open Data WorkConservation
set_option Elab.async false

theorem unpack_pack (cursor : Cursor) : unpack cursor.pack = some cursor := rfl

theorem pack_injective {left right : Cursor} (h : left.pack = right.pack) : left = right := by
  cases left
  cases right
  simp_all [Cursor.pack, list]

theorem init_captures (state etag : Term) :
    resident (some state) (a "init") etag =
      (some (Cursor.mk state state etag [] nil).pack, .tuple [a "done"]) := rfl

theorem baseline_captured (cursor : Cursor) :
    resident (some cursor.pack) (a "baseline") nil = (some cursor.baseline, .tuple [a "baseline", cursor.etag]) := rfl

theorem working_captured (cursor : Cursor) :
    resident (some cursor.pack) (a "working") nil = (some cursor.working, .tuple [a "done"]) := rfl

theorem metadata_captured (cursor : Cursor) :
    resident (some cursor.pack) (a "metadata") nil =
      (some cursor.pack, .tuple [a "metadata", list cursor.events, cursor.hwm]) := rfl

theorem run_batch (cursor : Cursor) (batch args : Term) :
    resident (some (.tuple [a "session_pending_batch", cursor.pack, batch])) (a "run") args =
      accept cursor (BatchExecution.resident (some batch) (a "run") args) := rfl

theorem resume_batch (cursor : Cursor) (batch args : Term) :
    resident (some (.tuple [a "session_pending_batch", cursor.pack, batch])) (a "resume") args =
      accept cursor (BatchExecution.resident (some batch) (a "resume") args) := rfl

inductive Execution : BatchExecution.Output → Cursor → Prop where
  | done (cursor : Cursor) : Execution (some cursor.pack, .tuple [a "done"]) cursor
  | run {cursor : Cursor} {state event : Term} {events observations : List Term} {final : Cursor}
      (tail : Execution (resident
        (some (.tuple [a "session_pending_batch", cursor.pack, BatchExecution.pending state (event :: events)]))
        (a "run") (list observations)) final) :
      Execution (some (.tuple [a "session_pending_batch", cursor.pack, BatchExecution.pending state (event :: events)]),
        .tuple [a "next"]) final
  | resume {cursor : Cursor} {token request observation : Term} {events : List Term} {final : Cursor}
      (tail : Execution (resident
        (some (.tuple [a "session_pending_batch", cursor.pack, BatchExecution.observing token events]))
        (a "resume") observation) final) :
      Execution (some (.tuple [a "session_pending_batch", cursor.pack, BatchExecution.observing token events]),
        .tuple [a "observe", request]) final

def Meaning : BatchExecution.Output → Cursor → Prop
  | (some value, .tuple [.atom "done"]), final => value = final.pack
  | (some (.tuple [.atom "session_pending_batch", saved, batch]), response), final =>
    ∃ cursor, unpack saved = some cursor ∧ ∃ working,
      BatchExecution.Meaning (some batch, response) working ∧ final = { cursor with working := working }
  | _, _ => False

theorem accept_meaning {cursor final : Cursor} {output : BatchExecution.Output}
    (h : Meaning (accept cursor output) final) :
    ∃ working, BatchExecution.Meaning output working ∧ final = { cursor with working := working } := by
  unfold accept at h
  split at h
  · rename_i working
    exact ⟨working, rfl, (pack_injective h).symm⟩
  · rename_i batch response notDone
    unfold Meaning at h
    split at h
    · simp_all [Cursor.pack, a, list]
    · rename_i saved nested reply _ shape
      simp only [Prod.mk.injEq, Option.some.injEq, Term.tuple.injEq, List.cons.injEq,
        and_true, true_and] at shape
      obtain ⟨⟨savedEq, batchEq⟩, replyEq⟩ := shape
      subst saved nested reply
      simp only [unpack_pack, Option.some.injEq] at h
      obtain ⟨captured, same, working, meaning, finalEq⟩ := h
      subst captured
      exact ⟨working, meaning, finalEq⟩
    · exact h.elim
  · exact h.elim

theorem execution_meaning {output : BatchExecution.Output} {final : Cursor}
    (execution : Execution output final) : Meaning output final := by
  induction execution with
  | done => rfl
  | @run cursor state event events observations final tail ih =>
    rw [run_batch] at ih
    obtain ⟨working, meaning, finalEq⟩ := accept_meaning ih
    simp only [BatchExecution.resident, BatchExecution.pending, a, list] at meaning
    obtain ⟨middle, head, rest⟩ := BatchExecution.accept_meaning meaning
    exact ⟨cursor, rfl, working, ResidentBatch.cons head rest, finalEq⟩
  | @resume cursor token request observation events final tail ih =>
    rw [resume_batch] at ih
    obtain ⟨working, meaning, finalEq⟩ := accept_meaning ih
    simp only [BatchExecution.resident, BatchExecution.observing, a, list] at meaning
    obtain ⟨middle, head, rest⟩ := BatchExecution.accept_meaning meaning
    exact ⟨cursor, rfl, working, ⟨middle, ResidentTrace.resume head, rest⟩, finalEq⟩

/-- Every successful staged write extends the captured events and runs them against the captured working state.
The baseline and ETag do not change. This includes the HWM reducer and all reducer observations. -/
theorem write_executes {cursor final : Cursor} {events : List Term} {hwm : Term}
    (execution : Execution (resident (some cursor.pack) (a "write") (.tuple [list events, hwm])) final) :
    ∃ merged, mergeHwm cursor.hwm hwm [] = .ok (merged, []) ∧
      final.baseline = cursor.baseline ∧ final.etag = cursor.etag ∧
      final.events = cursor.events ++ events ∧ final.hwm = merged ∧
      ResidentBatch cursor.working (events ++ hwmEvents hwm) final.working := by
  have meaning := execution_meaning execution
  change Meaning (write cursor events hwm) final at meaning
  unfold write at meaning
  split at meaning
  · rename_i merged mergeRead
    obtain ⟨working, batch, finalEq⟩ := accept_meaning meaning
    have applied := BatchExecution.next_meaning batch
    subst final
    exact ⟨merged, mergeRead, rfl, rfl, rfl, rfl, applied⟩
  · exact meaning.elim
  · exact meaning.elim

/-- The trace records actual reducer events, including each write's HWM event, without another runtime ledger. -/
inductive History (baseline etag : Term) : Cursor → List Term → Prop where
  | initial : History baseline etag (Cursor.mk baseline baseline etag [] nil) []
  | write {cursor final : Cursor} {prior events : List Term} {hwm : Term}
      (history : History baseline etag cursor prior)
      (execution : Execution (resident (some cursor.pack) (a "write") (.tuple [list events, hwm])) final) :
      History baseline etag final (prior ++ (events ++ hwmEvents hwm))

theorem batch_concat {state middle final : Term} {first last : List Term}
    (before : ResidentBatch state first middle) (after : ResidentBatch middle last final) :
    ResidentBatch state (first ++ last) final := by
  induction before with
  | nil => exact after
  | cons head tail ih => exact .cons head (ih after)

/-- Any finite sequence of actual staged writes keeps one baseline and derives its complete working-state execution. -/
theorem history_refines {baseline etag : Term} {cursor : Cursor} {events : List Term}
    (history : History baseline etag cursor events) :
    cursor.baseline = baseline ∧ cursor.etag = etag ∧ ResidentBatch baseline events cursor.working := by
  induction history with
  | initial => exact ⟨rfl, rfl, .nil _⟩
  | write previous execution ih =>
    obtain ⟨_, _, baselineEq, etagEq, _, _, applied⟩ := write_executes execution
    exact ⟨baselineEq.trans ih.1, etagEq.trans ih.2.1, batch_concat ih.2.2 applied⟩

end VerifiedKernel.Session.PendingRevision
