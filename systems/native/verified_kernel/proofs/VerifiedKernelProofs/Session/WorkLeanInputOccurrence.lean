import VerifiedKernelProofs.Session.WorkNativeInputTrace

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication
set_option Elab.async false

/-- An input submission and its landed CAS occupy one edge of this Lean history. -/
inductive InputOccurrence (versions : VersionBytes) :
    {world : ResidentWorld} → {past : List ResidentWorld} →
    ResidentReachable versions world past → Term → Term → Term → Prop where
  | landed {world : ResidentWorld} {past : List ResidentWorld}
      (prior : ResidentReachable versions world past) (call : InputLanding versions world) :
      InputOccurrence versions (.next prior call.step) call.captured.key call.source
        (RoundQuery.atomFirst call.entry "payload")
  | later {world next : ResidentWorld} {past : List ResidentWorld}
      {prior : ResidentReachable versions world past} {key source payload : Term}
      (occurrence : InputOccurrence versions prior key source payload)
      (step : ResidentStep versions world next) :
      InputOccurrence versions (.next prior step) key source payload

theorem InputOccurrence.conserved {framing : CodecFraming} {versions : VersionBytes}
    {world : ResidentWorld} {past : List ResidentWorld}
    {prior : ResidentReachable versions world past} {key source payload : Term}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (occurrence : InputOccurrence versions prior key source payload) :
    ∃ session event now first last item,
      Command.inputEvent session source payload now first = .ok (event, last) ∧
      MainTermInputFact event source item ∧ CanonicalQueueItem item ∧ world.store.work key item := by
  induction occurrence with
  | landed prior call =>
    let witness := call.witness (framing := framing) codec roundtrip prior
    exact ⟨_, witness.event, witness.now, witness.first, witness.last, witness.item,
      witness.generated, witness.origin, witness.canonical, witness.backed⟩
  | @later world next past prior key source payload occurrence step ih =>
    obtain ⟨session, event, now, first, last, item, generated, origin, canonical, backed⟩ := ih
    have kept := (step.invariant codec roundtrip
      (prior.conservation (framing := framing) codec roundtrip).1).2.2
    exact ⟨session, event, now, first, last, item, generated, origin, canonical,
      kept key (.work item) backed⟩

end VerifiedKernel.Session.WorkConservation.CurrentExecution
