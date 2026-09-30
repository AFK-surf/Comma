import VerifiedKernelProofs.Session.WorkArchiveLineage
import VerifiedKernelProofs.Session.WorkDuplicateOrigin

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem normalize_fact_reflect {state next : Term} {journal rest sealed live : List Term} {fact : IdentityFact}
    (ready : QueueReady state) (messages : state.get (a "messages") = list live)
    (call : Lifecycle.normalize state journal = .ok (next, rest))
    (present : IdentityFactPresent next sealed fact) : IdentityFactPresent state sealed fact := by
  obtain ⟨_, ⟨original, kept, before, after, permuted⟩, records⟩ := normalize_work ready call
  have filled := fillDefaults_get (key := "messages") (s := state)
    (by rw [messages]; intro impossible; cases impossible)
  rw [filled, messages] at records
  change next.get (a "messages") = list live at records
  have reflectRecord : ∀ record, ContainsRecord next record → ContainsRecord state record := by
    intro record stored
    simpa only [ContainsRecord, records, messages] using stored
  cases fact with
  | work item =>
    rcases present with ⟨queue, current, read, member, same⟩ | ⟨record, stored, fields⟩ | archived
    · have equal : queue = kept := Term.list.inj (read.symm.trans after)
      subst queue
      exact Or.inl ⟨original, current, before, permuted.mem_iff.mp member, same⟩
    · exact Or.inr (Or.inl ⟨record, reflectRecord record stored, fields⟩)
    · exact Or.inr (Or.inr archived)
  | record reference =>
    obtain ⟨record, stored, same⟩ := present
    exact ⟨record, stored.imp (reflectRecord record) id, same⟩

theorem normalize_identity_supported_before {state next : Term} {journal rest sealed live : List Term} {source : ByteArray}
    (ready : QueueReady state) (messages : state.get (a "messages") = list live)
    (header : LedgerHeader state) (supported : LedgerSupported state sealed)
    (call : Lifecycle.normalize state journal = .ok (next, rest))
    (present : IdentityPresent (next.get (a "input_dedupe")) (.binary source)) : IdentitySupported state sealed source := by
  obtain ⟨event, fact, origin, stored⟩ := normalize_ledger_supported ready header supported call source present
  exact ⟨event, fact, origin, normalize_fact_reflect ready messages call stored⟩

theorem load_trace_normalizes {resident : Option Term} {state next : Term} {bytes : ByteArray}
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, state]))
    (ready : QueueReady state)
    (trace : ReloadTrace
      (SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]))
      (some next, .tuple [i 1, a "ok", .tuple [a "done"]])) :
    ∃ journal rest, Lifecycle.normalize state journal = .ok (next, rest) := by
  have initial : ReloadEvidence state (SessionDomain.dispatch resident
      (.tuple [i 1, a "session", i 1, a "load", .binary bytes])) := by
    rw [load_dispatch_normalization decoded (queueReady_isMap ready)]
    exact normalizedResponse_evidence state [] ready
  exact (reload_trace_evidence trace ready initial).1 next rfl

theorem load_identity_supported_before {resident : Option Term} {state next : Term} {bytes source : ByteArray}
    {sealed live : List Term}
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, state]))
    (ready : QueueReady state) (messages : state.get (a "messages") = list live)
    (header : LedgerHeader state) (supported : LedgerSupported state sealed)
    (trace : ReloadTrace
      (SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]))
      (some next, .tuple [i 1, a "ok", .tuple [a "done"]]))
    (present : IdentityPresent (next.get (a "input_dedupe")) (.binary source)) : IdentitySupported state sealed source := by
  obtain ⟨journal, rest, normalized⟩ := load_trace_normalizes decoded ready trace
  exact normalize_identity_supported_before ready messages header supported normalized present

end VerifiedKernel.Session.WorkConservation
