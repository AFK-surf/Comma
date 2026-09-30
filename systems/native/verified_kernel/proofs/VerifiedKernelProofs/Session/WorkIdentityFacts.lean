import VerifiedKernelProofs.Session.WorkRecordLedgerFacts
import VerifiedKernelProofs.Session.WorkSeedFact
import VerifiedKernelProofs.Session.WorkNonRetiring
import VerifiedKernelProofs.Session.WorkForkLedger

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

/-- These witnesses are proof projections, not new runtime entities. -/
inductive IdentityFact where
  | work (item : Term)
  | record (value : Term)

inductive IdentityFactOrigin (event : Term) (source : ByteArray) : IdentityFact → Prop where
  | queue {item payload : Term} {keys before middle after : List Term}
      (kind : event.get (b "type") = b "queue_append")
      (normalized : stringify ((event.get (b "payload")).default empty) before = .ok (payload, middle))
      (read : queueKeys event payload (event.get (b "kind")) middle = .ok (keys, after))
      (included : .binary source ∈ keys) (fields : item.get (b "payload") = payload)
      (canonical : CanonicalQueueItem item) : IdentityFactOrigin event source (.work item)
  | log {record : Term} (kind : event.get (b "type") = b "session_log_message")
      (identity : record.get (a "source_message_id") = .binary source ∨ record.get (a "dedupe_key") = .binary source)
      (content : record.get (a "content") = event.get (b "content")) :
      IdentityFactOrigin event source (.record record)
  | delivery {record : Term} (kind : event.get (b "type") = b "delivery")
      (identity : record.get (a "source_message_id") = .binary source ∨ record.get (a "dedupe_key") = .binary source)
      (content : record.get (a "content") = event.get (b "content"))
      (input : record.get (a "accepted_input") = event.get (b "accepted_input")) :
      IdentityFactOrigin event source (.record record)
  | runtime {record : Term} (kind : event.get (b "type") = b "runtime_message")
      (identity : record.get (a "dedupe_key") = .binary source ∨ record.get (a "source_message_id") = .binary source ∨
        record.get (a "runtime_message_id") = .binary source)
      (content : record.get (a "content") = (event.get (b "content")).default (event.get (b "summary")))
      (input : record.get (a "accepted_input") = event.get (b "accepted_input")) :
      IdentityFactOrigin event source (.record record)
  | seed {items : List Term} {raw record : Term} (kind : event.get (b "type") = b "transcript_seed")
      (enumerated : enumeratedItems ((event.get (b "entries")).default (list [])) = some items)
      (included : raw ∈ items) (fields : SeedRecordSource event raw source record) :
      IdentityFactOrigin event source (.record record)
  | restoredQueue {keys before after : List Term}
      (read : Lifecycle.queueDedupeKeys event before = .ok (keys, after))
      (included : .binary source ∈ keys) (canonical : CanonicalQueueItem event) :
      IdentityFactOrigin event source (.work event)
  | forkedRecord {field : Term} (allowed : field ∈ forkIdentityFields)
      (identity : event.get field = .binary source) : IdentityFactOrigin event source (.record event)

def IdentityFactPresent (state : Term) (sealed : List Term) : IdentityFact → Prop
  | .work item => ValueSemantics.Represented state sealed item
  | .record reference => ∃ record,
      (ContainsRecord state record ∨ record ∈ sealed) ∧ ValueSemantics.Equivalent reference record

def IdentitySupported (state : Term) (sealed : List Term) (source : ByteArray) : Prop :=
  ∃ event fact, IdentityFactOrigin event source fact ∧ IdentityFactPresent state sealed fact

theorem identity_record_present {state record : Term} (present : ContainsRecord state record)
    (sealed : List Term) : IdentityFactPresent state sealed (.record record) :=
  ⟨record, Or.inl present, ValueSemantics.Equivalent.refl _⟩

theorem admitted_new_identity_fact {state event next : Term} {source : ByteArray} {journal rest : List Term}
    (ready : QueueReady state) (allowed : Command.inputEventAllowed event = true)
    (call : inner state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) (.binary source))
    (present : IdentityPresent (next.get (a "input_dedupe")) (.binary source)) :
    ∃ fact, IdentityFactOrigin event source fact ∧ ∀ sealed, IdentityFactPresent next sealed fact := by
  by_cases append : event.get (b "type") = b "queue_append"
  · have actual : queueAppend state event journal = .ok (next, rest) := by simpa +decide [inner, append] using call
    obtain ⟨item, payload, keys, before, middle, after, normalized, read, included, fields, canonical, kept⟩ :=
      queue_append_new_identity_fact ready actual absent present
    exact ⟨.work item, .queue append normalized read included fields canonical, kept⟩
  by_cases log : event.get (b "type") = b "session_log_message"
  · have actual : transcriptLog state event journal = .ok (next, rest) := by simpa +decide [inner, log] using call
    obtain ⟨record, _, stored, identity, content⟩ := log_new_identity_fact actual absent present
    exact ⟨.record record, .log log identity content, identity_record_present stored⟩
  by_cases delivery : event.get (b "type") = b "delivery"
  · have actual : transcriptDelivery state event journal = .ok (next, rest) := by simpa +decide [inner, delivery] using call
    obtain ⟨record, _, stored, identity, content, input⟩ := delivery_new_identity_fact actual absent present
    exact ⟨.record record, .delivery delivery identity content input, identity_record_present stored⟩
  by_cases runtime : event.get (b "type") = b "runtime_message"
  · have actual : transcriptRuntime state event journal = .ok (next, rest) := by simpa +decide [inner, runtime] using call
    obtain ⟨record, _, stored, identity, content, input⟩ := runtime_new_identity_fact actual absent present
    exact ⟨.record record, .runtime runtime identity content input, identity_record_present stored⟩
  by_cases seed : event.get (b "type") = b "transcript_seed"
  · have actual : transcriptSeed state event journal = .ok (next, rest) := by simpa +decide [inner, seed] using call
    obtain ⟨items, raw, record, enumerated, included, stored, fields⟩ := seed_new_identity_fact actual absent present
    exact ⟨.record record, .seed seed enumerated included fields, identity_record_present stored⟩
  have frame := admitted_inner_ledger_frame allowed (binary_ne_false append) (binary_ne_false log)
    (binary_ne_false seed) (binary_ne_false runtime) (binary_ne_false delivery) call
  unfold IdentityPresent at present
  unfold IdentityAbsent at absent
  rw [frame, absent] at present
  contradiction

theorem identity_fact_preserves {state next : Term} {sealed : List Term} {fact : IdentityFact}
    (work : ∀ item, ValueSemantics.Represented state sealed item → ValueSemantics.Represented next sealed item)
    (records : ∀ record, ContainsRecord state record → ContainsRecord next record)
    (present : IdentityFactPresent state sealed fact) : IdentityFactPresent next sealed fact := by
  cases fact with
  | work item => exact work item present
  | record reference =>
    obtain ⟨record, stored, same⟩ := present
    exact ⟨record, stored.imp (records record) id, same⟩

theorem identity_fact_equivalent {state next : Term} {sealed : List Term} {fact : IdentityFact}
    (same : ValueSemantics.Equivalent state next) (present : IdentityFactPresent state sealed fact) :
    IdentityFactPresent next sealed fact := by
  cases fact with
  | work item => exact same.represents present
  | record reference =>
    obtain ⟨record, stored, fields⟩ := present
    rcases stored with live | archived
    · obtain ⟨value, nextPresent, related⟩ := same.record live
      exact ⟨value, Or.inl nextPresent, fields.trans related⟩
    · exact ⟨record, Or.inr archived, fields⟩

theorem identity_fact_work_fields {state next : Term} {sealed : List Term} {fact : IdentityFact}
    (fields : WorkFieldsPreserved state next) (present : IdentityFactPresent state sealed fact) :
    IdentityFactPresent next sealed fact := by
  cases fact with
  | work item => exact ValueSemantics.work_fields_preserves fields present
  | record reference =>
    simpa only [IdentityFactPresent, ContainsRecord, fields.2] using present

end VerifiedKernel.Session.WorkConservation
