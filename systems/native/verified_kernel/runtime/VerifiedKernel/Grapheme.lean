import VerifiedKernel.GraphemeData

namespace VerifiedKernel.Grapheme

/-!
Executable grapheme counting for decoded Unicode scalar values, following
OTP 29.0.2 stdlib unicode_util.gc/1, Unicode 17.0. Input decoding and rejection
of invalid UTF-8 belong to the caller. This is not Lean String.length.

The scanner represents the native continuation modes: CR/control, prepend,
Hangul, regional pairs, extend, extended pictographic ZWJ, and Indic linker
chains. In particular it follows OTP's combined is_extend table for spacing
marks and Indic extension, rather than substituting a different Unicode
library's segmentation version. No caller-supplied counts or boundaries occur.

GraphemeData contains the complete pinned property ranges. This executable
model does not assert a proof of the OTP library or its Unicode conformance.
-/

private def search (ranges : Array (Nat × Nat)) : Nat → Nat → Nat → Nat → Bool
  | 0, _, _, _ => false
  | fuel + 1, low, high, codepoint =>
      if low ≥ high then false else
        let middle := low + (high - low) / 2
        let interval := ranges[middle]?.getD (0, 0)
        if codepoint < interval.1 then search ranges fuel low middle codepoint
        else if interval.2 < codepoint then search ranges fuel (middle + 1) high codepoint
        else true

private def searchRanges (ranges : Array (Nat × Nat)) (codepoint : Nat) : Bool :=
  search ranges ranges.size 0 ranges.size codepoint

/-- Property membership for every scalar below 256, computed once from the
range search itself, so the fast path is the same function by construction. -/
private def smallTable (ranges : Array (Nat × Nat)) : Array Bool :=
  (Array.range 256).map (searchRanges ranges)

private def controlSmall : Array Bool := smallTable Data.control
private def prependSmall : Array Bool := smallTable Data.prepend
private def extendSmall : Array Bool := smallTable Data.extend
private def pictographicSmall : Array Bool := smallTable Data.pictographic
private def consonantSmall : Array Bool := smallTable Data.consonant
private def linkerSmall : Array Bool := smallTable Data.linker

private def lookup (small : Array Bool) (ranges : Array (Nat × Nat)) (codepoint : Nat) : Bool :=
  if codepoint < 256 then small[codepoint]! else searchRanges ranges codepoint

private def isControl (c : Nat) : Bool := lookup controlSmall Data.control c
private def isPrepend (c : Nat) : Bool := lookup prependSmall Data.prepend c
private def isExtend (c : Nat) : Bool := lookup extendSmall Data.extend c
private def isPictographic (c : Nat) : Bool := lookup pictographicSmall Data.pictographic c
private def isConsonant (c : Nat) : Bool := lookup consonantSmall Data.consonant c
private def isLinker (c : Nat) : Bool := lookup linkerSmall Data.linker c

private def hangulL (c : Nat) : Bool :=
  (4352 ≤ c && c ≤ 4447) || (43360 ≤ c && c ≤ 43388)

private def hangulV (c : Nat) : Bool :=
  c == 93539 || (4448 ≤ c && c ≤ 4519) ||
    (55216 ≤ c && c ≤ 55238) || (93543 ≤ c && c ≤ 93546)

private def hangulT (c : Nat) : Bool :=
  (4520 ≤ c && c ≤ 4607) || (55243 ≤ c && c ≤ 55291)

private def hangulSyllable (c : Nat) : Bool := 44032 ≤ c && c ≤ 55203

private def regional (c : Nat) : Bool := 127462 ≤ c && c ≤ 127487

private inductive Mode where
  | closed
  | carriageReturn
  | prepend
  | extend
  | hangulL
  | hangulV
  | hangulT
  | regional
  | pictographic
  | pictographicZwj
  | indic (linked : Bool)

private def initialMode (c : Nat) : Mode :=
  if c == 13 then .carriageReturn
  else if isControl c then .closed
  else if isPrepend c then .prepend
  else if hangulL c then .hangulL
  else if hangulV c then .hangulV
  else if hangulT c then .hangulT
  else if 44000 ≤ c && c ≤ 56000 then
    if hangulSyllable c then
      if (c - 44032) % 28 == 0 then .hangulV else .hangulT
    else .extend
  else if regional c then .regional
  else if isPictographic c then .pictographic
  else if isConsonant c then .indic false
  else .extend

private def extendMode (c : Nat) : Option Mode :=
  if isExtend c then some .extend else none

private def continueMode (mode : Mode) (c : Nat) : Option Mode :=
  match mode with
  | .closed => none
  | .carriageReturn => if c == 10 then some .closed else none
  | .prepend => if isControl c then none else some (initialMode c)
  | .extend => extendMode c
  | .hangulL =>
      if hangulL c then some .hangulL
      else if hangulV c then some .hangulV
      else if hangulSyllable c then
        some (if (c - 44032) % 28 == 0 then .hangulV else .hangulT)
      else extendMode c
  | .hangulV =>
      if hangulV c then some .hangulV else if hangulT c then some .hangulT
      else extendMode c
  | .hangulT => if hangulT c then some .hangulT else extendMode c
  | .regional => if regional c then some .extend else extendMode c
  | .pictographic =>
      if c == 8205 then some .pictographicZwj
      else if isExtend c then some .pictographic else none
  | .pictographicZwj =>
      if isPictographic c then some .pictographic else none
  | .indic linked =>
      if isLinker c then some (.indic true)
      else if isExtend c then some (.indic linked)
      else if linked && isConsonant c then some (.indic false)
      else none

/-- Count native OTP grapheme clusters over an already decoded scalar stream.
Empty input counts as zero. The runtime model does not perform UTF-8 decoding. -/
private def step (state : Nat × Option Mode) (codepoint : Nat) : Nat × Option Mode :=
  match state.2 with
  | none => (state.1 + 1, some (initialMode codepoint))
  | some mode =>
      match continueMode mode codepoint with
      | some next => (state.1, some next)
      | none => (state.1 + 1, some (initialMode codepoint))

def count (codepoints : List Nat) : Nat :=
  (codepoints.foldl step (0, none)).1

/-- `count` over the scalar values of a string. `String.foldl` visits the same
characters in the same order as `toList`, so this equals
`count (text.toList.map Char.toNat)` without building that list. -/
def countString (text : String) : Nat :=
  (text.foldl (fun state char => step state char.toNat) (0, none)).1

private def takeChars (limit : Nat) (state : Nat × Option Mode) (acc : List Char) : List Char → List Char
  | [] => acc.reverse
  | char :: rest =>
    let next := step state char.toNat
    if next.1 > limit then acc.reverse else takeChars limit next (char :: acc) rest

def takeString (text : String) (limit : Nat) : String :=
  String.ofList (takeChars limit (0, none) [] text.toList)

end VerifiedKernel.Grapheme
