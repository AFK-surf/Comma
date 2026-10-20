import VerifiedKernelProofs.Session.AppendOnly.Core
import VerifiedKernel.Provider.Request
import Lean.Elab.Tactic

/-!
Journal independence for host-free kernel computations.

A `KernelM` computation reads host answers only through `observe`. A computation
that never observes returns the same value for every journal and leaves the
journal unchanged. `Stateless` states this for successful runs. The provider
projection is stateless, so a proof can compare two runs of it that start
from different journals.
-/

namespace VerifiedKernel
open Data

set_option maxHeartbeats 4000000

/-- A successful run of `m` keeps its journal, and `m` returns the same value from every journal. -/
@[irreducible] def Stateless {α : Type} (m : KernelM α) : Prop :=
  ∀ (j r : List Term) (v : α), m j = .ok (v, r) → r = j ∧ ∀ j', m j' = .ok (v, j')

namespace Stateless

theorem run {α : Type} {m : KernelM α} (h : Stateless m) {j r : List Term} {v : α}
    (ok : m j = .ok (v, r)) (j' : List Term) : m j' = .ok (v, j') := by
  unfold Stateless at h; exact (h _ _ _ ok).2 j'

theorem keep {α : Type} {m : KernelM α} (h : Stateless m) {j r : List Term} {v : α}
    (ok : m j = .ok (v, r)) : r = j := by
  unfold Stateless at h; exact (h _ _ _ ok).1

theorem pure {α : Type} (x : α) : Stateless (Pure.pure x : KernelM α) := by
  unfold Stateless
  intro j r v h
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
  obtain ⟨rfl, rfl⟩ := h
  exact ⟨rfl, fun _ => rfl⟩

theorem bind {α β : Type} {m : KernelM α} {k : α → KernelM β}
    (hm : Stateless m) (hk : ∀ x, Stateless (k x)) : Stateless (m >>= k) := by
  unfold Stateless at hm hk ⊢
  intro j r v h
  obtain ⟨x, j₁, h₁, h₂⟩ := Session.bind_ok_iff.mp h
  obtain ⟨rfl, all₁⟩ := hm _ _ _ h₁
  obtain ⟨rfl, all₂⟩ := hk x _ _ _ h₂
  exact ⟨rfl, fun j' => Session.bind_ok_iff.mpr ⟨x, j', all₁ j', all₂ j'⟩⟩

theorem throw {α : Type} (e : Signal) : Stateless (MonadExcept.throw e : KernelM α) := by
  unfold Stateless
  intro j r v h
  cases h

theorem throwThe {α : Type} (e : Signal) : Stateless (throwThe Signal e : KernelM α) := by
  unfold Stateless
  intro j r v h
  cases h

theorem fail {α : Type} (kind : String) (args : List Term) : Stateless (VerifiedKernel.fail kind args : KernelM α) := by
  unfold Stateless
  intro j r v h
  cases h

theorem ite {α : Type} {c : Prop} [Decidable c] {t e : KernelM α}
    (ht : Stateless t) (he : Stateless e) : Stateless (if c then t else e) := by
  split <;> assumption

theorem dite {α : Type} {c : Prop} [Decidable c] {t : c → KernelM α} {e : ¬c → KernelM α}
    (ht : ∀ h, Stateless (t h)) (he : ∀ h, Stateless (e h)) : Stateless (if h : c then t h else e h) := by
  split
  · exact ht _
  · exact he _

theorem mapM {α β : Type} {f : α → KernelM β} (hf : ∀ x, Stateless (f x)) :
    ∀ xs : List α, Stateless (xs.mapM f)
  | [] => by rw [List.mapM_nil]; exact Stateless.pure _
  | x :: xs => by
    rw [List.mapM_cons]
    exact bind (hf x) fun y => bind (mapM hf xs) fun ys => Stateless.pure _

theorem foldlM {α β : Type} {f : β → α → KernelM β} (hf : ∀ acc x, Stateless (f acc x)) :
    ∀ (xs : List α) (init : β), Stateless (xs.foldlM f init)
  | [], init => by rw [List.foldlM_nil]; exact Stateless.pure _
  | x :: xs, init => by
    rw [List.foldlM_cons]
    exact bind (hf init x) fun acc => foldlM hf xs acc

theorem filterAuxM {α : Type} {p : α → KernelM Bool} (hp : ∀ x, Stateless (p x)) :
    ∀ (xs acc : List α), Stateless (List.filterAuxM p xs acc)
  | [], acc => by unfold List.filterAuxM; exact Stateless.pure _
  | x :: xs, acc => by
    unfold List.filterAuxM
    exact bind (hp x) fun b => filterAuxM hp xs _

theorem filterM {α : Type} {p : α → KernelM Bool} (hp : ∀ x, Stateless (p x)) (xs : List α) :
    Stateless (xs.filterM p) := by
  unfold List.filterM
  exact bind (filterAuxM hp xs []) fun acc => Stateless.pure _

theorem forIn {α β : Type} {f : α → β → KernelM (ForInStep β)} (hf : ∀ x acc, Stateless (f x acc)) :
    ∀ (xs : List α) (init : β), Stateless (ForIn.forIn xs init f)
  | [], init => by rw [List.forIn_nil]; exact Stateless.pure _
  | x :: xs, init => by
    rw [List.forIn_cons]
    refine bind (hf x init) fun step => ?_
    cases step with
    | done acc => exact Stateless.pure acc
    | yield acc => exact forIn hf xs acc

theorem forInRange {β : Type} {f : Nat → β → KernelM (ForInStep β)} (hf : ∀ x acc, Stateless (f x acc))
    (r : Std.Legacy.Range) (init : β) : Stateless (ForIn.forIn r init f) := by
  rw [Std.Legacy.Range.forIn_eq_forIn_range']
  exact forIn hf _ init

theorem anyM {α : Type} {p : α → KernelM Bool} (hp : ∀ x, Stateless (p x)) :
    ∀ xs : List α, Stateless (xs.anyM p)
  | [] => by simpa [List.anyM] using Stateless.pure false
  | x :: xs => by
    simp only [List.anyM]
    exact bind (hp x) fun b => by split <;> first | exact Stateless.pure _ | exact anyM hp xs

end Stateless

/-! ### The `stateless` tactic -/

open Lean Elab Tactic Meta in
/-- Unfolds the head constant of the action in a `Stateless` goal by its unfolding equation.
Private runtime helpers are unfolded too: the name is taken from the goal, not resolved
from syntax. A recursive helper is refused; it needs its own lemma. -/
def statelessUnfold (allowRec : Bool) : Lean.Elab.Tactic.TacticM Unit := open Lean Elab Tactic Meta in withMainContext do
  let goal ← instantiateMVars (← getMainTarget)
  let some m := (if goal.isAppOfArity ``Stateless 2 then some goal.appArg! else none)
    | throwError "stateless_unfold: expected a Stateless goal"
  let .const name _ := m.headBeta.getAppFn | throwError "stateless_unfold: no head constant"
  if [``Bind.bind, ``Pure.pure, ``ForIn.forIn, ``List.mapM, ``List.foldlM, ``List.filterM,
      ``List.anyM, ``ite, ``dite].contains name then
    throwError "stateless_unfold: structural head"
  let some eqn ← getUnfoldEqnFor? name (nonRec := true) | throwError "stateless_unfold: no equation"
  let type ← inferType (mkConst eqn ((← getConstInfo eqn).levelParams.map mkLevelParam))
  if !allowRec && (← forallTelescope type fun _ body => pure
      (body.appArg!.find? (fun e => e.isConstOf name)).isSome) then
    throwError "stateless_unfold: {name} is recursive"
  if allowRec then
    evalTactic (← `(tactic| rw [$(mkCIdent eqn):ident]; try dsimp only))
  else
    evalTactic (← `(tactic| rw [$(mkCIdent eqn):ident]))

elab "stateless_unfold" : tactic => statelessUnfold false
/-- Unfolds a recursive head once, for an induction step. -/
elab "stateless_unfold_rec" : tactic => statelessUnfold true

open Lean Elab Tactic Meta in
/-- One step on a `Stateless` goal, chosen by the head of its action. -/
elab "stateless_step" : tactic => withMainContext do
  let goal ← instantiateMVars (← getMainTarget)
  if !goal.isAppOfArity ``Stateless 2 then
    if goal.isForall then evalTactic (← `(tactic| intro _)); return
    throwError "stateless_step: not a Stateless goal"
  let m := goal.appArg!.consumeMData
  if m.isLet || m.headBeta != m then
    evalTactic (← `(tactic| dsimp only)); return
  let fn := m.getAppFn
  let run (t : TSyntax `tactic) : TacticM Unit := evalTactic t
  match fn with
  | .const name _ =>
    if name == ``Bind.bind then run (← `(tactic| refine Stateless.bind ?_ fun _ => ?_))
    else if name == ``Pure.pure then run (← `(tactic| exact Stateless.pure _))
    else if name == ``VerifiedKernel.fail then run (← `(tactic| exact Stateless.fail _ _))
    else if name == ``MonadExcept.throw then run (← `(tactic| exact Stateless.throw _))
    else if name == ``throwThe then run (← `(tactic| exact Stateless.throwThe _))
    else if name == ``ForIn.forIn then
      run (← `(tactic| first
        | refine Stateless.forIn (fun _ _ => ?_) _ _
        | refine Stateless.forInRange (fun _ _ => ?_) _ _))
    else if name == ``List.mapM then run (← `(tactic| refine Stateless.mapM (fun _ => ?_) _))
    else if name == ``List.foldlM then run (← `(tactic| refine Stateless.foldlM (fun _ _ => ?_) _ _))
    else if name == ``List.filterM then run (← `(tactic| refine Stateless.filterM (fun _ => ?_) _))
    else if name == ``List.anyM then run (← `(tactic| refine Stateless.anyM (fun _ => ?_) _))
    else if name == ``ite then run (← `(tactic| refine Stateless.ite ?_ ?_))
    else if name == ``dite then run (← `(tactic| refine Stateless.dite (fun _ => ?_) (fun _ => ?_)))
    else if (← isMatcher name) then run (← `(tactic| split))
    else if (← getEnv).contains (name ++ `stateless) then
      run (← `(tactic| apply $(mkCIdent (name ++ `stateless))))
    else statelessUnfold false
  | _ => throwError "stateless_step: no head constant"

/-- `stateless` closes `Stateless m` for a `do` block by structural rules, the lemma
`f.stateless` of a helper `f` when it exists, and unfolding of other non-recursive helpers. -/
syntax "stateless" : tactic
macro_rules
  | `(tactic| stateless) => `(tactic| repeat' stateless_step)

end VerifiedKernel

namespace VerifiedKernel
open Data

theorem Data.stringChars.stateless (v : Term) : Stateless (stringChars v) := by stateless
theorem Json.encode.stateless (value : Term) : Stateless (Json.encode value) := by
  unfold Json.encode
  generalize value.depth + 1 = fuel
  induction fuel generalizing value with
  | zero => stateless_unfold_rec; stateless
  | succ fuel ih => stateless_unfold_rec; stateless; all_goals exact ih _

end VerifiedKernel
