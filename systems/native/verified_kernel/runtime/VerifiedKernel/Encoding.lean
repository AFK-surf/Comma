import VerifiedKernel.ETF
import VerifiedKernel.Order
import VerifiedKernel.ByteDigest

namespace VerifiedKernel.Data

private def deterministicBody : Nat → Term → KernelM ByteArray
  | 0, _ => fail "invalid_term_depth"
  | fuel + 1, term => do
    match term with
    | .integer n => return ETF.integer n
    | .floatBits bits => return ⟨#[70]⟩ ++ ETF.be bits.toNat 8
    | .atom name =>
      let bytes := name.toUTF8
      let header := if bytes.size < 256 then ⟨#[119, UInt8.ofNat bytes.size]⟩ else ⟨#[118]⟩ ++ ETF.be bytes.size 2
      return header ++ bytes
    | .binary bytes => return ⟨#[109]⟩ ++ ETF.be bytes.size 4 ++ bytes
    | .tuple xs =>
      let header := if xs.length < 256 then ⟨#[104, UInt8.ofNat xs.length]⟩ else ⟨#[105]⟩ ++ ETF.be xs.length 4
      xs.foldlM (fun bytes x => return bytes ++ (← deterministicBody fuel x)) header
    | .list [] => return ⟨#[106]⟩
    | .list xs =>
      if xs.length ≤ 65535 && xs.all (fun x => x.isInteger && 0 ≤ integerValue x && integerValue x ≤ 255) then
        return ⟨#[107]⟩ ++ ETF.be xs.length 2 ++ (xs.map (fun x => UInt8.ofNat (integerValue x).toNat)).toByteArray
      let bytes ← xs.foldlM (fun bytes x => return bytes ++ (← deterministicBody fuel x)) (⟨#[108]⟩ ++ ETF.be xs.length 4)
      return bytes.push 106
    | .improper xs tail =>
      let bytes ← xs.foldlM (fun bytes x => return bytes ++ (← deterministicBody fuel x)) (⟨#[108]⟩ ++ ETF.be xs.length 4)
      return bytes ++ (← deterministicBody fuel tail)
    | .map xs =>
      let keys ← sortedKeys (xs.map Prod.fst)
      keys.foldlM (fun bytes key => do
        let keyBytes ← deterministicBody fuel key
        let valueBytes ← deterministicBody fuel (term.get key)
        return bytes ++ keyBytes ++ valueBytes) (⟨#[116]⟩ ++ ETF.be xs.length 4)
    | .bitstring bytes lastBits => return ⟨#[77]⟩ ++ ETF.be bytes.size 4 ++ ⟨#[lastBits]⟩ ++ bytes

def deterministic (term : Term) : KernelM ByteArray := do
  return (ByteArray.mk #[131]) ++ (← deterministicBody (term.depth + 1) term)

def digest (bytes : ByteArray) : KernelM ByteArray :=
  pure (ByteDigest.sha256Bytes bytes)

def hex (bytes : ByteArray) : ByteArray :=
  (bytes.toList.flatMap (fun byte =>
    [byte.toNat / 16, byte.toNat % 16].map (fun n => UInt8.ofNat (if n < 10 then 48 + n else 87 + n)))).toByteArray

def fingerprint (term : Term) : KernelM Term := do
  return .binary (hex (← digest (← deterministic term)))

end VerifiedKernel.Data
