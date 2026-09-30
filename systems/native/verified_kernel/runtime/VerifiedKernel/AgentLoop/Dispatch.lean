import VerifiedKernel.Term
import VerifiedKernel.AgentLoop.Dependency
import VerifiedKernel.AgentLoop.Policy
import VerifiedKernel.AgentLoop.ToolSideEffects
import VerifiedKernel.AgentLoop.TerminalReply
import VerifiedKernel.AgentLoop.CompletionWake
import VerifiedKernel.AgentLoop.CallEnvelope

namespace VerifiedKernel.AgentLoop

abbrev Identity := Option (List UInt8)

def terminalOwner (ownerSession ownerCall session call : Identity) : Bool :=
  decide (ownerSession = session ∧ ownerCall = call)

private def boolean : Term → Except String Bool
  | .atom "true" => .ok true
  | .atom "false" => .ok false
  | _ => .error "expected_boolean"

private def natural : Term → Except String Nat
  | .integer n => if n ≥ 0 then .ok n.toNat else .error "expected_natural"
  | _ => .error "expected_natural"

private def identity : Term → Except String Identity
  | .atom "nil" => .ok none
  | .binary bytes => .ok (some bytes.data.toList)
  | _ => .error "expected_identity"

private def dependencyState : Term → Except String Dependency.State
  | .tuple [.atom "running", .binary token] => .ok (.running token.data.toList)
  | .tuple [.atom "retained", .binary token] => .ok (.retained token.data.toList)
  | .atom "retired" => .ok .retired
  | _ => .error "invalid_dependency_state"

private def encodeDependency : Dependency.State → Term
  | .running token => .tuple [.atom "running", .binary ⟨token.toArray⟩]
  | .retained token => .tuple [.atom "retained", .binary ⟨token.toArray⟩]
  | .retired => .atom "retired"

private def encodeCommand : Dependency.Command → Term
  | .acceptResult => .atom "accept_result"
  | .acceptTimeout => .atom "accept_timeout"
  | .acceptDown => .atom "accept_down"
  | .ignore => .atom "ignore"

def invoke : Term → Term → Except String Term
  | .atom "validate_tool_events", payload => .ok (ToolSideEffects.events payload)
  | .atom "activation", .tuple [l, c, r] => do
    return .atom (Policy.activation (← boolean l) (← boolean c) (← boolean r))
  | .atom "retry_admission", .tuple [.atom "invalid", n] => do
    let _ ← natural n
    return .atom "ignore"
  | .atom "retry_admission", .tuple [r, n] => do
    return .atom (Policy.retryAdmission (← boolean r) (← natural n))
  | .atom "retry_failure", .tuple [n, b] => do
    return .atom (Policy.retryFailure (Int.ofNat (← natural n)) (Int.ofNat (← natural b)))
  | .atom "terminal_owner", .tuple [os, oc, s, c] => do
    return .atom (if terminalOwner (← identity os) (← identity oc) (← identity s) (← identity c)
      then "true" else "false")
  | .atom "dependency_step", .tuple [state, .tuple [.binary token, .atom event]] => do
    let (next, command) := Dependency.step (← dependencyState state) ⟨token.data.toList, event⟩
    return .tuple [encodeDependency next, encodeCommand command]
  | .atom "terminal_reply_admission", .tuple [call, scope, flags] =>
    match (TerminalReply.admit call scope flags).run' [] with
    | .ok result => .ok result
    | .error _ => .error "invalid_terminal_reply_call"
  | .atom "call_envelope", args =>
    match (CallEnvelope.decode args).run' [] with
    | .ok result => .ok result
    | .error _ => .error "invalid_call_envelope"
  | .atom "completion_wake", .tuple [own, siblings, events] =>
    .ok (CompletionWake.decide own siblings events)
  | _, _ => .error "invalid_agent_loop_request"

end VerifiedKernel.AgentLoop
