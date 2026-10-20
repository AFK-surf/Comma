import VerifiedKernelProofs.Provider.TermRefl
import VerifiedKernelProofs.Provider.Eval

/-!
Anthropic adjacency: `adjacentAnthropic` only extends its result after a closed prefix, and the
tool-use ids it tracks as pending.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

set_option maxHeartbeats 4000000

/-- The tool-use ids of an Anthropic message. -/
def toolUseIds (m : Term) : List Term :=
  (items (get m "content")).filterMap fun c =>
    if (get c "type" == b "tool_use" && c.has (b "id")) = true then some (get c "id") else none

/-- The tool-use id that an Anthropic message answers, if its first block is a tool result. -/
def resultId (m : Term) : Term :=
  let first := (items (get m "content")).headD nil
  if (get first "type" == b "tool_result") = true then get first "tool_use_id" else nil

/-- The pending tool-use ids after one tagged message, as `adjacentAnthropic` tracks them. -/
def anthPendingStep (pending : List Term) (item : Bool × Term) : List Term :=
  let m := item.2
  let blocks := items (get m "content")
  let first := blocks.headD nil
  let isResult := get first "type" == b "tool_result"
  let id := if isResult = true then get first "tool_use_id" else nil
  if (id != nil && pending.contains id) = true then pending.filter (· != id)
  else if (!pending.isEmpty && !isResult && get m "role" != b "assistant") = true then pending
  else if (get m "role" == b "assistant") = true then toolUseIds m
  else []

/-- Every tool use of an assistant message has a later message that answers its id. -/
def AnthAnswered : List (Bool × Term) → Prop
  | [] => True
  | x :: L => ((get x.2 "role" == b "assistant") = true →
      ∀ c ∈ toolUseIds x.2, ∃ y ∈ L, (c == resultId y.2) = true) ∧ AnthAnswered L

/-- The loop state of `adjacentAnthropic`: emitted messages (reversed), held messages
(reversed), and pending tool-use ids. -/
abbrev AnthState := List (Bool × Term) × List (Bool × Term) × List Term

/-- Whether an Anthropic message's first block is a tool result. -/
def anthIsResult (m : Term) : Bool := get ((items (get m "content")).headD nil) "type" == b "tool_result"

/-- The loop answers a pending tool use. -/
def anthMatch (pending : List Term) (m : Term) : Bool := resultId m != nil && pending.contains (resultId m)

/-- The loop holds a message back behind pending tool uses. -/
def anthHold (pending : List Term) (m : Term) : Bool :=
  !pending.isEmpty && !anthIsResult m && get m "role" != b "assistant"

/-- Whether an Anthropic message is an assistant message. -/
def anthAssistant (m : Term) : Bool := get m "role" == b "assistant"

/-- One iteration of the `adjacentAnthropic` loop. -/
def anthStep (s : AnthState) (item : Bool × Term) : AnthState :=
  if anthMatch s.2.2 item.2 = true then (item :: s.1, s.2.1, s.2.2.filter (· != resultId item.2))
  else if anthHold s.2.2 item.2 = true then (s.1, item :: s.2.1, s.2.2)
  else (item :: (s.2.1 ++ s.1), [], if anthAssistant item.2 = true then toolUseIds item.2 else [])

theorem anthPendingStep_eq (pending : List Term) (item : Bool × Term) :
    anthPendingStep pending item =
      if anthMatch pending item.2 = true then pending.filter (· != resultId item.2)
      else if anthHold pending item.2 = true then pending
      else if anthAssistant item.2 = true then toolUseIds item.2 else [] := rfl

theorem forIn_id_yield {α σ : Type} (xs : List α) (f : α → σ → Id (ForInStep σ)) (g : σ → α → σ)
    (h : ∀ a s, f a s = pure (.yield (g s a))) (init : σ) : forIn xs init f = pure (xs.foldl g init) := by
  induction xs generalizing init with
  | nil => rfl
  | cons x xs ih => simp only [List.forIn_cons, h, List.foldl_cons]; exact ih _

theorem adjacentAnthropic_eq (xs : List (Bool × Term)) :
    adjacentAnthropic xs = (let s := xs.foldl anthStep ([], [], []); (s.2.1 ++ s.1).reverse) := by
  unfold adjacentAnthropic
  simp only [Id.run]
  rw [forIn_id_yield _ _ anthStep]
  · rfl
  · intro item s
    simp only [anthStep, apply_ite (fun x : AnthState => (pure (ForInStep.yield x) : Id (ForInStep AnthState)))]
    rfl

theorem anthStep_pending (s : AnthState) (item : Bool × Term) :
    (anthStep s item).2.2 = anthPendingStep s.2.2 item := by
  rw [anthPendingStep_eq, anthStep]
  split
  · rfl
  · split
    · rfl
    · split <;> rfl

theorem foldl_anthStep_pending (xs : List (Bool × Term)) (s : AnthState) :
    (xs.foldl anthStep s).2.2 = xs.foldl anthPendingStep s.2.2 := by
  induction xs generalizing s with
  | nil => rfl
  | cons x xs ih => simp only [List.foldl_cons, ih, anthStep_pending]

theorem anthStep_out (s : AnthState) (item : Bool × Term) : ∃ w, (anthStep s item).1 = w ++ s.1 := by
  unfold anthStep
  split
  · exact ⟨[item], rfl⟩
  · split
    · exact ⟨[], rfl⟩
    · exact ⟨item :: s.2.1, rfl⟩

theorem foldl_anthStep_out (xs : List (Bool × Term)) (s : AnthState) :
    ∃ w, (xs.foldl anthStep s).1 = w ++ s.1 := by
  induction xs generalizing s with
  | nil => exact ⟨[], rfl⟩
  | cons x xs ih =>
    obtain ⟨w₁, h₁⟩ := anthStep_out s x
    obtain ⟨w₂, h₂⟩ := ih (anthStep s x)
    exact ⟨w₂ ++ w₁, by simp only [List.foldl_cons, h₂, h₁, List.append_assoc]⟩

theorem anthStep_closed (s : AnthState) (item : Bool × Term) (h : s.2.2 = []) :
    (anthStep s item).1 = item :: (s.2.1 ++ s.1) := by
  obtain ⟨out, held, pending⟩ := s
  simp only at h
  subst h
  simp [anthStep, anthMatch, anthHold]

theorem anthMatch_of_nil {P : List Term} (hP : ∀ c ∈ P, c = nil) (m : Term) : anthMatch P m = false := by
  unfold anthMatch
  by_cases hid : (resultId m == nil) = true
  · simp [bne, hid]
  · have : P.contains (resultId m) = false := by
      induction P with
      | nil => rfl
      | cons c P ih =>
        rw [hP c (List.mem_cons_self ..)] at *
        simp only [List.contains_cons, Bool.or_eq_false_iff]
        exact ⟨by simpa using hid, ih (fun d hd => hP d (List.mem_cons_of_mem _ hd))⟩
    simp [this]

/-- The loop invariant after a state `s₀` whose pending ids are all `nil`: either nothing has been
emitted yet, the held messages extend those of `s₀` and every pending id is still `nil`, or the
emitted messages extend `held₀ ++ out₀`. -/
def AnthExtends (s₀ s : AnthState) : Prop :=
  (∃ w, s.1 = w ++ (s₀.2.1 ++ s₀.1)) ∨
    (s.1 = s₀.1 ∧ (∃ w, s.2.1 = w ++ s₀.2.1) ∧ ∀ c ∈ s.2.2, c = nil)

theorem AnthExtends.step {s₀ s : AnthState} (h : AnthExtends s₀ s) (item : Bool × Term) :
    AnthExtends s₀ (anthStep s item) := by
  rcases h with ⟨w, hw⟩ | ⟨hout, ⟨w, hw⟩, hP⟩
  · obtain ⟨v, hv⟩ := anthStep_out s item
    exact .inl ⟨v ++ w, by rw [hv, hw, List.append_assoc]⟩
  · unfold anthStep
    rw [if_neg (by simp [anthMatch_of_nil hP])]
    split
    · exact .inr ⟨hout, ⟨item :: w, by simp [hw]⟩, hP⟩
    · exact .inl ⟨item :: w, by simp [hw, hout]⟩

theorem AnthExtends.foldl {s₀ s : AnthState} (h : AnthExtends s₀ s) (ys : List (Bool × Term)) :
    AnthExtends s₀ (ys.foldl anthStep s) := by
  induction ys generalizing s with
  | nil => exact h
  | cons y ys ih => exact ih (h.step y)

theorem AnthExtends.result {s₀ s : AnthState} (h : AnthExtends s₀ s) :
    ∃ zs, (s.2.1 ++ s.1).reverse = (s₀.2.1 ++ s₀.1).reverse ++ zs := by
  rcases h with ⟨w, hw⟩ | ⟨hout, ⟨w, hw⟩, _⟩
  · exact ⟨(s.2.1 ++ w).reverse, by simp [hw]⟩
  · exact ⟨w.reverse, by simp [hw, hout]⟩

/-- After a list whose pending tool-use ids are all `nil`, `adjacentAnthropic` of an extension
extends its result. -/
theorem adjacentAnthropic_append (xs ys : List (Bool × Term))
    (closed : ∀ c ∈ xs.foldl anthPendingStep [], c = nil) :
    ∃ zs, adjacentAnthropic (xs ++ ys) = adjacentAnthropic xs ++ zs := by
  rw [adjacentAnthropic_eq, adjacentAnthropic_eq]
  generalize hs : xs.foldl anthStep ([], [], []) = s
  have hp : ∀ c ∈ s.2.2, c = nil := by rw [← hs, foldl_anthStep_pending]; exact closed
  have start : AnthExtends s s := .inr ⟨rfl, ⟨[], rfl⟩, hp⟩
  simp only [List.foldl_append, hs]
  exact (start.foldl ys).result

theorem resultId_of_not_result {m : Term} (h : anthIsResult m = false) : resultId m = nil := by
  show (if anthIsResult m = true then get ((items (get m "content")).headD nil) "tool_use_id" else nil) = nil
  rw [if_neg (by simp [h])]

theorem nil_of_beq {c : Term} (h : (c == nil) = true) : c = nil := by
  cases c <;> simp_all [BEq.beq, nil, a]

/-- `anthPending_closed`, generalized over the initial pending ids: each pending id is `nil` or has
an answering message in the rest of the list. -/
theorem anthPending_nil_from : ∀ (L : List (Bool × Term)) (P : List Term), AnthAnswered L →
    (∀ c ∈ P, c = nil ∨ ∃ y ∈ L, (c == resultId y.2) = true) → ∀ c ∈ L.foldl anthPendingStep P, c = nil
  | [], P, _, hP => by
    intro c hc
    rcases hP c hc with h | ⟨y, hy, _⟩
    · exact h
    · cases hy
  | x :: L, P, ⟨hx, hL⟩, hP => by
    rw [List.foldl_cons]
    refine anthPending_nil_from L _ hL ?_
    intro c hc
    rw [anthPendingStep_eq] at hc
    split at hc
    · obtain ⟨hcP, hne⟩ := List.mem_filter.mp hc
      rcases hP c hcP with hcn | ⟨y, hy, hyc⟩
      · exact .inl hcn
      rcases List.mem_cons.mp hy with rfl | hy
      · simp [bne, hyc] at hne
      · exact .inr ⟨y, hy, hyc⟩
    · split at hc
      · rename_i hold
        rcases hP c hc with hcn | ⟨y, hy, hyc⟩
        · exact .inl hcn
        rcases List.mem_cons.mp hy with rfl | hy
        · simp only [anthHold, Bool.and_eq_true, Bool.not_eq_true'] at hold
          rw [resultId_of_not_result hold.1.2] at hyc
          exact .inl (nil_of_beq hyc)
        · exact .inr ⟨y, hy, hyc⟩
      · split at hc
        · rename_i assistant
          exact .inr (hx assistant c hc)
        · cases hc

/-- A list whose tool uses are all answered leaves no pending id other than `nil`. -/
theorem anthPending_closed (xs : List (Bool × Term)) (h : AnthAnswered xs) :
    ∀ c ∈ xs.foldl anthPendingStep [], c = nil :=
  anthPending_nil_from xs [] h (fun _ hc => by cases hc)

end VerifiedKernel.ProviderLoop
