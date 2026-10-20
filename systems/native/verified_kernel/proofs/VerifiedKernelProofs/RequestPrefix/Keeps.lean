import VerifiedKernelProofs.RequestPrefix.Stateless

/-!
Computations that leave a stable journal unchanged.

A journal is stable when every successful observation on it leaves it unchanged, as a journal
of answered-ahead host entries does. A kernel computation changes its journal only through
`observe`, so on a stable journal it keeps the journal. `Keeps m` states this for `m`; the
`keeps` tactic proves it structurally, like `stateless`.
-/

namespace VerifiedKernel
open Data

set_option maxHeartbeats 4000000

/-- Every successful observation on `J` leaves `J` unchanged. -/
def StableJournal (J : List Term) : Prop := ∀ r v J', observe r J = .ok (v, J') → J' = J

/-- A successful run of `m` on a stable journal leaves the journal unchanged. -/
@[irreducible] def Keeps {α : Type} (m : KernelM α) : Prop :=
  ∀ (J : List Term) (v : α) (J' : List Term), StableJournal J → m J = .ok (v, J') → J' = J

namespace Keeps

theorem run {α : Type} {m : KernelM α} (h : Keeps m) {J J' : List Term} {v : α} (hJ : StableJournal J)
    (ok : m J = .ok (v, J')) : J' = J := by
  unfold Keeps at h; exact h _ _ _ hJ ok

theorem of_stateless {α : Type} {m : KernelM α} (h : Stateless m) : Keeps m := by
  unfold Keeps; intro J v J' _ ok; exact h.keep ok

theorem pure {α : Type} (x : α) : Keeps (Pure.pure x : KernelM α) := of_stateless (Stateless.pure x)

theorem bind {α β : Type} {m : KernelM α} {k : α → KernelM β} (hm : Keeps m) (hk : ∀ x, Keeps (k x)) :
    Keeps (m >>= k) := by
  unfold Keeps at hm hk ⊢
  intro J v J' hJ h
  obtain ⟨x, J₁, h₁, h₂⟩ := Session.bind_ok_iff.mp h
  obtain rfl := hm _ _ _ hJ h₁
  exact hk x _ _ _ hJ h₂

theorem observe (r : Term) : Keeps (VerifiedKernel.observe r) := by
  unfold Keeps; intro J v J' hJ h; exact hJ r v J' h

theorem ite {α : Type} {c : Prop} [Decidable c] {t e : KernelM α} (ht : Keeps t) (he : Keeps e) :
    Keeps (if c then t else e) := by
  split <;> assumption

theorem dite {α : Type} {c : Prop} [Decidable c] {t : c → KernelM α} {e : ¬c → KernelM α}
    (ht : ∀ h, Keeps (t h)) (he : ∀ h, Keeps (e h)) : Keeps (if h : c then t h else e h) := by
  split
  · exact ht _
  · exact he _

theorem mapM {α β : Type} {f : α → KernelM β} (hf : ∀ x, Keeps (f x)) :
    ∀ xs : List α, Keeps (xs.mapM f)
  | [] => by rw [List.mapM_nil]; exact Keeps.pure _
  | x :: xs => by
    rw [List.mapM_cons]
    exact bind (hf x) fun y => bind (mapM hf xs) fun ys => Keeps.pure _

theorem foldlM {α β : Type} {f : β → α → KernelM β} (hf : ∀ acc x, Keeps (f acc x)) :
    ∀ (xs : List α) (init : β), Keeps (xs.foldlM f init)
  | [], init => by rw [List.foldlM_nil]; exact Keeps.pure _
  | x :: xs, init => by
    rw [List.foldlM_cons]
    exact bind (hf init x) fun acc => foldlM hf xs acc

theorem filterAuxM {α : Type} {p : α → KernelM Bool} (hp : ∀ x, Keeps (p x)) :
    ∀ (xs acc : List α), Keeps (List.filterAuxM p xs acc)
  | [], acc => by unfold List.filterAuxM; exact Keeps.pure _
  | x :: xs, acc => by
    unfold List.filterAuxM
    exact bind (hp x) fun b => filterAuxM hp xs _

theorem filterM {α : Type} {p : α → KernelM Bool} (hp : ∀ x, Keeps (p x)) (xs : List α) :
    Keeps (xs.filterM p) := by
  unfold List.filterM
  exact bind (filterAuxM hp xs []) fun acc => Keeps.pure _

theorem forIn {α β : Type} {f : α → β → KernelM (ForInStep β)} (hf : ∀ x acc, Keeps (f x acc)) :
    ∀ (xs : List α) (init : β), Keeps (ForIn.forIn xs init f)
  | [], init => by rw [List.forIn_nil]; exact Keeps.pure _
  | x :: xs, init => by
    rw [List.forIn_cons]
    refine bind (hf x init) fun step => ?_
    cases step with
    | done acc => exact Keeps.pure acc
    | yield acc => exact forIn hf xs acc

theorem forInRange {β : Type} {f : Nat → β → KernelM (ForInStep β)} (hf : ∀ x acc, Keeps (f x acc))
    (r : Std.Legacy.Range) (init : β) : Keeps (ForIn.forIn r init f) := by
  rw [Std.Legacy.Range.forIn_eq_forIn_range']
  exact forIn hf _ init

theorem anyM {α : Type} {p : α → KernelM Bool} (hp : ∀ x, Keeps (p x)) :
    ∀ xs : List α, Keeps (xs.anyM p)
  | [] => by simpa [List.anyM] using Keeps.pure false
  | x :: xs => by
    simp only [List.anyM]
    exact bind (hp x) fun b => by split <;> first | exact Keeps.pure _ | exact anyM hp xs

theorem get : Keeps (MonadState.get : KernelM (List Term)) := by
  unfold Keeps; intro J v J' _ h
  simp only [MonadState.get, getThe, MonadStateOf.get, StateT.get, Pure.pure, Except.pure] at h
  cases h; rfl

end Keeps

open Lean Elab Tactic Meta in
/-- One step on a `Keeps` goal, chosen by the head of its action: structural rules, `observe`,
the lemma `f.keeps` or `f.stateless` of a helper `f`, or unfolding a non-recursive helper. -/
elab "keeps_step" : tactic => withMainContext do
  let goal := (← instantiateMVars (← getMainTarget)).consumeMData
  if goal.isAppOfArity ``Stateless 2 then
    evalTactic (← `(tactic| stateless_step)); return
  if !goal.isAppOfArity ``Keeps 2 then
    if goal.isForall then evalTactic (← `(tactic| intro _)); return
    throwError "keeps_step: not a Keeps goal"
  let m := goal.appArg!.consumeMData
  if m.isLet || m.headBeta != m then
    evalTactic (← `(tactic| dsimp only)); return
  -- A local `Keeps` fact that closes the goal by `apply` comes first.
  for ldecl in (← getLCtx) do
    if ldecl.isImplementationDetail then continue
    let isKeeps ← forallTelescopeReducing (← instantiateMVars ldecl.type) fun _ body =>
      pure (body.isAppOfArity ``Keeps 2)
    if isKeeps then
      let saved ← saveState
      try
        let goals ← withReducible <| (← getMainGoal).apply (mkFVar ldecl.fvarId)
        if goals.isEmpty then replaceMainGoal []; return
        saved.restore
      catch _ => saved.restore
  let fn := m.getAppFn
  if fn.isProj || fn.isConstOf ``MonadState.get || fn.isConstOf ``MonadStateOf.get || fn.isConstOf ``getThe then
    if (← observing? (evalTactic (← `(tactic| exact Keeps.get)))).isSome then return
  let run (t : TSyntax `tactic) : TacticM Unit := evalTactic t
  match fn with
  | .const name _ =>
    if name == ``Bind.bind then run (← `(tactic| refine Keeps.bind ?_ fun _ => ?_))
    else if name == ``Pure.pure then run (← `(tactic| exact Keeps.pure _))
    else if name == ``VerifiedKernel.observe then run (← `(tactic| exact Keeps.observe _))
    else if name == ``VerifiedKernel.fail then run (← `(tactic| exact Keeps.of_stateless (Stateless.fail _ _)))
    else if name == ``MonadExcept.throw then run (← `(tactic| exact Keeps.of_stateless (Stateless.throw _)))
    else if name == ``throwThe then run (← `(tactic| exact Keeps.of_stateless (Stateless.throwThe _)))
    else if name == ``ForIn.forIn then
      run (← `(tactic| first
        | refine Keeps.forIn (fun _ _ => ?_) _ _
        | refine Keeps.forInRange (fun _ _ => ?_) _ _))
    else if name == ``List.mapM then run (← `(tactic| refine Keeps.mapM (fun _ => ?_) _))
    else if name == ``List.foldlM then run (← `(tactic| refine Keeps.foldlM (fun _ _ => ?_) _ _))
    else if name == ``List.filterM then run (← `(tactic| refine Keeps.filterM (fun _ => ?_) _))
    else if name == ``List.anyM then run (← `(tactic| refine Keeps.anyM (fun _ => ?_) _))
    else if name == ``ite then run (← `(tactic| refine Keeps.ite ?_ ?_))
    else if name == ``dite then run (← `(tactic| refine Keeps.dite (fun _ => ?_) (fun _ => ?_)))
    else if (← isMatcher name) then run (← `(tactic| split))
    else if (← getEnv).contains (name ++ `keeps) && (← Term.getDeclName?) != some (name ++ `keeps) then
      run (← `(tactic| apply $(mkCIdent (name ++ `keeps))))
    else if (← getEnv).contains (name ++ `stateless) then
      run (← `(tactic| (refine Keeps.of_stateless ?_; apply $(mkCIdent (name ++ `stateless)))))
    else
      let some eqn ← getUnfoldEqnFor? name (nonRec := true) | throwError "keeps_step: no equation"
      let type ← inferType (mkConst eqn ((← getConstInfo eqn).levelParams.map mkLevelParam))
      if (← forallTelescope type fun _ body => pure
          (body.appArg!.find? (fun e => e.isConstOf name)).isSome) then
        throwError "keeps_step: {name} is recursive"
      run (← `(tactic| rw [$(mkCIdent eqn):ident]))
  | _ => throwError "keeps_step: no head constant"

/-- `keeps` closes `Keeps m` structurally. -/
syntax "keeps" : tactic
macro_rules
  | `(tactic| keeps) => `(tactic| repeat' keeps_step)

end VerifiedKernel
