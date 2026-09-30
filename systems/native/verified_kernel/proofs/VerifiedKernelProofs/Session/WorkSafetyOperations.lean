import VerifiedKernelProofs.Session.WorkQueueFrames
import VerifiedKernelProofs.Session.WorkRetry
import VerifiedKernelProofs.Session.WorkExecution
import VerifiedKernelProofs.Session.InputAdmission
import VerifiedKernelProofs.Session.WorkCanonical
import VerifiedKernelProofs.Session.WorkInput

namespace VerifiedKernel.Session.WorkConservation
open Data

theorem binary_ne_false {value : Term} {key : String} (different : value ≠ b key) :
    (value == b key) = false :=
  Bool.eq_false_iff.mpr (fun same => different (binary_beq_true same))

/-- Every dispatched reducer preserves the queue's canonical allocation invariant. -/
theorem inner_allocation {s e t : Term} {j r : List Term}
    (invariant : QueueAllocated s) (h : inner s e j = .ok (t, r)) : QueueAllocated t := by
  by_cases append : e.get (b "type") = b "queue_append"
  · apply queueAppend_allocated invariant
    simpa +decide [inner, append] using h
  by_cases ack : e.get (b "type") = b "queue_ack"
  · apply queueAck_allocation invariant
    simpa +decide [inner, ack] using h
  by_cases consume : e.get (b "type") = b "queue_consume"
  · simp +decide [inner, consume] at h
    split at h
    · exact queueConsume_allocation invariant h
    · have same := pure_ok h
      subst t
      exact invariant
  by_cases fact : e.get (b "type") = b "session_event"
  · apply sessionEvent_allocation invariant
    simpa +decide [inner, fact] using h
  exact queue_frame_allocated (inner_queue_frame (binary_ne_false append) (binary_ne_false ack)
    (binary_ne_false consume) (binary_ne_false fact) h) invariant

theorem concrete_representation_frame_extends {s t item : Term} {sealed : List Term}
    (queue : QueuePreserved s t) (records : TranscriptExtends s t)
    (represented : ConcreteRepresented s sealed item) : ConcreteRepresented t sealed item := by
  rcases represented with pending | recorded | archived
  · obtain ⟨items, current, read, member, same⟩ := pending
    exact Or.inl ⟨items, current, queue.trans read, member, same⟩
  · obtain ⟨record, present, fields⟩ := recorded
    exact Or.inr (Or.inl ⟨record, record_survives records present, fields⟩)
  · exact Or.inr (Or.inr archived)

theorem queueAppend_representation {s e t item : Term} {sealed j r : List Term}
    (invariant : QueueAllocated s) (h : queueAppend s e j = .ok (t, r))
    (represented : ConcreteRepresented s sealed item) : ConcreteRepresented t sealed item := by
  obtain ⟨items, _, read, _, _, canonical, _⟩ := invariant
  obtain ⟨kept, queue, retained⟩ := queueAppend_keeps_queue read canonical h
  rcases represented with pending | recorded | archived
  · obtain ⟨original, current, originalRead, member, same⟩ := pending
    have equal : original = items := Term.list.inj (originalRead.symm.trans read)
    subst original
    exact Or.inl ⟨kept, current, queue, retained member, same⟩
  · obtain ⟨record, present, fields⟩ := recorded
    exact Or.inr (Or.inl ⟨record, record_survives (queueAppend_extends h) present, fields⟩)
  · exact Or.inr (Or.inr archived)

/-- Every event allowed in input admission preserves previously represented work. -/
theorem admitted_inner_representation {s e t item : Term} {sealed j r : List Term}
    (invariant : QueueAllocated s) (allowed : Command.inputEventAllowed e = true)
    (h : inner s e j = .ok (t, r)) (represented : ConcreteRepresented s sealed item) :
    ConcreteRepresented t sealed item := by
  have excluded := InputAdmission.admitted_event_no_retirement (events := [e]) (event := e) (by simpa using allowed) (by simp)
  have records := inner_extends (binary_ne_false excluded.2.2.2) (binary_ne_false excluded.2.2.1) h
  by_cases append : e.get (b "type") = b "queue_append"
  · have reduced : queueAppend s e j = .ok (t, r) := by simpa +decide [inner, append] using h
    exact queueAppend_representation invariant reduced represented
  by_cases fact : e.get (b "type") = b "session_event"
  · obtain ⟨items, _, read, _⟩ := invariant
    have reduced : sessionEvent s e j = .ok (t, r) := by simpa +decide [inner, fact] using h
    exact sessionEvent_representation read reduced represented
  exact concrete_representation_frame_extends
    (inner_queue_frame (binary_ne_false append) (binary_ne_false excluded.1)
      (binary_ne_false excluded.2.1) (binary_ne_false fact) h).1 records represented

theorem projected_allocation {s t : Term} {raw normalized j r : List Term}
    (trace : ProjectedBatch s raw j normalized t r) (invariant : QueueAllocated s) : QueueAllocated t := by
  induction trace with
  | nil => exact invariant
  | skip prepared tail ih =>
    have same := prepareTrusted_none prepared
    subst same
    exact ih invariant
  | cons prepared activity tail ih =>
    obtain ⟨_, _, _, reduced⟩ := prepareTrusted_stringify prepared
    exact ih (queue_frame_allocated (afterEvent_queue_frame activity) (inner_allocation invariant reduced))

theorem projected_admitted_representation {s t item : Term} {raw normalized sealed j r : List Term}
    (trace : ProjectedBatch s raw j normalized t r) (invariant : QueueAllocated s)
    (allowed : normalized.all Command.inputEventAllowed = true)
    (represented : ConcreteRepresented s sealed item) : ConcreteRepresented t sealed item := by
  induction trace with
  | nil => exact represented
  | skip prepared tail ih =>
    have same := prepareTrusted_none prepared
    subst same
    exact ih invariant allowed represented
  | cons prepared activity tail ih =>
    obtain ⟨_, _, _, reduced⟩ := prepareTrusted_stringify prepared
    simp only [List.all_cons, Bool.and_eq_true] at allowed
    obtain ⟨head, rest⟩ := allowed
    have updated := inner_allocation invariant reduced
    have frame := afterEvent_queue_frame activity
    exact ih (queue_frame_allocated frame updated) rest
      (concrete_representation_frame_extends frame.1 (afterEvent_extends activity)
        (admitted_inner_representation invariant head reduced represented))

/-- Actual command projection keeps allocation valid and preserves work for admitted normalized events. -/
theorem project_admitted_safety {s t : Term} {events j r : List Term}
    (invariant : QueueAllocated s) (h : Command.project s events j = .ok (t, r)) :
    ∃ normalized, ProjectedBatch s events j normalized t r ∧ QueueAllocated t ∧
      (normalized.all Command.inputEventAllowed = true →
        ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item) := by
  obtain ⟨normalized, trace⟩ := project_execution h
  exact ⟨normalized, trace, projected_allocation trace invariant,
    fun allowed _ _ represented => projected_admitted_representation trace invariant allowed represented⟩

theorem projected_binary_sublist {s t : Term} {raw normalized j r : List Term}
    (trace : ProjectedBatch s raw j normalized t r)
    (keys : ∀ event ∈ raw, BinaryKeys event) : normalized.Sublist raw := by
  induction trace with
  | nil => exact .refl _
  | skip prepared tail ih =>
    exact (ih (fun event member => keys event (List.mem_cons_of_mem _ member))).cons _
  | cons prepared activity tail ih =>
    obtain ⟨_, read, _⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys (keys _ (by simp)) read
    subst same
    exact (ih (fun event member => keys event (List.mem_cons_of_mem _ member))).cons_cons _

/-- Admission transfers through the actual normalizer and projection, including skipped targets. -/
theorem project_input_safety {s t : Term} {events j r : List Term}
    (invariant : QueueAllocated s) (keys : ∀ event ∈ events, BinaryKeys event)
    (allowed : events.all Command.inputEventAllowed = true)
    (h : Command.project s events j = .ok (t, r)) :
    QueueAllocated t ∧
      ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item := by
  obtain ⟨normalized, trace⟩ := project_execution h
  have subset := (projected_binary_sublist trace keys).subset
  have admitted : normalized.all Command.inputEventAllowed = true :=
    List.all_eq_true.mpr (fun event member => List.all_eq_true.mp allowed event (subset member))
  exact ⟨projected_allocation trace invariant,
    fun _ _ represented => projected_admitted_representation trace invariant admitted represented⟩

/-- Workspace separation cannot insert events that bypass input admission. -/
theorem input_batch_project_safety {s t entry : Term} {events trailing j r j' r' : List Term}
    (workspace : Term → Bool) (invariant : QueueAllocated s)
    (read : Command.inputEvents entry j = .ok (events, r))
    (trailingKeys : ∀ event ∈ trailing, BinaryKeys event)
    (allowed : (events ++ trailing).all Command.inputEventAllowed = true)
    (projected : Command.project s (events.filter (fun event => !workspace event) ++ trailing) j' = .ok (t, r')) :
    QueueAllocated t ∧
      ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item := by
  have subset : ∀ event ∈ events.filter (fun event => !workspace event) ++ trailing,
      event ∈ events ++ trailing := by
    intro event member
    rcases List.mem_append.mp member with first | last
    · exact List.mem_append_left _ (List.mem_filter.mp first).1
    · exact List.mem_append_right _ last
  apply project_input_safety invariant _ _ projected
  · intro event member
    rcases List.mem_append.mp (subset event member) with embedded | generated
    · exact inputEvents_binary_keys read event embedded
    · exact trailingKeys event generated
  · exact List.all_eq_true.mpr (fun event member =>
      List.all_eq_true.mp allowed event (subset event member))

/-- The actual input command supplies the admission premises of concrete work preservation. -/
theorem input_projection_safety {s args result : Term} {j r : List Term}
    (invariant : QueueAllocated s)
    (h : Command.input s args j = .ok (result, r)) :
    result = Command.duplicateInput ∨
    result = Command.finish (.tuple [a "error", a "saturated"]) ∨
    result = Command.finish (.tuple [a "error", a "invalid_delivery_events"]) ∨
    ∃ batch, InputStart result batch ∧
      ∀ t before after, Command.project s batch before = .ok (t, after) →
        QueueAllocated t ∧
          ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item := by
  rcases input_start h with duplicate | saturated | invalid | ⟨batch, start, keys, allowed⟩
  · exact Or.inl duplicate
  · exact Or.inr (Or.inl saturated)
  · exact Or.inr (Or.inr (Or.inl invalid))
  · exact Or.inr (Or.inr (Or.inr ⟨batch, start,
      fun _ _ _ projected => project_input_safety invariant keys allowed projected⟩))

end VerifiedKernel.Session.WorkConservation
