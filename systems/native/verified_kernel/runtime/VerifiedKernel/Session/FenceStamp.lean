import VerifiedKernel.Session.Ops
import VerifiedKernel.Session.Query.State

/-! # Activity revision

A durable fence stamps the activity revision of a write with the rest of its
commit metadata. The host supplies a fresh revision; the kernel decides
whether the current one holds. -/

namespace VerifiedKernel.Session.FenceStamp
open Data

private def validRevision (value : Term) : Bool :=
  match value with | .binary raw => !raw.isEmpty | _ => false

/-- The activity revision of a write, asked of the state before it. The
current revision holds while the monitored activity signature is unchanged;
otherwise the fresh `candidate` replaces it. Args:
`{next_signature, candidate}`. -/
def activityRevision (state args : Term) : KernelM Term := do
  let .tuple [nextSignature, candidate] := args | fail "function_clause"
  let activity ← field state "activity_revision"
  let current ← if validRevision activity then pure activity else field state "storage_revision"
  if validRevision current && (← StateQuery.monitoredSignature state) == nextSignature then return current
  return candidate

def table : OpTable :=
  [("activity_revision", activityRevision)]

end VerifiedKernel.Session.FenceStamp
