import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernelProofs.Session.WorkSemanticExecution
import VerifiedKernelProofs.Session.WorkStorageFormat

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

/-- Retirement requires the materialization or archive protocol, not an arbitrary event batch. -/
def NonRetiring (event : Term) : Prop :=
  event.get (b "type") ≠ b "queue_ack" ∧ event.get (b "type") ≠ b "queue_consume" ∧
    event.get (b "type") ≠ b "archive_advance"

theorem nonretiring_inner_ready {state event next : Term} {journal rest : List Term}
    (ready : QueueReady state) (safe : NonRetiring event)
    (call : inner state event journal = .ok (next, rest)) : QueueReady next := by
  by_cases append : event.get (b "type") = b "queue_append"
  · apply queueAppend_ready ready
    simpa +decide [inner, append] using call
  by_cases fact : event.get (b "type") = b "session_event"
  · apply sessionEvent_ready ready
    simpa +decide [inner, fact] using call
  exact queue_frame_ready (inner_queue_frame (binary_ne_false append) (binary_ne_false safe.1)
    (binary_ne_false safe.2.1) (binary_ne_false fact) call) ready

theorem nonretiring_inner_extends {state event next : Term} {journal rest : List Term}
    (format : state.get (a "storage_format") = i 3) (safe : NonRetiring event)
    (call : inner state event journal = .ok (next, rest)) : TranscriptExtends state next := by
  by_cases compact : event.get (b "type") = b "session_microcompact"
  · have actual : microcompact state event journal = .ok (next, rest) := by
      simpa +decide [inner, compact] using call
    exact extends_of_frame (microcompact_modern_work_fields format (by decide) actual).2
  exact inner_extends (binary_ne_false compact) (binary_ne_false safe.2.2) call

theorem nonretiring_inner_preserves {state event next : Term} {journal rest : List Term}
    (ready : QueueReady state) (format : state.get (a "storage_format") = i 3) (safe : NonRetiring event)
    (call : inner state event journal = .ok (next, rest)) :
    ∀ sealed item, ValueSemantics.Represented state sealed item → ValueSemantics.Represented next sealed item := by
  have records := nonretiring_inner_extends format safe call
  intro sealed item represented
  apply ValueSemantics.execution_preserves ?_ (fun _ present => record_survives records present) represented
  intro current present
  by_cases append : event.get (b "type") = b "queue_append"
  · have actual : queueAppend state event journal = .ok (next, rest) := by
      simpa +decide [inner, append] using call
    exact queueAppend_representation ready.1 actual present
  by_cases fact : event.get (b "type") = b "session_event"
  · obtain ⟨items, _, read, _⟩ := ready.1
    have actual : sessionEvent state event journal = .ok (next, rest) := by
      simpa +decide [inner, fact] using call
    exact sessionEvent_representation read actual present
  exact concrete_representation_frame_extends
    (inner_queue_frame (binary_ne_false append) (binary_ne_false safe.1)
      (binary_ne_false safe.2.1) (binary_ne_false fact) call).1 records present

theorem nonretiring_resident_preserves {state event next : Term}
    (step : ResidentStep state event next) (ready : QueueReady state)
    (format : state.get (a "storage_format") = i 3) (canonical : BinaryKeys event) (safe : NonRetiring event) :
    QueueReady next ∧ next.get (a "storage_format") = i 3 ∧
      ∀ sealed item, ValueSemantics.Represented state sealed item → ValueSemantics.Represented next sealed item := by
  have finalFormat := (resident_step_format step).trans format
  obtain ⟨middle, normalized, journal, rest, prepared, activity⟩ := step
  have activityQueue := activity_frame_queue activity
  have activityRecords := activity_frame_extends activity
  have activityWork : ∀ sealed item, ValueSemantics.Represented middle sealed item →
      ValueSemantics.Represented next sealed item := by
    intro sealed item present
    exact ValueSemantics.execution_preserves
      (fun _ before => concrete_representation_frame_extends activityQueue.1 activityRecords before)
      (fun _ before => record_survives activityRecords before) present
  cases normalized with
  | none =>
    have same := prepareTrusted_none prepared
    subst middle
    exact ⟨queue_frame_ready activityQueue ready, finalFormat, activityWork⟩
  | some normalized =>
    obtain ⟨_, read, _, call⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys canonical read
    subst normalized
    exact ⟨queue_frame_ready activityQueue (nonretiring_inner_ready ready safe call), finalFormat,
      fun sealed item present => activityWork sealed item (nonretiring_inner_preserves ready format safe call sealed item present)⟩

/-- All other modern native reducers preserve accepted work, including compaction and owner controls. -/
theorem nonretiring_batch_preserves {state next : Term} {events : List Term}
    (execution : ResidentBatch state events next) (ready : QueueReady state)
    (format : state.get (a "storage_format") = i 3)
    (canonical : ∀ event ∈ events, BinaryKeys event) (safe : ∀ event ∈ events, NonRetiring event) :
    QueueReady next ∧ next.get (a "storage_format") = i 3 ∧
      ∀ sealed item, ValueSemantics.Represented state sealed item → ValueSemantics.Represented next sealed item := by
  induction execution with
  | nil => exact ⟨ready, format, fun _ _ present => present⟩
  | cons head tail ih =>
    obtain ⟨middleReady, middleFormat, middleWork⟩ := nonretiring_resident_preserves
      (resident_execution_step head) ready format (canonical _ List.mem_cons_self) (safe _ List.mem_cons_self)
    obtain ⟨nextReady, nextFormat, nextWork⟩ := ih middleReady middleFormat
      (fun event member => canonical event (List.mem_cons_of_mem _ member))
      (fun event member => safe event (List.mem_cons_of_mem _ member))
    exact ⟨nextReady, nextFormat, fun sealed item present => nextWork sealed item (middleWork sealed item present)⟩

end VerifiedKernel.Session.WorkConservation
