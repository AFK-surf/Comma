import VerifiedKernel.Stackless
import Std.Data.DHashMap.Internal.AssocList.Basic
import Std.Data.HashSet.Basic
import Init.Data.List.Sort.Impl

namespace VerifiedKernel

private def listEq [DecidableEq α] : List α → List α → Bool
  | [], [] => true
  | x :: xs, y :: ys => if x = y then listEq xs ys else false
  | _, _ => false

private theorem listEq_iff [DecidableEq α] (xs ys : List α) : listEq xs ys = true ↔ xs = ys := by
  induction xs generalizing ys with
  | nil => cases ys <;> simp [listEq]
  | cons x xs ih => cases ys <;> simp_all [listEq]

def listDecEq [DecidableEq α] (xs ys : List α) : Decidable (xs = ys) :=
  if h : listEq xs ys then .isTrue ((listEq_iff xs ys).mp h)
  else .isFalse (fun eq => h ((listEq_iff xs ys).mpr eq))

@[csimp] theorem listDecEq_eq : @List.hasDecEq = @listDecEq := by
  funext α inst xs ys
  exact Subsingleton.elim _ _

@[csimp] theorem listDecEqInstance_eq : @instDecidableEqList = @listDecEq := by
  funext α inst xs ys
  exact Subsingleton.elim _ _

open Std.DHashMap.Internal

private def eraseDeferred [BEq α] (key : α) : AssocList α β → Stackless (AssocList α β)
  | .nil => .done .nil
  | .cons k value rest => .delay fun _ =>
    bif k == key then .done rest
    else .bind (eraseDeferred key rest) fun remaining => .done (.cons k value remaining)

private theorem eraseDeferred_eq [BEq α] (key : α) (values : AssocList α β) :
    (eraseDeferred key values).run = values.erase key := by
  induction values with
  | nil => rfl
  | cons k value rest ih => cases h : k == key <;> simp [eraseDeferred, Stackless.run, AssocList.erase, h, ih]

def assocErase.{v, u} {α : Type u} {β : α → Type v} [BEq α] (key : α) (values : AssocList α β) : AssocList α β :=
  (eraseDeferred key values).run

@[csimp] theorem assocErase_eq : @AssocList.erase = @assocErase := by
  funext α β inst key values
  exact (eraseDeferred_eq key values).symm

private def replaceDeferred [BEq α] (key : α) (value : β key) : AssocList α β → Stackless (AssocList α β)
  | .nil => .done .nil
  | .cons k previous rest => .delay fun _ =>
    bif k == key then .done (.cons key value rest)
    else .bind (replaceDeferred key value rest) fun remaining => .done (.cons k previous remaining)

private theorem replaceDeferred_eq [BEq α] (key : α) (value : β key) (values : AssocList α β) :
    (replaceDeferred key value values).run = values.replace key value := by
  induction values with
  | nil => rfl
  | cons k previous rest ih => cases h : k == key <;> simp [replaceDeferred, Stackless.run, AssocList.replace, h, ih]

def assocReplace.{v, u} {α : Type u} {β : α → Type v} [BEq α] (key : α) (value : β key) (values : AssocList α β) : AssocList α β :=
  (replaceDeferred key value values).run

@[csimp] theorem assocReplace_eq : @AssocList.replace = @assocReplace := by
  funext α β inst key value values
  exact (replaceDeferred_eq key value values).symm

-- Compile these wrappers here so their bucket operations use the replacements
-- above. Imported wrappers retain the code compiled in the standard library.
private def rawErase [BEq α] [Hashable α] (m : Raw₀ α β) (a : α) : Raw₀ α β :=
  let ⟨⟨size, buckets⟩, hb⟩ := m
  let ⟨i, h⟩ := mkIdx buckets.size hb (hash a)
  let bucket := buckets[i]
  if bucket.contains a then
    let buckets' := buckets.uset i .nil h
    ⟨⟨size - 1, buckets'.uset i (bucket.erase a) (by simpa [buckets'])⟩, by simpa [buckets']⟩
  else ⟨⟨size, buckets⟩, hb⟩

private def rawInsert [BEq α] [Hashable α] (m : Raw₀ α β) (a : α) (b : β a) : Raw₀ α β :=
  let ⟨⟨size, buckets⟩, hm⟩ := m
  let ⟨i, h⟩ := mkIdx buckets.size hm (hash a)
  let bucket := buckets[i]
  if bucket.contains a then
    let buckets' := buckets.uset i .nil h
    ⟨⟨size, buckets'.uset i (bucket.replace a b) (by simpa [buckets'])⟩, by simpa [buckets']⟩
  else
    let buckets' := buckets.uset i (AssocList.cons a b bucket) h
    Raw₀.expandIfNecessary ⟨⟨size + 1, buckets'⟩, by simpa [buckets']⟩

private def dhashErase [BEq α] [Hashable α] (m : Std.DHashMap α β) (a : α) : Std.DHashMap α β :=
  ⟨rawErase ⟨m.1, m.2.size_buckets_pos⟩ a, .erase₀ m.2⟩

private def dhashInsert [BEq α] [Hashable α] (m : Std.DHashMap α β) (a : α) (b : β a) : Std.DHashMap α β :=
  ⟨rawInsert ⟨m.1, m.2.size_buckets_pos⟩ a b, .insert₀ m.2⟩

def hashMapErase [BEq α] [Hashable α] (m : Std.HashMap α β) (a : α) : Std.HashMap α β :=
  ⟨dhashErase m.inner a⟩

@[csimp] theorem hashMapErase_eq : @Std.HashMap.erase = @hashMapErase := rfl

def hashMapInsert [BEq α] [Hashable α] (m : Std.HashMap α β) (a : α) (b : β) : Std.HashMap α β :=
  ⟨dhashInsert m.inner a b⟩

@[csimp] theorem hashMapInsert_eq : @Std.HashMap.insert = @hashMapInsert := rfl

def hashSetErase [BEq α] [Hashable α] (m : Std.HashSet α) (a : α) : Std.HashSet α :=
  ⟨hashMapErase m.inner a⟩

@[csimp] theorem hashSetErase_eq : @Std.HashSet.erase = @hashSetErase := rfl

private def mergeSortDeferred (xs : List α) (le : α → α → Bool) : Stackless (List α) := .delay fun _ =>
  match xs with
  | [] => .done []
  | [a] => .done [a]
  | a :: b :: rest =>
    let halves := List.MergeSort.Internal.splitInTwo ⟨a :: b :: rest, rfl⟩
    have := by simpa using halves.1.2
    have := by simpa using halves.2.2
    .bind (mergeSortDeferred halves.1 le) fun left =>
      .bind (mergeSortDeferred halves.2 le) fun right => .done (List.merge left right le)
termination_by xs.length

private theorem mergeSortDeferred_eq (xs : List α) (le : α → α → Bool) :
    (mergeSortDeferred xs le).run = xs.mergeSort le := by
  fun_induction List.mergeSort xs le <;> simp_all [mergeSortDeferred, Stackless.run]
  rename_i a b rest le halves h₁ h₂ ih_left ih_right
  have result : (mergeSortDeferred halves.1 le).run.merge (mergeSortDeferred halves.2 le).run le =
      (halves.1.val.mergeSort le).merge (halves.2.val.mergeSort le) le := by rw [ih_left, ih_right]
  simpa [halves, List.MergeSort.Internal.splitInTwo, List.splitAt_eq] using result

def mergeSort (xs : List α) (le : α → α → Bool) : List α := (mergeSortDeferred xs le).run

@[csimp] theorem mergeSort_eq : @List.mergeSort = @mergeSort := by
  funext α xs le
  exact (mergeSortDeferred_eq xs le).symm

end VerifiedKernel
