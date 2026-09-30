import VerifiedKernel.Session.PendingRevision
import VerifiedKernel.Session.StorageCommit
import VerifiedKernel.Session.Revision

namespace VerifiedKernel.Session.RevisionFence
open Data
abbrev Output := BatchExecution.Output

def invalid : Output := (none, .tuple [a "raised", .tuple [a "invalid_observation", list []]])

def prepared (cursor : PendingRevision.Cursor) (key state : Term) : Term :=
  .tuple [a "session_fence_prepared", cursor.pack, key, state]

def prepare (cursor : PendingRevision.Cursor) (key : Term) (observations : List Term) : Output :=
  if !StorageAddress.agrees cursor.working key then (none, .tuple [a "error", a "session_key_mismatch"])
  else
    match Lifecycle.prepareWrite cursor.working observations with
    | .ok (.tuple [.atom "ok", state], rest) =>
      if settled rest then (some (prepared cursor key state), .tuple [a "prepared"]) else invalid
    | .ok (.tuple [.atom "error", reason], _) => (none, .tuple [a "error", reason])
    | .error (.observe request) =>
      (some (.tuple [a "session_fence_preparing", cursor.pack, key, list observations]), .tuple [a "observe", request])
    | .error (.raised reason) => (none, .tuple [a "raised", reason])
    | _ => invalid

/-- These are the existing commit metadata writes, not caller-selected reducer events. -/
def metadataEvents (token reasons activity revision flush epoch node : Term) : List Term :=
  [.map [(b "type", b "session_stamp"), (b "work_index_token", token), (b "work_index_reasons", reasons)],
   .map [(b "type", b "session_stamp"), (b "activity_revision", activity)],
   .map [(b "type", b "session_stamp"), (b "storage_revision", revision), (b "flush_id", flush)]] ++
    if epoch.isInteger then [.map [(b "type", b "session_stamp"), (b "runtime_epoch", epoch), (b "runtime_node", node)]] else []

def acceptMetadata (cursor : PendingRevision.Cursor) (key : Term) : Output → Output
  | (some state, .tuple [.atom "done"]) =>
    (some (.tuple [a "session_fence_stamped", cursor.pack, key, state]), .tuple [a "stamped"])
  | (some batch, response) =>
    (some (.tuple [a "session_fence_batch", cursor.pack, key, batch]), response)
  | (none, response) => (none, response)

def encode (cursor : PendingRevision.Cursor) (key state : Term) : Output :=
  match StorageCommit.resident (some state) (a "start") (.tuple [key, cursor.etag]) with
  | (some commit, request) => (some (.tuple [a "session_fence_cas", commit]), request)
  | (none, response) => (none, response)

def resident (current : Option Term) (operation args : Term) : Output :=
  match operation, current, args with
  | .atom "start", some saved, .tuple [key, .list observations] =>
    match Revision.unpack saved with
    | some cursor => prepare cursor.candidate key observations
    | none => invalid
  | .atom "resume", some (.tuple [.atom "session_fence_preparing", saved, key, .list observations]), observation =>
    match PendingRevision.unpack saved with
    | some cursor => prepare cursor key (observations ++ [observation])
    | none => invalid
  | .atom "view", some (.tuple [.atom "session_fence_prepared", _, _, state]), _ =>
    (some state, .tuple [a "done"])
  | .atom "stamp", some (.tuple [.atom "session_fence_prepared", saved, key, state]),
      .tuple [token, reasons, activity, revision, flush, epoch, node] =>
    match PendingRevision.unpack saved with
    | some cursor => acceptMetadata cursor key (BatchExecution.next state (metadataEvents token reasons activity revision flush epoch node))
    | none => invalid
  | _, some (.tuple [.atom "session_fence_batch", saved, key, batch]), _ =>
    if operation == a "run" || operation == a "resume" then
      match PendingRevision.unpack saved with
      | some cursor => acceptMetadata cursor key (BatchExecution.resident (some batch) operation args)
      | none => invalid
    else invalid
  | .atom "encode", some (.tuple [.atom "session_fence_stamped", saved, key, state]), _ =>
    match PendingRevision.unpack saved with
    | some cursor => encode cursor key state
    | none => invalid
  | .atom "cas_result", some (.tuple [.atom "session_fence_cas", commit]), result =>
    StorageCommit.resident (some commit) (a "resume") result
  | .atom "cas_revision", some (.tuple [.atom "session_fence_cas", commit]), result =>
    Revision.committedResult (StorageCommit.resident (some commit) (a "resume") result)
  | _, _, _ => invalid

end VerifiedKernel.Session.RevisionFence
