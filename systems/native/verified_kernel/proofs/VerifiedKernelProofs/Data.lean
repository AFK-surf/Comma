import VerifiedKernel.Data
import VerifiedKernelProofs.Effect
import VerifiedKernel.Number
import Std.Data.HashSet.Basic

namespace VerifiedKernel.Data

private theorem enumListLoop_keep_all (step : List Term → Term → KernelM (Bool × List Term))
    (hstep : ∀ acc item s, step acc item s = .ok ((true, item :: acc), s))
    (xs acc s : List Term) : enumListLoop step xs acc s = .ok (xs.reverse ++ acc, s) := by
  induction xs generalizing acc with
  | nil => rfl
  | cons x rest ih =>
    simp [enumListLoop, Bind.bind, StateT.bind, Except.bind, hstep, ih]

/-- Mapping the identity over a list container returns the list itself. -/
theorem enumMap_list_pure (xs s : List Term) : enumMap (.list xs) pure s = .ok (xs, s) := by
  simp only [enumMap, enumFold, enumUntil, Bind.bind, StateT.bind, Except.bind, Pure.pure, StateT.pure,
    Except.pure]
  have loop := enumListLoop_keep_all
    (fun acc item => ((StateT.pure item : KernelM Term).bind fun l => StateT.pure (l :: acc)).bind
      fun l => (StateT.pure (true, l) : KernelM (Bool × List Term)))
    (fun _ _ _ => rfl) xs [] s
  rw [loop]
  simp

/-- A successful `access` returns the field, or `nil` for a `nil` value, without touching the journal. -/
theorem access_ok {v key x : Term} {s r : List Term} (h : access v key s = .ok (x, r)) :
    x = v.get key ∧ r = s := by
  unfold access at h
  split at h
  · simp [Pure.pure, StateT.pure, Except.pure] at h
    exact ⟨h.1.symm, h.2.symm⟩
  · split at h
    · simp [Pure.pure, StateT.pure, Except.pure] at h
      rename_i hnil
      refine ⟨?_, h.2.symm⟩
      rw [← h.1]
      cases v <;> simp [BEq.beq, nil, Term.get] at hnil ⊢
    · simp [fail, throw, throwThe, MonadExceptOf.throw, StateT.lift, Functor.map, Except.map] at h

private theorem enumListLoop_foldlM {α : Type} (step : α → Term → KernelM α) (xs : List Term) (init : α)
    (s : List Term) :
    enumListLoop (fun acc item => do return (true, ← step acc item)) xs init s = List.foldlM step init xs s := by
  induction xs generalizing init s with
  | nil => rfl
  | cons x rest ih =>
    simp only [enumListLoop, List.foldlM_cons, Bind.bind, StateT.bind, Except.bind]
    cases step init x s with
    | error e => rfl
    | ok v =>
      obtain ⟨v, s'⟩ := v
      simp only [Pure.pure, StateT.pure, Except.pure, ↓reduceIte]
      exact ih v s'

private theorem enumUntil_ok {α : Type} {value : Term} {init : α} {step : α → Term → KernelM (Bool × α)}
    {s r : List Term} {acc : α} (h : enumUntil value init step s = .ok (acc, r)) :
    ∃ items : List Term, enumListLoop step items init s = .ok (acc, r) ∧ ∀ xs, value = .list xs → items = xs := by
  cases value <;> simp only [enumUntil] at h
  case list xs => exact ⟨xs, h, fun ys hys => by cases hys; rfl⟩
  case map entries =>
    split at h
    · exact ⟨_, h, fun ys hys => by cases hys⟩
    · split at h
      · generalize Term.get _ _ = discriminant at h
        split at h
        · exact ⟨_, h, fun ys hys => by cases hys⟩
        · simp [Bind.bind, StateT.bind, Except.bind, fail, throw, throwThe, MonadExceptOf.throw, StateT.lift] at h
      · simp [fail, throw, throwThe, MonadExceptOf.throw, StateT.lift, Functor.map, Except.map] at h
  all_goals simp [fail, throw, throwThe, MonadExceptOf.throw, StateT.lift, Functor.map, Except.map] at h

/-- A fold over a container is a fold over the list it enumerates; a list enumerates itself. -/
theorem enumFold_ok {α : Type} {value : Term} {init : α} {step : α → Term → KernelM α} {s r : List Term}
    {acc : α} (h : enumFold value init step s = .ok (acc, r)) :
    ∃ items : List Term, List.foldlM step init items s = .ok (acc, r) ∧ ∀ xs, value = .list xs → items = xs := by
  unfold enumFold at h
  split at h
  · rename_i heads tail
    simp only [Bind.bind, StateT.bind] at h
    cases hf : List.foldlM step init heads s <;> simp [hf, Except.bind, fail, throw, throwThe, MonadExceptOf.throw,
      StateT.lift, Functor.map, Except.map] at h
  · obtain ⟨items, hl, hxs⟩ := enumUntil_ok h
    exact ⟨items, by rw [← enumListLoop_foldlM]; exact hl, hxs⟩

/-- Successful folds of one container traverse the same elements, regardless of their callbacks or journals. -/
theorem enumFold_same_input {α β : Type} {value : Term} {first : α} {second : β}
    {f : α → Term → KernelM α} {g : β → Term → KernelM β}
    {j r before after : List Term} {x : α} {y : β}
    (left : enumFold value first f j = .ok (x, r))
    (right : enumFold value second g before = .ok (y, after)) :
    ∃ items : List Term, items.foldlM f first j = .ok (x, r) ∧
      items.foldlM g second before = .ok (y, after) := by
  cases value <;> simp only [enumFold, enumUntil] at left right
  case list items =>
    rw [enumListLoop_foldlM] at left right
    exact ⟨items, left, right⟩
  case improper heads tail =>
    simp only [Bind.bind, StateT.bind] at left
    cases folded : heads.foldlM f first j <;>
      simp_all [Except.bind, fail, throw, throwThe, MonadExceptOf.throw, StateT.lift, Functor.map, Except.map]
  case map entries =>
    split at left
    · rename_i plain
      simp only [plain, ↓reduceIte, enumListLoop_foldlM] at left right
      exact ⟨_, left, right⟩
    · rename_i structured
      simp only [structured, Bool.false_eq_true, ↓reduceIte] at right
      split at left
      · rename_i mapSet
        simp only [mapSet, ↓reduceIte] at right
        generalize source : (Term.map entries).get (a "map") = members at left right
        cases members <;> simp only at left right
        case map members =>
          rw [enumListLoop_foldlM] at left right
          exact ⟨_, left, right⟩
        all_goals simp [Bind.bind, StateT.bind, Except.bind, fail, throw, throwThe,
          MonadExceptOf.throw, StateT.lift, Functor.map, Except.map] at left
      · simp [Bind.bind, StateT.bind, Except.bind, fail, throw, throwThe,
          MonadExceptOf.throw, StateT.lift, Functor.map, Except.map] at left
  all_goals simp [Bind.bind, StateT.bind, Except.bind, fail, throw, throwThe, MonadExceptOf.throw,
    StateT.lift, Functor.map, Except.map, Pure.pure, StateT.pure, Except.pure] at left

/-- Integer addition in the kernel is integer addition. -/
theorem add_integer (x y : Int) (s : List Term) : add (.integer x) (.integer y) s = .ok (.integer (x + y), s) := by
  simp [add, Number.calculate, Pure.pure, StateT.pure, Except.pure]

end VerifiedKernel.Data
