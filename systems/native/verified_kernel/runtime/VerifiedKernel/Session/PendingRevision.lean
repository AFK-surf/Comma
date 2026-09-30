import VerifiedKernel.Session.BatchExecution

namespace VerifiedKernel.Session.PendingRevision
open Data

structure Cursor where
  baseline : Term
  working : Term
  etag : Term
  events : List Term
  hwm : Term

def Cursor.pack (cursor : Cursor) : Term :=
  .tuple [a "session_pending_revision", cursor.baseline, cursor.working, cursor.etag, list cursor.events, cursor.hwm]

def unpack : Term → Option Cursor
  | .tuple [.atom "session_pending_revision", baseline, working, etag, .list events, hwm] =>
    some ⟨baseline, working, etag, events, hwm⟩
  | _ => none

def hwmEvents (hwm : Term) : List Term :=
  if hwm.isInteger && integerValue hwm ≥ 0 then [.map [(b "type", b "bump_hwm"), (b "hwm", hwm)]] else []

def mergeHwm (left right : Term) : KernelM Term :=
  if left == nil then pure right else if right == nil then pure left else maximum left right

def accept (cursor : Cursor) : BatchExecution.Output → BatchExecution.Output
  | (some working, .tuple [.atom "done"]) =>
    (some { cursor with working := working }.pack, .tuple [a "done"])
  | (some batch, response) =>
    (some (.tuple [a "session_pending_batch", cursor.pack, batch]), response)
  | (none, response) => (none, response)

/-- A staged write retains its original baseline and captures both the input batch and optional HWM event. -/
def write (cursor : Cursor) (events : List Term) (hwm : Term) : BatchExecution.Output :=
  match mergeHwm cursor.hwm hwm [] with
  | .ok (merged, []) =>
    accept { cursor with events := cursor.events ++ events, hwm := merged }
      (BatchExecution.next cursor.working (events ++ hwmEvents hwm))
  | .error (.raised reason) => (none, .tuple [a "raised", reason])
  | _ => (none, .tuple [a "raised", .tuple [a "invalid_observation", list []]])

def resident (current : Option Term) (operation args : Term) : BatchExecution.Output :=
  match operation, current with
  | .atom "init", some state =>
    (some (Cursor.mk state state args [] nil).pack, .tuple [a "done"])
  | _, some (.tuple [.atom "session_pending_batch", saved, batch]) =>
    if operation == a "run" || operation == a "resume" then
      match unpack saved with
      | some cursor => accept cursor (BatchExecution.resident (some batch) operation args)
      | none => (none, .tuple [a "raised", .tuple [a "invalid_observation", list []]])
    else (none, .tuple [a "raised", .tuple [a "invalid_observation", list []]])
  | _, some saved =>
    match unpack saved with
    | some cursor =>
      match operation, args with
      | .atom "write", .tuple [.list events, hwm] => write cursor events hwm
      | .atom "working", _ => (some cursor.working, .tuple [a "done"])
      | .atom "baseline", _ => (some cursor.baseline, .tuple [a "baseline", cursor.etag])
      | .atom "metadata", _ => (some saved, .tuple [a "metadata", list cursor.events, cursor.hwm])
      | _, _ => (none, .tuple [a "raised", .tuple [a "invalid_observation", list []]])
    | none => (none, .tuple [a "raised", .tuple [a "invalid_observation", list []]])
  | _, none => (none, .tuple [a "raised", .tuple [a "invalid_observation", list []]])

end VerifiedKernel.Session.PendingRevision
