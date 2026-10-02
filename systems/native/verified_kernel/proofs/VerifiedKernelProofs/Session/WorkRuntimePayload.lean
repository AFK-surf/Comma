import VerifiedKernelProofs.Session.WorkApplication
import VerifiedKernelProofs.Session.WorkRecordShape

namespace VerifiedKernel.Session.WorkConservation
open Data StateQuery
set_option maxHeartbeats 4000000
set_option Elab.async false

def RuntimeFields (event record : Term) : Prop :=
  record.get (a "id") = event.get (b "message_id") ∧
  record.get (a "runtime_message_id") = event.get (b "runtime_message_id") ∧
  record.get (a "source_message_id") = event.get (b "source_message_id") ∧
  record.get (a "content") = (event.get (b "content")).default (event.get (b "summary")) ∧
  record.get (a "accepted_input") = event.get (b "accepted_input") ∧ RecordShape.WellFormed record

def RuntimeIdentityFields (event record : Term) : Prop :=
  RuntimeFields event record ∧ record.get (a "dedupe_key") = event.get (b "dedupe_key")

theorem alias_value {value first second result : Term} {j r : List Term}
    (h : alias value first second j = .ok (result, r)) :
    result = (value.get first).default (value.get second) := by
  unfold alias at h
  obtain ⟨found, _, read, h⟩ := bind_ok h
  have eq := (access_ok read).1
  subst found
  split at h
  · have eq := pure_ok h
    simp [Term.default, *]
  · have eq := (access_ok h).1
    simp [Term.default, *]

syntax "runtime_record_fields" : tactic
macro_rules
  | `(tactic| runtime_record_fields) => `(tactic|
      (refine ⟨⟨?_, ?_, ?_, ?_, ?_, ?_⟩, ?_⟩
       case refine_6 => record_shape
       all_goals repeat' first
         | (rw [get_put_other _ _ (by decide)])
         | (rw [merge_present_frame (trace_fields_keys (by assumption)) (by decide) (by assumption)]
            rw [present_lookup]
            simp +decide [List.find?_cons, atom_beq]
            split
            · rfl
            · rename_i missing; exact (bne_nil_false missing).symm)
         | split))

/-- Result metadata that `runtimeAppend` puts on a runtime message keeps its identity fields. -/
theorem runtime_identity_put {e m : Term} {name : String} (fields : RuntimeIdentityFields e m)
    (safe : RecordShape.SafeName name) (id : name ≠ "id") (runtimeId : name ≠ "runtime_message_id")
    (source : name ≠ "source_message_id") (content : name ≠ "content")
    (accepted : name ≠ "accepted_input") (dedupe : name ≠ "dedupe_key") (value : Term) :
    RuntimeIdentityFields e (m.put (a name) value) := by
  obtain ⟨⟨hid, hruntime, hsource, hcontent, haccepted, shape⟩, hdedupe⟩ := fields
  exact ⟨⟨(get_put_other _ _ id).trans hid, (get_put_other _ _ runtimeId).trans hruntime,
    (get_put_other _ _ source).trans hsource, (get_put_other _ _ content).trans hcontent,
    (get_put_other _ _ accepted).trans haccepted, shape.put safe value⟩,
    (get_put_other _ _ dedupe).trans hdedupe⟩

/-- Runtime content keeps the event's content-or-summary rule, even when result metadata is attached. -/
theorem runtime_append_stores_identity {s e t : Term} {j r : List Term}
    (h : runtimeAppend s e j = .ok (t, r)) :
    ∃ record, RecordWitness e record ∧ ContainsRecord t record ∧ RuntimeIdentityFields e record := by
  unfold runtimeAppend at h
  replace h := bind_ok h
  obtain ⟨keys, _, _, h⟩ := h
  iterate 7
    replace h := bind_ok h
    obtain ⟨value, _, hx, h⟩ := h
    have eq := (access_ok hx).1
    subst value
  replace h := bind_ok h
  obtain ⟨content, _, hc, h⟩ := h
  have eq := alias_value hc
  subst content
  replace h := bind_ok h
  obtain ⟨provider, _, _, h⟩ := h
  split at h
  all_goals
    replace h := bind_ok h
    obtain ⟨contentKind, _, _, h⟩ := h
    replace h := bind_ok h
    obtain ⟨trace, _, ht, h⟩ := h
    iterate 2
      replace h := bind_ok h
      obtain ⟨value, _, hx, h⟩ := h
      have eq := (access_ok hx).1
      subst value
    replace h := bind_ok h
    obtain ⟨merged, _, hm, h⟩ := h
    -- Both result branches put metadata on this message. Prove its fields once.
    have base : RuntimeIdentityFields e (present merged) := by runtime_record_fields
    replace h := bind_ok h
    obtain ⟨kind, _, _, h⟩ := h
    split at h
  all_goals
    try
      replace h := bind_ok h
      obtain ⟨tool, _, htool, h⟩ := h
      have _ := access_ok htool
      replace h := bind_ok h
      obtain ⟨result, _, _, h⟩ := h
    replace h := bind_ok h
    obtain ⟨message, _, hp, h⟩ := h
    have eq := pure_ok hp
    subst message
    iterate 3
      replace h := bind_ok h
      obtain ⟨_, _, _, h⟩ := h
    replace h := bind_ok h
    obtain ⟨appended, _, ha, h⟩ := h
    obtain ⟨xs, seq, before, read⟩ := appendFields_stores ha
    refine ⟨_, ⟨s, appended, _, _, _, seq, ha, ⟨xs, before, read⟩, rfl⟩, ?_, ?_⟩
    · refine record_survives (s := appended) ?_ ⟨_, read, List.mem_append_right _ (by simp)⟩
      transcript_walk h
    · repeat' first
        | exact base
        | refine runtime_identity_put ?_ (by simp +decide [RecordShape.SafeName]) (by decide) (by decide)
            (by decide) (by decide) (by decide) (by decide) _
        | split

theorem runtime_append_stores_fields {s e t : Term} {j r : List Term}
    (h : runtimeAppend s e j = .ok (t, r)) :
    ∃ record, RecordWitness e record ∧ ContainsRecord t record ∧ RuntimeFields e record := by
  obtain ⟨record, witness, present, fields, _⟩ := runtime_append_stores_identity h
  exact ⟨record, witness, present, fields⟩

theorem runtime_stores_fields {s e t : Term} {j r : List Term}
    (queued : e.get (b "from_queue") = a "true")
    (h : transcriptRuntime s e j = .ok (t, r)) :
    ∃ record, RecordWitness e record ∧ ContainsRecord t record ∧ RuntimeFields e record := by
  unfold transcriptRuntime at h
  simp only [queued, bne, atom_beq_self, Bool.not_true, Bool.and_false, Bool.false_eq_true,
    ↓reduceIte] at h
  repeat' first
    | exact runtime_append_stores_fields h
    | (have impossible := fail_ok h; exact impossible.elim)
    | unfold argumentError at h
    | split at h
    | (replace h := bind_ok h; obtain ⟨_, _, _, h⟩ := h)

end VerifiedKernel.Session.WorkConservation
