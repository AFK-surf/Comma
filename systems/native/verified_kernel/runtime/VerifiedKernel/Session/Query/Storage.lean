import VerifiedKernel.Session.Ops
import VerifiedKernel.Session.Kernel
import VerifiedKernel.Session.Query.StateCore

/-! Queries ported from the session work index, format migrations, backups, and snapshot repair. See the README query catalog. -/

namespace VerifiedKernel.Session.StorageQuery
open Data

/-- `to_string(value || "")` over one scalar. -/
private def statusText (value : Term) : KernelM Term := stringChars (value.default (b ""))

/-- The `{key, payload}` pairs `sortBy` carries through an Elixir `Enum.sort_by`. -/
private def keyOf (entry : Term) : KernelM Term :=
  match entry with | .tuple [key, _] => pure key | _ => fail "invalid_term"

private def payloadOf (entry : Term) : Option Term :=
  match entry with | .tuple [_, value] => some value | _ => none

private def indexed (xs : List Term) : List (Nat × Term) := xs.zipIdx.map (fun p => (p.2, p.1))

/-- `SessionFormat1BackupPrune.terminal_results_from_backup/1`.

Replays the format-1 migration's deterministic total order over a legacy
snapshot — segment ① is the covered messages plus every fact, segment ② the
terminal async calls ordered by `{completed_at, tool_call_id}` — and pins each
terminal record to the exact seq the migration must have given it. The value is
a list of `{tool_call_id, call, expected_seq}`. -/
def terminalResultsFromBackup (state : Term) : KernelM Term := do
  let calls ← entries ((← field state "async_tool_calls").default empty)

  let terminal ← calls.filterM (fun pair => do
    let status ← statusText (← access pair.2 (b "status"))
    return status == b "completed" || status == b "failed" || status == b "cancelled")

  let messages ← asList ((← field state "messages").default (list []))
  let boundary := (← field state "compacted_through").default (i 0)

  let covered ← messages.filterM (fun message => do
    let id ← alias message (a "id") (b "id")
    atMost (id.default (i 0)) boundary)

  let events ← asList ((← field state "events").default (list []))
  let start := Int.ofNat (covered.length + events.length) + 1

  let keyed ← terminal.mapM (fun pair => do
    let when := (← access pair.2 (b "completed_at")).default (i 0)
    return Term.tuple [.tuple [when, pair.1], .tuple [pair.1, pair.2]])

  let ordered := (← sortBy keyed keyOf).filterMap payloadOf

  return list ((indexed ordered).filterMap (fun pair =>
    match pair.2 with
    | .tuple [id, call] => some (Term.tuple [id, call, i (Int.ofNat pair.1 + start)])
    | _ => none))

/-- Project the hot collections into the archive's ordered record format. -/
def windowRecords (state : Term) : KernelM Term := do
  let collect (fieldName : String) (seqKey : Term) (kind : String) := do
    let records ← asList ((← field state fieldName).default (list []))
    records.filterMapM (fun record => do
      let seq ← access record seqKey
      let kind := if fieldName == "async_results" then
        (record.get (b "kind")).default (b kind) else b kind
      if !seq.isInteger || !kind.isBinary then return none
      let data ← stringify (← remove (← remove record (a "seq")) (b "seq"))
      return some (.map [(a "seq", seq), (a "kind", kind), (a "data", data)]))
  let messages ← collect "messages" (a "seq") "message"
  let events ← collect "events" (b "seq") "fact"
  let results ← collect "async_results" (b "seq") "async_result"
  return list (← sortBy (messages ++ events ++ results) (fun record => pure (record.get (a "seq"))))

/-- Capture the contiguous window and compaction ceiling before storage I/O. -/
def archiveWindow (state : Term) : KernelM Term := do
  let records ← windowRecords state
  let first ← add ((← field state "archived_through").default (i 0)) (i 1)
  let checked ← (← asList records).foldlM (fun result record => do
    match result with
    | .tuple [.atom "error", _] => pure result
    | expected =>
      let seq := record.get (a "seq")
      if seq != expected then
        return .tuple [a "error", .tuple [a "window_seq_gap", expected, seq]]
      add expected (i 1)) first
  match checked with
  | .tuple [.atom "error", _] => return checked
  | _ => return .tuple [a "ok", records, (← field state "compacted_seq").default (i 0)]

/-- Name → operation. Names match the Elixir functions they replace. -/
def table : OpTable :=
  [("terminal_results_from_backup", fun state _ => terminalResultsFromBackup state),
   ("archive_window_records", fun state _ => windowRecords state),
   ("archive_window", fun state _ => archiveWindow state)]

end VerifiedKernel.Session.StorageQuery
