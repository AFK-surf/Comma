import VerifiedKernelProofs.Provider.RequestPrefix
import VerifiedKernel.Session.Request

/-!
Journal independence of the Session request context.

`Session.Request.context` and the steps that build the durable request history read no host
answer. The recursive term order needs its own lemmas.
-/

namespace VerifiedKernel
open Data

set_option maxHeartbeats 4000000

theorem Data.lexM.stateless {cmp : Term → Term → KernelM Ordering} (h : ∀ x y, Stateless (cmp x y)) :
    ∀ xs ys, Stateless (lexM cmp xs ys)
  | [], [] => by simp only [lexM]; stateless
  | [], _ :: _ => by simp only [lexM]; stateless
  | _ :: _, [] => by simp only [lexM]; stateless
  | x :: xs, y :: ys => by
    simp only [lexM]
    exact Stateless.bind (h x y) fun _ => Stateless.ite (Data.lexM.stateless h xs ys) (Stateless.pure _)

theorem Data.compareLists.stateless {cmp : Term → Term → KernelM Ordering} (h : ∀ x y, Stateless (cmp x y))
    (xt yt : Term) : ∀ xs ys, Stateless (compareLists cmp xt yt xs ys)
  | [], [] => by simp only [compareLists]; exact h _ _
  | [], _ :: _ => by simp only [compareLists]; exact h _ _
  | _ :: _, [] => by simp only [compareLists]; exact h _ _
  | x :: xs, y :: ys => by
    simp only [compareLists]
    exact Stateless.bind (h x y) fun _ => Stateless.ite (Data.compareLists.stateless h xt yt xs ys) (Stateless.pure _)

theorem Data.sortM.merge.stateless {cmp : Term → Term → KernelM Ordering} (h : ∀ x y, Stateless (cmp x y)) :
    ∀ fuel xs ys acc, Stateless (sortM.merge cmp fuel xs ys acc)
  | _, [], _, _ => by simp only [sortM.merge]; stateless
  | _, _ :: _, [], _ => by simp only [sortM.merge]; stateless
  | 0, _ :: _, _ :: _, _ => by simp only [sortM.merge]; stateless
  | fuel + 1, x :: xs, y :: ys, acc => by
    simp only [sortM.merge]
    exact Stateless.bind (h x y) fun _ =>
      Stateless.ite (Data.sortM.merge.stateless h fuel _ _ _) (Data.sortM.merge.stateless h fuel _ _ _)

theorem Data.sortM.sort.stateless {cmp : Term → Term → KernelM Ordering} (h : ∀ x y, Stateless (cmp x y)) :
    ∀ fuel xs, Stateless (sortM.sort cmp fuel xs)
  | 0, _ => by simp only [sortM.sort]; stateless
  | fuel + 1, xs => by
    simp only [sortM.sort]
    stateless
    all_goals first
      | exact h _ _
      | exact Data.sortM.sort.stateless h fuel _
      | exact Data.sortM.merge.stateless h _ _ _ _

theorem Data.sortM.stateless {cmp : Term → Term → KernelM Ordering} (h : ∀ x y, Stateless (cmp x y))
    (xs : List Term) : Stateless (sortM cmp xs) := by
  unfold sortM
  exact Data.sortM.sort.stateless h _ _

theorem Data.orderFuel.stateless : ∀ fuel keys left right, Stateless (orderFuel fuel keys left right) := by
  intro fuel
  induction fuel with
  | zero => intro keys left right; stateless_unfold_rec; stateless
  | succ fuel ih =>
    intro keys left right
    stateless_unfold_rec
    stateless
    all_goals exact ih _ _ _

theorem Session.CompactionQuery.requestLiveMessages.stateless (s : Term) :
    Stateless (Session.CompactionQuery.requestLiveMessages s) := by stateless
theorem Session.CompactionQuery.contextPrefix.stateless (s : Term) :
    Stateless (Session.CompactionQuery.contextPrefix s) := by stateless
theorem Session.ReplyQuery.phase.stateless (s : Term) : Stateless (Session.ReplyQuery.phase s) := by stateless
theorem Session.ReplyQuery.promptSnapshot.stateless (s x : Term) :
    Stateless (Session.ReplyQuery.promptSnapshot s x) := by stateless
theorem Session.Request.prepend.stateless (m p : Term) : Stateless (Session.Request.prepend m p) := by stateless
theorem Session.Request.annotate.stateless (m : Term) : Stateless (Session.Request.annotate m) := by stateless
theorem Session.RequestPage.fit.stateless (m : Term) :
    Stateless (Session.RequestPage.fit Session.Request.annotate m) := by stateless
theorem Session.Presentation.sanitizeContext.stateless (ms : List Term) :
    Stateless (Session.Presentation.sanitizeContext ms) := by stateless
theorem Session.Request.context.stateless (s : Term) : Stateless (Session.Request.context s) := by stateless

end VerifiedKernel
