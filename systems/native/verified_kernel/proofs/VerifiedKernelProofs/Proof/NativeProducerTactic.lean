module

public meta import Lean.Elab.Tactic.ElabTerm
public meta import VerifiedKernelProofs.Proof.WalkTactic

public section
namespace VerifiedKernel.Session.WorkConservation

elab "execution_head_is " h:ident requested:str : tactic => do
  let name ← executionHead h
  unless (Lean.privateToUserName name).toString == requested.getString do
    throwError "different execution head: {name}"

/-- The one declaration whose user name is `requested`, public or private to any loaded module.
It looks up each candidate name directly: listing every environment constant costs about half a
second per call. -/
meta def nativeDecl (requested : String) : Lean.CoreM Lean.Name := do
  let env ← Lean.getEnv
  let user := requested.toName
  let modules := env.allImportedModuleNames.push env.mainModule
  let candidates := (modules.map (Lean.mkPrivateNameCore · user)).push user |>.filter env.contains
  let #[name] := candidates | throwError "expected one native declaration for {requested}"
  return name

elab "native_decl% " requested:str : term => do
  return Lean.mkConst (← nativeDecl requested.getString)

elab "unfold_native " requested:str : tactic => do
  let id := Lean.mkIdent (← nativeDecl requested.getString)
  Lean.Elab.Tactic.evalTactic (← `(tactic| unfold $id:ident))

open Lean Elab Tactic Meta in
/-- Close the goal with the latest hypothesis of the same type. The goal is an equation whose left
side has a named head. Only hypotheses with the same head are unified with the goal, first without
unfolding definitions. `assumption` tries every hypothesis at default transparency, and a mismatch
can unfold a whole execution before it fails. -/
elab "head_assumption" : tactic => withMainContext do
  let goal ← getMainGoal
  let type ← instantiateMVars (← goal.getType)
  let some (_, lhs, _) := type.eq? | throwError "expected an equation"
  let .const head _ := (zetaHead lhs).getAppFn | throwError "expected a named head"
  let mut candidates := #[]
  for decl in (← getLCtx).decls.toArray.reverse do
    let some decl := decl | continue
    if decl.isImplementationDetail then continue
    let some (_, declLhs, _) := (← instantiateMVars decl.type).eq? | continue
    if (zetaHead declLhs).getAppFn.isConstOf head then candidates := candidates.push decl
  for mode in [TransparencyMode.instances, .default] do
    for decl in candidates do
      if ← withTransparency mode (isDefEq decl.type type) then
        goal.assign decl.toExpr
        replaceMainGoal []
        return
  throwError "no hypothesis of type{indentExpr type}"

/-- `hyp% T` is `‹T›` with `head_assumption` in place of `assumption`. -/
macro "hyp% " t:term : term => `(((by head_assumption) : $t))

end VerifiedKernel.Session.WorkConservation
