import VerifiedKernel.Term

namespace VerifiedKernel.ETF

/-! The decoder reads in direct style: each step returns the term and the
next offset. Containers read their items with a loop on the item count,
without a generic range loop or a parser monad on each byte. -/

/-- `count` big-endian bytes at `offset`, or `"truncated"`. -/
private def numberAt (bytes : ByteArray) (offset count : Nat) : Except String Nat :=
  if count > bytes.size - offset || offset > bytes.size then .error "truncated"
  else .ok <| match count with
    | 1 => bytes[offset]!.toNat
    | 2 => bytes[offset]!.toNat * 256 + bytes[offset + 1]!.toNat
    | 4 =>
      ((bytes[offset]!.toNat * 256 + bytes[offset + 1]!.toNat) * 256 +
        bytes[offset + 2]!.toNat) * 256 + bytes[offset + 3]!.toNat
    | _ => (List.range count).foldl (fun value index => value * 256 + bytes[offset + index]!.toNat) 0

/-- `count` bytes at `offset`, or `"truncated"`. -/
private def takeAt (bytes : ByteArray) (offset count : Nat) : Except String ByteArray :=
  if count > bytes.size - offset || offset > bytes.size then .error "truncated"
  else .ok (bytes.extract offset (offset + count))

mutual
  private def parseAt (bytes : ByteArray) : Nat → Nat → Except String (Term × Nat)
    | 0, _ => .error "depth_limit"
    | depth + 1, pos => do
      let tag ← numberAt bytes pos 1
      let pos := pos + 1
      match tag with
      | 97 => return (.integer (Int.ofNat (← numberAt bytes pos 1)), pos + 1)
      | 98 =>
        let n ← numberAt bytes pos 4
        return (.integer (if n < 2147483648 then Int.ofNat n else Int.ofNat n - 4294967296), pos + 4)
      | 70 =>
        let bits ← numberAt bytes pos 8
        if bits / 2^52 % 2048 == 2047 then throw "invalid_float"
        return (.floatBits (UInt64.ofNat bits), pos + 8)
      | 110 | 111 =>
        let width := if tag == 110 then 1 else 4
        let count ← numberAt bytes pos width
        let sign ← numberAt bytes (pos + width) 1
        if sign > 1 then throw "invalid_integer"
        let digits ← takeAt bytes (pos + width + 1) count
        let n := digits.toList.reverse.foldl (fun acc byte => acc * 256 + byte.toNat) 0
        return (.integer (if sign == 0 then Int.ofNat n else -Int.ofNat n), pos + width + 1 + count)
      | 119 | 118 | 100 | 115 =>
        let width := if tag == 119 || tag == 115 then 1 else 2
        let count ← numberAt bytes pos width
        let raw ← takeAt bytes (pos + width) count
        let name ← if tag == 100 || tag == 115 then
          pure (String.ofList (raw.toList.map (fun b => Char.ofNat b.toNat)))
          else match String.fromUTF8? raw with
            | some s => pure s
            | none => throw "invalid_atom"
        if name.length > 255 then throw "invalid_atom"
        return (.atom name, pos + width + count)
      | 109 =>
        let count ← numberAt bytes pos 4
        return (.binary (← takeAt bytes (pos + 4) count), pos + 4 + count)
      | 77 =>
        let count ← numberAt bytes pos 4
        let lastBits ← numberAt bytes (pos + 4) 1
        if count == 0 || lastBits == 0 || lastBits > 8 then throw "invalid_bitstring"
        let raw ← takeAt bytes (pos + 5) count
        let next := pos + 5 + count
        if lastBits == 8 then return (.binary raw, next)
        if raw[count - 1]!.toNat % 2^(8 - lastBits) != 0 then throw "invalid_bitstring"
        return (.bitstring raw (UInt8.ofNat lastBits), next)
      | 106 => return (.list [], pos)
      | 107 =>
        let count ← numberAt bytes pos 2
        let raw ← takeAt bytes (pos + 2) count
        return (.list (raw.toList.map (fun b => .integer (Int.ofNat b.toNat))), pos + 2 + count)
      | 104 | 105 | 108 | 116 =>
        let width := if tag == 104 then 1 else 4
        let count ← numberAt bytes pos width
        let pos := pos + width
        if (if tag == 116 then count * 2 else count) > bytes.size - pos then throw "truncated"
        if tag == 116 then
          let (entries, pos) ← parseEntries bytes depth count [] pos
          -- OTP 29 writes hash-map entries in the reverse of its native iterator.
          -- Flat maps (at most 32 entries) use the iterator order on the wire.
          return (.map (if count > 32 then entries else entries.reverse), pos)
        let (values, pos) ← parseItems bytes depth count [] pos
        if tag == 108 then
          let (tail, pos) ← parseAt bytes depth pos
          match tail with
          | .list rest => return (.list (values.reverse ++ rest), pos)
          | .improper rest ending => return (.improper (values.reverse ++ rest) ending, pos)
          | _ =>
            if values.isEmpty then return (tail, pos)
            return (.improper values.reverse tail, pos)
        return (.tuple values.reverse, pos)
      | _ => throw "unsupported_tag"
  termination_by depth _ => (depth, 0)

  /-- `count` items in reverse order. -/
  private def parseItems (bytes : ByteArray) (depth : Nat) : Nat → List Term → Nat → Except String (List Term × Nat)
    | 0, acc, pos => .ok (acc, pos)
    | count + 1, acc, pos => do
      let (item, pos) ← parseAt bytes depth pos
      parseItems bytes depth count (item :: acc) pos
  termination_by count => (depth, count + 1)

  /-- `count` map entries in reverse order. -/
  private def parseEntries (bytes : ByteArray) (depth : Nat) : Nat → List (Term × Term) → Nat → Except String (List (Term × Term) × Nat)
    | 0, acc, pos => .ok (acc, pos)
    | count + 1, acc, pos => do
      let (key, pos) ← parseAt bytes depth pos
      let (value, pos) ← parseAt bytes depth pos
      parseEntries bytes depth count ((key, value) :: acc) pos
  termination_by count => (depth, count + 1)
end

def decode (bytes : ByteArray) : Except String Term := do
  if (← numberAt bytes 0 1) != 131 then throw "invalid_version"
  let (term, offset) ← parseAt bytes 64 1
  if offset != bytes.size then throw "trailing_bytes"
  return term

def be (n width : Nat) : ByteArray :=
  ⟨(List.range width).toArray.map (fun i => UInt8.ofNat (n / 256^(width - i - 1) % 256))⟩

def integer (value : Int) : ByteArray := Id.run do
  if 0 ≤ value && value < 256 then return ⟨#[97, UInt8.ofNat value.toNat]⟩
  if -2147483648 ≤ value && value < 2147483648 then
    return ⟨#[98]⟩ ++ be (value % 4294967296).toNat 4
  let count := (value.natAbs.log2 / 8) + 1
  let digits := (be value.natAbs count).toList.reverse.toByteArray
  let header := if count < 256 then ⟨#[110, UInt8.ofNat count]⟩ else ⟨#[111]⟩ ++ be count 4
  return (header.push (if value < 0 then 1 else 0)) ++ digits

/-- Pushes `width` big-endian bytes of `value`. -/
private def pushBE (acc : ByteArray) (value : Nat) : Nat → ByteArray
  | 0 => acc
  | width + 1 => pushBE (acc.push (UInt8.ofNat ((value >>> (8 * width)) % 256))) value width

/-- Pushes `count` little-endian bytes of `value`. -/
private def pushLE (acc : ByteArray) (value : Nat) : Nat → ByteArray
  | 0 => acc
  | remaining + 1 => pushLE (acc.push (UInt8.ofNat (value % 256))) (value / 256) remaining

/-- Pushes a length or count of at most four bytes, big-endian. -/
@[inline] private def push4 (acc : ByteArray) (value : Nat) : ByteArray :=
  let v := UInt32.ofNat value
  (((acc.push (v >>> 24).toUInt8).push (v >>> 16).toUInt8).push (v >>> 8).toUInt8).push v.toUInt8

/-- Pushes `count` little-endian bytes of a magnitude below `2^64` in machine words. -/
private def pushLE64 (acc : ByteArray) (value : UInt64) : Nat → ByteArray
  | 0 => acc
  | remaining + 1 => pushLE64 (acc.push value.toUInt8) (value >>> 8) remaining

/-- Pushes the encoding `integer value` produces. -/
private def pushInteger (acc : ByteArray) (value : Int) : ByteArray :=
  if 0 ≤ value && value < 256 then (acc.push 97).push (UInt8.ofNat value.toNat)
  -- Literal bounds: `2^31` would compute a big-number power on every call.
  else if -2147483648 ≤ value && value < 2147483648 then
    push4 (acc.push 98) (if value < 0 then (value + 4294967296).toNat else value.toNat)
  else
    let magnitude := value.natAbs
    let count := magnitude.log2 / 8 + 1
    let acc := if count < 256 then (acc.push 110).push (UInt8.ofNat count) else pushBE (acc.push 111) count 4
    let acc := acc.push (if value < 0 then 1 else 0)
    -- Millisecond timestamps land here: word arithmetic, not `Nat` division.
    if magnitude < 18446744073709551616 then pushLE64 acc (UInt64.ofNat magnitude) count
    else pushLE acc magnitude count

/-- Appends the UTF-8 bytes of `s` from byte `index` up to `size`, its byte
length, without first copying them into a separate array. -/
private def pushUTF8 (acc : ByteArray) (s : @& String) (size index : USize) : ByteArray :=
  if h : index < size then
    if hs : index.toNat < s.utf8ByteSize then
      pushUTF8 (acc.push (String.Internal.ugetUTF8Byte s index hs)) s size (index + 1)
    else acc
  else acc
termination_by size.toNat - index.toNat
decreasing_by
  have _ := USize.lt_iff_toNat_lt.mp h
  have _ := USize.toNat_lt_two_pow_numBits size
  rw [USize.toNat_add, USize.toNat_one]
  rw [Nat.mod_eq_of_lt (show _ < 2 ^ System.Platform.numBits by omega)]
  omega

mutual
  /-- The number of bytes that `encodeInto` appends for `term`, or `0` when
  `term` nests deeper than `fuel`, where `encodeInto` fails. Every encoding
  takes at least two bytes, so `0` is free for the failure. -/
  private def encodedSize (fuel : Nat) (term : @& Term) : Nat :=
    match fuel with
    | 0 => 0
    | depth + 1 =>
      match term with
      | .integer n =>
        if 0 ≤ n && n < 256 then 2
        else if -2147483648 ≤ n && n < 2147483648 then 5
        else
          let count := n.natAbs.log2 / 8 + 1
          (if count < 256 then 2 else 5) + 1 + count
      | .floatBits _ => 9
      | .atom s => (if s.utf8ByteSize < 256 then 2 else 3) + s.utf8ByteSize
      | .binary bytes => 5 + bytes.size
      | .tuple values =>
        let size := sizes depth values 1
        if size == 0 then 0 else (if values.length < 256 then 2 else 5) + size - 1
      | .list values => let size := sizes depth values 1; if size == 0 then 0 else 5 + size
      | .map entries => let size := entrySizes depth entries 1; if size == 0 then 0 else 4 + size
      | .improper values tail =>
        let size := sizes depth values 1
        let last := encodedSize depth tail
        if size == 0 || last == 0 then 0 else 4 + size + last
      | .bitstring bytes _ => 6 + bytes.size

  /-- `acc` plus the sizes of `values`, from an `acc` of at least one; `0`
  when one of them is too deep. -/
  private def sizes (depth : Nat) (values : @& List Term) (acc : Nat) : Nat :=
    match values with
    | [] => acc
    | value :: rest =>
      let size := encodedSize depth value
      if size == 0 then 0 else sizes depth rest (acc + size)

  private def entrySizes (depth : Nat) (entries : @& List (Term × Term)) (acc : Nat) : Nat :=
    match entries with
    | [] => acc
    | (key, value) :: rest =>
      let keySize := encodedSize depth key
      let valueSize := encodedSize depth value
      if keySize == 0 || valueSize == 0 then 0 else entrySizes depth rest (acc + keySize + valueSize)
end

/-- Appends the encoding of `term` to `acc`. `encode` checks the depth first,
so this walk cannot fail. The accumulator is owned, so every push extends one
buffer in place instead of copying each subterm once per nesting level. The
input is borrowed: encoding never changes the resident snapshot, so traversal
does not need atomic reference-count updates per term. -/
private def encodeInto (fuel : Nat) (acc : ByteArray) (term : @& Term) : ByteArray :=
  match fuel with
  | 0 => acc
  | depth + 1 =>
    match term with
    | .integer n => pushInteger acc n
    | .floatBits bits => pushBE (acc.push 70) bits.toNat 8
    | .atom s =>
      -- The same framing `term_to_binary` chooses: small atoms and small
      -- tuples take the one-byte length, so byte-level tooling that reads
      -- either form sees the familiar one.
      let size := s.utf8ByteSize
      let acc := if size < 256 then (acc.push 119).push (UInt8.ofNat size)
        else pushBE (acc.push 118) size 2
      pushUTF8 acc s size.toUSize 0
    | .binary bytes => push4 (acc.push 109) bytes.size ++ bytes
    | .tuple values =>
      let count := values.length
      let header := if count < 256 then (acc.push 104).push (UInt8.ofNat count)
        else push4 (acc.push 105) count
      values.foldl (encodeInto depth) header
    | .list values => (values.foldl (encodeInto depth) (push4 (acc.push 108) values.length)).push 106
    | .map entries =>
      entries.foldl (fun acc (key, value) => encodeInto depth (encodeInto depth acc key) value)
        (push4 (acc.push 116) entries.length)
    | .improper values tail =>
      encodeInto depth (values.foldl (encodeInto depth) (push4 (acc.push 108) values.length)) tail
    | .bitstring bytes lastBits => (push4 (acc.push 77) bytes.size).push lastBits ++ bytes

/-- One buffer of the final size: a snapshot of tens of megabytes otherwise
grows through a couple of dozen reallocations, each copying the bytes so far
into freshly faulted pages. A term nested deeper than the bound fails with
`depth_limit` before any byte is written. -/
def encode (term : Term) : Except String ByteArray :=
  match encodedSize 72 term with
  | 0 => .error "depth_limit"
  | size => .ok (encodeInto 72 ((ByteArray.emptyWithCapacity (1 + size)).push 131) term)

end VerifiedKernel.ETF
