import VerifiedKernelProofs.Provider.SyntheticRuntime

/-!
A closed history leaves no call pending in the `syntheticRuntime` loop.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

theorem role_text {m : Term} {s : String} (h : (openaiRole m == b s) = true) : openaiRole m = b s := text_beq_eq h

theorem runtimeBranch_inert {r : Bool} {m : Term} (h : runtimeBranch r m = true) : Inert m := by
  unfold runtimeBranch at h
  simp only [Bool.and_eq_true] at h
  obtain ⟨s, hs, eq⟩ := List.any_eq_true.mp h.1
  have role := text_beq_eq eq
  unfold Inert callsOf IsResult
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hs
  rw [role]
  rcases hs with rfl | rfl | rfl <;> simp (config := {decide := true}) [text_beq_text]

theorem pending_closed (r : Bool) : ∀ {L p : List Term}, AnsweredEq L →
    (∀ x ∈ p, ∃ y ∈ L, IsResult y ∧ (x == callId y) = true) → L.foldl (pendingStep r) p = []
  | [], p, _, hp => by
    cases p with
    | nil => rfl
    | cons x p => obtain ⟨y, mem, -⟩ := hp x (List.mem_cons_self ..); simp at mem
  | m :: L, p, ⟨head, tail⟩, hp => by
    simp only [List.foldl_cons]
    apply pending_closed r tail
    unfold pendingStep
    split
    · rename_i hb
      intro x hx
      obtain ⟨y, mem, res, eq⟩ := hp x hx
      rcases List.mem_cons.mp mem with rfl | mem
      · exact absurd res (runtimeBranch_inert hb).2
      · exact ⟨y, mem, res, eq⟩
    · split
      · intro x hx
        obtain ⟨hx, keep⟩ := List.mem_filter.mp hx
        obtain ⟨y, mem, res, eq⟩ := hp x hx
        rcases List.mem_cons.mp mem with rfl | mem
        · simp [bne, eq] at keep
        · exact ⟨y, mem, res, eq⟩
      · split
        · rename_i _ ha
          intro x hx
          exact head x (by unfold callsOf; rw [if_pos ha]; exact hx)
        · rename_i ht _
          intro x hx
          obtain ⟨y, mem, res, eq⟩ := hp x hx
          rcases List.mem_cons.mp mem with rfl | mem
          · exact absurd res ht
          · exact ⟨y, mem, res, eq⟩

theorem answered_closed {H : List Term} (r : Bool) (h : AnsweredEq H) :
    (loopPart H).foldl (pendingStep r) [] = [] := by
  apply pending_closed r _ (by simp)
  unfold loopPart
  exact h.drop_takeWhile

/-- A matched history leaves no call pending in the `syntheticRuntime` loop. -/
theorem matched_closed {H : List Term} (r : Bool) (h : Matched H) :
    (loopPart H).foldl (pendingStep r) [] = [] := answered_closed r h.answeredEq

end VerifiedKernel.ProviderLoop
