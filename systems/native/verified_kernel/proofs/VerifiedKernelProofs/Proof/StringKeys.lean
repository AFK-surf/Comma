module

public meta import Lean.Elab.Tactic.ElabTerm

/-!
Cheap proofs that a literal key list does not contain a key.

The frame lemmas need `entries.all (fun e => e.1 != key) = true` for the literal entries of a
`write`. Proved by `rfl`, the elaborator and the kernel both evaluate `String.decEq`, which
compares the UTF-8 encodings of both strings byte by byte through `UInt8` and `BitVec`. That
costs about 10 ms per pair in each checker. `keys_absent` compares the keys as `List Char`
instead: the kernel unfolds a string literal to `String.ofList` of its characters, and it
compares characters as `Nat` literals.
-/

public section

namespace VerifiedKernel.Session

theorem string_ofList_bne {l m : List Char} (h : (l == m) = false) :
    (String.ofList l != String.ofList m) = true := by
  have different : String.ofList l ≠ String.ofList m := fun same => by
    rw [String.ofList_inj] at same
    subst same
    simp at h
  simpa [bne] using different

theorem string_ofList_ne {l m : List Char} (h : (l == m) = false) :
    String.ofList l ≠ String.ofList m := fun same => by
  rw [String.ofList_inj] at same
  subst same
  simp at h

theorem bool_and_true {x y : Bool} (left : x = true) (right : y = true) : (x && y) = true := by
  simp [left, right]

theorem list_all_cons_true {α : Type} {p : α → Bool} {x : α} {xs : List α}
    (head : p x = true) (tail : xs.all p = true) : (x :: xs).all p = true := by
  simp [List.all_cons, head, tail]

open Lean Meta Elab Tactic

/-- The literal text of a string literal. -/
meta def stringLiteral? (e : Expr) : Option String :=
  match e.consumeMData with
  | .lit (.strVal text) => some text
  | _ => none

/-- A proof of `body = true`, where `body` is a conjunction of `name != key` with literal keys. -/
meta partial def keysDifferProof (name : String) (body : Expr) : MetaM Expr := do
  match_expr body with
  | and left right =>
    return mkApp4 (mkConst ``bool_and_true) left right (← keysDifferProof name left)
      (← keysDifferProof name right)
  | bne _ _ _ key =>
    let some text := stringLiteral? key | throwError "keys_absent: key is not a string literal"
    if name == text then throwError "keys_absent: key {text} is present"
    let chars (s : String) : Expr := toExpr s.toList
    return mkApp3 (mkConst ``string_ofList_bne) (chars name) (chars text)
      (mkApp2 (mkConst ``Eq.refl [Level.one]) (mkConst ``Bool) (mkConst ``Bool.false))
  | _ => throwError "keys_absent: predicate is not a conjunction of `!=`"

/-- A proof of `entries.all p = true` for a literal list `entries` with literal keys and
`p = fun e => e.1 != key₁ && …`. The proof is checked by the kernel only. -/
meta partial def keysAbsentProof (α p body entries : Expr) : MetaM Expr := do
  let entries ← whnfR entries
  match_expr entries with
  | List.nil _ => return mkApp2 (mkConst ``Eq.refl [Level.one]) (mkConst ``Bool) (mkConst ``Bool.true)
  | List.cons _ entry rest =>
    let_expr Prod.mk _ _ first _ := (← whnfR entry)
      | throwError "keys_absent: entry is not a pair"
    let some name := stringLiteral? first | throwError "keys_absent: entry key is not a string literal"
    let head ← keysDifferProof name (body.instantiate1 entry)
    let tail ← keysAbsentProof α p body rest
    return mkApp6 (mkConst ``list_all_cons_true) α p entry rest head tail
  | _ => throwError "keys_absent: entries are not a literal list"

/-- Proves `entries.all (fun e => e.1 != key₁ && …) = true` for literal entries and keys. -/
elab "keys_absent" : tactic => liftMetaFinishingTactic fun goal => do
  let type ← instantiateMVars (← goal.getType)
  let_expr Eq _ lhs _ := type | throwError "keys_absent: goal is not an equation"
  let_expr List.all α entries p := lhs | throwError "keys_absent: goal is not `List.all`"
  let .lam _ _ body _ := p | throwError "keys_absent: predicate is not a lambda"
  goal.assign (← keysAbsentProof α p body entries)

/-- Proves `s ≠ t` when `s` and `t` reduce to different string literals. -/
elab "string_ne" : tactic => liftMetaFinishingTactic fun goal => do
  let type ← whnfR (← instantiateMVars (← goal.getType))
  let (α, left, right) ← match_expr type with
    | Ne α left right => pure (α, left, right)
    | Not equation =>
      let_expr Eq α left right := equation | throwError "string_ne: goal is not a disequality"
      pure (α, left, right)
    | _ => throwError "string_ne: goal is not a disequality"
  unless α.isConstOf ``String do throwError "string_ne: goal is not about strings"
  let some s := stringLiteral? (← whnf left) | throwError "string_ne: {left} is not a string literal"
  let some t := stringLiteral? (← whnf right) | throwError "string_ne: {right} is not a string literal"
  if s == t then throwError "string_ne: both sides are {s}"
  let chars (s : String) : Expr := toExpr s.toList
  goal.assign (mkApp3 (mkConst ``string_ofList_ne) (chars s) (chars t)
    (mkApp2 (mkConst ``Eq.refl [Level.one]) (mkConst ``Bool) (mkConst ``Bool.false)))

end VerifiedKernel.Session
