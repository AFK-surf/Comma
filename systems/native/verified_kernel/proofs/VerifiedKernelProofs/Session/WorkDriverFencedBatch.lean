import VerifiedKernelProofs.Session.WorkDriverRawBatch

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

def writeContinuation (continuationAfter : Term) : Term := .tuple [b "durable_fence", continuationAfter]

def writeFenced (cursor : PendingRevision.Cursor) (continuationAfter : Term) : Output :=
  (some (.tuple [a "session_command_driver_fence", cursor.pack, continuationAfter]), .tuple [a "fence"])

theorem fenced_write_completed (context : Context) (continuationAfter : Term) (cursor : PendingRevision.Cursor) :
    acceptWrite context (writeContinuation continuationAfter) (some cursor.pack, .tuple [a "done"]) =
      writeFenced cursor continuationAfter := rfl

theorem accept_fenced_done {context : Context} {continuationAfter : Term} {inner : Output}
    {final : PendingRevision.Cursor}
    (h : acceptWrite context (writeContinuation continuationAfter) inner = writeFenced final continuationAfter) :
    inner = (some final.pack, .tuple [a "done"]) := by
  unfold acceptWrite at h
  split at h
  · rename_i saved
    split at h
    · rename_i cursor opened
      change writeFenced cursor continuationAfter = writeFenced final continuationAfter at h
      have packed : cursor.pack = final.pack := by
        simpa only [writeFenced, Prod.mk.injEq, Option.some.injEq, Term.tuple.injEq,
          List.cons.injEq, and_true, true_and] using h
      have same := PendingRevision.pack_injective packed
      subst cursor
      rw [pending_unpack_captured opened]
    · have impossible := congrArg Prod.fst h
      cases impossible
  · simp [writeFenced, a] at h
  · have impossible := congrArg Prod.fst h
    cases impossible

theorem accept_fenced_batch {context : Context} {continuationAfter : Term} {inner : Output} {batch response : Term}
    (h : acceptWrite context (writeContinuation continuationAfter) inner =
      (some (.tuple [a "session_command_driver_batch", context.pack, writeContinuation continuationAfter, batch]), response)) :
    inner = (some batch, response) := by
  unfold acceptWrite at h
  split at h
  · split at h
    · rename_i cursor opened
      change writeFenced cursor continuationAfter = _ at h
      simp [writeFenced, a] at h
    · have impossible := congrArg Prod.fst h
      cases impossible
  · simp only [Prod.mk.injEq, Option.some.injEq, Term.tuple.injEq, List.cons.injEq,
      and_true, true_and] at h
    obtain ⟨rfl, rfl⟩ := h
    rfl
  · have impossible := congrArg Prod.fst h
    cases impossible

/-- Each step is an actual native batch run or resume, ending at the captured write fence. -/
inductive FencedBatchTrace (context : Context) (continuationAfter : Term) : Output → PendingRevision.Cursor → Prop where
  | done (cursor : PendingRevision.Cursor) : FencedBatchTrace context continuationAfter (writeFenced cursor continuationAfter) cursor
  | run {cursor : PendingRevision.Cursor} {state event : Term} {remaining observations : List Term}
      {final : PendingRevision.Cursor}
      (tail : FencedBatchTrace context continuationAfter
        (resident (some (.tuple [a "session_command_driver_batch", context.pack, writeContinuation continuationAfter,
          .tuple [a "session_pending_batch", cursor.pack, BatchExecution.pending state (event :: remaining)]]))
          (a "run") (list observations)) final) :
      FencedBatchTrace context continuationAfter
        (some (.tuple [a "session_command_driver_batch", context.pack, writeContinuation continuationAfter,
          .tuple [a "session_pending_batch", cursor.pack, BatchExecution.pending state (event :: remaining)]]),
          .tuple [a "next"]) final
  | resume {cursor : PendingRevision.Cursor} {token request observation : Term} {remaining : List Term}
      {final : PendingRevision.Cursor}
      (tail : FencedBatchTrace context continuationAfter
        (resident (some (.tuple [a "session_command_driver_batch", context.pack, writeContinuation continuationAfter,
          .tuple [a "session_pending_batch", cursor.pack, BatchExecution.observing token remaining]]))
          (a "resume") observation) final) :
      FencedBatchTrace context continuationAfter
        (some (.tuple [a "session_command_driver_batch", context.pack, writeContinuation continuationAfter,
          .tuple [a "session_pending_batch", cursor.pack, BatchExecution.observing token remaining]]),
          .tuple [a "observe", request]) final

theorem fenced_batch_reflect {context : Context} {continuationAfter : Term} {inner : Output}
    {final : PendingRevision.Cursor}
    (trace : FencedBatchTrace context continuationAfter (acceptWrite context (writeContinuation continuationAfter) inner) final) :
    Revision.Execution inner final := by
  generalize origin : acceptWrite context (writeContinuation continuationAfter) inner = output at trace
  induction trace generalizing inner with
  | done cursor =>
    rw [accept_fenced_done origin]
    exact .done cursor
  | @run cursor state event remaining observations final tail ih =>
    rw [accept_fenced_batch origin]
    apply Revision.Execution.run (observations := observations)
    apply ih
    cases context <;> rfl
  | @resume cursor token request observation remaining final tail ih =>
    rw [accept_fenced_batch origin]
    apply Revision.Execution.resume (observation := observation)
    apply ih
    cases context <;> rfl

def fencedBatchCursor (context : Context) (continuationAfter : Term)
    (cursor : PendingRevision.Cursor) (batch : Term) : Term :=
  .tuple [a "session_command_driver_batch", context.pack, writeContinuation continuationAfter,
    .tuple [a "session_pending_batch", cursor.pack, batch]]

inductive FencedBatchOutput (context : Context) (continuationAfter : Term) : Output → Prop where
  | done (cursor : PendingRevision.Cursor) : FencedBatchOutput context continuationAfter (writeFenced cursor continuationAfter)
  | run (cursor : PendingRevision.Cursor) (state event : Term) (remaining : List Term) :
      FencedBatchOutput context continuationAfter
        (some (fencedBatchCursor context continuationAfter cursor (BatchExecution.pending state (event :: remaining))),
          .tuple [a "next"])
  | resume (cursor : PendingRevision.Cursor) (token request : Term) (remaining : List Term) :
      FencedBatchOutput context continuationAfter
        (some (fencedBatchCursor context continuationAfter cursor (BatchExecution.observing token remaining)),
          .tuple [a "observe", request])
  | failed (response : Term) : FencedBatchOutput context continuationAfter (none, response)

theorem fenced_batch_next_valid (context : Context) (continuationAfter : Term)
    (cursor : PendingRevision.Cursor) (state : Term) (remaining : List Term) :
    FencedBatchOutput context continuationAfter
      (acceptWrite context (writeContinuation continuationAfter)
        (PendingRevision.accept cursor (BatchExecution.next state remaining))) := by
  cases remaining with
  | nil => exact .done { cursor with working := state }
  | cons event remaining => exact .run cursor state event remaining

theorem fenced_batch_accept_valid (context : Context) (continuationAfter : Term)
    (cursor : PendingRevision.Cursor) (remaining : List Term) (result : Term) :
    FencedBatchOutput context continuationAfter
      (acceptWrite context (writeContinuation continuationAfter)
        (PendingRevision.accept cursor (BatchExecution.accept remaining result))) := by
  unfold BatchExecution.accept
  split
  · exact fenced_batch_next_valid _ _ _ _ _
  · exact .resume cursor _ _ remaining
  · exact .failed _

theorem fenced_batch_run_captured (context : Context) (continuationAfter : Term)
    (cursor : PendingRevision.Cursor) (state event : Term) (remaining observations : List Term) :
    resident (some (fencedBatchCursor context continuationAfter cursor (BatchExecution.pending state (event :: remaining))))
      (a "run") (list observations) =
      acceptWrite context (writeContinuation continuationAfter)
        (PendingRevision.accept cursor (BatchExecution.accept remaining (runTrusted state event observations))) := by
  cases context <;> rfl

theorem fenced_batch_resume_captured (context : Context) (continuationAfter : Term)
    (cursor : PendingRevision.Cursor) (token observation : Term) (remaining : List Term) :
    resident (some (fencedBatchCursor context continuationAfter cursor (BatchExecution.observing token remaining)))
      (a "resume") observation =
      acceptWrite context (writeContinuation continuationAfter)
        (PendingRevision.accept cursor (BatchExecution.accept remaining (resumeTrusted token observation))) := by
  cases context <;> rfl

theorem fenced_batch_start_valid (context : Context) (continuationAfter : Term) (events : List Term) (hwm : Term) :
    FencedBatchOutput context continuationAfter
      (acceptWrite context (writeContinuation continuationAfter)
        (Revision.resident (some context.pack) (a "write") (.tuple [list events, hwm]))) := by
  rw [Revision.write_captured]
  change FencedBatchOutput context continuationAfter
    (acceptWrite context (writeContinuation continuationAfter) (PendingRevision.write context.candidate events hwm))
  unfold PendingRevision.write
  split
  · exact fenced_batch_next_valid _ _ _ _ _
  · exact .failed _
  · exact .failed _

theorem fenced_batch_next_shape {context : Context} {continuationAfter : Term} {saved : Term}
    (valid : FencedBatchOutput context continuationAfter (some saved, .tuple [a "next"])) :
    ∃ cursor state event remaining,
      saved = fencedBatchCursor context continuationAfter cursor (BatchExecution.pending state (event :: remaining)) := by
  generalize same : (some saved, Term.tuple [a "next"]) = output at valid
  cases valid with
  | done => simp [writeFenced, a] at same
  | run cursor state event remaining => exact ⟨cursor, state, event, remaining, Option.some.inj (congrArg Prod.fst same)⟩
  | resume => simp [a] at same
  | failed => cases congrArg Prod.fst same

theorem fenced_batch_observation_shape {context : Context} {continuationAfter : Term} {saved request : Term}
    (valid : FencedBatchOutput context continuationAfter (some saved, .tuple [a "observe", request])) :
    ∃ cursor token remaining,
      saved = fencedBatchCursor context continuationAfter cursor (BatchExecution.observing token remaining) := by
  generalize same : (some saved, Term.tuple [a "observe", request]) = output at valid
  cases valid with
  | done => simp [writeFenced, a] at same
  | run => simp [a] at same
  | resume cursor token request remaining => exact ⟨cursor, token, remaining, Option.some.inj (congrArg Prod.fst same)⟩
  | failed => cases congrArg Prod.fst same

theorem fenced_batch_trace_reflect {context : Context} {continuationAfter : Term} {initial : Output}
    {final : PendingRevision.Cursor}
    (valid : FencedBatchOutput context continuationAfter initial)
    (trace : BatchTrace initial (writeFenced final continuationAfter)) :
    FencedBatchTrace context continuationAfter initial final := by
  generalize ending : writeFenced final continuationAfter = output at trace
  induction trace with
  | done output =>
    subst output
    exact .done final
  | @run saved observations output tail ih =>
    obtain ⟨cursor, state, event, remaining, rfl⟩ := fenced_batch_next_shape valid
    apply FencedBatchTrace.run (observations := observations)
    apply ih
    · rw [fenced_batch_run_captured]
      exact fenced_batch_accept_valid _ _ _ _ _
    · exact ending
  | @resume saved request observation output tail ih =>
    obtain ⟨cursor, token, remaining, rfl⟩ := fenced_batch_observation_shape valid
    apply FencedBatchTrace.resume (observation := observation)
    apply ih
    · rw [fenced_batch_resume_captured]
      exact fenced_batch_accept_valid _ _ _ _ _
    · exact ending

theorem fenced_batch_output_preserved {context : Context} {continuationAfter : Term} {initial final : Output}
    (trace : BatchTrace initial final) (valid : FencedBatchOutput context continuationAfter initial) :
    FencedBatchOutput context continuationAfter final := by
  induction trace with
  | done => exact valid
  | run tail ih =>
    obtain ⟨cursor, state, event, remaining, rfl⟩ := fenced_batch_next_shape valid
    apply ih
    rw [fenced_batch_run_captured]
    exact fenced_batch_accept_valid _ _ _ _ _
  | resume tail ih =>
    obtain ⟨cursor, token, remaining, rfl⟩ := fenced_batch_observation_shape valid
    apply ih
    rw [fenced_batch_resume_captured]
    exact fenced_batch_accept_valid _ _ _ _ _

theorem fenced_batch_continuation {context : Context} {expected actual : Term} {cursor : PendingRevision.Cursor}
    (valid : FencedBatchOutput context expected (writeFenced cursor actual)) : actual = expected := by
  generalize same : writeFenced cursor actual = output at valid
  cases valid with
  | done final =>
    have packed := Option.some.inj (congrArg Prod.fst same)
    simp only [writeFenced, Term.tuple.injEq, List.cons.injEq, and_true, true_and] at packed
    exact packed.2
  | run => simp [writeFenced, a] at same
  | resume => simp [writeFenced, a] at same
  | failed => cases congrArg Prod.fst same

end VerifiedKernel.Session.CommandDriver
