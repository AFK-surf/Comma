import VerifiedKernelProofs.Session.WorkEncoding
import VerifiedKernel.Session.Command

namespace VerifiedKernel.Session.WorkConservation
open Data

theorem prepareTrusted_stringify {state raw next event : Term} {journal rest : List Term}
    (h : prepareTrusted state raw journal = .ok ((next, some event), rest)) :
    ∃ rest', shallowStringify raw journal = .ok (event, rest') ∧
      ∃ rest'', inner state event rest' = .ok (next, rest'') := by
  unfold prepareTrusted at h
  simp only [bind_ok_iff, ite_ok_iff, fail_ok_iff, false_and, and_false, exists_false, false_or,
    pure_ok_iff, Prod.mk.injEq, reduceCtorEq, Option.some.injEq] at h
  obtain ⟨-, -, normalized, rest', hs, -, n, rest'', hn, ⟨rfl, rfl⟩, rfl⟩ := h
  exact ⟨_, hs, _, hn⟩

theorem prepareTrusted_none {state raw next : Term} {journal rest : List Term}
    (h : prepareTrusted state raw journal = .ok ((next, none), rest)) : next = state := by
  unfold prepareTrusted at h
  simp only [bind_ok_iff, ite_ok_iff, fail_ok_iff, false_and, and_false, exists_false, false_or,
    or_false, pure_ok_iff, Prod.mk.injEq, reduceCtorEq, and_true] at h
  obtain ⟨-, -, normalized, rest', hs, -, hnext, -⟩ := h
  exact hnext

/-- Actual projected execution, with normalized events, skipped targets, and continuous journals. -/
inductive ProjectedBatch : Term → List Term → List Term → List Term → Term → List Term → Prop where
  | nil (s : Term) (j : List Term) : ProjectedBatch s [] j [] s j
  | skip {s next final raw : Term} {events normalized j r rest : List Term}
      (prepared : prepareTrusted s raw j = .ok ((next, none), r))
      (tail : ProjectedBatch next events r normalized final rest) :
      ProjectedBatch s (raw :: events) j normalized final rest
  | cons {s middle next final raw event : Term} {events normalized j r after rest : List Term}
      (prepared : prepareTrusted s raw j = .ok ((middle, some event), r))
      (activity : afterEvent s middle event r = .ok (next, after))
      (tail : ProjectedBatch next events after normalized final rest) :
      ProjectedBatch s (raw :: events) j (event :: normalized) final rest

/-- The execution trace is a consequence of the executable fold, not a caller assumption. -/
theorem project_execution {s t : Term} {events j r : List Term}
    (h : Command.project s events j = .ok (t, r)) :
    ∃ normalized, ProjectedBatch s events j normalized t r := by
  induction events generalizing s j with
  | nil =>
    have eq := Prod.mk.inj (Except.ok.inj h)
    obtain ⟨rfl, rfl⟩ := eq
    exact ⟨[], .nil _ _⟩
  | cons raw events ih =>
    unfold Command.project at h
    rw [List.foldlM_cons] at h
    obtain ⟨next, after, step, tail⟩ := bind_ok h
    obtain ⟨normalized, executed⟩ := ih tail
    obtain ⟨⟨middle, event⟩, rest, prepared, step⟩ := bind_ok step
    cases event with
    | none =>
      have eq := Prod.mk.inj (Except.ok.inj step)
      obtain ⟨rfl, rfl⟩ := eq
      exact ⟨normalized, .skip prepared executed⟩
    | some event => exact ⟨event :: normalized, .cons prepared step executed⟩

theorem projected_batch_extends {s t : Term} {raw normalized j r : List Term}
    (trace : ProjectedBatch s raw j normalized t r) (ordinary : Ordinary normalized) :
    TranscriptExtends s t := by
  induction trace with
  | nil => exact extends_refl _
  | skip prepared tail ih =>
    have same := prepareTrusted_none prepared
    subst same
    exact ih ordinary
  | @cons s middle next final raw event events normalized j r after rest prepared activity tail ih =>
    obtain ⟨_, _, _, reduced⟩ := prepareTrusted_stringify prepared
    have kind := ordinary event (by simp)
    exact extends_trans (inner_extends kind.1 kind.2 reduced)
      (extends_trans (afterEvent_extends activity)
        (ih (fun event member => ordinary event (List.mem_cons_of_mem _ member))))

theorem projected_batch_input_fields {s t e : Term} {raw normalized j r : List Term}
    (trace : ProjectedBatch s raw j normalized t r) (ordinary : Ordinary normalized)
    (member : e ∈ normalized) (kind : RecordEvent e) :
    ∃ record, RecordWitness e record ∧ ContainsRecord t record ∧ InputRecordFields e record := by
  induction trace with
  | nil => simp at member
  | skip prepared tail ih => exact ih ordinary member
  | cons prepared activity tail ih =>
    have ordinaryTail : Ordinary _ :=
      fun event member => ordinary event (List.mem_cons_of_mem _ member)
    rcases List.mem_cons.mp member with same | later
    · subst same
      obtain ⟨_, _, _, reduced⟩ := prepareTrusted_stringify prepared
      obtain ⟨record, witness, present, fields⟩ := input_event_stores_fields kind reduced
      exact ⟨record, witness,
        record_survives (projected_batch_extends tail ordinaryTail)
          (record_survives (afterEvent_extends activity) present), fields⟩
    · exact ih ordinaryTail later

/-- Successful projection preserves old records and stores each executed queue record's payload.
The normalized trace is derived from the call, including any target-filtered events. -/
theorem project_input_records {s t : Term} {events j r : List Term}
    (h : Command.project s events j = .ok (t, r)) :
    ∃ normalized, ProjectedBatch s events j normalized t r ∧
      (Ordinary normalized → TranscriptExtends s t ∧
        ∀ session item event, event ∈ normalized → Generated session item event →
          ∃ record, ContainsRecord t record ∧ QueuedRecord item record) := by
  obtain ⟨normalized, trace⟩ := project_execution h
  refine ⟨normalized, trace, fun ordinary => ⟨projected_batch_extends trace ordinary, ?_⟩⟩
  intro session item event member generated
  obtain ⟨record, _, present, fields⟩ :=
    projected_batch_input_fields trace ordinary member (generated_record_event generated)
  exact ⟨record, present, generated_record_payload generated fields⟩

end VerifiedKernel.Session.WorkConservation
