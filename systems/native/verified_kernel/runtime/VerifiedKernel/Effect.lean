import VerifiedKernel.Term

namespace VerifiedKernel

/-- Observations contain raw host results, never a replacement domain state. -/
inductive Signal where
  | observe (request : Term)
  | raised (reason : Term)
  deriving Inhabited

abbrev KernelM := StateT (List Term) (Except Signal)

/-- A host may answer requests ahead of time with `{:ok_for, key, value}`
entries. `key` names the request exactly, or `{:config, app, name}` for a
configuration request with any fallback. Such entries are never consumed, so
a computation reads one clock value throughout and a replay sees the same
answers; positional `{:ok, value}` entries keep the continuation protocol. -/
def answers (request : Term) : Term → Bool
  | .tuple [.atom "ok_for", key, _] =>
    key == request ||
      match request, key with
      | .tuple [.atom "config", app, name, _], .tuple [.atom "config", app', name'] =>
        app == app' && name == name'
      | _, _ => false
  | _ => false

def keyed : Term → Bool
  | .tuple [.atom "ok_for", _, _] => true
  | _ => false

/-- Answered-ahead entries are never consumed, so a computation is settled
when only those remain. -/
def settled (observations : List Term) : Bool := observations.all keyed

/-- Keyed observations stay in order while the first positional one is removed. -/
def positionalLoop (acc : List Term) : List Term → Option (Term × List Term)
  | [] => none
  | entry :: rest =>
    if keyed entry then positionalLoop (entry :: acc) rest
    else some (entry, acc.reverse ++ rest)

/-- Removes the first positional observation without a frame per keyed entry. -/
def positional (entries : List Term) : Option (Term × List Term) :=
  positionalLoop [] entries

def observe (request : Term) : KernelM Term := do
  let observations ← get
  match observations.find? (answers request) with
  | some (.tuple [_, _, value]) => return value
  | _ =>
    match positional observations with
    | none => throw (.observe request)
    | some (result, rest) =>
      set rest
      match result with
      | .tuple [.atom "ok", value] => return value
      | .tuple [.atom "raised", reason] => throw (.raised reason)
      | _ => throw (.raised (.atom "invalid_observation"))

def fail (kind : String) (args : List Term := []) : KernelM α :=
  throw (.raised (.tuple [.atom kind, .list args]))

end VerifiedKernel
