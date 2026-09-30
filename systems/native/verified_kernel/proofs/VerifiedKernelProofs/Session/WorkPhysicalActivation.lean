import VerifiedKernelProofs.Session.WorkPhysicalPreservation
import VerifiedKernelProofs.Session.WorkActivationWrite

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

theorem activation_nonretiring {event : Term} (kind : ActivationEvent event) : NonRetiring event := by
  rcases kind with kind | kind | kind | kind
  all_goals
    unfold NonRetiring
    rw [kind]
    simp +decide [b, Term.text]

theorem activationStarted_owner {state raw next : Term} {journal rest : List Term}
    (call : activationStarted state raw journal = .ok (next, rest)) : OwnerFrame state next := by
  unfold activationStarted at call
  owner_walk call

theorem activationFinished_owner {state identity next : Term} {journal rest : List Term}
    (call : activationFinished state identity journal = .ok (next, rest)) : OwnerFrame state next := by
  unfold activationFinished at call
  owner_walk call

theorem statusTransition_owner {state event next : Term} {journal rest : List Term}
    (call : statusTransition state event journal = .ok (next, rest)) : OwnerFrame state next := by
  unfold statusTransition at call
  repeat' first
    | exact owner_write call rfl
    | (have same := pure_ok call; cases same; rfl)
    | (simp only [inspectedError, fail_ok_iff] at call)
    | split at call

theorem activation_inner_owner {state event next : Term} {journal rest : List Term}
    (kind : ActivationEvent event) (call : inner state event journal = .ok (next, rest)) : OwnerFrame state next := by
  rcases kind with kind | kind | kind | kind
  · simp +decide [inner, kind] at call
    split at call
    · exact activationStarted_owner call
    · rw [pure_ok call]; rfl
  · simp +decide [inner, kind] at call
    split at call
    · exact activationFinished_owner call
    · rw [pure_ok call]; rfl
  · exact owner_write (by simpa +decide [inner, kind, metadataPrompt] using call) rfl
  · exact statusTransition_owner (by simpa +decide [inner, kind] using call)

theorem activation_batch_owner {state next : Term} {events : List Term}
    (execution : ResidentBatch state events next) (batch : ActivationBatch events) : OwnerFrame state next := by
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
        exact activation_inner_owner (batch _ List.mem_cons_self).2 call
    exact (ih (fun event member => batch event (List.mem_cons_of_mem _ member))).trans
      ((activity "agent_id" (by decide) (by decide)).trans frame)

theorem PhysicalHistory.activation {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {state next : Term} {sealed events : List Term}
    (history : PhysicalHistory framing objects owner session state sealed)
    (execution : ResidentBatch state events next) (batch : ActivationBatch events) :
    PhysicalHistory framing objects owner session next sealed ∧
      ∀ item, PhysicalIdentityFact objects state (.work item) → PhysicalIdentityFact objects next (.work item) := by
  have canonical := fun event member => (batch event member).1
  have safe := fun event member => activation_nonretiring (batch event member).2
  have ownerFrame := activation_batch_owner execution batch
  exact ⟨history.nonretiring execution canonical safe ownerFrame,
    history.nonretiring_physical execution canonical safe ownerFrame⟩

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.PendingRevision
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem activation_write_physical {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {cursor final : Cursor} {sealed events : List Term} {hwm : Term}
    (history : PhysicalHistory framing objects owner session cursor.working sealed)
    (batch : ActivationBatch events)
    (execution : Execution (resident (some cursor.pack) (a "write") (.tuple [list events, hwm])) final) :
    PhysicalHistory framing objects owner session final.working sealed ∧
      ∀ item, PhysicalIdentityFact objects cursor.working (.work item) → PhysicalIdentityFact objects final.working (.work item) := by
  obtain ⟨_, _, _, _, _, _, applied⟩ := write_executes execution
  obtain ⟨middle, activationBatch, hwmBatch⟩ := resident_batch_append applied
  obtain ⟨middleHistory, kept⟩ := history.activation activationBatch batch
  obtain ⟨keys, metadata⟩ := hwm_metadata hwm
  exact ⟨middleHistory.metadata hwmBatch keys metadata, fun item present =>
    middleHistory.metadata_physical hwmBatch keys metadata item (kept item present)⟩

end VerifiedKernel.Session.PendingRevision
