import VerifiedKernel.ETF
import VerifiedKernel.Session.Kernel
import VerifiedKernel.Schema
import VerifiedKernel.Session.Query
import VerifiedKernel.IFC.Dispatch
import VerifiedKernel.AgentLoop.Dispatch
import VerifiedKernel.Provider.Dispatch
import VerifiedKernel.Session.ArchivePublication
import VerifiedKernel.Session.BatchExecution
import VerifiedKernel.Session.PendingRevision
import VerifiedKernel.Session.RevisionFence
import VerifiedKernel.Session.CommandDriver
import VerifiedKernel.Session.Loop
import VerifiedKernel.Session.Drive

namespace VerifiedKernel

private def ok (payload : Term) : Term := .tuple [.integer 1, .atom "ok", payload]
private def error (domain : String) (code : String) : Term :=
  .tuple [.integer 1, .atom "error", .atom domain, .text code]

/-- `{1, :error, :wire, "encode_error"}` for a response that cannot be encoded. -/
private def encodeError : ByteArray :=
  ⟨#[131, 104, 4, 97, 1, 119, 5, 101, 114, 114, 111, 114,
     119, 4, 119, 105, 114, 101, 109, 0, 0, 0, 12]⟩ ++ "encode_error".toUTF8

def dispatch : Term → Term
  | .tuple [.integer 1, .atom "provider", .integer 1, operation, payload] => ok (Provider.invoke operation payload)
  | .tuple [.integer 1, .atom "agent_loop", .integer 1, operation, payload] =>
    match AgentLoop.invoke operation payload with
    | .ok result => ok result
    | .error code => error "agent_loop" code
  | .tuple [.integer 1, .atom "ifc", .integer 1, operation, payload] => ok (IFC.invoke operation payload)
  | .tuple [.integer 1, .atom "codec", .integer 1, .atom "roundtrip", payload] => ok payload
  | _ => error "wire" "unsupported_request"

@[export salix_verified_kernel_invoke]
def invoke (bytes : ByteArray) : ByteArray :=
  let response := match ETF.decode bytes with
    | .ok request => dispatch request
    | .error code => error "wire" code
  match ETF.encode response with
  | .ok output => output
  | .error _ => encodeError

/-! ### Session domain

The Session state is resident in the kernel. The host passes the current
resident state by reference and receives the next resident state by
reference. Lifecycle operations produce a resident state, queries produce
data, and `step`/`resume` reduce events. A response never contains the
state; `export` is the one exception and exists for tests and tools. -/

namespace SessionDomain
open Data

private def missing : Option Term × Term := (none, error "session" "missing_state")

/-- The stored snapshot envelope `{:comma_internal_session, 3, state}` or a bare state. -/
private def unwrapSnapshot : Term → Option Term
  | .tuple [.atom "comma_internal_session", .integer 3, state] => if state.isMap then some state else none
  | state => if state.isMap && state.has (a "__struct__") then some state else none

/-- Splits the state out of a finished lifecycle result. `{:ok, state}` and a
bare state become resident; `{:error, reason}` leaves the resident state alone
and answers `{:failed, reason}`. -/
private def finishLifecycle (response : Term) : Option Term × Term :=
  match response with
  | .tuple [.atom "done", .tuple [.atom "ok", next]] => (some next, ok (.tuple [a "done"]))
  | .tuple [.atom "done", .tuple [.atom "error", reason]] => (none, ok (.tuple [a "failed", reason]))
  | .tuple [.atom "done", next] => (some next, ok (.tuple [a "done"]))
  | other =>
    let (resident, response) := Session.detach other
    (resident, ok response)

private def runLifecycle (name args state : Term) (observations : List Term) : Option Term × Term :=
  match Session.lookupOp Session.lifecycleTable name with
  | some op => finishLifecycle (Session.runOp (a "lifecycle") name args op state observations)
  | none => (none, error "session" "unknown_operation")

private def runQuery (name args state : Term) (observations : List Term) : Option Term × Term :=
  match Session.lookupOp (Session.queryTable ++ Session.Loop.table ++ Session.Drive.table) name with
  | some op =>
    let (_, response) := Session.detach (Session.runOp (a "query") name args op state observations)
    (some state, ok response)
  | none => (none, error "session" "unknown_query")

def resumeOp (state token observation : Term) : Option Term × Term :=
  match token with
  | .tuple [.atom "op", kind, name, args, .list observations] =>
    if !Schema.admissible observation then
      (none, ok (.tuple [a "raised", .tuple [a "schema", list [b "continuations and observations must contain Session data"]]]))
    else if kind == a "lifecycle" then runLifecycle name args state (observations ++ [observation])
    else runQuery name args state (observations ++ [observation])
  | _ =>
    let (next, response) :=
      Session.detach (Session.resumeTrusted (Session.attach state token) observation)
    (next, ok response)

/-- Decodes a stored snapshot, normalizes it, and admits the result. -/
def loadSnapshot (bytes : ByteArray) (prelude : List Term) : Option Term × Term :=
  match ETF.decode bytes with
  | .error _ => (none, ok (.tuple [a "failed", a "invalid_snapshot"]))
  | .ok snapshot =>
    match unwrapSnapshot snapshot with
    | some state =>
      match runLifecycle (a "normalize") nil state prelude with
      | (some next, response) =>
        if Schema.admissible next true then (some next, response)
        else (none, ok (.tuple [a "failed", a "invalid_snapshot"]))
      | other => other
    | none => (none, ok (.tuple [a "failed", a "invalid_snapshot"]))

namespace ReadRevision

abbrev key := Session.StorageAddress.key

def failed (reason : Term) : Option Term × Term := (none, ok (.tuple [a "error", reason]))

def finish (agent session : ByteArray) (objectKey etag state : Term) : Option Term × Term :=
  if state.get (a "agent_id") != .binary agent then failed (a "session_agent_id_mismatch")
  else if !Session.validId (state.get (a "session_id")) "ses1" then failed (a "invalid_session_id")
  else if state.get (a "session_id") != .binary session then failed (a "session_id_mismatch")
  else if objectKey != key agent session then failed (a "session_key_mismatch")
  else
    let operation := if etag == nil then a "fresh" else a "init"
    let (cursor, _) := Session.Revision.resident (some state) operation etag
    (cursor, ok (.tuple [a "loaded"]))

def accept (agent session : ByteArray) (objectKey etag : Term) : (Option Term × Term) → Option Term × Term
  | (some state, .tuple [.integer 1, .atom "ok", .tuple [.atom "done"]]) => finish agent session objectKey etag state
  | (some state, .tuple [.integer 1, .atom "ok", .tuple [.atom "observe", request, token]]) =>
    (some (.tuple [a "session_read_loading", .binary agent, .binary session, objectKey, etag, state, token]),
      ok (.tuple [a "observe", request]))
  | _ => failed (a "invalid_session_snapshot")

/-- The read continuation retains scope and the returned ETag through load observations. -/
def resident (current : Option Term) (operation args : Term) : Option Term × Term :=
  match operation, current, args with
  | .atom "start", _, .tuple [.binary agent, .binary session] =>
    if Session.validId (.binary session) "ses1" then
      (some (.tuple [a "session_read_pending", .binary agent, .binary session, key agent session]),
        ok (.tuple [a "read", key agent session]))
    else failed (a "invalid_session_id")
  | .atom "read_result", some (.tuple [.atom "session_read_pending", .binary agent, .binary session, objectKey]),
      .tuple [.tuple [.atom "ok", .binary bytes, etag], .list observations] =>
    if Schema.admissible (list observations) then accept agent session objectKey etag (loadSnapshot bytes observations)
    else failed (a "invalid_session_snapshot")
  | .atom "read_result", some (.tuple [.atom "session_read_pending", _, _, _]),
      .tuple [.tuple [.atom "error", reason], _] => failed reason
  | .atom "resume", some (.tuple [.atom "session_read_loading", .binary agent, .binary session, objectKey, etag, state, token]),
      observation => accept agent session objectKey etag (resumeOp state token observation)
  | _, _, _ => failed (a "invalid_observation")

end ReadRevision

def dispatch (resident : Option Term) : Term → Option Term × Term
  | .tuple [.integer 1, .atom "session_read", .integer 1, operation, payload] =>
    ReadRevision.resident resident operation payload
  | .tuple [.integer 1, .atom "session_command_driver", .integer 1, operation, payload] =>
    let (next, response) := Session.CommandDriver.resident resident operation payload
    (next, ok response)
  | .tuple [.integer 1, .atom "session_revision", .integer 1, operation, payload] =>
    let (next, response) := Session.Revision.resident resident operation payload
    (next, ok response)
  | .tuple [.integer 1, .atom "session_fence", .integer 1, operation, payload] =>
    let (next, response) := Session.RevisionFence.resident resident operation payload
    (next, ok response)
  | .tuple [.integer 1, .atom "session_pending", .integer 1, operation, payload] =>
    let (next, response) := Session.PendingRevision.resident resident operation payload
    (next, ok response)
  | .tuple [.integer 1, .atom "session_batch", .integer 1, operation, payload] =>
    let (next, response) := Session.BatchExecution.resident resident operation payload
    (next, ok response)
  | .tuple [.integer 1, .atom "session_commit", .integer 1, operation, payload] =>
    let (next, response) := Session.StorageCommit.resident resident operation payload
    (next, ok response)
  | .tuple [.integer 1, .atom "session_archive", .integer 1, operation, payload] =>
    let (next, response) := Session.ArchivePublication.resident resident operation payload
    (next, ok response)
  | .tuple [.integer 1, .atom "provider", .integer 1, operation, payload] =>
    let (next, response) := Provider.resident resident operation payload
    (next, ok response)
  | .tuple [.integer 1, .atom "session", .integer 1, .atom "open", state] =>
    if state.isMap && Schema.admissible state true then (some state, ok (.atom "opened"))
    else (none, error "session" "invalid_state")
  | .tuple [.integer 1, .atom "session", .integer 1, .atom "new", .tuple [args, .list prelude]] =>
    if Schema.admissible (list prelude) then runLifecycle (a "new") args nil prelude
    else (none, error "session" "invalid_prelude")
  | .tuple [.integer 1, .atom "session", .integer 1, .atom "new", args] =>
    runLifecycle (a "new") args nil []
  | .tuple [.integer 1, .atom "session", .integer 1, .atom "load", .binary bytes] =>
    loadSnapshot bytes []
  | .tuple [.integer 1, .atom "session", .integer 1, .atom "load", .tuple [.binary bytes, .list prelude]] =>
    if Schema.admissible (list prelude) then loadSnapshot bytes prelude
    else (none, error "session" "invalid_prelude")
  | .tuple [.integer 1, .atom "session", .integer 1, .atom "admit", .binary bytes] =>
    -- A stored snapshot exactly as written, without normalization: for repair
    -- tools that must not change what they did not touch.
    match ETF.decode bytes with
    | .error _ => (none, ok (.tuple [a "failed", a "invalid_snapshot"]))
    | .ok snapshot =>
      match unwrapSnapshot snapshot with
      | some state =>
        if Schema.admissible state true then (some state, ok (.tuple [a "done"]))
        else (none, ok (.tuple [a "failed", a "invalid_snapshot"]))
      | none => (none, ok (.tuple [a "failed", a "invalid_snapshot"]))
  | .tuple [.integer 1, .atom "session", .integer 1, .atom "persist", _] =>
    match resident with
    | some state =>
      match Session.Lifecycle.persistable state [] with
      | .ok (persistable, _) =>
        match ETF.encode (.tuple [a "comma_internal_session", i 3, persistable]) with
        | .ok bytes => (resident, ok (.binary bytes))
        | .error code => (none, error "wire" code)
      | .error _ => (none, error "session" "persist_failed")
    | none => missing
  | .tuple [.integer 1, .atom "session", .integer 1, .atom "lifecycle", .tuple [name, args]] =>
    match resident with
    | some state => runLifecycle name args state []
    | none => missing
  | .tuple [.integer 1, .atom "session", .integer 1, .atom "lifecycle", .tuple [name, args, .list prelude]] =>
    match resident with
    | some state =>
      if Schema.admissible (list prelude) then runLifecycle name args state prelude
      else (none, error "session" "invalid_prelude")
    | none => missing
  | .tuple [.integer 1, .atom "session", .integer 1, .atom "query", .tuple [name, args]] =>
    match resident with
    | some state => runQuery name args state []
    | none => missing
  | .tuple [.integer 1, .atom "session", .integer 1, .atom "query", .tuple [name, args, .list prelude]] =>
    match resident with
    | some state =>
      if Schema.admissible (list prelude) then runQuery name args state prelude
      else (none, error "session" "invalid_prelude")
    | none => missing
  | .tuple [.integer 1, .atom "session", .integer 1, .atom "get", field] =>
    match resident with
    | some state => (resident, ok (.tuple [a "value", state.get field]))
    | none => missing
  | .tuple [.integer 1, .atom "session", .integer 1, .atom "step", .tuple [event, .list prelude]] =>
    match resident with
    | some state =>
      let (next, response) := Session.detach (Session.runTrusted state event prelude)
      (next, ok response)
    | none => missing
  | .tuple [.integer 1, .atom "session", .integer 1, .atom "step", event] =>
    match resident with
    | some state =>
      let (next, response) := Session.detach (Session.runTrusted state event [])
      (next, ok response)
    | none => missing
  | .tuple [.integer 1, .atom "session", .integer 1, .atom "resume", .tuple [token, observation]] =>
    match resident with
    | some state => resumeOp state token observation
    | none => missing
  | .tuple [.integer 1, .atom "session", .integer 1, .atom "export", _] =>
    match resident with
    | some state => (resident, ok state)
    | none => missing
  | _ => (none, error "wire" "unsupported_request")

end SessionDomain

@[export salix_verified_kernel_session]
def session (resident : Option Term) (bytes : ByteArray) : Option Term × ByteArray :=
  let (next, response) := match ETF.decode bytes with
    | .ok request => SessionDomain.dispatch resident request
    | .error code => (none, error "wire" code)
  match ETF.encode response with
  | .ok output => (next, output)
  | .error _ => (none, encodeError)

end VerifiedKernel
