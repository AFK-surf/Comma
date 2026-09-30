import VerifiedKernel.Session.Activity
import VerifiedKernel.Session.Queue

namespace VerifiedKernel.Session
open Data

def normalizeScope (values : Term) : KernelM (List Term) := do
  let flat := (wrap values).flatMap (fun value => match value with | .list xs => xs | _ => [value])
  let strings ← flat.mapM stringChars
  sorted (uniq (strings.filter (!missing ·)))

def pendingInput (message : Term) : KernelM Bool := do
  let role ← alias message (a "role") (b "role")
  if role == b "user" || role == b "runtime" then return (← access message (a "no_wake")) != a "true"
  return false

def scopeParts (message : Term) : KernelM (List Term) := do
  let trusted := (← alias message (a "trusted_origin_source_message_ids") (b "trusted_origin_source_message_ids")).default (list [])
  match trusted with
  | .list (_ :: _) => return wrap trusted
  | _ => pure ()
  let candidates ← [a "source_message_id", b "source_message_id", a "runtime_message_id", b "runtime_message_id",
    a "dedupe_key", b "dedupe_key", a "id", b "id"].mapM (access message)
  let selected := candidates.findSome? (fun value =>
    if value.isBinary && value != b "" then some value
    else if value.isInteger then some (b (toString (integerValue value))) else none)
  return selected.toList

def compactedScope (state : Term) : KernelM (List Term) := do
  let scope := (← field state "visible_reply_activation_scope").default empty
  let past ← greater ((← field state "compacted_through").default (i 0)) ((← field state "last_ack_message_id").default (i 0))
  if past && scope.isMap then
    normalizeScope ((← alias scope (b "source_message_ids") (a "source_message_ids")).default (list []))
  else pure []

def liveScope (state : Term) : KernelM (List Term) := do
  let compacted ← compactedScope state
  let messages := wrap (← field state "messages")
  let ack := (← field state "last_ack_message_id").default (i 0)
  let selected ← messages.filterM (fun message => do
    let id := i (integerValue (← alias message (a "id") (b "id")))
    if ← greater id ack then pendingInput message else pure false)
  -- Collected in reverse: `normalizeScope` sorts, so order does not matter,
  -- and appending at the end once per pending message is quadratic.
  let parts ← selected.foldlM (fun acc message => return (← scopeParts message).reverse ++ acc) []
  let live ← normalizeScope (list parts)
  normalizeScope (list (compacted ++ live))

def unacked (state : Term) : KernelM Bool := do
  less ((← field state "last_ack_message_id").default (i 0)) (← highWatermark state)

def storedScope (state : Term) : KernelM (List Term) := do
  let current := state.get (a "active_source_message_ids")
  let current := if state.has (a "active_source_message_ids") then current else list []
  if current != list [] then return ← normalizeScope current
  let value ← field state "runaway_unsettled_streak"
  let legacy := if value.isMap then value else empty
  normalizeScope ((← alias legacy (b "key") (b "activation_key")).default (list []))

def activationKey (state : Term) : KernelM (List Term) := do
  let current ← normalizeScope (list (← liveScope state))
  if !current.isEmpty then return current
  if ← unacked state then storedScope state else pure []

/-- A background tool completion or a wait timeout is the loop's own wake, not
fresh input: it keeps the repeated-result and round-budget counts. -/
def resetFresh (state message : Term) : KernelM Term := do
  if !(← pendingInput message) then return state
  let source ← alias message (a "source_tool_call_id") (b "source_tool_call_id")
  let kind ← alias message (a "type") (b "type")
  let repeated ← if source.isBinary then field state "repeated_tool_result_streak" else pure nil
  let rounds ← if source.isBinary || kind == b "wait_expired" then field state "input_round_streak" else pure nil
  let current ← activationKey state
  write state [("runaway_unsettled_streak", .map [(b "count", i 0)]), ("repeated_tool_result_streak", repeated),
    ("input_round_streak", rounds), ("active_source_message_ids", list current)]

end VerifiedKernel.Session
