import Init

namespace VerifiedKernel.JsonSyntax

/-- JSON grammar over UTF-8. Numeric conversion is separate. -/

inductive Syntax where
  | null
  | boolean (value : Bool)
  | string (value : String)
  | number (token : String)
  | array (items : List Syntax)
  | object (pairs : List (String × Syntax))
  deriving Repr

inductive ParseFailure where
  | syntax
  | resourceBound
  deriving Repr

def whitespace (c : Char) : Bool :=
  c == ' ' || c == '\t' || c == '\r' || c == '\n'

def ws (input : List Char) : List Char := input.dropWhile whitespace
def digit (c : Char) : Bool := '0' ≤ c && c ≤ '9'
def nonzero (c : Char) : Bool := '1' ≤ c && c ≤ '9'

def hex (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat)
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
  else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
  else none

def hex4 : List Char → Option (Nat × List Char)
  | a :: b :: c :: d :: rest => do
      let a ← hex a
      let b ← hex b
      let c ← hex c
      let d ← hex d
      some (4096 * a + 256 * b + 16 * c + d, rest)
  | _ => none

def escaped : List Char → Option (Char × List Char)
  | '"' :: rest => some ('"', rest)
  | '\\' :: rest => some ('\\', rest)
  | '/' :: rest => some ('/', rest)
  | 'b' :: rest => some ('\x08', rest)
  | 'f' :: rest => some ('\x0c', rest)
  | 'n' :: rest => some ('\n', rest)
  | 'r' :: rest => some ('\r', rest)
  | 't' :: rest => some ('\t', rest)
  | 'u' :: rest => do
      let (first, rest) ← hex4 rest
      if first < 0xD800 || first ≥ 0xE000 then
        some (Char.ofNat first, rest)
      else if first < 0xDC00 then
        let '\\' :: 'u' :: rest := rest | none
        let (second, rest) ← hex4 rest
        if 0xDC00 ≤ second && second < 0xE000 then
          some (Char.ofNat (0x10000 + (first - 0xD800) * 1024 + second - 0xDC00), rest)
        else none
      else none
  | _ => none

/-- Grammar-only scan. No floating-point or huge-integer conversion occurs. -/
def numberToken (original : List Char) : Option (String × List Char) := do
  let input := match original with | '-' :: rest => rest | _ => original
  let rest ← match input with
    | '0' :: rest => some rest
    | c :: rest => if nonzero c then some (rest.dropWhile digit) else none
    | [] => none
  let rest ← match rest with
    | '.' :: c :: tail => if digit c then some (tail.dropWhile digit) else none
    | '.' :: [] => none
    | rest => some rest
  let rest ← match rest with
    | exponent :: tail =>
        if exponent == 'e' || exponent == 'E' then
          let tail := match tail with | '+' :: rest | '-' :: rest => rest | _ => tail
          match tail with
          | c :: rest => if digit c then some (rest.dropWhile digit) else none
          | [] => none
        else some rest
    | [] => some []
  some (String.ofList (original.take (original.length - rest.length)), rest)

/-- Scan UTF-8 bytes without allocating one list cell per input character. -/
private def skipWhitespace (bytes : ByteArray) (pos : Nat) : Nat → Nat
  | 0 => pos
  | fuel + 1 =>
    if pos < bytes.size && (bytes[pos]! == 32 || bytes[pos]! == 9 || bytes[pos]! == 10 || bytes[pos]! == 13)
    then skipWhitespace bytes (pos + 1) fuel else pos

private def skipWs (bytes : ByteArray) (pos : Nat) : Nat := skipWhitespace bytes pos (bytes.size + 1)

private def textSlice (bytes : ByteArray) (start stop : Nat) : String :=
  String.fromUTF8! (bytes.extract start stop)

private def readString (bytes : ByteArray) (start pos : Nat) (acc : String) : Nat → Except ParseFailure (String × Nat)
  | 0 => .error .resourceBound
  | fuel + 1 => do
    let some pos := bytes.findIdx? (fun byte => byte < 32 || byte == 34 || byte == 92) pos
      | throw .syntax
    let byte := bytes[pos]!
    if byte == 34 then
      return (acc ++ textSlice bytes start pos, pos + 1)
    else if byte == 92 then
      -- JSON escapes contain at most twelve ASCII bytes, including a surrogate pair.
      let chars := (bytes.extract (pos + 1) (pos + 13)).toList.map (fun c => Char.ofNat c.toNat)
      let some (char, rest) := escaped chars | throw .syntax
      let next := pos + 1 + chars.length - rest.length
      readString bytes next next ((acc ++ textSlice bytes start pos).push char) fuel
    else throw .syntax

private def literal (bytes : ByteArray) (pos : Nat) (word : String) (node : Syntax) : Except ParseFailure (Syntax × Nat) :=
  if bytes.extract pos (pos + word.utf8ByteSize) == word.toUTF8
  then .ok (node, pos + word.utf8ByteSize) else .error .syntax

private def numberByte (c : UInt8) : Bool :=
  (c >= 48 && c <= 57) || c == 45 || c == 43 || c == 46 || c == 101 || c == 69

private def numberEnd (bytes : ByteArray) (pos : Nat) : Nat → Nat
  | 0 => pos
  | fuel + 1 =>
    if pos < bytes.size && numberByte bytes[pos]! then numberEnd bytes (pos + 1) fuel else pos

mutual
  def value (bytes : ByteArray) (depth : Nat) : Nat → Nat → Except ParseFailure (Syntax × Nat)
    | 0, _ => .error .resourceBound
    | fuel + 1, original => do
      if depth == 0 then throw .resourceBound
      let pos := skipWs bytes original
      if pos >= bytes.size then throw .syntax
      match bytes[pos]!.toNat with
      | 110 => literal bytes pos "null" .null
      | 116 => literal bytes pos "true" (.boolean true)
      | 102 => literal bytes pos "false" (.boolean false)
      | 34 => do
        let (text, next) ← readString bytes (pos + 1) (pos + 1) "" (bytes.size + 1)
        return (.string text, next)
      | 91 => do
        let next := skipWs bytes (pos + 1)
        if next < bytes.size && bytes[next]! == 93 then return (.array [], next + 1)
        let (items, next) ← arrayItems bytes (depth - 1) [] fuel next
        return (.array items, next)
      | 123 => do
        let next := skipWs bytes (pos + 1)
        if next < bytes.size && bytes[next]! == 125 then return (.object [], next + 1)
        let (items, next) ← objectItems bytes (depth - 1) [] fuel next
        return (.object items, next)
      | _ => do
        let stop := numberEnd bytes pos (bytes.size + 1)
        let text := textSlice bytes pos stop
        let some (token, []) := numberToken text.toList | throw .syntax
        return (.number token, stop)

  /-- Container items accumulate in reverse and finish with one reversal, so
  the native stack grows with nesting depth only, never with the number of
  items in one array or object. This parser runs on a BEAM dirty scheduler
  whose stack is a few hundred kilobytes; a tool result or provider body
  with tens of thousands of items must not take one frame per item. -/
  def arrayItems (bytes : ByteArray) (depth : Nat) (acc : List Syntax) : Nat → Nat → Except ParseFailure (List Syntax × Nat)
    | 0, _ => .error .resourceBound
    | fuel + 1, pos => do
      let (head, next) ← value bytes depth fuel pos
      let next := skipWs bytes next
      if next >= bytes.size then throw .syntax
      if bytes[next]! == 93 then return ((head :: acc).reverse, next + 1)
      if bytes[next]! != 44 then throw .syntax
      arrayItems bytes depth (head :: acc) fuel (next + 1)

  def objectItems (bytes : ByteArray) (depth : Nat) (acc : List (String × Syntax)) : Nat → Nat → Except ParseFailure (List (String × Syntax) × Nat)
    | 0, _ => .error .resourceBound
    | fuel + 1, original => do
      let pos := skipWs bytes original
      if pos >= bytes.size || bytes[pos]! != 34 then throw .syntax
      let (key, next) ← readString bytes (pos + 1) (pos + 1) "" (bytes.size + 1)
      let next := skipWs bytes next
      if next >= bytes.size || bytes[next]! != 58 then throw .syntax
      let (item, next) ← value bytes depth fuel (next + 1)
      let next := skipWs bytes next
      if next >= bytes.size then throw .syntax
      if bytes[next]! == 125 then return (((key, item) :: acc).reverse, next + 1)
      if bytes[next]! != 44 then throw .syntax
      objectItems bytes depth ((key, item) :: acc) fuel (next + 1)
end

private def stringRunNat (bytes : ByteArray) (pos : Nat) : Option Nat :=
  if h : pos < bytes.size then
    let byte := bytes[pos]
    if byte < 128 then
      if byte < 32 || byte == 34 || byte == 92 then some pos
      else stringRunNat bytes (pos + 1)
    else match bytes.utf8DecodeChar? pos with
      | some char =>
        have := char.utf8Size_pos
        stringRunNat bytes (pos + char.utf8Size)
      | none => none
  else none
termination_by bytes.size - pos

/-- `stringRunNat` with machine-word indices, for an array whose size a word holds. -/
private def stringRunWord (bytes : ByteArray) (size : USize) (hs : size.toNat = bytes.size) (pos : USize) : Option USize :=
  if h : pos < size then
    have hp : pos.toNat < bytes.size := hs ▸ (USize.lt_iff_toNat_lt.mp h)
    let byte := bytes.uget pos hp
    if byte < 128 then
      if byte < 32 || byte == 34 || byte == 92 then some pos
      else stringRunWord bytes size hs (pos + 1)
    else match bytes.utf8DecodeChar? pos.toNat with
      | some char =>
        -- The decoder only accepts a character whose bytes all lie in the array.
        if pos.toNat + char.utf8Size ≤ bytes.size then
          stringRunWord bytes size hs (pos + USize.ofNat char.utf8Size)
        else none
      | none => none
  else none
termination_by size.toNat - pos.toNat
decreasing_by
  · have _ := USize.lt_iff_toNat_lt.mp h
    have _ := USize.toNat_lt_two_pow_numBits size
    rw [USize.toNat_add, USize.toNat_one]
    rw [Nat.mod_eq_of_lt (show _ < 2 ^ System.Platform.numBits by omega)]
    omega
  · have _ := USize.lt_iff_toNat_lt.mp h
    have _ := USize.toNat_lt_two_pow_numBits size
    have _ := char.utf8Size_pos
    have _ : char.utf8Size ≤ 4 := char.utf8Size_le_four
    rw [USize.toNat_add, USize.toNat_ofNat_of_lt' (show _ < 2 ^ System.Platform.numBits by omega)]
    rw [Nat.mod_eq_of_lt (show _ < 2 ^ System.Platform.numBits by omega)]
    omega

/-- `1` at each byte a JSON string body holds as itself: printable ASCII other
than a quote or a backslash. -/
private def plainBytes : ByteArray :=
  ⟨(Array.range 256).map (fun b => if 32 ≤ b && b < 128 && b != 34 && b != 92 then 1 else 0)⟩

private theorem plainBytes_size : plainBytes.size = 256 := by
  simp [plainBytes, ByteArray.size]

@[inline] private def plainAt (bytes : ByteArray) (pos : USize) (h : pos.toNat < bytes.size) : UInt8 :=
  plainBytes.uget (bytes.uget pos h).toUSize (by
    rw [plainBytes_size]
    have := (bytes.uget pos h).toNat_lt
    simp only [UInt8.toNat_toUSize]
    omega)

private theorem plainIndex {bytes : ByteArray} {size pos : USize} (hs : size.toNat = bytes.size)
    (h : pos.toNat + 8 ≤ size.toNat) (k : Nat) (hk : k < 8) :
    (pos + USize.ofNat k).toNat < bytes.size := by
  have := USize.toNat_lt_two_pow_numBits size
  rw [USize.toNat_add, USize.toNat_ofNat_of_lt' (show k < 2 ^ System.Platform.numBits by omega)]
  rw [Nat.mod_eq_of_lt (show _ < 2 ^ System.Platform.numBits by omega)]
  omega

/-- The first position at or after `pos` that does not start eight plain bytes:
most of a long string body passes here a word at a time, and `stringRunWord`
checks the rest byte by byte. -/
private def plainRun (bytes : ByteArray) (size : USize) (hs : size.toNat = bytes.size) (pos : USize) : USize :=
  if h : pos.toNat + 8 ≤ size.toNat then
    let count := plainAt bytes (pos + USize.ofNat 0) (plainIndex hs h 0 (by omega)) +
      plainAt bytes (pos + USize.ofNat 1) (plainIndex hs h 1 (by omega)) +
      plainAt bytes (pos + USize.ofNat 2) (plainIndex hs h 2 (by omega)) +
      plainAt bytes (pos + USize.ofNat 3) (plainIndex hs h 3 (by omega)) +
      plainAt bytes (pos + USize.ofNat 4) (plainIndex hs h 4 (by omega)) +
      plainAt bytes (pos + USize.ofNat 5) (plainIndex hs h 5 (by omega)) +
      plainAt bytes (pos + USize.ofNat 6) (plainIndex hs h 6 (by omega)) +
      plainAt bytes (pos + USize.ofNat 7) (plainIndex hs h 7 (by omega))
    if count == 8 then plainRun bytes size hs (pos + USize.ofNat 8) else pos
  else pos
termination_by size.toNat - pos.toNat
decreasing_by
  have _ := USize.toNat_lt_two_pow_numBits size
  rw [USize.toNat_add, USize.toNat_ofNat_of_lt' (show 8 < 2 ^ System.Platform.numBits by omega)]
  rw [Nat.mod_eq_of_lt (show _ < 2 ^ System.Platform.numBits by omega)]
  omega

/-- The index of the first control byte, quote or backslash at or after `pos`,
checking that every byte before it belongs to a valid UTF-8 character with the
decoder of `ByteArray.validateUTF8`. `none` for an invalid character or when
no such byte follows. This loop reads most of a JSON text, so it indexes with
machine words when the array allows. -/
private def stringRun (bytes : ByteArray) (pos : Nat) : Option Nat :=
  if h : bytes.size < USize.size then
    if pos < bytes.size then
      let size := USize.ofNat bytes.size
      let hs := USize.toNat_ofNat_of_lt' h
      (stringRunWord bytes size hs (plainRun bytes size hs (USize.ofNat pos))).map USize.toNat
    else none
  else stringRunNat bytes pos

/-- `readString` without the decoded text: the same end position and failures,
and it also checks the UTF-8 of the text it passes. -/
private def skipString (bytes : ByteArray) (pos : Nat) : Nat → Except ParseFailure Nat
  | 0 => .error .resourceBound
  | fuel + 1 => do
    let some pos := stringRun bytes pos
      | throw .syntax
    let byte := bytes[pos]!
    if byte == 34 then return pos + 1
    else if byte == 92 then
      let chars := (bytes.extract (pos + 1) (pos + 13)).toList.map (fun c => Char.ofNat c.toNat)
      let some (_, rest) := escaped chars | throw .syntax
      let next := pos + 1 + chars.length - rest.length
      skipString bytes next fuel
    else throw .syntax

/-- The decoded UTF-8 bytes of the string whose body starts at `pos`, and the
position after it. `skipString` checks the body; a body without an escape is
its own decoding, so only a body with one is decoded by `readString`. -/
private def readBytes (bytes : ByteArray) (pos : Nat) : Except ParseFailure (ByteArray × Nat) := do
  let next ← skipString bytes pos (bytes.size + 1)
  let body := bytes.extract pos (next - 1)
  if (body.findIdx? (· == 92)).isSome then
    let (text, next) ← readString bytes pos pos "" (bytes.size + 1)
    return (text.toUTF8, next)
  return (body, next)

private def resultRefKey : ByteArray := "result_ref".toUTF8

/-- What `refs` keeps of one value: the `result_ref` values that the value's
first-key-wins conversion holds, the value's text when it is a string that the
caller asked for, and whether a number token did not convert. -/
structure RefScan where
  refs : List ByteArray := []
  text : Option ByteArray := none
  invalidNumber : Bool := false

/- The walk of `value`, `arrayItems` and `objectItems` with the same fuel,
depth bound and failures, keeping only what `RefScan` names. Only object keys
and the strings under a `result_ref` key are decoded. -/
mutual
  def scanValue (bytes : ByteArray) (number : String → Bool) (keep : Bool) (depth : Nat) :
      Nat → Nat → Except ParseFailure (RefScan × Nat)
    | 0, _ => .error .resourceBound
    | fuel + 1, original => do
      if depth == 0 then throw .resourceBound
      let pos := skipWs bytes original
      if pos >= bytes.size then throw .syntax
      match bytes[pos]!.toNat with
      | 110 => return ({}, (← literal bytes pos "null" .null).2)
      | 116 => return ({}, (← literal bytes pos "true" (.boolean true)).2)
      | 102 => return ({}, (← literal bytes pos "false" (.boolean false)).2)
      | 34 =>
        if keep then do
          let (text, next) ← readBytes bytes (pos + 1)
          return ({ text := some text }, next)
        else return ({}, ← skipString bytes (pos + 1) (bytes.size + 1))
      | 91 => do
        let next := skipWs bytes (pos + 1)
        if next < bytes.size && bytes[next]! == 93 then return ({}, next + 1)
        scanArray bytes number (depth - 1) {} fuel next
      | 123 => do
        let next := skipWs bytes (pos + 1)
        if next < bytes.size && bytes[next]! == 125 then return ({}, next + 1)
        scanObject bytes number (depth - 1) [] {} fuel next
      | _ => do
        let stop := numberEnd bytes pos (bytes.size + 1)
        let text := textSlice bytes pos stop
        let some (token, []) := numberToken text.toList | throw .syntax
        return ({ invalidNumber := !number token }, stop)
  termination_by structural fuel _ => fuel

  def scanArray (bytes : ByteArray) (number : String → Bool) (depth : Nat) (acc : RefScan) :
      Nat → Nat → Except ParseFailure (RefScan × Nat)
    | 0, _ => .error .resourceBound
    | fuel + 1, pos => do
      let (head, next) ← scanValue bytes number false depth fuel pos
      let acc := { acc with refs := head.refs ++ acc.refs, invalidNumber := acc.invalidNumber || head.invalidNumber }
      let next := skipWs bytes next
      if next >= bytes.size then throw .syntax
      if bytes[next]! == 93 then return (acc, next + 1)
      if bytes[next]! != 44 then throw .syntax
      scanArray bytes number depth acc fuel (next + 1)
  termination_by structural fuel _ => fuel

  /-- `seen` holds the keys read so far: a repeated key's value is checked but
  holds nothing, as the conversion keeps the first value of each key. -/
  def scanObject (bytes : ByteArray) (number : String → Bool) (depth : Nat) (seen : List ByteArray) (acc : RefScan) :
      Nat → Nat → Except ParseFailure (RefScan × Nat)
    | 0, _ => .error .resourceBound
    | fuel + 1, original => do
      let pos := skipWs bytes original
      if pos >= bytes.size || bytes[pos]! != 34 then throw .syntax
      let (key, next) ← readBytes bytes (pos + 1)
      let next := skipWs bytes next
      if next >= bytes.size || bytes[next]! != 58 then throw .syntax
      let first := !seen.contains key
      let direct := first && key == resultRefKey
      let (item, next) ← scanValue bytes number direct depth fuel (next + 1)
      let found := match item.text with
        | some text => if direct && !text.isEmpty then [text] else []
        | none => []
      let acc := { acc with
        refs := if first then found ++ item.refs ++ acc.refs else acc.refs,
        invalidNumber := acc.invalidNumber || item.invalidNumber }
      let next := skipWs bytes next
      if next >= bytes.size then throw .syntax
      if bytes[next]! == 125 then return (acc, next + 1)
      if bytes[next]! != 44 then throw .syntax
      scanObject bytes number depth (key :: seen) acc fuel (next + 1)
  termination_by structural fuel _ => fuel
end

/-- The non-empty `result_ref` strings of `parseSyntax bytes`, converted with
the first value of each object key, in no fixed order. `number` decides
whether a number token converts; a token that does not fails the text like
`.syntax` after the whole text parses.

The scan checks UTF-8 inside strings only: outside them the grammar accepts
ASCII alone, so a text that scans is valid UTF-8. A scan that stops at a
resource bound checks the whole text, because `parseSyntax` rejects invalid
UTF-8 as `.syntax` before it parses. -/
def refs (bytes : ByteArray) (number : String → Bool) : Except ParseFailure (List ByteArray) := do
  let (scan, next) ← match scanValue bytes number false 64 (2 * bytes.size + 1) 0 with
    | .ok result => pure result
    | .error .resourceBound => throw (if bytes.validateUTF8 then .resourceBound else .syntax)
    | .error .syntax => throw .syntax
  if skipWs bytes next != bytes.size then throw .syntax
  if scan.invalidNumber then throw .syntax
  return scan.refs

def parseSyntax (bytes : ByteArray) : Except ParseFailure Syntax := do
  -- Validation alone: building the string would copy and count the text.
  if !bytes.validateUTF8 then throw .syntax
  let (parsed, next) ← value bytes 64 (2 * bytes.size + 1) 0
  if skipWs bytes next == bytes.size then return parsed else throw .syntax

end VerifiedKernel.JsonSyntax
