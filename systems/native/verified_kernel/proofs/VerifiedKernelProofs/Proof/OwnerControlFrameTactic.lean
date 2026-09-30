module

public meta import Lean.Elab.Command
public meta import Lean.Elab.Tactic.ElabTerm
public meta import VerifiedKernelProofs.Proof.WalkTactic

public section

namespace VerifiedKernel.Session.WorkConservation

elab "unfold_execution_head " h:ident : tactic => Lean.Elab.Tactic.withMainContext do
  let decl ← (← Lean.Elab.Tactic.getFVarId h).getDecl
  let some (_, lhs, _) := decl.type.eq? | throwError "expected an execution equation"
  let .const fn _ := lhs.getAppFn | throwError "expected a named executable function"
  let name := Lean.mkIdent fn
  Lean.Elab.Tactic.evalTactic (← `(tactic| unfold $name:ident at $h:ident))

elab "owner_control_frame_step " h:ident : tactic => Lean.Elab.Tactic.withMainContext do
  let fn ← executionHead h
  let trans := Lean.mkIdent `VerifiedKernel.Session.WorkConservation.owner_control_frame_trans
  let writeStep := Lean.mkIdent `VerifiedKernel.Session.WorkConservation.write_owner_control_frame_step
  if fn == `VerifiedKernel.Data.write then
    Lean.Elab.Tactic.evalTactic (← `(tactic|
      (simp only [$writeStep:ident] at $h:ident; obtain ⟨_, kept⟩ := $h;
       refine $trans:ident (kept rfl) ?_)))
  else
    let lemma := Lean.mkIdent (`VerifiedKernel.Session.WorkConservation ++
      Lean.Name.mkSimple (fn.getString! ++ "_owner_control_frame_step"))
    unless (← Lean.getEnv).contains lemma.getId do throwError "no owner_control frame for this call"
    Lean.Elab.Tactic.evalTactic (← `(tactic|
      (simp only [$lemma:ident] at $h:ident; obtain ⟨_, kept⟩ := $h; refine $trans:ident kept ?_)))

syntax "owner_control_frame_walk" ident : tactic
macro_rules
  | `(tactic| owner_control_frame_walk $h:ident) => do
    let pureStep := Lean.mkIdent `VerifiedKernel.Session.pure_ok_iff
    let failStep := Lean.mkIdent `VerifiedKernel.Session.fail_ok_iff
    let bindStep := Lean.mkIdent `VerifiedKernel.Session.bind_ok
    let argumentError := Lean.mkIdent `VerifiedKernel.Session.argumentError
    let inspectedError := Lean.mkIdent `VerifiedKernel.Session.inspectedError
    let reflexive := Lean.mkIdent `VerifiedKernel.Session.WorkConservation.owner_control_frame_refl
    let get := Lean.mkIdent `VerifiedKernel.Term.get
    `(tactic| repeat' first
      | (head_is $h [Pure.pure]; simp only [$pureStep:ident] at $h:ident; cases $h:ident; exact $reflexive:ident _)
      | (head_is $h [$argumentError:ident, $inspectedError:ident, VerifiedKernel.fail]
         simp only [$argumentError:ident, $inspectedError:ident, $failStep:ident] at $h:ident)
      | (owner_control_frame_step $h; exact $reflexive:ident _)
      | split at $h:ident
      | (generalize $get:ident _ _ = discriminant at $h:ident; split at $h:ident)
      | (generalize List.filter _ _ = discriminant at $h:ident; split at $h:ident)
      | (generalize List.find? _ _ = discriminant at $h:ident; split at $h:ident)
      | (obtain ⟨_, $h:ident⟩ | ⟨_, $h:ident⟩ := ($h : _ ∨ _))
      | (obtain ⟨_, _, prior, $h:ident⟩ := $bindStep:ident $h
         first
           | (head_is prior [Pure.pure]; simp only [$pureStep:ident] at prior; cases prior)
           | owner_control_frame_step prior
           | (head_is prior [$argumentError:ident, $inspectedError:ident, VerifiedKernel.fail]
              simp only [$argumentError:ident, $inspectedError:ident, $failStep:ident] at prior)
           | skip)
      | dsimp only at $h:ident)

syntax "owner_control_rule " ident " (" ident+ ")" : command
elab_rules : command
  | `(owner_control_rule $fn:ident ($args:ident*)) => do
    let lemma := Lean.mkIdent (fn.getId.appendAfter "_owner_control_frame")
    let step := Lean.mkIdent (fn.getId.appendAfter "_owner_control_frame_step")
    let state := args[0]!
    let termType := Lean.mkIdent `VerifiedKernel.Term
    let frame := Lean.mkIdent `VerifiedKernel.Session.WorkConservation.OwnerControlFrame
    let stepIff := Lean.mkIdent `VerifiedKernel.Session.step_iff
    let binders ← args.mapM (fun arg => `(bracketedBinder| {$arg : $termType:ident}))
    let applied ← args.foldlM (fun acc arg => `(term| $acc $arg)) (← `(term| $fn))
    Lean.Elab.Command.elabCommand (← `(command|
      theorem $lemma $binders:bracketedBinder* {next : $termType:ident} {journal rest : List $termType:ident}
          (call : $applied journal = .ok (next, rest)) : $frame:ident $state next := by
        unfold $fn at call
        owner_control_frame_walk call))
    Lean.Elab.Command.elabCommand (← `(command|
      theorem $step $binders:bracketedBinder* {next : $termType:ident} {journal rest : List $termType:ident} :
          $applied journal = .ok (next, rest) ↔
            Except.ok (next, rest) = $applied journal ∧ $frame:ident $state next := $stepIff:ident $lemma))

end VerifiedKernel.Session.WorkConservation
