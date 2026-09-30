-- Run with: lake env lean --run scripts/bench-tool-history.lean
-- Microbenchmark only; these interpreter timings are not native NIF latency.
import VerifiedKernel.Provider.Messages
open VerifiedKernel VerifiedKernel.Data VerifiedKernel.Provider

def assistant (id name : String) : Term := host [
  ("role", b "assistant"), ("content", b ""),
  ("tool_calls", list [host [("id", b id), ("name", b name), ("args", empty)]])]
def tool (id value : String) : Term := host [
  ("role", b "tool"), ("tool_call_id", b id), ("content", b value)]

set_option maxRecDepth 100000
set_option maxHeartbeats 0

def main : IO Unit := do
  for reused in [false, true] do
    for n in [100, 500, 1000] do
      let history := (List.range n).flatMap fun j =>
        let id := if reused then "call_repeat" else s!"call_{j}"
        [assistant id "call", tool id "RESULT"]
      let start ← IO.monoMsNow
      let mut count := 0
      for _ in [:3] do
        match Messages.chat history (b "google/gemini-3.8-flash") [] with
        | .error _ => throw (IO.userError "converter failed")
        | .ok (wire, _) => count := count + (items wire).length
      let elapsed ← IO.monoMsNow
      IO.println s!"reused={reused} calls={n} runs=3 total_ms={elapsed-start} output_count={count}"
