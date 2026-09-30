import VerifiedKernel.Session.Lifecycle
import VerifiedKernel.ETF
import VerifiedKernel.Session.StorageAddress

namespace VerifiedKernel.Session.StorageCommit
open Data

def prepare (state args : Term) : KernelM Term := do
  let .tuple [key, base] := args | fail "invalid_term"
  if !StorageAddress.agrees state key then fail "session_key_mismatch"
  else do
    let snapshot ← Lifecycle.persistable state
    match ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) with
    | .ok bytes => pure (.tuple [a "cas", key, .binary bytes, base])
    | .error reason => fail "wire" [b reason]

def finish (_state result : Term) : KernelM Term :=
  match result with
  | .tuple [.atom "ok", etag, _outcome] => pure (.tuple [a "ok", etag])
  | .tuple [.atom "error", .atom "settlement_indeterminate"] =>
    pure (.tuple [a "error", a "commit_indeterminate"])
  | .tuple [.atom "error", reason] => pure (.tuple [a "error", reason])
  | _ => fail "invalid_observation"

/-- A single storage continuation retains the candidate without encoding it again on resume. -/
def resident (current : Option Term) (operation args : Term) : Option Term × Term :=
  match operation, current with
  | .atom "start", some state =>
    match prepare state args [] with
    | .ok (request, []) => (some (.tuple [a "storage_commit_pending", state]), request)
    | .error (.raised reason) => (none, .tuple [a "error", reason])
    | _ => (none, .tuple [a "error", a "invalid_term"])
  | .atom "resume", some (.tuple [.atom "storage_commit_pending", state]) =>
    match finish state args [] with
    | .ok (result, []) => (some state, result)
    | _ => (none, .tuple [a "error", a "invalid_observation"])
  | _, _ => (none, .tuple [a "error", a "invalid_term"])

end VerifiedKernel.Session.StorageCommit
