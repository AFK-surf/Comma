import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernelProofs.Session.WorkArchiveProjection

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem activity_frame_seq {s t : Term} (frame : ActivityFrame s t) : SeqStep s t :=
  seq_of_frame (frame "messages" (by decide) (by decide))
    (frame "last_seq" (by decide) (by decide))

theorem resident_step_seq {s event t : Term} (step : ResidentStep s event t) : SeqStep s t := by
  obtain ⟨reduced, normalized, j, r, prepared, activity⟩ := step
  cases normalized with
  | none =>
    rw [prepareTrusted_none prepared] at activity
    exact activity_frame_seq activity
  | some normalized =>
    obtain ⟨_, _, _, call⟩ := prepareTrusted_stringify prepared
    exact seq_trans (inner_seq call) (activity_frame_seq activity)

theorem resident_batch_seq {s t : Term} {events : List Term} (execution : ResidentBatch s events t) : SeqStep s t := by
  induction execution with
  | nil => exact seq_refl _
  | cons first rest ih => exact seq_trans (resident_step_seq (resident_execution_step first)) ih

namespace ValueSemantics

theorem Equivalent.seqValues {xs ys : List Term} (same : Equivalent (Data.list xs) (Data.list ys)) :
    xs.map seqOf = ys.map seqOf := by
  obtain ⟨other, equal, length, related⟩ := same.list
  have equal := Term.list.inj equal
  subst other
  apply List.ext_getElem
  · simpa using length
  · intro index leftBound rightBound
    simp only [List.length_map] at leftBound rightBound
    simp only [List.getElem_map]
    have value := related index
    simp only [List.getElem?_eq_getElem leftBound, List.getElem?_eq_getElem rightBound,
      Option.getD_some] at value
    exact (value.get (a "seq")).integerValue

theorem Equivalent.seqSorted {s t : Term} (same : Equivalent s t) (sorted : SeqSorted s) : SeqSorted t := by
  obtain ⟨messages, ceiling, read, last, stamped, ordered⟩ := sorted
  have values := same.get (a "messages")
  rw [read] at values
  obtain ⟨next, nextRead, length, related⟩ := values.list
  have lastValue := (same.get (a "last_seq")).default (Equivalent.refl (i 0))
  change Equivalent (lastSeq s) (lastSeq t) at lastValue
  rw [last] at lastValue
  refine ⟨next, ceiling, nextRead, lastValue.integer, ?_, ?_⟩
  · intro message member
    have reverse : Equivalent (Data.list next) (Data.list messages) := by
      rw [nextRead] at values
      exact values.symm
    obtain ⟨other, otherRead, count, entries⟩ := reverse.list
    have equal := Term.list.inj otherRead
    subst other
    obtain ⟨original, originalMember, equivalent⟩ := list_member count entries member
    obtain ⟨stamp, stampRead, bound⟩ := stamped original originalMember
    have field := equivalent.symm.get (a "seq")
    rw [stampRead] at field
    exact ⟨stamp, field.integer, bound⟩
  · have order : (messages.map seqOf).Pairwise (· ≤ ·) := List.pairwise_map.mpr ordered
    have mapped : messages.map seqOf = next.map seqOf := by
      rw [nextRead] at values
      exact values.seqValues
    rw [mapped] at order
    exact List.pairwise_map.mp order

end ValueSemantics
end VerifiedKernel.Session.WorkConservation
