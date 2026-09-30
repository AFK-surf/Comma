import VerifiedKernelProofs.Session.WorkPendingInput
import VerifiedKernel.Session.RevisionFence

namespace VerifiedKernel.Session.RevisionFence
open Data WorkConservation
set_option Elab.async false

theorem prepare_done {cursor : PendingRevision.Cursor} {key state : Term} {observations : List Term}
    (h : prepare cursor key observations = (some (prepared cursor key state), .tuple [a "prepared"])) :
    ∃ rest, Lifecycle.prepareWrite cursor.working observations = .ok (.tuple [a "ok", state], rest) := by
  unfold prepare at h
  split at h
  · simp at h
  split at h
  · rename_i result rest call
    split at h
    · have same := Option.some.inj (congrArg Prod.fst h)
      simp only [prepared, Term.tuple.injEq, List.cons.injEq, and_true, true_and] at same
      subst result
      exact ⟨rest, call⟩
    · simp [invalid] at h
  · simp [prepared] at h
  · simp [prepared, a] at h
  · simp [prepared] at h
  · simp [invalid] at h

inductive Preparation (cursor : PendingRevision.Cursor) (key : Term) : Output → Term → Prop where
  | done (state : Term) : Preparation cursor key (some (prepared cursor key state), .tuple [a "prepared"]) state
  | resume {observations : List Term} {request observation final : Term}
      (tail : Preparation cursor key (resident
        (some (.tuple [a "session_fence_preparing", cursor.pack, key, list observations]))
        (a "resume") observation) final) :
      Preparation cursor key
        (some (.tuple [a "session_fence_preparing", cursor.pack, key, list observations]), .tuple [a "observe", request]) final

theorem preparation_call {cursor : PendingRevision.Cursor} {key state : Term} {output : Output}
    (execution : Preparation cursor key output state)
    (origin : ∃ observations, output = prepare cursor key observations) :
    ∃ observations rest, Lifecycle.prepareWrite cursor.working observations = .ok (.tuple [a "ok", state], rest) := by
  induction execution with
  | done state =>
    obtain ⟨observations, origin⟩ := origin
    obtain ⟨rest, call⟩ := prepare_done origin.symm
    exact ⟨observations, rest, call⟩
  | @resume observations request observation final tail ih =>
    exact ih ⟨observations ++ [observation], rfl⟩

theorem start_prepares {cursor : PendingRevision.Cursor} {key state : Term} {observations : List Term}
    (execution : Preparation cursor key (resident (some cursor.pack) (a "start") (.tuple [key, list observations])) state) :
    ∃ journal rest, Lifecycle.prepareWrite cursor.working journal = .ok (.tuple [a "ok", state], rest) :=
  preparation_call execution ⟨observations, rfl⟩

theorem metadata_admitted (token reasons activity revision flush epoch node : Term) :
    ∀ event ∈ metadataEvents token reasons activity revision flush epoch node,
      BinaryKeys event ∧ CommitMetadata event := by
  intro event member
  unfold metadataEvents at member
  split at member
  · simp only [List.mem_append, List.mem_cons, List.mem_nil_iff, or_false] at member
    rcases member with (rfl | rfl | rfl) | rfl
    all_goals exact ⟨rfl, Or.inl ⟨rfl, rfl⟩⟩
  · simp only [List.append_nil, List.mem_cons, List.mem_nil_iff, or_false] at member
    rcases member with rfl | rfl | rfl
    all_goals exact ⟨rfl, Or.inl ⟨rfl, rfl⟩⟩

theorem metadata_run (cursor : PendingRevision.Cursor) (key batch args : Term) :
    resident (some (.tuple [a "session_fence_batch", cursor.pack, key, batch])) (a "run") args =
      acceptMetadata cursor key (BatchExecution.resident (some batch) (a "run") args) := rfl

theorem metadata_resume (cursor : PendingRevision.Cursor) (key batch args : Term) :
    resident (some (.tuple [a "session_fence_batch", cursor.pack, key, batch])) (a "resume") args =
      acceptMetadata cursor key (BatchExecution.resident (some batch) (a "resume") args) := rfl

inductive MetadataExecution (cursor : PendingRevision.Cursor) (key : Term) : Output → Term → Prop where
  | done (state : Term) : MetadataExecution cursor key
      (some (.tuple [a "session_fence_stamped", cursor.pack, key, state]), .tuple [a "stamped"]) state
  | run {state event final : Term} {events observations : List Term}
      (tail : MetadataExecution cursor key (resident
        (some (.tuple [a "session_fence_batch", cursor.pack, key, BatchExecution.pending state (event :: events)]))
        (a "run") (list observations)) final) :
      MetadataExecution cursor key
        (some (.tuple [a "session_fence_batch", cursor.pack, key, BatchExecution.pending state (event :: events)]), .tuple [a "next"]) final
  | resume {token request observation final : Term} {events : List Term}
      (tail : MetadataExecution cursor key (resident
        (some (.tuple [a "session_fence_batch", cursor.pack, key, BatchExecution.observing token events]))
        (a "resume") observation) final) :
      MetadataExecution cursor key
        (some (.tuple [a "session_fence_batch", cursor.pack, key, BatchExecution.observing token events]), .tuple [a "observe", request]) final

def MetadataMeaning (cursor : PendingRevision.Cursor) (key : Term) : Output → Term → Prop
  | (some value, .tuple [.atom "stamped"]), final =>
    value = .tuple [a "session_fence_stamped", cursor.pack, key, final]
  | (some (.tuple [.atom "session_fence_batch", saved, issued, batch]), response), final =>
    saved = cursor.pack ∧ issued = key ∧ BatchExecution.Meaning (some batch, response) final
  | _, _ => False

theorem accept_metadata_meaning {cursor : PendingRevision.Cursor} {key final : Term} {output : Output}
    (h : MetadataMeaning cursor key (acceptMetadata cursor key output) final) :
    BatchExecution.Meaning output final := by
  unfold acceptMetadata at h
  split at h
  · rename_i state
    change Term.tuple [a "session_fence_stamped", cursor.pack, key, state] =
      Term.tuple [a "session_fence_stamped", cursor.pack, key, final] at h
    change state = final
    simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using h
  · rename_i batch response _
    unfold MetadataMeaning at h
    split at h
    · simp_all [a]
    · rename_i saved issued nested reply _ shape
      simp only [Prod.mk.injEq, Option.some.injEq, Term.tuple.injEq, List.cons.injEq,
        and_true, true_and] at shape
      obtain ⟨⟨savedEq, keyEq, batchEq⟩, replyEq⟩ := shape
      subst saved issued nested reply
      exact h.2.2
    · exact h.elim
  · exact h.elim

theorem metadata_execution_meaning {cursor : PendingRevision.Cursor} {key final : Term} {output : Output}
    (execution : MetadataExecution cursor key output final) : MetadataMeaning cursor key output final := by
  induction execution with
  | done => rfl
  | run tail ih =>
    rw [metadata_run] at ih
    have meaning := accept_metadata_meaning ih
    simp only [BatchExecution.resident, BatchExecution.pending, a, list] at meaning
    obtain ⟨middle, head, rest⟩ := BatchExecution.accept_meaning meaning
    exact ⟨rfl, rfl, ResidentBatch.cons head rest⟩
  | resume tail ih =>
    rw [metadata_resume] at ih
    have meaning := accept_metadata_meaning ih
    simp only [BatchExecution.resident, BatchExecution.observing, a, list] at meaning
    obtain ⟨middle, head, rest⟩ := BatchExecution.accept_meaning meaning
    exact ⟨rfl, rfl, middle, ResidentTrace.resume head, rest⟩

theorem metadata_executes {cursor : PendingRevision.Cursor}
    {key before after token reasons activity revision flush epoch node : Term}
    (execution : MetadataExecution cursor key
      (resident (some (prepared cursor key before)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) after) :
    ResidentBatch before (metadataEvents token reasons activity revision flush epoch node) after := by
  have meaning := metadata_execution_meaning execution
  exact BatchExecution.next_meaning (accept_metadata_meaning meaning)

theorem encode_capture {cursor : PendingRevision.Cursor} {key state saved request : Term}
    (h : resident (some (.tuple [a "session_fence_stamped", cursor.pack, key, state]))
      (a "encode") nil = (some saved, request)) :
    ∃ commit, saved = .tuple [a "session_fence_cas", commit] ∧
      StorageCommit.resident (some state) (a "start") (.tuple [key, cursor.etag]) = (some commit, request) := by
  change encode cursor key state = (some saved, request) at h
  unfold encode at h
  split at h
  · rename_i commit issued call
    cases h
    exact ⟨commit, rfl, call⟩
  · have impossible := congrArg Prod.fst h
    cases impossible

theorem confirmed_capture {cursor : PendingRevision.Cursor}
    {key state saved request result restored etag : Term} {durable : ArchivePublication.HotSnapshots}
    (encoded : resident (some (.tuple [a "session_fence_stamped", cursor.pack, key, state]))
      (a "encode") nil = (some saved, request))
    (primitive : ArchivePublication.SnapshotCASMeaning request result durable)
    (resumed : resident (some saved) (a "cas_result") result = (some restored, .tuple [a "ok", etag])) :
    restored = state ∧ ∃ snapshot bytes,
      Lifecycle.persistable state [] = .ok (snapshot, []) ∧
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      request = .tuple [a "cas", key, .binary bytes, cursor.etag] ∧ durable key etag snapshot := by
  obtain ⟨commit, same, started⟩ := encode_capture encoded
  subst saved
  exact StorageCommit.confirmed_candidate started primitive resumed

theorem candidate_preserves {cursor : PendingRevision.Cursor}
    {key preparedState stamped token reasons activity revision flush epoch node saved request result restored etag : Term}
    {observations : List Term} {durable : ArchivePublication.HotSnapshots}
    (ready : QueueReady cursor.working) (format : cursor.working.get (a "storage_format") = i 3)
    (preparation : Preparation cursor key
      (resident (some cursor.pack) (a "start") (.tuple [key, list observations])) preparedState)
    (metadata : MetadataExecution cursor key
      (resident (some (prepared cursor key preparedState)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) stamped)
    (encoded : resident (some (.tuple [a "session_fence_stamped", cursor.pack, key, stamped]))
      (a "encode") nil = (some saved, request))
    (primitive : ArchivePublication.SnapshotCASMeaning request result durable)
    (resumed : resident (some saved) (a "cas_result") result = (some restored, .tuple [a "ok", etag])) :
    restored = stamped ∧ ∃ snapshot,
      durable key etag snapshot ∧ QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
      ∀ sealed item, ValueSemantics.Represented cursor.working sealed item →
        ValueSemantics.Represented snapshot sealed item := by
  obtain ⟨journal, rest, preparationCall⟩ := start_prepares preparation
  obtain ⟨normalized, same, preparedFormat, preparedReady, _⟩ :=
    prepareWrite_modern format (Or.inr rfl) ready preparationCall
  have equal : preparedState = normalized := by
    simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using same
  subst normalized
  obtain ⟨stampedReady, stampedFormat, kept⟩ := ValueSemantics.metadata_work
    (metadata_executes metadata)
    (fun event member => (metadata_admitted token reasons activity revision flush epoch node event member).1)
    (fun event member => (metadata_admitted token reasons activity revision flush epoch node event member).2)
    preparedReady
  obtain ⟨restoredEq, snapshot, bytes, persisted, _, _, committed⟩ := confirmed_capture encoded primitive resumed
  refine ⟨restoredEq, snapshot, committed, (persistable_preserves stampedReady persisted).1,
    (persistable_queue_frame persisted).2.2.2.2.trans (stampedFormat.trans preparedFormat), ?_⟩
  intro sealed item represented
  exact ValueSemantics.work_fields_preserves (persistable_work_fields persisted)
    (kept sealed item (ValueSemantics.prepareWrite_preserves ready format preparationCall represented))

theorem input_durable {cursor staged : PendingRevision.Cursor}
    {inputEntry born commandResult hwm key preparedState stamped token reasons activity revision flush epoch node
      saved request result restored etag : Term}
    {source : ByteArray} {batch journal rest observations : List Term} {durable : ArchivePublication.HotSnapshots}
    (sourceValue : RoundQuery.atomFirst inputEntry "source_message_id" = .binary source)
    (ready : QueueReady cursor.working) (format : cursor.working.get (a "storage_format") = i 3)
    (input : Command.input cursor.working (.tuple [inputEntry, born]) journal = .ok (commandResult, rest))
    (started : InputStart commandResult batch)
    (write : PendingRevision.Execution
      (PendingRevision.resident (some cursor.pack) (a "write") (.tuple [list batch, hwm])) staged)
    (preparation : Preparation staged key
      (resident (some staged.pack) (a "start") (.tuple [key, list observations])) preparedState)
    (metadata : MetadataExecution staged key
      (resident (some (prepared staged key preparedState)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) stamped)
    (encoded : resident (some (.tuple [a "session_fence_stamped", staged.pack, key, stamped]))
      (a "encode") nil = (some saved, request))
    (primitive : ArchivePublication.SnapshotCASMeaning request result durable)
    (resumed : resident (some saved) (a "cas_result") result = (some restored, .tuple [a "ok", etag])) :
    staged.baseline = cursor.baseline ∧ staged.etag = cursor.etag ∧ restored = stamped ∧
      ∃ snapshot event now first last item,
        durable key etag snapshot ∧ QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
        Command.inputEvent (cursor.working.get (a "session_id")) (.binary source)
          (RoundQuery.atomFirst inputEntry "payload") now first = .ok (event, last) ∧
        MainInputFact event source item ∧ CanonicalQueueItem item ∧
        (∀ sealed, ValueSemantics.Represented snapshot sealed item) ∧
        (∀ sealed old, ValueSemantics.Represented cursor.working sealed old → ValueSemantics.Represented snapshot sealed old) := by
  obtain ⟨baselineEq, etagEq, _, stagedReady, stagedFormat, oldKept,
    event, now, first, last, item, generated, fields, shape, present⟩ :=
    PendingRevision.input_write_preserves sourceValue ready input started write
  obtain ⟨restoredEq, snapshot, committed, snapshotReady, snapshotFormat, kept⟩ :=
    candidate_preserves stagedReady (stagedFormat.trans format) preparation metadata encoded primitive resumed
  exact ⟨baselineEq, etagEq, restoredEq, snapshot, event, now, first, last, item,
    committed, snapshotReady, snapshotFormat, generated, fields, shape,
    fun sealed => kept sealed item (present sealed),
    fun sealed old represented => kept sealed old (oldKept sealed old represented)⟩

end VerifiedKernel.Session.RevisionFence
