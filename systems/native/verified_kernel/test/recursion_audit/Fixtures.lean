namespace RecursionFixtures

@[export recursion_fixture_loop]
def loop (items kept : List UInt8) : List UInt8 :=
  match items with
  | [] => kept
  | item :: rest => loop rest (item :: kept)

@[export recursion_fixture_recursive]
def recursive (items : List UInt8) : List UInt8 :=
  match items with
  | [] => []
  | item :: rest => item :: recursive rest

@[noinline] def helper (items : List UInt8) : List UInt8 :=
  match items with
  | [] => []
  | item :: rest => item :: helper rest

@[export recursion_fixture_transitive]
def transitive (items : List UInt8) : List UInt8 := helper items

mutual
  @[noinline] partial def first (items : List UInt8) : List UInt8 :=
    match items with
    | [] => []
    | item :: rest => item :: second rest

  @[noinline] partial def second (items : List UInt8) : List UInt8 :=
    match items with
    | [] => []
    | item :: rest => item :: first rest
end

@[export recursion_fixture_mutual]
def mutualCalls (items : List UInt8) : List UInt8 := first items

@[export recursion_fixture_closure]
def closure : Option (List UInt8 → List UInt8) := some helper

@[export recursion_fixture_indirect]
def indirect (action : List UInt8 → List UInt8) (items : List UInt8) : List UInt8 :=
  action items

@[export recursion_fixture_bounded]
def bounded (fuel : Nat) (items : List UInt8) : List UInt8 :=
  match fuel, items with
  | 0, _ | _, [] => []
  | fuel + 1, item :: rest => item :: bounded fuel rest

@[export recursion_fixture_closed_bound]
def closedBound (items : List UInt8) : List UInt8 := bounded 64 items

@[noinline] def invoke (f : UInt8 → UInt8) (x : UInt8) : UInt8 := f x

@[export recursion_fixture_known]
def knownCallback (choose : Bool) (x : UInt8) : UInt8 :=
  invoke (if choose then fun n => n + 1 else fun n => n - 1) x

@[export recursion_fixture_array]
def arrayCallback (index : Nat) (x : UInt8) : UInt8 :=
  let callbacks : Array (UInt8 → UInt8) := #[fun n => n + 1, fun n => n - 1]
  invoke (callbacks[index % 2]!) x

@[noinline] partial def reset (fuel n : Nat) : Nat :=
  if fuel == 0 then n else 1 + reset 64 (n + 1)

@[export recursion_fixture_reset]
def resetFuel (n : Nat) : Nat := reset 64 n

@[noinline] partial def truncated (fuel : Nat) : Nat := 1 + truncated (fuel - 1)

@[export recursion_fixture_truncated]
def truncatedFuel : Nat := truncated 64

@[extern "recursion_fixture_foreign_container"] opaque foreignContainer : Nat → Option (UInt8 → UInt8)

@[export recursion_fixture_foreign_result]
def foreignResult (n : Nat) : UInt8 :=
  match foreignContainer n with | some callback => callback 0 | none => 0

@[extern "recursion_fixture_foreign_call"] opaque foreignCall : (UInt8 → UInt8) → UInt8 → UInt8

@[export recursion_fixture_foreign_callback]
def foreignCallback (x : UInt8) : UInt8 := foreignCall (fun n => n + 1) x

@[export recursion_fixture_input_container]
def inputContainer (callbacks : List (UInt8 → UInt8)) (x : UInt8) : UInt8 :=
  callbacks.foldl (fun value callback => callback value) x

@[noinline] def callbacks (items : List (List UInt8 → List UInt8)) : List (List UInt8 → List UInt8) :=
  items.reverse

@[export recursion_fixture_container_recursion]
def containerRecursion (choose : Bool) (items : List UInt8) : List UInt8 :=
  let functions := callbacks [helper, fun xs => xs]
  match functions with
  | first :: second :: _ => (if choose then first else second) items
  | _ => items

mutual
  @[noinline] def boundedFirst : Nat → Nat
    | 0 => 0
    | fuel + 1 => 1 + boundedSecond fuel
  @[noinline] def boundedSecond : Nat → Nat
    | 0 => 0
    | fuel + 1 => 1 + boundedFirst fuel
end

@[export recursion_fixture_bounded_mutual]
def boundedMutual (offset : Nat) : Nat := offset + boundedFirst 32

@[noinline] partial def refuel (fuel n : Nat) : Nat :=
  if fuel == 0 then refuel 64 n else 1 + refuel (fuel - 1) n

@[export recursion_fixture_tail_refuel]
def tailRefuel (n : Nat) : Nat := refuel 64 n

end RecursionFixtures
