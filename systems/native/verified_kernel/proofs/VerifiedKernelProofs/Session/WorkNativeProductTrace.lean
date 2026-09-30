import VerifiedKernelProofs.Session.WorkNativeInputTrace
import VerifiedKernelProofs.Session.WorkNativeOtherReceipts

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication CommandDriver
set_option Elab.async false

inductive ProductReceipt where
  | input (receipt : InputReceipt)
  | terminal (receipt : TerminalReceipt)

def ProductReceipt.observer : ProductReceipt → FactProtocol.Observer
  | .input receipt => receipt.observer
  | .terminal receipt => receipt.observer

def ProductReceipt.ReturnEquations : ProductReceipt → Prop
  | .input receipt => receipt.ReturnEquations
  | .terminal receipt => receipt.ReturnEquations

variable {framing : CodecFraming} {versions : VersionBytes}
variable (codec : SnapshotCodec)
variable (roundtrip : ∀ snapshot bytes,
  ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
  ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))

/-- A finite Lean trace with declared input, log, and duplicate reports.
External report correspondence is an assumption. Receipts add no runtime state. -/
inductive NativeProductRun : {world : ResidentWorld} → {past : List ResidentWorld} →
    ResidentReachable versions world past → List ProductReceipt → List ProductLabel → Prop where
  | initial : NativeProductRun .initial [] []
  | store {world next : ResidentWorld} {past : List ResidentWorld}
      {prior : ResidentReachable versions world past} {receipts : List ProductReceipt} {labels : List ProductLabel}
      (run : NativeProductRun prior receipts labels) (step : ResidentStep versions world next) :
      NativeProductRun (.next prior step) receipts labels
  | input {world : ResidentWorld} {past : List ResidentWorld}
      {prior : ResidentReachable versions world past} {receipts : List ProductReceipt} {labels : List ProductLabel}
      (run : NativeProductRun prior receipts labels) (call : InputLanding versions world) :
      NativeProductRun (.next prior call.step)
        (.input (call.receipt (framing := framing) codec roundtrip prior) :: receipts)
        (labels ++ [.accepted (call.receipt (framing := framing) codec roundtrip prior).observer])
  | log {world : ResidentWorld} {past : List ResidentWorld}
      {prior : ResidentReachable versions world past} {receipts : List ProductReceipt} {labels : List ProductLabel}
      (run : NativeProductRun prior receipts labels) (call : LogLanding versions world) :
      NativeProductRun (.next prior call.step)
        (.terminal (call.receipt (framing := framing) codec roundtrip prior) :: receipts) labels
  | duplicate {world : ResidentWorld} {past : List ResidentWorld}
      {prior : ResidentReachable versions world past} {receipts : List ProductReceipt} {labels : List ProductLabel}
      (run : NativeProductRun prior receipts labels) (call : DuplicateCall world) :
      NativeProductRun prior (.terminal (call.receipt (framing := framing) codec roundtrip prior) :: receipts) labels
  | confirm {world : ResidentWorld} {past : List ResidentWorld}
      {prior : ResidentReachable versions world past} {receipts : List ProductReceipt} {labels : List ProductLabel}
      (run : NativeProductRun prior receipts labels) (receipt : ProductReceipt)
      (member : receipt ∈ receipts) (equations : receipt.ReturnEquations) :
      NativeProductRun prior receipts (labels ++ [.confirmed receipt.observer])
  | notify {world : ResidentWorld} {past : List ResidentWorld}
      {prior : ResidentReachable versions world past} {receipts : List ProductReceipt} {labels : List ProductLabel}
      (run : NativeProductRun prior receipts labels) (receipt : InputReceipt)
      (member : ProductReceipt.input receipt ∈ receipts) (equations : receipt.NotificationEquations) :
      NativeProductRun prior receipts (labels ++ [.confirmed receipt.observer])

theorem NativeProductRun.certificate {world : ResidentWorld} {past : List ResidentWorld}
    {prior : ResidentReachable versions world past} {receipts : List ProductReceipt} {labels : List ProductLabel}
    (run : NativeProductRun (framing := framing) codec roundtrip prior receipts labels) :
    LabelledTrace versions ResidentInitial world labels ∧
      ∀ receipt ∈ receipts, ObserverBacked world.store receipt.observer := by
  induction run with
  | initial => exact ⟨.done _, by simp⟩
  | @store world next past prior receipts labels run step ih =>
    have kept := (step.invariant codec roundtrip (prior.conservation (framing := framing) codec roundtrip).1).2.2
    exact ⟨by simpa using ih.1.trans (.store step (.done _)),
      fun receipt member => kept _ _ (ih.2 receipt member)⟩
  | @input world past prior receipts labels run call ih =>
    have backed : ObserverBacked call.world.store
        (call.receipt (framing := framing) codec roundtrip prior).observer :=
      (call.witness (framing := framing) codec roundtrip prior).backed
    have kept := (call.step.invariant codec roundtrip
      (prior.conservation (framing := framing) codec roundtrip).1).2.2
    refine ⟨ih.1.trans (.store call.step (.emit _ backed (.done _))), ?_⟩
    intro receipt member
    rcases List.mem_cons.mp member with rfl | old
    · exact backed
    · exact kept _ _ (ih.2 receipt old)
  | @log world past prior receipts labels run call ih =>
    have kept := (call.step.invariant codec roundtrip
      (prior.conservation (framing := framing) codec roundtrip).1).2.2
    refine ⟨by simpa using ih.1.trans (.store call.step (.done _)), ?_⟩
    intro receipt member
    rcases List.mem_cons.mp member with rfl | old
    · exact (call.witness (framing := framing) codec roundtrip prior).backed
    · exact kept _ _ (ih.2 receipt old)
  | @duplicate world past prior receipts labels run call ih =>
    refine ⟨ih.1, ?_⟩
    intro receipt member
    rcases List.mem_cons.mp member with rfl | old
    · exact (call.witness (framing := framing) codec roundtrip prior).backed
    · exact ih.2 receipt old
  | confirm run receipt member delivered ih =>
    exact ⟨ih.1.trans (.emit _ (ih.2 receipt member) (.done _)), ih.2⟩
  | notify run receipt member issued ih =>
    exact ⟨ih.1.trans (.emit _ (ih.2 (.input receipt) member) (.done _)), ih.2⟩

/-- All labels share the same abstract execution and the same fixed observer set. -/
theorem NativeProductRun.safety {world : ResidentWorld} {past : List ResidentWorld}
    {prior : ResidentReachable versions world past} {receipts : List ProductReceipt} {labels : List ProductLabel}
    (run : NativeProductRun (framing := framing) codec roundtrip prior receipts labels) :
    ∃ abstract, LabelSimulation {} abstract labels ∧
      ObserverRelation (labels.map ProductLabel.observer) world.store abstract ∧
      ∀ label ∈ labels, ObserverBacked world.store label.observer :=
  labelled_execution_safety (framing := framing) codec roundtrip (run.certificate codec roundtrip).1

end VerifiedKernel.Session.WorkConservation.CurrentExecution
