import VerifiedKernel.Effect
import VerifiedKernel.Number
import Std.Data.HashSet.Basic

namespace VerifiedKernel.Data

abbrev a := Term.atom
abbrev b := Term.text
abbrev i := Term.integer
def nil : Term := a "nil"
def empty : Term := .map []
def list (xs : List Term := []) : Term := .list xs

def get? (value key : Term) (fallback : Term := nil) : KernelM Term :=
  match value with
  | .map xs => pure ((xs.find? (fun pair => pair.1 == key)).map Prod.snd |>.getD fallback)
  | _ => fail "badmap" [value]

def fetch (value key : Term) : KernelM Term := do
  if !value.isMap then fail "badmap" [value]
  else if value.has key then pure (value.get key)
  else fail "badkey" [key, value]

/-- `fetch` for compiled code: one search instead of `has` and then `get`. -/
def fetchImpl (value key : Term) : KernelM Term :=
  match value with
  | .map entries =>
    match entries.find? (fun pair => Term.keyEq key pair.1) with
    | some pair => pure pair.2
    | none => fail "badkey" [key, value]
  | _ => fail "badmap" [value]

@[csimp] theorem fetch_eq_fetchImpl : @fetch = @fetchImpl := by
  funext value key
  cases value <;> try rfl
  rename_i entries
  simp only [fetch, fetchImpl, Term.isMap, Term.has, Term.get, Bool.not_true, Bool.false_eq_true, ↓reduceIte,
    Term.keyEq_eq]
  cases h : entries.find? (fun pair => pair.1 == key) with
  | none =>
    have : entries.any (fun entry => entry.1 == key) = false := by
      simpa [List.find?_eq_none, List.any_eq_false] using h
    simp [this]
  | some pair =>
    have : entries.any (fun entry => entry.1 == key) = true := by
      have := List.find?_isSome.mp (by simp [h] : (entries.find? (fun pair => pair.1 == key)).isSome)
      simpa [List.any_eq_true] using this
    simp [this]


@[inline] def field (value : Term) (name : String) : KernelM Term := fetch value (a name)

def put (value key item : Term) : KernelM Term :=
  if value.isMap then pure (value.put key item) else fail "badmap" [value]

def write (value : Term) (entries : List (String × Term)) : KernelM Term :=
  entries.foldlM (fun state pair => do
    let _ ← field state pair.1
    put state (a pair.1) pair.2) value

def remove (value key : Term) : KernelM Term :=
  match value with
  | .map xs => pure (.map (xs.filter (fun pair => pair.1 != key)))
  | _ => fail "badmap" [value]

def entries (value : Term) : KernelM (List (Term × Term)) :=
  match value with
  | .map xs => pure xs
  | _ => fail "badmap" [value]

def merge (left right : Term) : KernelM Term := do
  let _ ← entries left
  (← entries right).foldlM (fun acc pair => put acc pair.1 pair.2) left

def select (value : Term) (keys : List String) (dropNil : Bool := false) : Term :=
  .map (keys.filterMap (fun name =>
    let key := b name
    if value.has key && (!dropNil || value.get key != nil) then some (key, value.get key) else none))

def present (value : Term) : Term :=
  match value with
  | .map xs => .map (xs.filter (fun pair => pair.2 != nil))
  | _ => value

def wrap (value : Term) : List Term :=
  match value with | .list xs => xs | .atom "nil" => [] | _ => [value]

def asList (value : Term) : KernelM (List Term) :=
  match value with | .list xs => pure xs | _ => fail "badarg" [value]

def append (left right : Term) : KernelM Term := do
  return .list ((← asList left) ++ (← asList right))

def add (left right : Term) : KernelM Term :=
  Number.calculate false left right

def sub (left right : Term) : KernelM Term :=
  Number.calculate true left right

def access (value key : Term) : KernelM Term := do
  if value.isMap && !value.has (a "__struct__") then return value.get key
  if value == nil then return nil
  fail "schema" [b "expected plain map for field access"]

private def plainLookup (key : Term) : List (Term × Term) → Option Term → Option Term
  | [], found => some (found.getD nil)
  | pair :: rest, found =>
    if Term.keyEq (a "__struct__") pair.1 then none
    else plainLookup key rest (match found with
      | some v => some v
      | none => if Term.keyEq key pair.1 then some pair.2 else none)

private theorem plainLookup_spec (key : Term) (entries : List (Term × Term)) (found : Option Term) :
    plainLookup key entries found =
      if entries.any (fun entry => entry.1 == a "__struct__") then none
      else some (found.getD (((entries.find? (fun pair => pair.1 == key)).map Prod.snd).getD nil)) := by
  induction entries generalizing found with
  | nil => simp [plainLookup]
  | cons pair rest ih =>
    simp only [plainLookup, List.any_cons, List.find?_cons, Term.keyEq_eq]
    by_cases hs : (pair.1 == a "__struct__") = true
    · simp [hs]
    · simp only [hs, Bool.false_or, Bool.false_eq_true, ↓reduceIte, ih]
      cases found with
      | some v => simp
      | none => by_cases hk : (pair.1 == key) = true <;> simp [hk]

/-- `access` for compiled code: one pass finds the key and rules out
`__struct__`, instead of a full `has` scan and then `get`. -/
def accessImpl (value key : Term) : KernelM Term :=
  match value with
  | .map entries =>
    match plainLookup key entries none with
    | some item => pure item
    | none => fail "schema" [b "expected plain map for field access"]
  | _ => if value == nil then pure nil else fail "schema" [b "expected plain map for field access"]

@[csimp] theorem access_eq_accessImpl : @access = @accessImpl := by
  funext value key
  cases value <;> try rfl
  rename_i entries
  funext s
  simp only [access, accessImpl, plainLookup_spec, Term.isMap, Term.has, Term.get, Bool.true_and]
  by_cases hs : entries.any (fun entry => entry.1 == a "__struct__") = true
  · have hn : (Term.map entries == nil) = false := rfl
    simp only [hs, Bool.not_true, Bool.and_false, Bool.false_eq_true, ↓reduceIte, hn]
  · simp [hs]; rfl

@[inline] def event (value : Term) (name : String) : KernelM Term := access value (b name)

/-- The second lookup runs only when the first value is nil or false. -/
def alias (value first second : Term) : KernelM Term := do
  let found ← access value first
  if found.truthy then pure found else access value second

def aliases (value : Term) : List Term → KernelM Term
  | [] => pure nil
  | [key] => access value key
  | key :: rest => do
    let found ← access value key
    if found.truthy then pure found else aliases value rest

def truthyPut (value key item : Term) : KernelM Term :=
  if item.truthy then put value key item else pure value

def nonnilPut (value key item : Term) : KernelM Term :=
  if item != nil then put value key item else pure value

def uniq (xs : List Term) : List Term :=
  if xs.all Term.isBinary then Id.run do
    let mut seen : Std.HashSet ByteArray := {}
    let mut result := []
    for value in xs do
      if let .binary raw := value then
        if !seen.contains raw then
          seen := seen.insert raw
          result := value :: result
    return result.reverse
  else xs.foldl (fun seen x => if seen.any (· == x) then seen else seen ++ [x]) []

def whitespace (c : Char) : Bool :=
  let n := c.toNat
  (9 ≤ n && n ≤ 13) || n == 32 || n == 133 || n == 160 || n == 5760 ||
    (8192 ≤ n && n ≤ 8202) || n == 8232 || n == 8233 || n == 8239 || n == 8287 || n == 12288

/-- The code point and byte length at `i`, read as UTF-8. A sequence that
runs past the end reads as U+FFFD, which is not whitespace. -/
private def utf8CharAt (raw : ByteArray) (i : Nat) : Nat × Nat :=
  let b0 := raw[i]!.toNat
  let len := if b0 < 0x80 then 1 else if b0 < 0xE0 then 2 else if b0 < 0xF0 then 3 else 4
  if i + len > raw.size then (0xFFFD, 1) else
  let tail := fun (k : Nat) => raw[i + k]!.toNat % 0x40
  if len == 1 then (b0, 1)
  else if len == 2 then (((b0 % 0x20) <<< 6) ||| tail 1, 2)
  else if len == 3 then (((b0 % 0x10) <<< 12) ||| (tail 1 <<< 6) ||| tail 2, 3)
  else (((b0 % 0x08) <<< 18) ||| (tail 1 <<< 12) ||| (tail 2 <<< 6) ||| tail 3, 4)

private def trimFront (raw : ByteArray) (i : Nat) : Nat → Nat
  | 0 => i
  | fuel + 1 =>
    if i < raw.size then
      let (code, len) := utf8CharAt raw i
      if whitespace (Char.ofNat code) then trimFront raw (i + len) fuel else i
    else i

/-- The index of the lead byte of the character ending before `stop`. -/
private def leadIndex (raw : ByteArray) (k : Nat) : Nat → Nat
  | 0 => k
  | fuel + 1 =>
    let byte := raw[k]!.toNat
    if k > 0 && byte ≥ 0x80 && byte < 0xC0 then leadIndex raw (k - 1) fuel else k

private def trimBack (raw : ByteArray) (start stop : Nat) : Nat → Nat
  | 0 => stop
  | fuel + 1 =>
    if start < stop then
      let lead := leadIndex raw (stop - 1) 3
      let (code, _) := utf8CharAt raw lead
      if whitespace (Char.ofNat code) then trimBack raw start lead fuel else stop
    else stop

/-- Whitespace removed from both ends. The result is a byte slice of the
input: trimming touches only the characters at the ends, where building the
character list of a long text and reversing it twice cost a long transcript
hundreds of milliseconds per activation. -/
def trim (raw : ByteArray) : ByteArray :=
  let start := trimFront raw 0 (raw.size + 1)
  let stop := trimBack raw start raw.size (raw.size + 1)
  -- Text with nothing to remove is returned as is whether or not it is
  -- valid UTF-8, so the validation pass over the whole text runs only when
  -- an end would be cut, where an invalid text must stay unchanged.
  if start == 0 && stop == raw.size then raw
  else if raw.validateUTF8 then raw.extract start stop
  else raw

def missing (value : Term) : Bool :=
  match value with | .binary bytes => (trim bytes).isEmpty | .atom "nil" => true | _ => false

def charData : Term → Option ByteArray
  | .binary raw => if (String.fromUTF8? raw).isSome then some raw else none
  | .integer n =>
    if n ≥ 0 && n ≤ 0x10FFFF && !(0xD800 ≤ n && n ≤ 0xDFFF) then
      some (String.singleton (Char.ofNat n.toNat)).toUTF8 else none
  | .list xs => do
    let parts ← xs.mapM charData
    return parts.foldl (· ++ ·) ByteArray.empty
  | _ => none

def stringChars (value : Term) : KernelM Term :=
  match value with
  | .binary _ => pure value
  | .atom "nil" => pure (b "")
  | .atom name => pure (b name)
  | .integer n => pure (b (toString n))
  | .floatBits bits => pure (b (Number.floatText bits))
  | .list _ => match charData value with
    | some raw => pure (.binary raw)
    | none => fail "schema" [b "expected Unicode character data"]
  | _ => fail "schema" [b "value has no schema-defined string conversion"]

def enumListLoop (step : α → Term → KernelM (Bool × α)) :
    List Term → α → KernelM α
  | [], acc => pure acc
  | item :: rest, acc => do
    let (more, next) ← step acc item
    if more then enumListLoop step rest next else pure next

/-- Traversal is defined only for lists, plain maps, and the MapSet data record. -/
def enumUntil (value : Term) (initial : α) (step : α → Term → KernelM (Bool × α)) : KernelM α := do
  match value with
  | .list xs => return ← enumListLoop step xs initial
  | .map xs =>
    if !value.has (a "__struct__") then
      return ← enumListLoop step (xs.map (fun p => .tuple [p.1, p.2])) initial
    if value.get (a "__struct__") == a "Elixir.MapSet" then
      match value.get (a "map") with
      | .map members => return ← enumListLoop step (members.map Prod.fst) initial
      | _ => fail "schema" [b "invalid MapSet data"]
  | _ => pure ()
  fail "schema" [b "expected an enumerable data container"]

def enumFold (value : Term) (initial : α) (step : α → Term → KernelM α) : KernelM α :=
  match value with
  | .improper heads _ => do
    let _ ← heads.foldlM step initial
    fail "enum_reduce_tail"
  | _ => enumUntil value initial (fun acc item => return (true, ← step acc item))

def enumMap (value : Term) (f : Term → KernelM Term) : KernelM (List Term) := do
  return (← enumFold value [] (fun acc item => return (← f item) :: acc)).reverse

def enumFind (value : Term) (f : Term → KernelM Bool) : KernelM Term :=
  enumUntil value nil (fun _ item => do
    if ← f item then return (false, item)
    return (true, nil))

def shallowStringify (value : Term) : KernelM Term := do
  let xs ← entries value
  if xs.all (fun pair => pair.1.isBinary) then return value
  enumFold value empty (fun acc pair => do
    let .tuple [key, item] := pair | fail "function_clause"
    put acc (← stringChars key) item)

def stringifyFuel : Nat → Term → KernelM Term
  | 0, _ => fail "invalid_observation"
  | fuel + 1, value =>
    match value with
    | .map _ => enumFold value empty (fun acc pair => do
      let .tuple [key, item] := pair | fail "function_clause"
      let key ← stringChars key
      put acc key (← stringifyFuel fuel item))
    | .list xs => return .list (← xs.mapM (stringifyFuel fuel))
    | .improper heads _ => do
      let _ ← heads.mapM (stringifyFuel fuel)
      fail "enum_map_tail"
    | value => pure value

def stringify (value : Term) : KernelM Term := do
  let observations ← get
  stringifyFuel (value.depth + 1 + (observations.map Term.depth).foldl (· + ·) 0) value

def integerValue (value : Term) : Int :=
  match value with
  | .integer n => n
  | .floatBits _ => match value.number with
    | some (n, d) => if n < 0 then -(Int.ofNat (n.natAbs / d)) else Int.ofNat (n.toNat / d)
    | none => 0
  | .binary raw => match String.fromUTF8? raw with
    | some text =>
      let chars := text.toList
      let (negative, digits) := match chars with
        | '-' :: rest => (true, rest)
        | '+' :: rest => (false, rest)
        | _ => (false, chars)
      if digits.isEmpty || !digits.all (fun c => c ≥ '0' && c ≤ '9') then 0
      else
        let magnitude : Nat := digits.foldl (fun n c => n * 10 + c.toNat - 48) 0
        if negative then -(Int.ofNat magnitude) else Int.ofNat magnitude
    | none => 0
  | _ => 0

def setMember (set key : Term) : KernelM Bool := do
  if !set.truthy then return false
  let members := set.get (a "map")
  if set.get (a "__struct__") == a "Elixir.MapSet" && members.isMap then
    return members.has key
  fail "schema" [b "expected MapSet data"]

def setPut (set key : Term) : KernelM Term := do
  if !set.truthy then
    return .map [(a "__struct__", a "Elixir.MapSet"), (a "map", .map [(key, list [])])]
  let members := set.get (a "map")
  if set.get (a "__struct__") == a "Elixir.MapSet" && members.isMap then
    return set.put (a "map") (members.put key (list []))
  fail "schema" [b "expected MapSet data"]

def dedupeHit (set : Term) : List Term → KernelM Bool
  | [] => pure false
  | key :: rest => do
    if ← setMember set key then return true
    dedupeHit set rest

def addDedupe (set : Term) (keys : List Term) : KernelM Term := keys.foldlM setPut set

end VerifiedKernel.Data
