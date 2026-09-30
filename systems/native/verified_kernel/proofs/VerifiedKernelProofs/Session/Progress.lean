import VerifiedKernel.Session.Progress
import VerifiedKernelProofs.Data

namespace VerifiedKernel.Session
open Data

/-- Terminal progress preserves the whole state and consumes no observations. -/
theorem terminal_preserved (state event calls record : Term)
    (readCalls : field state "async_tool_calls" = pure calls)
    (readRecord : get? (calls.default empty) (event.get (b "tool_call_id")) = pure record)
    (closed : terminal record = true) :
    progressStep state event = pure state := by
  simp [progressStep, readCalls, readRecord, closed]

theorem missing_record_preserved (state event calls record : Term)
    (readCalls : field state "async_tool_calls" = pure calls)
    (readRecord : get? (calls.default empty) (event.get (b "tool_call_id")) = pure record)
    (missing : record.isMap = false) :
    progressStep state event = pure state := by
  simp [progressStep, readCalls, readRecord, missing]

end VerifiedKernel.Session
