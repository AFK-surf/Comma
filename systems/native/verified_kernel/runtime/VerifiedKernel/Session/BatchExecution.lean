import VerifiedKernel.Session.Kernel

namespace VerifiedKernel.Session.BatchExecution
open Data

abbrev Output := Option Term × Term

def pending (state : Term) (events : List Term) : Term :=
  .tuple [a "session_batch_next", state, list events]

def observing (token : Term) (events : List Term) : Term :=
  .tuple [a "session_batch_observe", token, list events]

def next (state : Term) : List Term → Output
  | [] => (some state, .tuple [a "done"])
  | events => (some (pending state events), .tuple [a "next"])

/-- Only a completed reducer advances the captured batch. Observations retain its remaining events. -/
def accept (events : List Term) : Term → Output
  | .tuple [.atom "done", state] => next state events
  | .tuple [.atom "observe", request, token] =>
    (some (observing token events), .tuple [a "observe", request])
  | result => (none, result)

def resident (current : Option Term) (operation args : Term) : Output :=
  match operation, current, args with
  | .atom "start", some state, .list events => next state events
  | .atom "run", some (.tuple [.atom "session_batch_next", state, .list (event :: events)]), .list observations =>
    accept events (runTrusted state event observations)
  | .atom "resume", some (.tuple [.atom "session_batch_observe", token, .list events]), observation =>
    accept events (resumeTrusted token observation)
  | _, _, _ => (none, .tuple [a "raised", .tuple [a "invalid_observation", list []]])

end VerifiedKernel.Session.BatchExecution
