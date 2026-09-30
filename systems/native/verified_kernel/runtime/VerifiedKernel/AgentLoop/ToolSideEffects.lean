import VerifiedKernel.Data

namespace VerifiedKernel.AgentLoop.ToolSideEffects
open Data

def forbidden (kind : Term) : Bool :=
  [b "delivery", b "queue_append", b "user_message", b "runtime_message",
    b "queue_ack", b "queue_consume", b "archive_advance", b "session_stamp"].contains kind

def invalid (reason : Term) : Term :=
  .tuple [a "error", .tuple [a "invalid_tool_side_effect_event", reason]]

def typeKey (key : Term) : Bool :=
  match stringChars key [] with
  | .ok (converted, _) => converted == b "type"
  | .error _ => false

def entry (item : Term) : Term :=
  match item with
  | .tuple [key, kind] => if forbidden kind && typeKey key then invalid kind else a "ok"
  | _ => a "ok"

def event (value : Term) : Term :=
  if !value.isMap then invalid (a "not_a_map") else
    match enumUntil value (a "ok") (fun _ item =>
      let result := entry item
      pure (result == a "ok", result)) [] with
    | .ok (result, _) => result
    | .error _ => invalid (a "not_a_map")

def eventsList : List Term → Term
  | [] => a "ok"
  | value :: rest =>
    let result := event value
    if result == a "ok" then eventsList rest else result

def events : Term → Term
  | .list values => eventsList values
  | _ => invalid (a "not_a_list")

end VerifiedKernel.AgentLoop.ToolSideEffects
