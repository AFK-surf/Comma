import VerifiedKernelProofs.Session.WorkResidentEvidence
import VerifiedKernelProofs.Session.AppendOnly.SessionEvent

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 1000000
set_option Elab.async false

theorem queueAppend_format {s e t : Term} {j r : List Term}
    (h : queueAppend s e j = .ok (t, r)) : t.get (a "storage_format") = s.get (a "storage_format") := by
  unfold queueAppend at h
  repeat' first
    | exact write_field_frame h rfl
    | (have same := pure_ok h; subst t; rfl)
    | (exact (fail_ok h).elim)
    | split at h
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)
    | dsimp only at h

theorem pruneResultRefs_format {s t : Term} {j r : List Term}
    (h : pruneResultRefs s j = .ok (t, r)) : t.get (a "storage_format") = s.get (a "storage_format") := by
  unfold pruneResultRefs at h
  repeat' first
    | exact write_field_frame h rfl
    | (have same := pure_ok h; subst t; rfl)
    | split at h
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)

theorem queueConsume_format {s e t : Term} {j r : List Term}
    (h : queueConsume s e j = .ok (t, r)) : t.get (a "storage_format") = s.get (a "storage_format") := by
  unfold queueConsume at h
  iterate 4 obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, written, pruned⟩ := bind_ok h
  exact (pruneResultRefs_format pruned).trans (write_field_frame written rfl)

theorem queueAck_format {s e t : Term} {j r : List Term}
    (h : queueAck s e j = .ok (t, r)) : t.get (a "storage_format") = s.get (a "storage_format") := by
  unfold queueAck at h
  iterate 6 obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, written, pruned⟩ := bind_ok h
  exact (pruneResultRefs_format pruned).trans (write_field_frame written rfl)

theorem sessionEvent_format {s e t : Term} {j r : List Term}
    (h : sessionEvent s e j = .ok (t, r)) : t.get (a "storage_format") = s.get (a "storage_format") :=
  (sessionEvent_fields h).2 "storage_format" rfl

theorem inner_format {s e t : Term} {j r : List Term}
    (h : inner s e j = .ok (t, r)) : t.get (a "storage_format") = s.get (a "storage_format") := by
  by_cases append : (e.get (b "type") == b "queue_append") = true
  · apply queueAppend_format
    simpa +decide [inner, binary_beq_true append] using h
  by_cases ack : (e.get (b "type") == b "queue_ack") = true
  · apply queueAck_format
    simpa +decide [inner, binary_beq_true ack] using h
  by_cases consume : (e.get (b "type") == b "queue_consume") = true
  · simp +decide [inner, binary_beq_true consume] at h
    split at h
    · exact queueConsume_format h
    · have same := pure_ok h; subst t; rfl
  by_cases fact : (e.get (b "type") == b "session_event") = true
  · apply sessionEvent_format
    simpa +decide [inner, binary_beq_true fact] using h
  exact (inner_queue_frame (Bool.eq_false_iff.mpr append) (Bool.eq_false_iff.mpr ack)
    (Bool.eq_false_iff.mpr consume) (Bool.eq_false_iff.mpr fact) h).2.2.2.2


theorem resident_step_format {s event t : Term} (step : ResidentStep s event t) :
    t.get (a "storage_format") = s.get (a "storage_format") := by
  obtain ⟨middle, normalized, j, r, prepared, activity⟩ := step
  apply (activity "storage_format" (by decide) (by decide)).trans
  cases normalized with
  | none => rw [prepareTrusted_none prepared]
  | some normalized =>
    obtain ⟨_, _, _, call⟩ := prepareTrusted_stringify prepared
    exact inner_format call

theorem resident_batch_format {s t : Term} {events : List Term} (execution : ResidentBatch s events t) :
    t.get (a "storage_format") = s.get (a "storage_format") := by
  induction execution with
  | nil => rfl
  | cons head tail ih => exact ih.trans (resident_step_format (resident_execution_step head))

end VerifiedKernel.Session.WorkConservation
