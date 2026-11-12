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

theorem init_captures (state revision : Term) :
    resident (some state) (a "init") revision =
      (some (Cursor.mk state state revision [] nil []).pack, .tuple [a "done"]) := rfl

theorem baseline_captured (cursor : Cursor) :
    resident (some cursor.pack) (a "baseline") nil =
      (some cursor.baseline, .tuple [a "baseline", cursor.revision]) := rfl

theorem working_captured (cursor : Cursor) :
    resident (some cursor.pack) (a "working") nil = (some cursor.working, .tuple [a "done"]) := rfl

theorem metadata_captured (cursor : Cursor) :
    resident (some cursor.pack) (a "metadata") nil =
      (some cursor.pack, .tuple [a "metadata", list cursor.events, cursor.hwm]) := rfl

/-- Alias capture changes no reducer state or frozen write coordinates. -/
def Frame (before after : Cursor) : Prop :=
  after.baseline = before.baseline ∧ after.revision = before.revision ∧
    after.events = before.events ∧ after.hwm = before.hwm

inductive Execution : BatchExecution.Output → Cursor → Prop where
  | done (cursor : Cursor) : Execution (some cursor.pack, .tuple [a "done"]) cursor
  | run {cursor : Cursor} {state event : Term} {events observations : List Term} {final : Cursor}
      (tail : Execution (resident
        (some (.tuple [a "session_delta_batch", cursor.pack, BatchExecution.pending state (event :: events)]))
        (a "run") (list observations)) final) :
      Execution (some (.tuple [a "session_delta_batch", cursor.pack, BatchExecution.pending state (event :: events)]),
        .tuple [a "next"]) final
  | resume {cursor : Cursor} {before event token request observation : Term} {events : List Term} {final : Cursor}
      (tail : Execution (resident
        (some (.tuple [a "session_delta_observe", cursor.pack, before, event, BatchExecution.observing token events]))
        (a "resume") observation) final) :
      Execution (some (.tuple [a "session_delta_observe", cursor.pack, before, event, BatchExecution.observing token events]),
        .tuple [a "observe", request]) final

def Meaning : BatchExecution.Output → Cursor → Prop
  | (some value, .tuple [.atom "done"]), final => value = final.pack
  | (some (.tuple [.atom "session_delta_batch", saved, batch]), response), final
  | (some (.tuple [.atom "session_delta_observe", saved, _, _, batch]), response), final =>
    ∃ cursor, unpack saved = some cursor ∧ ∃ working,
      BatchExecution.Meaning (some batch, response) working ∧ Frame cursor final ∧ final.working = working
  | _, _ => False

theorem accept_meaning {cursor final : Cursor} {output : BatchExecution.Output}
    (h : Meaning (accept cursor output) final) :
    ∃ working, BatchExecution.Meaning output working ∧ Frame cursor final ∧ final.working = working := by
  unfold accept at h
  split at h
  · rename_i working
    have same := (pack_injective h).symm
    subst final
    exact ⟨working, rfl, ⟨rfl, rfl, rfl, rfl⟩, rfl⟩
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
      obtain ⟨captured, same, working, meaning, frame, workingEq⟩ := h
      subst captured
      exact ⟨working, meaning, frame, workingEq⟩
    · rename_i saved before event nested reply _ _ shape
      simp [a] at shape
    · exact h.elim
  · exact h.elim

theorem capture_meaning {cursor final : Cursor} {before after event : Term} {output : BatchExecution.Output}
    (h : Meaning (captureDelta cursor before after event output) final) :
    ∃ working, BatchExecution.Meaning output working ∧ Frame cursor final ∧ final.working = working := by
  cases call : StorageDelta.captureDedupe before after event [] with
  | ok result =>
    obtain ⟨added, rest⟩ := result
    cases rest with
    | nil =>
      simp only [captureDelta, call] at h
      obtain ⟨working, meaning, frame, workingEq⟩ := accept_meaning h
      exact ⟨working, meaning, frame, workingEq⟩
    | cons head tail => simp [captureDelta, call, Meaning] at h
  | error signal =>
    cases signal <;> simp [captureDelta, call, Meaning] at h

theorem captured_meaning {cursor final : Cursor} {before event : Term} {output : BatchExecution.Output}
    (h : Meaning (acceptCaptured cursor before event output) final) :
    ∃ working, BatchExecution.Meaning output working ∧ Frame cursor final ∧ final.working = working := by
  unfold acceptCaptured at h
  split at h
  · exact capture_meaning h
  · exact capture_meaning h
  · rename_i batch response request
    simp only [Meaning, unpack_pack, Option.some.injEq] at h
    obtain ⟨captured, same, working, meaning, frame, workingEq⟩ := h
    have capturedEq : cursor = captured := by simpa only [unpack_pack, Option.some.injEq] using same
    subst captured
    exact ⟨working, meaning, frame, workingEq⟩
  · exact accept_meaning h

theorem execution_meaning {output : BatchExecution.Output} {final : Cursor}
    (execution : Execution output final) : Meaning output final := by
  induction execution with
  | done => rfl
  | @run cursor state event events observations final tail ih =>
    change Meaning (acceptCaptured cursor state event
      (BatchExecution.resident (some (BatchExecution.pending state (event :: events))) (a "run") (list observations))) final at ih
    obtain ⟨working, meaning, frame, workingEq⟩ := captured_meaning ih
    simp only [BatchExecution.resident, BatchExecution.pending, a, list] at meaning
    obtain ⟨middle, head, rest⟩ := BatchExecution.accept_meaning meaning
    exact ⟨cursor, rfl, working, ResidentBatch.cons head rest, frame, workingEq⟩
  | @resume cursor before event token request observation events final tail ih =>
    change Meaning (acceptCaptured cursor before event
      (BatchExecution.resident (some (BatchExecution.observing token events)) (a "resume") observation)) final at ih
    obtain ⟨working, meaning, frame, workingEq⟩ := captured_meaning ih
    simp only [BatchExecution.resident, BatchExecution.observing, a, list] at meaning
    obtain ⟨middle, head, rest⟩ := BatchExecution.accept_meaning meaning
    exact ⟨cursor, rfl, working, ⟨middle, ResidentTrace.resume head, rest⟩, frame, workingEq⟩

/-- The unique pending writer runs the captured reducers once; alias capture retains its baseline, revision and HWM. -/
theorem write_executes {cursor final : Cursor} {events : List Term} {hwm : Term}
    (execution : Execution (resident (some cursor.pack) (a "write") (.tuple [list events, hwm])) final) :
    ∃ merged, mergeHwm cursor.hwm hwm [] = .ok (merged, []) ∧
      final.baseline = cursor.baseline ∧ final.revision = cursor.revision ∧
      final.events = cursor.events ++ events ∧ final.hwm = merged ∧
      ResidentBatch cursor.working (events ++ hwmEvents hwm) final.working := by
  have meaning := execution_meaning execution
  change Meaning (write cursor events hwm) final at meaning
  unfold write at meaning
  split at meaning
  · rename_i merged mergeRead
    obtain ⟨working, batch, frame, workingEq⟩ := accept_meaning meaning
    have applied := BatchExecution.next_meaning batch
    rw [← workingEq] at applied
    exact ⟨merged, mergeRead, frame.1, frame.2.1, frame.2.2.1, frame.2.2.2, applied⟩
  · exact meaning.elim
  · exact meaning.elim

inductive History (baseline revision : Term) : Cursor → List Term → Prop where
  | initial : History baseline revision (Cursor.mk baseline baseline revision [] nil []) []
  | write {cursor final : Cursor} {prior events : List Term} {hwm : Term}
      (history : History baseline revision cursor prior)
      (execution : Execution (resident (some cursor.pack) (a "write") (.tuple [list events, hwm])) final) :
      History baseline revision final (prior ++ (events ++ hwmEvents hwm))

theorem batch_concat {state middle final : Term} {first last : List Term}
    (before : ResidentBatch state first middle) (after : ResidentBatch middle last final) :
    ResidentBatch state (first ++ last) final := by
  induction before with
  | nil => exact after
  | cons head tail ih => exact .cons head (ih after)

theorem history_refines {baseline revision : Term} {cursor : Cursor} {events : List Term}
    (history : History baseline revision cursor events) :
    cursor.baseline = baseline ∧ cursor.revision = revision ∧ ResidentBatch baseline events cursor.working := by
  induction history with
  | initial => exact ⟨rfl, rfl, .nil _⟩
  | write previous execution ih =>
    obtain ⟨_, _, baselineEq, revisionEq, _, _, applied⟩ := write_executes execution
    exact ⟨baselineEq.trans ih.1, revisionEq.trans ih.2.1, batch_concat ih.2.2 applied⟩

end VerifiedKernel.Session.PendingRevision
