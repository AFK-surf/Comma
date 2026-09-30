import VerifiedKernelProofs.Session.WorkPhysicalRecords
import VerifiedKernelProofs.Session.WorkLogAdmission
import VerifiedKernelProofs.Session.WorkReceiptHistory

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

/-- A log retry confirms a previously stored matching fact; a new log confirms its stored content. -/
def LogFactOrigin (event : Term) (fact : IdentityFact) : Prop :=
  (∃ record, fact = .record record ∧ LogFactFields event record) ∨
  ∃ key original,
    key ∈ [event.get (b "source_message_id"), event.get (b "dedupe_key")].filter (!missing ·) ∧
    ReceiptOrigin original key fact

theorem transcriptLog_logical {state event next : Term} {sealed journal rest : List Term}
    (supported : ReceiptSupported state sealed)
    (call : transcriptLog state event journal = .ok (next, rest)) :
    ∃ fact, LogFactOrigin event fact ∧ IdentityFactPresent next sealed fact := by
  rcases log_record_or_duplicate call with ⟨⟨key, member, present⟩, same⟩ | ⟨record, _, stored, fields⟩
  · obtain ⟨original, fact, origin, backed⟩ := supported key present
    rw [same]
    exact ⟨fact, Or.inr ⟨key, original, member, origin⟩, backed⟩
  · exact ⟨.record record, Or.inl ⟨record, rfl, fields⟩, identity_record_present stored sealed⟩

theorem log_event_routed (session entry now : Term) : Routed session (logEvent session entry now) := by
  refine ⟨compact_binary_keys _, ?_⟩
  simp +decide [logEvent, compact_lookup, List.find?_cons]
  split
  · rfl
  · rename_i missing
    exact (bne_nil_false missing).symm

theorem log_event_kind (session entry now : Term) :
    (logEvent session entry now).get (b "type") = b "session_log_message" := by
  simp +decide [logEvent, compact_lookup]

theorem PhysicalHistory.log_singleton {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {state next entry now : Term} {sealed : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (execution : ResidentBatch state [logEvent (state.get (a "session_id")) entry now] next) :
    ∃ fact, LogFactOrigin (logEvent (state.get (a "session_id")) entry now) fact ∧
      PhysicalIdentityFact objects next fact := by
  have canonical : ∀ event ∈ [logEvent (state.get (a "session_id")) entry now], BinaryKeys event := by
    intro event member
    obtain rfl := List.mem_singleton.mp member
    exact compact_binary_keys _
  have allowed : ∀ event ∈ [logEvent (state.get (a "session_id")) entry now], Command.inputEventAllowed event = true := by
    intro event member
    obtain rfl := List.mem_singleton.mp member
    simp +decide [Command.inputEventAllowed, log_event_kind]
  have nextHistory := history.admitted execution canonical allowed
  obtain ⟨reduced, _⟩ := resident_routed_reduces execution (by
    intro event member
    obtain rfl := List.mem_singleton.mp member
    exact log_event_routed _ _ _)
  cases reduced with
  | cons call activity tail =>
    cases tail
    rename_i reduced journal rest
    have actual : transcriptLog state (logEvent (state.get (a "session_id")) entry now) journal = .ok (reduced, rest) := by
      simpa +decide [inner, log_event_kind] using call
    obtain ⟨fact, origin, stored⟩ := transcriptLog_logical history.receipts actual
    refine ⟨fact, origin, identity_fact_physical nextHistory.invariant.images ?_⟩
    exact identity_fact_preserves
      (fun _ work => ValueSemantics.execution_preserves
        (fun _ before => (concrete_representation_frame (activity_frame_work activity)).mp before)
        (fun _ before => record_survives (activity_frame_extends activity) before) work)
      (fun _ before => record_survives (activity_frame_extends activity) before) stored

theorem transcriptLog_physical {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {state event next : Term} {sealed journal rest : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (call : transcriptLog state event journal = .ok (next, rest)) :
    ∃ fact, LogFactOrigin event fact ∧ PhysicalIdentityFact objects next fact := by
  rcases log_record_or_duplicate call with ⟨⟨key, member, present⟩, same⟩ | ⟨record, _, stored, fields⟩
  · obtain ⟨original, fact, origin, supported⟩ := history.receipts key present
    rw [same]
    exact ⟨fact, Or.inr ⟨key, original, member, origin⟩,
      identity_fact_physical history.invariant.images supported⟩
  · exact ⟨.record record, Or.inl ⟨record, rfl, fields⟩,
      record, ValueSemantics.Equivalent.refl _, Or.inl stored⟩

end VerifiedKernel.Session.WorkConservation
