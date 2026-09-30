import Std

namespace VerifiedKernel.AgentLoop.Dependency

inductive State where
  | running (token : List UInt8)
  | retained (token : List UInt8)
  | retired
  deriving DecidableEq, Repr

structure Event where
  token : List UInt8
  kind : String
  deriving DecidableEq, Repr

inductive Command where
  | acceptResult | acceptTimeout | acceptDown | ignore
  deriving DecidableEq, BEq, Repr

def step (state : State) (event : Event) : State × Command :=
  match state with
  | .running token =>
    if token = event.token then
      if event.kind = "result" then (.retained token, .acceptResult)
      else if event.kind = "timeout" then (.retained token, .acceptTimeout)
      else if event.kind = "down" then (.retained token, .acceptDown)
      else (state, .ignore)
    else (state, .ignore)
  | _ => (state, .ignore)

end VerifiedKernel.AgentLoop.Dependency
