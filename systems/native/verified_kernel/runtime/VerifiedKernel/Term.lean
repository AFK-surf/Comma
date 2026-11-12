import VerifiedKernel.Zip
import VerifiedKernel.StacklessStd

namespace VerifiedKernel

inductive Term where
  | integer (value : Int)
  | atom (value : String)
  | binary (value : ByteArray)
  | floatBits (value : UInt64)
  | tuple (values : List Term)
  | list (values : List Term)
  | map (entries : List (Term × Term))
  | improper (heads : List Term) (tail : Term)
  | bitstring (bytes : ByteArray) (lastBits : UInt8)
  deriving Inhabited

def Term.depth : Term → Nat
  | .tuple xs | .list xs => 1 + (xs.map depth).foldl max 0
  | .map xs => 1 + (xs.map (fun pair => max pair.1.depth pair.2.depth)).foldl max 0
  | .improper xs tail => 1 + max tail.depth ((xs.map depth).foldl max 0)
  | _ => 1
termination_by value => sizeOf value
decreasing_by
  all_goals simp_wf
  all_goals first
    | decreasing_trivial
    | (have h := List.sizeOf_lt_of_mem (by assumption)
       cases ‹Term × Term›
       simp_all
       omega)

private def Term.depthDeferred (value : Term) : Stackless Nat := .delay fun _ =>
  match value with
  | .tuple xs | .list xs =>
    .bind (Stackless.mapM (fun x => x.val.depthDeferred) xs.attach) fun depths =>
      .done (1 + depths.foldl max 0)
  | .map xs =>
    .bind (Stackless.mapM (fun pair =>
      .bind pair.val.1.depthDeferred fun left =>
        .bind pair.val.2.depthDeferred fun right => .done (max left right)) xs.attach) fun depths =>
      .done (1 + depths.foldl max 0)
  | .improper xs tail =>
    .bind tail.depthDeferred fun last =>
      .bind (Stackless.mapM (fun x => x.val.depthDeferred) xs.attach) fun depths =>
        .done (1 + max last (depths.foldl max 0))
  | _ => .done 1
termination_by sizeOf value
decreasing_by
  all_goals simp_wf
  all_goals first
    | decreasing_trivial
    | (have h := List.sizeOf_lt_of_mem x.property; omega)
    | (have h := List.sizeOf_lt_of_mem pair.property
       rcases pair with ⟨⟨left, right⟩, member⟩
       simp_all
       omega)

private theorem Term.depthDeferred_eq (value : Term) : value.depthDeferred.run = value.depth := by
  fun_induction Term.depth value <;> simp_all [Term.depthDeferred, Stackless.run]
  rename_i xs left right
  have children (pair : { pair // pair ∈ xs }) :
      max pair.val.1.depthDeferred.run pair.val.2.depthDeferred.run = max pair.val.1.depth pair.val.2.depth := by
    rw [left _ _ pair.property, right _ _ pair.property]
  simp only [children]
  simp [List.map_attach_eq_pmap]

def Term.depthImpl (value : Term) : Nat := value.depthDeferred.run

@[csimp] theorem Term.depth_eq_depthImpl : @Term.depth = @Term.depthImpl := by
  funext value
  exact value.depthDeferred_eq.symm

/-- Map equality is independent of wire order. OTP 27+ exact equality keeps
positive and negative floating-point zero distinct, including as map keys. -/
def Term.exactFuel : Nat → Term → Term → Bool
  | 0, _, _ => false
  | n + 1, left, right =>
    match left, right with
    | .integer x, .integer y => x == y
    | .atom x, .atom y => x == y
    | .binary x, .binary y => x == y
    | .floatBits x, .floatBits y => x == y
    | .tuple xs, .tuple ys | .list xs, .list ys =>
      xs.length == ys.length && (xs.zip ys).all (fun (x, y) => exactFuel n x y)
    | .map xs, .map ys =>
      xs.length == ys.length && xs.all (fun (k, v) =>
        ys.any (fun (l, w) => exactFuel n k l && exactFuel n v w))
    | .improper xs x, .improper ys y =>
      xs.length == ys.length && exactFuel n x y &&
        (xs.zip ys).all (fun (a, b) => exactFuel n a b)
    | .bitstring xs x, .bitstring ys y => xs == ys && x == y
    | _, _ => false

private def Term.exactDeferred : Nat → Term → Term → Stackless Bool
  | 0, _, _ => .done false
  | n + 1, left, right => .delay fun _ =>
    match left, right with
    | .integer x, .integer y => .done (x == y)
    | .atom x, .atom y => .done (x == y)
    | .binary x, .binary y => .done (x == y)
    | .floatBits x, .floatBits y => .done (x == y)
    | .tuple xs, .tuple ys | .list xs, .list ys =>
      Stackless.both (.done (xs.length == ys.length)) fun _ =>
        Stackless.allM (fun (x, y) => exactDeferred n x y) (xs.zip ys)
    | .map xs, .map ys =>
      Stackless.both (.done (xs.length == ys.length)) fun _ =>
        Stackless.allM (fun (k, v) => Stackless.anyM (fun (l, w) =>
          Stackless.both (exactDeferred n k l) fun _ => exactDeferred n v w) ys) xs
    | .improper xs x, .improper ys y =>
      Stackless.both (Stackless.both (.done (xs.length == ys.length)) fun _ => exactDeferred n x y) fun _ =>
        Stackless.allM (fun (a, b) => exactDeferred n a b) (xs.zip ys)
    | .bitstring xs x, .bitstring ys y => .done (xs == ys && x == y)
    | _, _ => .done false

private theorem Term.exactDeferred_eq (fuel : Nat) (left right : Term) :
    (exactDeferred fuel left right).run = exactFuel fuel left right := by
  induction fuel generalizing left right with
  | zero => rfl
  | succ fuel ih =>
    cases left <;> cases right <;>
      simp [exactDeferred, Stackless.run, exactFuel, ih]

def Term.exactFuelImpl (fuel : Nat) (left right : Term) : Bool :=
  (exactDeferred fuel left right).run

@[csimp] theorem Term.exactFuel_eq_exactFuelImpl : @Term.exactFuel = @Term.exactFuelImpl := by
  funext fuel left right
  exact (exactDeferred_eq fuel left right).symm

instance : BEq Term := ⟨fun x y =>
  match x, y with
  | .integer a, .integer b => a == b
  | .atom a, .atom b => a == b
  | .binary a, .binary b => a == b
  | .floatBits a, .floatBits b => a == b
  | .tuple xs, .tuple ys | .list xs, .list ys =>
    xs.length == ys.length && Term.exactFuel (max x.depth y.depth) x y
  | .map xs, .map ys =>
    xs.length == ys.length && Term.exactFuel (max x.depth y.depth) x y
  | .improper _ _, .improper _ _ => Term.exactFuel (max x.depth y.depth) x y
  | .bitstring a m, .bitstring b n => a == b && m == n
  | _, _ => false⟩

def Term.truthy : Term → Bool
  | .atom "nil" | .atom "false" => false
  | _ => true

def Term.isMap : Term → Bool | .map _ => true | _ => false
def Term.isBinary : Term → Bool | .binary _ => true | _ => false
def Term.isInteger : Term → Bool | .integer _ => true | _ => false
def Term.isList : Term → Bool | .list _ => true | _ => false
def Term.isBoolean (v : Term) : Bool := v == .atom "true" || v == .atom "false"

def Term.bool (v : Bool) : Term := .atom (if v then "true" else "false")

/-- Exact rational values avoid rounding large integers during numeric comparison. -/
def Term.number : Term → Option (Int × Nat)
  | .integer i => some (i, 1)
  | .floatBits bits =>
    let b := bits.toNat
    let exponent := b / 2^52 % 2048
    let significand : Nat := b % 2^52 + (if exponent == 0 then 0 else 2^52)
    let signed : Int := if b / 2^63 == 0 then Int.ofNat significand else -(Int.ofNat significand)
    let exponent := if exponent == 0 then 1 else exponent
    if exponent ≥ 1075 then some (signed * Int.ofNat (2^(exponent - 1075)), 1)
    else some (signed, 2^(1075 - exponent))
  | _ => none

def Term.numericEqFuel : Nat → Term → Term → Bool
  | 0, _, _ => false
  | fuel + 1, left, right =>
    match left.number, right.number with
    | some (x, xd), some (y, yd) => x * Int.ofNat yd == y * Int.ofNat xd
    | _, _ =>
      match left, right with
      | .tuple xs, .tuple ys | .list xs, .list ys =>
        xs.length == ys.length && (xs.zip ys).all (fun (x, y) => numericEqFuel fuel x y)
      | .map xs, .map ys =>
        xs.length == ys.length && xs.all (fun (k, v) =>
          ys.any (fun (l, w) => k == l && numericEqFuel fuel v w))
      | .improper xs x, .improper ys y =>
        xs.length == ys.length && numericEqFuel fuel x y &&
          (xs.zip ys).all (fun (a, b) => numericEqFuel fuel a b)
      | _, _ => left == right

private def Term.numericEqDeferred : Nat → Term → Term → Stackless Bool
  | 0, _, _ => .done false
  | fuel + 1, left, right => .delay fun _ =>
    match left.number, right.number with
    | some (x, xd), some (y, yd) => .done (x * Int.ofNat yd == y * Int.ofNat xd)
    | _, _ =>
      match left, right with
      | .tuple xs, .tuple ys | .list xs, .list ys =>
        Stackless.both (.done (xs.length == ys.length)) fun _ =>
          Stackless.allM (fun (x, y) => numericEqDeferred fuel x y) (xs.zip ys)
      | .map xs, .map ys =>
        Stackless.both (.done (xs.length == ys.length)) fun _ =>
          Stackless.allM (fun (k, v) => Stackless.anyM (fun (l, w) =>
            Stackless.both (.done (k == l)) fun _ => numericEqDeferred fuel v w) ys) xs
      | .improper xs x, .improper ys y =>
        Stackless.both (Stackless.both (.done (xs.length == ys.length)) fun _ => numericEqDeferred fuel x y) fun _ =>
          Stackless.allM (fun (a, b) => numericEqDeferred fuel a b) (xs.zip ys)
      | _, _ => .done (left == right)

private theorem Term.numericEqDeferred_eq (fuel : Nat) (left right : Term) :
    (numericEqDeferred fuel left right).run = numericEqFuel fuel left right := by
  induction fuel generalizing left right with
  | zero => rfl
  | succ fuel ih =>
    cases left <;> cases right <;>
      simp [numericEqDeferred, Stackless.run, numericEqFuel, Term.number, ih]
    all_goals split <;> simp_all [Stackless.run]

def Term.numericEqFuelImpl (fuel : Nat) (left right : Term) : Bool :=
  (numericEqDeferred fuel left right).run

@[csimp] theorem Term.numericEqFuel_eq_numericEqFuelImpl : @Term.numericEqFuel = @Term.numericEqFuelImpl := by
  funext fuel left right
  exact (numericEqDeferred_eq fuel left right).symm

def Term.numericEq (left right : Term) : Bool :=
  numericEqFuel (max left.depth right.depth) left right

def Term.text (s : String) : Term := .binary s.toUTF8

def Term.get (value key : Term) : Term :=
  match value with
  | .map entries => (entries.find? (fun entry => entry.1 == key)).map Prod.snd |>.getD (.atom "nil")
  | _ => .atom "nil"

def Term.has (value key : Term) : Bool :=
  match value with
  | .map entries => entries.any (fun entry => entry.1 == key)
  | _ => false

/-- `entry == key` for an atom or binary key. -/
@[inline] def Term.scalarKeyEq (key entry : Term) : Bool :=
  match key, entry with
  | .atom k, .atom s => s == k
  | .binary k, .binary s => s == k
  | _, _ => false

/-- Whether a key is an atom or a binary. -/
@[inline] def Term.isScalarKey : Term → Bool
  | .atom _ | .binary _ => true
  | _ => false

/-- Entry elements against key elements that are atoms or binaries, in order. -/
def Term.flatKeyEq : List Term → List Term → Bool
  | [], [] => true
  | entry :: entries, key :: keys => Term.scalarKeyEq key entry && Term.flatKeyEq entries keys
  | _, _ => false

/-- `entry == key` for a map key: an atom or binary key compares only with an
entry key of its own kind, and a tuple of atoms and binaries (an IFC audience
atom) compares element by element, without the depth-bounded walk. -/
@[inline] def Term.keyEq (key entry : Term) : Bool :=
  match key, entry with
  | .atom _, _ | .binary _, _ => Term.scalarKeyEq key entry
  | .tuple ks, .tuple es => if ks.all Term.isScalarKey then Term.flatKeyEq es ks else entry == key
  | _, _ => entry == key

private theorem Term.exactFuel_scalar (fuel : Nat) (entry key : Term) (scalar : key.isScalarKey = true) :
    Term.exactFuel (fuel + 1) entry key = Term.scalarKeyEq key entry := by
  cases key <;> simp [Term.isScalarKey] at scalar <;> cases entry <;>
    simp [Term.exactFuel, Term.scalarKeyEq]

private theorem Term.zip_exactFuel_flat (fuel : Nat) :
    ∀ (entries keys : List Term), keys.all Term.isScalarKey = true →
      (entries.length == keys.length &&
        (entries.zip keys).all (fun pair => Term.exactFuel (fuel + 1) pair.1 pair.2)) =
      Term.flatKeyEq entries keys
  | [], [], _ => rfl
  | [], _ :: _, _ => rfl
  | _ :: _, [], _ => by simp [Term.flatKeyEq]
  | entry :: entries, key :: keys, scalar => by
    simp only [List.all_cons, Bool.and_eq_true] at scalar
    have rest := Term.zip_exactFuel_flat fuel entries keys scalar.2
    simp only [List.length_cons, List.zip_cons_cons, List.all_cons, Term.flatKeyEq,
      Term.exactFuel_scalar fuel entry key scalar.1, ← rest]
    cases Term.scalarKeyEq key entry <;> simp

private theorem Term.fold_max_ge (values : List Nat) (seed : Nat) : seed ≤ values.foldl max seed := by
  induction values generalizing seed with
  | nil => exact Nat.le_refl _
  | cons value values ih => exact Nat.le_trans (Nat.le_max_left _ _) (ih _)

private theorem Term.flat_tuple_depth (key : Term) (keys : List Term) (scalar : key.isScalarKey = true) :
    2 ≤ (Term.tuple (key :: keys)).depth := by
  have one : key.depth = 1 := by
    cases key <;> simp [Term.isScalarKey] at scalar <;> rw [Term.depth] <;> simp
  rw [Term.depth]
  simp only [List.map_cons, List.foldl_cons, one]
  have := Term.fold_max_ge (keys.map Term.depth) (max 0 1)
  omega

theorem Term.keyEq_eq (key entry : Term) : Term.keyEq key entry = (entry == key) := by
  cases key with
  | tuple keys =>
    cases entry with
    | tuple entries =>
      simp only [Term.keyEq]
      split
      · rename_i scalar
        change Term.flatKeyEq entries keys = (entries.length == keys.length &&
          Term.exactFuel (max (Term.tuple entries).depth (Term.tuple keys).depth) (.tuple entries) (.tuple keys))
        cases keys with
        | nil =>
          obtain ⟨fuel, same⟩ : ∃ fuel, max (Term.tuple entries).depth (Term.tuple []).depth = fuel + 1 :=
            ⟨_, (Nat.succ_pred_eq_of_pos (Nat.lt_of_lt_of_le (by rw [Term.depth]; simp)
              (Nat.le_max_right _ _))).symm⟩
          rw [same]
          cases entries <;> simp [Term.flatKeyEq, Term.exactFuel]
        | cons key rest =>
          have deep := Nat.le_trans (Term.flat_tuple_depth key rest (by
            simp only [List.all_cons, Bool.and_eq_true] at scalar; exact scalar.1)) (Nat.le_max_right
              (Term.tuple entries).depth _)
          obtain ⟨fuel, same⟩ : ∃ fuel, max (Term.tuple entries).depth (Term.tuple (key :: rest)).depth =
              fuel + 1 + 1 :=
            ⟨max (Term.tuple entries).depth (Term.tuple (key :: rest)).depth - 2, by omega⟩
          rw [same, Term.exactFuel, ← Term.zip_exactFuel_flat fuel entries (key :: rest) scalar]
          cases entries.length == (key :: rest).length <;> simp
      · rfl
    | _ => rfl
  | _ => cases entry <;> first | rfl | (simp [Term.keyEq, Term.scalarKeyEq, BEq.beq]) | skip

/-- The value under the first entry whose key is `key`, else `nil`, without an
intermediate `Option` per lookup. -/
def Term.lookup (key : Term) : List (Term × Term) → Term
  | [] => .atom "nil"
  | entry :: rest => if Term.keyEq key entry.1 then entry.2 else Term.lookup key rest

theorem Term.lookup_eq (key : Term) (entries : List (Term × Term)) :
    Term.lookup key entries =
      ((entries.find? (fun entry => Term.keyEq key entry.1)).map Prod.snd |>.getD (.atom "nil")) := by
  induction entries with
  | nil => rfl
  | cons entry rest ih =>
    simp only [Term.lookup, List.find?_cons]
    split <;> simp_all

/-- `Term.get` for compiled code, comparing keys with `Term.keyEq`. -/
def Term.getImpl (value key : Term) : Term :=
  match value with
  | .map entries => Term.lookup key entries
  | _ => .atom "nil"

/-- `Term.has` for compiled code, comparing keys with `Term.keyEq`. -/
def Term.hasImpl (value key : Term) : Bool :=
  match value with
  | .map entries => entries.any (fun entry => Term.keyEq key entry.1)
  | _ => false

@[csimp] theorem Term.get_eq_getImpl : @Term.get = @Term.getImpl := by
  funext value key
  cases value <;> simp [Term.get, Term.getImpl, Term.lookup_eq, Term.keyEq_eq]

@[csimp] theorem Term.has_eq_hasImpl : @Term.has = @Term.hasImpl := by
  funext value key
  cases value <;> simp [Term.has, Term.hasImpl, Term.keyEq_eq]
def Term.put (value key item : Term) : Term :=
  match value with
  | .map entries => .map ((key, item) :: entries.filter (fun entry => !(entry.1 == key)))
  | _ => .map [(key, item)]

/-- Compiled code evaluates `fallback` only when `value` is falsy: a fallback
is often a second map lookup, which a present first key makes unnecessary. -/
@[macro_inline] def Term.default (value fallback : Term) : Term :=
  if value.truthy then value else fallback

end VerifiedKernel
