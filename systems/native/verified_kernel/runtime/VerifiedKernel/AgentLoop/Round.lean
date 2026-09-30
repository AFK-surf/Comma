import Std

namespace VerifiedKernel.AgentLoop.Round

inductive State where
  | ready | awaitIntent | awaitTools | awaitResults | settled | failed
  deriving DecidableEq, BEq, Repr

inductive Event where
  | start | committed | executed | failed | irrelevant
  deriving DecidableEq, BEq, Repr

inductive Command where
  | commitIntent | executeTools | commitResults | continue | stop | ignore
  deriving DecidableEq, BEq, Repr

def step : State → Event → State × Command
  | .ready, .start => (.awaitIntent, .commitIntent)
  | .awaitIntent, .committed => (.awaitTools, .executeTools)
  | .awaitTools, .executed => (.awaitResults, .commitResults)
  | .awaitResults, .committed => (.settled, .continue)
  | .awaitIntent, .failed | .awaitTools, .failed | .awaitResults, .failed => (.failed, .stop)
  | state, _ => (state, .ignore)

end VerifiedKernel.AgentLoop.Round
