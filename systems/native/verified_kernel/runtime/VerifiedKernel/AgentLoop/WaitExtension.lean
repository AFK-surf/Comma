import VerifiedKernel.Data

/-! Whether an expired `wait_for` is re-armed or delivered.

A Router waits for a delegated Task with `wait_for`; the Worker's report wakes
it. When the timeout fires while a delegated Worker is still busy, the wait is
re-armed for its own duration, up to a total extension ceiling. The host
supplies whether a delegate is busy, the clock and the ceiling; this function
makes the decision and builds the re-armed wait. -/

namespace VerifiedKernel.AgentLoop.WaitExtension
open Data

private def natural (wait : Term) (key : String) : Int :=
  match wait.get (b key) with
  | .integer n => if n ≥ 0 then n else 0
  | _ => 0

private def text : Term → String
  | .binary raw => String.fromUTF8! raw
  | .atom name => if name == "nil" then "" else name
  | .integer n => toString n
  | _ => ""

/-- The identity every extension of one wait derives from. -/
private def baseId (wait : Term) : String :=
  match wait.get (b "extended_from") with
  | .binary raw => if raw.isEmpty then fallback else String.fromUTF8! raw
  | _ => fallback
where fallback :=
  let id := text (wait.get (b "wait_id"))
  if id == "" then "wait" else id

/-- `{:extend, wait}` or `:wake`. -/
def decide (wait busy nowMs ceilingMs : Term) : Term :=
  if !wait.isMap || wait.get (b "source") != b "wait_for" then a "wake" else
  let timeout := match wait.get (b "timeout_seconds") with
    | .integer n => if n > 0 then n * 1000 else 60000
    | _ => 60000
  let extended := natural wait "extended_ms"
  let remaining := integerValue ceilingMs - extended
  let step := min timeout (max remaining 0)
  if step < 1000 || busy != a "true" then a "wake" else
  let count := natural wait "extensions" + 1
  let base := baseId wait
  .tuple [a "extend", wait
    |>.put (b "wait_id") (b (base ++ "-x" ++ toString count))
    |>.put (b "extended_from") (b base)
    |>.put (b "deadline_ms") (i (integerValue nowMs + step))
    |>.put (b "extended_ms") (i (extended + step))
    |>.put (b "extensions") (i count)]

end VerifiedKernel.AgentLoop.WaitExtension
