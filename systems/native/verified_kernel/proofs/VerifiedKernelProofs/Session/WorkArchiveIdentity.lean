import VerifiedKernelProofs.Session.WorkIdentityFence
import VerifiedKernelProofs.Session.WorkArchiveFence

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem identity_fact_archive {state next : Term} {live sealed dropped kept : List Term} {fact : IdentityFact}
    (queue : QueuePreserved state next) (before : state.get (a "messages") = list live)
    (partition : live = dropped ++ kept) (after : next.get (a "messages") = list kept)
    (present : IdentityFactPresent state sealed fact) : IdentityFactPresent next (sealed ++ dropped) fact := by
  cases fact with
  | work item => exact ValueSemantics.archive_represents queue before partition after present
  | record reference =>
    obtain ⟨record, stored, same⟩ := present
    refine ⟨record, ?_, same⟩
    rcases stored with ⟨messages, read, member⟩ | archived
    · have equal : messages = live := Term.list.inj (read.symm.trans before)
      rw [equal, partition] at member
      rcases List.mem_append.mp member with removed | retained
      · exact Or.inr (List.mem_append_right _ removed)
      · exact Or.inl ⟨kept, after, retained⟩
    · exact Or.inr (List.mem_append_left _ archived)

theorem archive_ledger_supported {state event next : Term} {live sealed dropped kept journal rest : List Term}
    (before : state.get (a "messages") = list live) (partition : live = dropped ++ kept)
    (after : next.get (a "messages") = list kept)
    (supported : LedgerSupported state sealed)
    (call : archiveAdvance state event journal = .ok (next, rest)) : LedgerSupported next (sealed ++ dropped) := by
  have ledger : LedgerFrame state next := by
    unfold archiveAdvance at call
    ledger_frame_walk call
  intro source present
  rw [ledger] at present
  obtain ⟨originInput, fact, origin, stored⟩ := supported source present
  exact ⟨originInput, fact, origin,
    identity_fact_archive (archive_preserves_queue call) before partition after stored⟩

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.ArchivePublication
open Data WorkConservation
set_option Elab.async false

def RecordImageBacked (objects : Objects) (agent session : Term) (catalog : List Term) (record : Term) : Prop :=
  ∃ projected, ArchiveProjection.MessageRecord record projected ∧ CatalogMessage objects agent session catalog projected

theorem RecordImageBacked.binary_field {objects : Objects} {agent session : Term} {catalog : List Term}
    {before after : List (String × Term)} {field : String} {value : ByteArray}
    (plain : ∀ pair ∈ before ++ (field, Term.binary value) :: after, pair.1 ≠ "__struct__")
    (notSeq : field ≠ "seq") (notNil : field ≠ "nil")
    (different : ∀ pair ∈ after, pair.1 ≠ field ∧ pair.1 ≠ "nil")
    (backed : RecordImageBacked objects agent session catalog
      (ArchiveProjection.atomFields (before ++ (field, Term.binary value) :: after))) :
    ∃ records count actual,
      entry records count ∈ catalog ∧
      objects (key agent session ((records.head?.getD nil).get (a "seq"))) records ∧ actual ∈ records ∧
      (actual.get (a "data")).get (b field) = .binary value := by
  obtain ⟨projected, projection, records, count, actual, listed, stored, member, same⟩ := backed
  have selected := ArchiveProjection.projected_binary_field plain notSeq notNil different projection
  have fieldSame := (same.get (a "data")).get (b field)
  rw [selected] at fieldSame
  exact ⟨records, count, actual, listed, stored, member, fieldSame.binary⟩

theorem published_archive_ledger_supported {state event next : Term} {records live sealed : List Term}
    {base ceiling line : Int} {before after : Objects} {final : Output} {journal rest : List Term}
    (framing : CodecFraming) (sorted : SeqSorted state)
    (numeric : (state.get (a "archived_through")).default (i 0) = i base) (nonnegative : base ≥ 0)
    (initial : StateCatalogBacked before state)
    (catalog : ∀ value ∈ wrap ((state.get (a "segment_catalog")).default (list [])), validSegment value = true)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0) (execution : Execution (start state (i line)) before final after)
    (emitted : final.2 = .tuple [a "advance", event])
    (read : state.get (a "messages") = list live)
    (supported : LedgerSupported state sealed)
    (reduced : archiveAdvance state event journal = .ok (next, rest)) :
    next = state ∨ ∃ (dropped kept : List Term),
      live = dropped ++ kept ∧ next.get (a "messages") = list kept ∧
      LedgerSupported next (sealed ++ dropped) ∧
      ∀ record ∈ dropped, RecordImageBacked after (state.get (a "agent_id")) (state.get (a "session_id"))
        (wrap (next.get (a "segment_catalog"))) record := by
  have exactFilter := publication_catalog_filter_exact framing numeric nonnegative initial catalog window positive execution emitted
  rcases archiveAdvance_keeps_published_catalog exactFilter reduced with unchanged | included
  · exact Or.inl unchanged
  · obtain ⟨dropped, kept, partition, nextRead, projections⟩ :=
      published_archive_removed_projections sorted numeric nonnegative initial window positive execution emitted read reduced
    refine Or.inr ⟨dropped, kept, partition, nextRead,
      archive_ledger_supported read partition nextRead supported reduced, ?_⟩
    intro record member
    obtain ⟨projected, projection, backed⟩ := projections record member
    exact ⟨projected, projection, backed.catalog_mono included⟩

end VerifiedKernel.Session.ArchivePublication
