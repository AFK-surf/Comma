import VerifiedKernel.Session.BatchExecution
import VerifiedKernel.Session.StorageDelta

namespace VerifiedKernel.Session.PendingRevision
open Data

structure Cursor where
  baseline : Term
  working : Term
  revision : Term
  events : List Term
  hwm : Term
  dedupeAdded : List Term := []

def Cursor.pack (cursor : Cursor) : Term :=
  .tuple [a "session_pending_revision", cursor.baseline, cursor.working, cursor.revision, list cursor.events, cursor.hwm,
    list cursor.dedupeAdded]

def unpack : Term → Option Cursor
  | .tuple [.atom "session_pending_revision", baseline, working, etag, .list events, hwm, .list dedupeAdded] =>
    some ⟨baseline, working, etag, events, hwm, dedupeAdded⟩
  | _ => none

def hwmEvents (hwm : Term) : List Term :=
  if hwm.isInteger && integerValue hwm ≥ 0 then [.map [(b "type", b "bump_hwm"), (b "hwm", hwm)]] else []

def mergeHwm (left right : Term) : KernelM Term :=
  if left == nil then pure right else if right == nil then pure left else maximum left right

def accept (cursor : Cursor) : BatchExecution.Output → BatchExecution.Output
  | (some working, .tuple [.atom "done"]) =>
    (some { cursor with working := working }.pack, .tuple [a "done"])
  | (some batch, response) =>
    (some (.tuple [a "session_delta_batch", cursor.pack, batch]), response)
  | (none, response) => (none, response)

def captureDelta (cursor : Cursor) (before after event : Term) : BatchExecution.Output → BatchExecution.Output :=
  match StorageDelta.captureDedupe before after event [] with
  | .ok (added, []) => accept { cursor with dedupeAdded := cursor.dedupeAdded ++ added }
  | .error (.raised reason) => fun _ => (none, .tuple [a "raised", reason])
  | _ => fun _ => (none, .tuple [a "raised", .tuple [a "invalid_observation", list []]])

def acceptCaptured (cursor : Cursor) (before event : Term) : BatchExecution.Output → BatchExecution.Output
  | result@(some after, .tuple [.atom "done"]) => captureDelta cursor before after event result
  | result@(some (.tuple [.atom "session_batch_next", after, _]), .tuple [.atom "next"]) =>
    captureDelta cursor before after event result
  | (some batch, response@(.tuple [.atom "observe", _])) =>
    (some (.tuple [a "session_delta_observe", cursor.pack, before, event, batch]), response)
  | result => accept cursor result

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
    (some (Cursor.mk state state args [] nil []).pack, .tuple [a "done"])
  | .atom "run", some (.tuple [.atom "session_delta_batch", saved,
      batch@(.tuple [.atom "session_batch_next", before, .list (event :: _)])]) =>
    match unpack saved with
    | some cursor => acceptCaptured cursor before event (BatchExecution.resident (some batch) operation args)
    | none => (none, .tuple [a "raised", .tuple [a "invalid_observation", list []]])
  | .atom "resume", some (.tuple [.atom "session_delta_observe", saved, before, event, batch]) =>
      match unpack saved with
      | some cursor => acceptCaptured cursor before event (BatchExecution.resident (some batch) operation args)
      | none => (none, .tuple [a "raised", .tuple [a "invalid_observation", list []]])
  | _, some saved =>
    match unpack saved with
    | some cursor =>
      match operation, args with
      | .atom "write", .tuple [.list events, hwm] => write cursor events hwm
      | .atom "working", _ => (some cursor.working, .tuple [a "done"])
      | .atom "baseline", _ => (some cursor.baseline, .tuple [a "baseline", cursor.revision])
      | .atom "metadata", _ => (some saved, .tuple [a "metadata", list cursor.events, cursor.hwm])
      | _, _ => (none, .tuple [a "raised", .tuple [a "invalid_observation", list []]])
    | none => (none, .tuple [a "raised", .tuple [a "invalid_observation", list []]])
  | _, none => (none, .tuple [a "raised", .tuple [a "invalid_observation", list []]])

end VerifiedKernel.Session.PendingRevision
