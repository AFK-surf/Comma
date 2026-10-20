import VerifiedKernelProofs.Provider.SyntheticRuntime
import VerifiedKernelProofs.Provider.Eval

/-!
The Responses projection keeps the projection of a closed history as a prefix of its input.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

set_option maxHeartbeats 4000000

theorem drop_append_of_le {α : Type} {n : Nat} {xs ys : List α} (h : n ≤ xs.length) :
    (xs ++ ys).drop n = xs.drop n ++ ys := List.drop_append_of_le_length h

/-- `historicalTools` as a recursion: the item, then the rest with the unsafe ids so far. -/
def historicalRun (unsafeIds : List Term) : List Term → KernelM (List Term)
  | [] => pure []
  | item :: rest => do
    let type := get item "type"
    let unsafeCall := type == b "function_call" && !toolName (get item "name")
    let unsafeIds := if unsafeCall then get item "call_id" :: unsafeIds else unsafeIds
    let item ← if unsafeCall || (type == b "function_call_output" && unsafeIds.contains (get item "call_id"))
      then historicalRecord item else pure item
    return item :: (← historicalRun unsafeIds rest)

theorem historicalRun.stateless : ∀ (unsafeIds items : List Term), Stateless (historicalRun unsafeIds items)
  | _, [] => by rw [historicalRun]; exact Stateless.pure _
  | u, item :: rest => by
    rw [historicalRun]
    dsimp only
    refine Stateless.ite ?_ ?_ <;> refine Stateless.bind (by stateless) fun _ =>
      Stateless.bind (historicalRun.stateless _ rest) fun _ => Stateless.pure _

/-- The unsafe call ids after `historicalTools` reads `items`. -/
def unsafeAfter (u : List Term) : List Term → List Term
  | [] => u
  | item :: rest => unsafeAfter
    (if (get item "type" == b "function_call" && !toolName (get item "name")) = true then get item "call_id" :: u else u)
    rest

/-- `historicalTools` decides each item from the items before it, so its output for `A ++ B`
is its output for `A` followed by an output for `B`. -/
theorem historicalRun_append : ∀ (u A B : List Term), historicalRun u (A ++ B) =
    (do let x ← historicalRun u A; let y ← historicalRun (unsafeAfter u A) B; pure (x ++ y))
  | u, [], B => by simp [historicalRun, unsafeAfter]
  | u, item :: A, B => by
    simp only [List.cons_append, historicalRun, unsafeAfter, historicalRun_append _ A B]
    split <;> split <;> simp [bind_assoc] <;> rfl

theorem foldlM_historicalStep : ∀ (items u acc : List Term), items.foldlM historicalStep (u, acc) =
    (do let v ← historicalRun u items; pure (unsafeAfter u items, v.reverse ++ acc))
  | [], u, acc => by simp [historicalRun, unsafeAfter]
  | item :: items, u, acc => by
    simp only [List.foldlM_cons, historicalStep, historicalRun, unsafeAfter, bind_assoc]
    split <;> split <;> simp [bind_assoc, foldlM_historicalStep]

theorem historicalTools_eq (items : List Term) : historicalTools items = historicalRun [] items := by
  unfold historicalTools
  rw [foldlM_historicalStep]
  simp

/-- **Responses prefix.** The Responses input of a closed history with a conversation turn is a
prefix of the input for that history followed by more messages, and both requests
send the same instructions. -/
theorem responsesParts_append {H X : List Term} {v₀ v₁ : Term} {j₀ j₁ k₀ k₁ : List Term}
    (turn : ∃ m ∈ H, TurnRole m) (closed : (loopPart H).foldl (pendingStep false) [] = [])
    (h₀ : responsesParts H j₀ = .ok (v₀, k₀)) (h₁ : responsesParts (H ++ X) j₁ = .ok (v₁, k₁)) :
    ∃ in₀ in₁ instr, v₀ = .tuple [list in₀, instr] ∧ v₁ = .tuple [list in₁, instr] ∧ in₀ <+: in₁ := by
  unfold responsesParts at h₀ h₁
  simp only [Session.bind_ok_iff] at h₀ h₁
  obtain ⟨s₀, ja, hs₀, t₀, jb, ht₀, i₀, jc, hi₀, r₀, jd, hr₀, fin₀⟩ := h₀
  obtain ⟨s₁, ja', hs₁, t₁, jb', ht₁, i₁, jc', hi₁, r₁, jd', hr₁, fin₁⟩ := h₁
  -- The synthetic-runtime pass keeps the history's projection as a prefix.
  obtain ⟨vH, T, jH, hsynH, rfl, ⟨m, mvH, role⟩, -, -⟩ := syntheticRuntime_append turn closed hs₁
  have := (syntheticRuntime.stateless H false false).same hs₀ hsynH
  subst this
  -- The leading system run is the history's.
  have leadStop : ∃ x ∈ s₀, (fun m => member (openaiRole m) ["system", "summary"]) x = false :=
    ⟨m, mvH, by rcases role with h | h <;> simp only [h] <;> decide⟩
  rw [takeWhile_append_of_false leadStop] at ht₁ hi₁
  have texts := (Stateless.mapM (fun _ => by stateless) _).same ht₀ ht₁
  subst texts
  rw [drop_append_of_le (takeWhile_length_le _ _)] at hi₁
  obtain ⟨iH, iT, jf, hiH, hiT, rfl⟩ := mapM_append_ok hi₁
  have := (Stateless.mapM (fun _ => by stateless) _).same hi₀ hiH
  subst this
  -- Each historical record depends only on earlier items.
  rw [historicalTools_eq] at hr₀ hr₁
  rw [List.flatten_append, historicalRun_append] at hr₁
  obtain ⟨rH, j₇, hrH, hr₁⟩ := Session.bind_ok_iff.mp hr₁
  obtain ⟨rT, jg, hrT, hr₁⟩ := Session.bind_ok_iff.mp hr₁
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at hr₁
  obtain ⟨rfl, rfl⟩ := hr₁
  have := (historicalRun.stateless _ _).same hr₀ hrH
  subst this
  split at fin₀ <;> split at fin₁ <;> (try contradiction)
  · simp only [Session.bind_ok_iff, Session.pure_ok_iff, Prod.mk.injEq] at fin₀ fin₁
    obtain ⟨_, _, ⟨rfl, rfl⟩, rfl, rfl⟩ := fin₀
    obtain ⟨_, _, ⟨rfl, rfl⟩, rfl, rfl⟩ := fin₁
    exact ⟨_, _, _, rfl, rfl, ⟨rT, by simp⟩⟩
  · obtain ⟨n₀, _, hn₀, fin₀⟩ := Session.bind_ok_iff.mp fin₀
    obtain ⟨n₁, _, hn₁, fin₁⟩ := Session.bind_ok_iff.mp fin₁
    have := (Provider.join.stateless _ _).same hn₀ hn₁
    subst this
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at fin₀ fin₁
    rw [fin₀.1, fin₁.1]
    exact ⟨_, _, _, rfl, rfl, ⟨rT, by simp⟩⟩

end VerifiedKernel.ProviderLoop
