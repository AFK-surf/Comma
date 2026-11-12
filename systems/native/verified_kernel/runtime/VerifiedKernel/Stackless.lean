import Init

/-!
Deferred computations keep their continuations on the heap. The logical
interpreter defines the result. Its compiled replacement uses a tail loop.
-/

universe u v w

namespace VerifiedKernel

inductive Stackless : Type u → Type (u + 1) where
  | done {α : Type u} : α → Stackless α
  | delay {α : Type u} : (Unit → Stackless α) → Stackless α
  | bind {α β : Type u} : Stackless β → (β → Stackless α) → Stackless α

namespace Stackless

instance : Monad Stackless where
  pure := .done
  bind := .bind

def run {α : Type u} : Stackless α → α
  | .done value => value
  | .delay next => (next ()).run
  | .bind first next => (next first.run).run

@[simp] theorem run_pure {α : Type u} (value : α) : (pure value : Stackless α).run = value := rfl

@[simp] theorem run_bind {α β : Type u} (first : Stackless α) (next : α → Stackless β) :
    (first >>= next).run = (next first.run).run := rfl

@[simp] theorem run_delay {α : Type u} (next : Unit → Stackless α) :
    (delay next).run = (next ()).run := rfl

private def cost {α : Type u} : Stackless α → Nat
  | .done _ => 1
  | .delay next => 1 + cost (next ())
  | .bind first next => 1 + cost first + cost (next first.run)

private inductive Continuation (α : Type u) : Type u → Type (u + 1) where
  | halt : Continuation α α
  | more {β γ : Type u} : (β → Stackless γ) → Continuation α γ → Continuation α β

private def Continuation.run {α β : Type u} : Continuation α β → β → α
  | .halt, value => value
  | .more next rest, value => rest.run (next value).run

private def Continuation.cost {α β : Type u} : Continuation α β → β → Nat
  | .halt, _ => 0
  | .more next rest, value => Stackless.cost (next value) + rest.cost (next value).run

private def drive {α β : Type u} (step : Stackless β) (continuation : Continuation α β) : α :=
  match step, continuation with
  | .done value, .halt => value
  | .done value, .more next rest => drive (next value) rest
  | .delay next, rest => drive (next ()) rest
  | .bind first next, rest => drive first (.more next rest)
termination_by cost step + continuation.cost step.run
decreasing_by all_goals simp_all [cost, run, Continuation.cost] <;> omega

private theorem drive_eq {α β : Type u} (step : Stackless β) (continuation : Continuation α β) :
    drive step continuation = continuation.run step.run := by
  fun_induction drive <;> simp_all [run, Continuation.run]

def runTR {α : Type u} (step : Stackless α) : α := drive step .halt

@[csimp] theorem run_eq_runTR : @run = @runTR := by
  funext α step
  simp [runTR, drive_eq, Continuation.run]

def mapM {α β : Type u} (action : α → Stackless β) : List α → Stackless (List β)
  | [] => .done []
  | value :: rest => .bind (action value) fun result =>
    .bind (mapM action rest) fun results => .done (result :: results)

@[simp] theorem run_mapM {α β : Type u} (action : α → Stackless β) (values : List α) :
    (mapM action values).run = values.map (fun value => (action value).run) := by
  induction values with
  | nil => rfl
  | cons value rest ih => simp [mapM, run, ih]

def allM {α : Type u} (action : α → Stackless Bool) : List α → Stackless Bool
  | [] => .done true
  | value :: rest => .bind (action value) fun result =>
    if result then allM action rest else .done false

@[simp] theorem run_allM {α : Type u} (action : α → Stackless Bool) (values : List α) :
    (allM action values).run = values.all (fun value => (action value).run) := by
  induction values with
  | nil => rfl
  | cons value rest ih => simp only [allM, run, List.all_cons]; split <;> simp_all [run]

def anyM {α : Type u} (action : α → Stackless Bool) : List α → Stackless Bool
  | [] => .done false
  | value :: rest => .bind (action value) fun result =>
    if result then .done true else anyM action rest

@[simp] theorem run_anyM {α : Type u} (action : α → Stackless Bool) (values : List α) :
    (anyM action values).run = values.any (fun value => (action value).run) := by
  induction values with
  | nil => rfl
  | cons value rest ih => simp only [anyM, run, List.any_cons]; split <;> simp_all [run]

def both (first : Stackless Bool) (next : Unit → Stackless Bool) : Stackless Bool :=
  .bind first fun result => if result then next () else .done false

@[simp] theorem run_both (first : Stackless Bool) (next : Unit → Stackless Bool) :
    (both first next).run = (first.run && (next ()).run) := by
  simp only [both, run]
  split <;> simp_all [run]

theorem mapM_hom {m : Type u → Type v} {n : Type u → Type w} [Monad m] [Monad n]
    (evaluate : {α : Type u} → m α → n α)
    (hp : ∀ {α : Type u} (x : α), evaluate (pure x) = pure x)
    (hb : ∀ {α β : Type u} (x : m α) (f : α → m β),
      evaluate (x >>= f) = (evaluate x >>= fun y => evaluate (f y)))
    {α β : Type u} (f : α → m β) (xs : List α) :
    evaluate (xs.mapM f) = xs.mapM (fun x => evaluate (f x)) := by
  suffices ∀ acc, evaluate (List.mapM.loop f xs acc) =
      List.mapM.loop (fun x => evaluate (f x)) xs acc by
    exact this []
  induction xs with
  | nil => intro acc; simp [List.mapM.loop, hp]
  | cons x xs ih => intro acc; simp [List.mapM.loop, hb, ih]

theorem foldlM_hom {m : Type u → Type v} {n : Type u → Type w} [Monad m] [Monad n]
    (evaluate : {α : Type u} → m α → n α)
    (hp : ∀ {α : Type u} (x : α), evaluate (pure x) = pure x)
    (hb : ∀ {α β : Type u} (x : m α) (f : α → m β),
      evaluate (x >>= f) = (evaluate x >>= fun y => evaluate (f y)))
    {α β : Type u} (f : β → α → m β) (xs : List α) (acc : β) :
    evaluate (xs.foldlM f acc) = xs.foldlM (fun acc x => evaluate (f acc x)) acc := by
  induction xs generalizing acc with
  | nil => simp [hp]
  | cons x xs ih => simp [hb, ih]

abbrev ExceptEval (ε : Type u) := ExceptT ε Stackless

def runExcept {ε α : Type u} (action : ExceptEval ε α) : Except ε α := action.run.run

@[simp] theorem runExcept_pure {ε α : Type u} (x : α) :
    runExcept (pure x : ExceptEval ε α) = pure x := rfl

@[simp] theorem runExcept_bind {ε α β : Type u} (first : ExceptEval ε α) (next : α → ExceptEval ε β) :
    runExcept (first >>= next) = (runExcept first >>= fun x => runExcept (next x)) := by
  unfold runExcept
  change (Stackless.bind _ _).run = _
  simp only [run]
  simp only [ExceptT.run] at *
  cases h : Stackless.run first <;> rfl

@[simp] theorem runExcept_mapM {ε α β : Type u} (action : α → ExceptEval ε β) (values : List α) :
    runExcept (values.mapM action) = values.mapM (fun x => runExcept (action x)) :=
  mapM_hom (@runExcept ε) (@runExcept_pure ε) (@runExcept_bind ε) action values

@[simp] theorem runExcept_foldlM {ε α β : Type u} (action : β → α → ExceptEval ε β)
    (values : List α) (acc : β) :
    runExcept (values.foldlM action acc) = values.foldlM (fun acc x => runExcept (action acc x)) acc :=
  foldlM_hom (@runExcept ε) (@runExcept_pure ε) (@runExcept_bind ε) action values acc

def deferExcept {ε α : Type u} (next : Unit → ExceptEval ε α) : ExceptEval ε α :=
  .delay fun _ => (next ()).run

@[simp] theorem runExcept_defer {ε α : Type u} (next : Unit → ExceptEval ε α) :
    runExcept (deferExcept next) = runExcept (next ()) := rfl

@[simp] theorem runExcept_lift {ε α : Type u} (value : Except ε α) :
    runExcept (monadLift value : ExceptEval ε α) = value := rfl

@[simp] theorem runExcept_throw {ε α : Type u} (error : ε) :
    runExcept (throw error : ExceptEval ε α) = .error error := rfl

abbrev OptionEval := OptionT Stackless

def runOption {α : Type u} (action : OptionEval α) : Option α := action.run.run

def liftOption {α : Type u} (value : Option α) : OptionEval α := .done value

def deferOption {α : Type u} (next : Unit → OptionEval α) : OptionEval α :=
  .delay fun _ => (next ()).run

@[simp] theorem runOption_pure {α : Type u} (value : α) :
    runOption (pure value : OptionEval α) = some value := rfl

@[simp] theorem runOption_bind {α β : Type u} (first : OptionEval α) (next : α → OptionEval β) :
    runOption (first >>= next) = (runOption first >>= fun value => runOption (next value)) := by
  unfold runOption
  change (Stackless.bind _ _).run = _
  simp only [run, OptionT.run]
  cases h : Stackless.run first <;> rfl

@[simp] theorem runOption_lift {α : Type u} (value : Option α) : runOption (liftOption value) = value := rfl

@[simp] theorem runOption_defer {α : Type u} (next : Unit → OptionEval α) :
    runOption (deferOption next) = runOption (next ()) := rfl

@[simp] theorem runOption_mapM {α β : Type u} (action : α → OptionEval β) (values : List α) :
    runOption (values.mapM action) = values.mapM (fun value => runOption (action value)) :=
  mapM_hom (@runOption) (@runOption_pure) (@runOption_bind) action values

end Stackless
end VerifiedKernel
