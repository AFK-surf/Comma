import VerifiedKernelProofs.RequestPrefix.Keeps

/-!
`Keeps` for the request builder, which reads host configuration.
-/

namespace VerifiedKernel
open Data

set_option maxHeartbeats 4000000

theorem Data.enumListLoop.keeps {α : Type} {step : α → Term → KernelM (Bool × α)} (h : ∀ acc x, Keeps (step acc x)) :
    ∀ xs acc, Keeps (enumListLoop step xs acc)
  | [], acc => by simp only [enumListLoop]; exact Keeps.pure _
  | x :: xs, acc => by
    simp only [enumListLoop]
    refine Keeps.bind (h acc x) fun r => ?_
    obtain ⟨more, next⟩ := r
    exact Keeps.ite (Data.enumListLoop.keeps h xs next) (Keeps.pure _)

theorem Data.stringifyFuel.keeps : ∀ fuel v, Keeps (stringifyFuel fuel v)
  | 0, v => by simp only [stringifyFuel]; keeps
  | fuel + 1, v => by
    simp only [stringifyFuel]
    have ih := Data.stringifyFuel.keeps fuel
    keeps

theorem Session.Request.build.keeps (s args : Term) : Keeps (Session.Request.build s args) := by
  keeps

end VerifiedKernel
