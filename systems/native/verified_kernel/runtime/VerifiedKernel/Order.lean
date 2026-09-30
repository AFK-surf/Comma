import VerifiedKernel.Data
import Init.Data.List.Sort.Basic

namespace VerifiedKernel.Data

def rank : Term → Nat
  | .integer _ | .floatBits _ => 0
  | .atom _ => 1
  | .tuple _ => 6
  | .map _ => 7
  | .list [] => 8
  | .list _ | .improper _ _ => 9
  | .binary _ | .bitstring _ _ => 10

private def lexM (cmp : Term → Term → KernelM Ordering) :
    List Term → List Term → KernelM Ordering
  | [], [] => pure .eq
  | [], _ => pure .lt
  | _, [] => pure .gt
  | x :: xs, y :: ys => do
    let order ← cmp x y
    if order == .eq then lexM cmp xs ys else pure order

def sortM (cmp : Term → Term → KernelM Ordering) (xs : List Term) : KernelM (List Term) := do
  -- A merge must not retain one native stack frame per transcript item:
  -- this runs on a BEAM dirty scheduler, including during snapshot recovery.
  let rec merge : Nat → List Term → List Term → List Term → KernelM (List Term)
    | _, [], ys, acc => pure (acc.reverse ++ ys)
    | _, xs, [], acc => pure (acc.reverse ++ xs)
    | 0, _, _, _ => fail "invalid_term"
    | fuel + 1, x :: xs, y :: ys, acc => do
      if (← cmp x y) != .gt then merge fuel xs (y :: ys) (x :: acc)
      else merge fuel (x :: xs) ys (y :: acc)
  let rec sort : Nat → List Term → KernelM (List Term)
    | 0, xs => pure xs
    | fuel + 1, xs => do
      if xs.length ≤ 1 then return xs
      let (left, right) := xs.splitAt (xs.length / 2)
      merge xs.length (← sort fuel left) (← sort fuel right) []
  sort (xs.length + 1) xs

private def rawBits : Term → List Bool
  | .binary raw => raw.toList.flatMap (fun byte => (List.range 8).map (fun n => byte.toNat / 2^(7 - n) % 2 == 1))
  | .bitstring raw lastBits =>
    let bits := raw.toList.flatMap (fun byte => (List.range 8).map (fun n => byte.toNat / 2^(7 - n) % 2 == 1))
    bits.take (raw.size * 8 - (8 - lastBits.toNat))
  | _ => []

private def compareLists (cmp : Term → Term → KernelM Ordering) (xtail ytail : Term) :
    List Term → List Term → KernelM Ordering
  | [], [] => cmp xtail ytail
  | [], ys => cmp xtail (.improper ys ytail)
  | xs, [] => cmp (.improper xs xtail) ytail
  | x :: xs, y :: ys => do
    let order ← cmp x y
    if order == .eq then compareLists cmp xtail ytail xs ys else pure order

def orderFuel : Nat → Bool → Term → Term → KernelM Ordering
  | 0, _, _, _ => fail "invalid_term_depth"
  | fuel + 1, keys, left, right => do
    if left == right then return .eq
    if keys && left.number.isSome && right.number.isSome && left.isInteger != right.isInteger then
      return if left.isInteger then .lt else .gt
    if rank left != rank right then return compare (rank left) (rank right)
    match left.number, right.number with
    | some (x, xd), some (y, yd) => return compare (x * Int.ofNat yd) (y * Int.ofNat xd)
    | _, _ => pure ()
    match left, right with
    | .atom x, .atom y => return compare x y
    | .binary x, .binary y => return compare x.toList y.toList
    | .tuple xs, .tuple ys =>
      if xs.length != ys.length then return compare xs.length ys.length
      lexM (orderFuel fuel keys) xs ys
    | .list xs, .list ys => lexM (orderFuel fuel keys) xs ys
    | .improper xs xtail, .improper ys ytail => compareLists (orderFuel fuel keys) xtail ytail xs ys
    | .list xs, .improper ys ytail => compareLists (orderFuel fuel keys) (list []) ytail xs ys
    | .improper xs xtail, .list ys => compareLists (orderFuel fuel keys) xtail (list []) xs ys
    | .map xs, .map ys =>
      if xs.length != ys.length then return compare xs.length ys.length
      let xkeys ← sortM (orderFuel fuel true) (xs.map Prod.fst)
      let ykeys ← sortM (orderFuel fuel true) (ys.map Prod.fst)
      let order ← lexM (orderFuel fuel true) xkeys ykeys
      if order != .eq then return order
      lexM (orderFuel fuel keys) (xkeys.map left.get) (ykeys.map right.get)
    | .bitstring _ _, _ | _, .bitstring _ _ => return compare (rawBits left) (rawBits right)
    | _, _ => fail "schema" [b "runtime identities have no data ordering"]

def order (left right : Term) : KernelM Ordering :=
  orderFuel (max left.depth right.depth + 1) false left right

/-- `order` for compiled code: two integers compare directly, without the depth
walk and the rational conversion that `orderFuel` makes for any two numbers. -/
def orderImpl (left right : Term) : KernelM Ordering :=
  match left, right with
  | .integer x, .integer y => pure (compare x y)
  | _, _ => orderFuel (max left.depth right.depth + 1) false left right

@[csimp] theorem order_eq_orderImpl : @order = @orderImpl := by
  funext left right
  cases left <;> cases right <;> try rfl
  rename_i x y
  funext s
  unfold order orderImpl
  simp only [Term.depth, Nat.max_self]
  by_cases hxy : x = y
  · subst hxy
    simp [orderFuel, Pure.pure, StateT.pure, Except.pure, BEq.beq]
  · simp [orderFuel, Pure.pure, StateT.pure, Except.pure, BEq.beq, hxy, rank, Term.number]

def less (left right : Term) : KernelM Bool := return (← order left right) == .lt
def greater (left right : Term) : KernelM Bool := less right left
def atMost (left right : Term) : KernelM Bool := return (← order left right) != .gt

def maximum (left right : Term) : KernelM Term := do
  if ← atMost left right then pure right else pure left

def minimum (left right : Term) : KernelM Term := do
  if ← atMost left right then pure left else pure right

def sorted (xs : List Term) : KernelM (List Term) := sortM order xs

def sortedKeys (xs : List Term) : KernelM (List Term) :=
  sortM (fun x y => orderFuel (max x.depth y.depth + 1) true x y) xs

def sortBy (xs : List Term) (f : Term → KernelM Term) (descending : Bool := false) : KernelM (List Term) := do
  let keyed ← xs.mapM (fun x => return Term.tuple [← f x, x])
  let ordered ← sortM (fun x y => do
    let .tuple [kx, _] := x | fail "invalid_term"
    let .tuple [ky, _] := y | fail "invalid_term"
    if descending then order ky kx else order kx ky) keyed
  return ordered.filterMap (fun x => match x with | .tuple [_, v] => some v | _ => none)

end VerifiedKernel.Data
