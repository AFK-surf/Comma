import VerifiedKernelProofs.Session.WorkCurrentConfirmation
import VerifiedKernelProofs.Session.WorkPhysicalArchive

namespace VerifiedKernel.Session.ArchivePublication
open Data WorkConservation
set_option Elab.async false

theorem physical_record_transport {before after : Objects} {state next : Term}
    (extension : ObjectsExtend before after)
    (owner : next.get (a "agent_id") = state.get (a "agent_id"))
    (session : next.get (a "session_id") = state.get (a "session_id"))
    (catalog : ∀ value ∈ wrap ((state.get (a "segment_catalog")).default (list [])),
      value ∈ wrap ((next.get (a "segment_catalog")).default (list [])))
    (live : ∀ record, ContainsRecord state record → PhysicalIdentityFact after next (.record record)) :
    ∀ reference, PhysicalIdentityFact before state (.record reference) →
      PhysicalIdentityFact after next (.record reference) := by
  intro reference present
  obtain ⟨record, same, stored | archived⟩ := present
  · obtain ⟨value, related, retained⟩ := live record stored
    exact ⟨value, same.trans related, retained⟩
  · refine ⟨record, same, Or.inr ?_⟩
    rw [owner, session]
    obtain ⟨projected, projection, stored⟩ := archived
    exact ⟨projected, projection, (stored.mono extension).catalog_mono catalog⟩

theorem physical_identity_objects {before after : Objects} {state : Term} {fact : IdentityFact}
    (extension : ObjectsExtend before after) (present : PhysicalIdentityFact before state fact) :
    PhysicalIdentityFact after state fact := by
  cases fact with
  | work item => exact physical_work_objects extension item present
  | record reference =>
    exact physical_record_transport extension rfl rfl (fun _ h => h)
      (fun record stored => ⟨record, ValueSemantics.Equivalent.refl _, Or.inl stored⟩) reference present

end VerifiedKernel.Session.ArchivePublication

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

theorem nonretiring_batch_extends {state next : Term} {events : List Term}
    (execution : ResidentBatch state events next) (format : state.get (a "storage_format") = i 3)
    (canonical : ∀ event ∈ events, BinaryKeys event) (safe : ∀ event ∈ events, NonRetiring event) :
    TranscriptExtends state next := by
  induction execution with
  | nil => exact extends_refl _
  | cons head tail ih =>
    have nextFormat := (resident_step_format (resident_execution_step head)).trans format
    have tailExtends := ih nextFormat (fun e h => canonical e (List.mem_cons_of_mem _ h))
      (fun e h => safe e (List.mem_cons_of_mem _ h))
    obtain ⟨middle, normalized, journal, rest, prepared, activity⟩ := resident_execution_step head
    apply extends_trans ?_ tailExtends
    cases normalized with
    | none =>
      rw [prepareTrusted_none prepared] at activity
      exact activity_frame_extends activity
    | some normalized =>
      obtain ⟨_, read, _, call⟩ := prepareTrusted_stringify prepared
      have same := shallowStringify_binary_keys (canonical _ List.mem_cons_self) read
      subst normalized
      exact extends_trans (nonretiring_inner_extends format (safe _ List.mem_cons_self) call)
        (activity_frame_extends activity)

theorem PhysicalHistory.record_frame {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {sealed nextSealed : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (nextHistory : PhysicalHistory framing objects owner session next nextSealed)
    (catalog : next.get (a "segment_catalog") = state.get (a "segment_catalog"))
    (records : ∀ record, ContainsRecord state record → ContainsRecord next record) :
    ∀ reference, PhysicalIdentityFact objects state (.record reference) →
      PhysicalIdentityFact objects next (.record reference) :=
  physical_record_transport (fun _ _ h => h)
    (nextHistory.invariant.owned.trans history.invariant.owned.symm)
    (nextHistory.invariant.identified.trans history.invariant.identified.symm)
    (fun _ h => by simpa only [catalog] using h)
    (fun record stored => ⟨record, ValueSemantics.Equivalent.refl _, Or.inl (records record stored)⟩)

theorem PhysicalHistory.admitted_records {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {sealed events : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (execution : ResidentBatch state events next) (canonical : ∀ event ∈ events, BinaryKeys event)
    (allowed : ∀ event ∈ events, Command.inputEventAllowed event = true) :
    ∀ reference, PhysicalIdentityFact objects state (.record reference) →
      PhysicalIdentityFact objects next (.record reference) := by
  have fields := batch_catalog_frame execution canonical
    (fun event member => binary_ne_false (admitted_nonretiring (allowed event member)).2.2)
  exact history.record_frame (history.admitted execution canonical allowed) fields.1
    (fun _ stored => record_survives (ValueSemantics.resident_input_batch_extends execution canonical allowed) stored)

theorem PhysicalHistory.nonretiring_records {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {sealed events : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (execution : ResidentBatch state events next) (canonical : ∀ event ∈ events, BinaryKeys event)
    (safe : ∀ event ∈ events, NonRetiring event) (ownerFrame : OwnerFrame state next) :
    ∀ reference, PhysicalIdentityFact objects state (.record reference) →
      PhysicalIdentityFact objects next (.record reference) := by
  have fields := batch_catalog_frame execution canonical (fun event member => binary_ne_false (safe event member).2.2)
  exact history.record_frame (history.nonretiring execution canonical safe ownerFrame) fields.1
    (fun _ stored => record_survives
      (nonretiring_batch_extends execution history.invariant.history.invariant.format canonical safe) stored)

theorem PhysicalHistory.metadata_records {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {sealed events : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (execution : ResidentBatch state events next) (canonical : ∀ event ∈ events, BinaryKeys event)
    (metadata : ∀ event ∈ events, CommitMetadata event) :
    ∀ reference, PhysicalIdentityFact objects state (.record reference) →
      PhysicalIdentityFact objects next (.record reference) :=
  history.nonretiring_records execution canonical
    (fun event member => commit_metadata_nonretiring (metadata event member))
    (commit_metadata_batch_frames execution canonical metadata).2.2

theorem PhysicalHistory.normalize_records {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {sealed journal rest : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (call : Lifecycle.normalize state journal = .ok (next, rest)) :
    ∀ reference, PhysicalIdentityFact objects state (.record reference) →
      PhysicalIdentityFact objects next (.record reference) := by
  obtain ⟨catalog, watermark, read, through, valid⟩ := history.invariant.archive
  exact history.record_frame (history.normalize call)
    ((normalize_archive_fields read through valid call).1.trans read.symm)
    (fun _ stored => ValueSemantics.normalize_records history.invariant.history.invariant.ready call stored)

theorem PhysicalHistory.materialize_records {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state projected next : Term} {sealed events journal rest : List Term}
    {limit : Int} {wake : Bool} {hwm : Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (queue : projected.get (a "input_queue") = state.get (a "input_queue"))
    (ack : projected.get (a "queue_ack_id") = state.get (a "queue_ack_id"))
    (sessionEq : state.get (a "session_id") = projected.get (a "session_id"))
    (planned : StateQuery.materialize projected limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
    (execution : ResidentBatch state events next) :
    ∀ reference, PhysicalIdentityFact objects state (.record reference) →
      PhysicalIdentityFact objects next (.record reference) := by
  have routed := materialize_routed planned
  rw [← sessionEq] at routed
  obtain ⟨reduced, _⟩ := resident_routed_reduces execution routed
  exact history.record_frame (history.materialize_framed queue ack sessionEq planned execution)
    (materialize_catalog_frame planned execution).1
    (fun _ stored => record_survives (resident_reduced_extends reduced (materialize_ordinary planned)) stored)

theorem prepareWrite_records {state next record : Term} {journal rest : List Term}
    (ready : QueueReady state) (format : state.get (a "storage_format") = i 3)
    (call : Lifecycle.prepareWrite state journal = .ok (.tuple [a "ok", next], rest))
    (present : ContainsRecord state record) : ContainsRecord next record := by
  unfold Lifecycle.prepareWrite at call
  obtain ⟨normalized, _, normalizedRead, call⟩ := bind_ok call
  have stored := ValueSemantics.normalize_records ready normalizedRead present
  have normalizedFormat := normalize_format format normalizedRead
  obtain ⟨value, _, valueRead, call⟩ := bind_ok call
  have same := (field_value valueRead).trans normalizedFormat
  subst value
  simp only [show (i 3 == i 1) = false from rfl,
    show (i 3 == i 2 || i 3 == i 3) = true from rfl, Bool.false_eq_true, ↓reduceIte] at call
  obtain ⟨written, _, writeCall, call⟩ := bind_ok call
  have same : next = written := by
    simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using pure_ok call
  subst written
  simpa only [ContainsRecord, write_field_frame (key := "messages") writeCall rfl] using stored

theorem PhysicalHistory.prepare_records {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {sealed journal rest : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (call : Lifecycle.prepareWrite state journal = .ok (.tuple [a "ok", next], rest)) :
    ∀ reference, PhysicalIdentityFact objects state (.record reference) →
      PhysicalIdentityFact objects next (.record reference) := by
  obtain ⟨catalog, watermark, read, through, valid⟩ := history.invariant.archive
  exact history.record_frame (history.prepare call)
    ((prepareWrite_archive_fields history.invariant.history.invariant.format read through valid call).1.trans read.symm)
    (fun _ stored => prepareWrite_records history.invariant.history.invariant.ready
      history.invariant.history.invariant.format call stored)

theorem PhysicalHistory.persist_records {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {sealed journal rest : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (call : Lifecycle.persistable state journal = .ok (next, rest)) :
    ∀ reference, PhysicalIdentityFact objects state (.record reference) →
      PhysicalIdentityFact objects next (.record reference) :=
  history.record_frame (history.persist call) (persistable_archive_fields call).1
    (fun _ stored => by simpa only [ContainsRecord, (persistable_work_fields call).2] using stored)

theorem PhysicalHistory.publish_records {framing : CodecFraming} {objects nextObjects : Objects}
    {owner session : ByteArray} {state event next : Term} {sealed records : List Term}
    {ceiling line : Int} {final : ArchivePublication.Output}
    (history : PhysicalHistory framing objects owner session state sealed)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0) (publication : Execution (start state (i line)) objects final nextObjects)
    (emitted : final.2 = .tuple [a "advance", event]) (applied : ResidentBatch state [event] next) :
    ∀ reference, PhysicalIdentityFact objects state (.record reference) →
      PhysicalIdentityFact nextObjects next (.record reference) := by
  obtain ⟨dropped, kept, read, after, nextHistory, _⟩ :=
    history.publish_resident window positive publication emitted applied
  apply physical_record_transport (execution_objects_extend publication)
    (nextHistory.invariant.owned.trans history.invariant.owned.symm)
    (nextHistory.invariant.identified.trans history.invariant.identified.symm)
    (history.publish_resident_catalog window positive publication emitted applied)
  intro record stored
  obtain ⟨messages, messageRead, member⟩ := stored
  have same := Term.list.inj (messageRead.symm.trans read)
  rw [same] at member
  rcases List.mem_append.mp member with removed | live
  · exact ⟨record, ValueSemantics.Equivalent.refl _, Or.inr
      (nextHistory.invariant.images record (List.mem_append_right _ removed))⟩
  · exact ⟨record, ValueSemantics.Equivalent.refl _, Or.inl ⟨kept, after, live⟩⟩

end VerifiedKernel.Session.WorkConservation
