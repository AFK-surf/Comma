import VerifiedKernelProofs.Session.WorkPhysicalHistory
import VerifiedKernelProofs.Session.WorkArchiveFence
import VerifiedKernelProofs.Session.WorkPhysicalTransport

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

/-- Actual publication and the complete resident archive batch determine the removed prefix. -/
theorem PhysicalHistory.publish_resident {framing : CodecFraming} {objects nextObjects : Objects}
    {owner session : ByteArray} {state event next : Term} {sealed records : List Term}
    {ceiling line : Int} {final : Output}
    (history : PhysicalHistory framing objects owner session state sealed)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0) (publication : Execution (start state (i line)) objects final nextObjects)
    (emitted : final.2 = .tuple [a "advance", event]) (applied : ResidentBatch state [event] next) :
    ∃ dropped kept,
      state.get (a "messages") = list (dropped ++ kept) ∧ next.get (a "messages") = list kept ∧
      PhysicalHistory framing nextObjects owner session next (sealed ++ dropped) ∧
      ∀ item, ValueSemantics.Represented state sealed item → ValueSemantics.Represented next (sealed ++ dropped) item := by
  obtain ⟨live, _, read, _, _, _⟩ := history.invariant.history.invariant.sorted
  obtain ⟨_, _, _, _, shape, _⟩ := publication_catalog_backed history.invariant.catalog publication emitted
  have canonical : BinaryKeys event := by rw [shape]; rfl
  have kind : event.get (b "type") = b "archive_advance" := by rw [shape]; rfl
  rcases resident_archive_call canonical kind applied with unchanged | ⟨middle, journal, rest, reduced, frame⟩
  · refine ⟨[], live, read, (unchanged "messages" (by decide) (by decide)).trans read, ?_, ?_⟩
    · simpa only [List.append_nil] using (history.objects (execution_objects_extend publication)).activity unchanged
    · intro item represented
      simpa only [List.append_nil] using
        ValueSemantics.work_fields_preserves (activity_frame_work unchanged) represented
  · obtain ⟨dropped, kept, partition, after, _⟩ :=
      archiveAdvance_executed_prefix history.invariant.history.invariant.sorted read reduced
    have middleHistory := history.publication window positive publication emitted reduced read partition after
    refine ⟨dropped, kept, ?_, (frame "messages" (by decide) (by decide)).trans after,
      middleHistory.activity frame, ?_⟩
    · rw [← partition]
      exact read
    · intro item represented
      exact ValueSemantics.work_fields_preserves (activity_frame_work frame)
        (ValueSemantics.archive_represents (archive_preserves_queue reduced) read partition after represented)

theorem PhysicalHistory.publish_resident_catalog {framing : CodecFraming} {objects nextObjects : Objects}
    {owner session : ByteArray} {state event next : Term} {sealed records : List Term}
    {ceiling line : Int} {final : Output}
    (history : PhysicalHistory framing objects owner session state sealed)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0) (publication : Execution (start state (i line)) objects final nextObjects)
    (emitted : final.2 = .tuple [a "advance", event]) (applied : ResidentBatch state [event] next) :
    ∀ value ∈ wrap ((state.get (a "segment_catalog")).default (list [])),
      value ∈ wrap ((next.get (a "segment_catalog")).default (list [])) := by
  obtain ⟨_, _, _, _, shape, _⟩ := publication_catalog_backed history.invariant.catalog publication emitted
  have canonical : BinaryKeys event := by rw [shape]; rfl
  have kind : event.get (b "type") = b "archive_advance" := by rw [shape]; rfl
  intro value member
  rcases resident_archive_call canonical kind applied with unchanged | ⟨middle, journal, rest, reduced, frame⟩
  · simpa only [unchanged "segment_catalog" (by decide) (by decide)] using member
  · obtain ⟨catalog, watermark, read, through, valid⟩ := history.invariant.archive
    obtain ⟨base, baseRead, nonnegative⟩ := history.invariant.nonnegative
    have numeric : (state.get (a "archived_through")).default (i 0) = i base := by
      rw [baseRead]; exact default_integer _ _
    have catalogValid : ∀ entry ∈ wrap ((state.get (a "segment_catalog")).default (list [])),
        validSegment entry = true := by
      simpa only [read, list, default_list, wrap] using valid
    have exactFilter := publication_catalog_filter_exact framing numeric nonnegative history.invariant.catalog
      catalogValid window positive publication emitted
    rcases archiveAdvance_keeps_published_catalog exactFilter reduced with same | included
    · subst middle
      simpa only [frame "segment_catalog" (by decide) (by decide)] using member
    · have retained := included value (publication_keeps_catalog publication emitted value member)
      obtain ⟨entries, _, catalogRead, _, _⟩ := history.invariant.archive.advance reduced
      rw [frame "segment_catalog" (by decide) (by decide), catalogRead]
      change value ∈ entries
      simpa only [catalogRead, list, wrap] using retained

/-- This covers every existing catalog witness, not only the records named by `sealed`. -/
theorem PhysicalHistory.publish_resident_physical {framing : CodecFraming} {objects nextObjects : Objects}
    {owner session : ByteArray} {state event next : Term} {sealed records : List Term}
    {ceiling line : Int} {final : Output}
    (history : PhysicalHistory framing objects owner session state sealed)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0) (publication : Execution (start state (i line)) objects final nextObjects)
    (emitted : final.2 = .tuple [a "advance", event]) (applied : ResidentBatch state [event] next) :
    ∀ item, PhysicalIdentityFact objects state (.work item) → PhysicalIdentityFact nextObjects next (.work item) := by
  obtain ⟨_, _, _, _, nextHistory, kept⟩ := history.publish_resident window positive publication emitted applied
  apply physical_work_transport (execution_objects_extend publication)
    (nextHistory.invariant.owned.trans history.invariant.owned.symm)
    (nextHistory.invariant.identified.trans history.invariant.identified.symm)
    (history.publish_resident_catalog window positive publication emitted applied)
  exact fun item present => identity_fact_physical nextHistory.invariant.images
    (kept item (ValueSemantics.live_represents present))

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.PendingRevision
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem archive_write_physical_history {framing : CodecFraming} {objects nextObjects : Objects}
    {owner session : ByteArray} {cursor next : Cursor} {event : Term} {sealed records : List Term}
    {ceiling line : Int} {final : Output}
    (history : PhysicalHistory framing objects owner session cursor.working sealed)
    (window : StorageQuery.archiveWindow cursor.working [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0) (publication : ArchivePublication.Execution (start cursor.working (i line)) objects final nextObjects)
    (emitted : final.2 = .tuple [a "advance", event])
    (written : Execution (resident (some cursor.pack) (a "write") (.tuple [list [event], nil])) next) :
    next.baseline = cursor.baseline ∧ next.etag = cursor.etag ∧ ∃ dropped,
      PhysicalHistory framing nextObjects owner session next.working (sealed ++ dropped) ∧
      (∀ item, ValueSemantics.Represented cursor.working sealed item →
        ValueSemantics.Represented next.working (sealed ++ dropped) item) ∧
      ∀ item, ValueSemantics.Represented cursor.working sealed item →
        PhysicalIdentityFact nextObjects next.working (.work item) := by
  obtain ⟨_, _, baselineEq, etagEq, _, _, applied⟩ := write_executes written
  change ResidentBatch cursor.working [event] next.working at applied
  obtain ⟨dropped, _, _, _, nextHistory, kept⟩ := history.publish_resident window positive publication emitted applied
  exact ⟨baselineEq, etagEq, dropped, nextHistory, kept,
    fun item represented => identity_fact_physical nextHistory.invariant.images (kept item represented)⟩

end VerifiedKernel.Session.PendingRevision
