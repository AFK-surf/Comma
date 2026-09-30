import VerifiedKernelProofs.Session.WorkFactProtocol
import VerifiedKernelProofs.Session.WorkResidentTrace

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication
set_option Elab.async false

def ObserverBacked (world : World) (observer : FactProtocol.Observer) : Prop :=
  world.fact observer.key observer.fact

/-- Soundness and completeness for one fixed finite observer set at storage boundaries. -/
def ObserverRelation (tracked : List FactProtocol.Observer) (world : World) (abstract : FactProtocol.State) : Prop :=
  (∀ observer ∈ abstract.registered, observer ∈ tracked ∧ ObserverBacked world observer) ∧
  (∀ observer ∈ tracked, ObserverBacked world observer → observer ∈ abstract.registered)

noncomputable def newlyBacked (tracked : List FactProtocol.Observer) (world : World)
    (abstract : FactProtocol.State) : List FactProtocol.Observer := by
  classical
  exact tracked.filter (fun observer => decide (ObserverBacked world observer ∧ observer ∉ abstract.registered))

theorem newlyBacked_member {tracked : List FactProtocol.Observer} {world : World} {abstract : FactProtocol.State}
    {observer : FactProtocol.Observer} : observer ∈ newlyBacked tracked world abstract ↔
      observer ∈ tracked ∧ ObserverBacked world observer ∧ observer ∉ abstract.registered := by
  classical
  simp [newlyBacked]

theorem observer_initial (tracked : List FactProtocol.Observer) : ObserverRelation tracked Initial {} := by
  refine ⟨by simp, ?_⟩
  intro observer member backed
  obtain ⟨etag, bytes, decoded, read, _, _⟩ := backed
  cases read

theorem observer_register_new {tracked : List FactProtocol.Observer} {before after : World}
    {abstract : FactProtocol.State} (relation : ObserverRelation tracked before abstract)
    (kept : ∀ key fact, before.fact key fact → after.fact key fact) :
    ObserverRelation tracked after
      (FactProtocol.registerMany abstract (newlyBacked tracked after abstract)) := by
  classical
  constructor
  · intro observer member
    rw [FactProtocol.registerMany_registered] at member
    rcases List.mem_append.mp member with old | fresh
    · obtain ⟨included, backed⟩ := relation.1 observer old
      exact ⟨included, kept _ _ backed⟩
    · obtain ⟨included, backed, _⟩ := newlyBacked_member.mp fresh
      exact ⟨included, backed⟩
  · intro observer member backed
    rw [FactProtocol.registerMany_registered]
    by_cases old : observer ∈ abstract.registered
    · exact List.mem_append_left _ old
    · exact List.mem_append_right _ (newlyBacked_member.mpr ⟨member, backed, old⟩)

/-- A read, return, or other step with unchanged storage cannot register a fact. -/
theorem newlyBacked_requires_storage_change {tracked : List FactProtocol.Observer} {before after : World}
    {abstract : FactProtocol.State} {observer : FactProtocol.Observer}
    (relation : ObserverRelation tracked before abstract)
    (fresh : observer ∈ newlyBacked tracked after abstract) : before ≠ after := by
  intro same
  subst after
  obtain ⟨member, backed, absent⟩ := newlyBacked_member.mp fresh
  exact absent (relation.2 observer member backed)

theorem resident_step_observer_simulation {framing : CodecFraming} {versions : VersionBytes}
    {before after : ResidentWorld} {tracked : List FactProtocol.Observer} {abstract : FactProtocol.State}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (valid : ResidentInvariant framing versions before)
    (relation : ObserverRelation tracked before.store abstract) (step : ResidentStep versions before after) :
    ∃ next, FactProtocol.Trace abstract next ∧ ObserverRelation tracked after.store next := by
  have kept := (step.invariant codec roundtrip valid).2.2
  exact ⟨_, FactProtocol.registerMany_trace _ _, observer_register_new relation kept⟩

theorem resident_trace_observer_simulation {framing : CodecFraming} {versions : VersionBytes}
    {before after : ResidentWorld} {tracked : List FactProtocol.Observer} {abstract : FactProtocol.State}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (valid : ResidentInvariant framing versions before) (relation : ObserverRelation tracked before.store abstract)
    (trace : ResidentTrace versions before after) :
    ∃ next, FactProtocol.Trace abstract next ∧ ObserverRelation tracked after.store next := by
  induction trace generalizing abstract with
  | done => exact ⟨abstract, .done _, relation⟩
  | next step tail ih =>
    obtain ⟨middle, simulated, middleRelation⟩ := resident_step_observer_simulation codec roundtrip valid relation step
    obtain ⟨next, suffix, nextRelation⟩ := ih (step.invariant codec roundtrip valid).1 middleRelation
    exact ⟨next, simulated.trans suffix, nextRelation⟩

/-- Fixed observers may be selected after a finite execution; every registration still occurs at its storage edge. -/
theorem ResidentReachable.observer_simulation {framing : CodecFraming} {versions : VersionBytes}
    {world : ResidentWorld} {past : List ResidentWorld} (tracked : List FactProtocol.Observer)
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (execution : ResidentReachable versions world past) :
    ∃ abstract, FactProtocol.Trace {} abstract ∧ ObserverRelation tracked world.store abstract := by
  induction execution with
  | initial => exact ⟨{}, .done _, observer_initial tracked⟩
  | next prior step ih =>
    obtain ⟨abstract, simulated, relation⟩ := ih
    obtain ⟨next, segment, nextRelation⟩ := resident_step_observer_simulation codec roundtrip
      (prior.conservation (framing := framing) codec roundtrip).1 relation step
    exact ⟨next, simulated.trans segment, nextRelation⟩

theorem observer_confirmation_ready {tracked : List FactProtocol.Observer} {world : World}
    {abstract : FactProtocol.State} {observer : FactProtocol.Observer}
    (relation : ObserverRelation tracked world abstract) (included : observer ∈ tracked)
    (backed : ObserverBacked world observer) :
    FactProtocol.Trace abstract (FactProtocol.acknowledge abstract observer) ∧
      ObserverRelation tracked world (FactProtocol.acknowledge abstract observer) :=
  ⟨.next (.acknowledge _ _ (relation.2 observer included backed)) (.done _), relation⟩

/-- The existing abstract conservation theorem transfers back to current physical bytes. -/
theorem observer_acknowledgment_durable {tracked : List FactProtocol.Observer} {world : World}
    {abstract : FactProtocol.State} {observer : FactProtocol.Observer}
    (trace : FactProtocol.Trace {} abstract) (relation : ObserverRelation tracked world abstract)
    (acknowledged : observer ∈ abstract.acknowledged) : ObserverBacked world observer :=
  (relation.1 observer (FactProtocol.acknowledged_registered trace acknowledged)).2

theorem observer_acceptance_ready {tracked : List FactProtocol.Observer} {world : World}
    {abstract : FactProtocol.State} {observer : FactProtocol.Observer}
    (relation : ObserverRelation tracked world abstract) (included : observer ∈ tracked)
    (backed : ObserverBacked world observer) :
    FactProtocol.Trace abstract (FactProtocol.accept abstract observer) ∧
      ObserverRelation tracked world (FactProtocol.accept abstract observer) :=
  ⟨.next (.accept _ _ (relation.2 observer included backed)) (.done _), relation⟩

theorem observer_accepted_conserved {tracked : List FactProtocol.Observer} {world : World}
    {abstract : FactProtocol.State} {observer : FactProtocol.Observer}
    (trace : FactProtocol.Trace {} abstract) (relation : ObserverRelation tracked world abstract)
    (accepted : observer ∈ abstract.accepted) : ObserverBacked world observer :=
  (relation.1 observer (FactProtocol.accepted_registered trace accepted)).2

end VerifiedKernel.Session.WorkConservation.CurrentExecution
