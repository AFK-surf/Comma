import VerifiedKernelProofs.Session.WorkFrames

namespace VerifiedKernel.Session.WorkConservation
open Data

def WorkFieldsPreserved (s t : Term) : Prop :=
  t.get (a "input_queue") = s.get (a "input_queue") ∧
  t.get (a "messages") = s.get (a "messages")

theorem mergePredicate_work_fields {s kind through replacement extra t : Term} {j r : List Term}
    (h : mergePredicate s kind through replacement extra j = .ok (t, r)) :
    WorkFieldsPreserved s t := by
  unfold mergePredicate at h
  repeat' first
    | exact ⟨write_field_frame h rfl, write_field_frame h rfl⟩
    | split at h
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)

theorem microcompactIds_work_fields {s replacement e t : Term} {ids j r : List Term}
    (h : microcompactIds s ids replacement e j = .ok (t, r)) :
    WorkFieldsPreserved s t := by
  unfold microcompactIds at h
  repeat' first
    | exact ⟨write_field_frame h rfl, write_field_frame h rfl⟩
    | split at h
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)

/-- Modern microcompaction records read-side redactions. It preserves the original durable work. -/
theorem microcompact_modern_work_fields {s e t : Term} {format : Int} {j r : List Term}
    (read : s.get (a "storage_format") = i format) (modern : 2 ≤ format)
    (h : microcompact s e j = .ok (t, r)) : WorkFieldsPreserved s t := by
  unfold microcompact at h
  iterate 3 obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨storedFormat, _, formatRead, h⟩ := bind_ok h
  have formatValue : storedFormat = i format := by
    simp only [field, fetch_ok_iff] at formatRead
    exact formatRead.2.2.1.trans read
  subst storedFormat
  iterate 3 obtain ⟨_, _, _, h⟩ := bind_ok h
  have gate : ((i format).isInteger && decide (integerValue (i format) ≥ 2)) = true := by
    simp [Term.isInteger, integerValue, modern]
  simp only [gate, ↓reduceIte] at h
  split at h
  · exact mergePredicate_work_fields h
  · split at h
    · exact mergePredicate_work_fields h
    · exact microcompactIds_work_fields h

end VerifiedKernel.Session.WorkConservation
