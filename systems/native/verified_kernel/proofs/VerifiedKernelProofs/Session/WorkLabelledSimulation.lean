import VerifiedKernelProofs.Session.WorkObserverSimulation

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication
set_option Elab.async false

inductive ProductLabel where
  | accepted (observer : FactProtocol.Observer)
  | confirmed (observer : FactProtocol.Observer)

def ProductLabel.observer : ProductLabel → FactProtocol.Observer
  | .accepted observer | .confirmed observer => observer

def ProductLabel.apply (state : FactProtocol.State) : ProductLabel → FactProtocol.State
  | .accepted observer => FactProtocol.accept state observer
  | .confirmed observer => FactProtocol.acknowledge state observer

/-- An intermediate simulation certificate. Native episode theorems must derive each `backed` field;
this certificate is not the runtime producer domain. Labels never register facts. -/
inductive LabelledTrace (versions : VersionBytes) : ResidentWorld → ResidentWorld → List ProductLabel → Prop where
  | done (world : ResidentWorld) : LabelledTrace versions world world []
  | store {before middle after : ResidentWorld} {labels : List ProductLabel}
      (step : ResidentStep versions before middle) (tail : LabelledTrace versions middle after labels) :
      LabelledTrace versions before after labels
  | emit {before after : ResidentWorld} {labels : List ProductLabel} (label : ProductLabel)
      (backed : ObserverBacked before.store label.observer)
      (tail : LabelledTrace versions before after labels) :
      LabelledTrace versions before after (label :: labels)

/-- Each concrete label appears in order; all intervening abstract steps only register facts. -/
theorem LabelledTrace.trans {versions : VersionBytes} {before middle after : ResidentWorld}
    {left right : List ProductLabel} (first : LabelledTrace versions before middle left)
    (last : LabelledTrace versions middle after right) :
    LabelledTrace versions before after (left ++ right) := by
  induction first with
  | done => exact last
  | store step tail ih => exact .store step (ih last)
  | emit label backed tail ih => exact .emit label backed (ih last)

inductive LabelSimulation : FactProtocol.State → FactProtocol.State → List ProductLabel → Prop where
  | done (state : FactProtocol.State) : LabelSimulation state state []
  | storage {before after : FactProtocol.State} {labels : List ProductLabel}
      (observers : List FactProtocol.Observer)
      (tail : LabelSimulation (FactProtocol.registerMany before observers) after labels) :
      LabelSimulation before after labels
  | emit {before after : FactProtocol.State} {labels : List ProductLabel} (label : ProductLabel)
      (ready : label.observer ∈ before.registered)
      (tail : LabelSimulation (label.apply before) after labels) :
      LabelSimulation before after (label :: labels)

theorem LabelSimulation.trace {before after : FactProtocol.State} {labels : List ProductLabel}
    (simulation : LabelSimulation before after labels) : FactProtocol.Trace before after := by
  induction simulation with
  | done => exact .done _
  | storage observers tail ih => exact (FactProtocol.registerMany_trace _ observers).trans ih
  | emit label ready tail ih =>
    cases label with
    | accepted observer => exact .next (.accept _ observer ready) ih
    | confirmed observer => exact .next (.acknowledge _ observer ready) ih

theorem LabelSimulation.labels {before after : FactProtocol.State} {labels : List ProductLabel}
    (simulation : LabelSimulation before after labels) :
    ∀ label ∈ labels, match label with
      | .accepted observer => observer ∈ after.accepted
      | .confirmed observer => observer ∈ after.acknowledged := by
  induction simulation with
  | done => simp
  | storage observers tail ih => exact ih
  | emit head ready tail ih =>
    intro label member
    rcases List.mem_cons.mp member with rfl | remaining
    · cases label with
      | accepted observer => exact tail.trace.accepted_preserves observer (List.mem_append_right _ List.mem_cons_self)
      | confirmed observer => exact tail.trace.acknowledged_preserves observer (List.mem_append_right _ List.mem_cons_self)
    · exact ih label remaining

theorem labelled_trace_simulation {framing : CodecFraming} {versions : VersionBytes}
    {before after : ResidentWorld} {tracked : List FactProtocol.Observer} {abstract : FactProtocol.State}
    {labels : List ProductLabel}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (valid : ResidentInvariant framing versions before)
    (relation : ObserverRelation tracked before.store abstract)
    (trackedLabels : ∀ label ∈ labels, label.observer ∈ tracked)
    (trace : LabelledTrace versions before after labels) :
    ∃ next, LabelSimulation abstract next labels ∧ ObserverRelation tracked after.store next := by
  induction trace generalizing abstract with
  | done => exact ⟨abstract, .done _, relation⟩
  | store step tail ih =>
    have invariant := step.invariant codec roundtrip valid
    have nextRelation := observer_register_new relation invariant.2.2
    obtain ⟨next, simulated, finalRelation⟩ := ih invariant.1 nextRelation trackedLabels
    exact ⟨next, .storage _ simulated, finalRelation⟩
  | @emit before after labels label backed tail ih =>
    have ready := relation.2 label.observer (trackedLabels _ List.mem_cons_self) backed
    have nextRelation : ObserverRelation tracked before.store (label.apply abstract) := by
      cases label <;> exact relation
    obtain ⟨next, simulated, finalRelation⟩ := ih valid nextRelation
      (fun label member => trackedLabels label (List.mem_cons_of_mem _ member))
    exact ⟨next, .emit label ready simulated, finalRelation⟩

theorem labelled_execution_safety {framing : CodecFraming} {versions : VersionBytes}
    {world : ResidentWorld} {labels : List ProductLabel}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (trace : LabelledTrace versions ResidentInitial world labels) :
    ∃ abstract, LabelSimulation {} abstract labels ∧
      ObserverRelation (labels.map ProductLabel.observer) world.store abstract ∧
      ∀ label ∈ labels, ObserverBacked world.store label.observer := by
  obtain ⟨abstract, simulation, relation⟩ := labelled_trace_simulation codec roundtrip
    (resident_initial_invariant framing versions) (observer_initial (labels.map ProductLabel.observer))
    (fun label member => List.mem_map.mpr ⟨label, member, rfl⟩) trace
  refine ⟨abstract, simulation, relation, ?_⟩
  intro label member
  have recorded := simulation.labels label member
  cases label with
  | accepted observer => exact observer_accepted_conserved simulation.trace relation recorded
  | confirmed observer => exact observer_acknowledgment_durable simulation.trace relation recorded

end VerifiedKernel.Session.WorkConservation.CurrentExecution
