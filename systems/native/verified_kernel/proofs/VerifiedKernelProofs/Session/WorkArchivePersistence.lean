import VerifiedKernelProofs.Session.WorkArchiveCommit
import VerifiedKernelProofs.Session.WorkStorageCommit
import VerifiedKernelProofs.Session.WorkArchiveMetadata

namespace VerifiedKernel.Session.ArchivePublication
open Data WorkConservation
set_option Elab.async false
set_option maxHeartbeats 1000000
set_option maxRecDepth 4096

theorem parse_valid_entry {value : Term} (valid : validSegment value = true) : Lifecycle.parseEntry value = true := by
  unfold validSegment at valid
  split at valid
  · exact valid
  · cases valid

def catalogFold (acc : List Term) (value : Term) : KernelM (List Term) :=
  pure (if Lifecycle.parseEntry value then acc ++ [value] else acc)

theorem catalog_fold_exact {records initial result : List Term} {j r : List Term}
    (valid : ∀ value ∈ records, validSegment value = true)
    (h : records.foldlM catalogFold initial j = .ok (result, r)) : result = initial ++ records := by
  induction records generalizing initial j with
  | nil => simpa using pure_ok h
  | cons value rest ih =>
    rw [List.foldlM_cons] at h
    obtain ⟨next, _, step, h⟩ := bind_ok h
    have parsed := parse_valid_entry (valid value List.mem_cons_self)
    simp only [catalogFold, parsed, ↓reduceIte] at step
    have nextEq := pure_ok step
    subst next
    simpa [List.append_assoc] using ih (fun value member => valid value (List.mem_cons_of_mem _ member)) h

theorem segmentCatalog_preserves {records : List Term} {result : Term} {j r : List Term}
    (valid : ∀ value ∈ records, validSegment value = true)
    (h : Lifecycle.segmentCatalog (list records) j = .ok (result, r)) : result = list records := by
  unfold Lifecycle.segmentCatalog at h
  obtain ⟨kept, _, folded, h⟩ := bind_ok h
  obtain ⟨items, folding, enumerated⟩ := enumFold_ok folded
  rw [enumerated _ rfl] at folding
  have same : kept = records := by simpa using catalog_fold_exact valid folding
  rw [pure_ok h, same]

theorem normalize_archive_fields {s t : Term} {catalog : List Term} {base : Int} {j r : List Term}
    (read : s.get (a "segment_catalog") = list catalog)
    (watermark : s.get (a "archived_through") = i base)
    (valid : ∀ value ∈ catalog, validSegment value = true)
    (h : Lifecycle.normalize s j = .ok (t, r)) :
    t.get (a "segment_catalog") = list catalog ∧ t.get (a "archived_through") = i base := by
  have filledCatalog := (fillDefaults_get (key := "segment_catalog") (s := s)
    (by rw [read]; intro impossible; cases impossible)).trans read
  have filledBase := (fillDefaults_get (key := "archived_through") (s := s)
    (by rw [watermark]; intro impossible; cases impossible)).trans watermark
  unfold Lifecycle.normalize at h
  repeat
    fail_if_success (bind_field_is h "archived_through"; change (field (Lifecycle.fillDefaults s) "archived_through" >>= _) _ = _ at h)
    obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨storedBase, _, baseRead, h⟩ := bind_ok h
  have baseEq := (field_value baseRead).trans filledBase
  subst storedBase
  repeat
    fail_if_success (bind_field_is h "segment_catalog"; change (field (Lifecycle.fillDefaults s) "segment_catalog" >>= _) _ = _ at h)
    obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨storedCatalog, _, catalogRead, h⟩ := bind_ok h
  have catalogEq := (field_value catalogRead).trans filledCatalog
  subst storedCatalog
  obtain ⟨normalizedCatalog, _, parsed, h⟩ := bind_ok h
  have normalizedEq := segmentCatalog_preserves valid parsed
  subst normalizedCatalog
  repeat
    fail_if_success (bind_head_is h [write]; change (write _ _ >>= _) _ = _ at h)
    obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨normalized, _, written, h⟩ := bind_ok h
  have catalogWritten := write_get_key "segment_catalog" written rfl
  have baseWritten := write_get_key "archived_through" written rfl
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, activityWrite, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, providersWrite, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  constructor
  · exact (write_field_frame h rfl).trans
      ((write_field_frame providersWrite rfl).trans ((write_field_frame activityWrite rfl).trans catalogWritten))
  · exact (write_field_frame h rfl).trans
      ((write_field_frame providersWrite rfl).trans ((write_field_frame activityWrite rfl).trans baseWritten))

theorem prepareWrite_archive_fields {s prepared : Term} {catalog : List Term} {base : Int} {j r : List Term}
    (format : s.get (a "storage_format") = i 3)
    (read : s.get (a "segment_catalog") = list catalog)
    (watermark : s.get (a "archived_through") = i base)
    (valid : ∀ value ∈ catalog, validSegment value = true)
    (h : Lifecycle.prepareWrite s j = .ok (.tuple [a "ok", prepared], r)) :
    prepared.get (a "segment_catalog") = list catalog ∧ prepared.get (a "archived_through") = i base := by
  unfold Lifecycle.prepareWrite at h
  obtain ⟨normalized, _, normalizedCall, h⟩ := bind_ok h
  have fields := normalize_archive_fields read watermark valid normalizedCall
  have normalizedFormat := normalize_format format normalizedCall
  obtain ⟨value, _, formatRead, h⟩ := bind_ok h
  have formatEq := (field_value formatRead).trans normalizedFormat
  subst value
  simp only [show (i 3 == i 1) = false from rfl, show (i 3 == i 2 || i 3 == i 3) = true from rfl,
    Bool.false_eq_true, ↓reduceIte] at h
  obtain ⟨after, _, written, h⟩ := bind_ok h
  have afterEq := pure_ok h
  simp only [Term.tuple.injEq, List.cons.injEq, true_and, and_true] at afterEq
  subst after
  exact ⟨(write_field_frame written rfl).trans fields.1, (write_field_frame written rfl).trans fields.2⟩

theorem persistable_archive_fields {s snapshot : Term} {j r : List Term}
    (h : Lifecycle.persistable s j = .ok (snapshot, r)) :
    snapshot.get (a "segment_catalog") = s.get (a "segment_catalog") ∧
      snapshot.get (a "archived_through") = s.get (a "archived_through") := by
  rw [put_ok h]
  exact ⟨get_put_other _ _ (by decide), get_put_other _ _ (by decide)⟩

/-- The actual CAS request retains the catalog and watermark in its encoded snapshot. -/
theorem storage_request_archive_fields {s key base request : Term} {j r : List Term}
    (h : StorageCommit.prepare s (.tuple [key, base]) j = .ok (request, r)) :
    ∃ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      request = .tuple [a "cas", key, .binary bytes, base] ∧
      snapshot.get (a "segment_catalog") = s.get (a "segment_catalog") ∧
      snapshot.get (a "archived_through") = s.get (a "archived_through") := by
  obtain ⟨snapshot, bytes, _, persisted, encoded, requestEq, _⟩ := storage_commit_candidate h
  exact ⟨snapshot, bytes, encoded, requestEq, persistable_archive_fields persisted⟩

/-- Logical snapshots stored under the actual object key and returned CAS revision. -/
abbrev HotSnapshots := Term → Term → Term → Prop

/-- A positive CAS observation stores the encoded candidate. It does not certify application invariants. -/
def SnapshotCASMeaning (request result : Term) (durable : HotSnapshots) : Prop :=
  ∀ key base bytes snapshot etag outcome,
    request = .tuple [a "cas", key, .binary bytes, base] →
    ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
    result = .tuple [a "ok", etag, outcome] → durable key etag snapshot

theorem confirmed_archive_snapshot {state prepared stamped key base request result etag : Term}
    {catalog : List Term} {watermark : Int} {metadata : List Term} {durable : HotSnapshots}
    {j r observations rest confirmation remaining : List Term}
    (format : state.get (a "storage_format") = i 3)
    (read : state.get (a "segment_catalog") = list catalog)
    (through : state.get (a "archived_through") = i watermark)
    (valid : ∀ value ∈ catalog, validSegment value = true)
    (prepare : Lifecycle.prepareWrite state j = .ok (.tuple [a "ok", prepared], r))
    (bookkeeping : ResidentBatch prepared metadata stamped)
    (canonical : ∀ event ∈ metadata, BinaryKeys event)
    (metadataOnly : ∀ event ∈ metadata, CommitMetadata event)
    (requested : StorageCommit.prepare stamped (.tuple [key, base]) observations = .ok (request, rest))
    (primitive : SnapshotCASMeaning request result durable)
    (confirmed : StorageCommit.finish stamped result confirmation = .ok (.tuple [a "ok", etag], remaining)) :
    ∃ snapshot, durable key etag snapshot ∧ snapshot.get (a "segment_catalog") = list catalog ∧
      snapshot.get (a "archived_through") = i watermark := by
  have preparedFields := prepareWrite_archive_fields format read through valid prepare
  have stampedFields := metadata_batch_archive_frame bookkeeping canonical metadataOnly
  obtain ⟨snapshot, bytes, encoded, requestEq, catalogEq, watermarkEq⟩ := storage_request_archive_fields requested
  obtain ⟨outcome, resultEq⟩ := storage_commit_confirmation confirmed
  exact ⟨snapshot, primitive key base bytes snapshot etag outcome requestEq encoded resultEq,
    catalogEq.trans (stampedFields.1.trans preparedFields.1),
    watermarkEq.trans (stampedFields.2.1.trans preparedFields.2)⟩

/-- Publication, actual removal, normalization, metadata, encoding, and positive CAS compose for one captured state. -/
theorem published_archive_durable_input
    {state event next prepared stamped key base request result etag : Term}
    {records live : List Term} {archiveBase ceiling line : Int}
    {before after : Objects} {durable : HotSnapshots} {final : Output} {metadata : List Term}
    {j r prepareJournal prepareRest observations rest confirmation remaining : List Term}
    (framing : CodecFraming) (sorted : SeqSorted state)
    (format : state.get (a "storage_format") = i 3)
    (numeric : (state.get (a "archived_through")).default (i 0) = i archiveBase) (nonnegative : archiveBase ≥ 0)
    (initial : StateCatalogBacked before state)
    (catalog : ∀ value ∈ wrap ((state.get (a "segment_catalog")).default (list [])), validSegment value = true)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0)
    (execution : Execution (start state (i line)) before final after)
    (emitted : final.2 = .tuple [a "advance", event])
    (read : state.get (a "messages") = list live)
    (reduced : archiveAdvance state event j = .ok (next, r))
    (prepare : Lifecycle.prepareWrite next prepareJournal = .ok (.tuple [a "ok", prepared], prepareRest))
    (bookkeeping : ResidentBatch prepared metadata stamped)
    (canonical : ∀ event ∈ metadata, BinaryKeys event)
    (metadataOnly : ∀ event ∈ metadata, CommitMetadata event)
    (requested : StorageCommit.prepare stamped (.tuple [key, base]) observations = .ok (request, rest))
    (primitive : SnapshotCASMeaning request result durable)
    (confirmed : StorageCommit.finish stamped result confirmation = .ok (.tuple [a "ok", etag], remaining)) :
    next = state ∨ ∃ (snapshot : Term) (dropped kept : List Term),
      durable key etag snapshot ∧ live = dropped ++ kept ∧ next.get (a "messages") = list kept ∧
      ∀ item record, record ∈ dropped → ValueSemantics.Recorded item record →
        ∃ stored count actual,
          entry stored count ∈ wrap (snapshot.get (a "segment_catalog")) ∧
          after (ArchivePublication.key (state.get (a "agent_id")) (state.get (a "session_id"))
            ((stored.head?.getD nil).get (a "seq"))) stored ∧ actual ∈ stored ∧
          ValueSemantics.Equivalent (queueWorkProjection item)
            ((actual.get (a "data")).get (b "accepted_input")) := by
  rcases published_archive_catalog_input framing sorted numeric nonnegative initial catalog window positive
      execution emitted read reduced with unchanged | ⟨dropped, kept, partition, nextMessages, storedInputs⟩
  · exact Or.inl unchanged
  · rcases archiveAdvance_storage_fields reduced with unchanged | ⟨entries, watermark, permuted, nextCatalog, nextBase, _⟩
    · exact Or.inl unchanged
    · have valid : ∀ value ∈ entries, validSegment value = true := by
        intro value member
        exact (List.mem_filter.mp (permuted.mem_iff.mp member)).2
      have nextFormat := (archiveAdvance_queue_frame reduced).2.2.2.2.trans format
      obtain ⟨snapshot, committed, snapshotCatalog, _⟩ := confirmed_archive_snapshot nextFormat nextCatalog nextBase valid
        prepare bookkeeping canonical metadataOnly requested primitive confirmed
      refine Or.inr ⟨snapshot, dropped, kept, committed, partition, nextMessages, ?_⟩
      intro item record member recorded
      obtain ⟨stored, count, actual, listed, fact, present, same⟩ := storedInputs item record member recorded
      refine ⟨stored, count, actual, ?_, fact, present, same⟩
      rw [snapshotCatalog, ← nextCatalog]
      exact listed

end VerifiedKernel.Session.ArchivePublication
