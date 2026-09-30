import VerifiedKernelProofs.Session.WorkPendingMaterialize
import VerifiedKernelProofs.Session.WorkRevision

namespace VerifiedKernel.Session.Revision
open Data WorkConservation
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem plan_captured (cursor : Cursor) (mode : Term) (observations : List Term) :
    resident (some cursor.pack) (a "plan") (.tuple [mode, list observations]) =
      plan cursor mode observations := by
  cases cursor <;> rfl

theorem plan_resume_captured (cursor : Cursor) (mode observation : Term) (observations : List Term) :
    resident (some (.tuple [a "session_revision_plan", cursor.pack, mode, list observations]))
      (a "resume") observation = plan cursor mode (observations ++ [observation]) := by
  cases cursor <;> rfl

theorem plan_batch_captured (outcome batch operation args : Term)
    (allowed : operation = a "run" ∨ operation = a "resume") :
    resident (some (.tuple [a "session_revision_plan_batch", outcome, batch])) operation args =
      acceptPlanBatch outcome (PendingRevision.resident (some batch) operation args) := by
  rcases allowed with rfl | rfl <;> rfl

theorem plan_batch_sealed (outcome batch args : Term) :
    resident (some (.tuple [a "session_revision_plan_batch", outcome, batch])) (a "write") args = invalid ∧
      resident (some (.tuple [a "session_revision_plan_batch", outcome, batch])) (a "working") args = invalid ∧
      resident (some (.tuple [a "session_revision_plan_batch", outcome, batch])) (a "plan") args = invalid := by
  exact ⟨rfl, rfl, rfl⟩

def planned (cursor : PendingRevision.Cursor) (outcome : Term) : Output :=
  (some cursor.pack, .tuple [a "planned", .tuple [outcome, Term.bool true]])

inductive PlanBatchTrace (outcome : Term) : Output → PendingRevision.Cursor → Prop where
  | done (cursor : PendingRevision.Cursor) : PlanBatchTrace outcome (planned cursor outcome) cursor
  | run {cursor : PendingRevision.Cursor} {state event : Term} {remaining observations : List Term}
      {final : PendingRevision.Cursor}
      (tail : PlanBatchTrace outcome
        (resident (some (.tuple [a "session_revision_plan_batch", outcome,
          .tuple [a "session_pending_batch", cursor.pack, BatchExecution.pending state (event :: remaining)]]))
          (a "run") (list observations)) final) :
      PlanBatchTrace outcome
        (some (.tuple [a "session_revision_plan_batch", outcome,
          .tuple [a "session_pending_batch", cursor.pack, BatchExecution.pending state (event :: remaining)]]),
          .tuple [a "next"]) final
  | resume {cursor : PendingRevision.Cursor} {token request observation : Term} {remaining : List Term}
      {final : PendingRevision.Cursor}
      (tail : PlanBatchTrace outcome
        (resident (some (.tuple [a "session_revision_plan_batch", outcome,
          .tuple [a "session_pending_batch", cursor.pack, BatchExecution.observing token remaining]]))
          (a "resume") observation) final) :
      PlanBatchTrace outcome
        (some (.tuple [a "session_revision_plan_batch", outcome,
          .tuple [a "session_pending_batch", cursor.pack, BatchExecution.observing token remaining]]),
          .tuple [a "observe", request]) final

theorem accept_plan_done {outcome : Term} {inner : Output} {final : PendingRevision.Cursor}
    (h : acceptPlanBatch outcome inner = planned final outcome) :
    inner = (some final.pack, .tuple [a "done"]) := by
  unfold acceptPlanBatch at h
  split at h
  · have same := Option.some.inj (congrArg Prod.fst h)
    rw [same]
  · simp [planned, PendingRevision.Cursor.pack, a] at h
  · cases congrArg Prod.fst h

theorem accept_plan_batch {outcome batch response : Term} {inner : Output}
    (notDone : response ≠ .tuple [a "planned", .tuple [outcome, Term.bool true]])
    (h : acceptPlanBatch outcome inner =
      (some (.tuple [a "session_revision_plan_batch", outcome, batch]), response)) :
    inner = (some batch, response) := by
  unfold acceptPlanBatch at h
  split at h
  · exact (notDone (congrArg Prod.snd h).symm).elim
  · simp only [Prod.mk.injEq, Option.some.injEq, Term.tuple.injEq, List.cons.injEq,
      and_true, true_and] at h
    obtain ⟨rfl, rfl⟩ := h
    rfl
  · cases congrArg Prod.fst h

theorem plan_batch_reflect {outcome : Term} {inner : Output} {final : PendingRevision.Cursor}
    (trace : PlanBatchTrace outcome (acceptPlanBatch outcome inner) final) :
    PendingRevision.Execution inner final := by
  generalize origin : acceptPlanBatch outcome inner = output at trace
  induction trace generalizing inner with
  | done cursor =>
    rw [accept_plan_done origin]
    exact .done cursor
  | @run cursor state event remaining observations final tail ih =>
    rw [accept_plan_batch (by simp [a]) origin]
    apply PendingRevision.Execution.run (observations := observations)
    apply ih
    rw [plan_batch_captured _ _ _ _ (Or.inl rfl)]
  | @resume cursor token request observation remaining final tail ih =>
    rw [accept_plan_batch (by simp [a]) origin]
    apply PendingRevision.Execution.resume (observation := observation)
    apply ih
    rw [plan_batch_captured _ _ _ _ (Or.inr rfl)]

theorem PlanBatchTrace.not_unchanged {outcome saved : Term} {output : Output} {final : PendingRevision.Cursor}
    (trace : PlanBatchTrace outcome output final) :
    output ≠ (some saved, .tuple [a "planned", .tuple [outcome, Term.bool false]]) := by
  intro same
  cases trace <;> simp [planned, a, Term.bool] at same

theorem stage_plan_executes {cursor : Cursor} {events : List Term} {hwm outcome : Term}
    {final : PendingRevision.Cursor}
    (trace : PlanBatchTrace outcome (stagePlan cursor events hwm outcome) final) :
    PendingRevision.Execution
      (PendingRevision.resident (some cursor.candidate.pack) (a "write") (.tuple [list events, hwm])) final := by
  unfold stagePlan at trace
  split at trace
  · exact (trace.not_unchanged rfl).elim
  · exact plan_batch_reflect trace

inductive PlanObservationTrace : Output → Output → Prop where
  | done (output : Output) : PlanObservationTrace output output
  | resume {saved request observation : Term} {final : Output}
      (tail : PlanObservationTrace (resident (some saved) (a "resume") observation) final) :
      PlanObservationTrace (some saved, .tuple [a "observe", request]) final

theorem stage_plan_not_observe (cursor : Cursor) (events : List Term) (hwm outcome request : Term) :
    (stagePlan cursor events hwm outcome).2 ≠ .tuple [a "observe", request] := by
  unfold stagePlan
  split
  · simp [a]
  · unfold PendingRevision.write
    split
    · cases events with
      | nil => simp_all
      | cons event remaining =>
        simp [PendingRevision.accept, BatchExecution.next, acceptPlanBatch, a]
    · simp [acceptPlanBatch, a]
    · simp [acceptPlanBatch, a]

theorem accept_plan_not_observe (cursor : Cursor) (mode result request : Term) :
    (acceptPlan cursor mode result).2 ≠ .tuple [a "observe", request] := by
  unfold acceptPlan
  split
  · simp [a]
  · simp [a]
  · split
    · exact stage_plan_not_observe _ _ _ _ _
    · simp [invalid, a]
  · split
    · simp [invalid, a]
    · exact stage_plan_not_observe _ _ _ _ _
  · simp [invalid, a]

theorem plan_observation_capture {cursor : Cursor} {mode saved request : Term} {observations : List Term}
    (h : plan cursor mode observations = (some saved, .tuple [a "observe", request])) :
    saved = .tuple [a "session_revision_plan", cursor.pack, mode, list observations] := by
  unfold plan at h
  split at h
  · split at h
    · exact (accept_plan_not_observe _ _ _ _ (congrArg Prod.snd h)).elim
    · cases congrArg Prod.fst h
  · exact (Option.some.inj (congrArg Prod.fst h)).symm
  · cases congrArg Prod.fst h

theorem plan_terminal_call {cursor : Cursor} {mode : Term} {observations : List Term}
    (present : (plan cursor mode observations).1 ≠ none)
    (terminal : ∀ request, (plan cursor mode observations).2 ≠ .tuple [a "observe", request]) :
    ∃ result rest, Command.revisionPlan cursor.candidate.working mode observations = .ok (result, rest) ∧
      settled rest = true ∧ plan cursor mode observations = acceptPlan cursor mode result := by
  unfold plan at present terminal ⊢
  split at present
  · rename_i result rest call
    split at present
    · rename_i complete
      exact ⟨result, rest, call, complete, by simp [complete]⟩
    · exact (present rfl).elim
  · rename_i request call
    simp only [call] at terminal
    exact (terminal request rfl).elim
  · exact (present rfl).elim

theorem plan_observations_call {cursor : Cursor} {mode : Term} {observations : List Term} {final : Output}
    (trace : PlanObservationTrace (plan cursor mode observations) final)
    (present : final.1 ≠ none)
    (terminal : ∀ request, final.2 ≠ .tuple [a "observe", request]) :
    ∃ journal result rest, Command.revisionPlan cursor.candidate.working mode journal = .ok (result, rest) ∧
      settled rest = true ∧ final = acceptPlan cursor mode result := by
  generalize origin : plan cursor mode observations = output at trace
  induction trace generalizing observations with
  | done output =>
    subst output
    obtain ⟨result, rest, call, complete, accepted⟩ := plan_terminal_call present terminal
    exact ⟨observations, result, rest, call, complete, accepted⟩
  | resume tail ih =>
    have captured := plan_observation_capture origin
    subst captured
    exact ih present terminal (plan_resume_captured _ _ _ _).symm

/-- A successful fast activation returns the events from its actual materialization call. -/
theorem fast_plan_materializes {s hwm : Term} {events j r : List Term}
    (h : Command.activationFast s j = .ok (.tuple [a "activate", list events, hwm], r)) :
    ∃ wake before after, StateQuery.materialize s 100 before =
      .ok (.tuple [list events, Term.bool wake, hwm], after) := by
  unfold Command.activationFast at h
  repeat' first
    | (have impossible := pure_ok h; simp [a] at impossible)
    | (fail_if_success (bind_head_is h [StateQuery.materialize]; change (StateQuery.materialize s 100 >>= _) _ = _ at h)
       obtain ⟨_, _, _, h⟩ := bind_ok h)
    | split at h
    | dsimp only at h
  obtain ⟨result, after, materialized, h⟩ := bind_ok h
  obtain ⟨_, _, _, _, _, generated, wake, nextHwm, _, _, _, _, _, shape, _, _⟩ :=
    materialize_batch_has_records materialized
  rw [shape] at materialized h
  have same : events = generated ∧ hwm = nextHwm := by
    repeat' first
      | (have result := pure_ok h
         simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and, list, Term.list.injEq] using result)
      | (obtain ⟨_, _, _, h⟩ := bind_ok h)
      | split at h
      | (exact (fail_ok h).elim)
      | (have impossible := pure_ok h; simp [a] at impossible)
      | dsimp only at h
  obtain ⟨rfl, rfl⟩ := same
  exact ⟨wake, _, after, materialized⟩

theorem ordinary_plan_materializes {s mode hwm outcome : Term} {events j r : List Term}
    (h : Command.materializationPlan s (.tuple [list [], mode]) j =
      .ok (.tuple [list events, hwm, outcome], r)) :
    ∃ wake before after, StateQuery.materialize s 100 before =
      .ok (.tuple [list events, Term.bool wake, hwm], after) := by
  unfold Command.materializationPlan at h
  obtain ⟨leading, _, leadingRead, h⟩ := bind_ok h
  have leadingEq : leading = [] := pure_ok leadingRead
  subst leading
  obtain ⟨state, _, projected, h⟩ := bind_ok h
  have stateEq : state = s := pure_ok projected
  subst state
  obtain ⟨result, after, materialized, h⟩ := bind_ok h
  obtain ⟨_, _, _, _, _, generated, wake, nextHwm, _, _, _, _, _, shape, _, _⟩ :=
    materialize_batch_has_records materialized
  rw [shape] at materialized h
  obtain ⟨leading, _, leadingRead, h⟩ := bind_ok h
  have leadingEq : leading = [] := pure_ok leadingRead
  subst leading
  obtain ⟨batch, _, batchRead, h⟩ := bind_ok h
  have batchEq : batch = generated := pure_ok batchRead
  subst batch
  iterate 2 obtain ⟨_, _, _, h⟩ := bind_ok h
  have same : events = generated ∧ hwm = nextHwm := by
    have result := pure_ok h
    simp only [List.nil_append, Term.tuple.injEq, List.cons.injEq, and_true, list, Term.list.injEq] at result
    exact ⟨result.1, result.2.1⟩
  obtain ⟨rfl, rfl⟩ := same
  exact ⟨wake, _, after, materialized⟩

end VerifiedKernel.Session.Revision
