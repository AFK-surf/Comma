import VerifiedKernelProofs.Session.WorkRecordCodec
import VerifiedKernelProofs.Session.WorkArchiveMatch

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

namespace ArchiveProjection

theorem MessageRecord.kind {record projected : Term} (projection : MessageRecord record projected) :
    projected.get (a "kind") = b "message" := by
  obtain ⟨_, _, _, _, _, _, _, _, _, _, equal⟩ := projection
  rw [equal]
  rfl

theorem MessageRecord.input_fact {item record projected : Term}
    (projection : MessageRecord record projected) (recorded : ValueSemantics.Recorded item record) :
    ValueSemantics.Equivalent (queueWorkProjection item)
      ((projected.get (a "data")).get (b "accepted_input")) := by
  have fact := recorded.input_fact
  obtain ⟨values, actual⟩ := fact.tuple_value
  obtain ⟨before, after, equal, plain, _, afterDifferent⟩ :=
    record_shape_field recorded.wellFormed actual (by intro impossible; cases impossible)
  rw [equal] at projection
  obtain ⟨converted, _, _, _, normalized, field⟩ := projected_atom_field plain
    (by decide) (by decide) afterDifferent projection
  rw [stringifyFuel_tuple_value normalized] at field
  rw [field, ← actual]
  exact fact

end ArchiveProjection

namespace ValueSemantics

/-- A matched landed message retains the full accepted input, not just its dedupe identity. -/
theorem matched_archive_input_fact {item record projected : Term} {landed window : List Term}
    (projection : ArchiveProjection.MessageRecord record projected)
    (recorded : Recorded item record)
    (member : projected ∈ window.take landed.length)
    (same : Equivalent (list (landed.map ArchiveMatch.canonical))
      (list ((window.take landed.length).map ArchiveMatch.canonical))) :
    ∃ stored ∈ landed, Equivalent (queueWorkProjection item)
      ((stored.get (a "data")).get (b "accepted_input")) := by
  obtain ⟨stored, present, equivalent⟩ := archive_match_message_fact same member projection.kind
  exact ⟨stored, present, (projection.input_fact recorded).trans
    ((equivalent.get (a "data")).get (b "accepted_input"))⟩

/-- The actual reachable archive window supplies the message witness used by adoption. -/
theorem reachable_archive_input_candidate {s ceiling item record : Term} {records j r : List Term}
    (reachable : HistoryReachable s) (present : ContainsRecord s record) (recorded : Recorded item record)
    (h : StorageQuery.archiveWindow s j = .ok (.tuple [a "ok", list records, ceiling], r)) :
    ∃ projected ∈ records, ArchiveProjection.MessageRecord record projected ∧
      Equivalent (queueWorkProjection item) ((projected.get (a "data")).get (b "accepted_input")) := by
  obtain ⟨messages, read, member⟩ := present
  obtain ⟨projected, included, projection⟩ :=
    ArchiveProjection.archiveWindow_messages reachable.sequence.1 read member h
  exact ⟨projected, included, projection, projection.input_fact recorded⟩

end ValueSemantics
end VerifiedKernel.Session.WorkConservation
