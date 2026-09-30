import VerifiedKernel.Data

/-! Classification of one model response. A response settles the turn only
when `end_turn` is its only tool call and its arguments are valid; every other
response executes its tools. The host acts on the verdict and does not inspect
the calls itself. -/

namespace VerifiedKernel.AgentLoop.TurnOutcome
open Data

/-- `Map.get(map, "key") || Map.get(map, :key)`. -/
private def value (m : Term) (key : String) : Term :=
  if !m.isMap then nil else (m.get (b key)).default (m.get (a key))

private def trimmed : Term → Term
  | .binary raw => .binary (trim raw)
  | _ => b ""

/-- The optional reply carried by `end_turn`: a target tool, its params, and an
optional IFC declaration. -/
private def reply (raw : Term) : Option Term :=
  if raw == nil then some nil else
  if !raw.isMap then none else
  let tool := value raw "tool"
  let params := value raw "params"
  let ifc := if raw.has (b "ifc") then raw.get (b "ifc") else raw.get (a "ifc")
  if !(tool.isBinary && tool != b "" && params.isMap && (ifc == nil || ifc.isMap)) then none else
  let base := Term.map [(b "tool", tool), (b "params", params)]
  some (if ifc == nil then base else base.put (b "ifc") ifc)

/-- The settlement decision for valid `end_turn` arguments. -/
def decision (args : Term) : Option Term := do
  let carried ← reply (value args "reply")
  let reason := trimmed (value args "reason")
  let outcome := value args "outcome"
  let base ←
    if outcome == b "done" then some (Term.map [(a "outcome", b "done"), (a "reason", nil)])
    else if outcome == b "blocked" && reason != b "" then
      some (Term.map [(a "outcome", b "blocked"), (a "reason", reason)])
    else none
  return if carried == nil then base else base.put (a "reply") carried

private def endTurn (call : Term) : Bool :=
  let name := value call "name"
  name == b "end_turn" || name == a "end_turn"

/-- `{:settle, decision}` for a standalone valid `end_turn`, else `:execute_tools`. -/
def classify : Term → Term
  | .list [call] =>
    if !endTurn call then a "execute_tools" else
    match decision (value call "args") with
    | some settled => .tuple [a "settle", settled]
    | none => a "execute_tools"
  | _ => a "execute_tools"

end VerifiedKernel.AgentLoop.TurnOutcome
