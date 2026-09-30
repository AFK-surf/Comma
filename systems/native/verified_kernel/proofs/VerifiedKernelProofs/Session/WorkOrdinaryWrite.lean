import VerifiedKernelProofs.Session.WorkOwnerControlFrame
import VerifiedKernelProofs.Session.WorkPhysicalRecords
import VerifiedKernelProofs.Session.WorkOrdinaryKinds

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

set_option maxHeartbeats 1000000 in
theorem ordinary_kind_owner {state event next : Term} {journal rest : List Term}
    (kind : OrdinaryKind (event.get (b "type")))
    (call : inner state event journal = .ok (next, rest)) : OwnerControlFrame state next := by
  unfold inner at call
  simp only [binary_ne_false kind.1, binary_ne_false kind.2.1,
    binary_ne_false kind.2.2.1, binary_ne_false kind.2.2.2, Bool.false_and, Bool.false_eq_true,
    if_false, ite_ok_iff] at call
  owner_control_frame_walk call

theorem ordinary_batch_owner {state next : Term} {events : List Term}
    (execution : ResidentBatch state events next) (batch : OrdinaryBatch events) : OwnerFrame state next := by
  induction execution with
  | nil => rfl
  | @cons state next final event events observations head tail ih =>
    obtain ⟨middle, normalized, journal, rest, prepared, activity⟩ := resident_execution_step head
    have frame : OwnerFrame state middle := by
      cases normalized with
      | none => rw [prepareTrusted_none prepared]; rfl
      | some normalized =>
        obtain ⟨_, read, _, call⟩ := prepareTrusted_stringify prepared
        have same := shallowStringify_binary_keys (batch _ List.mem_cons_self).1 read
        subst normalized
        exact ordinary_kind_owner (batch _ List.mem_cons_self).2 call
    exact (ih (fun event member => batch event (List.mem_cons_of_mem _ member))).trans
      ((activity "agent_id" (by decide) (by decide)).trans frame)

theorem PhysicalHistory.ordinary {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {state next : Term} {sealed events : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (execution : ResidentBatch state events next) (batch : OrdinaryBatch events) :
    PhysicalHistory framing objects owner session next sealed ∧
      ∀ fact, PhysicalIdentityFact objects state fact → PhysicalIdentityFact objects next fact := by
  have canonical := fun event member => (batch event member).1
  have safe : ∀ event ∈ events, NonRetiring event := fun event member =>
    ⟨(batch event member).2.1, (batch event member).2.2.1, (batch event member).2.2.2.1⟩
  have owner := ordinary_batch_owner execution batch
  refine ⟨history.nonretiring execution canonical safe owner, ?_⟩
  intro fact present
  cases fact with
  | work item => exact history.nonretiring_physical execution canonical safe owner item present
  | record reference => exact history.nonretiring_records execution canonical safe owner reference present

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.PendingRevision
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem ordinary_write_physical {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {cursor final : Cursor} {sealed events : List Term} {hwm : Term}
    (history : PhysicalHistory framing objects owner session cursor.working sealed)
    (batch : OrdinaryBatch events)
    (execution : Execution (resident (some cursor.pack) (a "write") (.tuple [list events, hwm])) final) :
    final.etag = cursor.etag ∧ PhysicalHistory framing objects owner session final.working sealed ∧
      ∀ fact, PhysicalIdentityFact objects cursor.working fact → PhysicalIdentityFact objects final.working fact := by
  obtain ⟨_, _, _, token, _, _, applied⟩ := write_executes execution
  obtain ⟨middle, ordinaryBatch, hwmBatch⟩ := resident_batch_append applied
  obtain ⟨middleHistory, kept⟩ := history.ordinary ordinaryBatch batch
  obtain ⟨keys, metadata⟩ := hwm_metadata hwm
  refine ⟨token, middleHistory.metadata hwmBatch keys metadata, ?_⟩
  intro fact present
  cases fact with
  | work item => exact middleHistory.metadata_physical hwmBatch keys metadata item (kept _ present)
  | record reference => exact middleHistory.metadata_records hwmBatch keys metadata reference (kept _ present)

end VerifiedKernel.Session.PendingRevision
