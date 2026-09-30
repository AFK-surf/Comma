module

public meta import Lean.Elab.Tactic.ElabTerm

/-!
Head guards for the reducer walks.

A walk hypothesis has the shape `f args… journal = .ok (next, rest)`. Every walk is a
`repeat' first` over alternatives, and each alternative used to discover whether it applied by
running `simp only`, `exact`, or unification against the whole hypothesis. On an unfolded
reducer body that costs one traversal per alternative per iteration, and the step alternatives
tried one lemma per reducer. These tactics read the head constant of the hypothesis once, so an
alternative that cannot apply fails before any rewriting, and the step lemma is selected by name
instead of by search.
-/

public section

namespace VerifiedKernel.Session

open Lean in
/-- The head of `e` after beta reduction and after the `let` and `have` binders that a reducer body
leaves in front of its next call. `simp only` reduces those binders before it matches, so the head
guards look through them the same way. -/
meta partial def zetaHead (e : Expr) : Expr :=
  let e := e.headBeta
  let args := e.getAppArgs
  match e.getAppFn with
  | .mdata _ inner => zetaHead (mkAppN inner args)
  | .letE _ _ value body _ => zetaHead (mkAppN (body.instantiate1 value) args)
  | .const ``letFun _ =>
    if h : args.size ≥ 4 then
      zetaHead (mkAppN (args[3].beta #[args[2]]) (args.extract 4 args.size))
    else e
  | _ => e

open Lean Elab Tactic in
/-- The constant at the head of the left-hand side of the execution equation `h`. -/
meta def executionHead (h : Ident) : TacticM Name := withMainContext do
  let decl ← (← getFVarId h).getDecl
  let some (_, lhs, _) := (← instantiateMVars decl.type).eq? | throwError "expected an execution equation"
  let .const name _ := (zetaHead lhs).getAppFn | throwError "expected a named execution head"
  return name

/-- `head_is h [f, g]` succeeds exactly when the equation `h` is headed by one of the named constants.
The names resolve in the current scope. -/
elab "head_is " h:ident " [" fns:ident,* "]" : tactic => do
  let name ← executionHead h
  for fn in fns.getElems do
    if (← Lean.resolveGlobalConstNoOverload fn) == name then return
  throwError "different execution head: {name}"

/-- `bind_head_is h [f, g]` succeeds exactly when the equation `h` is headed by a bind whose first
action is headed by one of the named constants, that is `h : (f … >>= k) s = .ok r`. -/
elab "bind_head_is " h:ident " [" fns:ident,* "]" : tactic => Lean.Elab.Tactic.withMainContext do
  let decl ← (← Lean.Elab.Tactic.getFVarId h).getDecl
  let some (_, lhs, _) := (← Lean.instantiateMVars decl.type).eq? | throwError "expected an execution equation"
  let lhs := zetaHead lhs
  let .const ``Bind.bind _ := lhs.getAppFn | throwError "expected a bind at the execution head"
  let args := lhs.getAppArgs
  unless args.size ≥ 5 do throwError "expected an applied bind"
  let .const name _ := (zetaHead args[4]!).getAppFn | throwError "expected a named action at the bind"
  for fn in fns.getElems do
    if (← Lean.resolveGlobalConstNoOverload fn) == name then return
  throwError "different bound action: {name}"

/-- `bind_field_is h "name"` succeeds exactly when the equation `h` is headed by a bind whose first
action is a `Data.field` read of the literal field `name`, that is `h : (field v "name" >>= k) s = .ok r`.
Comparing the literal here keeps a following `change` from unfolding the read value. -/
elab "bind_field_is " h:ident name:str : tactic => Lean.Elab.Tactic.withMainContext do
  let decl ← (← Lean.Elab.Tactic.getFVarId h).getDecl
  let some (_, lhs, _) := (← Lean.instantiateMVars decl.type).eq? | throwError "expected an execution equation"
  let lhs := zetaHead lhs
  let .const ``Bind.bind _ := lhs.getAppFn | throwError "expected a bind at the execution head"
  let args := lhs.getAppArgs
  unless args.size ≥ 5 do throwError "expected an applied bind"
  let action := zetaHead args[4]!
  let .const fn _ := action.getAppFn | throwError "expected a named action at the bind"
  unless fn == `VerifiedKernel.Data.field do throwError "expected a field read at the bind: {fn}"
  let fieldArgs := action.getAppArgs
  unless fieldArgs.size == 2 do throwError "expected an applied field read"
  let .lit (.strVal actual) := fieldArgs[1]! | throwError "expected a literal field name"
  unless actual == name.getString do throwError "different field: {actual}"

/-- `head_step h "_step"` rewrites `h` once with the lemma `<f>_step` for the reducer `f` at its head.
The lemma name resolves in the current scope, as the walk lemma lists did; the tactic fails without
rewriting when no such lemma exists. -/
elab "head_step " h:ident suffix:str : tactic => do
  let name ← executionHead h
  let lemma := Lean.mkIdent (Lean.Name.mkSimple (name.getString! ++ suffix.getString))
  let candidates := (← Lean.resolveGlobalName lemma.getId).filter (·.2.isEmpty)
  if candidates.isEmpty then throwError "no {lemma.getId} lemma for {name}"
  Lean.Elab.Tactic.evalTactic (← `(tactic| simp only [$lemma:ident] at $h:ident))

end VerifiedKernel.Session
