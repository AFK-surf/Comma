import VerifiedKernel.Provider.Request
import VerifiedKernel.Provider.Response
import VerifiedKernel.Provider.Usage
import VerifiedKernel.Provider.Complete

namespace VerifiedKernel.Provider
open Data

private def providerName (protocol : Term) : Term :=
  if protocol == b "anthropic" then protocol else if protocol == b "responses" then b "openai_responses" else b "openai_chat"

def retry (status seen : Term) (attempts : Int) : Term :=
  let retryable := match status with
    | .integer n => n == 408 || n == 429 || n ≥ 500
    | .atom "transport" => seen != a "true"
    | _ => false
  if retryable && attempts > 1 then .tuple [a "retry", i ((4 - attempts) * 1000), i (attempts - 1)] else a "stop"

def run : Term → Term → KernelM Term
  | .atom "error", .tuple [.atom "http", provider, .tuple [status, body]] => Error.http provider status body
  | .atom "error", .tuple [.atom "transport", provider, reason] => pure (Error.transport provider reason)
  | .atom "error", .tuple [.atom "provider_state", provider, .tuple [status, details]] => Error.state provider status details
  | .atom "error", .tuple [.atom "output_token_limit", .binary provider, _] => pure (Error.permanent (String.fromUTF8! provider) "output_token_limit")
  | .atom "error", .tuple [.atom "invalid_tool_arguments", .binary provider, _] => pure (Error.permanent (String.fromUTF8! provider) "invalid_tool_arguments")
  | .atom "error", .tuple [kind, provider, details] => do
    if kind != a "refusal" && kind != a "context_overflow" then fail "argument" [b "unsupported provider error"]
    let (category, message) := if kind == a "refusal" then
      ("provider_refusal", "LLM provider declined to answer the request") else
      ("context_overflow", "LLM provider rejected the request as over context")
    pure (.tuple [a "error", (Error.base provider (b category) (b message)).put (b "details") (Error.preview details)])
  | .atom "blocking_policy", .tuple [mode, retryPolicy] =>
    pure (if mode == b "compact" then .tuple [a "false", a "transient", a "true"] else .tuple [a "true", retryPolicy, a "false"])
  | .atom "config", .tuple [overrides, apiKey, authToken] => Request.config overrides apiKey authToken
  | .atom "encoded_body", .tuple [.binary protocol, cfg, .list messages, .list tools, .binary mode] =>
    Request.encodedBody (String.fromUTF8! protocol) cfg messages tools (String.fromUTF8! mode)
  | .atom "endpoint", .tuple [.binary protocol, cfg, .binary mode] => Request.endpoint (String.fromUTF8! protocol) cfg (String.fromUTF8! mode)
  | .atom "anthropic_headers", .tuple [cfg, .list extra] => do
    let .tuple [_, headers] ← Request.endpoint "anthropic" cfg "complete" extra | fail "badarg"
    return headers
  | .atom "stream_attempts", .tuple [protocol, custom] => pure (i (if protocol == b "responses" && custom != a "true" then 3 else 1))
  | .atom "configuration_error", .tuple [protocol, reason] => do
    let name := if protocol == b "anthropic" then "Anthropic" else if protocol == b "responses" then "OpenAI Responses" else "OpenAI Chat"
    return .tuple [a "error", (Error.base (providerName protocol) (b "configuration_error") (b (name ++ " request was rejected before transport"))).put (b "reason") reason]
  | .atom "watchdog_phase", .tuple [.integer status, redirect, location] =>
    pure (if [301, 302, 303, 307, 308].contains status && redirect.truthy && location == a "true" then a "first_event" else a "streaming")
  | .atom "complete", .tuple [.binary protocol, resp, model, compact] => Complete.response (String.fromUTF8! protocol) resp model (compact == a "true")
  | .atom "decode_stream", .tuple [.binary protocol, .binary raw, model] => Complete.stream (String.fromUTF8! protocol) raw model
  | .atom "events", .binary raw => pure (list (Stream.events raw))
  | .atom "data_line", .binary raw => pure (match Stream.event raw with | some ev => .tuple [a "ok", ev] | none => a "error")
  | .atom "normalize", v => pure ((decode v).getD v)
  | .atom "http_error", .tuple [protocol, status, body] => Error.http (providerName protocol) status body
  | .atom "stream_http_error", .tuple [protocol, status, body] =>
    Error.http (providerName protocol) status (if protocol == b "anthropic" then (decode body).getD body else body)
  | .atom "transport_error", .tuple [protocol, reason] => pure (Error.transport (providerName protocol) reason)
  | .atom "retry", .tuple [status, seen, .integer attempts] =>
    pure (retry status seen attempts)
  | .atom "anthropic_parts", .tuple [.list messages, model] => Messages.anthropicParts messages model
  | .atom "chat_messages", .tuple [.list messages, model] => Messages.chat messages model
  | .atom "responses_parts", .list messages => Messages.responsesParts messages
  | .atom "tools", .tuple [.binary protocol, .list tools] => return list (← tools.mapM (toolSpec (String.fromUTF8! protocol)))
  | .atom "cache", .tuple [system, tools, messages, enabled, trailing] => pure (Request.cache system tools messages enabled trailing)
  | .atom "parse_anthropic", .tuple [resp, model] => Response.anthropic resp model
  | .atom "parse_chat", resp => Response.chat resp
  | .atom "parse_responses", resp => Response.responses resp
  | .atom "chat_metadata", resp => pure (Response.chatMetadata resp)
  | .atom "chat_delta_metadata", deltas => Response.chatDeltaMetadata (items deltas)
  | .atom "usage", .tuple [.atom "anthropic", v] => pure (Usage.anthropic v)
  | .atom "usage", .tuple [.atom "openai", v] => pure (Usage.openai v)
  | .atom "usage", .tuple [.atom "openai_chat", v] => pure (Usage.chat v)
  | .atom "usage", .tuple [.atom "responses", v] => pure (Usage.responses v)
  | .atom "attach_usage", .tuple [result, usage, model] => pure (Usage.attach result usage model)
  | _, _ => fail "argument" [b "unsupported provider operation"]

def invoke (op payload : Term) : Term :=
  match run op payload [] with
  | .ok (value, _) => .tuple [a "value", value]
  | .error (.raised reason) => .tuple [a "raised", reason]
  | .error (.observe _) => .tuple [a "raised", b "provider projection requested an observation"]

def resident (current : Option Term) (op payload : Term) : Option Term × Term :=
  match op, payload, current with
  | .atom "new", .tuple [protocol, model, callback], _ =>
    (some (Stream.new protocol model callback), .tuple [a "value", a "opened"])
  | .atom "feed", .tuple [.binary raw, success], some st =>
    let (next, actions) := Stream.feed st raw (success == a "true")
    (some next, .tuple [a "value", actions])
  | .atom "raw", _, some st => (current, .tuple [a "value", .binary (Stream.rawBody st)])
  | .atom "finish", _, some st =>
    let answer := invoke (a "decode_stream") (.tuple [field st "protocol", .binary (Stream.rawBody st), field st "model"])
    match answer with
    | .tuple [.atom "value", value] => (current, .tuple [a "value", .tuple [Stream.finalActions st, value]])
    | _ => (current, answer)
  | _, _, _ => (current, .tuple [a "raised", b "invalid provider stream operation"])

end VerifiedKernel.Provider
