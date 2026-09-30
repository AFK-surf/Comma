import VerifiedKernel.Data

/-! Whether a settling background result wakes the session.

The host reports the completion owner of the settling call and of every other
process-local call of this actor that is still running or retained for a commit
retry. A direct-poll completion never activates and never counts as a sibling.
While another settlement is due, the result's runtime notification is committed
without a wake, so the last settlement of the batch activates once and a
response computed earlier is not steered by a result that lands during it. -/

namespace VerifiedKernel.AgentLoop.CompletionWake
open Data

private def activates (owner : Term) : Bool := owner != b "direct_poll"

private def held (event : Term) : Term :=
  if event.get (b "type") == b "queue_append" && event.get (b "kind") == b "runtime_message" then
    event.put (b "wake") (a "false")
  else event

/-- `{events, continue?, speculate?}`: the events with their wake decided,
whether the settlement continues the session, and whether a speculative model
call may start before persistence settles. -/
def decide (own siblings events : Term) : Term :=
  let due := (wrap siblings).any activates
  let events := match events with
    | .list xs => if due then .list (xs.map held) else events
    | other => other
  .tuple [events, Term.bool (activates own), Term.bool (activates own && !due)]

end VerifiedKernel.AgentLoop.CompletionWake
