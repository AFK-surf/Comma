import VerifiedKernel.Session.CommandDriver
import VerifiedKernelProofs.Session.WorkRevision
import VerifiedKernelProofs.Session.WorkInputTimestamp

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

theorem start_captured (context : Context) (args : Term) (observations : List Term) :
    resident (some context.pack) (a "start") (.tuple [args, list observations]) =
      query context (a "start") args observations := by
  cases context <;> rfl

theorem input_query_success {context : Context} {args result : Term} {observations rest : List Term}
    (call : Command.input context.candidate.working args observations = .ok (result, rest))
    (complete : settled rest = true) :
    query context (a "start") (.tuple [a "input", args, nil]) observations = issue context result := by
  have actual : Command.start context.candidate.working (.tuple [a "input", args, nil]) observations =
      .ok (result, rest) := call
  simp only [query, a, actual, complete, ↓reduceIte]

theorem command_query_success {context : Context} {args result : Term} {observations rest : List Term}
    (call : Command.start context.candidate.working args observations = .ok (result, rest))
    (complete : settled rest = true) :
    query context (a "start") args observations = issue context result := by
  simp only [query, a, call, complete, ↓reduceIte]

theorem effect_captured (context : Context) (continuation request result : Term)
    (valid : effectResultValid request result = true) :
    resident (some (.tuple [a "session_command_driver_effect", context.pack, continuation, request]))
      (a "effect_result") result =
      query context (a "resume") (.tuple [continuation, result]) [] := by
  have same : resident
      (some (.tuple [a "session_command_driver_effect", context.pack, continuation, request]))
      (a "effect_result") result =
      if effectResultValid request result then query context (a "resume") (.tuple [continuation, result]) [] else invalid := by
    cases context <;> rfl
  rw [same, valid]
  rfl

theorem resume_query_success {context : Context} {args result : Term} {observations rest : List Term}
    (call : Command.resume context.candidate.working args observations = .ok (result, rest))
    (complete : settled rest = true) :
    query context (a "resume") args observations = issue context result := by
  simp only [query, a, call, complete, ↓reduceIte]

theorem write_captured (context : Context) (continuation : Term) (events : List Term) (hwm : Term) :
    resident (some (.tuple [a "session_command_driver_write", context.pack, continuation, list events, hwm]))
      (a "write_result") (a "ok") =
      acceptWrite context continuation
        (Revision.resident (some context.pack) (a "write") (.tuple [list events, hwm])) := by
  cases context <;> rfl

theorem timestamp_write_captured (context : Context) (continuation : Term) (events : List Term)
    (hwm : Term) (milliseconds : Int) :
    resident (some (.tuple [a "session_command_driver_write_time", context.pack, continuation, list events, hwm]))
      (a "resume") (.tuple [a "ok", i milliseconds]) =
      preparedWrite context continuation (events.map (fun event => Command.timestampLifecycle event (milliseconds / 1000))) hwm := by
  cases context <;> rfl

theorem timestamp_unneeded {event : Term} (now : Int) (h : needsTimestamp event = false) :
    Command.timestampLifecycle event now = event := by
  change (if needsTimestamp event then event.put (b "created_at") (i now) else event) = event
  rw [h]
  rfl

theorem timestamp_fixed_no_clock {event : Term} (fixed : TimestampFixed event) : needsTimestamp event = false := by
  cases kind : [b "session_created", b "status", b "activity_status", b "wait_set", b "wait_clear"].contains
      (event.get (b "type")) with
  | false => simp [needsTimestamp, kind]
  | true => simp [needsTimestamp, kind, fixed_lifecycle_created_integer fixed kind]

theorem input_write_unchanged {context : Context} {args result continuation : Term} {batch journal rest : List Term}
    (input : Command.input context.candidate.working args journal = .ok (result, rest))
    (started : InputStart result batch) :
    issueWrite context continuation batch nil = preparedWrite context continuation batch nil := by
  have noClock : batch.any needsTimestamp = false := List.any_eq_false.mpr (by
    intro event member
    simp [timestamp_fixed_no_clock (input_timestamp_fixed input started event member)])
  simp only [issueWrite, noClock, Bool.false_eq_true, ↓reduceIte]

theorem completed_write_resumes (context : Context) (continuation : Term) (final : PendingRevision.Cursor) :
    acceptWrite context continuation (some final.pack, .tuple [a "done"]) =
      query (.pending final) (a "resume") (.tuple [continuation, a "ok"]) [] := rfl

theorem run_write_captured (context : Context) (continuation batch observations : Term) :
    resident (some (.tuple [a "session_command_driver_batch", context.pack, continuation, batch]))
      (a "run") observations =
      acceptWrite context continuation (PendingRevision.resident (some batch) (a "run") observations) := by
  cases context <;> rfl

theorem resume_write_captured (context : Context) (continuation batch observation : Term) :
    resident (some (.tuple [a "session_command_driver_batch", context.pack, continuation, batch]))
      (a "resume") observation =
      acceptWrite context continuation (PendingRevision.resident (some batch) (a "resume") observation) := by
  cases context <;> rfl

theorem pending_cannot_confirm_clean (cursor : PendingRevision.Cursor) (continuation : Term) :
    resident (some (.tuple [a "session_command_driver_fence", cursor.pack, continuation]))
      (a "fence_clean") nil = invalid := rfl

theorem fresh_cannot_confirm_clean (state continuation : Term) :
    resident (some (.tuple [a "session_command_driver_fence",
      (Revision.Cursor.fresh state).pack, continuation])) (a "fence_clean") nil = invalid := rfl

theorem fence_start_captured (cursor : PendingRevision.Cursor) (continuation key : Term) (observations : List Term) :
    resident (some (.tuple [a "session_command_driver_fence", cursor.pack, continuation]))
      (a "fence_start") (.tuple [key, list observations]) =
      acceptFence (.pending cursor) continuation
        (RevisionFence.resident (some cursor.pack) (a "start") (.tuple [key, list observations])) := rfl

theorem stamp_captured (context : Context) (continuation fence metadata : Term) :
    resident (some (.tuple [a "session_command_driver_fencing", context.pack, continuation, fence]))
      (a "stamp") metadata =
      acceptFence context continuation (RevisionFence.resident (some fence) (a "stamp") metadata) := by
  cases context <;> rfl

theorem encode_captured (context : Context) (continuation fence : Term) :
    resident (some (.tuple [a "session_command_driver_fencing", context.pack, continuation, fence]))
      (a "encode") nil =
      acceptFence context continuation (RevisionFence.resident (some fence) (a "encode") nil) := by
  cases context <;> rfl

theorem accept_fence_cas_capture {context : Context} {continuation saved key bytes base : Term} {output : Output}
    (h : acceptFence context continuation output = (some saved, .tuple [a "cas", key, bytes, base])) :
    ∃ fence, output = (some fence, .tuple [a "cas", key, bytes, base]) ∧
      saved = .tuple [a "session_command_driver_fencing", context.pack, continuation, fence] := by
  unfold acceptFence at h
  split at h
  · have impossible := congrArg Prod.snd h
    simp [rejected, a] at impossible
  · rename_i fence response
    have same := Prod.mk.inj h
    exact ⟨fence, by rw [same.2], (Option.some.inj same.1).symm⟩
  · have impossible := congrArg Prod.fst h
    cases impossible

theorem confirmed_resumes_captured (state etag continuation : Term) :
    resident (some (.tuple [a "session_command_driver_confirmed", (Revision.Cursor.committed state etag).pack, continuation]))
      (a "next") nil =
      query (.committed state etag) (a "resume") (.tuple [continuation, a "ok"]) [] := rfl

theorem rejected_restores_baseline (context : Context) (continuation reason candidate : Term) :
    rejected context continuation reason candidate =
      (some (.tuple [a "session_command_driver_rejected",
        context.baseline.pack,
        continuation, reason, candidate]), .tuple [a "rejected", reason]) := rfl

theorem accept_cas_capture {context : Context} {continuation confirmed : Term} {output : Output}
    (h : acceptCAS context continuation output = (some confirmed, .tuple [a "committed"])) :
    ∃ saved state etag, output = (some saved, .tuple [a "committed"]) ∧
      unpack saved = some (.committed state etag) ∧
      confirmed = .tuple [a "session_command_driver_confirmed", (Revision.Cursor.committed state etag).pack, continuation] := by
  unfold acceptCAS at h
  split at h
  · rename_i saved
    split at h
    · rename_i state etag opened
      exact ⟨saved, state, etag, rfl, opened, (Option.some.inj (congrArg Prod.fst h)).symm⟩
    · have impossible := congrArg Prod.fst h
      cases impossible
  · have impossible := congrArg Prod.snd h
    simp [rejected, a] at impossible
  · have impossible := congrArg Prod.fst h
    cases impossible
  · have impossible := congrArg Prod.fst h
    cases impossible

/-- A positive input fence retains its command continuation and the exact durable candidate. -/
theorem confirmed_snapshot {context : Context} {cursor : PendingRevision.Cursor}
    {key state saved request result continuation confirmed : Term} {durable : ArchivePublication.HotSnapshots}
    (encoded : RevisionFence.resident
      (some (.tuple [a "session_fence_stamped", cursor.pack, key, state]))
      (a "encode") nil = (some saved, request))
    (primitive : ArchivePublication.SnapshotCASMeaning request result durable)
    (resumed : resident (some (.tuple [a "session_command_driver_fencing", context.pack, continuation, saved]))
      (a "cas_result") result = (some confirmed, .tuple [a "committed"])) :
    ∃ etag snapshot bytes,
      confirmed = .tuple [a "session_command_driver_confirmed", (Revision.Cursor.committed state etag).pack, continuation] ∧
      Lifecycle.persistable state [] = .ok (snapshot, []) ∧
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      request = .tuple [a "cas", key, .binary bytes, cursor.etag] ∧ durable key etag snapshot := by
  have actual : acceptCAS context continuation (RevisionFence.resident (some saved) (a "cas_revision") result) =
      (some confirmed, .tuple [a "committed"]) := by
    cases context <;> exact resumed
  obtain ⟨committed, returnedState, returnedEtag, raw, opened, same⟩ := accept_cas_capture actual
  obtain ⟨etag, snapshot, bytes, packed, persisted, encodedBytes, requested, stored⟩ :=
    Revision.confirmed_revision encoded primitive raw
  rw [packed] at opened
  have pair : state = returnedState ∧ etag = returnedEtag := by
    simpa only [unpack, Revision.unpack_pack, Option.some.injEq, Revision.Cursor.committed.injEq] using opened
  rw [← pair.1, ← pair.2] at same
  exact ⟨etag, snapshot, bytes, same, persisted, encodedBytes, requested, stored⟩

/-- The actual input encode/resume pair keeps one continuation and its issued CAS candidate. -/
theorem issued_confirmation {context : Context} {cursor : PendingRevision.Cursor}
    {key state saved requestedKey requestedBytes requestedBase result continuation confirmed : Term}
    {durable : ArchivePublication.HotSnapshots}
    (encoded : resident (some (.tuple [a "session_command_driver_fencing", context.pack, continuation,
      .tuple [a "session_fence_stamped", cursor.pack, key, state]])) (a "encode") nil =
        (some saved, .tuple [a "cas", requestedKey, requestedBytes, requestedBase]))
    (primitive : ArchivePublication.SnapshotCASMeaning
      (.tuple [a "cas", requestedKey, requestedBytes, requestedBase]) result durable)
    (resumed : resident (some saved) (a "cas_result") result = (some confirmed, .tuple [a "committed"])) :
    ∃ etag snapshot bytes,
      confirmed = .tuple [a "session_command_driver_confirmed", (Revision.Cursor.committed state etag).pack, continuation] ∧
      Lifecycle.persistable state [] = .ok (snapshot, []) ∧
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      (.tuple [a "cas", requestedKey, requestedBytes, requestedBase] : Term) =
        .tuple [a "cas", key, .binary bytes, cursor.etag] ∧ durable key etag snapshot := by
  rw [encode_captured] at encoded
  obtain ⟨fence, inner, captured⟩ := accept_fence_cas_capture encoded
  rw [captured] at resumed
  exact confirmed_snapshot inner primitive resumed

/-- The actual staged input and issued CAS supply the durable facts behind its captured command continuation. -/
theorem input_confirmation_durable {context : Context} {staged : PendingRevision.Cursor}
    {inputEntry born commandResult key preparedState stamped token reasons activity revision flush epoch node
      saved requestedKey requestedBytes requestedBase result continuation confirmed : Term}
    {source : ByteArray} {batch journal rest observations : List Term} {durable : ArchivePublication.HotSnapshots}
    (sourceValue : RoundQuery.atomFirst inputEntry "source_message_id" = .binary source)
    (ready : QueueReady context.candidate.working)
    (format : context.candidate.working.get (a "storage_format") = i 3)
    (input : Command.input context.candidate.working (.tuple [inputEntry, born]) journal = .ok (commandResult, rest))
    (started : InputStart commandResult batch)
    (write : Revision.Execution
      (Revision.resident (some context.pack) (a "write") (.tuple [list batch, nil])) staged)
    (preparation : RevisionFence.Preparation staged key
      (RevisionFence.resident (some staged.pack) (a "start") (.tuple [key, list observations])) preparedState)
    (metadata : RevisionFence.MetadataExecution staged key
      (RevisionFence.resident (some (RevisionFence.prepared staged key preparedState)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) stamped)
    (encoded : resident (some (.tuple [a "session_command_driver_fencing", staged.pack, continuation,
      .tuple [a "session_fence_stamped", staged.pack, key, stamped]])) (a "encode") nil =
        (some saved, .tuple [a "cas", requestedKey, requestedBytes, requestedBase]))
    (primitive : ArchivePublication.SnapshotCASMeaning
      (.tuple [a "cas", requestedKey, requestedBytes, requestedBase]) result durable)
    (resumed : resident (some saved) (a "cas_result") result = (some confirmed, .tuple [a "committed"])) :
    staged.baseline = context.candidate.baseline ∧ staged.etag = context.candidate.etag ∧
      ∃ etag snapshot event now first last item,
        confirmed = .tuple [a "session_command_driver_confirmed", (Revision.Cursor.committed stamped etag).pack, continuation] ∧
        durable key etag snapshot ∧ QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
        Command.inputEvent (context.candidate.working.get (a "session_id")) (.binary source)
          (RoundQuery.atomFirst inputEntry "payload") now first = .ok (event, last) ∧
        MainInputFact event source item ∧ CanonicalQueueItem item ∧
        (∀ sealed, ValueSemantics.Represented snapshot sealed item) ∧
        (∀ sealed old, ValueSemantics.Represented context.candidate.working sealed old →
          ValueSemantics.Represented snapshot sealed old) := by
  change resident (some (.tuple [a "session_command_driver_fencing", (Revision.Cursor.pending staged).pack, continuation,
    .tuple [a "session_fence_stamped", staged.pack, key, stamped]])) (a "encode") nil = _ at encoded
  rw [encode_captured] at encoded
  obtain ⟨fence, inner, captured⟩ := accept_fence_cas_capture encoded
  rw [captured] at resumed
  change acceptCAS (.pending staged) continuation (RevisionFence.resident (some fence) (a "cas_revision") result) =
    (some confirmed, .tuple [a "committed"]) at resumed
  obtain ⟨committed, returnedState, returnedEtag, raw, opened, same⟩ := accept_cas_capture resumed
  obtain ⟨etag, packed, rawResult⟩ := Revision.confirmed_raw inner raw
  rw [packed] at opened
  have pair : stamped = returnedState ∧ etag = returnedEtag := by
    simpa only [unpack, Revision.unpack_pack, Option.some.injEq, Revision.Cursor.committed.injEq] using opened
  rw [← pair.1, ← pair.2] at same
  have pendingWrite := Revision.execution_pending write
  rw [Revision.write_captured] at pendingWrite
  obtain ⟨baselineEq, etagEq, _, snapshot, event, now, first, last, item,
    stored, snapshotReady, snapshotFormat, generated, fact, canonical, present, kept⟩ :=
    RevisionFence.input_durable sourceValue ready format input started pendingWrite
      preparation metadata inner primitive rawResult
  exact ⟨baselineEq, etagEq, etag, snapshot, event, now, first, last, item,
    same, stored, snapshotReady, snapshotFormat, generated, fact, canonical, present, kept⟩

end VerifiedKernel.Session.CommandDriver
