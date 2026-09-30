import VerifiedKernel.Term
import VerifiedKernel.ETF

/-!
# Terminal emulator

A VT100 emulator with the xterm extensions that interactive programs commonly
use. It turns the byte stream of an SSH PTY into the screen a person would
see (`ssh.screen` in `SalixAgent.SSH.Session`).

The state stays resident behind a BEAM resource. The host hands the only
reference to each call, so every array update below happens in place: a
byte costs constant work, and a line feed at the bottom moves row pointers.
Functions that update an array field never capture the state in a closure,
because a second reference would force a copy.

The emulator keeps the character grid, cursor, scroll region, tab stops,
modes, character sets, alternate screen and window title. Colors and other
rendition attributes (SGR) are parsed and ignored: a snapshot is text.

Supported:

* C0 controls: BS, HT, LF, VT, FF, CR, SO, SI. CAN and SUB abort a sequence.
* ESC: DECSC/DECRC (7, 8), IND (D), NEL (E), RI (M), HTS (H), RIS (c),
  DECALN (#8), G0/G1 designation of ASCII and DEC Special Graphics.
* CSI: ICH, CUU, CUD, CUF, CUB, CNL, CPL, CHA, CUP, CHT, ED, EL, IL, DL, DCH,
  SU, SD, ECH, CBT, HPA, HPR, REP, DA, VPA, VPR, HVP, TBC, SM/RM (IRM),
  DECSET/DECRST (DECCKM, DECOM, DECAWM, DECTCEM, 47, 1047, 1048, 1049), SGR
  (ignored), DSR, DECSTBM, SCOSC/SCORC.
* OSC 0 and 2 (title). Other OSC, DCS, SOS, PM and APC strings are consumed.
* UTF-8, including sequences split across `feed` calls, East Asian wide
  characters and combining marks. An invalid sequence shows one U+FFFD per
  byte that cannot start a character.

Device status and attribute queries produce replies that the host writes back
to the remote side.

Bounds: 10 to 500 columns, 2 to 200 rows, 32 CSI parameters (192 bytes of
parameter text), 4 KiB of OSC text per sequence, and 4096 combined characters
(a base with combining marks) on the screens at once; marks past that are
dropped.
-/

namespace VerifiedKernel
namespace Terminal

abbrev Cell := UInt32
abbrev Row := Array Cell

/-- A blank cell. -/
def blank : Cell := 32
/-- The right half of a wide character. -/
def wideCell : Cell := 0x1FFFFF
/-- Cells at or above this value index `State.extras` (combined characters). -/
def extraBase : Cell := 0x200000

def noChar : Cell := 0xFFFFFFFF
def maxExtras : Nat := 4096
def maxParamBytes : Nat := 192
def maxParams : Nat := 32
def maxParam : Nat := 65535
def maxOscBytes : Nat := 4096

def clampSize (cols rows : Nat) : Nat × Nat :=
  (min 500 (max 10 cols), min 200 (max 2 rows))

inductive Parser where
  | ground
  | escape
  | escInt (intermediate : UInt8)
  | csi (priv : UInt8) (params : ByteArray) (inter : ByteArray)
  | osc (acc : ByteArray) (esc : Bool)
  | str (esc : Bool)
  deriving Inhabited

structure Saved where
  x : UInt32
  y : UInt32
  pendingWrap : Bool
  origin : Bool
  g0 : Bool
  g1 : Bool
  shift1 : Bool
  deriving Inhabited

/-- Dimensions and modes: read often, written rarely. Positions and sizes are
machine words: the bounds keep them far below 2^32, and the compiler stores
them unboxed. -/
structure Config where
  cols : UInt32
  rows : UInt32
  top : UInt32 := 0
  bottom : UInt32
  origin : Bool := false
  autowrap : Bool := true
  insert : Bool := false
  cursorVisible : Bool := true
  appCursor : Bool := false
  /-- `true` selects DEC Special Graphics for G0 or G1. -/
  g0 : Bool := false
  g1 : Bool := false
  shift1 : Bool := false
  deriving Inhabited

/-- Data that changes rarely. -/
structure Aux where
  tabs : Array Bool
  saved : Option Saved := none
  /-- The main screen's rows and base while the alternate screen is active. -/
  alt : Option (Array (Array Cell) × UInt32) := none
  title : String := ""
  replies : ByteArray := .empty
  extras : Array String := #[]
  deriving Inhabited

/-- The fields a byte usually changes, plus the rarely written parts. A record
update costs one load per field, so the frequently updated record is small. -/
structure State where
  /-- Rows form a ring: logical row `y` is `grid[(base + y) % rows]`, so a
  full-screen scroll moves `base` instead of the rows. -/
  grid : Array Row
  base : UInt32 := 0
  x : UInt32 := 0
  y : UInt32 := 0
  pendingWrap : Bool := false
  /-- The last printed character for REP, or `noChar`. -/
  lastChar : Cell := 0xFFFFFFFF
  parser : Parser := .ground
  /-- A UTF-8 sequence in progress: the code point so far, the continuation
  bytes it needs, and the ones seen. -/
  utf8Cp : UInt32 := 0
  utf8Need : Nat := 0
  utf8Seen : Nat := 0
  cfg : Config
  aux : Aux
  deriving Inhabited

namespace State
@[inline] def cols (t : State) : UInt32 := t.cfg.cols
@[inline] def rows (t : State) : UInt32 := t.cfg.rows
@[inline] def top (t : State) : UInt32 := t.cfg.top
@[inline] def bottom (t : State) : UInt32 := t.cfg.bottom
@[inline] def origin (t : State) : Bool := t.cfg.origin
@[inline] def autowrap (t : State) : Bool := t.cfg.autowrap
@[inline] def insert (t : State) : Bool := t.cfg.insert
@[inline] def cursorVisible (t : State) : Bool := t.cfg.cursorVisible
@[inline] def appCursor (t : State) : Bool := t.cfg.appCursor
@[inline] def g0 (t : State) : Bool := t.cfg.g0
@[inline] def g1 (t : State) : Bool := t.cfg.g1
@[inline] def shift1 (t : State) : Bool := t.cfg.shift1
@[inline] def tabs (t : State) : Array Bool := t.aux.tabs
@[inline] def saved (t : State) : Option Saved := t.aux.saved
@[inline] def alt (t : State) : Option (Array (Array Cell) × UInt32) := t.aux.alt
@[inline] def title (t : State) : String := t.aux.title
@[inline] def replies (t : State) : ByteArray := t.aux.replies
@[inline] def extras (t : State) : Array String := t.aux.extras
@[inline] def withCfg (t : State) (f : Config → Config) : State := { t with cfg := f t.cfg }
@[inline] def withAux (t : State) (f : Aux → Aux) : State := { t with aux := f t.aux }
end State

/-- Rows are sparse: a row holds cells up to its last written column, and
missing cells are blank. Each row owns room for a full line. Scrolling blanks
a row in place and keeps its length, so writing lines does not allocate. -/
def freshRows (rows cols : Nat) : Array Row :=
  go (Array.emptyWithCapacity rows) rows
where
  go (out : Array Row) : Nat → Array Row
    | 0 => out
    | k + 1 => go (out.push (Array.emptyWithCapacity cols)) k

@[inline] def cellAt (row : Row) (i : Nat) : Cell := if h : i < row.size then row[i] else blank

/-- Pad `row` with blanks to at least `n` cells. -/
def ensure (row : Row) (n : Nat) : Row :=
  go row (n - row.size)
where
  go (row : Row) : Nat → Row
    | 0 => row
    | k + 1 => go (row.push blank) k

/-- Write `c` at `x`, which is at most one past the end. -/
@[inline] def put (row : Row) (x : Nat) (c : Cell) : Row :=
  if x < row.size then row.set! x c else row.push c

def defaultTabs (cols : Nat) : Array Bool :=
  (Array.range cols).map fun i => i ≥ 8 && i % 8 == 0

def new (cols rows : Nat) : State :=
  let (cols, rows) := clampSize cols rows
  { grid := freshRows rows cols,
    cfg := { cols := cols.toUInt32, rows := rows.toUInt32, bottom := (rows - 1).toUInt32 },
    aux := { tabs := defaultTabs cols } }

@[inline] private def inRange (n a b : Nat) : Bool := a ≤ n && n ≤ b

/-- Display width: 0 for combining and zero-width marks, 2 for East Asian
wide and fullwidth forms and pictographic emoji, 1 otherwise. -/
def charWidth (c : UInt32) : Nat :=
  if c < 0x300 then 1 else
  let n := c.toNat
  if inRange n 0x0300 0x036F || inRange n 0x0483 0x0489 || inRange n 0x0591 0x05BD ||
     inRange n 0x0610 0x061A || inRange n 0x064B 0x065F || inRange n 0x0E31 0x0E3A ||
     inRange n 0x1AB0 0x1AFF || inRange n 0x1DC0 0x1DFF || inRange n 0x200B 0x200F ||
     inRange n 0x20D0 0x20FF || inRange n 0xFE00 0xFE0F || inRange n 0xFE20 0xFE2F ||
     inRange n 0xE0100 0xE01EF then 0
  else if inRange n 0x1100 0x115F || inRange n 0x2E80 0x303E || inRange n 0x3041 0x33FF ||
     inRange n 0x3400 0x4DBF || inRange n 0x4E00 0x9FFF || inRange n 0xA000 0xA4CF ||
     inRange n 0xAC00 0xD7A3 || inRange n 0xF900 0xFAFF || inRange n 0xFE30 0xFE4F ||
     inRange n 0xFF00 0xFF60 || inRange n 0xFFE0 0xFFE6 || inRange n 0x1F300 0x1F64F ||
     inRange n 0x1F900 0x1F9FF || inRange n 0x20000 0x2FFFD || inRange n 0x30000 0x3FFFD then 2
  else 1

/-- DEC Special Graphics: the line-drawing set selected by `ESC ( 0`. -/
def decGraphics (c : UInt32) : UInt32 :=
  match c.toNat with
  | 0x5F => 0x20 | 0x60 => 0x25C6 | 0x61 => 0x2592 | 0x66 => 0x00B0 | 0x67 => 0x00B1
  | 0x6A => 0x2518 | 0x6B => 0x2510 | 0x6C => 0x250C | 0x6D => 0x2514 | 0x6E => 0x253C
  | 0x6F => 0x23BA | 0x70 => 0x23BB | 0x71 => 0x2500 | 0x72 => 0x23BC | 0x73 => 0x23BD
  | 0x74 => 0x251C | 0x75 => 0x2524 | 0x76 => 0x2534 | 0x77 => 0x252C | 0x78 => 0x2502
  | 0x79 => 0x2264 | 0x7A => 0x2265 | 0x7B => 0x03C0 | 0x7C => 0x2260 | 0x7D => 0x00A3
  | 0x7E => 0x00B7 | _ => c

@[inline] def graphics (t : State) : Bool := if t.shift1 then t.g1 else t.g0

/-! ### Rows -/

/-- Overwriting half of a wide character blanks its other half. -/
def clearWideEdges (row : Row) (lo hi : Nat) : Row :=
  let size := row.size
  let row := if lo > 0 && lo < size && cellAt row lo == wideCell then row.set! (lo - 1) blank else row
  if hi + 1 < size && cellAt row (hi + 1) == wideCell then row.set! (hi + 1) blank else row

/-! Loops over a row or the state are explicit tail recursion: the compiler
then owns the value being updated and changes it in place, where a
`for` loop in `Id` would borrow it and copy on every write. -/

/-- Set `row[i:i + n]` to `cell`; `row` must hold those cells. -/
def fillCells (row : Row) (cell : Cell) (i : Nat) : Nat → Row
  | 0 => row
  | n + 1 => fillCells (row.set! i cell) cell (i + 1) n

/-- Drop cells from the end down to `n`. -/
def truncate (row : Row) (n : Nat) : Row :=
  go row (row.size - n)
where
  go (row : Row) : Nat → Row
    | 0 => row
    | k + 1 => go row.pop k

/-- Sizes below this fit in a machine word on every platform. It is a small
`Nat` (below 2^32), so comparing with it does not allocate, unlike `USize.size`. -/
def wordBound : Nat := 4294967295

theorem lt_usize_size {n : Nat} (h : n < wordBound) : n < USize.size := by
  unfold wordBound at h; cases USize.size_eq <;> omega

theorem toNat_toUSize_of_lt {n : Nat} (h : n < wordBound) : n.toUSize.toNat = n := by
  rw [Nat.toUSize_eq, USize.toNat_ofNat_of_lt' (lt_usize_size h)]

theorem usize_succ_toNat (a b : USize) (h : a < b) : (a + 1).toNat = a.toNat + 1 := by
  have : a.toNat < b.toNat := h
  have := b.toNat_lt_size
  rw [USize.size_eq_two_pow] at this
  rw [USize.toNat_add, USize.toNat_one]; exact Nat.mod_eq_of_lt (by omega)

/-- Blank `row[i:]`, in place. -/
def blankFrom (row : Row) (size : USize) (hsize : size.toNat = row.size) (i : USize) : Row :=
  if h : i < size then blankFrom (row.uset i blank (hsize ▸ h)) size (by simp [hsize]) (i + 1)
  else row
termination_by size.toNat - i.toNat
decreasing_by have := usize_succ_toNat i size h; have : i.toNat < size.toNat := h; omega

/-- Blank a row in place. The row keeps its length, so the next line written
into it overwrites cells instead of appending them. -/
def clearRow (_cols : Nat) (row : Row) : Row :=
  if h : row.size < wordBound then blankFrom row row.size.toUSize (toNat_toUSize_of_lt h) 0
  else truncate row 0

/-- Blank `row[lo:hi + 1]`. Cells past the end are already blank; clearing
through the end shortens the row. -/
def fillRow (row : Row) (lo hi : Nat) : Row :=
  if lo > hi || lo ≥ row.size then row
  else
    let row := clearWideEdges row lo hi
    if hi + 1 ≥ row.size then truncate row lo
    else fillCells row blank lo (hi + 1 - lo)

/-- Copy cells leftward: `row[i] := row[i + d]` for `n` ascending `i`. -/
def moveLeft (row : Row) (d i : Nat) : Nat → Row
  | 0 => row
  | n + 1 => moveLeft (row.set! i row[i + d]!) d (i + 1) n

/-- Copy cells rightward: `row[i] := row[i - d]` for `n` descending `i`. -/
def moveRight (row : Row) (d i : Nat) : Nat → Row
  | 0 => row
  | n + 1 => moveRight (row.set! i row[i - d]!) d (i - 1) n

/-- Insert `n` blanks at `x`; cells shifted past the edge are lost. -/
def shiftRight (row : Row) (x n cols : Nat) : Row :=
  let row := ensure row cols
  let n := min n (cols - x)
  let row := if cols > x + n then moveRight row n (cols - 1) (cols - x - n) else row
  fillCells row blank x n

/-- Delete `n` cells at `x`; blanks enter at the right edge. -/
def shiftLeft (row : Row) (x n cols : Nat) : Row :=
  let row := ensure row cols
  let n := min n (cols - x)
  fillCells (moveLeft row n x (cols - x - n)) blank (cols - n) n

/-- The physical index of logical row `y`. -/
@[inline] def phys (t : State) (y : UInt32) : Nat :=
  let p := t.base + y
  (if p ≥ t.rows then p - t.rows else p).toNat

@[inline] def modifyRow (t : State) (y : UInt32) (f : Row → Row) : State :=
  let p := phys t y
  { t with grid := t.grid.modify p f }

@[inline] def setRow (t : State) (y : UInt32) (row : Row) : State :=
  let p := phys t y
  { t with grid := t.grid.set! p row }

@[inline] def getRow (t : State) (y : UInt32) : Row := t.grid[phys t y]!

/-- The rows in logical order. -/
def logicalRows (grid : Array Row) (base : Nat) : Array Row :=
  if base == 0 then grid else grid.extract base grid.size ++ grid.extract 0 base

/-! ### Scrolling -/

/-- Move the row at logical `top` to logical `bottom` by adjacent swaps. -/
def rotateUp (g : Array Row) (base rows top bottom : Nat) : Array Row :=
  go g top (bottom - top)
where
  go (g : Array Row) (y : Nat) : Nat → Array Row
    | 0 => g
    | n + 1 =>
      let p := (base + y) % rows
      let q := (base + y + 1) % rows
      go (g.swapIfInBounds p q) (y + 1) n

/-- Move the row at logical `bottom` to logical `top` by adjacent swaps. -/
def rotateDown (g : Array Row) (base rows top bottom : Nat) : Array Row :=
  go g bottom (bottom - top)
where
  go (g : Array Row) (y : Nat) : Nat → Array Row
    | 0 => g
    | n + 1 =>
      let p := (base + y) % rows
      let q := (base + y + rows - 1) % rows
      go (g.swapIfInBounds p q) (y - 1) n

/-! Hot paths change the state in one record update: the compiler reuses the
state for one update, and a second update in the same path allocates. -/

/-- Scroll rows `top..bottom` up by one; a blank row enters at the bottom. A
full-screen scroll moves the ring base. -/
def scrollUpOnce (t : State) (top bottom : UInt32) : State :=
  let rows := t.rows
  let cols := t.cols.toNat
  let base := t.base
  if top == 0 && bottom + 1 == rows then
    let p := phys t 0
    { t with grid := t.grid.modify p (clearRow cols), base := if base + 1 == rows then 0 else base + 1 }
  else
    let p := phys t bottom
    { t with grid := (rotateUp t.grid base.toNat rows.toNat top.toNat bottom.toNat).modify p (clearRow cols) }

/-- Scroll rows `top..bottom` down by one; a blank row enters at the top. -/
def scrollDownOnce (t : State) (top bottom : UInt32) : State :=
  let rows := t.rows.toNat
  let cols := t.cols.toNat
  let base := t.base.toNat
  let p := phys t top
  { t with grid := (rotateDown t.grid base rows top.toNat bottom.toNat).modify p (clearRow cols) }

def scrollUp (t : State) (top bottom : UInt32) (n : Nat) : State :=
  go t (min n (bottom.toNat + 1 - top.toNat))
where
  go (t : State) : Nat → State
    | 0 => t
    | k + 1 => go (scrollUpOnce t top bottom) k

def scrollDown (t : State) (top bottom : UInt32) (n : Nat) : State :=
  go t (min n (bottom.toNat + 1 - top.toNat))
where
  go (t : State) : Nat → State
    | 0 => t
    | k + 1 => go (scrollDownOnce t top bottom) k

-- Scalars are read before the update so the state stays uniquely referenced.
def index (t : State) : State :=
  let top := t.top
  let bottom := t.bottom
  let rows := t.rows
  if t.y == bottom then
    if top == 0 && bottom + 1 == rows then
      let base := t.base
      let cols := t.cols.toNat
      let p := phys t 0
      { t with grid := t.grid.modify p (clearRow cols), base := if base + 1 == rows then 0 else base + 1,
               pendingWrap := false }
    else scrollUpOnce { t with pendingWrap := false } top bottom
  else if t.y + 1 < rows then { t with y := t.y + 1, pendingWrap := false }
  else { t with pendingWrap := false }

def reverseIndex (t : State) : State :=
  let top := t.top
  let bottom := t.bottom
  if t.y == top then scrollDown { t with pendingWrap := false } top bottom 1
  else if t.y > 0 then { t with y := t.y - 1, pendingWrap := false }
  else { t with pendingWrap := false }

/-! ### Cursor -/

/-- Move to `(x, y)`, clamped to the screen. Callers subtract with `Nat`,
which stops at 0 like a clamp would. -/
def moveTo (t : State) (x y : Nat) : State :=
  let cx := min x (t.cols.toNat - 1)
  let cy := min y (t.rows.toNat - 1)
  { t with x := cx.toUInt32, y := cy.toUInt32, pendingWrap := false }

@[inline] def rowOrigin (t : State) : UInt32 := if t.origin then t.top else 0

def home (t : State) : State := { t with x := 0, y := rowOrigin t, pendingWrap := false }

def cursorUp (t : State) (n : Nat) : State :=
  let limit := if t.y ≥ t.top then t.top.toNat else 0
  { t with y := (max (t.y.toNat - n) limit).toUInt32, pendingWrap := false }

def cursorDown (t : State) (n : Nat) : State :=
  let limit := if t.y ≤ t.bottom then t.bottom.toNat else t.rows.toNat - 1
  { t with y := (min (t.y.toNat + n) limit).toUInt32, pendingWrap := false }

def saveCursor (t : State) : State :=
  let s : Saved := { x := t.x, y := t.y, pendingWrap := t.pendingWrap, origin := t.origin,
                     g0 := t.g0, g1 := t.g1, shift1 := t.shift1 }
  t.withAux fun a => { a with saved := some s }

def restoreCursor (t : State) : State :=
  match t.saved with
  | none => { t with x := 0, y := 0, pendingWrap := false, cfg := { t.cfg with origin := false } }
  | some s =>
    { t with x := (min s.x.toNat (t.cols.toNat - 1)).toUInt32, y := (min s.y.toNat (t.rows.toNat - 1)).toUInt32,
             pendingWrap := s.pendingWrap,
             cfg := { t.cfg with origin := s.origin, g0 := s.g0, g1 := s.g1, shift1 := s.shift1 } }

def tabForward (t : State) (n : Nat) : State := Id.run do
  let cols := t.cols.toNat
  let mut x := t.x.toNat
  for _ in [0:n] do
    let mut next := cols - 1
    let mut found := false
    for i in [x + 1:cols] do
      if !found && t.tabs[i]! then
        next := i
        found := true
    x := next
  return { t with x := x.toUInt32, pendingWrap := false }

def tabBackward (t : State) (n : Nat) : State := Id.run do
  let mut x := t.x.toNat
  for _ in [0:n] do
    let mut prev := 0
    let mut i := x
    let mut found := false
    while i > 0 && !found do
      i := i - 1
      if t.tabs[i]! then
        prev := i
        found := true
    x := prev
  return { t with x := x.toUInt32, pendingWrap := false }

/-! ### Printing -/

def putChar (t : State) (c : Cell) (width : Nat) : State :=
  let t := if t.pendingWrap && t.autowrap then index { t with x := 0, pendingWrap := false } else t
  let t := if width == 2 && t.x + 1 == t.cols && t.autowrap then index { t with x := 0 } else t
  let w := width.toUInt32
  let cols := t.cols
  let x := min t.x (cols - w)
  let ins := t.insert
  let autowrap := t.autowrap
  let p := phys t t.y
  let edge := x + w ≥ cols
  let xn := x.toNat
  let cn := cols.toNat
  { t with
    grid := t.grid.modify p fun row =>
      let row := if ins then shiftRight row xn width cn else ensure row xn
      let row := clearWideEdges row xn (xn + width - 1)
      let row := put row xn c
      if width == 2 then put row (xn + 1) wideCell else row
    lastChar := c
    x := if edge then cols - 1 else x + w
    pendingWrap := edge && autowrap }

def cellText (extras : Array String) (cell : Cell) : String :=
  if cell == wideCell then ""
  else if cell ≥ extraBase then extras[(cell - extraBase).toNat]!
  else String.singleton (Char.ofNat cell.toNat)

/-! Combined characters (a base with combining marks) live in `extras`,
indexed from their cells. When the table is full, it keeps only the entries
still on either screen, renumbered. -/

/-- Renumber the combined characters in `row[i:i + n]`. `remap` holds each old
index's new index plus one (zero: not yet seen); `acc` collects the kept text. -/
def remapRow (old : Array String) (row : Row) (remap : Array Nat) (acc : Array String) (i : Nat) :
    Nat → Row × Array Nat × Array String
  | 0 => (row, remap, acc)
  | n + 1 =>
    let c := row[i]!
    if c < extraBase || c == wideCell then remapRow old row remap acc (i + 1) n
    else
      let idx := (c - extraBase).toNat
      let seen := remap[idx]!
      let (next, remap, acc) :=
        if seen != 0 then (seen - 1, remap, acc)
        else (acc.size, remap.set! idx (acc.size + 1), acc.push old[idx]!)
      remapRow old (row.set! i (extraBase + next.toUInt32)) remap acc (i + 1) n

/-- Renumber every row of `grid` from index `y`. -/
def remapGrid (old : Array String) (grid : Array Row) (remap : Array Nat) (acc : Array String)
    (y : Nat) : Nat → Array Row × Array Nat × Array String
  | 0 => (grid, remap, acc)
  | n + 1 =>
    let (row, grid) := grid.swapAt! y #[]
    let (row, remap, acc) := remapRow old row remap acc 0 row.size
    remapGrid old (grid.set! y row) remap acc (y + 1) n

def compactExtras (t : State) : State :=
  let old := t.extras
  let remap := Array.replicate old.size 0
  let (grid, remap, acc) := remapGrid old t.grid remap #[] 0 t.grid.size
  let (alt, acc) := match t.alt with
    | some (g, base) =>
      let (g, _, acc) := remapGrid old g remap acc 0 g.size
      (some (g, base), acc)
    | none => (none, acc)
  { t with grid, aux := { t.aux with alt, extras := acc } }

/-- A combining mark joins the character before the cursor. -/
def combine (t : State) (mark : UInt32) : State :=
  if !t.pendingWrap && t.x == 0 then t else
  let t := if t.extras.size ≥ maxExtras then compactExtras t else t
  if t.extras.size ≥ maxExtras then t
  else
    let y := t.y
    let x0 := if t.pendingWrap then t.x.toNat else t.x.toNat - 1
    let x := if cellAt (getRow t y) x0 == wideCell && x0 > 0 then x0 - 1 else x0
    let text := cellText t.extras (cellAt (getRow t y) x) ++ String.singleton (Char.ofNat mark.toNat)
    let cell := extraBase + t.extras.size.toUInt32
    let t := t.withAux fun a => { a with extras := a.extras.push text }
    modifyRow t y fun row => (ensure row (x + 1)).set! x cell

def print (t : State) (c : UInt32) : State :=
  let c := if graphics t then decGraphics c else c
  match charWidth c with
  | 0 => combine t c
  | w => putChar t c w

def repeatLast (t : State) (n : Nat) : State :=
  let c := t.lastChar
  if c == noChar then t else go t c (max (charWidth c) 1) (min n (t.cols.toNat * t.rows.toNat))
where
  go (t : State) (c : Cell) (width : Nat) : Nat → State
    | 0 => t
    | k + 1 => go (putChar t c width) c width k

/-! ### Erasing, inserting and deleting -/

def fillRows (t : State) (lo hi : Nat) : State :=
  go t lo (hi - lo)
where
  go (t : State) (y : Nat) : Nat → State
    | 0 => t
    | k + 1 => go (modifyRow t y.toUInt32 (clearRow t.cols.toNat)) (y + 1) k

def eraseLine (t : State) (mode : Nat) : State :=
  let x := t.x.toNat
  let cols := t.cols.toNat
  let t := { t with pendingWrap := false }
  match mode with
  | 0 => modifyRow t t.y fun row => fillRow row x (cols - 1)
  | 1 => modifyRow t t.y fun row => fillRow row 0 x
  | 2 => modifyRow t t.y (clearRow cols)
  | _ => t

def eraseDisplay (t : State) (mode : Nat) : State :=
  match mode with
  | 0 => let t := eraseLine t 0; fillRows t (t.y.toNat + 1) t.rows.toNat
  | 1 => let t := eraseLine t 1; fillRows t 0 t.y.toNat
  | 2 | 3 => { fillRows t 0 t.rows.toNat with pendingWrap := false }
  | _ => t

def eraseChars (t : State) (n : Nat) : State :=
  let x := t.x.toNat
  let hi := min (x + n) t.cols.toNat - 1
  modifyRow { t with pendingWrap := false } t.y fun row => fillRow row x hi

def insertChars (t : State) (n : Nat) : State :=
  let x := t.x.toNat
  let cols := t.cols.toNat
  modifyRow { t with pendingWrap := false } t.y fun row => shiftRight row x n cols

def deleteChars (t : State) (n : Nat) : State :=
  let x := t.x.toNat
  let cols := t.cols.toNat
  modifyRow { t with pendingWrap := false } t.y fun row => shiftLeft row x n cols

def insertLines (t : State) (n : Nat) : State :=
  if t.top ≤ t.y && t.y ≤ t.bottom then { scrollDown t t.y t.bottom n with x := 0 } else t

def deleteLines (t : State) (n : Nat) : State :=
  if t.top ≤ t.y && t.y ≤ t.bottom then { scrollUp t t.y t.bottom n with x := 0 } else t

def alternateScreen (t : State) (on : Bool) : State :=
  match t.alt, on with
  | none, true =>
    let base := t.base
    let fresh := freshRows t.rows.toNat t.cols.toNat
    { t with aux := { t.aux with alt := some (t.grid, base) }, grid := fresh, base := 0,
             pendingWrap := false }
  | some (main, base), false =>
    { t with grid := main, base, aux := { t.aux with alt := none }, pendingWrap := false }
  | _, _ => t

/-! ### Controls and sequences -/

/-- CR: the cursor moves to the first column. A function of its own, so the
caller's byte loop does not take the state apart to rebuild it. -/
@[noinline] def carriageReturn (t : State) : State := { t with x := 0, pendingWrap := false }

def control (t : State) (c : UInt8) : State :=
  match c with
  | 0x08 => { t with x := if t.x == 0 then 0 else t.x - 1, pendingWrap := false }
  | 0x09 => tabForward t 1
  | 0x0A | 0x0B | 0x0C => index t
  | 0x0D => carriageReturn t
  | 0x0E => t.withCfg fun c => { c with shift1 := true }
  | 0x0F => t.withCfg fun c => { c with shift1 := false }
  | _ => t

def reply (t : State) (text : String) : State :=
  t.withAux fun a => { a with replies := a.replies ++ text.toUTF8 }

/-- Parameters in `text[lo:hi]`, separated by `;` or `:`, at most
`maxParams`. An empty parameter is 0, which every sequence treats as
absent. -/
def parseParams (text : ByteArray) (lo hi : Nat) : Array Nat :=
  -- Room for the common case, so pushes do not reallocate.
  go lo 0 (Array.emptyWithCapacity 4) (hi - lo)
where
  add (out : Array Nat) (v : Nat) : Array Nat := if out.size < maxParams then out.push v else out
  go (i : Nat) (current : Nat) (out : Array Nat) : Nat → Array Nat
    | 0 => add out current
    | n + 1 =>
      let b := text[i]!
      if b == 0x3B || b == 0x3A then go (i + 1) 0 (add out current) n
      else go (i + 1) (min maxParam (current * 10 + (b - 0x30).toNat)) out n

/-- A parameter with its default: absent and 0 both select the default. -/
@[inline] def param (params : Array Nat) (i default : Nat) : Nat :=
  let v := params[i]?.getD 0
  if v == 0 then default else v

@[inline] def count (params : Array Nat) : Nat := param params 0 1

def cursorPosition (t : State) (params : Array Nat) : State :=
  let row := param params 0 1 - 1
  let col := param params 1 1 - 1
  if t.origin then
    let x := min col (t.cols.toNat - 1)
    let y := max t.top.toNat (min (t.top.toNat + row) t.bottom.toNat)
    { t with x := x.toUInt32, y := y.toUInt32, pendingWrap := false }
  else moveTo t col row

def deviceStatus (t : State) (code : Nat) (marker : String) : State :=
  match code with
  | 5 => reply t s!"\x1b[{marker}0n"
  | 6 => reply t s!"\x1b[{marker}{t.y.toNat - (rowOrigin t).toNat + 1};{t.x.toNat + 1}R"
  | _ => t

def setScrollRegion (t : State) (params : Array Nat) : State :=
  let rows := t.rows.toNat
  let top := param params 0 1 - 1
  let bottom := min (param params 1 rows) rows - 1
  if top < bottom then home (t.withCfg fun c => { c with top := top.toUInt32, bottom := bottom.toUInt32 })
  else t

def clearTabs (t : State) (mode : Nat) : State :=
  match mode with
  | 0 => let x := t.x.toNat; t.withAux fun a => { a with tabs := a.tabs.set! x false }
  | 3 => let cols := t.cols.toNat; t.withAux fun a => { a with tabs := Array.replicate cols false }
  | _ => t

def setPrivateMode (t : State) (mode : Nat) (on : Bool) : State :=
  match mode with
  | 1 => t.withCfg fun c => { c with appCursor := on }
  | 6 => home (t.withCfg fun c => { c with origin := on })
  | 7 => { t with pendingWrap := false, cfg := { t.cfg with autowrap := on } }
  | 25 => t.withCfg fun c => { c with cursorVisible := on }
  | 47 | 1047 => alternateScreen t on
  | 1048 => if on then saveCursor t else restoreCursor t
  | 1049 => if on then alternateScreen (saveCursor t) true else restoreCursor (alternateScreen t false)
  | _ => t

def dispatchCsi (t : State) (priv : UInt8) (params : Array Nat) (hasInter : Bool)
    (final : UInt8) : State :=
  if hasInter then t
  else if priv == 0 then
    match final with
    | 0x40 => insertChars t (count params)
    | 0x41 => cursorUp t (count params)
    | 0x42 => cursorDown t (count params)
    | 0x43 => moveTo t (t.x.toNat + count params) t.y.toNat
    | 0x44 => moveTo t (t.x.toNat - count params) t.y.toNat
    | 0x45 => { cursorDown t (count params) with x := 0 }
    | 0x46 => { cursorUp t (count params) with x := 0 }
    | 0x47 | 0x60 => moveTo t (count params - 1) t.y.toNat
    | 0x48 | 0x66 => cursorPosition t params
    | 0x49 => tabForward t (count params)
    | 0x4A => eraseDisplay t (param params 0 0)
    | 0x4B => eraseLine t (param params 0 0)
    | 0x4C => insertLines t (count params)
    | 0x4D => deleteLines t (count params)
    | 0x50 => deleteChars t (count params)
    | 0x53 => scrollUp t t.top t.bottom (count params)
    | 0x54 => scrollDown t t.top t.bottom (count params)
    | 0x58 => eraseChars t (count params)
    | 0x5A => tabBackward t (count params)
    | 0x61 => moveTo t (t.x.toNat + count params) t.y.toNat
    | 0x62 => repeatLast t (count params)
    | 0x63 => if param params 0 0 == 0 then reply t "\x1b[?1;2c" else t
    | 0x64 => moveTo t t.x.toNat ((rowOrigin t).toNat + count params - 1)
    | 0x65 => moveTo t t.x.toNat (t.y.toNat + count params)
    | 0x67 => clearTabs t (param params 0 0)
    | 0x68 => params.foldl (fun t p => if p == 4 then t.withCfg fun c => { c with insert := true } else t) t
    | 0x6C => params.foldl (fun t p => if p == 4 then t.withCfg fun c => { c with insert := false } else t) t
    | 0x6E => deviceStatus t (param params 0 0) ""
    | 0x72 => setScrollRegion t params
    | 0x73 => saveCursor t
    | 0x75 => restoreCursor t
    | _ => t
  else if priv == 0x3F then
    match final with
    | 0x68 => params.foldl (fun t p => setPrivateMode t p true) t
    | 0x6C => params.foldl (fun t p => setPrivateMode t p false) t
    | 0x6E => deviceStatus t (param params 0 0) "?"
    | _ => t
  else if priv == 0x3E && final == 0x63 then
    if param params 0 0 == 0 then reply t "\x1b[>0;0;0c" else t
  else t

def escape (t : State) (c : UInt8) : State :=
  if c < 0x20 then { control t c with parser := .escape }
  else match c with
  | 0x5B => { t with parser := .csi 0 .empty .empty }
  | 0x5D => { t with parser := .osc .empty false }
  | 0x50 | 0x58 | 0x5E | 0x5F => { t with parser := .str false }
  | 0x37 => { saveCursor t with parser := .ground }
  | 0x38 => { restoreCursor t with parser := .ground }
  | 0x44 => { index t with parser := .ground }
  | 0x45 => { index { t with x := 0 } with parser := .ground }
  | 0x4D => { reverseIndex t with parser := .ground }
  | 0x48 =>
    let x := t.x.toNat
    { t with parser := .ground, aux := { t.aux with tabs := t.aux.tabs.set! x true } }
  | 0x63 =>
    let replies := t.replies
    let fresh := new t.cols.toNat t.rows.toNat
    { fresh with aux := { fresh.aux with replies } }
  | _ => if c ≤ 0x2F then { t with parser := .escInt c } else { t with parser := .ground }

def escapeIntermediate (t : State) (slot c : UInt8) : State :=
  let t := { t with parser := .ground }
  if slot == 0x28 then t.withCfg fun cfg => { cfg with g0 := c == 0x30 }
  else if slot == 0x29 then t.withCfg fun cfg => { cfg with g1 := c == 0x30 }
  else if slot == 0x23 && c == 0x38 then
    let row := Array.replicate t.cols.toNat (0x45 : Cell)
    { t with grid := Array.replicate t.rows.toNat row, base := 0, x := 0, y := 0, pendingWrap := false }
  else t

/-- `t` arrives with its parser reset, so the parameter buffers are unique. -/
def csiByte (t : State) (priv : UInt8) (params inter : ByteArray) (c : UInt8) : State :=
  if c < 0x20 then { control t c with parser := .csi priv params inter }
  else if (c == 0x3C || c == 0x3D || c == 0x3E || c == 0x3F) && priv == 0 &&
      params.size == 0 && inter.size == 0 then
    { t with parser := .csi c params inter }
  else if (0x30 ≤ c && c ≤ 0x39) || c == 0x3B || c == 0x3A then
    let params := if params.size < maxParamBytes then params.push c else params
    { t with parser := .csi priv params inter }
  else if 0x20 ≤ c && c ≤ 0x2F then { t with parser := .csi priv params (inter.push c) }
  else if 0x40 ≤ c && c ≤ 0x7E then dispatchCsi t priv (parseParams params 0 params.size) (inter.size != 0) c
  else { t with parser := .csi priv params inter }

/-- OSC 0 and 2 set the title: the text after `0;` or `2;` (an empty title for a
bare `0` or `2`). The code and `;` are ASCII, and no byte of a multi-byte UTF-8
sequence is `;`, so the bytes locate the title without decoding the code. -/
def oscDispatch (t : State) (acc : ByteArray) : State :=
  let n := acc.size
  let code := if 0 < n then acc[0]! else 0
  if (code == 0x30 || code == 0x32) && (n == 1 || acc[1]! == 0x3B) then
    let title := utf8Text (acc.extract 2 n)
    t.withAux fun a => { a with title }
  else t
where
  /-- The text as UTF-8: when it is not valid, each byte from 0x80 becomes U+FFFD. -/
  utf8Text (bytes : ByteArray) : String :=
    match String.fromUTF8? bytes with
    | some s => s
    | none => bytes.foldl (fun out b => out.push (if b < 0x80 then Char.ofNat b.toNat else '�')) ""

/-- `t` arrives with its parser reset, so the text buffer is unique. -/
def oscByte (t : State) (acc : ByteArray) (esc : Bool) (c : UInt8) : State :=
  if c == 0x07 || (esc && c == 0x5C) then oscDispatch t acc
  else if c == 0x1B then { t with parser := .osc acc true }
  else
    let acc := if acc.size < maxOscBytes then acc.push c else acc
    { t with parser := .osc acc false }

/-! ### UTF-8 and the byte loop -/

def replacement : UInt32 := 0xFFFD

def printCodePoint (t : State) (cp : UInt32) : State :=
  if 0x80 ≤ cp && cp ≤ 0x9F then t else print t cp

/-- Replacement characters for an invalid sequence: one for its lead byte and
one for each continuation byte, which cannot start a character. -/
def invalidSequence (t : State) (bytes : Nat) : State :=
  go { t with utf8Need := 0, utf8Seen := 0, utf8Cp := 0 } bytes
where
  go (t : State) : Nat → State
    | 0 => t
    | k + 1 => go (print t replacement) k

def validCodePoint (cp : UInt32) (length : Nat) : Bool :=
  let minimum : UInt32 := match length with | 2 => 0x80 | 3 => 0x800 | _ => 0x10000
  minimum ≤ cp && cp ≤ 0x10FFFF && !(0xD800 ≤ cp && cp ≤ 0xDFFF)

def groundByte (t : State) (c : UInt8) : State :=
  if c < 0x20 then control t c
  else if c < 0x7F then print t c.toUInt32
  else if c == 0x7F then t
  else if 0xC2 ≤ c && c ≤ 0xDF then { t with utf8Cp := (c &&& 0x1F).toUInt32, utf8Need := 1, utf8Seen := 0 }
  else if 0xE0 ≤ c && c ≤ 0xEF then { t with utf8Cp := (c &&& 0x0F).toUInt32, utf8Need := 2, utf8Seen := 0 }
  else if 0xF0 ≤ c && c ≤ 0xF4 then { t with utf8Cp := (c &&& 0x07).toUInt32, utf8Need := 3, utf8Seen := 0 }
  else print t replacement

def nonUtf8Byte (t : State) (c : UInt8) : State :=
  if (c == 0x18 || c == 0x1A) && !(t.parser matches .ground) then { t with parser := .ground }
  else if c == 0x1B && !(t.parser matches .osc _ _ || t.parser matches .str _) then
    { t with parser := .escape }
  else
    match t.parser with
    | .ground => groundByte t c
    | .escape => escape t c
    | .escInt slot => escapeIntermediate t slot c
    | .csi priv params inter => csiByte { t with parser := .ground } priv params inter c
    | .osc acc esc => oscByte { t with parser := .ground } acc esc c
    | .str esc =>
      let parser := if esc && c == 0x5C then .ground else if c == 0x1B then .str true else .str false
      { t with parser }

def step (t : State) (c : UInt8) : State :=
  if t.utf8Need == 0 then nonUtf8Byte t c
  else if c &&& 0xC0 == 0x80 then
    let cp := (t.utf8Cp <<< 6) ||| (c &&& 0x3F).toUInt32
    let seen := t.utf8Seen + 1
    if seen < t.utf8Need then { t with utf8Cp := cp, utf8Seen := seen }
    else
      let length := t.utf8Need + 1
      let t := { t with utf8Cp := 0, utf8Need := 0, utf8Seen := 0 }
      if validCodePoint cp length then printCodePoint t cp else invalidSequence t length
  else
    nonUtf8Byte (invalidSequence t (t.utf8Seen + 1)) c

/-! ### Fast paths

`feed` handles common shapes of input without the byte state machine: line
ends, tabs, a run of printable ASCII in ground state (in either character set
and either insert or replace mode), written a row segment at a time, a complete
CSI sequence, parsed straight from the input, a complete OSC string, and a
complete UTF-8 sequence.
`VerifiedKernelProofs.Terminal.FastPath` proves that `feed` gives the same
state as `step` applied byte by byte, for every state the host can hold.
-/

@[inline] def printable (c : UInt8) : Bool := 0x20 ≤ c && c < 0x7F

/-- The first index at or after `j` whose byte fails `p`, before `e`. -/
@[specialize] def scanWhileU (p : UInt8 → Bool) (bytes : ByteArray) (e : USize) (he : e.toNat ≤ bytes.size)
    (j : USize) : USize :=
  if h : j < e then
    if p (bytes.uget j (Nat.lt_of_lt_of_le h he)) then scanWhileU p bytes e he (j + 1) else j
  else j
termination_by e.toNat - j.toNat
decreasing_by have := usize_succ_toNat j e h; have : j.toNat < e.toNat := h; omega

/-- The first index at or after `i` whose byte fails `p`, or the end. -/
@[inline] def scanWhile (p : UInt8 → Bool) (bytes : ByteArray) (i : Nat) : Nat :=
  if h : bytes.size < wordBound ∧ i ≤ bytes.size then
    (scanWhileU p bytes bytes.size.toUSize (by rw [toNat_toUSize_of_lt h.1]; exact Nat.le_refl _)
      i.toUSize).toNat
  else go i (bytes.size - i)
where
  go (j : Nat) : Nat → Nat
    | 0 => j
    | n + 1 => if p bytes[j]! then go (j + 1) n else j

/-- End of the printable ASCII run that starts at `i`. -/
def asciiRunEnd (bytes : ByteArray) (i : Nat) : Nat := scanWhile printable bytes i

/-- The cell of a printable byte: DEC Special Graphics maps it when `g`. -/
@[inline] def asciiCell (g : Bool) (b : UInt8) : Cell :=
  if g then decGraphics b.toUInt32 else b.toUInt32

/-! The copy loops use machine-word indices. Their bounds are proved, so each
cell costs a load, a store and a compare. `f` maps a byte to its cell; each
use specializes the loops to that map. -/

/-- Append the cells of `bytes[start:stop]` to `row`. -/
@[specialize] def appendWith (f : UInt8 → Cell) (row : Row) (bytes : ByteArray) (stop : USize)
    (hs : stop.toNat ≤ bytes.size) (start : USize) : Row :=
  if h : start < stop then
    appendWith f (row.push (f (bytes.uget start (Nat.lt_of_lt_of_le h hs)))) bytes stop hs (start + 1)
  else row
termination_by stop.toNat - start.toNat
decreasing_by have := usize_succ_toNat start stop h; have : start.toNat < stop.toNat := h; omega

/-- Write the cells of `bytes[start:stop]` into `row` from `x`: over existing
cells, then appended. `size` is the length of `row`. -/
@[specialize] def overwriteWith (f : UInt8 → Cell) (row : Row) (size : USize)
    (hsize : size.toNat = row.size) (bytes : ByteArray) (stop : USize) (hs : stop.toNat ≤ bytes.size)
    (x start : USize) : Row :=
  if h : start < stop then
    if hx : x < size then
      overwriteWith f (row.uset x (f (bytes.uget start (Nat.lt_of_lt_of_le h hs))) (hsize ▸ hx)) size
        (by simp [hsize]) bytes stop hs (x + 1) (start + 1)
    else appendWith f row bytes stop hs start
  else row
termination_by stop.toNat - start.toNat
decreasing_by have := usize_succ_toNat start stop h; have : start.toNat < stop.toNat := h; omega

/-- `put` the cells of `bytes[start:start + n]` from column `x`, which is at
most one past the end of `row`. -/
@[inline] def copyWithU (f : UInt8 → Cell) (row : Row) (bytes : ByteArray) (x start n : Nat) : Row :=
  if h : start + n ≤ bytes.size ∧ bytes.size < wordBound ∧ row.size < wordBound ∧ x < wordBound then
    overwriteWith f row row.size.toUSize (toNat_toUSize_of_lt h.2.2.1) bytes
      (start + n).toUSize (by rw [toNat_toUSize_of_lt (by omega)]; exact h.1)
      x.toUSize start.toUSize
  else go row x start n
where
  go (row : Row) (x start : Nat) : Nat → Row
    | 0 => row
    | n + 1 => go (put row x (f bytes[start]!)) (x + 1) (start + 1) n

/-- Copy `n` bytes from `bytes[start]` into `row[x]`. -/
def copyRun (row : Row) (bytes : ByteArray) (x start n : Nat) : Row :=
  copyWithU (·.toUInt32) row bytes x start n

/-- `copyRun` for DEC Special Graphics. -/
def copyGraphics (row : Row) (bytes : ByteArray) (x start n : Nat) : Row :=
  copyWithU (fun b => decGraphics b.toUInt32) row bytes x start n

/-- The copy for character set `g`, chosen once for the whole segment. -/
@[inline] def copyCells (row : Row) (bytes : ByteArray) (g : Bool) (x start n : Nat) : Row :=
  if g then copyGraphics row bytes x start n else copyRun row bytes x start n

/-- Write the printable bytes `bytes[i:j]` as `putChar` would, one row
segment at a time. Requires ground state and no pending UTF-8. `g` is the
character set in use. In insert mode the rest of the row shifts right once for
the whole segment. The column is clamped as in `putChar`. -/
def writeAscii (t : State) (bytes : ByteArray) (g : Bool) (i j : Nat) : State :=
  go t i (j - i)
where
  go (t : State) (i : Nat) : Nat → State
    | 0 => t
    | fuel + 1 =>
      if i ≥ j then t else
      let t := if t.pendingWrap && t.autowrap then index { t with x := 0, pendingWrap := false } else t
      let cols := t.cols
      let x := min t.x (cols - 1)
      let autowrap := t.autowrap
      let ins := t.insert
      let n := min (cols - x).toNat (j - i)
      let p := phys t t.y
      let next := i + n
      let edge := x + n.toUInt32 ≥ cols
      let xn := x.toNat
      let cn := cols.toNat
      if next < j && !autowrap then
        -- Without autowrap, the rest overwrite the last column.
        let last := asciiCell g bytes[j - 1]!
        { t with
          grid := t.grid.modify p fun row =>
            let row := if ins then shiftRight row xn n cn else ensure row xn
            (copyCells (clearWideEdges row xn (xn + n - 1)) bytes g xn i n).set! (cn - 1) last
          lastChar := last
          x := cols - 1
          pendingWrap := false }
      else
        go { t with
          grid := t.grid.modify p fun row =>
            let row := if ins then shiftRight row xn n cn else ensure row xn
            copyCells (clearWideEdges row xn (xn + n - 1)) bytes g xn i n
          lastChar := asciiCell g bytes[next - 1]!
          x := if edge then cols - 1 else x + n.toUInt32
          pendingWrap := edge && autowrap } next fuel

@[inline] def paramByte (c : UInt8) : Bool := (0x30 ≤ c && c ≤ 0x39) || c == 0x3B || c == 0x3A
@[inline] def intermediateByte (c : UInt8) : Bool := 0x20 ≤ c && c ≤ 0x2F

/-- The first index at or after `k` that is not a parameter byte. -/
def skipParams (bytes : ByteArray) (k : Nat) : Nat := scanWhile paramByte bytes k

/-- The first index at or after `k` that is not an intermediate byte. -/
def skipIntermediates (bytes : ByteArray) (k : Nat) : Nat := scanWhile intermediateByte bytes k

/-- A complete CSI sequence: the private marker (0 for none), the parameter
text bounds, the intermediates' end, and the index after the final byte
(0 when there is no complete sequence). -/
structure CsiScan where
  priv : UInt8
  paramStart : Nat
  paramEnd : Nat
  interEnd : Nat
  next : Nat

/-- A complete CSI sequence at `i` (just after `ESC [`), in the form the byte
state machine parses the same way: an optional private marker, parameter
bytes, intermediates, and a final byte. -/
def scanCsi (bytes : ByteArray) (i : Nat) : CsiScan :=
  let c := if i < bytes.size then bytes[i]! else 0
  let marker := c == 0x3C || c == 0x3D || c == 0x3E || c == 0x3F
  let priv := if marker then c else 0
  let paramStart := if marker then i + 1 else i
  let paramEnd := skipParams bytes paramStart
  let interEnd := skipIntermediates bytes paramEnd
  let complete := paramEnd - paramStart < maxParamBytes && interEnd < bytes.size &&
    0x40 ≤ bytes[interEnd]! && bytes[interEnd]! ≤ 0x7E
  { priv, paramStart, paramEnd, interEnd, next := if complete then interEnd + 1 else 0 }

/-- A byte that ends or aborts OSC text: BEL, ESC, CAN or SUB. -/
@[inline] def oscStop (c : UInt8) : Bool := c == 0x07 || c == 0x1B || c == 0x18 || c == 0x1A

/-- The first index at or after `k` that holds an `oscStop` byte, or the end. -/
def skipOscText (bytes : ByteArray) (k : Nat) : Nat := scanWhile (fun c => !oscStop c) bytes k

/-- The index after a complete OSC string whose text starts at `k` (just
after `ESC ]`), terminated by BEL or `ESC \`; 0 when there is none. The text
ends at `skipOscText bytes k`. -/
def scanOsc (bytes : ByteArray) (k : Nat) : Nat :=
  let m := skipOscText bytes k
  if m < bytes.size && bytes[m]! == 0x07 then m + 1
  else if m + 1 < bytes.size && bytes[m]! == 0x1B && bytes[m + 1]! == 0x5C then m + 2
  else 0

/-- The first tab stop at or after column `i`, or the last column: where HT
moves the cursor from column `i - 1`. -/
def nextTab (tabs : Array Bool) (cols i : Nat) : Nat → Nat
  | 0 => cols - 1
  | n + 1 => if i < cols then (if tabs[i]! then i else nextTab tabs cols (i + 1) n) else cols - 1

/-- The OSC string whose text starts at `k`, dispatched: kept out of the byte
loop, which stays small. -/
@[noinline] def oscFast (t : State) (bytes : ByteArray) (k : Nat) : State :=
  oscDispatch t (bytes.extract k (min (skipOscText bytes k) (k + maxOscBytes)))

/-- HT: the cursor moves to the next tab stop. -/
@[noinline] def tabFast (t : State) : State :=
  let cols := t.cols.toNat
  let x := (nextTab t.tabs cols (t.x.toNat + 1) cols).toUInt32
  { t with x, pendingWrap := false }

/-- Decode continuation bytes `bytes[k:k + n]` onto `cp`; `0xFFFFFFFF` when one
is not a continuation byte. -/
def continuation (bytes : ByteArray) (cp : UInt32) (k : Nat) : Nat → UInt32
  | 0 => cp
  | n + 1 =>
    let b := bytes[k]!
    if b &&& 0xC0 == 0x80 then continuation bytes ((cp <<< 6) ||| (b &&& 0x3F).toUInt32) (k + 1) n
    else 0xFFFFFFFF

/-- A complete, valid UTF-8 sequence at `i`: its code point shifted left by 8
bits plus its length, or 0. Anything else goes through the byte state
machine. -/
def scanUtf8 (bytes : ByteArray) (i : Nat) : UInt64 :=
  let c := bytes[i]!
  let need := if 0xC2 ≤ c && c ≤ 0xDF then 1 else if 0xE0 ≤ c && c ≤ 0xEF then 2
    else if 0xF0 ≤ c && c ≤ 0xF4 then 3 else 0
  if need == 0 || i + need ≥ bytes.size then 0 else
  let lead : UInt32 := if need == 1 then (c &&& 0x1F).toUInt32 else if need == 2 then (c &&& 0x0F).toUInt32
    else (c &&& 0x07).toUInt32
  let cp := continuation bytes lead (i + 1) need
  if cp != 0xFFFFFFFF && validCodePoint cp (need + 1) then (cp.toUInt64 <<< 8) ||| (need + 1).toUInt64
  else 0

/-- Process remote output. Replies accumulate in `replies`. -/
def feed (t : State) (bytes : ByteArray) : State :=
  go t 0 bytes.size
where
  go (t : State) (i : Nat) : Nat → State
    | 0 => t
    | fuel + 1 =>
      if i ≥ bytes.size then t else
      let c := bytes[i]!
      -- Fast paths start only in ground state with no UTF-8 sequence pending.
      if !(t.utf8Need == 0 && t.parser matches .ground) then go (step t c) (i + 1) fuel
      else if c < 0x20 then
        if c == 0x0D then go (carriageReturn t) (i + 1) fuel
        else if c == 0x0A then go (index t) (i + 1) fuel
        else if c == 0x1B && i + 1 < bytes.size then
          let c1 := bytes[i + 1]!
          if c1 == 0x5B then
            let scan := scanCsi bytes (i + 2)
            if scan.next == 0 then go (step t c) (i + 1) fuel else
            let final := bytes[scan.next - 1]!
            let hasInter := scan.interEnd != scan.paramEnd
            -- SGR (rendition) is ignored; skip parsing it.
            let t := if final == 0x6D && scan.priv == 0 && !hasInter then t
              else dispatchCsi t scan.priv (parseParams bytes scan.paramStart scan.paramEnd) hasInter final
            go t scan.next fuel
          else if c1 == 0x5D then
            let next := scanOsc bytes (i + 2)
            if next == 0 then go (step t c) (i + 1) fuel else go (oscFast t bytes (i + 2)) next fuel
          else go (step t c) (i + 1) fuel
        else if c == 0x09 then go (tabFast t) (i + 1) fuel
        else go (step t c) (i + 1) fuel
      else if c < 0x7F then
        let j := asciiRunEnd bytes i
        go (writeAscii t bytes (graphics t) i j) j fuel
      else if c ≥ 0xC2 then
        let decoded := scanUtf8 bytes i
        if decoded == 0 then go (step t c) (i + 1) fuel
        else go (printCodePoint t (decoded >>> 8).toUInt32) (i + (decoded &&& 0xFF).toNat) fuel
      else go (step t c) (i + 1) fuel

/-! ### Resize and snapshot -/

def resizeGrid (grid : Array Row) (_oldCols cols rows drop : Nat) : Array Row :=
  let kept := (grid.extract drop grid.size).extract 0 rows
  let kept := kept.map fun row =>
    if row.size ≤ cols then row else
    let row := row.extract 0 cols
    -- A wide character cut at the new right edge becomes a blank.
    match row.back? with
    | some c => if c < extraBase && charWidth c == 2 then row.set! (row.size - 1) blank else row
    | none => row
  kept ++ freshRows (rows - kept.size) cols

def resize (t : State) (cols rows : Nat) : State :=
  let (cols, rows) := clampSize cols rows
  let drop := t.y.toNat - (rows - 1)
  let oldCols := t.cols.toNat
  let alt := t.alt.map fun (g, base) => (resizeGrid (logicalRows g base.toNat) oldCols cols rows drop, 0)
  let base := t.base.toNat
  { t with grid := resizeGrid (logicalRows t.grid base) oldCols cols rows drop, base := 0,
           x := (min t.x.toNat (cols - 1)).toUInt32, y := (min (t.y.toNat - drop) (rows - 1)).toUInt32,
           pendingWrap := false,
           cfg := { t.cfg with cols := cols.toUInt32, rows := rows.toUInt32, top := 0,
                               bottom := (rows - 1).toUInt32 },
           aux := { t.aux with alt, tabs := defaultTabs cols } }

def renderRow (extras : Array String) (row : Row) : String := Id.run do
  let mut last := 0
  for i in [0:row.size] do
    if row[i]! != blank then last := i + 1
  let mut out := ""
  for i in [0:last] do
    out := out ++ cellText extras row[i]!
  return out

private def key (name : String) : Term := .binary name.toUTF8
private def bool (value : Bool) : Term := .atom (if value then "true" else "false")

def snapshot (t : State) : Term :=
  .map [
    (key "cols", .integer t.cols.toNat),
    (key "rows", .integer t.rows.toNat),
    (key "lines", .list ((logicalRows t.grid t.base.toNat).toList.map fun row =>
      .binary (renderRow t.extras row).toUTF8)),
    (key "cursor", .map [(key "row", .integer (t.y.toNat + 1)), (key "col", .integer (t.x.toNat + 1)),
                         (key "visible", bool t.cursorVisible)]),
    (key "title", .binary t.title.toUTF8),
    (key "alternate_screen", bool t.alt.isSome)]

/-! ### Native entry points -/

@[export salix_verified_kernel_terminal_new]
def exportNew (cols rows : UInt32) : State := new cols.toNat rows.toNat

@[export salix_verified_kernel_terminal_feed]
def exportFeed (t : State) (bytes : ByteArray) : State × ByteArray :=
  let t := feed t bytes
  let replies := t.replies
  (t.withAux fun a => { a with replies := .empty }, replies)

@[export salix_verified_kernel_terminal_resize]
def exportResize (t : State) (cols rows : UInt32) : State := resize t cols.toNat rows.toNat

@[export salix_verified_kernel_terminal_snapshot]
def exportSnapshot (t : State) : ByteArray :=
  match ETF.encode (snapshot t) with
  | .ok bytes => bytes
  | .error _ => .empty

@[export salix_verified_kernel_terminal_app_cursor]
def exportAppCursor (t : State) : UInt8 := if t.appCursor then 1 else 0

end Terminal
end VerifiedKernel
