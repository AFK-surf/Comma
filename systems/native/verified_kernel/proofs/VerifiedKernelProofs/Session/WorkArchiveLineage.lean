import VerifiedKernelProofs.Session.WorkArchiveIdentity

namespace VerifiedKernel.Session.ArchivePublication
open Data WorkConservation
set_option Elab.async false

def CatalogLineage (catalog : List Term) (output : Output) : Prop :=
  (∀ cursor, output.1 = some cursor → cursor.catalog = catalog) ∧
  ∀ event, output.2 = .tuple [a "advance", event] →
    ∀ value ∈ catalog, value ∈ wrap (event.get (b "segments"))

theorem failed_catalog_lineage (catalog : List Term) (reason : Term) : CatalogLineage catalog (failed reason) := by
  simp [CatalogLineage, failed, a]

theorem complete_catalog_lineage (cursor : Cursor) : CatalogLineage cursor.catalog (complete cursor) := by
  unfold complete
  split
  · simp [CatalogLineage, a]
  · constructor
    · simp
    · intro event same value member
      have equal : event = .map [(b "type", b "archive_advance"), (b "session_id", cursor.session),
        (b "archived_through", (wrap (cursor.entries.head?.getD nil))[1]?.getD nil),
        (b "segments", list (cursor.catalog ++ cursor.entries.reverse))] := by
        rename_i last earlier entries
        simp only [entries, List.head?_cons, Option.getD_some]
        simpa only [entries, Term.tuple.injEq, List.cons.injEq, and_true, true_and] using same.symm
      rw [equal]
      exact List.mem_append_left _ member

theorem proceed_catalog_lineage (cursor : Cursor) : CatalogLineage cursor.catalog (proceed cursor) := by
  unfold proceed
  split
  · exact complete_catalog_lineage cursor
  · split
    · exact complete_catalog_lineage cursor
    · simp [CatalogLineage, objectRequest, a]

theorem advance_catalog_lineage (cursor : Cursor) (records : List Term) (catalogEntry : Term) :
    CatalogLineage cursor.catalog (advance cursor records catalogEntry) := proceed_catalog_lineage _

theorem propose_catalog_lineage (cursor : Cursor) : CatalogLineage cursor.catalog (propose cursor) := by
  unfold propose
  split
  · exact failed_catalog_lineage _ _
  · exact complete_catalog_lineage _
  · split
    · exact failed_catalog_lineage _ _
    · simp [CatalogLineage, objectRequest, a]

theorem compare_catalog_lineage (cursor : Cursor) (records : List Term) :
    CatalogLineage cursor.catalog (compare cursor records) := by
  unfold compare
  split
  · exact failed_catalog_lineage _ _
  · simp [CatalogLineage, ArchiveMatch.request, a]

theorem resume_catalog_lineage (cursor : Cursor) (result : Term) :
    CatalogLineage cursor.catalog (resume cursor result) := by
  unfold resume
  repeat' first
    | exact advance_catalog_lineage _ _ _
    | exact propose_catalog_lineage _
    | exact compare_catalog_lineage _ _
    | exact failed_catalog_lineage _ _
    | dsimp only
    | split

theorem start_catalog_lineage (state args : Term) :
    CatalogLineage (wrap ((state.get (a "segment_catalog")).default (list []))) (start state args) := by
  unfold start
  repeat' first
    | exact proceed_catalog_lineage _
    | exact failed_catalog_lineage _ _
    | split

theorem execution_catalog_lineage {initial final : Output} {before after : Objects} {catalog : List Term}
    (execution : Execution initial before final after) (lineage : CatalogLineage catalog initial) :
    CatalogLineage catalog final := by
  induction execution with
  | done => exact lineage
  | @step cursor request result before middle after final primitive tail ih =>
    apply ih
    rw [← lineage.1 cursor rfl]
    exact resume_catalog_lineage cursor result

theorem execution_objects_extend {initial final : Output} {before after : Objects}
    (execution : Execution initial before final after) : ObjectsExtend before after := by
  induction execution with
  | done => exact fun _ _ stored => stored
  | step primitive tail ih => exact fun _ _ stored => ih _ _ (primitive.1 _ _ stored)

theorem publication_keeps_catalog {state args event : Term} {final : Output} {before after : Objects}
    (execution : Execution (start state args) before final after)
    (emitted : final.2 = .tuple [a "advance", event]) :
    ∀ value ∈ wrap ((state.get (a "segment_catalog")).default (list [])),
      value ∈ wrap (event.get (b "segments")) :=
  (execution_catalog_lineage execution (start_catalog_lineage state args)).2 event emitted

def SealedImagesBacked (objects : Objects) (state : Term) (sealed : List Term) : Prop :=
  ∀ record ∈ sealed, RecordImageBacked objects (state.get (a "agent_id")) (state.get (a "session_id"))
    (wrap ((state.get (a "segment_catalog")).default (list []))) record

theorem SealedImagesBacked.mono {before after : Objects} {state : Term} {sealed : List Term}
    (extension : ObjectsExtend before after) (backed : SealedImagesBacked before state sealed) :
    SealedImagesBacked after state sealed := by
  intro record member
  obtain ⟨projected, projection, stored⟩ := backed record member
  exact ⟨projected, projection, stored.mono extension⟩

theorem published_archive_sealed_images {state event next : Term} {records live sealed : List Term}
    {base ceiling line : Int} {before after : Objects} {final : Output} {journal rest : List Term}
    (framing : CodecFraming) (sorted : SeqSorted state)
    (numeric : (state.get (a "archived_through")).default (i 0) = i base) (nonnegative : base ≥ 0)
    (initial : StateCatalogBacked before state)
    (catalog : ∀ value ∈ wrap ((state.get (a "segment_catalog")).default (list [])), validSegment value = true)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0) (execution : Execution (start state (i line)) before final after)
    (emitted : final.2 = .tuple [a "advance", event])
    (read : state.get (a "messages") = list live)
    (supported : LedgerSupported state sealed) (backed : SealedImagesBacked before state sealed)
    (reduced : archiveAdvance state event journal = .ok (next, rest)) :
    ∃ (dropped kept : List Term), live = dropped ++ kept ∧ next.get (a "messages") = list kept ∧
      LedgerSupported next (sealed ++ dropped) ∧ SealedImagesBacked after next (sealed ++ dropped) := by
  have oldBacked := backed.mono (execution_objects_extend execution)
  have unchanged (same : next = state) :
      ∃ (dropped kept : List Term), live = dropped ++ kept ∧ next.get (a "messages") = list kept ∧
        LedgerSupported next (sealed ++ dropped) ∧ SealedImagesBacked after next (sealed ++ dropped) := by
    subst next
    exact ⟨[], live, rfl, read, by simpa using supported, by simpa using oldBacked⟩
  rcases archiveAdvance_storage_fields reduced with same | ⟨entries, watermark, permuted, nextCatalog, nextBase, agent, session⟩
  · exact unchanged same
  have exactFilter := publication_catalog_filter_exact framing numeric nonnegative initial catalog window positive execution emitted
  rcases archiveAdvance_keeps_published_catalog exactFilter reduced with same | included
  · exact unchanged same
  rcases published_archive_ledger_supported framing sorted numeric nonnegative initial catalog window positive
      execution emitted read supported reduced with same | ⟨dropped, kept, partition, nextRead, nextSupport, images⟩
  · exact unchanged same
  refine ⟨dropped, kept, partition, nextRead, nextSupport, ?_⟩
  intro record member
  change RecordImageBacked after _ _ _ record
  rw [agent, session, nextCatalog]
  change RecordImageBacked after _ _ entries record
  rcases List.mem_append.mp member with old | removed
  · obtain ⟨projected, projection, stored⟩ := oldBacked record old
    refine ⟨projected, projection, stored.catalog_mono ?_⟩
    intro value member
    have kept := included value (publication_keeps_catalog execution emitted value member)
    rwa [nextCatalog] at kept
  · have image := images record removed
    rwa [nextCatalog] at image

end VerifiedKernel.Session.ArchivePublication
