import VerifiedKernelProofs.Session.WorkReady
import VerifiedKernelProofs.Proof.ValueSemantics

namespace VerifiedKernel.Session.WorkConservation
open Data
namespace ValueSemantics
set_option Elab.async false

theorem Equivalent.binaryKeys {left right : Term} (same : Equivalent left right) : BinaryKeys left ↔ BinaryKeys right := by
  have root := same.shape
  cases left <;> cases right <;> simp_all [ValueSemantics.shape, BinaryKeys]

theorem Equivalent.queueId {left right : Term} (same : Equivalent left right) : queueId left = queueId right :=
  ((same.get (b "queue_id")).default (same.get (a "queue_id"))).integerValue

theorem Equivalent.canonical {left right : Term} (same : Equivalent left right)
    (canonical : CanonicalQueueItem left) : CanonicalQueueItem right := by
  have map := same.isMap.symm.trans (canonical_item_map canonical)
  obtain ⟨fields, source, keys, positive⟩ := canonical
  have binary : BinaryKeys left := by rw [source]; exact keys
  have nextKeys := same.binaryKeys.mp binary
  cases right with
  | map entries => exact ⟨entries, rfl, nextKeys, same.queueId ▸ positive⟩
  | _ => cases map

theorem list_member {left right : List Term} (length : left.length = right.length)
    (same : ∀ index : Nat, Equivalent (left[index]?.getD nil) (right[index]?.getD nil))
    {item : Term} (member : item ∈ left) : ∃ next ∈ right, Equivalent item next := by
  obtain ⟨index, bound, atIndex⟩ := List.mem_iff_getElem.mp member
  have nextBound : index < right.length := by omega
  refine ⟨right[index], List.getElem_mem nextBound, ?_⟩
  simpa only [List.getElem?_eq_getElem bound, List.getElem?_eq_getElem nextBound, Option.getD_some, atIndex] using same index

theorem list_queue_ids {left right : List Term} (length : left.length = right.length)
    (same : ∀ index : Nat, Equivalent (left[index]?.getD nil) (right[index]?.getD nil)) :
    left.map queueId = right.map queueId := by
  apply List.ext_getElem
  · simp [length]
  · intro index leftBound rightBound
    have first : index < left.length := by simpa using leftBound
    have second : index < right.length := by simpa using rightBound
    have value := (same index).queueId
    simpa only [List.getElem_map, List.getElem?_eq_getElem first, List.getElem?_eq_getElem second, Option.getD_some] using value

theorem Equivalent.ready {s t : Term} (same : Equivalent s t) (ready : QueueReady s) : QueueReady t := by
  obtain ⟨⟨items, next, read, nextRead, positive, canonical, bounded, unique⟩,
    ⟨original, ack, originalRead, ackRead, above⟩, bound⟩ := ready
  have identical : original = items := Term.list.inj (originalRead.symm.trans read)
  subst original
  have queue := same.get (a "input_queue")
  rw [read] at queue
  obtain ⟨kept, keptRead, length, values⟩ := queue.list
  have allocator : t.get (a "next_queue_id") = i next := by
    have related := same.get (a "next_queue_id")
    rw [nextRead] at related
    exact related.integer
  have watermark : t.get (a "queue_ack_id") = i ack := by
    have related := same.get (a "queue_ack_id")
    rw [ackRead] at related
    exact related.integer
  have reverse : ∀ index : Nat, Equivalent (kept[index]?.getD nil) (items[index]?.getD nil) := fun index => (values index).symm
  have keptCanonical : ∀ item ∈ kept, CanonicalQueueItem item := by
    intro item member
    obtain ⟨before, present, related⟩ := list_member length.symm reverse member
    exact related.symm.canonical (canonical before present)
  have ids := list_queue_ids length values
  refine ⟨⟨kept, next, keptRead, allocator, positive, keptCanonical, ?_, ids ▸ unique⟩,
    ⟨kept, ack, keptRead, watermark, ?_⟩, ?_⟩
  · intro item member
    obtain ⟨before, present, related⟩ := list_member length.symm reverse member
    rw [related.queueId]
    exact bounded before present
  · intro item member
    obtain ⟨before, present, related⟩ := list_member length.symm reverse member
    rw [related.queueId]
    exact above before present
  · simpa only [allocator, watermark, nextRead, ackRead] using bound

end ValueSemantics
end VerifiedKernel.Session.WorkConservation
