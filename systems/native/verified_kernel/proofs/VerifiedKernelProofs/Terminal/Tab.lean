import VerifiedKernelProofs.Terminal.Ascii

/-!
# Tabs

`feed` moves the cursor for HT with `tabFast`, which stops at the first tab
stop. `tabFast_eq` shows that it equals `tabForward t 1`, the loop that `step`
uses.
-/

namespace VerifiedKernel.Terminal

/-- One pass of `tabForward`'s inner loop over the columns `l`. -/
def tabScan (tabs : Array Bool) (l : List Nat) (s : Nat × Bool) : Nat × Bool :=
  Id.run (forIn l s fun i s =>
    if (!s.snd && tabs[i]!) = true then pure (ForInStep.yield (i, true))
    else pure (ForInStep.yield (s.fst, s.snd)))

theorem tabScan_found (tabs : Array Bool) (l : List Nat) (v : Nat) :
    tabScan tabs l (v, true) = (v, true) := by
  induction l with
  | nil => rfl
  | cons a l ih => simpa [tabScan] using ih

theorem tabScan_range (tabs : Array Bool) (cols a len fuel : Nat) (hlen : a + len = cols)
    (hfuel : len ≤ fuel) :
    (tabScan tabs (List.range' a len) (cols - 1, false)).fst = nextTab tabs cols a fuel := by
  induction len generalizing a fuel with
  | zero =>
    cases fuel <;> simp [tabScan, nextTab] <;> omega
  | succ len ih =>
    obtain ⟨f, rfl⟩ : ∃ f, fuel = f + 1 := ⟨fuel - 1, by omega⟩
    rw [List.range'_succ, nextTab, if_pos (by omega)]
    by_cases h : tabs[a]! = true
    · have := tabScan_found tabs (List.range' (a + 1) len) a
      simp only [tabScan] at this ⊢
      simp [h]
      simpa using congrArg Prod.fst this
    · have := ih (a + 1) f (by omega) (by omega)
      simp only [tabScan] at this ⊢
      simp [h]
      simpa using this

theorem tabFast_eq (t : State) : tabFast t = tabForward t 1 := by
  have hs : (tabScan t.tabs (List.range' (t.x.toNat + 1) (t.cols.toNat - (t.x.toNat + 1)))
      (t.cols.toNat - 1, false)).fst = nextTab t.tabs t.cols.toNat (t.x.toNat + 1) t.cols.toNat := by
    by_cases h : t.x.toNat + 1 ≤ t.cols.toNat
    · exact tabScan_range _ _ _ _ _ (by omega) (by omega)
    · rw [show t.cols.toNat - (t.x.toNat + 1) = 0 by omega]
      cases hc : t.cols.toNat <;> simp [tabScan, nextTab] <;> omega
  unfold tabFast tabForward
  simp only [Id.run, Std.Legacy.Range.forIn_eq_forIn_range']
  simp [Std.Legacy.Range.size]
  simp only [tabScan, Id.run] at hs
  simp at hs
  rw [← hs]
  rfl

end VerifiedKernel.Terminal
