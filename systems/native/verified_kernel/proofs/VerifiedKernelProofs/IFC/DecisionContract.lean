import VerifiedKernelProofs.Order
import VerifiedKernel.IFC.Data

/-! Declarative contract for the complete IFC entry point. This module does not
import the decision implementation. Wire terms are the boundary representation;
reader facts are interpreted separately by the information-flow semantics. -/
namespace VerifiedKernel.IFC.DecisionContract
open Data

def ValidInputs (effect activation items facts : Term) : Prop :=
  tagged effect "Effect" = true ∧ tagged activation "Activation" = true ∧
  tagged facts "Facts" = true ∧ (∃ xs, items = .list xs) ∧
  dataValid effect = true ∧ effectValid effect = true ∧
  dataValid activation = true ∧ activationValid activation = true ∧
  dataValid items = true ∧ (values items).all itemValid = true ∧
  dataValid facts = true ∧ factsValid facts = true

def UniqueRefs (items : List Term) : Prop :=
  items.Pairwise (fun x y => (f x "ref" == f y "ref") = false)

def RequestAuthorized (effect activation request : Term) : Prop :=
  (f request "ref" == f effect "request") = true ∧
  (f request "integrity" == a "command") = true ∧
  (f request "principal" == nil) = false ∧
  contains (setValues (f activation "consumed_refs")) (f request "ref") = true ∧
  (authority (f request "principal") == authority (f activation "requester")) = true

def WriterAuthorized (effect activation p facts : Term) : Prop :=
  (external facts p = false ∨ f (f facts "policy") "external_principals" == a "as_internal" ∨
    (f (f facts "policy") "external_principals" == a "own_thread_only" ∧
      labelEqual (f effect "destination") (f activation "source_scope") = true)) ∧
  ((f effect "writers" == a "any") = true ∨
    ((f effect "writers" == a "unknown") = false ∧
      contains (setValues (f effect "writers")) (authority p) = true))

def PublicAuthorized (effect facts : Term) (items : List Term) : Prop :=
  publicLabel (f effect "destination") = false ∨
  (f (f facts "policy") "public_egress" == a "receipt") = true ∨
  ∀ source ∈ items, publicLabel (f source "label") = true

def Unsealed (source policy : Term) : Prop :=
  ∀ atom ∈ atoms source, contains (setValues (f policy "sealed_atoms")) atom = false

inductive SourceAuthorized (source effect activation p facts : Term) : Term → Prop where
  | flow : readersSubset (f effect "destination") (f source "label") facts = .yes →
      SourceAuthorized source effect activation p facts (a "flow")
  | inPlace : Unsealed (f source "label") (f facts "policy") →
      reader p (f source "label") facts = .yes → inPlaceAllowed (f facts "policy") = true →
      labelEqual (f effect "destination") (f activation "source_scope") = true →
      SourceAuthorized source effect activation p facts (a "in_place")
  | instruction : Unsealed (f source "label") (f facts "policy") →
      reader p (f source "label") facts = .yes → instructionAllowed (f facts "policy") = true →
      SourceAuthorized source effect activation p facts (a "instruction")
  | receipt (r : Term) : Unsealed (f source "label") (f facts "policy") →
      reader p (f source "label") facts = .yes → receiptAllowed (f facts "policy") = true →
      r ∈ setValues (f facts "receipts") → receiptValidAt r (f facts "now") = true →
      receiptCovers r p (f source "label") (f effect "destination") = true →
      SourceAuthorized source effect activation p facts (.tuple [a "receipt", f r "id"])

/-- Each declared reference identifies an existing context item. -/
inductive SelectedRefs (items : List Term) : List Term → List Term → Prop where
  | nil : SelectedRefs items [] []
  | cons {ref item : Term} {refs selected : List Term} :
      item ∈ items → (f item "ref" == ref) = true → SelectedRefs items refs selected →
      SelectedRefs items (ref :: refs) (item :: selected)

def Resolves (effect request : Term) (items sources : List Term) : Prop :=
  ((f effect "sources" == a "context") = true ∧ sources = dedupe (request :: items)) ∨
  ((f effect "sources" == a "context") = false ∧ ∃ selected,
    SelectedRefs items (values (f effect "sources")) selected ∧ sources = dedupe selected)

/-- Evidence covers the declared sources. Undeclared context is not implicit input. -/
inductive EvidenceSources (effect activation p facts : Term) : List Term → List Term → Prop where
  | nil : EvidenceSources effect activation p facts [] []
  | cons {source entry : Term} {sources entries : List Term} : (∃ clause, entry = .tuple [f source "ref", clause] ∧
      SourceAuthorized source effect activation p facts clause) →
      EvidenceSources effect activation p facts sources entries →
      EvidenceSources effect activation p facts (source :: sources) (entry :: entries)

def Authorized (effect activation rawItems facts evidence : Term) : Prop :=
  ValidInputs effect activation rawItems facts ∧ UniqueRefs (values rawItems) ∧
  ∃ request ∈ values rawItems,
    RequestAuthorized effect activation request ∧
    WriterAuthorized effect activation (f request "principal") facts ∧
    ∃ sources, Resolves effect request (values rawItems) sources ∧
    PublicAuthorized effect facts sources ∧
    ∃ admitted revisions,
      revisions = consultedRevisions effect facts sources ∧
      EvidenceSources effect activation (f request "principal") facts sources admitted ∧
      evidence = .map [
        (a "__struct__", a "Elixir.SalixIFC.Evidence"),
        (a "request", f effect "request"), (a "requester", authority (f request "principal")),
        (a "destination", f effect "destination"), (a "sources", list admitted),
        (a "membership_revisions", revisions)]

end VerifiedKernel.IFC.DecisionContract
