import VerifiedKernelProofs.Session.WorkObserverSimulation
import VerifiedKernelProofs.Session.WorkResidentIdentity
import VerifiedKernelProofs.Session.WorkResidentLog

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication CommandDriver
set_option Elab.async false

/-- Acceptance is attached to the landed input CAS. No delivered reply or notification is required. -/
theorem landed_input_refines_acceptance {framing : CodecFraming} {versions : VersionBytes}
    {before current : ResidentWorld} {past : List ResidentWorld} {after : HotStore}
    {captured : CapturedRevision} {entry born checkpoint outcome : Term} {source etag : ByteArray}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (prior : ResidentReachable versions before past) (member : captured ∈ before.captured)
    (submission : InputSubmission captured.cursor entry born checkpoint)
    (cas : HotCAS before.store.hot
      (.tuple [a "cas", submission.requestedKey, submission.requestedBytes, submission.requestedBase])
      (.tuple [a "ok", .binary etag, outcome]) after)
    (tokens : after.versioned versions)
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source)
    (later : ResidentTrace versions
      (committedWorld before after before.store.objects captured.owner captured.session submission.stamped (.binary etag)) current) :
    ∃ event now first last item, ∃ abstract : FactProtocol.State,
      Command.inputEvent (captured.cursor.candidate.working.get (a "session_id")) (.binary source)
        (RoundQuery.atomFirst entry "payload") now first = .ok (event, last) ∧
      MainInputFact event source item ∧ CanonicalQueueItem item ∧
      FactProtocol.Trace {} abstract ∧
      ObserverRelation [⟨captured.key, .work item⟩] current.store abstract ∧
      FactProtocol.Observer.mk captured.key (.work item) ∈ abstract.accepted ∧
      current.store.work captured.key item := by
  have valid := (prior.conservation (framing := framing) codec roundtrip).1
  obtain ⟨sealed, history⟩ := (valid.2.2 captured member).1
  have step : ResidentStep versions before
      (committedWorld before after before.store.objects captured.owner captured.session submission.stamped (.binary etag)) :=
    .commit member (.input submission) submission.fence cas tokens
  have landedValid := (step.invariant codec roundtrip valid).1
  obtain ⟨address, token, snapshot, bytes, event, now, first, last, item,
    encoded, _, stored, snapshotHistory, generated, fact, canonical, physical, _⟩ :=
    submission.current_facts history sourceValue cas
  obtain ⟨decoded, decoding⟩ := roundtrip snapshot bytes encoded
  have landed := HotStore.current_work snapshotHistory stored encoded decoding (codec _ _ _ encoded decoding) physical
  rw [address] at landed
  let observer : FactProtocol.Observer := ⟨captured.key, .work item⟩
  obtain ⟨registered, prefixTrace, relation⟩ :=
    (ResidentReachable.next prior step).observer_simulation (framing := framing) [observer] codec roundtrip
  obtain ⟨acceptedTrace, acceptedRelation⟩ := observer_acceptance_ready (observer := observer) relation (by simp) landed
  obtain ⟨abstract, suffixTrace, currentRelation⟩ :=
    resident_trace_observer_simulation codec roundtrip landedValid acceptedRelation later
  have accepted : observer ∈ abstract.accepted :=
    suffixTrace.accepted_preserves observer (List.mem_append_right _ List.mem_cons_self)
  have complete := prefixTrace.trans (acceptedTrace.trans suffixTrace)
  exact ⟨event, now, first, last, item, abstract, generated, fact, canonical, complete, currentRelation, accepted,
    observer_accepted_conserved complete currentRelation accepted⟩

def ConfirmationRefines (world : World) (observer : FactProtocol.Observer) : Prop :=
  ∃ before after : FactProtocol.State,
    FactProtocol.Trace {} before ∧ ObserverRelation [observer] world before ∧
    after = FactProtocol.acknowledge before observer ∧
    FactProtocol.Trace {} after ∧ ObserverRelation [observer] world after ∧
    observer ∈ after.acknowledged ∧ ObserverBacked world observer

/-- Used only after a native episode has supplied its matching fact. This step adds no registration. -/
theorem matching_confirmation_refines {framing : CodecFraming} {versions : VersionBytes}
    {world : ResidentWorld} {past : List ResidentWorld} {observer : FactProtocol.Observer}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (execution : ResidentReachable versions world past) (backed : ObserverBacked world.store observer) :
    ConfirmationRefines world.store observer := by
  obtain ⟨registered, prefixTrace, relation⟩ := execution.observer_simulation (framing := framing) [observer] codec roundtrip
  obtain ⟨acknowledgedTrace, acknowledgedRelation⟩ := observer_confirmation_ready relation (by simp) backed
  have complete := prefixTrace.trans acknowledgedTrace
  have marked : observer ∈ (FactProtocol.acknowledge registered observer).acknowledged :=
    List.mem_append_right _ List.mem_cons_self
  exact ⟨registered, _, prefixTrace, relation, rfl, complete, acknowledgedRelation, marked,
    observer_acknowledgment_durable complete acknowledgedRelation marked⟩

end VerifiedKernel.Session.WorkConservation.CurrentExecution
