import VerifiedKernel.Provider.Common
import VerifiedKernel.Inspect

namespace VerifiedKernel.Provider.Error
open Data

def preview (v : Term) : Term := Id.run do
  let raw := if v.isBinary then bytes v else (Inspect.render v).toUTF8
  if raw.size ≤ 4096 then return .binary raw
  let mut cut := raw.extract 0 4096
  for _ in [:4096] do
    if (String.fromUTF8? cut).isSome then break
    cut := cut.extract 0 (cut.size - 1)
  return .binary cut

private def overflowText (text : String) : Bool :=
  let text := text.toLower
  ["context_length_exceeded", "context_window_exceeded", "max_context_length",
    "maximum context length", "prompt is too long", "input is too long",
    "exceed max message tokens"].any (fun phrase => text.contains phrase) ||
    ((text.contains "context window" || text.contains "context length" ||
      text.contains "context limit" ||
      text.contains "input token count" || text.contains "input length") &&
      (text.contains "exceed" || text.contains "too long" || text.contains "too large"))

/-- Inspect error fields before truncating diagnostics. Do not confuse output or rate limits with input overflow. -/
private def overflowValue : Nat → Term → Bool
  | 0, _ => false
  | fuel + 1, value =>
    match value with
    | .binary raw =>
      match Json.decode raw with
      | some decoded => overflowValue fuel decoded
      | none => overflowText (String.fromUTF8! raw)
    | .map _ =>
      ["error", "errors", "code", "type", "message", "reason", "details", "response", "incomplete_details"].any
        (fun key => overflowValue fuel (field value key))
    | .list values => values.any (overflowValue fuel)
    | _ => false

def overflow (value : Term) : Bool := overflowValue 8 value

def base (provider category message : Term) (retryable := false) : Term :=
  obj [("type", b "llm_error"), ("provider", provider), ("category", category),
    ("message", message), ("retryable", Term.bool retryable)]

def permanent (provider reason : String) : Term :=
  let message := if reason == "output_token_limit" then
    "LLM tool output reached the output token limit. Increase the agent template's Max tokens or reduce the requested output size before retrying."
    else "LLM tool arguments must be a complete JSON object; the provider returned incomplete or invalid arguments. No tools from this response were executed."
  .tuple [a "error", (base (b provider) (b "permanent_provider_error") (b message)).put (b "reason") (b reason)]

def transport (provider : Term) (reason : Term) : Term :=
  .tuple [a "error", (base provider (b "transport_error") (b "LLM provider transport failed") true).put (b "reason") (preview reason)]

def http (provider status body : Term) : KernelM Term := do
  let retryable := match status with | .integer n => n == 408 || n == 429 || n ≥ 500 | _ => false
  let over := status != i 429 && status != i 401 && status != i 403 && overflow body
  let category := if over then "context_overflow" else if retryable then "retryable_provider_error" else "permanent_provider_error"
  let message ← if over then pure (b "LLM provider rejected the request as over context") else cat [b "LLM provider returned HTTP ", status]
  return .tuple [a "error", (base provider (b category) message (!over && retryable)).put (b "status") status |>.put (b "body") (preview body)]

def state (provider status details : Term) : KernelM Term := do
  if !member status ["incomplete", "failed", "cancelled", "expired"] then return nil
  let over := overflow details
  let category := if over then "context_overflow" else "permanent_provider_error"
  let message ← if over then pure (b "LLM provider rejected the request as over context") else cat [b "LLM provider response ended as ", status]
  return .tuple [a "error", (base provider (b category) message).put (b "provider_status") status |>.put (b "details") (preview details)]

end VerifiedKernel.Provider.Error
