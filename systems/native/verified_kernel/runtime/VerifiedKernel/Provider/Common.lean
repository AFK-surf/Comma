import VerifiedKernel.Json

namespace VerifiedKernel.Provider
open Data

def obj (fields : List (String × Term)) : Term := .map (fields.map fun (k, v) => (b k, v))
def host (fields : List (String × Term)) : Term := .map (fields.map fun (k, v) => (a k, v))
@[inline] def get (m : Term) (key : String) : Term := m.get (b key)
@[inline] def field (m : Term) (key : String) : Term :=
  let v := m.get (a key)
  if v.truthy then v else get m key
def coalesce (xs : List Term) : Term := (xs.find? Term.truthy).getD nil
def items : Term → List Term | .list xs => xs | _ => []
def bytes : Term → ByteArray | .binary raw => raw | _ => ByteArray.empty
def nonempty (v : Term) : Bool := v.isBinary && v != b ""
def str (v : Term) : KernelM Term := stringChars v
def cat (xs : List Term) : KernelM Term := do
  return .binary ((← xs.mapM str).foldl (fun acc v => acc ++ bytes v) ByteArray.empty)
def join (xs : List Term) (sep : String := "") : KernelM Term := do
  -- Do not materialize interspersed cells: Lean's intersperseTR retains a
  -- native frame per fragment on the bounded dirty-scheduler stack.
  let mut output := ByteArray.empty
  let mut first := true
  for value in xs do
    if !first then output := output ++ sep.toUTF8
    output := output ++ bytes (← str value)
    first := false
  return .binary output
def encode (v : Term) : KernelM Term := do
  let some raw ← Json.encode v | fail "badarg"
  return .binary raw
def decode (v : Term) : Option Term := if v.isBinary then Json.decode (bytes v) else none
def putOptional (m : Term) (k : String) (v : Term) : Term :=
  if v == nil then m else m.put (b k) v
def trimmed (v : Term) : KernelM Term := return .binary (trim (bytes (← str v)))
def member (v : Term) (values : List String) : Bool := values.any (v == b ·)
def mergeMaps (x y : Term) : Term :=
  match y with | .map entries => entries.foldl (fun acc (k, v) => acc.put k v) x | _ => x
def removeKey (m : Term) (key : Term) : Term :=
  match m with | .map entries => .map (entries.filter (·.1 != key)) | _ => m

private def scrubBytes (raw : ByteArray) : ByteArray := Id.run do
  if (String.fromUTF8? raw).isSome then return raw
  let mut output := ByteArray.empty
  let mut pos := 0
  for _ in [:raw.size] do
    if pos ≥ raw.size then break
    let mut width := 0
    for n in [1:5] do
      if pos + n ≤ raw.size && (String.fromUTF8? (raw.extract pos (pos + n))).isSome then
        width := n
        break
    if width == 0 then
      output := output ++ "�".toUTF8
      pos := pos + 1
    else
      output := output ++ raw.extract pos (pos + width)
      pos := pos + width
  return output

private def scrubFuel : Nat → Term → Term
  | 0, value => value
  | _ + 1, .binary raw => .binary (scrubBytes raw)
  | fuel + 1, .list xs => list (xs.map (scrubFuel fuel))
  | fuel + 1, .map xs =>
    if xs.any (·.1 == a "__struct__") then .map xs
    else .map (xs.map (fun pair => (scrubFuel fuel pair.1, scrubFuel fuel pair.2)))
  | _, value => value

def scrub (value : Term) : Term := scrubFuel (value.depth + 1) value

def toolName (name : Term) : Bool :=
  let raw := bytes name
  let alpha := fun c : UInt8 => (c ≥ 65 && c ≤ 90) || (c ≥ 97 && c ≤ 122)
  name.isBinary && raw.size > 0 && raw.size ≤ 64 && alpha raw[0]! &&
    raw.data.all (fun c => alpha c || (c ≥ 48 && c ≤ 57) || c == 95 || c == 45)

def toolSpec (protocol : String) (spec : Term) : KernelM Term := do
  let name := get spec "name"
  if !toolName name then fail "badarg" [b "invalid provider tool name"]
  let schema := get spec "input_schema"
  if !schema.isMap then fail "badarg" [b "tool spec is missing input_schema"]
  let description := get spec "description"
  if protocol == "anthropic" then
    return obj [("name", name), ("description", description), ("input_schema", schema)]
  if protocol == "responses" then
    return obj [("type", b "function"), ("name", name), ("description", description), ("parameters", schema)]
  let f := obj [("name", name), ("parameters", schema)]
  let f := if description.isBinary && !missing description then f.put (b "description") description else f
  return obj [("type", b "function"), ("function", f)]

def result (text : Term) (calls : List Term) (metadata : Term := empty) (assistant := false) : Term :=
  if !calls.isEmpty || assistant then
    .tuple ([a "assistant", text, list calls] ++ if metadata == empty then [] else [metadata])
  else if metadata == empty then .tuple [a "final", text]
  else .tuple [a "final", text, metadata, empty]

end VerifiedKernel.Provider
