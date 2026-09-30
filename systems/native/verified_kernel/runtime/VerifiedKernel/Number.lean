import VerifiedKernel.Effect
import Init.Data.Float.Model.Float

namespace VerifiedKernel.Number

private def rounded (n d : Nat) : Nat :=
  let q := n / d
  let r := n % d
  if r * 2 > d || (r * 2 == d && q % 2 == 1) then q + 1 else q

private def trimZeros : Nat → Nat → Int → Nat × Int
  | 0, n, e => (n, e)
  | fuel + 1, n, e => if n > 0 && n % 10 == 0 then trimZeros fuel (n / 10) (e + 1) else (n, e)

/-- Search the IEEE-754 round-to-nearest interval at increasing decimal precision. -/
private def shortest (bits : UInt64) (n d : Nat) : Nat × Int := Id.run do
  let estimate := Int.ofNat (toString n).length - Int.ofNat (toString d).length
  let smaller := if estimate ≥ 0 then n < d * 10^estimate.toNat else n * 10^(-estimate).toNat < d
  let exponent := if smaller then estimate - 1 else estimate
  for precision in [1:18] do
    let scale := Int.ofNat precision - 1 - exponent
    let (numerator, denominator) := if scale ≥ 0 then (n * 10^scale.toNat, d) else (n, d * 10^(-scale).toNat)
    let coefficient := rounded numerator denominator
    if (Float.Model.ofScientific coefficient (-scale)).toBits == bits then
      return trimZeros 18 coefficient (-scale)
  let scale := 16 - exponent
  let (numerator, denominator) := if scale ≥ 0 then (n * 10^scale.toNat, d) else (n, d * 10^(-scale).toNat)
  return trimZeros 18 (rounded numerator denominator) (-scale)

def floatText (bits : UInt64) (inspectMode : Bool := false) : String := Id.run do
  let negative := bits.toNat / 2^63 != 0
  let magnitude := UInt64.ofNat (bits.toNat % 2^63)
  let sign := if negative then "-" else ""
  if magnitude == 0 then return sign ++ "0.0"
  let some (value, denominator) := (Term.floatBits magnitude).number | return "0.0"
  let (coefficient, exponent) := shortest magnitude value.toNat denominator
  let digits := (toString coefficient).toList
  let point := Int.ofNat digits.length + exponent
  let fixed := if point ≤ 0 then "0." ++ String.ofList (List.replicate (-point).toNat '0' ++ digits)
    else if point.toNat ≥ digits.length then String.ofList (digits ++ List.replicate (point.toNat - digits.length) '0') ++ ".0"
    else String.ofList (digits.take point.toNat) ++ "." ++ String.ofList (digits.drop point.toNat)
  let fraction := if digits.length == 1 then "0" else String.ofList digits.tail
  let scientific := String.ofList (digits.take 1) ++ "." ++ fraction ++ "e" ++ toString (point - 1)
  let useFixed := if inspectMode then point - 1 ≥ -4 && point - 1 < 16 else fixed.length ≤ scientific.length
  return sign ++ if useFixed then fixed else scientific

def asFloat : Term → Option Float.Model
  | .integer n => some (Float.Model.ofInt n)
  | .floatBits bits => some (Float.Model.ofBits bits)
  | _ => none

def calculate (subtract : Bool) (left right : Term) : KernelM Term := do
  match left, right with
  | .integer x, .integer y => return .integer (if subtract then x - y else x + y)
  | _, _ =>
    let some x := asFloat left | fail "badarith"
    let some y := asFloat right | fail "badarith"
    let result := if subtract then x.sub y else x.add y
    let bits := result.toBits
    if bits.toNat / 2^52 % 2048 == 2047 then fail "badarith"
    else pure (.floatBits bits)

end VerifiedKernel.Number
