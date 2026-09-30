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

private def escapeChar (char : Char) : String :=
  match char with
  | '"' => "\\\""
  | '\\' => "\\\\"
  | '\x08' => "\\b"
  | '\t' => "\\t"
  | '\n' => "\\n"
  | '\x0c' => "\\f"
  | '\r' => "\\r"
  -- Jason writes the escape with `~4.16.0B`, whose digits are uppercase.
  | c => if c.toNat < 32 then
      let digit := fun n => Char.ofNat (if n < 10 then n + 48 else n + 55)
      "\\u00" ++ String.ofList [digit (c.toNat / 16), digit (c.toNat % 16)]
    else String.singleton c

/-- True when some byte needs a JSON escape: a control character, a quote or
a backslash. Every other byte, including every byte of a multi-byte UTF-8
sequence, is written as is. -/
private def needsEscape (raw : ByteArray) : Bool :=
  (raw.findIdx? (fun byte => byte < 32 || byte == 34 || byte == 92)).isSome

def quote (raw : ByteArray) : Option ByteArray := do
  let text ← String.fromUTF8? raw
  if !needsEscape raw then return "\"".toUTF8 ++ raw ++ "\"".toUTF8
  return ("\"" ++ String.join (text.toList.map escapeChar) ++ "\"").toUTF8

private def joined (left right : String) (parts : List ByteArray) : ByteArray := Id.run do
  -- List.intersperse's foldr consumes native stack proportional to list width.
  -- NIF worker stacks are bounded: append separators in the iterative builder.
  let mut output := left.toUTF8
  let mut first := true
  for part in parts do
    if !first then output := output.push 44
    output := output ++ part
    first := false
  return output ++ right.toUTF8

private def encodeFuel : Nat → Term → KernelM (Option ByteArray)
  | 0, _ => fail "invalid_term_depth"
  | fuel + 1, value => do
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
        let some part ← encodeFuel fuel item | return none
        parts := part :: parts
      return some (joined "[" "]" parts.reverse)
    | .map xs =>
      if value.has (a "__struct__") then
        return none
      let mut parts := []
      for pair in xs do
        let key ← match pair.1 with | .atom name => pure (b name) | _ => stringChars pair.1
        let key := match key with | .binary raw => quote raw | _ => none
        let some key := key | return none
        let some item ← encodeFuel fuel pair.2 | return none
        parts := (key ++ ":".toUTF8 ++ item) :: parts
      return some (joined "{" "}" parts.reverse)
    | _ => return none

def encode (value : Term) : KernelM (Option ByteArray) := encodeFuel (value.depth + 1) value

end VerifiedKernel.Json
