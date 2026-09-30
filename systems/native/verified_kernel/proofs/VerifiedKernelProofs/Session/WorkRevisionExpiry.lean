import VerifiedKernelProofs.Session.WorkQueueDeterminism

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

/-- The kernel selects either no timeout or a canonical input for this session. -/
theorem wait_timeout_shape {state args event : Term} {journal rest : List Term}
    (call : Command.waitTimeout state args journal = .ok (event, rest)) :
    event = nil ∨ Routed (state.get (a "session_id")) event ∧ event.get (b "type") = b "queue_append" := by
  unfold Command.waitTimeout at call
  repeat' first
    | (exact (fail_ok call).elim)
    | (have same := pure_ok call; subst event
       simp +decide [Routed, BinaryKeys, Term.get,
         b, Term.text, Term.isBinary])
    | (obtain ⟨value, _, read, call⟩ := bind_ok call
       try (have same := field_value read; subst value))
    | split at call
    | dsimp only at call

theorem wait_timeout_input {state args event : Term} {journal rest : List Term}
    (call : Command.waitTimeout state args journal = .ok (event, rest)) :
    event = nil ∨ BinaryKeys event ∧ Command.inputEventAllowed event = true := by
  rcases wait_timeout_shape call with absent | ⟨routed, kind⟩
  · exact Or.inl absent
  · exact Or.inr ⟨routed.1, by simp +decide [Command.inputEventAllowed, kind]⟩

theorem activity_frame_symm {s t : Term} (frame : ActivityFrame s t) : ActivityFrame t s :=
  fun key status time => (frame key status time).symm

/-- The projection and native reducer agree before activity classification. -/
theorem projected_queue_frame {state event projected actual : Term} {journal rest observations : List Term}
    (ready : QueueReady state)
    (routed : Routed (state.get (a "session_id")) event)
    (kind : event.get (b "type") = b "queue_append")
    (projection : Command.project state [event] journal = .ok (projected, rest))
    (execution : ResidentTrace (runTrusted state event observations) (.tuple [a "done", actual])) :
    ActivityFrame projected actual := by
  unfold Command.project at projection
  rw [List.foldlM_cons] at projection
  obtain ⟨view, _, projectStep, finished⟩ := bind_ok projection
  have same := pure_ok finished
  subst projected
  obtain ⟨⟨reduced, normalized⟩, _, prepared, projectActivity⟩ := bind_ok projectStep
  obtain ⟨actualReduced, actualNormalized, j, r, actualPrepared, actualActivity⟩ := resident_execution_step execution
  cases normalized with
  | none => exact (prepareTrusted_canonical_not_skipped routed.1 routed.2 prepared).elim
  | some normalized =>
    obtain ⟨_, read, _, call⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys routed.1 read
    subst normalized
    cases actualNormalized with
    | none => exact (prepareTrusted_canonical_not_skipped routed.1 routed.2 actualPrepared).elim
    | some actualNormalized =>
      obtain ⟨_, actualRead, _, actualCall⟩ := prepareTrusted_stringify actualPrepared
      have same := shallowStringify_binary_keys routed.1 actualRead
      subst actualNormalized
      simp +decide [inner, kind] at call actualCall
      have same := queue_append_same_results ready.1 call actualCall
      subst actualReduced
      exact activity_frame_trans (activity_frame_symm (afterEvent_activity_frame projectActivity)) actualActivity

theorem wait_prefix_preserves {state expired projected actual : Term}
    {journal rest before after : List Term}
    (ready : QueueReady state)
    (timeout : Command.waitTimeout state nil journal = .ok (expired, rest))
    (projection : Command.project state (if expired == nil then [] else [expired]) before = .ok (projected, after))
    (execution : ResidentBatch state (if expired == nil then [] else [expired]) actual) :
    QueueReady actual ∧ ActivityFrame projected actual ∧
      ∀ sealed item, ValueSemantics.Represented state sealed item → ValueSemantics.Represented actual sealed item := by
  by_cases missing : (expired == nil) = true
  · simp only [missing, ↓reduceIte] at execution projection
    cases execution
    have same := pure_ok projection
    subst projected
    exact ⟨ready, activity_frame_refl _, fun _ _ present => present⟩
  · simp only [missing, ↓reduceIte] at execution projection
    obtain ⟨routed, kind⟩ := (wait_timeout_shape timeout).resolve_left (by
      intro same; subst expired; exact missing rfl)
    have allowed : Command.inputEventAllowed expired = true := by simp +decide [Command.inputEventAllowed, kind]
    have canonical : ∀ event ∈ [expired], BinaryKeys event := by simpa using routed.1
    have admitted : ∀ event ∈ [expired], Command.inputEventAllowed event = true := by simpa using allowed
    have safe := resident_batch_input_safety execution ready canonical admitted
    refine ⟨safe.1, ?_, fun _ _ present => ValueSemantics.resident_input_preserves execution ready canonical admitted present⟩
    cases execution with
    | cons head tail =>
      cases tail
      exact projected_queue_frame ready routed kind projection head

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.Revision
open Data WorkConservation
set_option Elab.async false

theorem prefixed_plan_materializes {state mode result : Term} {leadingEvents journal rest : List Term}
    (call : Command.materializationPlan state (.tuple [list leadingEvents, mode]) journal = .ok (result, rest)) :
    ∃ projected events wake hwm outcome j₁ j₂,
      Command.project state leadingEvents journal = .ok (projected, j₁) ∧
      StateQuery.materialize projected 100 j₁ = .ok (.tuple [list events, Term.bool wake, hwm], j₂) ∧
      result = .tuple [list (leadingEvents ++ events), hwm, outcome] := by
  unfold Command.materializationPlan at call
  obtain ⟨leading, _, leadingRead, call⟩ := bind_ok call
  obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Except.ok.inj leadingRead)
  obtain ⟨projected, j₁, projectedCall, call⟩ := bind_ok call
  obtain ⟨generated, j₂, materialized, call⟩ := bind_ok call
  obtain ⟨_, _, _, _, _, events, wake, hwm, _, _, _, _, _, shape, _, _⟩ :=
    materialize_batch_has_records materialized
  rw [shape] at materialized call
  obtain ⟨leading, _, leadingRead, call⟩ := bind_ok call
  have same : leading = leadingEvents := pure_ok leadingRead
  subst leading
  obtain ⟨batch, _, batchRead, call⟩ := bind_ok call
  have same : batch = events := pure_ok batchRead
  subst batch
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨outcome, _, _, call⟩ := bind_ok call
  exact ⟨projected, events, wake, hwm, outcome, j₁, j₂, projectedCall, materialized, pure_ok call⟩

/-- Timeout planning derives its control prefix and materialization call from the command itself. -/
theorem expiry_plan_materializes {state result : Term} {journal rest : List Term}
    (call : Command.revisionPlan state (a "expire") journal = .ok (result, rest)) :
    ∃ expired projected events wake hwm outcome before j₁ j₂,
      Command.waitTimeout state nil journal = .ok (expired, before) ∧
      Command.project state (if expired == nil then [] else [expired]) before = .ok (projected, j₁) ∧
      StateQuery.materialize projected 100 j₁ = .ok (.tuple [list events, Term.bool wake, hwm], j₂) ∧
      result = .tuple [list ((if expired == nil then [] else [expired]) ++ events), hwm, outcome] := by
  simp +decide only [Command.revisionPlan, a, ↓reduceIte] at call
  obtain ⟨expired, before, timeout, call⟩ := bind_ok call
  obtain ⟨projected, events, wake, hwm, outcome, j₁, j₂, projectedCall, materialized, same⟩ :=
    prefixed_plan_materializes call
  exact ⟨expired, projected, events, wake, hwm, outcome, before, j₁, j₂, timeout, projectedCall, materialized, same⟩

theorem expiry_plan_preserves {cursor : Cursor} {observations : List Term}
    {final : PendingRevision.Cursor} {outcome : Term}
    (ready : QueueReady cursor.candidate.working)
    (trace : PlanTrace
      (resident (some cursor.pack) (a "plan") (.tuple [a "expire", list observations]))
      (planned final outcome)) :
    final.baseline = cursor.candidate.baseline ∧ final.etag = cursor.candidate.etag ∧
      QueueReady final.working ∧
      final.working.get (a "storage_format") = cursor.candidate.working.get (a "storage_format") ∧
      ∀ sealed item, ValueSemantics.Represented cursor.candidate.working sealed item →
        ValueSemantics.Represented final.working sealed item := by
  rw [plan_captured] at trace
  obtain ⟨journal, result, rest, call, _, execution⟩ := plan_trace_call trace
  obtain ⟨expired, projected, events, wake, hwm, plannedOutcome, before, j₁, j₂,
    timeout, projectedCall, materialized, same⟩ := expiry_plan_materializes call
  rw [same] at execution
  simp +decide only [acceptPlan, a, ↓reduceIte] at execution
  obtain ⟨_, written⟩ := stage_plan_raw_executes execution
  obtain ⟨_, _, baselineEq, etagEq, _, _, applied⟩ := PendingRevision.write_executes written
  obtain ⟨materializedState, workBatch, metadataBatch⟩ := resident_batch_append applied
  obtain ⟨prefixState, prefixBatch, materializedBatch⟩ := resident_batch_append workBatch
  obtain ⟨prefixReady, frame, prefixKept⟩ := wait_prefix_preserves ready timeout projectedCall prefixBatch
  have materializedWork := materialize_framed_work prefixReady
    (frame "input_queue" (by decide) (by decide)).symm
    (frame "queue_ack_id" (by decide) (by decide)).symm
    (frame "session_id" (by decide) (by decide)) materialized materializedBatch
  obtain ⟨keys, metadata⟩ := PendingRevision.hwm_metadata hwm
  obtain ⟨finalReady, _, metadataKept⟩ := ValueSemantics.metadata_work metadataBatch keys metadata materializedWork.1
  exact ⟨baselineEq, etagEq, finalReady, resident_batch_format applied,
    fun sealed item present => metadataKept sealed item (materializedWork.2 sealed item (prefixKept sealed item present))⟩

end VerifiedKernel.Session.Revision

namespace VerifiedKernel.Session.Revision
open Data WorkConservation

theorem successful_plan_mode {state mode result : Term} {journal rest : List Term}
    (call : Command.revisionPlan state mode journal = .ok (result, rest)) :
    mode = a "fast" ∨ mode = a "expire" ∨ mode = a "run" ∨ mode = a "until_wake" := by
  unfold Command.revisionPlan at call
  split at call
  · rename_i fast
    exact Or.inl (atom_beq_true fast)
  · split at call
    · rename_i expire
      exact Or.inr (Or.inl (atom_beq_true expire))
    · split at call
      · rename_i ordinary
        simp only [Bool.or_eq_true] at ordinary
        rcases ordinary with run | untilWake
        · exact Or.inr (Or.inr (Or.inl (atom_beq_true run)))
        · exact Or.inr (Or.inr (Or.inr (atom_beq_true untilWake)))
      · exact (fail_ok call).elim

/-- Every changed native plan preserves work. The actual command determines its mode. -/
theorem plan_preserves {cursor : Cursor} {mode outcome : Term} {observations : List Term}
    {final : PendingRevision.Cursor}
    (ready : QueueReady cursor.candidate.working)
    (trace : PlanTrace
      (resident (some cursor.pack) (a "plan") (.tuple [mode, list observations]))
      (planned final outcome)) :
    final.baseline = cursor.candidate.baseline ∧ final.etag = cursor.candidate.etag ∧
      QueueReady final.working ∧
      final.working.get (a "storage_format") = cursor.candidate.working.get (a "storage_format") ∧
      ∀ sealed item, ValueSemantics.Represented cursor.candidate.working sealed item →
        ValueSemantics.Represented final.working sealed item := by
  have queryTrace := trace
  rw [plan_captured] at queryTrace
  obtain ⟨_, _, _, call, _, _⟩ := plan_trace_call queryTrace
  rcases successful_plan_mode call with fast | expire | ordinary
  · subst mode; exact fast_plan_preserves ready trace
  · subst mode; exact expiry_plan_preserves ready trace
  · exact ordinary_plan_preserves ordinary ready trace

end VerifiedKernel.Session.Revision

namespace VerifiedKernel.Session.RevisionFence
open Data WorkConservation
set_option Elab.async false

/-- All native plan modes retain accepted work in the snapshot acknowledged by CAS. -/
theorem any_planned_snapshot_preserves {cursor : Revision.Cursor} {staged : PendingRevision.Cursor}
    {mode outcome key preparedState stamped token reasons activity revision flush epoch node
      saved request result restored etag : Term}
    {planningObservations observations : List Term} {durable : ArchivePublication.HotSnapshots}
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
  obtain ⟨baselineEq, etagEq, stagedReady, stagedFormat, preserved⟩ := Revision.plan_preserves ready trace
  obtain ⟨restoredEq, snapshot, committed, snapshotReady, snapshotFormat, kept⟩ :=
    candidate_preserves stagedReady (stagedFormat.trans format) preparation metadata encoded primitive resumed
  exact ⟨baselineEq, etagEq, restoredEq, snapshot, committed, snapshotReady, snapshotFormat,
    fun sealed item present => kept sealed item (preserved sealed item present)⟩

end VerifiedKernel.Session.RevisionFence
