import VerifiedKernel.Data

/-! The `call` envelope of an internal LLM session. The model runs a capability
through `call` with `tool`, `params` and an optional `ifc` declaration. The
envelope names one operation. A malformed envelope is guidance for the model,
never a dispatch. -/

namespace VerifiedKernel.AgentLoop.CallEnvelope
open Data

/-- `args[key] || args[:key]`. -/
private def raw (args : Term) (key : String) : Term :=
  if args.isMap then (args.get (b key)).default (args.get (a key)) else nil

private def envelopeKey : Term → Option String
  | .binary raw => if raw == "params".toUTF8 then some "params" else if raw == "tool".toUTF8 then some "tool"
      else if raw == "ifc".toUTF8 then some "ifc" else none
  | .atom "params" => some "params"
  | .atom "tool" => some "tool"
  | .atom "ifc" => some "ifc"
  | _ => none

/-- `exact_envelope_keys?/2`: the keys, as strings, are exactly `expected`. -/
private def exactKeys (value : Term) (expected : List String) : Bool :=
  match value with
  | .map pairs =>
    let keys := pairs.map (fun pair => envelopeKey pair.1)
    keys.all Option.isSome && keys.length == expected.length &&
      expected.all (fun key => keys.count (some key) == 1)
  | _ => false

private def trimmed : Term → Term
  | .binary bytes => .binary (trim bytes)
  | other => other

/-- A repeated function-arguments field: `{params: {tool, params[, ifc]}}`. -/
private def unwrap (args : Term) : Term :=
  let nested := raw args "params"
  let tool := raw nested "tool"
  if exactKeys args ["params"] && nested.isMap &&
      (exactKeys nested ["params", "tool"] || exactKeys nested ["ifc", "params", "tool"]) &&
      tool.isBinary && trimmed tool != b "" && (raw nested "params").isMap then nested
  else args

private def text (value : Term) : KernelM Term := do
  if value == nil then return b ""
  stringChars value

/-- `{:ok, target, params, ifc, reply_intent}` or `{:error, reason, target}`.
`reply_intent` keeps the original `reply_mode` and `final_outcome`. -/
def decode (args : Term) : KernelM Term := do
  if !args.isMap then return .tuple [a "error", b "call arguments must be an object", b ""]
  let intent := select args ["reply_mode", "final_outcome"]
  let envelope := unwrap args
  let target := trimmed (← text (raw envelope "tool"))
  if target == b "" then return .tuple [a "error", b "'tool' is required", b ""]
  if target == b "call" then
    return .tuple [a "error", b "call is the internal LLM tool envelope and cannot be nested; put the target business tool directly in the outer tool field", target]
  let params := raw envelope "params"
  if !params.isMap then return .tuple [a "error", b "'params' is required and must be a JSON object", target]
  return .tuple [a "ok", target, params, raw envelope "ifc", intent]

end VerifiedKernel.AgentLoop.CallEnvelope
