import VerifiedKernelProofs.Session.WorkLedgerShape

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem mergePredicate_ledger_frame {state kind through replacement extra next : Term} {journal rest : List Term}
    (call : mergePredicate state kind through replacement extra journal = .ok (next, rest)) : LedgerFrame state next := by
  unfold mergePredicate at call
  repeat' first
    | exact write_field_frame call rfl
    | split at call
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)

theorem mergePredicate_ledger_frame_step {state kind through replacement extra next : Term} {journal rest : List Term} :
    mergePredicate state kind through replacement extra journal = .ok (next, rest) ↔
      Except.ok (next, rest) = mergePredicate state kind through replacement extra journal ∧ LedgerFrame state next :=
  step_iff mergePredicate_ledger_frame

theorem microcompactIds_ledger_frame {state replacement event next : Term} {ids journal rest : List Term}
    (call : microcompactIds state ids replacement event journal = .ok (next, rest)) : LedgerFrame state next := by
  unfold microcompactIds at call
  repeat' first
    | exact write_field_frame call rfl
    | split at call
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)

theorem microcompactIds_ledger_frame_step {state replacement event next : Term} {ids journal rest : List Term} :
    microcompactIds state ids replacement event journal = .ok (next, rest) ↔
      Except.ok (next, rest) = microcompactIds state ids replacement event journal ∧ LedgerFrame state next :=
  step_iff microcompactIds_ledger_frame

theorem microcompact_ledger_frame {state event next : Term} {journal rest : List Term}
    (call : microcompact state event journal = .ok (next, rest)) : LedgerFrame state next := by
  unfold microcompact at call
  ledger_frame_walk call

theorem microcompact_ledger_frame_step {state event next : Term} {journal rest : List Term} :
    microcompact state event journal = .ok (next, rest) ↔
      Except.ok (next, rest) = microcompact state event journal ∧ LedgerFrame state next :=
  step_iff microcompact_ledger_frame

theorem inner_nonwriter_ledger_frame {state event next : Term} {journal rest : List Term}
    (append : (event.get (b "type") == b "queue_append") = false)
    (log : (event.get (b "type") == b "session_log_message") = false)
    (seed : (event.get (b "type") == b "transcript_seed") = false)
    (runtime : (event.get (b "type") == b "runtime_message") = false)
    (delivery : (event.get (b "type") == b "delivery") = false)
    (call : inner state event journal = .ok (next, rest)) : LedgerFrame state next := by
  unfold inner at call
  simp only [append, log, seed, runtime, delivery, Bool.false_and, Bool.false_eq_true, ↓reduceIte, ite_ok_iff] at call
  ledger_frame_walk call

theorem inner_ledger_header {state event next : Term} {journal rest : List Term}
    (header : LedgerHeader state) (call : inner state event journal = .ok (next, rest)) : LedgerHeader next := by
  by_cases append : event.get (b "type") = b "queue_append"
  · exact queueAppend_ledger_header header (by simpa +decide [inner, append] using call)
  by_cases log : event.get (b "type") = b "session_log_message"
  · exact transcriptLog_ledger_header header (by simpa +decide [inner, log] using call)
  by_cases seed : event.get (b "type") = b "transcript_seed"
  · exact transcriptSeed_ledger_header header (by simpa +decide [inner, seed] using call)
  by_cases runtime : event.get (b "type") = b "runtime_message"
  · exact transcriptRuntime_ledger_header header (by simpa +decide [inner, runtime] using call)
  by_cases delivery : event.get (b "type") = b "delivery"
  · exact transcriptDelivery_ledger_header header (by simpa +decide [inner, delivery] using call)
  unfold LedgerHeader
  rw [inner_nonwriter_ledger_frame (binary_ne_false append) (binary_ne_false log) (binary_ne_false seed)
    (binary_ne_false runtime) (binary_ne_false delivery) call]
  exact header

theorem resident_ledger_header {state event next : Term}
    (step : ResidentStep state event next) (header : LedgerHeader state) : LedgerHeader next := by
  obtain ⟨middle, normalized, journal, rest, prepared, activity⟩ := step
  unfold LedgerHeader
  rw [activity "input_dedupe" (by decide) (by decide)]
  cases normalized with
  | none => rw [prepareTrusted_none prepared]; exact header
  | some normalized =>
    obtain ⟨_, _, _, call⟩ := prepareTrusted_stringify prepared
    exact inner_ledger_header header call

theorem batch_ledger_header {state next : Term} {events : List Term}
    (execution : ResidentBatch state events next) (header : LedgerHeader state) : LedgerHeader next := by
  induction execution with
  | nil => exact header
  | cons head tail ih => exact ih (resident_ledger_header (resident_execution_step head) header)

theorem unadmitted_ledger_frame {state event next : Term} {journal rest : List Term}
    (unadmitted : Command.inputEventAllowed event = false)
    (call : inner state event journal = .ok (next, rest)) : LedgerFrame state next := by
  apply inner_nonwriter_ledger_frame (call := call)
  all_goals
    apply binary_ne_false
    intro kind
    have admitted : Command.inputEventAllowed event = true := by simp +decide [Command.inputEventAllowed, kind]
    rw [unadmitted] at admitted
    contradiction

theorem nonretiring_inner_ledger_supported {state event next : Term} {journal rest sealed : List Term}
    (ready : QueueReady state) (format : state.get (a "storage_format") = i 3)
    (safe : NonRetiring event) (supported : LedgerSupported state sealed)
    (call : inner state event journal = .ok (next, rest)) : LedgerSupported next sealed := by
  cases allowed : Command.inputEventAllowed event with
  | true => exact admitted_inner_ledger_supported ready format allowed supported call
  | false =>
    have ledger := unadmitted_ledger_frame allowed call
    intro source present
    rw [ledger] at present
    obtain ⟨originInput, fact, origin, represented⟩ := supported source present
    exact ⟨originInput, fact, origin, identity_fact_preserves
      (nonretiring_inner_preserves ready format safe call sealed)
      (fun _ stored => record_survives (nonretiring_inner_extends format safe call) stored) represented⟩

theorem nonretiring_resident_ledger_supported {state event next : Term} {sealed : List Term}
    (step : ResidentStep state event next) (ready : QueueReady state)
    (format : state.get (a "storage_format") = i 3) (canonical : BinaryKeys event)
    (safe : NonRetiring event) (supported : LedgerSupported state sealed) : LedgerSupported next sealed := by
  obtain ⟨middle, normalized, journal, rest, prepared, activity⟩ := step
  apply activity_ledger_supported activity
  cases normalized with
  | none => rw [prepareTrusted_none prepared]; exact supported
  | some normalized =>
    obtain ⟨_, read, _, call⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys canonical read
    subst normalized
    exact nonretiring_inner_ledger_supported ready format safe supported call

theorem nonretiring_batch_ledger_supported {state next : Term} {events sealed : List Term}
    (execution : ResidentBatch state events next) (ready : QueueReady state)
    (format : state.get (a "storage_format") = i 3)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (safe : ∀ event ∈ events, NonRetiring event)
    (supported : LedgerSupported state sealed) : LedgerSupported next sealed := by
  induction execution with
  | nil => exact supported
  | cons head tail ih =>
    have step := resident_execution_step head
    have headKeys := canonical _ List.mem_cons_self
    have headSafe := safe _ List.mem_cons_self
    obtain ⟨middleReady, middleFormat, _⟩ := nonretiring_resident_preserves step ready format headKeys headSafe
    exact ih middleReady middleFormat
      (fun event member => canonical event (List.mem_cons_of_mem _ member))
      (fun event member => safe event (List.mem_cons_of_mem _ member))
      (nonretiring_resident_ledger_supported step ready format headKeys headSafe supported)

end VerifiedKernel.Session.WorkConservation
