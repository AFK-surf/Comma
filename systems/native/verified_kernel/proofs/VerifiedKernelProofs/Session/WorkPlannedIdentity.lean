import VerifiedKernelProofs.Session.WorkMaterializedIdentity
import VerifiedKernelProofs.Session.WorkRevisionExpiry

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem no_binary_tag {value : Term} {key : String} (different : (value == b key) = false) : value ≠ b key := by
  intro same
  rw [same, binary_key_beq] at different
  simp at different

theorem commit_metadata_nonretiring {event : Term} (metadata : CommitMetadata event) : NonRetiring event := by
  rcases metadata with ⟨kind, _⟩ | kind
  all_goals
    unfold NonRetiring
    rw [kind]
    exact ⟨no_binary_tag rfl, no_binary_tag rfl, no_binary_tag rfl⟩

theorem metadata_ledger_supported {state next : Term} {events sealed : List Term}
    (execution : ResidentBatch state events next)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (metadata : ∀ event ∈ events, CommitMetadata event)
    (ready : QueueReady state) (format : state.get (a "storage_format") = i 3)
    (supported : LedgerSupported state sealed) : LedgerSupported next sealed :=
  nonretiring_batch_ledger_supported execution ready format canonical
    (fun event member => commit_metadata_nonretiring (metadata event member)) supported

theorem materialize_framed_ledger_supported {state projected next : Term} {events journal rest sealed : List Term}
    {limit : Int} {wake : Bool} {hwm : Term} (ready : QueueReady state)
    (queueSame : projected.get (a "input_queue") = state.get (a "input_queue"))
    (ackSame : projected.get (a "queue_ack_id") = state.get (a "queue_ack_id"))
    (sessionSame : state.get (a "session_id") = projected.get (a "session_id"))
    (planned : StateQuery.materialize projected limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
    (execution : ResidentBatch state events next) (supported : LedgerSupported state sealed) : LedgerSupported next sealed := by
  have routed := materialize_routed planned
  rw [← sessionSame] at routed
  obtain ⟨reduced, _⟩ := resident_routed_reduces execution routed
  have ordinary := materialize_ordinary planned
  have work := materialize_framed_work ready queueSame ackSame sessionSame planned execution
  intro source present
  rcases reduced_batch_new_identity_records reduced ordinary (materialize_no_append planned) present with
    old | ⟨event, _, record, origin, stored⟩
  · obtain ⟨originInput, fact, origin, represented⟩ := supported source old
    exact ⟨originInput, fact, origin, identity_fact_preserves (work.2 sealed)
      (fun _ stored => record_survives (resident_reduced_extends reduced ordinary) stored) represented⟩
  · exact ⟨event, .record record, origin, identity_record_present stored sealed⟩

theorem wait_prefix_ledger_supported {state expired next : Term} {journal rest sealed : List Term}
    (ready : QueueReady state) (format : state.get (a "storage_format") = i 3)
    (supported : LedgerSupported state sealed)
    (timeout : Command.waitTimeout state nil journal = .ok (expired, rest))
    (execution : ResidentBatch state (if expired == nil then [] else [expired]) next) : LedgerSupported next sealed := by
  by_cases missing : (expired == nil) = true
  · simp only [missing, ↓reduceIte] at execution
    cases execution
    exact supported
  · simp only [missing, Bool.false_eq_true, ↓reduceIte] at execution
    obtain ⟨canonical, allowed⟩ := (wait_timeout_input timeout).resolve_left (by
      intro same; subst expired; exact missing rfl)
    exact admitted_batch_ledger_supported execution ready format
      (by simpa using canonical) (by simpa using allowed) supported

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.PendingRevision
open Data WorkConservation
set_option Elab.async false

theorem materialize_write_ledger_supported {cursor final : Cursor} {events journal rest sealed : List Term}
    {limit : Int} {wake : Bool} {hwm : Term}
    (ready : QueueReady cursor.working) (format : cursor.working.get (a "storage_format") = i 3)
    (supported : LedgerSupported cursor.working sealed)
    (planned : StateQuery.materialize cursor.working limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
    (execution : Execution (resident (some cursor.pack) (a "write") (.tuple [list events, hwm])) final) :
    LedgerSupported final.working sealed := by
  obtain ⟨_, _, _, _, _, _, applied⟩ := write_executes execution
  obtain ⟨middle, materialized, metadataBatch⟩ := resident_batch_append applied
  have middleReady := materialize_resident_ready ready planned materialized
  have middleFormat := (resident_batch_format materialized).trans format
  have middleSupported := materialize_ledger_supported ready supported planned materialized
  obtain ⟨keys, metadata⟩ := hwm_metadata hwm
  exact metadata_ledger_supported metadataBatch keys metadata middleReady middleFormat middleSupported

theorem write_ledger_header {cursor final : Cursor} {events : List Term} {hwm : Term}
    (header : LedgerHeader cursor.working)
    (execution : Execution (resident (some cursor.pack) (a "write") (.tuple [list events, hwm])) final) :
    LedgerHeader final.working := by
  obtain ⟨_, _, _, _, _, _, applied⟩ := write_executes execution
  exact batch_ledger_header applied header

end VerifiedKernel.Session.PendingRevision

namespace VerifiedKernel.Session.Revision
open Data WorkConservation
set_option Elab.async false

theorem expiry_plan_ledger_supported {cursor : Cursor} {observations sealed : List Term}
    {final : PendingRevision.Cursor} {outcome : Term}
    (ready : QueueReady cursor.candidate.working) (format : cursor.candidate.working.get (a "storage_format") = i 3)
    (supported : LedgerSupported cursor.candidate.working sealed)
    (trace : PlanTrace (resident (some cursor.pack) (a "plan") (.tuple [a "expire", list observations]))
      (planned final outcome)) : LedgerSupported final.working sealed := by
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
  obtain ⟨prefixReady, frame, _⟩ := wait_prefix_preserves ready timeout projectedCall prefixBatch
  have prefixSupported := wait_prefix_ledger_supported ready format supported timeout prefixBatch
  have materializedWork := materialize_framed_work prefixReady
    (frame "input_queue" (by decide) (by decide)).symm
    (frame "queue_ack_id" (by decide) (by decide)).symm
    (frame "session_id" (by decide) (by decide)) materialized materializedBatch
  have materializedSupported := materialize_framed_ledger_supported prefixReady
    (frame "input_queue" (by decide) (by decide)).symm
    (frame "queue_ack_id" (by decide) (by decide)).symm
    (frame "session_id" (by decide) (by decide)) materialized materializedBatch prefixSupported
  obtain ⟨keys, metadata⟩ := PendingRevision.hwm_metadata hwm
  exact metadata_ledger_supported metadataBatch keys metadata materializedWork.1
    ((resident_batch_format workBatch).trans format) materializedSupported

/-- All changed native plan modes retain the actual facts behind duplicate identities. -/
theorem plan_ledger_supported {cursor : Cursor} {mode outcome : Term} {observations sealed : List Term}
    {final : PendingRevision.Cursor}
    (ready : QueueReady cursor.candidate.working) (format : cursor.candidate.working.get (a "storage_format") = i 3)
    (supported : LedgerSupported cursor.candidate.working sealed)
    (trace : PlanTrace (resident (some cursor.pack) (a "plan") (.tuple [mode, list observations]))
      (planned final outcome)) : LedgerSupported final.working sealed := by
  have queryTrace := trace
  rw [plan_captured] at queryTrace
  obtain ⟨_, _, _, call, _, _⟩ := plan_trace_call queryTrace
  rcases successful_plan_mode call with fast | expire | ordinary
  · subst mode
    obtain ⟨_, _, _, _, _, materialized, written⟩ := fast_plan_write trace
    exact PendingRevision.materialize_write_ledger_supported ready format supported materialized written
  · subst mode
    exact expiry_plan_ledger_supported ready format supported trace
  · obtain ⟨_, _, _, _, _, materialized, written⟩ := ordinary_plan_write ordinary trace
    exact PendingRevision.materialize_write_ledger_supported ready format supported materialized written

end VerifiedKernel.Session.Revision
