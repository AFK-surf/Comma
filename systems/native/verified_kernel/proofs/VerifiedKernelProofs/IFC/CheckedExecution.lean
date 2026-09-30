import VerifiedKernelProofs.Order
import VerifiedKernelProofs.IFC.SemanticRefinement
import VerifiedKernelProofs.IFC.Execution

namespace VerifiedKernel.IFC.CheckedExecution
open Data WireSemantics SemanticRefinement
local instance : System.Domain := domain

def Releases (w : System.World) (rawEffect rawActivation facts : Term)
    (receipts : System.ReceiptId → Option System.Receipt) (clock : Int)
    (sources entries : List Term) : System.Ref → Prop :=
  Behavior.Released w (policy (f facts "policy")) (activation rawActivation) (effect rawEffect)
    receipts clock.toNat (admissions sources entries)

/-- The trust boundary binds this effect's expression to its declared source
refs and labels. It does not bind all context seen by the model. -/
def Declared (command : Execution.Command Value) (state : Execution.State Value)
    (rawEffect rawItems : Term) : Prop :=
  command.action.destination = WireSemantics.label (f rawEffect "destination") ∧
  ∀ request sources,
    DecisionContract.Resolves rawEffect request (values rawItems) sources →
    ∀ ref ∈ command.action.expression.sources,
      ∃ raw ∈ sources,
        Identity.key (f raw "ref") = ref ∧ WireSemantics.label (f raw "label") = state.labels ref

theorem checked_advance_noninterference {commandScope : Prop}
    (allowed : decideChecked rawEffect rawActivation rawItems facts = .ok evidence)
    (sound : ReaderRefinement.FactsSound mapping w facts)
    (snapshot : ReceiptSnapshot facts receipts) (scope : commandScope)
    (declared : Declared command left rawEffect rawItems)
    (same : Execution.LowEq w observer left right)
    (release : ∀ request clock sources entries,
      request ∈ values rawItems → f facts "now" = .integer clock →
      DecisionContract.Resolves rawEffect request (values rawItems) sources →
      DecisionContract.EvidenceSources rawEffect rawActivation (f request "principal") facts sources entries →
      Execution.ReleaseAgreement (Releases w rawEffect rawActivation facts receipts clock sources
        (values (f evidence "sources"))) left right) :
    Execution.LowEq w observer (Execution.advance left command) (Execution.advance right command) ∧
    Behavior.observe w observer command.action left.values = Behavior.observe w observer command.action right.values := by
  obtain ⟨request, clock, sources, entries, _, present, hn, wire, resolved, admitted, authorized⟩ :=
    decideChecked_system allowed sound snapshot scope
  have declaredSources : ∀ ref ∈ command.action.expression.sources,
      ∃ entry ∈ admissions sources entries, entry.item.ref = ref ∧ entry.item.label = left.labels ref := by
    intro ref member
    obtain ⟨raw, hr, href, hlabel⟩ := declared.2 request sources resolved ref member
    have inItems : item raw ∈ (admissions sources entries).map System.Admission.item := by
      rw [evidence_items admitted]
      exact List.mem_map.mpr ⟨raw, hr, rfl⟩
    obtain ⟨entry, he, sameItem⟩ := List.mem_map.mp inItems
    exact ⟨entry, he, by rw [sameItem]; exact ⟨href, hlabel⟩⟩
  exact Execution.advance_noninterference same
    (Behavior.authorized_release_safe authorized declared.1 declaredSources)
    (by simpa only [evidence_entries wire, Releases] using release request clock sources entries present hn resolved admitted)

/-- One checked transition with its current authority snapshot. This is proof
data for an execution, not a runtime certificate or an additional gate. -/
structure CheckedStep (Value : Type) (w : System.World)
    (state : Execution.State Value) (command : Execution.Command Value) where
  rawEffect : Term
  rawActivation : Term
  rawItems : Term
  facts : Term
  evidence : Term
  receipts : System.ReceiptId → Option System.Receipt
  commandScope : Prop
  allowed : decideChecked rawEffect rawActivation rawItems facts = .ok evidence
  sound : ReaderRefinement.FactsSound mapping w facts
  snapshot : ReceiptSnapshot facts receipts
  scope : commandScope
  declared : Declared command state rawEffect rawItems

def CheckedStep.SameReleases (step : CheckedStep Value w left command)
    (right : Execution.State Value) : Prop :=
  ∀ request clock sources entries,
    request ∈ values step.rawItems → f step.facts "now" = .integer clock →
    DecisionContract.Resolves step.rawEffect request (values step.rawItems) sources →
    DecisionContract.EvidenceSources step.rawEffect step.rawActivation
      (f request "principal") step.facts sources entries →
    Execution.ReleaseAgreement (Releases w step.rawEffect step.rawActivation step.facts
      step.receipts clock sources (values (f step.evidence "sources"))) left right

theorem CheckedStep.noninterference (step : CheckedStep Value w left command)
    (same : Execution.LowEq w observer left right) (release : step.SameReleases right) :
    Execution.LowEq w observer (Execution.advance left command) (Execution.advance right command) ∧
    Behavior.observe w observer command.action left.values = Behavior.observe w observer command.action right.values :=
  checked_advance_noninterference step.allowed step.sound step.snapshot step.scope step.declared same release

inductive CheckedTrace (w : System.World) :
    Execution.State Value → Execution.State Value → List (Execution.Command Value) → Prop where
  | nil : CheckedTrace w left right []
  | cons (step : CheckedStep Value w left command) (release : step.SameReleases right)
      (tail : CheckedTrace w (Execution.advance left command) (Execution.advance right command) rest) :
      CheckedTrace w left right (command :: rest)

theorem checked_run_noninterference (same : Execution.LowEq w observer left right)
    (checked : CheckedTrace w left right commands) :
    Execution.LowEq w observer (Execution.run w observer left commands).1 (Execution.run w observer right commands).1 ∧
    (Execution.run w observer left commands).2 = (Execution.run w observer right commands).2 := by
  induction checked with
  | nil => exact ⟨same, rfl⟩
  | cons step release _ ih =>
    obtain ⟨next, output⟩ := step.noninterference same release
    obtain ⟨finalState, later⟩ := ih next
    exact ⟨finalState, by simp only [Execution.run, output, later]⟩

theorem checked_execute_noninterference (scheduler : Execution.Scheduler Value w observer)
    (checked : ∀ left right command, Execution.LowEq w observer left right → scheduler.next left = some command →
      ∃ step : CheckedStep Value w left command, step.SameReleases right)
    (same : Execution.LowEq w observer left right) :
    Execution.LowEq w observer (Execution.execute w observer scheduler fuel left).1
      (Execution.execute w observer scheduler fuel right).1 ∧
    (Execution.execute w observer scheduler fuel left).2 = (Execution.execute w observer scheduler fuel right).2 := by
  induction fuel generalizing left right with
  | zero => exact ⟨same, rfl⟩
  | succ fuel ih =>
    have control := scheduler.publicControl left right same
    cases hn : scheduler.next left with
    | none => simp only [Execution.execute, ← control, hn]; exact ⟨same, trivial⟩
    | some command =>
      obtain ⟨step, release⟩ := checked left right command same hn
      obtain ⟨next, output⟩ := step.noninterference same release
      obtain ⟨finalState, later⟩ := ih next
      simp only [Execution.execute, ← control, hn]
      exact ⟨finalState, by simp only [output, later]⟩

end VerifiedKernel.IFC.CheckedExecution
