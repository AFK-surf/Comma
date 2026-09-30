import VerifiedKernelProofs.IFC.System

/-! Payload behavior under trusted declarations. Knowledge acquired by a model
does not modify labels. A declaration describes dependencies of this effect,
not the model's accumulated knowledge. -/
namespace VerifiedKernel.IFC.Behavior
open VerifiedKernel.IFC.System
open Classical
variable [System.Domain]

structure Action (Value Output : Type) where
  expression : Expression Value Output
  destination : Label

/-- An authorized declassification makes a source part of the released view.
This relation never authorizes a release by itself. -/
def ViewEq (w : World) (observer : Principal) (labels : Ref → Label)
    (released : Ref → Prop) (left right : Store Value) : Prop :=
  ∀ ref, Reads w observer (labels ref) ∨ released ref → left ref = right ref

def ReleaseSafe (w : World) (observer : Principal) (labels : Ref → Label)
    (released : Ref → Prop) (action : Action Value Output) : Prop :=
  Reads w observer action.destination →
    ∀ ref ∈ action.expression.sources,
      Flows w (labels ref) action.destination ∨ released ref

noncomputable def observe (w : World) (observer : Principal)
    (action : Action Value Output) (store : Store Value) : List Output :=
  if Reads w observer action.destination then (action.expression.evaluate store).toList else []

theorem action_noninterference
    (safe : ReleaseSafe w observer labels released action)
    (same : ViewEq w observer labels released left right) :
    observe w observer action left = observe w observer action right := by
  classical
  unfold observe
  split
  · rename_i visible
    congr 1
    apply action.expression.declared
    intro ref member
    apply same ref
    rcases safe visible ref member with flows | release
    · exact Or.inl (flows observer visible)
    · exact Or.inr release
  · rfl

noncomputable def trace (w : World) (observer : Principal)
    (actions : List (Action Value Output)) (store : Store Value) : List Output :=
  actions.flatMap (fun action => observe w observer action store)

/-- Arbitrary finite traces, with no bound on hidden context or action count.
Actions share public authorization metadata and scheduling between the runs. -/
theorem trace_noninterference
    (safe : ∀ action ∈ actions, ReleaseSafe w observer labels released action)
    (same : ViewEq w observer labels released left right) :
    trace w observer actions left = trace w observer actions right := by
  unfold trace
  induction actions with
  | nil => rfl
  | cons action rest ih =>
    simp only [List.flatMap_cons]
    rw [action_noninterference (safe action (by simp)) same]
    rw [ih (fun action member => safe action (by simp [member]))]

/-- Only an actual non-flow authorization can justify the released view. -/
def Released (w : World) (policy : Policy) (activation : Activation)
    (effect : Effect) (receipts : ReceiptId → Option Receipt) (now : Nat)
    (evidence : List Admission) (ref : Ref) : Prop :=
  ∃ entry ∈ evidence, entry.item.ref = ref ∧ entry.clause ≠ .flow ∧
    SourceAuthorized w policy activation effect entry.item.label receipts now entry.clause

theorem authorized_release_safe {action : Action Value Output}
    (authorized : Authorized w policy ctx activation effect receipts now gates evidence)
    (destination : action.destination = effect.destination)
    (declared : ∀ ref ∈ action.expression.sources,
      ∃ entry ∈ evidence, entry.item.ref = ref ∧ entry.item.label = labels ref) :
    ReleaseSafe w observer labels
      (Released w policy activation effect receipts now evidence) action := by
  intro _ ref member
  obtain ⟨entry, present, href, hlabel⟩ := declared ref member
  have admitted := authorized.2.2.2 entry present
  cases hc : entry.clause with
  | flow =>
    rw [hc] at admitted
    cases admitted with
    | flow h => exact Or.inl (by simpa [destination, hlabel] using h)
  | inPlace => exact Or.inr ⟨entry, present, href, by simp [hc], admitted⟩
  | instruction => exact Or.inr ⟨entry, present, href, by simp [hc], admitted⟩
  | receipt id => exact Or.inr ⟨entry, present, href, by simp [hc], admitted⟩

theorem authorized_action_noninterference {action : Action Value Output}
    (authorized : Authorized w policy ctx activation effect receipts now gates evidence)
    (destination : action.destination = effect.destination)
    (declared : ∀ ref ∈ action.expression.sources,
      ∃ entry ∈ evidence, entry.item.ref = ref ∧ entry.item.label = labels ref)
    (same : ViewEq w observer labels
      (Released w policy activation effect receipts now evidence) left right) :
    observe w observer action left = observe w observer action right :=
  action_noninterference (authorized_release_safe authorized destination declared) same

/-- A trusted constant output needs no sources, even when stores differ. -/
def constantExpression (value : Output) : Expression Value Output where
  sources := []
  evaluate := fun _ => some value
  declared := fun _ _ _ => rfl

theorem empty_declaration_ignores_private_context (left right : Store Value) :
    (constantExpression value).evaluate left = (constantExpression value).evaluate right := rfl

/-- The declaration contract has content: a secret-dependent output cannot
truthfully declare the empty source list. -/
theorem secret_dependency_cannot_declare_empty (ref : Ref) :
    ¬ ∃ expression : Expression Bool Bool,
      expression.sources = [] ∧ expression.evaluate = (fun store => some (store ref)) := by
  rintro ⟨expression, empty, evaluates⟩
  have same := expression.declared (fun _ => false) (fun _ => true)
    (by simp [AgreeOn, empty])
  simp [evaluates] at same

end VerifiedKernel.IFC.Behavior
