import VerifiedKernelProofs.Session.WorkPhysicalHistory

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

theorem PhysicalHistory.wait_prefix {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {state expired next : Term} {sealed journal rest : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (timeout : Command.waitTimeout state nil journal = .ok (expired, rest))
    (execution : ResidentBatch state (if expired == nil then [] else [expired]) next) :
    PhysicalHistory framing objects owner session next sealed := by
  by_cases missing : (expired == nil) = true
  · simp only [missing, ↓reduceIte] at execution
    cases execution
    exact history
  · simp only [missing, ↓reduceIte] at execution
    obtain ⟨canonical, allowed⟩ := (wait_timeout_input timeout).resolve_left (by
      intro same; subst expired; exact missing rfl)
    exact history.admitted execution (by simpa using canonical) (by simpa using allowed)

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.PendingRevision
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem materialize_write_physical_history {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {cursor final : Cursor} {events journal rest sealed : List Term} {limit : Int} {wake : Bool} {hwm : Term}
    (history : PhysicalHistory framing objects owner session cursor.working sealed)
    (planned : StateQuery.materialize cursor.working limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
    (execution : Execution (resident (some cursor.pack) (a "write") (.tuple [list events, hwm])) final) :
    PhysicalHistory framing objects owner session final.working sealed := by
  obtain ⟨_, _, _, _, _, _, applied⟩ := write_executes execution
  obtain ⟨middle, materialized, metadataBatch⟩ := resident_batch_append applied
  obtain ⟨keys, metadata⟩ := hwm_metadata hwm
  exact (history.materialize planned materialized).metadata metadataBatch keys metadata

end VerifiedKernel.Session.PendingRevision

namespace VerifiedKernel.Session.Revision
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem expiry_plan_physical_history {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {cursor : Cursor} {observations sealed : List Term} {final : PendingRevision.Cursor} {outcome : Term}
    (history : PhysicalHistory framing objects owner session cursor.candidate.working sealed)
    (trace : PlanTrace (resident (some cursor.pack) (a "plan") (.tuple [a "expire", list observations]))
      (planned final outcome)) : PhysicalHistory framing objects owner session final.working sealed := by
  rw [plan_captured] at trace
  obtain ⟨journal, result, rest, call, _, execution⟩ := plan_trace_call trace
  obtain ⟨expired, projected, events, wake, hwm, plannedOutcome, before, j₁, j₂,
    timeout, projectedCall, materialized, same⟩ := expiry_plan_materializes call
  rw [same] at execution
  simp +decide only [acceptPlan, a, ↓reduceIte] at execution
  obtain ⟨_, written⟩ := stage_plan_raw_executes execution
  obtain ⟨_, _, _, _, _, _, applied⟩ := PendingRevision.write_executes written
  obtain ⟨materializedState, workBatch, metadataBatch⟩ := resident_batch_append applied
  obtain ⟨prefixState, prefixBatch, materializedBatch⟩ := resident_batch_append workBatch
  have prefixHistory := history.wait_prefix timeout prefixBatch
  obtain ⟨_, frame, _⟩ := wait_prefix_preserves history.invariant.history.invariant.ready timeout projectedCall prefixBatch
  have materializedHistory := prefixHistory.materialize_framed
    (frame "input_queue" (by decide) (by decide)).symm
    (frame "queue_ack_id" (by decide) (by decide)).symm
    (frame "session_id" (by decide) (by decide)) materialized materializedBatch
  obtain ⟨keys, metadata⟩ := PendingRevision.hwm_metadata hwm
  exact materializedHistory.metadata metadataBatch keys metadata

/-- Each changed native plan mode extends the physical history through its actual batch. -/
theorem plan_physical_history {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {cursor : Cursor} {mode outcome : Term} {observations sealed : List Term} {final : PendingRevision.Cursor}
    (history : PhysicalHistory framing objects owner session cursor.candidate.working sealed)
    (trace : PlanTrace (resident (some cursor.pack) (a "plan") (.tuple [mode, list observations]))
      (planned final outcome)) : PhysicalHistory framing objects owner session final.working sealed := by
  have queryTrace := trace
  rw [plan_captured] at queryTrace
  obtain ⟨_, _, _, call, _, _⟩ := plan_trace_call queryTrace
  rcases successful_plan_mode call with fast | expire | ordinary
  · subst mode
    obtain ⟨_, _, _, _, _, materialized, written⟩ := fast_plan_write trace
    exact PendingRevision.materialize_write_physical_history history materialized written
  · subst mode
    exact expiry_plan_physical_history history trace
  · obtain ⟨_, _, _, _, _, materialized, written⟩ := ordinary_plan_write ordinary trace
    exact PendingRevision.materialize_write_physical_history history materialized written

end VerifiedKernel.Session.Revision
