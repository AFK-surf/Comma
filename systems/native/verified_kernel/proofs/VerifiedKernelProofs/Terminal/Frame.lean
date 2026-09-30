import VerifiedKernel.Terminal

/-!
# Terminal state invariant

`Good` is what the fast paths in `feed` rely on: a nonzero width, and no
leftover decoder state when no UTF-8 sequence is in progress. Every state
the host can hold satisfies it: `new`, `step`, `resize` and clearing the
replies preserve it.
-/

namespace VerifiedKernel.Terminal

def Good (t : State) : Prop :=
  0 < t.cfg.cols ∧ (t.utf8Need = 0 → t.utf8Cp = 0 ∧ t.utf8Seen = 0)

/-- `t'` keeps the width and the UTF-8 decoder fields of `t`. -/
def Keeps (t t' : State) : Prop :=
  t'.cfg.cols = t.cfg.cols ∧ t'.utf8Cp = t.utf8Cp ∧ t'.utf8Need = t.utf8Need ∧
    t'.utf8Seen = t.utf8Seen

theorem Keeps.refl (t : State) : Keeps t t := ⟨rfl, rfl, rfl, rfl⟩

theorem Keeps.trans {a b c : State} (h1 : Keeps a b) (h2 : Keeps b c) : Keeps a c := by
  obtain ⟨h1, h2', h3, h4⟩ := h1
  obtain ⟨g1, g2, g3, g4⟩ := h2
  exact ⟨g1.trans h1, g2.trans h2', g3.trans h3, g4.trans h4⟩

theorem Keeps.good {t t' : State} (h : Keeps t t') (g : Good t) : Good t' := by
  obtain ⟨h1, h2, h3, h4⟩ := h
  obtain ⟨g1, g2⟩ := g
  refine ⟨h1 ▸ g1, fun hn => ?_⟩
  obtain ⟨a, b⟩ := g2 (h3 ▸ hn)
  exact ⟨h2.trans a, h4.trans b⟩

/-! ### Handlers that keep the width and decoder fields -/

/-- Close `Keeps` goals whose updates leave the tracked fields alone. -/
macro "keeps" : tactic =>
  `(tactic| (try dsimp only; repeat' (first | split | exact ⟨rfl, rfl, rfl, rfl⟩)))

theorem keeps_scrollUpOnce (t : State) (a b : UInt32) : Keeps t (scrollUpOnce t a b) := by
  unfold scrollUpOnce; keeps

theorem keeps_scrollDownOnce (t : State) (a b : UInt32) : Keeps t (scrollDownOnce t a b) := by
  unfold scrollDownOnce; keeps

theorem keeps_scrollUp (t : State) (a b : UInt32) (n : Nat) : Keeps t (scrollUp t a b n) := by
  unfold scrollUp
  generalize min n (b.toNat + 1 - a.toNat) = k
  induction k generalizing t with
  | zero => exact Keeps.refl _
  | succ k ih => exact (keeps_scrollUpOnce t a b).trans (ih _)

theorem keeps_scrollDown (t : State) (a b : UInt32) (n : Nat) : Keeps t (scrollDown t a b n) := by
  unfold scrollDown
  generalize min n (b.toNat + 1 - a.toNat) = k
  induction k generalizing t with
  | zero => exact Keeps.refl _
  | succ k ih => exact (keeps_scrollDownOnce t a b).trans (ih _)

theorem keeps_index (t : State) : Keeps t (index t) := by
  unfold index; try dsimp only
  split
  · split
    · exact ⟨rfl, rfl, rfl, rfl⟩
    · exact keeps_scrollUpOnce _ _ _
  · split <;> exact ⟨rfl, rfl, rfl, rfl⟩

theorem keeps_reverseIndex (t : State) : Keeps t (reverseIndex t) := by
  unfold reverseIndex; try dsimp only
  split
  · exact keeps_scrollDown _ _ _ _
  · split <;> exact ⟨rfl, rfl, rfl, rfl⟩

theorem keeps_tabForward (t : State) (n : Nat) : Keeps t (tabForward t n) := by
  unfold tabForward; simp [Keeps]

theorem keeps_tabBackward (t : State) (n : Nat) : Keeps t (tabBackward t n) := by
  unfold tabBackward; simp [Keeps]

theorem keeps_moveTo (t : State) (x y : Nat) : Keeps t (moveTo t x y) := ⟨rfl, rfl, rfl, rfl⟩
theorem keeps_home (t : State) : Keeps t (home t) := ⟨rfl, rfl, rfl, rfl⟩
theorem keeps_saveCursor (t : State) : Keeps t (saveCursor t) := ⟨rfl, rfl, rfl, rfl⟩

theorem keeps_restoreCursor (t : State) : Keeps t (restoreCursor t) := by
  unfold restoreCursor; keeps

theorem keeps_putChar (t : State) (c : Cell) (w : Nat) : Keeps t (putChar t c w) := by
  unfold putChar; try dsimp only
  have h1 : Keeps t (if t.pendingWrap && t.autowrap then index { t with x := 0, pendingWrap := false } else t) := by
    split
    · exact keeps_index _
    · exact Keeps.refl _
  generalize (if t.pendingWrap && t.autowrap then index { t with x := 0, pendingWrap := false } else t) = t1 at h1
  have h2 : Keeps t1 (if w == 2 && t1.x + 1 == t1.cols && t1.autowrap then index { t1 with x := 0 } else t1) := by
    split
    · exact keeps_index _
    · exact Keeps.refl _
  generalize (if w == 2 && t1.x + 1 == t1.cols && t1.autowrap then index { t1 with x := 0 } else t1) = t2 at h2
  exact h1.trans (h2.trans ⟨rfl, rfl, rfl, rfl⟩)

theorem keeps_compactExtras (t : State) : Keeps t (compactExtras t) := by
  unfold compactExtras; keeps

theorem keeps_combine (t : State) (m : UInt32) : Keeps t (combine t m) := by
  unfold combine; try dsimp only
  split
  · exact Keeps.refl _
  · have h1 : Keeps t (if t.extras.size ≥ maxExtras then compactExtras t else t) := by
      split
      · exact keeps_compactExtras _
      · exact Keeps.refl _
    generalize (if t.extras.size ≥ maxExtras then compactExtras t else t) = t1 at h1
    split
    · exact h1
    · exact h1.trans ⟨rfl, rfl, rfl, rfl⟩

theorem keeps_print (t : State) (c : UInt32) : Keeps t (print t c) := by
  unfold print; try dsimp only
  split
  · exact keeps_combine _ _
  · exact keeps_putChar _ _ _

theorem keeps_repeatLast (t : State) (n : Nat) : Keeps t (repeatLast t n) := by
  unfold repeatLast; try dsimp only
  split
  · exact Keeps.refl _
  · rename_i h; clear h
    generalize min n (t.cols.toNat * t.rows.toNat) = k
    generalize max (charWidth t.lastChar) 1 = w
    generalize t.lastChar = c
    induction k generalizing t with
    | zero => exact Keeps.refl _
    | succ k ih => exact (keeps_putChar t c w).trans (ih _)

theorem keeps_fillRows (t : State) (a b : Nat) : Keeps t (fillRows t a b) := by
  unfold fillRows
  generalize b - a = k
  induction k generalizing t a with
  | zero => exact Keeps.refl _
  | succ k ih => exact Keeps.trans ⟨rfl, rfl, rfl, rfl⟩ (ih _ _)

theorem keeps_eraseLine (t : State) (m : Nat) : Keeps t (eraseLine t m) := by
  unfold eraseLine; keeps

theorem keeps_eraseDisplay (t : State) (m : Nat) : Keeps t (eraseDisplay t m) := by
  unfold eraseDisplay; try dsimp only
  split
  · exact (keeps_eraseLine t 0).trans (keeps_fillRows _ _ _)
  · exact (keeps_eraseLine t 1).trans (keeps_fillRows _ _ _)
  · exact keeps_fillRows t 0 t.rows.toNat
  · exact keeps_fillRows t 0 t.rows.toNat
  · exact Keeps.refl _

theorem keeps_insertLines (t : State) (n : Nat) : Keeps t (insertLines t n) := by
  unfold insertLines
  split
  · exact keeps_scrollDown _ _ _ _
  · exact Keeps.refl _

theorem keeps_deleteLines (t : State) (n : Nat) : Keeps t (deleteLines t n) := by
  unfold deleteLines
  split
  · exact keeps_scrollUp _ _ _ _
  · exact Keeps.refl _

theorem keeps_alternateScreen (t : State) (on : Bool) : Keeps t (alternateScreen t on) := by
  unfold alternateScreen; keeps

theorem keeps_control (t : State) (c : UInt8) : Keeps t (control t c) := by
  unfold control
  split
  · exact ⟨rfl, rfl, rfl, rfl⟩
  · exact keeps_tabForward _ _
  · exact keeps_index _
  · exact keeps_index _
  · exact keeps_index _
  all_goals exact ⟨rfl, rfl, rfl, rfl⟩

theorem keeps_foldl (t : State) (ps : Array Nat) (f : State → Nat → State)
    (hf : ∀ s p, Keeps s (f s p)) : Keeps t (ps.foldl f t) := by
  rw [← Array.foldl_toList]
  generalize ps.toList = l
  induction l generalizing t with
  | nil => exact Keeps.refl _
  | cons p l ih => exact (hf t p).trans (ih _)

theorem keeps_setPrivateMode (t : State) (m : Nat) (on : Bool) : Keeps t (setPrivateMode t m on) := by
  unfold setPrivateMode
  split
  · exact ⟨rfl, rfl, rfl, rfl⟩
  · exact ⟨rfl, rfl, rfl, rfl⟩
  · exact ⟨rfl, rfl, rfl, rfl⟩
  · exact ⟨rfl, rfl, rfl, rfl⟩
  · exact keeps_alternateScreen _ _
  · exact keeps_alternateScreen _ _
  · split
    · exact ⟨rfl, rfl, rfl, rfl⟩
    · exact keeps_restoreCursor _
  · split
    · exact keeps_alternateScreen _ _
    · exact (keeps_alternateScreen _ _).trans (keeps_restoreCursor _)
  · exact Keeps.refl _


theorem keeps_reply (t : State) (s : String) : Keeps t (reply t s) := ⟨rfl, rfl, rfl, rfl⟩

theorem keeps_cursorPosition (t : State) (ps : Array Nat) : Keeps t (cursorPosition t ps) := by
  unfold cursorPosition; keeps

theorem keeps_deviceStatus (t : State) (c : Nat) (m : String) : Keeps t (deviceStatus t c m) := by
  unfold deviceStatus
  split
  · exact keeps_reply _ _
  · exact keeps_reply _ _
  · exact Keeps.refl _

theorem keeps_setScrollRegion (t : State) (ps : Array Nat) : Keeps t (setScrollRegion t ps) := by
  unfold setScrollRegion; keeps

theorem keeps_clearTabs (t : State) (m : Nat) : Keeps t (clearTabs t m) := by
  unfold clearTabs; keeps

theorem keeps_dispatchCsi (t : State) (priv : UInt8) (ps : Array Nat) (h : Bool) (f : UInt8) :
    Keeps t (dispatchCsi t priv ps h f) := by
  unfold dispatchCsi
  split
  · exact Keeps.refl _
  split
  · split
    all_goals first
      | with_reducible exact Keeps.refl _
      | with_reducible exact keeps_tabForward _ _
      | with_reducible exact keeps_tabBackward _ _
      | with_reducible exact keeps_cursorPosition _ _
      | with_reducible exact keeps_eraseDisplay _ _
      | with_reducible exact keeps_eraseLine _ _
      | with_reducible exact keeps_insertLines _ _
      | with_reducible exact keeps_deleteLines _ _
      | with_reducible exact keeps_scrollUp _ _ _ _
      | with_reducible exact keeps_scrollDown _ _ _ _
      | with_reducible exact keeps_repeatLast _ _
      | with_reducible exact keeps_clearTabs _ _
      | with_reducible exact keeps_deviceStatus _ _ _
      | with_reducible exact keeps_setScrollRegion _ _
      | with_reducible exact keeps_saveCursor _
      | with_reducible exact keeps_restoreCursor _
      | (split <;> exact ⟨rfl, rfl, rfl, rfl⟩)
      | exact ⟨rfl, rfl, rfl, rfl⟩
      | (apply keeps_foldl; intro s p; split <;> exact ⟨rfl, rfl, rfl, rfl⟩)
  split
  · split
    · exact keeps_foldl _ _ _ fun s p => keeps_setPrivateMode s p true
    · exact keeps_foldl _ _ _ fun s p => keeps_setPrivateMode s p false
    · exact keeps_deviceStatus _ _ _
    · exact Keeps.refl _
  split
  · split <;> exact ⟨rfl, rfl, rfl, rfl⟩
  · exact Keeps.refl _

theorem keeps_escapeIntermediate (t : State) (slot c : UInt8) :
    Keeps t (escapeIntermediate t slot c) := by
  unfold escapeIntermediate; keeps

theorem keeps_ite {p : Prop} [Decidable p] {t a b : State} (ha : Keeps t a) (hb : Keeps t b) :
    Keeps t (if p then a else b) := by
  split
  · exact ha
  · exact hb

theorem keeps_oscDispatch (t : State) (acc : ByteArray) : Keeps t (oscDispatch t acc) :=
  keeps_ite ⟨rfl, rfl, rfl, rfl⟩ (Keeps.refl _)

theorem keeps_oscByte (t : State) (acc : ByteArray) (e : Bool) (c : UInt8) :
    Keeps t (oscByte t acc e c) := by
  unfold oscByte
  split
  · exact keeps_oscDispatch _ _
  · split <;> exact ⟨rfl, rfl, rfl, rfl⟩

theorem keeps_csiByte (t : State) (priv : UInt8) (ps inter : ByteArray) (c : UInt8) :
    Keeps t (csiByte t priv ps inter c) := by
  unfold csiByte
  split
  · exact keeps_control t c
  split
  · exact ⟨rfl, rfl, rfl, rfl⟩
  split
  · exact ⟨rfl, rfl, rfl, rfl⟩
  split
  · exact ⟨rfl, rfl, rfl, rfl⟩
  split
  · exact keeps_dispatchCsi _ _ _ _ _
  · exact ⟨rfl, rfl, rfl, rfl⟩

theorem keeps_printCodePoint (t : State) (cp : UInt32) : Keeps t (printCodePoint t cp) := by
  unfold printCodePoint
  split
  · exact Keeps.refl _
  · exact keeps_print _ _

theorem toUInt32_pos {n : Nat} (h : 0 < n) (h2 : n < 2 ^ 32) : 0 < n.toUInt32 := by
  rw [UInt32.lt_iff_toNat_lt, Nat.toUInt32_eq, UInt32.toNat_ofNat_of_lt' h2]; exact h

theorem good_new (cols rows : Nat) : Good (new cols rows) := by
  refine ⟨toUInt32_pos ?_ ?_, fun _ => ⟨rfl, rfl⟩⟩ <;> (try simp only [clampSize]) <;> omega

theorem good_escape (t : State) (c : UInt8) (g : Good t) : Good (escape t c) := by
  unfold escape
  split
  · exact (keeps_control t c).good g
  split
  · exact g
  · exact g
  · exact g
  · exact g
  · exact g
  · exact g
  · exact (keeps_saveCursor t).good g
  · exact (keeps_restoreCursor t).good g
  · exact (keeps_index t).good g
  · exact (keeps_index _).good g
  · exact (keeps_reverseIndex t).good g
  · exact g
  · exact good_new t.cols.toNat t.rows.toNat
  · split
    · exact g
    · exact g

theorem good_of_need {t : State} (h : 0 < t.cfg.cols) (n : t.utf8Need ≠ 0) : Good t :=
  ⟨h, fun e => absurd e n⟩

theorem good_groundByte (t : State) (c : UInt8) (g : Good t) : Good (groundByte t c) := by
  unfold groundByte
  split
  · exact (keeps_control t c).good g
  split
  · exact (keeps_print t _).good g
  split
  · exact g
  split
  · exact good_of_need g.1 (by simp)
  split
  · exact good_of_need g.1 (by simp)
  split
  · exact good_of_need g.1 (by simp)
  · exact (keeps_print t _).good g

theorem good_ite {p : Prop} [Decidable p] {a b : State} (ha : Good a) (hb : Good b) :
    Good (if p then a else b) := by
  split
  · exact ha
  · exact hb

theorem good_nonUtf8Byte (t : State) (c : UInt8) (g : Good t) : Good (nonUtf8Byte t c) := by
  cases hp : t.parser <;> simp only [nonUtf8Byte, hp] <;> refine good_ite g (good_ite g ?_)
  · exact good_groundByte t c g
  · exact good_escape t c g
  · exact (keeps_escapeIntermediate t _ c).good g
  · exact (keeps_csiByte _ _ _ _ c).good g
  · exact (keeps_oscByte _ _ _ c).good g
  · exact g

theorem good_invalidSequence (t : State) (k : Nat) (h : 0 < t.cfg.cols) :
    Good (invalidSequence t k) := by
  unfold invalidSequence
  have g : Good { t with utf8Need := 0, utf8Seen := 0, utf8Cp := 0 } := ⟨h, fun _ => ⟨rfl, rfl⟩⟩
  generalize { t with utf8Need := 0, utf8Seen := 0, utf8Cp := 0 } = s at g
  induction k generalizing s with
  | zero => exact g
  | succ k ih => exact ih _ ((keeps_print s _).good g)

theorem good_step (t : State) (c : UInt8) (g : Good t) : Good (step t c) := by
  unfold step
  split
  · exact good_nonUtf8Byte t c g
  split
  · rename_i hn _
    dsimp only
    split
    · exact good_of_need g.1 (by simpa using hn)
    · split
      · exact (keeps_printCodePoint _ _).good ⟨g.1, fun _ => ⟨rfl, rfl⟩⟩
      · exact good_invalidSequence _ _ g.1
  · exact good_nonUtf8Byte _ c (good_invalidSequence t _ g.1)

theorem good_resize (t : State) (cols rows : Nat) (g : Good t) : Good (resize t cols rows) := by
  refine ⟨toUInt32_pos ?_ ?_, g.2⟩ <;> (try simp only [clampSize]) <;> omega

theorem good_clearReplies (t : State) (g : Good t) :
    Good (t.withAux fun a => { a with replies := .empty }) := g

end VerifiedKernel.Terminal
