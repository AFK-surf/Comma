import VerifiedKernelProofs.Session.WorkReceiptTransitions
import VerifiedKernelProofs.Session.WorkPhysicalHistory

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

/-- All receipt queries, not just binary identities, have an executable origin. -/
theorem KernelHistory.receipts {state : Term} {sealed : List Term} (history : KernelHistory state sealed) :
    ReceiptSupported state sealed := by
  induction history with
  | create call => exact create_receipt_supported call
  | fork format call => exact modern_fork_receipt_supported format call
  | nonretiring before execution canonical safe ih =>
    exact nonretiring_batch_receipt_supported execution before.invariant.ready before.invariant.format canonical safe ih
  | reduceOrdinary before safe call ih =>
    exact nonretiring_inner_receipt_supported before.invariant.ready before.invariant.format safe ih call
  | materialize before planned execution ih =>
    exact materialize_receipt_supported before.invariant.ready ih planned execution
  | normalize before call ih =>
    exact normalize_receipt_supported before.invariant.ready before.invariant.header ih call
  | materialize_framed before queue ack session planned execution ih =>
    exact materialize_framed_receipt_supported before.invariant.ready queue ack session planned execution ih
  | prepare before call ih =>
    exact (prepare_write_receipt_supported before.invariant.ready before.invariant.format before.invariant.header ih call).1
  | persist before call ih => exact persistable_receipt_supported ih call
  | reload before decoded codec trace ih =>
    have ready := codec.ready before.invariant.ready
    have header := equivalent_ledger_header before.invariant.header codec
    obtain ⟨journal, rest, normalized⟩ := load_trace_normalizes decoded ready trace
    exact normalize_receipt_supported ready header (equivalent_receipt_supported codec ih) normalized
  | decode before decoded codec ih => exact equivalent_receipt_supported codec ih
  | activity before frame ih => exact activity_receipt_supported frame ih
  | archive before kind call read partition after ih => exact archive_receipt_supported read partition after ih call

theorem PhysicalHistory.receipts {framing : ArchivePublication.CodecFraming}
    {objects : ArchivePublication.Objects} {owner session : ByteArray} {state : Term} {sealed : List Term}
    (history : PhysicalHistory framing objects owner session state sealed) : ReceiptSupported state sealed :=
  history.invariant.history.receipts

theorem PhysicalHistory.normalized_receipt_physical {framing : ArchivePublication.CodecFraming}
    {objects : ArchivePublication.Objects} {owner session bytes : ByteArray}
    {snapshot decodedState loaded source : Term} {sealed journal rest : List Term}
    (history : PhysicalHistory framing objects owner session snapshot sealed)
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
    (codec : ValueSemantics.Equivalent snapshot decodedState)
    (normalized : Lifecycle.normalize decodedState journal = .ok (loaded, rest))
    (present : IdentityPresent (loaded.get (a "input_dedupe")) source) :
    ∃ event fact, ReceiptOrigin event source fact ∧
      ArchivePublication.PhysicalIdentityFact objects snapshot fact := by
  have decodedHistory := history.decode decoded codec
  have logical := decodedHistory.invariant.history.invariant
  obtain ⟨live, _, read, _⟩ := logical.sorted
  obtain ⟨event, fact, origin, supported⟩ :=
    normalize_receipt_supported logical.ready logical.header decodedHistory.receipts normalized source present
  have original := normalize_fact_reflect logical.ready read normalized supported
  exact ⟨event, fact, origin, ArchivePublication.identity_fact_physical history.invariant.images
    (identity_fact_equivalent codec.symm original)⟩

end VerifiedKernel.Session.WorkConservation
