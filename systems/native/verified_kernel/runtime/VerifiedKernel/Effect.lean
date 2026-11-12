import VerifiedKernel.Term

namespace VerifiedKernel

/-- Observations contain raw host results, never a replacement domain state. -/
inductive Signal where
  | observe (request : Term)
  | raised (reason : Term)
  deriving Inhabited

abbrev KernelM := StateT (List Term) (Except Signal)

abbrev KernelEval := StateT (List Term) (Stackless.ExceptEval Signal)

namespace KernelEval

variable {α β : Type}

def run (action : KernelEval α) : KernelM α := fun observations =>
  Stackless.runExcept (action observations)

instance : MonadLift KernelM KernelEval := ⟨fun action observations => .done (action observations)⟩

def defer (next : Unit → KernelEval α) : KernelEval α := fun observations =>
  Stackless.deferExcept fun _ => next () observations

@[simp] theorem run_pure (value : α) : run (pure value : KernelEval α) = pure value := rfl

@[simp] theorem run_bind (first : KernelEval α) (next : α → KernelEval β) :
    run (first >>= next) = (run first >>= fun value => run (next value)) := by
  funext observations
  exact Stackless.runExcept_bind (first observations) (fun (value, rest) => next value rest)

@[simp] theorem run_lift (action : KernelM α) : run (monadLift action : KernelEval α) = action := rfl

@[simp] theorem run_defer (next : Unit → KernelEval α) : run (defer next) = run (next ()) := rfl

@[simp] theorem run_ite (condition : Prop) [Decidable condition] (yes no : KernelEval α) :
    run (if condition then yes else no) = if condition then run yes else run no := by
  split <;> rfl

@[simp] theorem run_dite (condition : Prop) [Decidable condition]
    (yes : condition → KernelEval α) (no : ¬condition → KernelEval α) :
    run (if h : condition then yes h else no h) = if h : condition then run (yes h) else run (no h) := by
  split <;> rfl

@[simp] theorem run_mapM (action : α → KernelEval β) (values : List α) :
    run (values.mapM action) = values.mapM (fun value => run (action value)) :=
  Stackless.mapM_hom (@run) (@run_pure) (@run_bind) action values

@[simp] theorem run_foldlM (action : β → α → KernelEval β) (values : List α) (acc : β) :
    run (values.foldlM action acc) = values.foldlM (fun acc value => run (action acc value)) acc :=
  Stackless.foldlM_hom (@run) (@run_pure) (@run_bind) action values acc

end KernelEval

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
