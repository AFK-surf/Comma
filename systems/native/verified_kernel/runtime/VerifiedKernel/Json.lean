import VerifiedKernel.JsonSyntax
import VerifiedKernel.Data
import Init.Data.Float.Model.Float

namespace VerifiedKernel.Json
open Data

private def decimal (text : String) : Option Term := do
  if !text.toList.any (fun c => c == '.' || c == 'e' || c == 'E') then
    if text.utf8ByteSize > 1024 then none else return i (← text.toInt?)
  else
    let negative := text.startsWith "-"
    let unsigned := if negative then String.ofList text.toList.tail else text
    let parts := unsigned.splitOn "e" |>.flatMap (·.splitOn "E")
    let mantissa := parts.head!
    let exponentText := parts[1]?.getD "0"
    let exponent : Int ←
      if exponentText.startsWith "+" then (String.ofList exponentText.toList.tail).toInt?
      else exponentText.toInt?
    let pieces := mantissa.splitOn "."
    let digits := String.join pieces
    let places := if pieces.length == 2 then (pieces[1]!).length else 0
    let magnitude ← digits.toNat?
    let adjusted := exponent - Int.ofNat places + Int.ofNat (toString magnitude).length - 1
    if magnitude != 0 && adjusted > 309 then none
    else if magnitude == 0 || adjusted < -400 then
      return .floatBits (UInt64.ofNat (if negative then 2^63 else 0))
    else do
      let model := Float.Model.ofScientific magnitude (exponent - Int.ofNat places)
      let bits := model.toBits.toNat
      if bits / 2^52 % 2048 == 2047 then none
      else return .floatBits (UInt64.ofNat (bits + (if negative then 2^63 else 0)))

private def convert : Nat → JsonSyntax.Syntax → Option Term
  | 0, _ => none
  | fuel + 1, node => do
    match node with
    | .null => return nil
    | .boolean value => return Term.bool value
    | .string text => return b text
    | .number token => decimal token
    | .array xs => return .list (← xs.mapM (convert fuel))
    | .object xs =>
      let pairs ← xs.mapM (fun pair => return (b pair.1, ← convert fuel pair.2))
      return pairs.foldl (fun acc pair => if acc.has pair.1 then acc else acc.put pair.1 pair.2) empty

/-- Keep resource rejection distinct from malformed JSON for reference pruning. -/
def decodeResult (bytes : ByteArray) : Except JsonSyntax.ParseFailure Term := do
  let parsed ← JsonSyntax.parseSyntax bytes
  match convert 64 parsed with
  | some value => pure value
  | none => throw .syntax

def decode (bytes : ByteArray) : Option Term := (decodeResult bytes).toOption

/-- The `result_ref` references that `decodeResult` exposes: the non-empty
binaries under a `result_ref` key of any decoded object, in no fixed order.
It fails exactly when `decodeResult` fails, without building the value. -/
def resultRefs (bytes : ByteArray) : Except JsonSyntax.ParseFailure (List Term) := do
  let refs ← JsonSyntax.refs bytes (fun token => (decimal token).isSome)
  return refs.map .binary

private def hexDigit (n : UInt8) : UInt8 :=
  if n < 10 then n + 48 else n + 55

private def escapeByte (out : ByteArray) (byte : UInt8) : ByteArray :=
  if byte == 34 then (out.push 92).push 34
  else if byte == 92 then (out.push 92).push 92
  else if byte == 8 then (out.push 92).push 98
  else if byte == 9 then (out.push 92).push 116
  else if byte == 10 then (out.push 92).push 110
  else if byte == 12 then (out.push 92).push 102
  else if byte == 13 then (out.push 92).push 114
  else
    -- Jason writes the escape with `~4.16.0B`, whose digits are uppercase.
    (((((out.push 92).push 117).push 48).push 48).push (hexDigit (byte / 16))).push (hexDigit (byte % 16))

/-- Quote valid UTF-8 bytes as a JSON string in a single pass. Every byte
needing a JSON escape (`< 32`, `"` = 34, `\` = 92) is `< 0x80`, so multi-byte
UTF-8 sequences are copied verbatim. -/
def quote (raw : ByteArray) : Option ByteArray :=
  if !raw.validateUTF8 then none
  else some (Id.run do
    let size := raw.size
    match raw.findIdx? (fun byte => byte < 32 || byte == 34 || byte == 92) with
    | none =>
      let out := (ByteArray.emptyWithCapacity (size + 2)).push 34
      (raw.copySlice 0 out 1 size false).push 34
    | some first =>
      let mut out := (ByteArray.emptyWithCapacity (size + 16)).push 34
      if first > 0 then
        out := raw.copySlice 0 out out.size first false
      out := escapeByte out raw[first]!
      let mut chunkStart := first + 1
      let mut i := first + 1
      while i < size do
        let byte := raw[i]!
        if byte < 32 || byte == 34 || byte == 92 then
          if i > chunkStart then
            out := raw.copySlice chunkStart out out.size (i - chunkStart) false
          out := escapeByte out byte
          chunkStart := i + 1
        i := i + 1
      if size > chunkStart then
        out := raw.copySlice chunkStart out out.size (size - chunkStart) false
      return out.push 34)

private def joined (left right : UInt8) (parts : List ByteArray) : ByteArray := Id.run do
  -- List.intersperse's foldr consumes native stack proportional to list width.
  -- NIF worker stacks are bounded: pre-size and copy into one buffer iteratively.
  let mut total := 2
  let mut count := 0
  for part in parts do
    total := total + part.size
    count := count + 1
  if count > 1 then total := total + (count - 1)
  let mut output := (ByteArray.emptyWithCapacity total).push left
  let mut first := true
  for part in parts do
    if !first then output := output.push 44
    output := part.copySlice 0 output output.size part.size false
    first := false
  return output.push right

private def joinedObject (pairs : List (ByteArray × ByteArray)) : ByteArray := Id.run do
  let mut total := 2
  let mut count := 0
  for (key, item) in pairs do
    total := total + key.size + 1 + item.size
    count := count + 1
  if count > 1 then total := total + (count - 1)
  let mut output := (ByteArray.emptyWithCapacity total).push 123
  let mut first := true
  for (key, item) in pairs do
    if !first then output := output.push 44
    output := key.copySlice 0 output output.size key.size false
    output := output.push 58
    output := item.copySlice 0 output output.size item.size false
    first := false
  return output.push 125

private def encodeFuelDeferred : Nat → Term → KernelEval (Option ByteArray)
  | 0, _ => monadLift (fail "invalid_term_depth")
  | fuel + 1, value => KernelEval.defer fun _ => do
    match value with
    | .atom "nil" => return some "null".toUTF8
    | .atom "true" => return some "true".toUTF8
    | .atom "false" => return some "false".toUTF8
    | .atom name => return quote name.toUTF8
    | .integer n => return some (toString n).toUTF8
    | .floatBits bits => return some (Number.floatText bits).toUTF8
    | .binary raw => return quote raw
    | .list xs =>
      let mut parts := []
      for item in xs do
        let some part ← encodeFuelDeferred fuel item | return none
        parts := part :: parts
      return some (joined 91 93 parts.reverse)
    | .map xs =>
      if value.has (a "__struct__") then
        return none
      let mut pairs := []
      for pair in xs do
        let key ← match pair.1 with | .atom name => pure (b name) | _ => stringChars pair.1
        let key := match key with | .binary raw => quote raw | _ => none
        let some key := key | return none
        let some item ← encodeFuelDeferred fuel pair.2 | return none
        pairs := (key, item) :: pairs
      return some (joinedObject pairs.reverse)
    | _ => return none

private def encodeFuel (fuel : Nat) (value : Term) : KernelM (Option ByteArray) :=
  KernelEval.run (encodeFuelDeferred fuel value)

def encode (value : Term) : KernelM (Option ByteArray) := encodeFuel (value.depth + 1) value

end VerifiedKernel.Json
