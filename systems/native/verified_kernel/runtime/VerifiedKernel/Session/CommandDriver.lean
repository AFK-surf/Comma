import VerifiedKernel.Session.RevisionFence
import VerifiedKernel.Session.Command

namespace VerifiedKernel.Session.CommandDriver
open Data
abbrev Output := RevisionFence.Output

abbrev Context := Revision.Cursor
abbrev unpack := Revision.unpack

def invalid : Output := RevisionFence.invalid

def rejected (context : Context) (continuation reason candidate : Term) : Output :=
  let baseline := context.baseline
  (some (.tuple [a "session_command_driver_rejected", baseline.pack, continuation, reason, candidate]),
    .tuple [a "rejected", reason])

def preparedWrite (context : Context) (continuation : Term) (events : List Term) (hwm : Term) : Output :=
  (some (.tuple [a "session_command_driver_write", context.pack, continuation, list events, hwm]),
    .tuple [a "validate_write", list events])

def needsTimestamp (event : Term) : Bool :=
  [b "session_created", b "status", b "activity_status", b "wait_set", b "wait_clear"].contains
    (event.get (b "type")) && !(event.get (b "created_at")).isInteger

def issueWrite (context : Context) (continuation : Term) (events : List Term) (hwm : Term) : Output :=
  if events.any needsTimestamp then
    (some (.tuple [a "session_command_driver_write_time", context.pack, continuation, list events, hwm]),
      .tuple [a "observe", a "time"])
  else preparedWrite context continuation events hwm

def effectResultValid (request result : Term) : Bool :=
  match request, result with
  | .tuple [.atom "random", _], .binary _ => true
  | .tuple [.atom "authorize", _], .atom "none" => true
  | .tuple [.atom "authorize", _], .atom "ok"
  | .tuple [.atom "authorize", _], .tuple [.atom "error", _]
  | .tuple [.atom "workspace", _, _, _, _], .atom "ok"
  | .tuple [.atom "workspace", _, _, _, _], .tuple [.atom "error", _]
  | .tuple [.atom "notify", _, _], .atom "ok"
  | .tuple [.atom "notify", _, _], .tuple [.atom "error", _]
  | .tuple [.atom "draft_clear", _], .atom "ok"
  | .tuple [.atom "draft_clear", _], .tuple [.atom "error", _] => true
  | _, _ => false

def issue (context : Context) : Term → Output
  | .tuple [.atom "return", result, checkpoint] =>
    (some context.pack, .tuple [a "return", result, checkpoint])
  | .tuple [.atom "perform", .tuple [.atom "write", .list events, .list []], continuation] =>
    issueWrite context continuation events nil
  | .tuple [.atom "perform", .tuple [.atom "write", .list events,
      .list [.tuple [.atom "hwm", hwm]]], continuation] =>
    issueWrite context continuation events hwm
  | .tuple [.atom "perform", .tuple [.atom "write", .list events,
      .list [.tuple [.atom "hwm", hwm], .tuple [.atom "on_conflict", .atom "error"]]], continuation] =>
    issueWrite context continuation events hwm
  | .tuple [.atom "perform", .atom "durable_fence", continuation] =>
    (some (.tuple [a "session_command_driver_fence", context.pack, continuation]), .tuple [a "fence"])
  | .tuple [.atom "perform", request@(.tuple [.atom "workspace", _, _, _, _]), continuation]
  | .tuple [.atom "perform", request@(.tuple [.atom "notify", _, _]), continuation]
  | .tuple [.atom "perform", request@(.tuple [.atom "authorize", _]), continuation]
  | .tuple [.atom "perform", request@(.tuple [.atom "random", _]), continuation]
  | .tuple [.atom "perform", request@(.tuple [.atom "draft_clear", _]), continuation] =>
    (some (.tuple [a "session_command_driver_effect", context.pack, continuation, request]), .tuple [a "effect", request])
  | _ => invalid

def query (context : Context) (operation args : Term) (observations : List Term) : Output :=
  let call := match operation with
    | .atom "start" => Command.start context.candidate.working args observations
    | .atom "resume" => Command.resume context.candidate.working args observations
    | _ => .error (.raised (.tuple [a "invalid_observation", list []]))
  match call with
  | .ok (result, rest) => if settled rest then issue context result else invalid
  | .error (.observe request) =>
    (some (.tuple [a "session_command_driver_query", context.pack, operation, args, list observations]),
      .tuple [a "observe", request])
  | .error (.raised reason) => (none, .tuple [a "raised", reason])

def acceptWrite (context : Context) (continuation : Term) : Output → Output
  | (some saved, .tuple [.atom "done"]) =>
    match PendingRevision.unpack saved with
    | some pending => query (.pending pending)
      (a "resume") (.tuple [continuation, a "ok"]) []
    | none => invalid
  | (some batch, response) =>
    (some (.tuple [a "session_command_driver_batch", context.pack, continuation, batch]), response)
  | (none, response) => (none, response)

def acceptFence (context : Context) (continuation : Term) : Output → Output
  | (none, .tuple [.atom "error", reason]) => rejected context continuation reason context.candidate.working
  | (some fence, response) =>
    (some (.tuple [a "session_command_driver_fencing", context.pack, continuation, fence]), response)
  | (none, response) => (none, response)

def acceptCAS (context : Context) (continuation : Term) : Output → Output
  | (some saved, .tuple [.atom "committed"]) =>
    match unpack saved with
    | some (.committed state etag) =>
      (some (.tuple [a "session_command_driver_confirmed", (Revision.Cursor.committed state etag).pack, continuation]),
        .tuple [a "committed"])
    | _ => invalid
  | (some candidate, .tuple [.atom "error", reason]) => rejected context continuation reason candidate
  | (none, response) => (none, response)
  | _ => invalid

def contextOf (current : Term) : Option Context :=
  match unpack current with
  | some context => some context
  | none =>
    match current with
    | .tuple [.atom "session_command_driver_write", saved, _, _, _]
    | .tuple [.atom "session_command_driver_write_time", saved, _, _, _]
    | .tuple [.atom "session_command_driver_fence", saved, _]
    | .tuple [.atom "session_command_driver_effect", saved, _, _]
    | .tuple [.atom "session_command_driver_batch", saved, _, _]
    | .tuple [.atom "session_command_driver_fencing", saved, _, _]
    | .tuple [.atom "session_command_driver_confirmed", saved, _]
    | .tuple [.atom "session_command_driver_rejected", saved, _, _, _]
    | .tuple [.atom "session_command_driver_query", saved, _, _, _] => unpack saved
    | _ => none

def resident (current : Option Term) (operation args : Term) : Output :=
  match operation, current, args with
  | .atom "start", some saved, .tuple [inputArgs, .list observations] =>
    match unpack saved with
    | some context => query context (a "start") inputArgs observations
    | none => invalid
  | .atom "view", some value, _ =>
    match contextOf value with
    | some context => (some context.candidate.working,
      .tuple [a "view", context.candidate.etag, Term.bool context.isPending])
    | none => invalid
  | .atom "revision", some value, _ =>
    match contextOf value with
    | some context => (some context.pack, .tuple [a "done"])
    | none => invalid
  | .atom "resume", some (.tuple [.atom "session_command_driver_query", saved, mode, queryArgs, .list observations]), observation =>
    match unpack saved with
    | some context => query context mode queryArgs (observations ++ [observation])
    | none => invalid
  | .atom "resume", some (.tuple [.atom "session_command_driver_write_time", saved, continuation, .list events, hwm]),
      .tuple [.atom "ok", .integer milliseconds] =>
    match unpack saved with
    | some context => preparedWrite context continuation
      (events.map (fun event => Command.timestampLifecycle event (milliseconds / 1000))) hwm
    | none => invalid
  | .atom "write_result", some (.tuple [.atom "session_command_driver_write", saved, continuation, .list events, hwm]), result =>
    match unpack saved, result with
    | some context, .atom "ok" => acceptWrite context continuation
      (Revision.resident (some context.pack) (a "write") (.tuple [list events, hwm]))
    | some context, .tuple [.atom "error", _] => query context (a "resume") (.tuple [continuation, result]) []
    | _, _ => invalid
  | .atom "effect_result", some (.tuple [.atom "session_command_driver_effect", saved, continuation, request]), result =>
    match unpack saved with
    | some context =>
      if effectResultValid request result then query context (a "resume") (.tuple [continuation, result]) [] else invalid
    | none => invalid
  | _, some (.tuple [.atom "session_command_driver_batch", saved, continuation, batch]), _ =>
    if operation == a "run" || operation == a "resume" then
      match unpack saved with
      | some context => acceptWrite context continuation (PendingRevision.resident (some batch) operation args)
      | none => invalid
    else invalid
  | .atom "fence_start", some (.tuple [.atom "session_command_driver_fence", saved, continuation]), .tuple [key, .list observations] =>
    match unpack saved with
    | some context => acceptFence context continuation
      (RevisionFence.resident (some context.candidate.pack) (a "start") (.tuple [key, list observations]))
    | none => invalid
  | .atom "fence_clean", some (.tuple [.atom "session_command_driver_fence", saved, continuation]), _ =>
    match unpack saved with
    | some context =>
      if context.isPending then invalid else
        (some (.tuple [a "session_command_driver_confirmed", context.pack, continuation]), .tuple [a "committed"])
    | none => invalid
  | .atom "fence_reject", some (.tuple [.atom "session_command_driver_fence", saved, continuation]), .tuple [.atom "error", reason] =>
    match unpack saved with
    | some context => rejected context continuation reason context.candidate.working
    | none => invalid
  | .atom "fence_view", some (.tuple [.atom "session_command_driver_fencing", _, _, fence]), _ =>
    RevisionFence.resident (some fence) (a "view") nil
  | .atom "cas_result", some (.tuple [.atom "session_command_driver_fencing", saved, continuation, fence]), result =>
    match unpack saved with
    | some context => acceptCAS context continuation (RevisionFence.resident (some fence) (a "cas_revision") result)
    | none => invalid
  | _, some (.tuple [.atom "session_command_driver_fencing", saved, continuation, fence]), _ =>
    if [a "resume", a "run", a "stamp", a "encode"].contains operation then
      match unpack saved with
      | some context => acceptFence context continuation (RevisionFence.resident (some fence) operation args)
      | none => invalid
    else invalid
  | .atom "next", some (.tuple [.atom "session_command_driver_confirmed", saved, continuation]), _ =>
    match unpack saved with
    | some context => query context (a "resume") (.tuple [continuation, a "ok"]) []
    | none => invalid
  | .atom "next", some (.tuple [.atom "session_command_driver_rejected", saved, continuation, reason, _]), _ =>
    match unpack saved with
    | some context => query context (a "resume") (.tuple [continuation, .tuple [a "error", reason]]) []
    | none => invalid
  | .atom "candidate", some (.tuple [.atom "session_command_driver_rejected", _, _, _, candidate]), _ =>
    (some candidate, .tuple [a "done"])
  | _, _, _ => invalid

end VerifiedKernel.Session.CommandDriver
