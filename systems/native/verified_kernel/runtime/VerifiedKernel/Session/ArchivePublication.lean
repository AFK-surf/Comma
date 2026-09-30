import VerifiedKernel.Session.Query.Storage
import VerifiedKernel.Session.ArchiveMatch
import VerifiedKernel.ETF

namespace VerifiedKernel.Session.ArchivePublication
open Data

inductive Phase where
  | read
  | create (records : List Term) (entry : Term)
  | compare (records : List Term)

/-- The existing captured archive window, kept resident between storage calls. -/
structure Cursor where
  agent : Term
  session : Term
  remaining : List Term
  ceiling : Int
  line : Nat
  catalog : List Term
  entries : List Term := []
  phase : Phase := .read

def Phase.pack : Phase → Term
  | .read => a "read"
  | .create records entry => .tuple [a "create", list records, entry]
  | .compare records => .tuple [a "compare", list records]

def Phase.unpack : Term → Option Phase
  | .atom "read" => some .read
  | .tuple [.atom "create", .list records, entry] => some (.create records entry)
  | .tuple [.atom "compare", .list records] => some (.compare records)
  | _ => none

def Cursor.pack (cursor : Cursor) : Term :=
  .tuple [b "session_archive_cursor", cursor.agent, cursor.session, list cursor.remaining,
    i cursor.ceiling, i cursor.line, list cursor.catalog, list cursor.entries, cursor.phase.pack]

def Cursor.unpack : Term → Option Cursor
  | .tuple [tag, agent, session, .list records, .integer ceiling, .integer line,
      .list catalog, .list entries, phase] => do
    if tag != b "session_archive_cursor" || line ≤ 0 then none else do
      return ⟨agent, session, records, ceiling, line.toNat, catalog, entries, ← Phase.unpack phase⟩
  | _ => none

abbrev Output := Option Cursor × Term

def failed (reason : Term) : Output := (none, .tuple [a "error", reason])

def divergence (cursor : Cursor) : Output :=
  failed (.tuple [a "segment_divergence", ((cursor.remaining.head?).getD nil).get (a "seq")])

def objectRequest (cursor : Cursor) (operation : String) (extra : List Term := []) : Term :=
  .tuple ([a operation, cursor.agent, cursor.session,
    ((cursor.remaining.head?).getD nil).get (a "seq")] ++ extra)

def complete (cursor : Cursor) : Output :=
  match cursor.entries with
  | [] => (none, .tuple [a "ok", a "nothing_to_archive"])
  | last :: _ =>
    let through := (wrap last)[1]?.getD nil
    let event := Term.map [(b "type", b "archive_advance"), (b "session_id", cursor.session),
      (b "archived_through", through), (b "segments", list (cursor.catalog ++ cursor.entries.reverse))]
    (none, .tuple [a "advance", event])

def proceed (cursor : Cursor) : Output :=
  match cursor.remaining with
  | [] => complete cursor
  | first :: _ =>
    if integerValue (first.get (a "seq")) > cursor.ceiling then complete cursor
    else (some { cursor with phase := .read }, objectRequest cursor "read_segment")

def validate : List Term → Option Int → Bool
  | [], previous => previous.isSome
  | record :: rest, previous =>
    match record.get (a "seq") with
    | .integer seq =>
      seq > 0 && (record.get (a "kind")).isBinary && (record.get (a "data")).isMap &&
        (previous.isNone || previous == some (seq - 1)) && validate rest (some seq)
    | _ => false

/-- Include the first record that crosses the size target, and the partial compacted tail. -/
def cutLoop (ceiling : Int) (line : Nat) : List Term → List Term → Nat → Except String (List Term × Nat)
  | [], selected, bytes => pure (selected.reverse, bytes)
  | record :: rest, selected, bytes => do
    if integerValue (record.get (a "seq")) > ceiling then return (selected.reverse, bytes)
    let raw ← ETF.encode record
    let bytes := bytes + raw.size
    let selected := record :: selected
    if bytes ≥ line then return (selected.reverse, bytes)
    cutLoop ceiling line rest selected bytes

def cut (ceiling : Int) (line : Nat) (records : List Term) (bytes : Nat) :
    Except String (List Term × Nat) := cutLoop ceiling line records [] bytes

def entry (records : List Term) (bytes : Nat) : Term :=
  list [((records.head?).getD nil).get (a "seq"),
    ((records.getLast?).getD nil).get (a "seq"),
    i (records.filter (fun record => record.get (a "kind") == b "message")).length, i bytes]

def measuredEntry (records : List Term) : Except String Term := do
  let bytes ← records.foldlM (fun count record => do
    let raw ← ETF.encode record
    return count + raw.size) 0
  return entry records bytes

def advance (cursor : Cursor) (records : List Term) (catalogEntry : Term) : Output :=
  proceed { cursor with
    remaining := cursor.remaining.drop records.length
    entries := catalogEntry :: cursor.entries
    phase := .read }

def propose (cursor : Cursor) : Output :=
  match cut cursor.ceiling cursor.line cursor.remaining 0 with
  | .error reason => failed (.tuple [a "segment_encode_failed", b reason])
  | .ok ([], _) => complete cursor
  | .ok (records, bytes) =>
    match ETF.encode (list records) with
    | .error reason => failed (.tuple [a "segment_encode_failed", b reason])
    | .ok body =>
      (some { cursor with phase := .create records (entry records bytes) },
        objectRequest cursor "create_segment" [.binary body])

def compare (cursor : Cursor) (records : List Term) : Output :=
  if !validate records none then divergence cursor
  else
    let expected := cursor.remaining.take records.length
    (some { cursor with phase := .compare records }, ArchiveMatch.request records expected)

def resume (cursor : Cursor) (result : Term) : Output :=
  match cursor.phase with
  | .read =>
    match result with
    | .tuple [.atom "ok", .list records] => compare cursor records
    | .tuple [.atom "ok", _] => divergence cursor
    | .tuple [.atom "error", .atom "not_found"] => propose cursor
    | .atom "invalid_segment" => divergence cursor
    | .tuple [.atom "error", reason] => failed (.tuple [a "segment_read_failed", reason])
    | _ => failed (a "invalid_observation")
  | .create records catalogEntry =>
    match result with
    | .atom "created" | .atom "landed" => advance cursor records catalogEntry
    | .tuple [.atom "exists", .list landed] => compare cursor landed
    | .tuple [.atom "exists", _] => divergence cursor
    | .atom "invalid_segment" => divergence cursor
    | .tuple [.atom "error", reason] => failed (.tuple [a "segment_write_failed", reason])
    | _ => failed (a "invalid_observation")
  | .compare records =>
    let expected := cursor.remaining.take records.length
    match ArchiveMatch.check nil (.tuple [list records, list expected]) [.tuple [a "ok", result]] with
    | .ok (.atom "ok", []) =>
      match measuredEntry records with
      | .ok catalogEntry => advance cursor records catalogEntry
      | .error reason => failed (.tuple [a "segment_encode_failed", b reason])
    | .ok (.tuple [.atom "error", .atom "segment_divergence"], []) => divergence cursor
    | .ok (.tuple [.atom "error", reason], []) => failed reason
    | _ => failed (a "invalid_observation")

def start (state args : Term) : Output :=
  match args with
  | .integer line =>
    if line ≤ 0 then failed (a "invalid_term") else
    match StorageQuery.archiveWindow state [] with
    | .ok (.tuple [.atom "ok", .list records, .integer ceiling], []) =>
      proceed ⟨state.get (a "agent_id"), state.get (a "session_id"), records, ceiling, line.toNat,
        wrap ((state.get (a "segment_catalog")).default (list [])), [], .read⟩
    | .ok (.tuple [.atom "error", reason], []) => failed reason
    | .error (.raised reason) => failed reason
    | _ => failed (a "invalid_term")
  | _ => failed (a "invalid_term")

def packOutput (output : Output) : Option Term × Term :=
  (output.1.map Cursor.pack, output.2)

def resident (current : Option Term) (operation args : Term) : Option Term × Term :=
  match operation, current with
  | .atom "start", some state => packOutput (start state args)
  | .atom "resume", some value =>
    match Cursor.unpack value with
    | some cursor => packOutput (resume cursor args)
    | none => packOutput (failed (a "invalid_term"))
  | _, _ => packOutput (failed (a "invalid_term"))

end VerifiedKernel.Session.ArchivePublication
