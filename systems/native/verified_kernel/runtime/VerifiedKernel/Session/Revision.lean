import VerifiedKernel.Session.PendingRevision
import VerifiedKernel.Session.Command

namespace VerifiedKernel.Session.Revision
open Data
abbrev Output := BatchExecution.Output

inductive Cursor where
  | fresh (state : Term)
  | committed (state etag : Term)
  | pending (cursor : PendingRevision.Cursor)

def Cursor.pack : Cursor → Term
  | .fresh state => .tuple [a "session_fresh_revision", state]
  | .committed state etag => .tuple [a "session_committed_revision", state, etag]
  | .pending cursor => cursor.pack

def unpack : Term → Option Cursor
  | .tuple [.atom "session_fresh_revision", state] => some (.fresh state)
  | .tuple [.atom "session_committed_revision", state, etag] => some (.committed state etag)
  | saved => (PendingRevision.unpack saved).map Cursor.pending

def Cursor.candidate : Cursor → PendingRevision.Cursor
  | .fresh state => ⟨state, state, nil, [], nil⟩
  | .committed state etag => ⟨state, state, etag, [], nil⟩
  | .pending cursor => cursor

def Cursor.isPending : Cursor → Bool
  | .fresh _ => true
  | .committed _ _ => false
  | .pending _ => true

def Cursor.baseline : Cursor → Cursor
  | .fresh state => .fresh state
  | .committed state etag => .committed state etag
  | .pending cursor =>
    if cursor.etag == nil then .fresh cursor.baseline else .committed cursor.baseline cursor.etag

def committedResult : Output → Output
  | (some state, .tuple [.atom "ok", etag]) =>
    (some (Cursor.committed state etag).pack, .tuple [a "committed"])
  | other => other

def invalid : Output := (none, .tuple [a "raised", .tuple [a "invalid_observation", list []]])

def acceptPlanBatch (outcome : Term) : Output → Output
  | (some saved, .tuple [.atom "done"]) => (some saved, .tuple [a "planned", .tuple [outcome, Term.bool true]])
  | (some saved, response) => (some (.tuple [a "session_revision_plan_batch", outcome, saved]), response)
  | (none, response) => (none, response)

def stagePlan (cursor : Cursor) (events : List Term) (hwm outcome : Term) : Output :=
  if events.isEmpty then (some cursor.pack, .tuple [a "planned", .tuple [outcome, Term.bool false]])
  else acceptPlanBatch outcome (PendingRevision.write cursor.candidate events hwm)

def acceptPlan (cursor : Cursor) (mode : Term) : Term → Output
  | .atom "fallback" => (some cursor.pack, .tuple [a "planned", .tuple [a "fallback", Term.bool false]])
  | .atom "idle" => (some cursor.pack, .tuple [a "planned", .tuple [a "idle", Term.bool false]])
  | .tuple [.atom "activate", .list events, hwm] =>
    if mode == a "fast" then stagePlan cursor events hwm (a "run") else invalid
  | .tuple [.list events, hwm, outcome] =>
    if mode == a "fast" then invalid else stagePlan cursor events hwm outcome
  | _ => invalid

def plan (cursor : Cursor) (mode : Term) (observations : List Term) : Output :=
  match Command.revisionPlan cursor.candidate.working mode observations with
  | .ok (result, rest) => if settled rest then acceptPlan cursor mode result else invalid
  | .error (.observe request) =>
    (some (.tuple [a "session_revision_plan", cursor.pack, mode, list observations]), .tuple [a "observe", request])
  | .error (.raised reason) => (none, .tuple [a "raised", reason])

def resident (current : Option Term) (operation args : Term) : Output :=
  match operation, current with
  | .atom "fresh", some state =>
    (some (Cursor.fresh state).pack, .tuple [a "done"])
  | .atom "init", some state =>
    (some (Cursor.committed state args).pack, .tuple [a "done"])
  | .atom "resume", some (.tuple [.atom "session_revision_plan", saved, mode, .list observations]) =>
    match unpack saved with
    | some cursor => plan cursor mode (observations ++ [args])
    | none => invalid
  | _, some (.tuple [.atom "session_revision_plan_batch", outcome, batch]) =>
    if operation == a "run" || operation == a "resume" then
      acceptPlanBatch outcome (PendingRevision.resident (some batch) operation args)
    else invalid
  | _, some (.tuple [.atom "session_pending_batch", _, _]) =>
    PendingRevision.resident current operation args
  | _, some saved =>
    match unpack saved with
    | some cursor =>
      match operation, args with
      | .atom "working", _ =>
        (some cursor.candidate.working, .tuple [a "revision", cursor.candidate.etag, Term.bool cursor.isPending])
      | .atom "is_pending", _ => (some saved, .tuple [a "pending", Term.bool cursor.isPending])
      | .atom "baseline", _ =>
        (some cursor.baseline.pack, .tuple [a "done"])
      | .atom "metadata", _ =>
        (some saved, .tuple [a "metadata", list cursor.candidate.events, cursor.candidate.hwm])
      | .atom "write", .tuple [.list events, hwm] =>
        PendingRevision.resident (some cursor.candidate.pack) (a "write") (.tuple [list events, hwm])
      | .atom "plan", .tuple [mode, .list observations] => plan cursor mode observations
      | _, _ => invalid
    | none => invalid
  | _, none => invalid

end VerifiedKernel.Session.Revision
