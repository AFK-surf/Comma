import Std

/-! Shared IFC definitions. The runtime checks authority. The agent declares dependencies. -/
namespace VerifiedKernel.IFC.System

/-- Resolved identity types, supplied by the runtime. -/
class Domain where
  principal : Type
  audience : Type
  reference : Type
  receipt : Type
  principalEq : DecidableEq principal
  audienceEq : DecidableEq audience
  referenceEq : DecidableEq reference
  receiptEq : DecidableEq receipt

abbrev Principal [d : Domain] := d.principal
abbrev Audience [d : Domain] := d.audience
abbrev Ref [d : Domain] := d.reference
abbrev ReceiptId [d : Domain] := d.receipt
instance [d : Domain] : DecidableEq (Principal) := d.principalEq
instance [d : Domain] : DecidableEq (Audience) := d.audienceEq
instance [d : Domain] : DecidableEq (Ref) := d.referenceEq
instance [d : Domain] : DecidableEq (ReceiptId) := d.receiptEq

variable [Domain]

inductive Atom where
  | unrestricted | runtimePrivate | audience (id : Audience)
  deriving DecidableEq

abbrev Label := List Atom

structure World where
  readers : Audience → Principal → Prop

def AtomReads (w : World) (p : Principal) : Atom → Prop
  | .unrestricted => True
  | .runtimePrivate => False
  | .audience id => w.readers id p

def Reads (w : World) (p : Principal) (l : Label) : Prop :=
  ∀ atom ∈ l, AtomReads w p atom

def Flows (w : World) (src dst : Label) : Prop :=
  ∀ p, Reads w p dst → Reads w p src

inductive Integrity where
  | command | data
  deriving DecidableEq

structure Item where
  ref : Ref
  label : Label
  integrity : Integrity
  principal : Option Principal

inductive Sources where
  | context | explicit (refs : List Ref)

structure Activation where
  requester : Principal
  sourceScope : Label
  consumed : List Ref

structure Effect where
  request : Ref
  sources : Sources
  destination : Label

structure Policy where
  sealed : Atom → Prop
  inPlace : Prop
  instruction : Prop
  receipt : Prop

structure Receipt where
  requester : Principal
  sources : Label
  destination : Label
  expires : Option Nat

def LabelEq (a b : Label) : Prop := ∀ atom, atom ∈ a ↔ atom ∈ b

/-- Receipts cover audience scope, not message identity. -/
def Covers (r : Receipt) (p : Principal) (src dst : Label) (now : Nat) : Prop :=
  r.requester = p ∧ LabelEq r.destination dst ∧
  ((∀ atom ∈ src, atom ∈ r.sources) ∨ LabelEq src [.unrestricted]) ∧
  (∀ expiry, r.expires = some expiry → now < expiry)

def Unsealed (policy : Policy) (src : Label) : Prop :=
  ∀ atom ∈ src, ¬ policy.sealed atom

inductive Clause where
  | flow | inPlace | instruction | receipt (id : ReceiptId)

/-- Sealed sources allow normal flow, not declassification. -/
inductive SourceAuthorized (w : World) (policy : Policy) (a : Activation)
    (e : Effect) (src : Label) (receipts : ReceiptId → Option Receipt) (now : Nat) :
    Clause → Prop where
  | flow : Flows w src e.destination → SourceAuthorized w policy a e src receipts now .flow
  | inPlace : Unsealed policy src → Reads w a.requester src → policy.inPlace →
      LabelEq e.destination a.sourceScope → SourceAuthorized w policy a e src receipts now .inPlace
  | instruction : Unsealed policy src → Reads w a.requester src → policy.instruction →
      SourceAuthorized w policy a e src receipts now .instruction
  | receipt {id : ReceiptId} {r : Receipt} : Unsealed policy src → Reads w a.requester src → policy.receipt →
      receipts id = some r → Covers r a.requester src e.destination now →
      SourceAuthorized w policy a e src receipts now (.receipt id)

def RequestAuthorized (ctx : List Item) (a : Activation) (e : Effect) : Prop :=
  ∃ item ∈ ctx, item.ref = e.request ∧ item.integrity = .command ∧
    item.principal = some a.requester ∧ item.ref ∈ a.consumed

/-- Context refs are unique. Explicit sources do not implicitly include the request. -/
def Resolves (ctx : List Item) (sources : Sources) (selected : List Item) : Prop :=
  match sources with
  | .context => ∀ item, item ∈ selected ↔ item ∈ ctx
  | .explicit refs =>
      (∀ ref ∈ refs, ∃ item ∈ ctx, item.ref = ref) ∧
      (∀ item, item ∈ selected ↔ item ∈ ctx ∧ item.ref ∈ refs)

inductive Writers where
  | any | unknown | members (principals : List Principal)

inductive ExternalMode where
  | deny | ownThread | asInternal

inductive PublicMode where
  | receipt | publicSourcesOnly

/-- The host checks organization-command scope. -/
structure Gates where
  writers : Writers
  external : Bool
  externalMode : ExternalMode
  publicMode : PublicMode
  commandScope : Prop

def Gates.Hold (g : Gates) (a : Activation) (e : Effect) (sources : List Item) : Prop :=
  (match g.writers with
    | .any => True
    | .unknown => False
    | .members ps => a.requester ∈ ps) ∧
  (g.external = false ∨ match g.externalMode with
    | .deny => False
    | .ownThread => LabelEq e.destination a.sourceScope
    | .asInternal => True) ∧
  (match g.publicMode with
    | .receipt => True
    | .publicSourcesOnly => LabelEq e.destination [.unrestricted] →
        ∀ item ∈ sources, LabelEq item.label [.unrestricted]) ∧
  g.commandScope

structure Admission where
  item : Item
  clause : Clause

def Authorized (w : World) (policy : Policy) (ctx : List Item) (a : Activation)
    (e : Effect) (receipts : ReceiptId → Option Receipt) (now : Nat)
    (gates : Gates) (evidence : List Admission) : Prop :=
  RequestAuthorized ctx a e ∧ gates.Hold a e (evidence.map Admission.item) ∧
  Resolves ctx e.sources (evidence.map Admission.item) ∧
  ∀ entry ∈ evidence,
    SourceAuthorized w policy a e entry.item.label receipts now entry.clause

end VerifiedKernel.IFC.System

namespace VerifiedKernel.IFC.Behavior
open VerifiedKernel.IFC.System
variable [System.Domain]

abbrev Store (Value : Type) := Ref → Value

def AgreeOn (refs : List Ref) (left right : Store Value) : Prop :=
  ∀ ref ∈ refs, left ref = right ref

/-- Trusted content dependencies, including output presence. Not a runtime check.
Reading information does not accumulate labels. -/
structure Expression (Value Output : Type) where
  sources : List Ref
  evaluate : Store Value → Option Output
  declared : ∀ left right, AgreeOn sources left right → evaluate left = evaluate right

end VerifiedKernel.IFC.Behavior
