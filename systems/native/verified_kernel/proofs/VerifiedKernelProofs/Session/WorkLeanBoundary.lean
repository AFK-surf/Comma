import VerifiedKernelProofs.Session.WorkNativeProductTrace
import VerifiedKernelProofs.Session.WorkLeanInputOccurrence

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication
set_option Elab.async false

/-- External reports must match the declared Lean trace, including order and multiplicity.
This hypothesis specifies an external contract. It does not verify external code. -/
theorem NativeProductRun.conditional_safety
    {framing : CodecFraming} {versions : VersionBytes}
    {world : ResidentWorld} {past : List ResidentWorld}
    {prior : ResidentReachable versions world past}
    {receipts : List ProductReceipt} {labels reports : List ProductLabel}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (run : NativeProductRun (framing := framing) codec roundtrip prior receipts labels)
    (externalCorrespondence : reports = labels) :
    (∀ earlier ∈ world :: past, ∀ key fact,
      earlier.store.fact key fact → world.store.fact key fact) ∧
    ∃ abstract, LabelSimulation {} abstract reports ∧
      ObserverRelation (reports.map ProductLabel.observer) world.store abstract ∧
      WorkConservation.Reachable (abstract.protocol false) ∧
      WorkConservation.Reachable (abstract.protocol true) ∧
      (∀ observer, ProductLabel.confirmed observer ∈ reports → ObserverBacked world.store observer) ∧
      (∀ observer, ProductLabel.accepted observer ∈ reports → ObserverBacked world.store observer) := by
  subst reports
  obtain ⟨abstract, simulation, relation, backed⟩ := run.safety codec roundtrip
  exact ⟨(prior.conservation (framing := framing) codec roundtrip).2,
    abstract, simulation, relation, simulation.trace.reachable false, simulation.trace.reachable true,
    fun observer member => backed (.confirmed observer) member,
    fun observer member => backed (.accepted observer) member⟩

/-- The external input contract supplies occurrence correspondence, not durable backing. -/
theorem NativeProductRun.external_input_conserved
    {framing : CodecFraming} {versions : VersionBytes}
    {world : ResidentWorld} {past : List ResidentWorld}
    {prior : ResidentReachable versions world past}
    {receipts : List ProductReceipt} {labels : List ProductLabel}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (_run : NativeProductRun (framing := framing) codec roundtrip prior receipts labels)
    (inputs : List (Term × Term × Term))
    (externalCorrespondence : ∀ input ∈ inputs,
      InputOccurrence versions prior input.1 input.2.1 input.2.2) :
    ∀ input ∈ inputs, ∃ session event now first last item,
      Command.inputEvent session input.2.1 input.2.2 now first = .ok (event, last) ∧
      MainTermInputFact event input.2.1 item ∧ CanonicalQueueItem item ∧ world.store.work input.1 item := by
  intro input member
  exact (externalCorrespondence input member).conserved (framing := framing) codec roundtrip

theorem NativeProductRun.refinement
    {framing : CodecFraming} {versions : VersionBytes}
    {world : ResidentWorld} {past : List ResidentWorld}
    {prior : ResidentReachable versions world past}
    {receipts : List ProductReceipt} {labels reports : List ProductLabel}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (run : NativeProductRun (framing := framing) codec roundtrip prior receipts labels)
    (inputs : List (Term × Term × Term))
    (inputCorrespondence : ∀ input ∈ inputs,
      InputOccurrence versions prior input.1 input.2.1 input.2.2)
    (reportCorrespondence : reports = labels) :
    (∀ input ∈ inputs, ∃ session event now first last item,
      Command.inputEvent session input.2.1 input.2.2 now first = .ok (event, last) ∧
      MainTermInputFact event input.2.1 item ∧ CanonicalQueueItem item ∧ world.store.work input.1 item) ∧
    (∀ earlier ∈ world :: past, ∀ key fact,
      earlier.store.fact key fact → world.store.fact key fact) ∧
    ∃ abstract, LabelSimulation {} abstract reports ∧
      ObserverRelation (reports.map ProductLabel.observer) world.store abstract ∧
      WorkConservation.Reachable (abstract.protocol false) ∧
      WorkConservation.Reachable (abstract.protocol true) ∧
      (∀ observer, ProductLabel.confirmed observer ∈ reports → ObserverBacked world.store observer) ∧
      (∀ observer, ProductLabel.accepted observer ∈ reports → ObserverBacked world.store observer) := by
  exact ⟨run.external_input_conserved codec roundtrip inputs inputCorrespondence,
    run.conditional_safety codec roundtrip reportCorrespondence⟩

end VerifiedKernel.Session.WorkConservation.CurrentExecution
