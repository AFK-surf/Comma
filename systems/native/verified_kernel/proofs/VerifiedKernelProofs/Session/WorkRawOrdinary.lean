import VerifiedKernelProofs.Session.WorkOrdinaryWrite

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

theorem activity_physical_identities {objects : Objects} {state next : Term}
    (frame : ActivityFrame state next) :
    ∀ fact, PhysicalIdentityFact objects state fact → PhysicalIdentityFact objects next fact := by
  have owner := frame "agent_id" (by decide) (by decide)
  have session := frame "session_id" (by decide) (by decide)
  have catalog := frame "segment_catalog" (by decide) (by decide)
  intro fact
  cases fact with
  | work item =>
    apply physical_work_transport (fun _ _ h => h) owner session
    · intro value member; simpa only [catalog] using member
    · exact fun item present => Or.inl (ValueSemantics.work_fields_preserves (activity_frame_work frame) present)
  | record reference =>
    apply physical_record_transport (fun _ _ h => h) owner session
    · intro value member; simpa only [catalog] using member
    · exact fun record present => ⟨record, ValueSemantics.Equivalent.refl _,
        Or.inl (record_survives (activity_frame_extends frame) present)⟩

theorem PhysicalHistory.raw_ordinary_step {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state event next : Term} {sealed : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (step : ResidentStep state event next) (safe : RawOrdinary event) :
    PhysicalHistory framing objects owner session next sealed ∧
      ∀ fact, PhysicalIdentityFact objects state fact → PhysicalIdentityFact objects next fact := by
  obtain ⟨middle, normalized, journal, rest, prepared, activity⟩ := step
  cases normalized with
  | none =>
    rw [prepareTrusted_none prepared] at activity
    exact ⟨history.activity activity, activity_physical_identities activity⟩
  | some normalized =>
    obtain ⟨_, converted, _, call⟩ := prepareTrusted_stringify prepared
    have kind := safe _ _ _ converted
    have nonretiring : NonRetiring normalized := ⟨kind.1, kind.2.1, kind.2.2.1⟩
    have owner := ordinary_kind_owner kind call
    have middleHistory := history.reduceOrdinary nonretiring owner call
    have fields := inner_catalog_frame (binary_ne_false nonretiring.2.2) call
    refine ⟨middleHistory.activity activity, ?_⟩
    intro fact present
    apply activity_physical_identities activity fact
    cases fact with
    | work item =>
      apply physical_work_transport (fun _ _ h => h) owner fields.2.2 ?_ ?_ item present
      · intro value member; simpa only [fields.1] using member
      · exact fun item present => Or.inl (nonretiring_inner_preserves
          history.invariant.history.invariant.ready history.invariant.history.invariant.format nonretiring call [] item present)
    | record reference =>
      exact history.record_frame middleHistory fields.1
        (fun _ present => record_survives
          (nonretiring_inner_extends history.invariant.history.invariant.format nonretiring call) present) reference present

theorem PhysicalHistory.raw_ordinary {framing : CodecFraming} {objects : Objects}
    {owner session : ByteArray} {state next : Term} {sealed events : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (execution : ResidentBatch state events next) (safe : RawOrdinaryBatch events) :
    PhysicalHistory framing objects owner session next sealed ∧
      ∀ fact, PhysicalIdentityFact objects state fact → PhysicalIdentityFact objects next fact := by
  induction execution with
  | nil => exact ⟨history, fun _ h => h⟩
  | cons head tail ih =>
    have first := history.raw_ordinary_step (resident_execution_step head) (safe _ List.mem_cons_self)
    have last := ih first.1 (fun event member => safe event (List.mem_cons_of_mem _ member))
    exact ⟨last.1, fun fact present => last.2 fact (first.2 fact present)⟩

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.PendingRevision
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem raw_ordinary_write_physical {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {cursor final : Cursor} {sealed events : List Term} {hwm : Term}
    (history : PhysicalHistory framing objects owner session cursor.working sealed)
    (batch : RawOrdinaryBatch events)
    (execution : Execution (resident (some cursor.pack) (a "write") (.tuple [list events, hwm])) final) :
    final.etag = cursor.etag ∧ PhysicalHistory framing objects owner session final.working sealed ∧
      ∀ fact, PhysicalIdentityFact objects cursor.working fact → PhysicalIdentityFact objects final.working fact := by
  obtain ⟨_, _, _, token, _, _, applied⟩ := write_executes execution
  obtain ⟨middle, ordinaryBatch, hwmBatch⟩ := resident_batch_append applied
  obtain ⟨middleHistory, kept⟩ := history.raw_ordinary ordinaryBatch batch
  obtain ⟨keys, metadata⟩ := hwm_metadata hwm
  refine ⟨token, middleHistory.metadata hwmBatch keys metadata, ?_⟩
  intro fact present
  cases fact with
  | work item => exact middleHistory.metadata_physical hwmBatch keys metadata item (kept _ present)
  | record reference => exact middleHistory.metadata_records hwmBatch keys metadata reference (kept _ present)

end VerifiedKernel.Session.PendingRevision
