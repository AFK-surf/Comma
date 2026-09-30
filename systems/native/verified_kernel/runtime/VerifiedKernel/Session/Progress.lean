import VerifiedKernel.Data

namespace VerifiedKernel.Session
open Data

def terminal (record : Term) : Bool :=
  ["completed", "failed", "cancelled"].any (fun s => record.get (b "status") == b s)

def progressStep (state event : Term) : KernelM Term := do
  let calls := (← field state "async_tool_calls").default empty
  let id := event.get (b "tool_call_id")
  let record ← get? calls id
  if terminal record || !record.isMap then return state
  let progress := (event.get (b "progress")).default empty
  let timestamp := event.get (b "updated_at")
  let timestamp ← if timestamp.truthy then pure timestamp else observe (a "time")
  let next := record.put (b "progress") progress |>.put (b "updated_at") timestamp
  write state [("async_tool_calls", calls.put id next)]

end VerifiedKernel.Session
