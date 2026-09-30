import VerifiedKernelProofs.Session.WorkEncoding
import VerifiedKernelProofs.Session.WorkEnqueue
import VerifiedKernelProofs.Session.WorkCompaction
import VerifiedKernelProofs.Session.WorkAllocation
import VerifiedKernelProofs.Session.AppendOnly.Sorted

namespace VerifiedKernel.Session.WorkConservation
open Data

/-- Retry bookkeeping may change, but a queued input keeps these work-bearing fields. -/
def QueueWork (original current : Term) : Prop :=
  current.get (b "queue_id") = original.get (b "queue_id") ∧
  current.get (b "kind") = original.get (b "kind") ∧
  current.get (b "dedupe_key") = original.get (b "dedupe_key") ∧
  current.get (b "payload") = original.get (b "payload")

def queueWorkProjection (item : Term) : Term :=
  .tuple [item.get (b "queue_id"), item.get (b "kind"), item.get (b "dedupe_key"), item.get (b "payload")]

theorem queueWork_projection {original current : Term} :
    QueueWork original current ↔ queueWorkProjection current = queueWorkProjection original := by
  simp only [QueueWork, queueWorkProjection, Term.tuple.injEq, List.cons.injEq, and_true]

/-- Representation in concrete queue items, concrete transcript records, or sealed records. -/
def ConcreteRepresented (state : Term) (sealed : List Term) (item : Term) : Prop :=
  (∃ queue current, state.get (a "input_queue") = list queue ∧
    current ∈ queue ∧ QueueWork item current) ∨
  (∃ record, ContainsRecord state record ∧ QueuedRecord item record) ∨
  (∃ record ∈ sealed, QueuedRecord item record)

theorem concrete_representation_frame {s t item : Term} {sealed : List Term}
    (fields : WorkFieldsPreserved s t) :
    ConcreteRepresented s sealed item ↔ ConcreteRepresented t sealed item := by
  simp only [ConcreteRepresented, ContainsRecord, fields.1, fields.2]

theorem queued_record_same_work {original current record : Term}
    (same : QueueWork original current) :
    QueuedRecord original record ↔ QueuedRecord current record := by
  simp only [QueuedRecord, StateQuery.acceptedInput, same.1, same.2.1, same.2.2.1, same.2.2.2]

theorem modern_microcompact_representation {s e t item : Term} {sealed j r : List Term} {format : Int}
    (read : s.get (a "storage_format") = i format) (modern : 2 ≤ format)
    (h : microcompact s e j = .ok (t, r)) :
    ConcreteRepresented s sealed item ↔ ConcreteRepresented t sealed item :=
  concrete_representation_frame (microcompact_modern_work_fields read modern h)

/-- A selected record represents the original work even after queue retry bookkeeping changes. -/
theorem generated_represents_work {s original current session event record : Term}
    {sealed : List Term} (same : QueueWork original current)
    (generated : Generated session current event) (fields : InputRecordFields event record)
    (present : ContainsRecord s record) : ConcreteRepresented s sealed original :=
  Or.inr (Or.inl ⟨record, present,
    (queued_record_same_work same).mpr (generated_record_payload generated fields)⟩)

/-- The archive primitive seals the removed records before the reducer removes the live prefix.
The storage premise names exact records, not an assumed preservation conclusion. -/
theorem archive_representation {s t item : Term} {live sealed dropped kept : List Term}
    (queue : QueuePreserved s t)
    (before : s.get (a "messages") = list live)
    (partition : live = dropped ++ kept)
    (after : t.get (a "messages") = list kept)
    (represented : ConcreteRepresented s sealed item) :
    ConcreteRepresented t (sealed ++ dropped) item := by
  rcases represented with pending | recorded | archived
  · obtain ⟨items, current, read, member, same⟩ := pending
    exact Or.inl ⟨items, current, queue.trans read, member, same⟩
  · obtain ⟨record, ⟨messages, read, member⟩, fields⟩ := recorded
    have equal : messages = live := Term.list.inj (read.symm.trans before)
    rw [equal, partition] at member
    rcases List.mem_append.mp member with removed | retained
    · exact Or.inr (Or.inr ⟨record, List.mem_append_right _ removed, fields⟩)
    · exact Or.inr (Or.inl ⟨record, ⟨kept, after, retained⟩, fields⟩)
  · obtain ⟨record, member, fields⟩ := archived
    exact Or.inr (Or.inr ⟨record, List.mem_append_left _ member, fields⟩)

/-- Actual archive reduction determines the exact prefix that the storage primitive must seal. -/
theorem archiveAdvance_representation {s e t : Term} {live sealed j r : List Term}
    (inv : SeqSorted s) (read : s.get (a "messages") = list live)
    (plain : ∀ record ∈ live, (record.isMap && !record.has (a "__struct__")) = true)
    (h : archiveAdvance s e j = .ok (t, r)) :
    ∃ dropped kept, live = dropped ++ kept ∧ t.get (a "messages") = list kept ∧
      ∀ item, ConcreteRepresented s sealed item → ConcreteRepresented t (sealed ++ dropped) item := by
  obtain ⟨dropped, kept, partition, after, _⟩ := archiveAdvance_prefix inv read plain h
  exact ⟨dropped, kept, partition, after,
    fun _ represented => archive_representation (archive_preserves_queue h) read partition after represented⟩

end VerifiedKernel.Session.WorkConservation
