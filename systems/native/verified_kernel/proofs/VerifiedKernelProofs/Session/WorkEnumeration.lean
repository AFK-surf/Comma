import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernelProofs.Session.WorkLedgerFacts

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

def enumeratedItems : Term → Option (List Term)
  | .list items => some items
  | .map entries =>
    let value := Term.map entries
    if !value.has (a "__struct__") then some (entries.map (fun p => .tuple [p.1, p.2]))
    else if value.get (a "__struct__") == a "Elixir.MapSet" then
      match value.get (a "map") with
      | .map members => some (members.map Prod.fst)
      | _ => none
    else none
  | _ => none

theorem enumFold_list_call {α : Type} {items : List Term} {initial final : α}
    {step : α → Term → KernelM α} {journal rest : List Term}
    (call : enumFold (.list items) initial step journal = .ok (final, rest)) :
    items.foldlM step initial journal = .ok (final, rest) := by
  obtain ⟨actual, folded, same⟩ := enumFold_ok call
  simpa only [same items rfl] using folded

/-- A successful kernel fold traverses the container's actual entries. -/
theorem enumFold_actual_items {α : Type} {value : Term} {initial final : α}
    {step : α → Term → KernelM α} {journal rest : List Term}
    (call : enumFold value initial step journal = .ok (final, rest)) :
    ∃ items, enumeratedItems value = some items ∧
      items.foldlM step initial journal = .ok (final, rest) := by
  cases value
  case list items => exact ⟨items, rfl, enumFold_list_call call⟩
  case map entries =>
    simp only [enumFold, enumUntil] at call
    simp only [enumeratedItems]
    split at call
    · rename_i plain
      simp only [plain, ↓reduceIte]
      exact ⟨_, rfl, enumFold_list_call call⟩
    · rename_i structured
      simp only [structured, Bool.false_eq_true, ↓reduceIte]
      split at call
      · rename_i mapSet
        simp only [mapSet, ↓reduceIte]
        generalize source : (Term.map entries).get (a "map") = members at call ⊢
        cases members <;> simp only at call ⊢
        case map members => exact ⟨_, rfl, enumFold_list_call call⟩
        all_goals simp [Bind.bind, StateT.bind, Except.bind, fail, throw, throwThe,
          MonadExceptOf.throw, StateT.lift, Functor.map, Except.map] at call
      · simp [Bind.bind, StateT.bind, Except.bind, fail, throw, throwThe,
          MonadExceptOf.throw, StateT.lift, Functor.map, Except.map] at call
  case improper heads tail =>
    simp only [enumFold, Bind.bind, StateT.bind] at call
    cases folded : heads.foldlM step initial journal <;>
      simp_all [Except.bind, fail, throw, throwThe, MonadExceptOf.throw, StateT.lift, Functor.map, Except.map]
  all_goals simp [enumFold, enumUntil, Bind.bind, StateT.bind, Except.bind, fail, throw, throwThe,
    MonadExceptOf.throw, StateT.lift, Functor.map, Except.map, Pure.pure, StateT.pure, Except.pure] at call

end VerifiedKernel.Session.WorkConservation
