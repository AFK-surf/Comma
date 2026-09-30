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

/-- `entry == key` for a map key: an atom or binary key compares only with an
entry key of its own kind. -/
@[inline] def Term.keyEq (key entry : Term) : Bool :=
  match key, entry with
  | .atom k, .atom s => s == k
  | .binary k, .binary s => s == k
  | .atom _, _ => false
  | .binary _, _ => false
  | _, _ => entry == key

theorem Term.keyEq_eq (key entry : Term) : Term.keyEq key entry = (entry == key) := by
  cases key <;> cases entry <;> first | rfl | (simp [Term.keyEq, BEq.beq]) | skip

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
