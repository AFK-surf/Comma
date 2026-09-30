import VerifiedKernelProofs.Session.WorkRevisionPlan

namespace VerifiedKernel.Session.Revision
open Data WorkConservation
set_option Elab.async false

/-- The host follows public responses without inspecting planning or reducer resource tags. -/
inductive PlanTrace : Output → Output → Prop where
  | done (output : Output) : PlanTrace output output
  | run {saved : Term} {observations : List Term} {final : Output}
      (tail : PlanTrace (resident (some saved) (a "run") (list observations)) final) :
      PlanTrace (some saved, .tuple [a "next"]) final
  | resume {saved request observation : Term} {final : Output}
      (tail : PlanTrace (resident (some saved) (a "resume") observation) final) :
      PlanTrace (some saved, .tuple [a "observe", request]) final

theorem PlanTrace.fixed {initial final : Output} (trace : PlanTrace initial final)
    (notNext : initial.2 ≠ .tuple [a "next"])
    (notObserve : ∀ request, initial.2 ≠ .tuple [a "observe", request]) : final = initial := by
  cases trace with
  | done => rfl
  | run => exact (notNext rfl).elim
  | resume => exact (notObserve _ rfl).elim

def planBatchCursor (outcome : Term) (cursor : PendingRevision.Cursor) (batch : Term) : Term :=
  .tuple [a "session_revision_plan_batch", outcome, .tuple [a "session_pending_batch", cursor.pack, batch]]

inductive PlanBatchOutput (outcome : Term) : Output → Prop where
  | done (cursor : PendingRevision.Cursor) : PlanBatchOutput outcome (planned cursor outcome)
  | run (cursor : PendingRevision.Cursor) (state event : Term) (remaining : List Term) :
      PlanBatchOutput outcome
        (some (planBatchCursor outcome cursor (BatchExecution.pending state (event :: remaining))), .tuple [a "next"])
  | resume (cursor : PendingRevision.Cursor) (token request : Term) (remaining : List Term) :
      PlanBatchOutput outcome
        (some (planBatchCursor outcome cursor (BatchExecution.observing token remaining)), .tuple [a "observe", request])
  | failed (response : Term) : PlanBatchOutput outcome (none, response)

theorem plan_batch_next_valid (outcome : Term) (cursor : PendingRevision.Cursor)
    (state : Term) (remaining : List Term) :
    PlanBatchOutput outcome
      (acceptPlanBatch outcome (PendingRevision.accept cursor (BatchExecution.next state remaining))) := by
  cases remaining with
  | nil => exact .done { cursor with working := state }
  | cons event remaining => exact .run cursor state event remaining

theorem plan_batch_accept_valid (outcome : Term) (cursor : PendingRevision.Cursor)
    (remaining : List Term) (result : Term) :
    PlanBatchOutput outcome
      (acceptPlanBatch outcome (PendingRevision.accept cursor (BatchExecution.accept remaining result))) := by
  unfold BatchExecution.accept
  split
  · exact plan_batch_next_valid _ _ _ _
  · exact .resume cursor _ _ remaining
  · exact .failed _

theorem plan_batch_run_captured (outcome : Term) (cursor : PendingRevision.Cursor)
    (state event : Term) (remaining observations : List Term) :
    resident (some (planBatchCursor outcome cursor (BatchExecution.pending state (event :: remaining))))
      (a "run") (list observations) =
      acceptPlanBatch outcome
        (PendingRevision.accept cursor (BatchExecution.accept remaining (runTrusted state event observations))) := rfl

theorem plan_batch_resume_captured (outcome : Term) (cursor : PendingRevision.Cursor)
    (token observation : Term) (remaining : List Term) :
    resident (some (planBatchCursor outcome cursor (BatchExecution.observing token remaining)))
      (a "resume") observation =
      acceptPlanBatch outcome
        (PendingRevision.accept cursor (BatchExecution.accept remaining (resumeTrusted token observation))) := rfl

theorem plan_batch_start_valid (outcome : Term) (cursor : Cursor) (events : List Term) (hwm : Term) :
    PlanBatchOutput outcome (acceptPlanBatch outcome (PendingRevision.write cursor.candidate events hwm)) := by
  unfold PendingRevision.write
  split
  · exact plan_batch_next_valid _ _ _ _
  · exact .failed _
  · exact .failed _

theorem plan_batch_next_shape {outcome saved : Term}
    (valid : PlanBatchOutput outcome (some saved, .tuple [a "next"])) :
    ∃ cursor state event remaining,
      saved = planBatchCursor outcome cursor (BatchExecution.pending state (event :: remaining)) := by
  generalize same : (some saved, Term.tuple [a "next"]) = output at valid
  cases valid with
  | done => simp [planned, a] at same
  | run cursor state event remaining => exact ⟨cursor, state, event, remaining, Option.some.inj (congrArg Prod.fst same)⟩
  | resume => simp [a] at same
  | failed => cases congrArg Prod.fst same

theorem plan_batch_observation_shape {outcome saved request : Term}
    (valid : PlanBatchOutput outcome (some saved, .tuple [a "observe", request])) :
    ∃ cursor token remaining, saved = planBatchCursor outcome cursor (BatchExecution.observing token remaining) := by
  generalize same : (some saved, Term.tuple [a "observe", request]) = output at valid
  cases valid with
  | done => simp [planned, a] at same
  | run => simp [a] at same
  | resume cursor token _ remaining => exact ⟨cursor, token, remaining, Option.some.inj (congrArg Prod.fst same)⟩
  | failed => cases congrArg Prod.fst same

theorem plan_batch_trace_reflect {outcome : Term} {initial : Output} {final : PendingRevision.Cursor}
    (valid : PlanBatchOutput outcome initial)
    (trace : PlanTrace initial (planned final outcome)) : PlanBatchTrace outcome initial final := by
  generalize ending : planned final outcome = output at trace
  induction trace with
  | done output =>
    subst output
    exact .done final
  | @run saved observations output tail ih =>
    obtain ⟨cursor, state, event, remaining, rfl⟩ := plan_batch_next_shape valid
    apply PlanBatchTrace.run (observations := observations)
    apply ih
    · rw [plan_batch_run_captured]
      exact plan_batch_accept_valid _ _ _ _
    · exact ending
  | @resume saved request observation output tail ih =>
    obtain ⟨cursor, token, remaining, rfl⟩ := plan_batch_observation_shape valid
    apply PlanBatchTrace.resume (observation := observation)
    apply ih
    · rw [plan_batch_resume_captured]
      exact plan_batch_accept_valid _ _ _ _
    · exact ending

theorem plan_batch_output_preserved {outcome : Term} {initial final : Output}
    (trace : PlanTrace initial final) (valid : PlanBatchOutput outcome initial) :
    PlanBatchOutput outcome final := by
  induction trace with
  | done => exact valid
  | run tail ih =>
    obtain ⟨cursor, state, event, remaining, rfl⟩ := plan_batch_next_shape valid
    apply ih
    rw [plan_batch_run_captured]
    exact plan_batch_accept_valid _ _ _ _
  | resume tail ih =>
    obtain ⟨cursor, token, remaining, rfl⟩ := plan_batch_observation_shape valid
    apply ih
    rw [plan_batch_resume_captured]
    exact plan_batch_accept_valid _ _ _ _

theorem plan_batch_done_outcome {outcome other : Term} {final : PendingRevision.Cursor}
    (valid : PlanBatchOutput outcome (planned final other)) : outcome = other := by
  generalize same : planned final other = output at valid
  cases valid with
  | done =>
    have value := congrArg Prod.snd same
    simpa [planned] using value.symm
  | run => simp [planned, a] at same
  | resume => simp [planned, a] at same
  | failed => cases congrArg Prod.fst same

theorem stage_plan_raw_executes {cursor : Cursor} {events : List Term} {hwm outcome other : Term}
    {final : PendingRevision.Cursor}
    (trace : PlanTrace (stagePlan cursor events hwm outcome) (planned final other)) :
    outcome = other ∧ PendingRevision.Execution
      (PendingRevision.resident (some cursor.candidate.pack) (a "write") (.tuple [list events, hwm])) final := by
  unfold stagePlan at trace
  split at trace
  · have impossible := trace.fixed (by simp [a]) (by simp [a])
    simp [planned, a, Term.bool] at impossible
  · have valid := plan_batch_start_valid outcome cursor events hwm
    have same := plan_batch_done_outcome (plan_batch_output_preserved trace valid)
    subst other
    exact ⟨rfl, plan_batch_reflect (plan_batch_trace_reflect valid trace)⟩

/-- Leading observations derive the actual planner call before any batch execution. -/
theorem plan_trace_terminal_call {cursor : Cursor} {mode : Term} {observations : List Term} {final : Output}
    (trace : PlanTrace (plan cursor mode observations) final)
    (present : final.1 ≠ none)
    (terminal : ∀ request, final.2 ≠ .tuple [a "observe", request]) :
    ∃ journal result rest, Command.revisionPlan cursor.candidate.working mode journal = .ok (result, rest) ∧
      settled rest = true ∧ PlanTrace (acceptPlan cursor mode result) final := by
  generalize origin : plan cursor mode observations = output at trace
  induction trace generalizing observations with
  | done output =>
    have startPresent : (plan cursor mode observations).1 ≠ none := by rw [origin]; exact present
    have startTerminal : ∀ request, (plan cursor mode observations).2 ≠ .tuple [a "observe", request] := by
      rw [origin]; exact terminal
    obtain ⟨result, rest, call, complete, accepted⟩ := plan_terminal_call startPresent startTerminal
    exact ⟨observations, result, rest, call, complete, by rw [← accepted, origin]; exact .done _⟩
  | @run saved journal last tail ih =>
    have present : (plan cursor mode observations).1 ≠ none := by rw [origin]; simp
    have terminal : ∀ request, (plan cursor mode observations).2 ≠ .tuple [a "observe", request] := by
      rw [origin]; simp [a]
    obtain ⟨result, rest, call, complete, accepted⟩ := plan_terminal_call present terminal
    refine ⟨observations, result, rest, call, complete, ?_⟩
    rw [← accepted, origin]
    exact .run tail
  | resume tail ih =>
    have captured := plan_observation_capture origin
    subst captured
    exact ih present terminal (plan_resume_captured _ _ _ _).symm

theorem plan_trace_call {cursor : Cursor} {mode : Term} {observations : List Term}
    {final : PendingRevision.Cursor} {outcome : Term}
    (trace : PlanTrace (plan cursor mode observations) (planned final outcome)) :
    ∃ journal result rest, Command.revisionPlan cursor.candidate.working mode journal = .ok (result, rest) ∧
      settled rest = true ∧ PlanTrace (acceptPlan cursor mode result) (planned final outcome) :=
  plan_trace_terminal_call trace (by simp [planned]) (by simp [planned, a])

theorem plan_batch_not_unchanged {outcome saved other : Term}
    (valid : PlanBatchOutput outcome (some saved, .tuple [a "planned", .tuple [other, Term.bool false]])) : False := by
  generalize same : (some saved, Term.tuple [a "planned", .tuple [other, Term.bool false]]) = output at valid
  cases valid with
  | done => simp [planned, Term.bool, a] at same
  | run => simp [a] at same
  | resume => simp [a] at same
  | failed => cases congrArg Prod.fst same

theorem stage_plan_unchanged {cursor : Cursor} {events : List Term} {hwm outcome saved other : Term}
    (trace : PlanTrace (stagePlan cursor events hwm outcome)
      (some saved, .tuple [a "planned", .tuple [other, Term.bool false]])) : saved = cursor.pack := by
  unfold stagePlan at trace
  split at trace
  · have same := trace.fixed (by simp [a]) (by simp [a])
    exact Option.some.inj (congrArg Prod.fst same)
  · exact (plan_batch_not_unchanged
      (plan_batch_output_preserved trace (plan_batch_start_valid _ _ _ _))).elim

theorem accept_plan_unchanged {cursor : Cursor} {mode result saved outcome : Term}
    (trace : PlanTrace (acceptPlan cursor mode result)
      (some saved, .tuple [a "planned", .tuple [outcome, Term.bool false]])) : saved = cursor.pack := by
  unfold acceptPlan at trace
  split at trace
  · exact Option.some.inj (congrArg Prod.fst (trace.fixed (by simp [a]) (by simp [a])))
  · exact Option.some.inj (congrArg Prod.fst (trace.fixed (by simp [a]) (by simp [a])))
  · split at trace
    · exact stage_plan_unchanged trace
    · have impossible := trace.fixed (by simp [invalid, a]) (by simp [invalid, a])
      cases congrArg Prod.fst impossible
  · split at trace
    · have impossible := trace.fixed (by simp [invalid, a]) (by simp [invalid, a])
      cases congrArg Prod.fst impossible
    · exact stage_plan_unchanged trace
  · have impossible := trace.fixed (by simp [invalid, a]) (by simp [invalid, a])
    cases congrArg Prod.fst impossible

/-- An unchanged result returns the exact original revision, including its pending or fresh state. -/
theorem plan_unchanged_captured {cursor : Cursor} {mode saved outcome : Term} {observations : List Term}
    (trace : PlanTrace
      (resident (some cursor.pack) (a "plan") (.tuple [mode, list observations]))
      (some saved, .tuple [a "planned", .tuple [outcome, Term.bool false]])) : saved = cursor.pack := by
  rw [plan_captured] at trace
  obtain ⟨_, _, _, _, _, execution⟩ := plan_trace_terminal_call trace (by simp) (by simp [a])
  exact accept_plan_unchanged execution

/-- A changed fast plan derives both the planner call and its matched native write from one public trace. -/
theorem fast_plan_write {cursor : Cursor} {observations : List Term}
    {final : PendingRevision.Cursor} {outcome : Term}
    (trace : PlanTrace
      (resident (some cursor.pack) (a "plan") (.tuple [a "fast", list observations]))
      (planned final outcome)) :
    ∃ events hwm wake before after,
      StateQuery.materialize cursor.candidate.working 100 before =
        .ok (.tuple [list events, Term.bool wake, hwm], after) ∧
      PendingRevision.Execution
        (PendingRevision.resident (some cursor.candidate.pack) (a "write") (.tuple [list events, hwm])) final := by
  rw [plan_captured] at trace
  obtain ⟨journal, result, rest, call, _, execution⟩ := plan_trace_call trace
  change Command.activationFast cursor.candidate.working journal = .ok (result, rest) at call
  unfold acceptPlan at execution
  split at execution
  · have impossible := execution.fixed (by simp [a]) (by simp [a])
    simp [planned, a, Term.bool] at impossible
  · have impossible := execution.fixed (by simp [a]) (by simp [a])
    simp [planned, a, Term.bool] at impossible
  · simp only [show (a "fast" == a "fast") = true from rfl, ↓reduceIte] at execution
    obtain ⟨_, written⟩ := stage_plan_raw_executes execution
    obtain ⟨wake, before, after, materialized⟩ := fast_plan_materializes call
    exact ⟨_, _, wake, before, after, materialized, written⟩
  · simp only [show (a "fast" == a "fast") = true from rfl, ↓reduceIte] at execution
    have impossible := execution.fixed (by simp [invalid, a]) (by simp [invalid, a])
    cases congrArg Prod.fst impossible
  · have impossible := execution.fixed (by simp [invalid, a]) (by simp [invalid, a])
    cases congrArg Prod.fst impossible

theorem fast_plan_preserves {cursor : Cursor} {observations : List Term}
    {final : PendingRevision.Cursor} {outcome : Term}
    (ready : QueueReady cursor.candidate.working)
    (trace : PlanTrace
      (resident (some cursor.pack) (a "plan") (.tuple [a "fast", list observations]))
      (planned final outcome)) :
    final.baseline = cursor.candidate.baseline ∧ final.etag = cursor.candidate.etag ∧
      QueueReady final.working ∧
      final.working.get (a "storage_format") = cursor.candidate.working.get (a "storage_format") ∧
      ∀ sealed item, ValueSemantics.Represented cursor.candidate.working sealed item →
        ValueSemantics.Represented final.working sealed item := by
  obtain ⟨_, _, _, _, _, materialized, written⟩ := fast_plan_write trace
  obtain ⟨baselineEq, etagEq, _, _, finalReady, formatEq, preserved⟩ :=
    PendingRevision.materialize_write_preserves ready materialized written
  exact ⟨baselineEq, etagEq, finalReady, formatEq, preserved⟩

theorem ordinary_plan_write {cursor : Cursor} {observations : List Term} {mode outcome : Term}
    {final : PendingRevision.Cursor}
    (ordinary : mode = a "run" ∨ mode = a "until_wake")
    (trace : PlanTrace
      (resident (some cursor.pack) (a "plan") (.tuple [mode, list observations]))
      (planned final outcome)) :
    ∃ events hwm wake before after,
      StateQuery.materialize cursor.candidate.working 100 before =
        .ok (.tuple [list events, Term.bool wake, hwm], after) ∧
      PendingRevision.Execution
        (PendingRevision.resident (some cursor.candidate.pack) (a "write") (.tuple [list events, hwm])) final := by
  rw [plan_captured] at trace
  obtain ⟨journal, result, rest, call, _, execution⟩ := plan_trace_call trace
  have callEq : Command.revisionPlan cursor.candidate.working mode =
      Command.materializationPlan cursor.candidate.working (.tuple [list [], mode]) := by
    rcases ordinary with rfl | rfl <;> rfl
  have notFast : (mode == a "fast") = false := by
    rcases ordinary with rfl | rfl <;> rfl
  rw [callEq] at call
  unfold acceptPlan at execution
  split at execution
  · have impossible := execution.fixed (by simp [a]) (by simp [a])
    simp [planned, a, Term.bool] at impossible
  · have impossible := execution.fixed (by simp [a]) (by simp [a])
    simp [planned, a, Term.bool] at impossible
  · simp only [notFast, Bool.false_eq_true, ↓reduceIte] at execution
    have impossible := execution.fixed (by simp [invalid, a]) (by simp [invalid, a])
    cases congrArg Prod.fst impossible
  · simp only [notFast, Bool.false_eq_true, ↓reduceIte] at execution
    obtain ⟨_, written⟩ := stage_plan_raw_executes execution
    obtain ⟨wake, before, after, materialized⟩ := ordinary_plan_materializes call
    exact ⟨_, _, wake, before, after, materialized, written⟩
  · have impossible := execution.fixed (by simp [invalid, a]) (by simp [invalid, a])
    cases congrArg Prod.fst impossible

theorem ordinary_plan_preserves {cursor : Cursor} {observations : List Term} {mode outcome : Term}
    {final : PendingRevision.Cursor}
    (ordinary : mode = a "run" ∨ mode = a "until_wake")
    (ready : QueueReady cursor.candidate.working)
    (trace : PlanTrace
      (resident (some cursor.pack) (a "plan") (.tuple [mode, list observations]))
      (planned final outcome)) :
    final.baseline = cursor.candidate.baseline ∧ final.etag = cursor.candidate.etag ∧
      QueueReady final.working ∧
      final.working.get (a "storage_format") = cursor.candidate.working.get (a "storage_format") ∧
      ∀ sealed item, ValueSemantics.Represented cursor.candidate.working sealed item →
        ValueSemantics.Represented final.working sealed item := by
  obtain ⟨_, _, _, _, _, materialized, written⟩ := ordinary_plan_write ordinary trace
  obtain ⟨baselineEq, etagEq, _, _, finalReady, formatEq, preserved⟩ :=
    PendingRevision.materialize_write_preserves ready materialized written
  exact ⟨baselineEq, etagEq, finalReady, formatEq, preserved⟩

end VerifiedKernel.Session.Revision

namespace VerifiedKernel.Session.RevisionFence
open Data WorkConservation
set_option Elab.async false

/-- The public planning trace, pending revision, and native CAS share the same materialized candidate. -/
theorem planned_snapshot_preserves {cursor : Revision.Cursor} {staged : PendingRevision.Cursor}
    {mode outcome key preparedState stamped token reasons activity revision flush epoch node
      saved request result restored etag : Term}
    {planningObservations observations : List Term} {durable : ArchivePublication.HotSnapshots}
    (supported : mode = a "fast" ∨ mode = a "run" ∨ mode = a "until_wake")
    (ready : QueueReady cursor.candidate.working) (format : cursor.candidate.working.get (a "storage_format") = i 3)
    (trace : Revision.PlanTrace
      (Revision.resident (some cursor.pack) (a "plan") (.tuple [mode, list planningObservations]))
      (Revision.planned staged outcome))
    (preparation : Preparation staged key
      (resident (some staged.pack) (a "start") (.tuple [key, list observations])) preparedState)
    (metadata : MetadataExecution staged key
      (resident (some (prepared staged key preparedState)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) stamped)
    (encoded : resident (some (.tuple [a "session_fence_stamped", staged.pack, key, stamped]))
      (a "encode") nil = (some saved, request))
    (primitive : ArchivePublication.SnapshotCASMeaning request result durable)
    (resumed : resident (some saved) (a "cas_result") result = (some restored, .tuple [a "ok", etag])) :
    staged.baseline = cursor.candidate.baseline ∧ staged.etag = cursor.candidate.etag ∧ restored = stamped ∧
      ∃ snapshot, durable key etag snapshot ∧ QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
        ∀ sealed item, ValueSemantics.Represented cursor.candidate.working sealed item →
          ValueSemantics.Represented snapshot sealed item := by
  have preservation : staged.baseline = cursor.candidate.baseline ∧ staged.etag = cursor.candidate.etag ∧
      QueueReady staged.working ∧
      staged.working.get (a "storage_format") = cursor.candidate.working.get (a "storage_format") ∧
      ∀ sealed item, ValueSemantics.Represented cursor.candidate.working sealed item →
        ValueSemantics.Represented staged.working sealed item := by
    rcases supported with fast | ordinary
    · subst mode
      exact Revision.fast_plan_preserves ready trace
    · exact Revision.ordinary_plan_preserves ordinary ready trace
  obtain ⟨baselineEq, etagEq, stagedReady, stagedFormat, preserved⟩ := preservation
  obtain ⟨restoredEq, snapshot, committed, snapshotReady, snapshotFormat, kept⟩ :=
    candidate_preserves stagedReady (stagedFormat.trans format) preparation metadata encoded primitive resumed
  exact ⟨baselineEq, etagEq, restoredEq, snapshot, committed, snapshotReady, snapshotFormat,
    fun sealed item present => kept sealed item (preserved sealed item present)⟩

end VerifiedKernel.Session.RevisionFence
