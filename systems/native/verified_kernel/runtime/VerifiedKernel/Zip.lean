/-!
`List.zip` is compiled in core before core's own `zipWith` csimp lemma exists, so the
`List.zip` in the Lean runtime recurses once per item. The NIF runs on a bounded BEAM
dirty-scheduler stack: zipping a long transcript aborted the whole node. This lemma makes
every kernel call to `List.zip` run the accumulator loop below instead; the logical
definition, and every proof about it, is unchanged.
-/

namespace VerifiedKernel

def zipTR (xs : List α) (ys : List β) : List (α × β) :=
  go xs ys []
where
  go : List α → List β → List (α × β) → List (α × β)
    | x :: xs, y :: ys, acc => go xs ys ((x, y) :: acc)
    | _, _, acc => acc.reverse

@[csimp] theorem zip_eq_zipTR : @List.zip = @zipTR := by
  funext α β xs ys
  suffices ∀ acc, zipTR.go xs ys acc = acc.reverse ++ xs.zip ys by simpa [zipTR] using (this []).symm
  induction xs generalizing ys with
  | nil => intro acc; simp [zipTR.go]
  | cons x xs ih => cases ys <;> intro acc <;> simp [zipTR.go, ih]

end VerifiedKernel
