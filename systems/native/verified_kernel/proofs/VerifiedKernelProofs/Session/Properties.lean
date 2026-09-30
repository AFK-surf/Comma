import VerifiedKernelProofs.Session.Kernel

namespace VerifiedKernel.Session
open Data

theorem terminal_settlement_preserved (state event status calls record : Term)
    (readCalls : field state "async_tool_calls" = pure calls)
    (readRecord : get? (calls.default empty) (event.get (b "tool_call_id")) = pure record)
    (closed : terminal record = true) :
    asyncTerminal state event status = pure state := by
  simp [asyncTerminal, readCalls, readRecord, closed]

theorem terminal_start_preserved (state event : Term)
    (closed : existingTerminal state (event.get (b "tool_call_id")) = pure true) :
    asyncStart state event = pure state := by
  simp [asyncStart, closed]

theorem blocked_ack_preserved (state event previous requested next : Term)
    (readPrevious : field state "last_ack_message_id" = pure previous)
    (readRequested : Data.event event "last_ack_message_id" = pure requested)
    (selected : maximum previous (requested.default (i 0)) = pure next)
    (advanced : greater next previous = pure true)
    (blocked : obligationBlocking state = true) :
    sessionAck state event = pure state := by
  simp [sessionAck, readPrevious, readRequested, selected, advanced, blocked]

theorem stale_compaction_preserved (state event baseline previous : Term) (provider : Bool)
    (readBaseline : Data.event event "summary_sequence" = pure baseline)
    (integer : baseline.isInteger = true)
    (readPrevious : field state "summary_sequence" = pure previous)
    (stale : atMost baseline (previous.default (i 0)) = pure true) :
    historyCompaction state event provider = pure state := by
  simp [historyCompaction, readBaseline, integer, readPrevious, stale]

theorem invalid_state_rejected (state event : Term)
    (invalid : Schema.admissible state true = false) :
    prepare state event = fail "schema"
      [b "Session accepts pure ETF data, the State envelope, and MapSet data only"] := by
  simp [prepare, invalid]
  rfl

end VerifiedKernel.Session
