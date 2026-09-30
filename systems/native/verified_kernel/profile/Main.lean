import VerifiedKernel

open VerifiedKernel VerifiedKernel.Data VerifiedKernel.Session

def timeIt (label : String) (n : Nat) (f : Unit → IO α) : IO α := do
  let _ ← f ()
  let start ← IO.monoNanosNow
  let mut result := none
  for _ in [:n] do
    result := some (← f ())
  let stop ← IO.monoNanosNow
  IO.println s!"{label}: {(stop - start) / n / 1000} us"
  match result with
  | some r => pure r
  | none => f ()

/-- Runs a kernel computation, answering configuration requests with their
default and clock requests with zero, as the host would. -/
partial def describe : Term → Nat → String
  | .atom s, _ => ":" ++ s
  | .binary raw, _ => "\"" ++ ((String.fromUTF8? raw).getD "<bytes>").take 60 ++ "\""
  | .integer n, _ => toString n
  | .list xs, 0 => s!"[..{xs.length}]"
  | .list xs, d + 1 => "[" ++ ", ".intercalate (xs.take 6 |>.map (describe · d)) ++ "]"
  | .tuple xs, 0 => "{.." ++ toString xs.length ++ "}"
  | .tuple xs, d + 1 => "{" ++ ", ".intercalate (xs.take 8 |>.map (describe · d)) ++ "}"
  | .map es, 0 => "%{.." ++ toString es.length ++ "}"
  | .map es, d + 1 => "%{" ++ ", ".intercalate (es.take 8 |>.map (fun (k, v) => describe k d ++ " => " ++ describe v d)) ++ "}"
  | _, _ => "?"

partial def kmWith (f : KernelM Term) (obs : List Term) : IO Term :=
  match f obs with
  | .ok (v, _) => pure v
  | .error (.raised r) => throw (IO.userError s!"raised {describe r 3}")
  | .error (.observe request) =>
    match request with
    | .tuple [.atom "config", _, _, fallback] => kmWith f (obs ++ [.tuple [.atom "ok", fallback]])
    | .atom "time" => kmWith f (obs ++ [.tuple [.atom "ok", .integer 0]])
    | _ => throw (IO.userError "unknown observation")

/-- The host's prelude: the clock and the configuration keys answered ahead,
so a computation runs once instead of replaying per observation. -/
def prelude : List Term :=
  [.tuple [.atom "ok_for", .atom "time", .integer 0],
   .tuple [.atom "ok_for", .tuple [.atom "config", .atom "salix_agent", .atom "llm_failure_activation_cap"], .integer 3],
   .tuple [.atom "ok_for", .tuple [.atom "config", .atom "salix_agent", .atom "runaway_unsettled_round_cap"], .integer 2],
   .tuple [.atom "ok_for", .tuple [.atom "config", .atom "salix_agent", .atom "repeated_tool_result_cap"], .integer 5],
   .tuple [.atom "ok_for", .tuple [.atom "config", .atom "salix_agent", .atom "compaction_threshold"], .atom "nil"]]

def km (f : KernelM Term) : IO Term := kmWith f prelude

def main (args : List String) : IO Unit := do
  let path := args.headD "state.etf"
  let bytes ← IO.FS.readBinFile path
  IO.println s!"bytes {bytes.size}"
  let term ← timeIt "decode" 3 (fun _ => match ETF.decode bytes with
    | .ok t => pure t | .error e => throw (IO.userError e))
  let state := match term with
    | .tuple [_, _, s] => s
    | s => s
  let _ ← timeIt "depth" 3 (fun _ => pure state.depth)
  let _ ← timeIt "admissible (state envelope)" 3 (fun _ => pure (Schema.admissible state true))
  let _ ← timeIt "encode" 3 (fun _ => match ETF.encode state with
    | .ok b => pure b.size | .error e => throw (IO.userError e))
  let _ ← timeIt "put one field" 20 (fun _ => pure (state.put (a "storage_revision") (b "x")).depth)
  let stamp := Term.map [(b "type", b "session_stamp"), (b "storage_revision", b "rev-1")]
  let _ ← timeIt "sessionStamp" 5 (fun _ => km (sessionStamp state stamp))
  let _ ← timeIt "run session_stamp (full run)" 5 (fun _ => pure (Session.run state stamp []).depth)
  let _ ← timeIt "fillDefaults" 5 (fun _ => pure (Lifecycle.fillDefaults state).depth)
  let _ ← timeIt "normalize" 3 (fun _ => km (Lifecycle.normalize state))
  let _ ← timeIt "migrationStates" 3 (fun _ => km (Lifecycle.migrationStates state))
  let _ ← timeIt "runawayStreak" 3 (fun _ => km (Lifecycle.runawayStreak state))
  let _ ← timeIt "normalizeLastSeq" 3 (fun _ => km (Lifecycle.normalizeLastSeq state))
  let _ ← timeIt "boundaryProviderStates" 3 (fun _ => km (Lifecycle.boundaryProviderStates state))
  let _ ← timeIt "preserveDedupe" 3 (fun _ => km (Lifecycle.preserveDedupe state))
  let _ ← timeIt "normalizeDedupe" 3 (fun _ => km (Lifecycle.normalizeDedupe (state.get (a "input_dedupe"))))
  let _ ← timeIt "persistable" 3 (fun _ => km (Lifecycle.persistable state))
  let _ ← timeIt "prepareWrite" 3 (fun _ => km (Lifecycle.prepareWrite state))
  let _ ← timeIt "activationKey" 3 (fun _ => km (return list (← activationKey state)))
  let _ ← timeIt "activity" 3 (fun _ => km (activity state))
  let _ ← timeIt "pruneQueue" 3 (fun _ => km (return list (← Lifecycle.pruneQueue (state.get (a "input_queue")) (state.get (a "queue_ack_id")))))
  let _ ← timeIt "fillDefaults+write(40 fields)" 3 (fun _ => km (write (Lifecycle.fillDefaults state) (Lifecycle.defaults.map (fun p => (p.1, state.get (a p.1))))))
  let messages := wrap (state.get (a "messages"))
  let contents := messages.map (fun m => m.get (a "content"))
  let _ ← timeIt "trim all contents" 3 (fun _ => pure (contents.foldl (fun acc c => match c with | .binary raw => acc + (trim raw).size | _ => acc) 0))
  let _ ← timeIt "validateUTF8 all contents" 3 (fun _ => pure (contents.foldl (fun acc c => match c with | .binary raw => acc + (if raw.validateUTF8 then 1 else 0) | _ => acc) 0))
  let _ ← timeIt "walk messages (get id/role)" 3 (fun _ => pure (messages.foldl (fun acc m => acc + (if m.get (a "role") == b "user" then integerValue (m.get (a "id")) else 0)) 0))
  let _ ← timeIt "activationUserMessages" 3 (fun _ => km (return list (← ProvenanceQuery.activationUserMessages state messages)))
  let _ ← timeIt "freshQuestion" 3 (fun _ => km (ProvenanceQuery.freshQuestion state))
  let _ ← timeIt "protectedRefs" 3 (fun _ => km (return list (← protectedRefs state)))
  let _ ← timeIt "pruneResultRefs" 3 (fun _ => km (pruneResultRefs state))
  let _ ← timeIt "write messages field" 3 (fun _ => km (write state [("messages", state.get (a "messages"))]))
  let _ ← timeIt "normalize: write block only" 3 (fun _ => km (do
    let queue ← Lifecycle.pruneQueue (← field state "input_queue") ((← field state "queue_ack_id").default (i 0))
    write state
      [("status", ← Lifecycle.parseStatus (← field state "status")),
       ("input_queue", list queue),
       ("input_dedupe", ← Lifecycle.normalizeDedupe (← field state "input_dedupe")),
       ("visible_reply_activation_scope", ← Lifecycle.activationScope (← field state "visible_reply_activation_scope")),
       ("provider_reply_obligations", ← Lifecycle.obligationTable (← field state "provider_reply_obligations")),
       ("work_index_reasons", ← Lifecycle.workReasons (← field state "work_index_reasons")),
       ("archive_chunks", ← Lifecycle.archiveChunks ((← field state "archive_chunks").default (list []))),
       ("segment_catalog", ← Lifecycle.segmentCatalog ((← field state "segment_catalog").default (list [])))]))
  let _ ← timeIt "normalize part A (defaults..runaway)" 3 (fun _ => km (do
    let state := Lifecycle.fillDefaults state
    let _ ← Lifecycle.migrationStates state
    let ack := (← field state "queue_ack_id").default (i 0)
    let _ ← Lifecycle.pruneQueue (← field state "input_queue") ack
    let _ ← activationKey state
    Lifecycle.runawayStreak state))
  let _ ← timeIt "normalize part C (activity..preserve)" 3 (fun _ => km (do
    let normalized ← write state [("activity_status", ← activity state)]
    let boundaries ← Lifecycle.boundaryProviderStates normalized
    let normalized ← write normalized [("context_provider_states", boundaries)]
    write normalized [("input_dedupe", ← Lifecycle.preserveDedupe normalized)]))
  let _ ← timeIt "normalizeLastSeq x1" 3 (fun _ => km (Lifecycle.normalizeLastSeq state))
  let bare := state.put (a "messages") (list [])
  let _ ← timeIt "normalize (messages removed)" 3 (fun _ => km (Lifecycle.normalize bare))
  let _ ← timeIt "normalize (decoded, again)" 3 (fun _ => km (Lifecycle.normalize state))
  let normalized ← km (Lifecycle.normalize state)
  let _ ← timeIt "normalize (of normalized)" 3 (fun _ => km (Lifecycle.normalize normalized))
  let _ ← timeIt "activationKey (of normalized)" 3 (fun _ => km (return list (← activationKey normalized)))
  let _ ← timeIt "normalizeLastSeq (of normalized)" 3 (fun _ => km (Lifecycle.normalizeLastSeq normalized))
  let _ ← timeIt "boundary (of normalized)" 3 (fun _ => km (Lifecycle.boundaryProviderStates normalized))
  let _ ← timeIt "migrationStates (of normalized)" 3 (fun _ => km (Lifecycle.migrationStates normalized))
  let _ ← timeIt "fillDefaults (of normalized)" 3 (fun _ => pure (Lifecycle.fillDefaults normalized).depth)
  let _ ← timeIt "normalize twice (idempotence cost)" 3 (fun _ => km (do Lifecycle.normalize (← Lifecycle.normalize state)))
  let ack := Term.map [(b "type", b "queue_ack"), (b "queue_ack_id", .integer 1)]
  let _ ← timeIt "run queue_ack (full run)" 3 (fun _ => pure (Session.run state ack []).depth)
  let _ ← timeIt "persistable+encode" 3 (fun _ => do
    let p ← km (Lifecycle.persistable state)
    match ETF.encode (.tuple [a "comma_internal_session", i 3, p]) with
    | .ok b => pure b.size | .error e => throw (IO.userError e))
  pure ()
