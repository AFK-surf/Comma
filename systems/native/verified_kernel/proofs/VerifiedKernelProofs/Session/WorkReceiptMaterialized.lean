import VerifiedKernelProofs.Session.WorkReceiptClosure
import VerifiedKernelProofs.Session.WorkMaterializedIdentity

namespace VerifiedKernel.Session.WorkConservation
open Data StateQuery
set_option Elab.async false

theorem inner_new_receipt_record {state event next : Term} {source : Term} {journal rest : List Term}
    (noAppend : event.get (b "type") ≠ b "queue_append")
    (call : inner state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) (source))
    (present : IdentityPresent (next.get (a "input_dedupe")) (source)) :
    ∃ record, ReceiptOrigin event source (.record record) ∧ ContainsRecord next record := by
  by_cases log : event.get (b "type") = b "session_log_message"
  · obtain ⟨record, _, stored, identity, content⟩ := log_new_receipt_fact
      (by simpa +decide [inner, log] using call) absent present
    exact ⟨record, .log log identity content, stored⟩
  by_cases delivery : event.get (b "type") = b "delivery"
  · obtain ⟨record, _, stored, identity, content, input⟩ := delivery_new_receipt_fact
      (by simpa +decide [inner, delivery] using call) absent present
    exact ⟨record, .delivery delivery identity content input, stored⟩
  by_cases runtime : event.get (b "type") = b "runtime_message"
  · have actual : transcriptRuntime state event journal = .ok (next, rest) := by
      simpa +decide [inner, runtime] using call
    obtain ⟨record, _, stored, fields⟩ := runtime_new_receipt_record actual absent present
    obtain ⟨keys, before, after, read, identity⟩ := runtime_new_receipt_keys actual absent present
    exact ⟨record, .runtime runtime read identity fields, stored⟩
  by_cases seed : event.get (b "type") = b "transcript_seed"
  · obtain ⟨items, raw, record, enumerated, included, stored, fields⟩ := seed_new_receipt_fact
      (by simpa +decide [inner, seed] using call) absent present
    exact ⟨record, .seed seed enumerated included fields, stored⟩
  have frame := inner_nonwriter_ledger_frame (binary_ne_false noAppend) (binary_ne_false log)
    (binary_ne_false seed) (binary_ne_false runtime) (binary_ne_false delivery) call
  unfold IdentityPresent at present
  unfold IdentityAbsent at absent
  rw [frame, absent] at present
  contradiction

theorem reduced_batch_new_receipt_records {state next : Term} {source : Term} {events : List Term}
    (execution : ResidentReducedBatch state events next) (ordinary : Ordinary events)
    (noAppend : NoQueueAppend events)
    (present : IdentityPresent (next.get (a "input_dedupe")) (source)) :
    IdentityPresent (state.get (a "input_dedupe")) (source) ∨
      ∃ event ∈ events, ∃ record, ReceiptOrigin event source (.record record) ∧ ContainsRecord next record := by
  induction execution with
  | nil => exact Or.inl present
  | cons call activity tail ih =>
    have ordinaryTail : Ordinary _ := fun event member => ordinary event (List.mem_cons_of_mem _ member)
    have noAppendTail : NoQueueAppend _ := fun event member => noAppend event (List.mem_cons_of_mem _ member)
    rcases ih ordinaryTail noAppendTail present with middle | ⟨event, included, record, origin, stored⟩
    · rcases identity_present_or_absent _ (source) with old | absent
      · exact Or.inl old
      · rw [activity "input_dedupe" (by decide) (by decide)] at middle
        obtain ⟨record, origin, stored⟩ := inner_new_receipt_record
          (noAppend _ List.mem_cons_self) call absent middle
        exact Or.inr ⟨_, List.mem_cons_self, record, origin,
          record_survives (extends_trans (activity_frame_extends activity) (resident_reduced_extends tail ordinaryTail)) stored⟩
    · exact Or.inr ⟨event, List.mem_cons_of_mem _ included, record, origin, stored⟩

/-- The actual planner can retire queue entries without losing the facts that support their ledger identities. -/
theorem materialize_receipt_supported {state next : Term} {events journal rest sealed : List Term}
    {wake : Bool} {hwm : Term} {limit : Int}
    (ready : QueueReady state) (supported : ReceiptSupported state sealed)
    (planned : materialize state limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
    (execution : ResidentBatch state events next) : ReceiptSupported next sealed := by
  have routed := materialize_routed planned
  obtain ⟨reduced, _⟩ := resident_routed_reduces execution routed
  have ordinary := materialize_ordinary planned
  intro source present
  rcases reduced_batch_new_receipt_records reduced ordinary (materialize_no_append planned) present with
    old | ⟨event, _, record, origin, stored⟩
  · obtain ⟨originInput, fact, origin, represented⟩ := supported source old
    exact ⟨originInput, fact, origin, identity_fact_preserves
      (fun _ work => ValueSemantics.materialize_preserves ready planned execution work)
      (fun _ stored => record_survives (resident_reduced_extends reduced ordinary) stored) represented⟩
  · exact ⟨event, .record record, origin, identity_record_present stored sealed⟩

end VerifiedKernel.Session.WorkConservation
