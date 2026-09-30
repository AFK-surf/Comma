import VerifiedKernelProofs.Session.WorkRevisionFence

namespace VerifiedKernel.Session.ArchivePublication
open Data WorkConservation
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem resident_archive_call {state event final : Term}
    (canonical : BinaryKeys event) (kind : event.get (b "type") = b "archive_advance")
    (execution : ResidentBatch state [event] final) :
    ActivityFrame state final ∨ ∃ next journal rest,
      archiveAdvance state event journal = .ok (next, rest) ∧ ActivityFrame next final := by
  cases execution with
  | cons head tail =>
    cases tail
    obtain ⟨next, normalized, journal, rest, prepared, activity⟩ := resident_execution_step head
    cases normalized with
    | none =>
      rw [prepareTrusted_none prepared] at activity
      exact Or.inl activity
    | some normalized =>
      obtain ⟨before, read, after, call⟩ := prepareTrusted_stringify prepared
      have same := shallowStringify_binary_keys canonical read
      subst normalized
      refine Or.inr ⟨next, before, after, ?_, activity⟩
      simpa +decide [inner, kind] using call

theorem fence_catalog {cursor : PendingRevision.Cursor}
    {key preparedState stamped token reasons activity revision flush epoch node saved request result restored etag : Term}
    {catalog : List Term} {watermark : Int} {observations : List Term} {durable : HotSnapshots}
    (format : cursor.working.get (a "storage_format") = i 3)
    (read : cursor.working.get (a "segment_catalog") = list catalog)
    (through : cursor.working.get (a "archived_through") = i watermark)
    (valid : ∀ value ∈ catalog, validSegment value = true)
    (preparation : RevisionFence.Preparation cursor key
      (RevisionFence.resident (some cursor.pack) (a "start") (.tuple [key, list observations])) preparedState)
    (metadata : RevisionFence.MetadataExecution cursor key
      (RevisionFence.resident (some (RevisionFence.prepared cursor key preparedState)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) stamped)
    (encoded : RevisionFence.resident (some (.tuple [a "session_fence_stamped", cursor.pack, key, stamped]))
      (a "encode") nil = (some saved, request))
    (primitive : SnapshotCASMeaning request result durable)
    (resumed : RevisionFence.resident (some saved) (a "cas_result") result = (some restored, .tuple [a "ok", etag])) :
    restored = stamped ∧ ∃ snapshot,
      durable key etag snapshot ∧ snapshot.get (a "segment_catalog") = list catalog ∧
      snapshot.get (a "archived_through") = i watermark := by
  obtain ⟨journal, rest, preparationCall⟩ := RevisionFence.start_prepares preparation
  have preparedFields := prepareWrite_archive_fields format read through valid preparationCall
  have stampedFields := metadata_batch_archive_frame (RevisionFence.metadata_executes metadata)
    (fun event member => (RevisionFence.metadata_admitted token reasons activity revision flush epoch node event member).1)
    (fun event member => (RevisionFence.metadata_admitted token reasons activity revision flush epoch node event member).2)
  obtain ⟨same, snapshot, bytes, persisted, _, _, committed⟩ :=
    RevisionFence.confirmed_capture encoded primitive resumed
  have persistedFields := persistable_archive_fields persisted
  exact ⟨same, snapshot, committed,
    persistedFields.1.trans (stampedFields.1.trans preparedFields.1),
    persistedFields.2.trans (stampedFields.2.1.trans preparedFields.2)⟩

theorem published_pending_fence_input
    {state event base key preparedState stamped token reasons activity revision flush epoch node
      saved request result restored etag : Term} {staged : PendingRevision.Cursor}
    {records live : List Term} {archiveBase ceiling line : Int}
    {before after : Objects} {durable : HotSnapshots} {final : Output} {observations : List Term}
    (framing : CodecFraming) (sorted : SeqSorted state)
    (format : state.get (a "storage_format") = i 3)
    (numeric : (state.get (a "archived_through")).default (i 0) = i archiveBase) (nonnegative : archiveBase ≥ 0)
    (initial : StateCatalogBacked before state)
    (catalog : ∀ value ∈ wrap ((state.get (a "segment_catalog")).default (list [])), validSegment value = true)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0)
    (publication : Execution (start state (i line)) before final after)
    (emitted : final.2 = .tuple [a "advance", event])
    (read : state.get (a "messages") = list live)
    (write : PendingRevision.Execution
      (PendingRevision.resident (some (PendingRevision.Cursor.mk state state base [] nil).pack)
        (a "write") (.tuple [list [event], nil])) staged)
    (preparation : RevisionFence.Preparation staged key
      (RevisionFence.resident (some staged.pack) (a "start") (.tuple [key, list observations])) preparedState)
    (metadata : RevisionFence.MetadataExecution staged key
      (RevisionFence.resident (some (RevisionFence.prepared staged key preparedState)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) stamped)
    (encoded : RevisionFence.resident (some (.tuple [a "session_fence_stamped", staged.pack, key, stamped]))
      (a "encode") nil = (some saved, request))
    (primitive : SnapshotCASMeaning request result durable)
    (resumed : RevisionFence.resident (some saved) (a "cas_result") result = (some restored, .tuple [a "ok", etag])) :
    staged.etag = base ∧ (staged.working.get (a "messages") = state.get (a "messages") ∨
      ∃ (snapshot : Term) (dropped kept : List Term),
        durable key etag snapshot ∧ live = dropped ++ kept ∧ staged.working.get (a "messages") = list kept ∧
        ∀ item record, record ∈ dropped → ValueSemantics.Recorded item record →
          ∃ stored count actual,
            entry stored count ∈ wrap (snapshot.get (a "segment_catalog")) ∧
            after (ArchivePublication.key (state.get (a "agent_id")) (state.get (a "session_id"))
              ((stored.head?.getD nil).get (a "seq"))) stored ∧ actual ∈ stored ∧
            ValueSemantics.Equivalent (queueWorkProjection item)
              ((actual.get (a "data")).get (b "accepted_input"))) := by
  obtain ⟨_, _, _, etagEq, _, _, applied⟩ := PendingRevision.write_executes write
  change ResidentBatch state [event] staged.working at applied
  obtain ⟨agent, session, through, entries, shape, _⟩ := publication_catalog_backed initial publication emitted
  have canonical : BinaryKeys event := by rw [shape]; rfl
  have kind : event.get (b "type") = b "archive_advance" := by rw [shape]; rfl
  refine ⟨etagEq, ?_⟩
  rcases resident_archive_call canonical kind applied with unchanged | ⟨next, journal, rest, reduced, framed⟩
  · exact Or.inl (unchanged "messages" (by decide) (by decide))
  · rcases published_archive_catalog_input framing sorted numeric nonnegative initial catalog window positive
        publication emitted read reduced with unchanged | ⟨dropped, kept, partition, nextMessages, storedInputs⟩
    · rw [unchanged] at framed
      exact Or.inl (framed "messages" (by decide) (by decide))
    · rcases archiveAdvance_storage_fields reduced with unchanged | ⟨catalogEntries, watermark, permuted, nextCatalog, nextBase, _⟩
      · rw [unchanged] at framed
        exact Or.inl (framed "messages" (by decide) (by decide))
      · have valid : ∀ value ∈ catalogEntries, validSegment value = true := by
          intro value member
          exact (List.mem_filter.mp (permuted.mem_iff.mp member)).2
        have nextFormat := (archiveAdvance_queue_frame reduced).2.2.2.2.trans format
        have stagedFormat := (framed "storage_format" (by decide) (by decide)).trans nextFormat
        have stagedCatalog := (framed "segment_catalog" (by decide) (by decide)).trans nextCatalog
        have stagedBase := (framed "archived_through" (by decide) (by decide)).trans nextBase
        obtain ⟨_, snapshot, committed, snapshotCatalog, _⟩ :=
          fence_catalog stagedFormat stagedCatalog stagedBase valid preparation metadata encoded primitive resumed
        refine Or.inr ⟨snapshot, dropped, kept, committed, partition,
          (framed "messages" (by decide) (by decide)).trans nextMessages, ?_⟩
        intro item record member recorded
        obtain ⟨stored, count, actual, listed, fact, present, same⟩ := storedInputs item record member recorded
        refine ⟨stored, count, actual, ?_, fact, present, same⟩
        rw [snapshotCatalog, ← nextCatalog]
        exact listed

end VerifiedKernel.Session.ArchivePublication
