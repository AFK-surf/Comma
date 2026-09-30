import VerifiedKernel.Encoding
import VerifiedKernel.Session.Progress

namespace VerifiedKernel.Session
open Data

def resolveResult (state ref : Term) : KernelM Term := do
  let calls := (← field state "async_tool_calls").default empty
  let results := (← field state "async_results").default (list [])
  let live ← get? calls ref
  if live.truthy then return .tuple [a "ok", live]
  let refs := (← field state "async_result_refs").default empty
  let seq ← get? refs ref
  if seq.truthy then
    let found ← enumFind results (fun candidate => return (← access candidate (b "seq")).numericEq seq)
    return if found == nil then .tuple [a "archived", seq] else .tuple [a "ok", found]
  let found ← enumFind results (fun candidate => return (← access candidate (b "result_ref")).numericEq ref)
  if found.truthy then return .tuple [a "ok", found]
  let found ← enumFind results (fun candidate => return (← access candidate (b "tool_call_id")).numericEq ref)
  return if found.truthy then .tuple [a "ok", found] else a "not_found"

def existingTerminal (state id : Term) : KernelM Bool := do
  if !id.isBinary || id == b "" then return false
  match ← resolveResult state id with
  | .tuple [.atom "ok", record] => return terminal record
  | .tuple [.atom "archived", _] => return true
  | _ => return false

/-- A callback's request deadline is independent of the model's wait slot.
Old records without a request snapshot are due for reconciliation, not assumed expired. -/
def capabilityDueAt (record : Term) : Term :=
  if record.get (b "completion_mode") != b "external_callback" ||
      record.get (b "capability_sync_failed") == a "true" then nil
  else if (record.get (b "capability_retry_at_ms")).isInteger then
    record.get (b "capability_retry_at_ms")
  else if terminal record then (record.get (b "completed_at")).default (i 1)
  else if (record.get (b "capability_deadline_ms")).isInteger then
    record.get (b "capability_deadline_ms")
  else i 1

/-- Only the session owner applies request observations. Terminal execution
records stay discoverable until the request owner acknowledges their outcome. -/
def capabilitySync (state event : Term) : KernelM Term := do
  let id := event.get (b "tool_call_id")
  let calls := (← field state "async_tool_calls").default empty
  let record ← get? calls id
  if !record.isMap || (record.get (b "completion_mode") != b "external_callback" &&
      event.get (b "completion_mode") != b "external_callback") then return state
  if event.get (b "settled") == a "true" && terminal record then
    return ← write state [("async_tool_calls", ← remove calls id)]
  let patch := select event ["completion_mode", "capability_request_id", "capability_deadline_ms",
    "capability_retry_at_ms", "capability_sync_failed", "capability_error_since_ms"]
  let record ← merge record patch
  write state [("async_tool_calls", ← put calls id record)]

def asyncStart (state event : Term) : KernelM Term := do
  let id := event.get (b "tool_call_id")
  if ← existingTerminal state id then return state
  let selected := select event ["tool_call_id", "tool_name", "input", "status", "completion_mode",
    "completion_owner", "started_at", "auto_wait_seconds", "visible_reply_origin", "terminal_reply",
    "capability_request_id", "capability_deadline_ms", "capability_retry_at_ms",
    "capability_sync_failed", "capability_error_since_ms",
    "trusted_origin", "trusted_origins", "trusted_origin_source_message_ids"]
  let record := selected.put (b "status") ((event.get (b "status")).default (b "running"))
  let calls := (← field state "async_tool_calls").default empty
  write state [("async_tool_calls", ← put calls id record)]

def businessOutput (content output : Term) : Term :=
  if output == nil || output.numericEq content then content else .tuple [content, output]

def noteResult (state tool input status errorClass message content : Term) : KernelM Term := do
  if !tool.isBinary || tool == b "wait_for" || tool == b "tool_call.get_result" ||
      status == b "async_running" || status == b "running" then return state
  let outcome := if status == b "error" then b "failed" else status
  let hash ← fingerprint (.tuple [tool, input, outcome, errorClass, message, content])
  let previous ← field state "repeated_tool_result_streak"
  let oldCount := previous.get (b "count")
  let count ← if previous.get (b "fingerprint") == hash && oldCount.isInteger && integerValue oldCount > 0 then
    add oldCount (i 1) else pure (i 1)
  write state [("repeated_tool_result_streak", .map [(b "fingerprint", hash), (b "tool_name", tool), (b "count", count)])]

def noteAsyncResult (state existing event status : Term) : KernelM Term := do
  let result ← Data.event event "result"
  let result ← if result.isMap then Data.event event "result" else pure empty
  let tool ← Data.event existing "tool_name"
  let input ← Data.event existing "input"
  let errorClass ← Data.event event "error_class"
  let message ← Data.event event "error_message"
  let content ← Data.event result "content"
  let output ← Data.event result "output"
  noteResult state tool input status errorClass message (businessOutput content output)

def asyncTerminal (state event status : Term) : KernelM Term := do
  let id := event.get (b "tool_call_id")
  let calls := (← field state "async_tool_calls").default empty
  let existing ← get? calls id
  if existing == nil || terminal existing then return state
  let overlay := select event ["result", "error", "error_class", "error_message", "diagnostic_visibility",
    "public_summary", "visible_reply_origin", "duration_ms", "completed_at", "cancelled_at", "cancel_reason"]
  let record0 := (← merge existing overlay).put (b "status") status |>.put (b "kind") (b "async_result") |>.put (b "tool_call_id") id
  let seq ← add ((← field state "last_seq").default (i 0)) (i 1)
  let record := record0.put (b "seq") seq
  let results := (← field state "async_results").default (list [])
  let results ← append results (list [record])
  let refs := (← field state "async_result_refs").default empty
  let refs ← put refs id seq
  let calls ← if existing.get (b "completion_mode") == b "external_callback" then
      put calls id ((record.put (b "capability_retry_at_ms") (record.get (b "completed_at"))).put
        (b "capability_sync_failed") (a "false"))
    else remove calls id
  let next ← write state [("async_tool_calls", calls), ("async_results", results),
    ("async_result_refs", refs), ("last_seq", seq)]
  noteAsyncResult next existing event status

end VerifiedKernel.Session
