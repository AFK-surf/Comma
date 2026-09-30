import VerifiedKernel.Effect
import VerifiedKernel.Term

namespace VerifiedKernel

theorem observe_empty (request : Term) :
    observe request [] = .error (.observe request) := rfl

theorem observe_recorded (request value : Term) (rest : List Term)
    (h : rest.find? (answers request) = none) :
    observe request (.tuple [.atom "ok", value] :: rest) = .ok (value, rest) := by
  have hk : answers request (.tuple [.atom "ok", value]) = false := rfl
  have hp : keyed (.tuple [.atom "ok", value]) = false := rfl
  simp [observe, positional, positionalLoop, List.find?_cons, hk, hp, h, bind, StateT.bind, get, getThe,
    MonadStateOf.get, StateT.get, set, StateT.set, pure, StateT.pure, Except.pure, Except.bind]

end VerifiedKernel
