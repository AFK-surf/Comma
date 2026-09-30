import VerifiedKernel.Session.Ops

namespace VerifiedKernel.Session.ArchiveMatch
open Data

/-- Retired guard diagnostics are the only fields excluded from archive adoption. -/
def canonical (record : Term) : Term :=
  let data := record.get (a "data")
  let kind := data.get (b "kind")
  if record.get (a "kind") == b "fact" &&
      (kind == b "runaway_guard_reset" || kind == b "runaway_unsettled_round") then
    match data.get (b "event") with
    | .map fields => record.put (a "data")
        (data.put (b "event") (.map (fields.filter (fun pair => pair.1 != b "activation_key"))))
    | _ => record
  else record

def request (landed window : List Term) : Term :=
  .tuple [a "request_batch", list [
    .tuple [a "deterministic_etf", list ((landed.take window.length).map canonical)],
    .tuple [a "deterministic_etf", list ((window.take landed.length).map canonical)]]]

/-- The codec supplies full encodings. The kernel decides equality and stale-window outcomes. -/
def check (_state args : Term) : KernelM Term := do
  let .tuple [.list landed, .list window] := args | fail "invalid_term"
  let encoded ← observe (request landed window)
  let .list [.binary left, .binary right] := encoded | fail "invalid_observation"
  if left != right then return .tuple [a "error", a "segment_divergence"]
  if landed.length > window.length then return .tuple [a "error", a "archive_ahead"]
  return a "ok"

def table : OpTable := [("archive_match_prefix", check)]

end VerifiedKernel.Session.ArchiveMatch
