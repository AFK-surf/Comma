import Std

namespace VerifiedKernel.AgentLoop

def runTrace (step : S → E → S × List C) (state : S) : List E → S × List C
  | [] => (state, [])
  | event :: rest =>
    let (next, commands) := step state event
    let (finish, later) := runTrace step next rest
    (finish, commands ++ later)

end VerifiedKernel.AgentLoop
