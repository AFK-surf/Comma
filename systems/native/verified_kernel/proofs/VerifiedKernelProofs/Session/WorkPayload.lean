import VerifiedKernelProofs.Session.WorkApplication
import VerifiedKernelProofs.Session.WorkRecordShape

namespace VerifiedKernel.Session.WorkConservation
open Data StateQuery
set_option maxHeartbeats 4000000
set_option Elab.async false

/-- Input identity and content in a delivery record use the event's exact values. -/
def DeliveryFields (event record : Term) : Prop :=
  record.get (a "id") = event.get (b "message_id") ∧
  record.get (a "source_message_id") = event.get (b "source_message_id") ∧
  record.get (a "dedupe_key") = event.get (b "dedupe_key") ∧
  record.get (a "content") = event.get (b "content") ∧
  record.get (a "accepted_input") = event.get (b "accepted_input") ∧ RecordShape.WellFormed record

theorem delivery_fields_stamped {e message seq : Term} (fields : DeliveryFields e message) :
    DeliveryFields e (message.put (a "seq") seq) := by
  obtain ⟨id, source, dedupe, content, fact, shape⟩ := fields
  have nextShape := shape.put (by simp +decide [RecordShape.SafeName] : RecordShape.SafeName "seq") seq
  simpa only [DeliveryFields, get_put_other _ _ (by decide : "seq" ≠ "id"),
    get_put_other _ _ (by decide : "seq" ≠ "source_message_id"),
    get_put_other _ _ (by decide : "seq" ≠ "dedupe_key"),
    get_put_other _ _ (by decide : "seq" ≠ "content"),
    get_put_other _ _ (by decide : "seq" ≠ "accepted_input")] using
      (show message.get (a "id") = e.get (b "message_id") ∧
        message.get (a "source_message_id") = e.get (b "source_message_id") ∧
        message.get (a "dedupe_key") = e.get (b "dedupe_key") ∧
        message.get (a "content") = e.get (b "content") ∧
        message.get (a "accepted_input") = e.get (b "accepted_input") ∧
        RecordShape.WellFormed (message.put (a "seq") seq) from
          ⟨id, source, dedupe, content, fact, nextShape⟩)

theorem delivery_stores_fields {s e t : Term} {j r : List Term}
    (queued : e.get (b "from_queue") = a "true")
    (h : transcriptDelivery s e j = .ok (t, r)) :
    ∃ record, RecordWitness e record ∧ ContainsRecord t record ∧ DeliveryFields e record := by
  unfold transcriptDelivery at h
  simp only [queued, bne, atom_beq_self, Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h
  iterate 11
    replace h := bind_ok h
    obtain ⟨value, _, hx, h⟩ := h
    have eq := (access_ok hx).1
    subst value
  replace h := bind_ok h
  obtain ⟨trace, _, ht, h⟩ := h
  replace h := bind_ok h
  obtain ⟨merged, _, hm, h⟩ := h
  replace h := bind_ok h
  obtain ⟨appended, _, ha, h⟩ := h
  obtain ⟨xs, seq, before, read⟩ := appendFields_stores ha
  refine ⟨(present merged).put (a "seq") seq,
    ⟨s, appended, present merged, _, _, seq, ha, ⟨xs, before, read⟩, rfl⟩,
    ?_, delivery_fields_stamped ?_⟩
  · apply record_survives (s := appended) (record := _)
    · transcript_walk h
    · exact ⟨_, read, List.mem_append_right _ (by simp)⟩
  · refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
    case refine_6 => record_shape
    all_goals
      rw [merge_present_frame (trace_fields_keys ht) (by decide) hm]
      rw [present_lookup]
      simp +decide [List.find?_cons, atom_beq]
      split
      · rfl
      · rename_i missing
        exact (bne_nil_false missing).symm

end VerifiedKernel.Session.WorkConservation
