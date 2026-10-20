import VerifiedKernelProofs.Provider.MatchedCore
import VerifiedKernelProofs.Provider.Distinct

/-!
A history with answered, distinct call ids is matched.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

set_option maxHeartbeats 4000000

theorem callKey_ne_symm {x y : Term} (h : (CallKey.mk x == CallKey.mk y) = false) :
    (CallKey.mk y == CallKey.mk x) = false := by
  change (x == y && y == x) = false at h
  change (y == x && x == y) = false
  rw [Bool.and_comm]; exact h

/-! ### Distinct answered histories are matched -/

theorem eraseP_unique {l : List Term} {k : CallKey} {c : Term}
    (dist : l.Pairwise fun x y => (CallKey.mk x == CallKey.mk y) = false)
    (hc : c ∈ l.eraseP (fun x => CallKey.mk x == k)) (hk : (CallKey.mk c == k) = true) : False := by
  obtain ⟨x, l₁, l₂, hfirst, hx, rfl, he⟩ := List.exists_of_eraseP (p := fun x => CallKey.mk x == k) (List.mem_of_mem_eraseP hc) hk
  rw [he] at hc
  rw [List.pairwise_append, List.pairwise_cons] at dist
  rcases List.mem_append.mp hc with h₁ | h₂
  · exact absurd hk (by simpa using hfirst c h₁)
  · have := dist.2.1.1 c h₂
    rw [BEq.trans hx (BEq.symm hk)] at this
    cases this

theorem matched_of_distinct : ∀ (L st : List Term), Answered L →
    (st ++ L.flatMap callsOf).Pairwise (fun x y => (CallKey.mk x == CallKey.mk y) = false) →
    (∀ c ∈ st, ∃ r ∈ L, IsResult r ∧ c = callId r) → L.foldl openStep st = []
  | [], [], _, _, _ => rfl
  | [], c :: _, _, _, w => by
    obtain ⟨r, hr, -⟩ := w c (List.mem_cons_self ..)
    cases hr
  | m :: L, st, ⟨head, tail⟩, dist, w => by
    rw [List.foldl_cons]
    unfold openStep
    split
    · rename_i hres
      have nc : callsOf m = [] := callsOf_of_tool hres
      rw [List.flatMap_cons, nc, List.nil_append] at dist
      refine matched_of_distinct L _ tail ?_ ?_
      · exact dist.sublist ((List.eraseP_sublist).append (List.Sublist.refl _))
      · intro c hc
        obtain ⟨r, hr, res, rfl⟩ := w c (List.mem_of_mem_eraseP hc)
        rcases List.mem_cons.mp hr with rfl | hr
        · exact (eraseP_unique (List.pairwise_append.mp dist).1 hc BEq.rfl).elim
        · exact ⟨r, hr, res, rfl⟩
    · rename_i hres
      refine matched_of_distinct L _ tail ?_ ?_
      · rw [List.flatMap_cons] at dist
        have perm : ((callsOf m).reverse ++ st ++ L.flatMap callsOf).Perm (st ++ (callsOf m ++ L.flatMap callsOf)) := by
          rw [List.append_assoc]
          exact ((List.reverse_perm _).append_right _).trans (by
            simpa [List.append_assoc] using (List.perm_append_comm (l₁ := callsOf m) (l₂ := st)).append_right
              (L.flatMap callsOf))
        exact (List.Pairwise.perm dist perm.symm (fun h => callKey_ne_symm h))
      · intro c hc
        rcases List.mem_append.mp hc with hc | hc
        · exact head c (List.mem_reverse.mp hc)
        · obtain ⟨r, hr, res, e⟩ := w c hc
          rcases List.mem_cons.mp hr with rfl | hr
          · exact absurd res hres
          · exact ⟨r, hr, res, e⟩

/-- An answered history with distinct call ids is matched. -/
theorem Matched.of_distinct {L : List Term} (answered : Answered L) (distinct : DistinctCalls L) :
    Matched L :=
  matched_of_distinct L [] answered (by simpa [DistinctCalls] using distinct) (fun _ h => by cases h)

end VerifiedKernel.ProviderLoop
