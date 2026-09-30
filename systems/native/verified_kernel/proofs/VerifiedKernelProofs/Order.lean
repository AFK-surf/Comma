import VerifiedKernel.Order
import VerifiedKernelProofs.Data
import Init.Data.List.Sort.Basic

namespace VerifiedKernel.Data

/-- Two integers order by value. Proofs about sequence watermarks rely on this. -/
theorem order_integer (x y : Int) (s : List Term) :
    order (.integer x) (.integer y) s = .ok (compare x y, s) := by
  unfold order
  simp only [Term.depth, Nat.max_self]
  by_cases hxy : x = y
  · subst hxy
    simp [orderFuel, Pure.pure, StateT.pure, Except.pure, BEq.beq]
  · simp [orderFuel, Pure.pure, StateT.pure, Except.pure, BEq.beq, hxy, rank, Term.number]

theorem greater_integer (x y : Int) (s : List Term) :
    greater (.integer x) (.integer y) s = .ok (decide (y < x), s) := by
  simp only [greater, less, order_integer, Bind.bind, StateT.bind, Except.bind, Pure.pure, StateT.pure,
    Except.pure]
  by_cases hlt : y < x
  · simp [hlt, Int.compare_eq_lt.mpr hlt]
  · have : compare y x ≠ .lt := fun e => hlt (Int.compare_eq_lt.mp e)
    simp [hlt, this]

end VerifiedKernel.Data
