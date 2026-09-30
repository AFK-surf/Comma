import VerifiedKernelProofs.Session.WorkSemanticRepresentation
import VerifiedKernelProofs.Session.WorkSnapshotPipeline
import VerifiedKernelProofs.Session.WorkReload

namespace VerifiedKernel.Session.WorkConservation
open Data
namespace ValueSemantics
set_option maxHeartbeats 1000000
set_option Elab.async false

theorem resident_input_extends {s t event : Term} (step : ResidentStep s event t)
    (canonical : BinaryKeys event) (allowed : Command.inputEventAllowed event = true) : TranscriptExtends s t := by
  obtain ⟨reduced, normalized, j, r, prepared, activity⟩ := step
  cases normalized with
  | none =>
    rw [prepareTrusted_none prepared] at activity
    exact activity_frame_extends activity
  | some normalized =>
    obtain ⟨_, read, _, call⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys canonical read
    subst normalized
    have excluded := InputAdmission.admitted_event_no_retirement (events := [event]) (event := event)
      (by simpa using allowed) (by simp)
    exact extends_trans (inner_extends (binary_ne_false excluded.2.2.2) (binary_ne_false excluded.2.2.1) call)
      (activity_frame_extends activity)

theorem resident_input_batch_extends {s t : Term} {events : List Term} (execution : ResidentBatch s events t)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (allowed : ∀ event ∈ events, Command.inputEventAllowed event = true) : TranscriptExtends s t := by
  induction execution with
  | nil => exact extends_refl _
  | cons head tail ih =>
    exact extends_trans
      (resident_input_extends (resident_execution_step head) (canonical _ List.mem_cons_self) (allowed _ List.mem_cons_self))
      (ih (fun e mem => canonical e (List.mem_cons_of_mem _ mem)) (fun e mem => allowed e (List.mem_cons_of_mem _ mem)))

theorem resident_input_preserves {s t item : Term} {events sealed : List Term}
    (execution : ResidentBatch s events t) (ready : QueueReady s)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (allowed : ∀ event ∈ events, Command.inputEventAllowed event = true)
    (represented : Represented s sealed item) : Represented t sealed item := by
  have safe := resident_batch_input_safety execution ready canonical allowed
  exact execution_preserves (safe.2 sealed)
    (fun _ present => record_survives (resident_input_batch_extends execution canonical allowed) present) represented

theorem materialize_preserves {s t item : Term} {events sealed j r : List Term}
    {limit : Int} {wake : Bool} {hwm : Term}
    (ready : QueueReady s)
    (planned : StateQuery.materialize s limit j = .ok (.tuple [list events, Term.bool wake, hwm], r))
    (execution : ResidentBatch s events t)
    (represented : Represented s sealed item) : Represented t sealed item := by
  obtain ⟨_, _, _, _, _, _, _, _, _, _, _, records, _⟩ := materialize_resident_payloads planned execution
  exact execution_preserves (materialize_resident_preserves ready.1 ready.2.1 planned execution sealed)
    (fun _ present => record_survives records present) represented

theorem normalize_records {s t record : Term} {j r : List Term}
    (ready : QueueReady s) (h : Lifecycle.normalize s j = .ok (t, r))
    (present : ContainsRecord s record) : ContainsRecord t record := by
  obtain ⟨messages, read, member⟩ := present
  have records := (normalize_work ready h).2.2
  have frame := fillDefaults_get (key := "messages") (s := s) (by rw [read]; intro impossible; cases impossible)
  rw [frame, read] at records
  exact ⟨messages, records, member⟩

theorem normalize_preserves {s t item : Term} {sealed j r : List Term}
    (ready : QueueReady s) (h : Lifecycle.normalize s j = .ok (t, r))
    (represented : Represented s sealed item) : Represented t sealed item :=
  execution_preserves (fun _ present => normalize_representation ready h present)
    (fun _ present => normalize_records ready h present) represented

theorem work_fields_preserves {s t item : Term} {sealed : List Term}
    (fields : WorkFieldsPreserved s t) (represented : Represented s sealed item) : Represented t sealed item := by
  simpa only [Represented, ContainsRecord, fields.1, fields.2] using represented

theorem prepareWrite_preserves {s prepared item : Term} {sealed j r : List Term}
    (ready : QueueReady s) (format : s.get (a "storage_format") = i 3)
    (h : Lifecycle.prepareWrite s j = .ok (.tuple [a "ok", prepared], r))
    (represented : Represented s sealed item) : Represented prepared sealed item := by
  unfold Lifecycle.prepareWrite at h
  obtain ⟨normalized, _, normalizedRead, h⟩ := bind_ok h
  have stored := normalize_format format normalizedRead
  obtain ⟨value, _, valueRead, h⟩ := bind_ok h
  have same := (field_value valueRead).trans stored
  subst value
  simp +decide only [show (i 3 == i 1) = false from rfl,
    show (i 3 == i 2 || i 3 == i 3) = true from rfl, Bool.false_eq_true, ↓reduceIte] at h
  obtain ⟨next, _, written, h⟩ := bind_ok h
  have output := pure_ok h
  have same : prepared = next := by simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using output
  subst next
  exact work_fields_preserves ⟨write_field_frame written rfl, write_field_frame written rfl⟩
    (normalize_preserves ready normalizedRead represented)

theorem persist_preserves {s item : Term} {bytes : ByteArray} {sealed : List Term}
    (ready : QueueReady s)
    (h : SessionDomain.dispatch (some s) (.tuple [i 1, a "session", i 1, a "persist", nil]) =
      (some s, .tuple [i 1, a "ok", .binary bytes]))
    (represented : Represented s sealed item) :
    ∃ snapshot, ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      QueueReady snapshot ∧ Represented snapshot sealed item := by
  obtain ⟨snapshot, rest, persisted, encoded⟩ := persist_dispatch_snapshot h
  exact ⟨snapshot, encoded, (persistable_preserves ready persisted).1,
    work_fields_preserves (persistable_work_fields persisted) represented⟩

theorem load_preserves {resident : Option Term} {s t item : Term} {bytes : ByteArray} {sealed : List Term}
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, s]))
    (ready : QueueReady s)
    (trace : ReloadTrace
      (SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]))
      (some t, .tuple [i 1, a "ok", .tuple [a "done"]]))
    (represented : Represented s sealed item) : Represented t sealed item := by
  have initial := normalizedResponse_evidence s [] ready
  rw [← load_dispatch_normalization (resident := resident) decoded (queueReady_isMap ready)] at initial
  obtain ⟨prelude, rest, normalized⟩ := (reload_trace_evidence trace ready initial).1 t rfl
  exact normalize_preserves ready normalized represented

theorem archive_preserves {s e t item : Term} {live sealed j r : List Term}
    (inv : SeqSorted s) (read : s.get (a "messages") = list live)
    (plain : ∀ record ∈ live, (record.isMap && !record.has (a "__struct__")) = true)
    (h : archiveAdvance s e j = .ok (t, r))
    (represented : Represented s sealed item) :
    ∃ dropped kept, live = dropped ++ kept ∧ t.get (a "messages") = list kept ∧
      Represented t (sealed ++ dropped) item := by
  obtain ⟨dropped, kept, partition, after, _⟩ := archiveAdvance_prefix inv read plain h
  exact ⟨dropped, kept, partition, after,
    archive_represents (archive_preserves_queue h) read partition after represented⟩

end ValueSemantics
end VerifiedKernel.Session.WorkConservation
