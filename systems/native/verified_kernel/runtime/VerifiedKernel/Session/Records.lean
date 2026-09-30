import VerifiedKernel.Session.Ops
import VerifiedKernel.Session.Kernel

/-!
Shared record helpers for the lifecycle operations: the Elixir comparison
primitives the ports rely on, list indexing, and the result-reference rebuild
that both the legacy migration and the fork run after rewriting a transcript.
-/

namespace VerifiedKernel.Session
open Data

/-- `Kernel.max/2`: the left value on a tie. -/
def kmax (left right : Term) : KernelM Term := do
  if ← less left right then pure right else pure left

/-- `Enum.max(xs, fn -> fallback end)`: folds `>=` from the head, so a tie keeps the later element. -/
def largest (xs : List Term) (fallback : Term) : KernelM Term :=
  match xs with
  | [] => pure fallback
  | x :: rest => rest.foldlM (fun acc y => do if ← less y acc then pure acc else pure y) x

/-- `Enum.find/2` with a monadic predicate; `nil` when nothing matches. -/
def firstWhere (xs : List Term) (p : Term → KernelM Bool) : KernelM Term :=
  match xs with
  | [] => pure nil
  | x :: rest => do if ← p x then pure x else firstWhere rest p

/-- `Enum.with_index/1`. -/
def indexed (xs : List Term) : List (Nat × Term) := (List.range xs.length).zip xs

/-- `tool_result_record?/1`. -/
def toolResultRecord (record : Term) : Bool :=
  record.get (b "kind") == b "tool_result" || record.get (a "kind") == b "tool_result"

/-- `State.rebuild_async_result_refs/1`: the bounded live-reference set.
A protected archived pointer survives; protected hot records are reconstructed. -/
def rebuildRefs (state : Term) : KernelM Term := do
  let live ← protectedRefs state
  let results ← asList ((← field state "async_results").default (list []))
  let hot ← results.foldlM (fun acc record => do
    let ref ← recordRef record
    if ref.isBinary && live.any (· == ref) then put acc ref (record.get (b "seq")) else pure acc) empty
  let stored ← entries ((← field state "async_result_refs").default empty)
  let archived := stored.filter (fun pair =>
    live.any (· == pair.1) && pair.2.isInteger && integerValue pair.2 > 0)
  write state [("async_result_refs", ← merge (.map archived) hot)]

end VerifiedKernel.Session
