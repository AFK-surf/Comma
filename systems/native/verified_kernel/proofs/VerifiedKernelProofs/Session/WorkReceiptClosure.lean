import VerifiedKernelProofs.Session.WorkReceiptInitial
import VerifiedKernelProofs.Session.WorkLedgerClosure

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem nonretiring_inner_receipt_supported {state event next : Term} {journal rest sealed : List Term}
    (ready : QueueReady state) (format : state.get (a "storage_format") = i 3)
    (safe : NonRetiring event) (supported : ReceiptSupported state sealed)
    (call : inner state event journal = .ok (next, rest)) : ReceiptSupported next sealed := by
  cases allowed : Command.inputEventAllowed event with
  | true => exact admitted_inner_receipt_supported ready format allowed supported call
  | false =>
    have ledger := unadmitted_ledger_frame allowed call
    intro source present
    rw [ledger] at present
    obtain ⟨originInput, fact, origin, represented⟩ := supported source present
    exact ⟨originInput, fact, origin, identity_fact_preserves
      (nonretiring_inner_preserves ready format safe call sealed)
      (fun _ stored => record_survives (nonretiring_inner_extends format safe call) stored) represented⟩

theorem nonretiring_resident_receipt_supported {state event next : Term} {sealed : List Term}
    (step : ResidentStep state event next) (ready : QueueReady state)
    (format : state.get (a "storage_format") = i 3) (canonical : BinaryKeys event)
    (safe : NonRetiring event) (supported : ReceiptSupported state sealed) : ReceiptSupported next sealed := by
  obtain ⟨middle, normalized, journal, rest, prepared, activity⟩ := step
  apply activity_receipt_supported activity
  cases normalized with
  | none => rw [prepareTrusted_none prepared]; exact supported
  | some normalized =>
    obtain ⟨_, read, _, call⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys canonical read
    subst normalized
    exact nonretiring_inner_receipt_supported ready format safe supported call

theorem nonretiring_batch_receipt_supported {state next : Term} {events sealed : List Term}
    (execution : ResidentBatch state events next) (ready : QueueReady state)
    (format : state.get (a "storage_format") = i 3)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (safe : ∀ event ∈ events, NonRetiring event)
    (supported : ReceiptSupported state sealed) : ReceiptSupported next sealed := by
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
      (nonretiring_resident_receipt_supported step ready format headKeys headSafe supported)

end VerifiedKernel.Session.WorkConservation
