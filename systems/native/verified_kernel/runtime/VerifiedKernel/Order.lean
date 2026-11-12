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

def lexM (cmp : Term → Term → KernelM Ordering) :
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

def rawBits : Term → List Bool
  | .binary raw => raw.toList.flatMap (fun byte => (List.range 8).map (fun n => byte.toNat / 2^(7 - n) % 2 == 1))
  | .bitstring raw lastBits =>
    let bits := raw.toList.flatMap (fun byte => (List.range 8).map (fun n => byte.toNat / 2^(7 - n) % 2 == 1))
    bits.take (raw.size * 8 - (8 - lastBits.toNat))
  | _ => []

def compareLists (cmp : Term → Term → KernelM Ordering) (xtail ytail : Term) :
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

private def lexEval (cmp : Term → Term → KernelEval Ordering) :
    List Term → List Term → KernelEval Ordering
  | [], [] => pure .eq
  | [], _ => pure .lt
  | _, [] => pure .gt
  | x :: xs, y :: ys => do
    let order ← cmp x y
    if order == .eq then lexEval cmp xs ys else pure order

private theorem run_lexEval (cmp : Term → Term → KernelEval Ordering) (xs ys : List Term) :
    KernelEval.run (lexEval cmp xs ys) = lexM (fun x y => KernelEval.run (cmp x y)) xs ys := by
  induction xs generalizing ys with
  | nil => cases ys <;> simp [lexEval, lexM]
  | cons x xs ih => cases ys <;> simp [lexEval, lexM, ih]

private def compareListsEval (cmp : Term → Term → KernelEval Ordering) (xtail ytail : Term) :
    List Term → List Term → KernelEval Ordering
  | [], [] => cmp xtail ytail
  | [], ys => cmp xtail (.improper ys ytail)
  | xs, [] => cmp (.improper xs xtail) ytail
  | x :: xs, y :: ys => do
    let order ← cmp x y
    if order == .eq then compareListsEval cmp xtail ytail xs ys else pure order

private theorem run_compareListsEval (cmp : Term → Term → KernelEval Ordering) (xtail ytail : Term)
    (xs ys : List Term) : KernelEval.run (compareListsEval cmp xtail ytail xs ys) =
      compareLists (fun x y => KernelEval.run (cmp x y)) xtail ytail xs ys := by
  induction xs generalizing ys with
  | nil => cases ys <;> simp [compareListsEval, compareLists]
  | cons x xs ih => cases ys <;> simp [compareListsEval, compareLists, ih]

private def mergeEval (cmp : Term → Term → KernelEval Ordering) :
    Nat → List Term → List Term → List Term → KernelEval (List Term)
  | _, [], ys, acc => pure (acc.reverse ++ ys)
  | _, xs, [], acc => pure (acc.reverse ++ xs)
  | 0, _, _, _ => monadLift (fail "invalid_term")
  | fuel + 1, x :: xs, y :: ys, acc => do
    if (← cmp x y) != .gt then mergeEval cmp fuel xs (y :: ys) (x :: acc)
    else mergeEval cmp fuel (x :: xs) ys (y :: acc)

private theorem run_mergeEval (cmp : Term → Term → KernelEval Ordering) (fuel : Nat)
    (xs ys acc : List Term) : KernelEval.run (mergeEval cmp fuel xs ys acc) =
      sortM.merge (fun x y => KernelEval.run (cmp x y)) fuel xs ys acc := by
  induction fuel generalizing xs ys acc with
  | zero => cases xs <;> cases ys <;> simp [mergeEval, sortM.merge]
  | succ fuel ih => cases xs <;> cases ys <;> simp [mergeEval, sortM.merge, ih]

private def sortEval (cmp : Term → Term → KernelEval Ordering) : Nat → List Term → KernelEval (List Term)
  | 0, xs => pure xs
  | fuel + 1, xs => KernelEval.defer fun _ => do
    if xs.length ≤ 1 then return xs
    let (left, right) := xs.splitAt (xs.length / 2)
    mergeEval cmp xs.length (← sortEval cmp fuel left) (← sortEval cmp fuel right) []

private theorem run_sortEval (cmp : Term → Term → KernelEval Ordering) (fuel : Nat) (xs : List Term) :
    KernelEval.run (sortEval cmp fuel xs) = sortM.sort (fun x y => KernelEval.run (cmp x y)) fuel xs := by
  induction fuel generalizing xs with
  | zero => simp [sortEval, sortM.sort]
  | succ fuel ih => simp [sortEval, sortM.sort, run_mergeEval, ih]

def sortMImpl (cmp : Term → Term → KernelM Ordering) (xs : List Term) : KernelM (List Term) :=
  KernelEval.run (sortEval (fun x y => monadLift (cmp x y)) (xs.length + 1) xs)

@[csimp] theorem sortM_eq_sortMImpl : @sortM = @sortMImpl := by
  funext cmp xs
  simp [sortMImpl, run_sortEval, sortM]

private def orderDeferred : Nat → Bool → Term → Term → KernelEval Ordering
  | 0, _, _, _ => monadLift (fail "invalid_term_depth")
  | fuel + 1, keys, left, right => KernelEval.defer fun _ => do
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
      lexEval (orderDeferred fuel keys) xs ys
    | .list xs, .list ys => lexEval (orderDeferred fuel keys) xs ys
    | .improper xs xtail, .improper ys ytail => compareListsEval (orderDeferred fuel keys) xtail ytail xs ys
    | .list xs, .improper ys ytail => compareListsEval (orderDeferred fuel keys) (list []) ytail xs ys
    | .improper xs xtail, .list ys => compareListsEval (orderDeferred fuel keys) xtail (list []) xs ys
    | .map xs, .map ys =>
      if xs.length != ys.length then return compare xs.length ys.length
      let xkeys ← sortEval (orderDeferred fuel true) ((xs.map Prod.fst).length + 1) (xs.map Prod.fst)
      let ykeys ← sortEval (orderDeferred fuel true) ((ys.map Prod.fst).length + 1) (ys.map Prod.fst)
      let order ← lexEval (orderDeferred fuel true) xkeys ykeys
      if order != .eq then return order
      lexEval (orderDeferred fuel keys) (xkeys.map left.get) (ykeys.map right.get)
    | .bitstring _ _, _ | _, .bitstring _ _ => return compare (rawBits left) (rawBits right)
    | _, _ => monadLift (fail "schema" [b "runtime identities have no data ordering"])

private theorem orderDeferred_eq (fuel : Nat) (keys : Bool) (left right : Term) :
    KernelEval.run (orderDeferred fuel keys left right) = orderFuel fuel keys left right := by
  induction fuel generalizing keys left right with
  | zero => simp [orderDeferred, orderFuel]
  | succ fuel ih =>
    simp only [orderDeferred, orderFuel, KernelEval.run_defer, KernelEval.run_ite,
      KernelEval.run_pure, sortM]
    congr 1
    congr 1
    congr 1
    split <;> try simp_all only [KernelEval.run_pure]
    all_goals cases left <;> cases right <;>
      simp_all only [KernelEval.run_ite, KernelEval.run_pure, KernelEval.run_bind,
        KernelEval.run_lift, run_lexEval, run_compareListsEval, run_sortEval]

def orderFuelImpl (fuel : Nat) (keys : Bool) (left right : Term) : KernelM Ordering :=
  KernelEval.run (orderDeferred fuel keys left right)

@[csimp] theorem orderFuel_eq_orderFuelImpl : @orderFuel = @orderFuelImpl := by
  funext fuel keys left right
  exact (orderDeferred_eq fuel keys left right).symm

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
