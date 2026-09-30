import VerifiedKernelProofs.Session.WorkPhysicalHistory
import VerifiedKernelProofs.Session.WorkPhysicalTransport

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

theorem PhysicalHistory.admitted_physical {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {sealed events : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (execution : ResidentBatch state events next)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (allowed : ∀ event ∈ events, Command.inputEventAllowed event = true) :
    ∀ item, PhysicalIdentityFact objects state (.work item) → PhysicalIdentityFact objects next (.work item) := by
  have fields := batch_catalog_frame execution canonical
    (fun event member => binary_ne_false (admitted_nonretiring (allowed event member)).2.2)
  apply physical_work_transport (fun _ _ stored => stored)
    (admitted_resident_owner execution canonical allowed) fields.2.2
  · intro value member
    simpa only [fields.1] using member
  · exact fun _ present => Or.inl (ValueSemantics.resident_input_preserves execution
      history.invariant.history.invariant.ready canonical allowed present)

theorem PhysicalHistory.metadata_physical {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {sealed events : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (execution : ResidentBatch state events next)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (metadata : ∀ event ∈ events, CommitMetadata event) :
    ∀ item, PhysicalIdentityFact objects state (.work item) → PhysicalIdentityFact objects next (.work item) := by
  have fields := metadata_batch_archive_frame execution canonical metadata
  have nextHistory := history.metadata execution canonical metadata
  apply physical_work_transport (fun _ _ stored => stored)
    (nextHistory.invariant.owned.trans history.invariant.owned.symm)
    (nextHistory.invariant.identified.trans history.invariant.identified.symm)
  · intro value member
    simpa only [fields.1] using member
  · exact fun item present => Or.inl ((ValueSemantics.metadata_work execution canonical metadata
      history.invariant.history.invariant.ready).2.2 [] item present)

theorem PhysicalHistory.materialize_framed_physical {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state projected next : Term} {sealed events journal rest : List Term}
    {limit : Int} {wake : Bool} {hwm : Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (queue : projected.get (a "input_queue") = state.get (a "input_queue"))
    (ack : projected.get (a "queue_ack_id") = state.get (a "queue_ack_id"))
    (sessionEq : state.get (a "session_id") = projected.get (a "session_id"))
    (planned : StateQuery.materialize projected limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
    (execution : ResidentBatch state events next) :
    ∀ item, PhysicalIdentityFact objects state (.work item) → PhysicalIdentityFact objects next (.work item) := by
  have fields := materialize_catalog_frame planned execution
  apply physical_work_transport (fun _ _ stored => stored) (materialize_owner planned execution) fields.2.2
  · intro value member
    simpa only [fields.1] using member
  · exact fun item present => Or.inl ((materialize_framed_work history.invariant.history.invariant.ready
      queue ack sessionEq planned execution).2 [] item present)

theorem PhysicalHistory.normalize_physical {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {sealed journal rest : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (call : Lifecycle.normalize state journal = .ok (next, rest)) :
    ∀ item, PhysicalIdentityFact objects state (.work item) → PhysicalIdentityFact objects next (.work item) := by
  obtain ⟨catalog, watermark, read, through, valid⟩ := history.invariant.archive
  have fields := normalize_archive_fields read through valid call
  apply physical_work_transport (fun _ _ stored => stored)
    (normalize_owner history.invariant.owner_not_nil call)
    (normalize_session_id history.invariant.session_not_nil call)
  · intro value member
    simpa only [fields.1, read] using member
  · exact fun _ present => Or.inl (ValueSemantics.normalize_preserves
      history.invariant.history.invariant.ready call present)

theorem PhysicalHistory.decode_physical {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {sealed : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (codec : ValueSemantics.Equivalent state next) :
    ∀ item, PhysicalIdentityFact objects state (.work item) → PhysicalIdentityFact objects next (.work item) := by
  obtain ⟨catalog, watermark, read, through, valid⟩ := history.invariant.archive
  exact physical_work_equivalent codec history.invariant.owned history.invariant.identified read valid

theorem PhysicalHistory.prepare_physical {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {sealed journal rest : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (call : Lifecycle.prepareWrite state journal = .ok (.tuple [a "ok", next], rest)) :
    ∀ item, PhysicalIdentityFact objects state (.work item) → PhysicalIdentityFact objects next (.work item) := by
  obtain ⟨catalog, watermark, read, through, valid⟩ := history.invariant.archive
  have fields := prepareWrite_archive_fields history.invariant.history.invariant.format read through valid call
  have nextHistory := history.prepare call
  apply physical_work_transport (fun _ _ stored => stored)
    (nextHistory.invariant.owned.trans history.invariant.owned.symm)
    (nextHistory.invariant.identified.trans history.invariant.identified.symm)
  · intro value member
    simpa only [fields.1, read] using member
  · exact fun _ present => Or.inl (ValueSemantics.prepareWrite_preserves
      history.invariant.history.invariant.ready history.invariant.history.invariant.format call present)

theorem PhysicalHistory.persist_physical {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {sealed journal rest : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (call : Lifecycle.persistable state journal = .ok (next, rest)) :
    ∀ item, PhysicalIdentityFact objects state (.work item) → PhysicalIdentityFact objects next (.work item) := by
  have fields := persistable_archive_fields call
  have nextHistory := history.persist call
  apply physical_work_transport (fun _ _ stored => stored)
    (nextHistory.invariant.owned.trans history.invariant.owned.symm)
    (nextHistory.invariant.identified.trans history.invariant.identified.symm)
  · intro value member
    simpa only [fields.1] using member
  · exact fun _ present => Or.inl (ValueSemantics.work_fields_preserves (persistable_work_fields call) present)

theorem PhysicalHistory.nonretiring_physical {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {sealed events : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (execution : ResidentBatch state events next) (canonical : ∀ event ∈ events, BinaryKeys event)
    (safe : ∀ event ∈ events, NonRetiring event) (ownerFrame : OwnerFrame state next) :
    ∀ item, PhysicalIdentityFact objects state (.work item) → PhysicalIdentityFact objects next (.work item) := by
  have fields := batch_catalog_frame execution canonical
    (fun event member => binary_ne_false (safe event member).2.2)
  apply physical_work_transport (fun _ _ stored => stored) ownerFrame fields.2.2
  · intro value member
    simpa only [fields.1] using member
  · exact fun item present => Or.inl ((nonretiring_batch_preserves execution
      history.invariant.history.invariant.ready history.invariant.history.invariant.format canonical safe).2.2 [] item present)

end VerifiedKernel.Session.WorkConservation
