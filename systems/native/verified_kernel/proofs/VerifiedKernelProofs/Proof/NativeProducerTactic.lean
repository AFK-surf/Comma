module

public meta import Lean.Elab.Tactic.ElabTerm
public meta import VerifiedKernelProofs.Proof.WalkTactic

public section
namespace VerifiedKernel.Session.WorkConservation

elab "execution_head_is " h:ident requested:str : tactic => do
  let name ← executionHead h
  unless (Lean.privateToUserName name).toString == requested.getString do
    throwError "different execution head: {name}"

elab "native_decl% " requested:str : term => do
  let candidates := (← Lean.getEnv).constants.toList.filter fun (name, _) =>
    (Lean.privateToUserName name).toString == requested.getString
  let [(name, _)] := candidates | throwError "expected one native declaration for {requested}"
  return Lean.mkConst name

elab "unfold_native " requested:str : tactic => do
  let candidates := (← Lean.getEnv).constants.toList.filter fun (name, _) =>
    (Lean.privateToUserName name).toString == requested.getString
  let [(name, _)] := candidates | throwError "expected one native declaration for {requested}"
  let id := Lean.mkIdent name
  Lean.Elab.Tactic.evalTactic (← `(tactic| unfold $id:ident))

end VerifiedKernel.Session.WorkConservation
