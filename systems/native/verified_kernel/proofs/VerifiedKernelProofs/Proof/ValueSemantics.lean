import VerifiedKernel.Data

namespace VerifiedKernel.Session.WorkConservation.ValueSemantics
open Data
set_option Elab.async false

inductive Shape where
  | integer (value : Int)
  | atom (value : String)
  | binary (value : ByteArray)
  | floatBits (value : UInt64)
  | bitstring (bytes : ByteArray) (lastBits : UInt8)
  | tuple (size : Nat)
  | list (size : Nat)
  | map (size : Nat) (binaryKeys : Bool)
  | improper (size : Nat)

def shape : Term → Shape
  | .integer value => .integer value
  | .atom value => .atom value
  | .binary value => .binary value
  | .floatBits value => .floatBits value
  | .bitstring bytes bits => .bitstring bytes bits
  | .tuple values => .tuple values.length
  | .list values => .list values.length
  | .map entries => .map entries.length (entries.all (fun pair => pair.1.isBinary))
  | .improper heads _ => .improper heads.length

inductive Access where
  | key (key : Term)
  | present (key : Term)
  | index (index : Nat)
  | tail

def access (value : Term) : Access → Term
  | .key key => value.get key
  | .present key => Term.bool (value.has key)
  | .index index => match value with
    | .list values | .tuple values | .improper values _ => values[index]?.getD nil
    | _ => nil
  | .tail => match value with | .improper _ tail => tail | _ => nil

def navigate (value : Term) : List Access → Term
  | [] => value
  | next :: rest => navigate (access value next) rest

/-- Map order is not observable. Field presence, list order, scalar values, and key types are observable. -/
def Equivalent (left right : Term) : Prop :=
  ∀ path, shape (navigate left path) = shape (navigate right path)

theorem Equivalent.refl (value : Term) : Equivalent value value := fun _ => rfl

theorem Equivalent.symm {left right : Term} (same : Equivalent left right) : Equivalent right left :=
  fun path => (same path).symm

theorem Equivalent.trans {left middle right : Term} (first : Equivalent left middle) (last : Equivalent middle right) :
    Equivalent left right := fun path => (first path).trans (last path)

theorem Equivalent.access {left right : Term} (same : Equivalent left right) (next : Access) :
    Equivalent (access left next) (access right next) := fun path => same (next :: path)

theorem Equivalent.get {left right : Term} (same : Equivalent left right) (key : Term) :
    Equivalent (left.get key) (right.get key) := same.access (.key key)

theorem Equivalent.shape {left right : Term} (same : Equivalent left right) : shape left = shape right := same []

theorem Equivalent.integer {right : Term} {value : Int} (same : Equivalent (i value) right) : right = i value := by
  have root := same.shape
  cases right <;> cases root <;> rfl

theorem Equivalent.atom {right : Term} {value : String} (same : Equivalent (a value) right) : right = a value := by
  have root := same.shape
  cases right <;> cases root <;> rfl

theorem Equivalent.binary {right : Term} {value : ByteArray} (same : Equivalent (.binary value) right) : right = .binary value := by
  have root := same.shape
  cases right <;> cases root <;> rfl

theorem Equivalent.truthy {left right : Term} (same : Equivalent left right) : left.truthy = right.truthy := by
  have root := same.shape
  cases left <;> cases right <;> simp_all [ValueSemantics.shape, Term.truthy]

theorem Equivalent.isMap {left right : Term} (same : Equivalent left right) : left.isMap = right.isMap := by
  have root := same.shape
  cases left <;> cases right <;> simp_all [ValueSemantics.shape, Term.isMap]

theorem Equivalent.list {right : Term} {values : List Term} (same : Equivalent (list values) right) :
    ∃ other, right = list other ∧ values.length = other.length ∧
      ∀ index : Nat, Equivalent (values[index]?.getD nil) (other[index]?.getD nil) := by
  have root := same.shape
  cases right with
  | list other =>
    exact ⟨other, rfl, Shape.list.inj root, fun index => same.access (.index index)⟩
  | _ => cases root

theorem Equivalent.default {left right fallback other : Term}
    (same : Equivalent left right) (defaults : Equivalent fallback other) :
    Equivalent (left.default fallback) (right.default other) := by
  unfold Term.default
  rw [same.truthy]
  split
  · exact same
  · exact defaults

theorem Equivalent.integerValue {left right : Term} (same : Equivalent left right) : integerValue left = integerValue right := by
  have root := same.shape
  cases left <;> cases right <;> simp_all [ValueSemantics.shape, Data.integerValue]

theorem Equivalent.has {left right : Term} (same : Equivalent left right) (key : Term) :
    left.has key = right.has key := by
  have observed := (same.access (.present key)).shape
  cases first : left.has key <;> cases last : right.has key <;>
    simp_all [ValueSemantics.access, Term.bool, ValueSemantics.shape]

end VerifiedKernel.Session.WorkConservation.ValueSemantics
