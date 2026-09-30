import VerifiedKernelProofs.Session.WorkStorageCursor

namespace VerifiedKernel.Session.WorkConservation
open Data CommandExecution DurableConfirmation ArchivePublication
set_option Elab.async false

theorem input_start_unique {result : Term} {left right : List Term} {notifyInput : Bool}
    (first : InputStart result left notifyInput) (second : InputStart result right notifyInput) : left = right := by
  rcases first with first | ⟨operation, metadata, workspace, billing, first⟩
  all_goals rcases second with second | ⟨operation', metadata', workspace', billing', second⟩
  all_goals have same := first.symm.trans second
  all_goals simp [Command.writeInput, Command.perform, a, b, list, Term.text] at same
  · exact same.1
  · exact same.2

namespace ValueSemantics

/-- Actual input execution and the native CAS continuation retain the complete input in a durable snapshot.
The caller must still connect these calls to the host's revision and prerequisite control flow. -/
theorem confirmed_input_durable_snapshot
    {state inputEntry born commandResult final next prepared stamped key base cursor request result restored etag : Term}
    {source : ByteArray} {batch metadata : List Term} {effects : List (Term × Result)}
    {j r prepareJournal prepareRest : List Term} {durable : HotSnapshots}
    (sourceValue : RoundQuery.atomFirst inputEntry "source_message_id" = .binary source)
    (ready : QueueReady state) (format : state.get (a "storage_format") = i 3)
    (input : Command.input state (.tuple [inputEntry, born]) j = .ok (commandResult, r))
    (trace : Trace commandResult effects final)
    (confirmed : final = Command.finish (.tuple [a "ok", a "committed"]) ∨
      ∃ notified, final = Command.perform (.tuple [a "notify", b "input_accepted", notified]) (b "input_notified"))
    (started : InputStart commandResult batch)
    (applied : ResidentBatch state batch next)
    (prepare : Lifecycle.prepareWrite next prepareJournal = .ok (.tuple [a "ok", prepared], prepareRest))
    (bookkeeping : ResidentBatch prepared metadata stamped)
    (canonical : ∀ event ∈ metadata, BinaryKeys event)
    (metadataOnly : ∀ event ∈ metadata, CommitMetadata event)
    (requested : StorageCommit.resident (some stamped) (a "start") (.tuple [key, base]) = (some cursor, request))
    (primitive : SnapshotCASMeaning request result durable)
    (resumed : StorageCommit.resident (some cursor) (a "resume") result = (some restored, .tuple [a "ok", etag])) :
    restored = stamped ∧ ∃ snapshot event now first last item,
      durable key etag snapshot ∧ QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
      Command.inputEvent (state.get (a "session_id")) (.binary source)
        (RoundQuery.atomFirst inputEntry "payload") now first = .ok (event, last) ∧
      MainInputFact event source item ∧ CanonicalQueueItem item ∧
      (∀ sealed, Represented snapshot sealed item) ∧
      (∀ sealed old, Represented state sealed old → Represented snapshot sealed old) := by
  obtain ⟨planned, event, now, first, last, planStart, _, generated, candidate⟩ :=
    confirmed_input_storage_request sourceValue ready format input trace confirmed
  have same := input_start_unique planStart started
  subst planned
  obtain ⟨cursorEq, preparedRequest⟩ := StorageCommit.start_capture requested
  rw [cursorEq] at resumed
  obtain ⟨restoredEq, outcome, resultEq⟩ := StorageCommit.resume_capture resumed
  obtain ⟨snapshot, bytes, requestEq, encoded, snapshotReady, snapshotFormat, kept, item, fields, shape, present⟩ :=
    candidate next prepared stamped key base request prepareJournal prepareRest metadata [] []
      applied prepare bookkeeping canonical metadataOnly preparedRequest
  exact ⟨restoredEq, snapshot, event, now, first, last, item,
    primitive key base bytes snapshot etag outcome requestEq encoded resultEq,
    snapshotReady, snapshotFormat, generated, fields, shape, present, kept⟩

end ValueSemantics
end VerifiedKernel.Session.WorkConservation
