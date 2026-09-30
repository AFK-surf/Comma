import VerifiedKernelProofs.Session.WorkReceiptReload
import VerifiedKernelProofs.Session.WorkIdentityFacts

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

/-- The stored fact and the actual key comparison that introduced its receipt. -/
inductive ReceiptOrigin (event key : Term) : IdentityFact → Prop where
  | queue {item payload : Term} {keys before middle after : List Term}
      (kind : event.get (b "type") = b "queue_append")
      (normalized : stringify ((event.get (b "payload")).default empty) before = .ok (payload, middle))
      (read : queueKeys event payload (event.get (b "kind")) middle = .ok (keys, after))
      (included : ReceiptMatches key keys) (fields : item.get (b "payload") = payload)
      (canonical : CanonicalQueueItem item) : ReceiptOrigin event key (.work item)
  | log {record : Term} (kind : event.get (b "type") = b "session_log_message")
      (identity : ReceiptMatches key [record.get (a "source_message_id"), record.get (a "dedupe_key")])
      (fields : LogFactFields event record) : ReceiptOrigin event key (.record record)
  | delivery {record : Term} (kind : event.get (b "type") = b "delivery")
      (identity : ReceiptMatches key [record.get (a "source_message_id"), record.get (a "dedupe_key")])
      (content : record.get (a "content") = event.get (b "content"))
      (input : record.get (a "accepted_input") = event.get (b "accepted_input")) :
      ReceiptOrigin event key (.record record)
  | runtime {record : Term} {keys before after : List Term}
      (kind : event.get (b "type") = b "runtime_message")
      (read : runtimeKeys event before = .ok (keys, after))
      (identity : ReceiptMatches key keys) (fields : RuntimeIdentityFields event record) :
      ReceiptOrigin event key (.record record)
  | seed {items : List Term} {raw record : Term} (kind : event.get (b "type") = b "transcript_seed")
      (enumerated : enumeratedItems ((event.get (b "entries")).default (list [])) = some items)
      (included : raw ∈ items) (fields : SeedReceiptSource event raw key record) :
      ReceiptOrigin event key (.record record)
  | restoredQueue {keys before after : List Term}
      (read : Lifecycle.queueDedupeKeys event before = .ok (keys, after))
      (included : ReceiptMatches key keys) (canonical : CanonicalQueueItem event) :
      ReceiptOrigin event key (.work event)
  | forkedRecord {field : Term} (allowed : field ∈ forkIdentityFields)
      (identity : (event.get field == key) = true) : ReceiptOrigin event key (.record event)

def ReceiptSupported (state : Term) (sealed : List Term) : Prop :=
  ∀ key, IdentityPresent (state.get (a "input_dedupe")) key →
    ∃ event fact, ReceiptOrigin event key fact ∧ IdentityFactPresent state sealed fact

theorem admitted_new_receipt_fact {state event next key : Term} {journal rest : List Term}
    (ready : QueueReady state) (allowed : Command.inputEventAllowed event = true)
    (call : inner state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) key)
    (present : IdentityPresent (next.get (a "input_dedupe")) key) :
    ∃ fact, ReceiptOrigin event key fact ∧ ∀ sealed, IdentityFactPresent next sealed fact := by
  by_cases append : event.get (b "type") = b "queue_append"
  · have actual : queueAppend state event journal = .ok (next, rest) := by simpa +decide [inner, append] using call
    obtain ⟨item, payload, keys, before, middle, after, normalized, read, included, fields, canonical, kept⟩ :=
      queue_append_new_receipt_fact ready actual absent present
    exact ⟨.work item, .queue append normalized read included fields canonical, kept⟩
  by_cases log : event.get (b "type") = b "session_log_message"
  · have actual : transcriptLog state event journal = .ok (next, rest) := by simpa +decide [inner, log] using call
    obtain ⟨record, _, stored, identity, fields⟩ := log_new_receipt_fact actual absent present
    exact ⟨.record record, .log log identity fields, identity_record_present stored⟩
  by_cases delivery : event.get (b "type") = b "delivery"
  · have actual : transcriptDelivery state event journal = .ok (next, rest) := by simpa +decide [inner, delivery] using call
    obtain ⟨record, _, stored, identity, content, input⟩ := delivery_new_receipt_fact actual absent present
    exact ⟨.record record, .delivery delivery identity content input, identity_record_present stored⟩
  by_cases runtime : event.get (b "type") = b "runtime_message"
  · have actual : transcriptRuntime state event journal = .ok (next, rest) := by simpa +decide [inner, runtime] using call
    obtain ⟨record, _, stored, fields⟩ := runtime_new_receipt_record actual absent present
    obtain ⟨keys, before, after, read, identity⟩ := runtime_new_receipt_keys actual absent present
    exact ⟨.record record, .runtime runtime read identity fields, identity_record_present stored⟩
  by_cases seed : event.get (b "type") = b "transcript_seed"
  · have actual : transcriptSeed state event journal = .ok (next, rest) := by simpa +decide [inner, seed] using call
    obtain ⟨items, raw, record, enumerated, included, stored, fields⟩ := seed_new_receipt_fact actual absent present
    exact ⟨.record record, .seed seed enumerated included fields, identity_record_present stored⟩
  have frame := admitted_inner_ledger_frame allowed (binary_ne_false append) (binary_ne_false log)
    (binary_ne_false seed) (binary_ne_false runtime) (binary_ne_false delivery) call
  unfold IdentityPresent at present
  unfold IdentityAbsent at absent
  rw [frame, absent] at present
  contradiction

end VerifiedKernel.Session.WorkConservation
