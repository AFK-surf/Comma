import VerifiedKernelProofs.Session.WorkValueSemantics

namespace VerifiedKernel.Session.WorkConservation
open Data
namespace ValueSemantics
set_option Elab.async false

def SameWork (original current : Term) : Prop :=
  Equivalent (original.get (b "queue_id")) (current.get (b "queue_id")) ∧
  Equivalent (original.get (b "kind")) (current.get (b "kind")) ∧
  Equivalent (original.get (b "dedupe_key")) (current.get (b "dedupe_key")) ∧
  Equivalent (original.get (b "payload")) (current.get (b "payload"))

theorem SameWork.refl (item : Term) : SameWork item item :=
  ⟨Equivalent.refl _, Equivalent.refl _, Equivalent.refl _, Equivalent.refl _⟩

theorem SameWork.trans {first middle last : Term} (before : SameWork first middle) (after : SameWork middle last) :
    SameWork first last := ⟨before.1.trans after.1, before.2.1.trans after.2.1,
      before.2.2.1.trans after.2.2.1, before.2.2.2.trans after.2.2.2⟩

theorem SameWork.projection {original current : Term} (same : SameWork original current) :
    Equivalent (queueWorkProjection original) (queueWorkProjection current) := by
  intro path
  cases path with
  | nil => rfl
  | cons step rest =>
    cases step with
    | key _ => rfl
    | present _ => rfl
    | tail => rfl
    | index index =>
      cases index with
      | zero => exact same.1 rest
      | succ index =>
        cases index with
        | zero => exact same.2.1 rest
        | succ index =>
          cases index with
          | zero => exact same.2.2.1 rest
          | succ index =>
            cases index with
            | zero => exact same.2.2.2 rest
            | succ index => rfl

theorem Equivalent.work {left right : Term} (same : Equivalent left right) : SameWork left right :=
  ⟨same.get _, same.get _, same.get _, same.get _⟩

theorem queueWork_semantic {original current : Term} (same : QueueWork original current) : SameWork original current := by
  rcases same with ⟨id, kind, dedupe, payload⟩
  simp only [SameWork, id, kind, dedupe, payload]
  exact SameWork.refl original

def Recorded (item record : Term) : Prop :=
  ∃ witness reference, SameWork item witness ∧ QueuedRecord witness reference ∧ Equivalent reference record

/-- A recorded work witness includes its complete input fact, through semantic codec round trips. -/
theorem Recorded.input_fact {item record : Term} (recorded : Recorded item record) :
    Equivalent (queueWorkProjection item) (record.get (a "accepted_input")) := by
  obtain ⟨witness, reference, same, fields, codec⟩ := recorded
  have stored := codec.get (a "accepted_input")
  rw [fields.1] at stored
  exact same.projection.trans stored

def Represented (state : Term) (sealed : List Term) (item : Term) : Prop :=
  (∃ queue current, state.get (a "input_queue") = list queue ∧ current ∈ queue ∧ SameWork item current) ∨
  (∃ record, ContainsRecord state record ∧ Recorded item record) ∨
  (∃ record ∈ sealed, Recorded item record)

theorem recorded_trans {original current record : Term} (same : SameWork original current)
    (recorded : Recorded current record) : Recorded original record := by
  obtain ⟨witness, reference, work, fields, equivalent⟩ := recorded
  exact ⟨witness, reference, same.trans work, fields, equivalent⟩

theorem represented_trans {state original current : Term} {sealed : List Term}
    (same : SameWork original current) (represented : Represented state sealed current) :
    Represented state sealed original := by
  rcases represented with queued | recorded | archived
  · obtain ⟨queue, item, read, member, work⟩ := queued
    exact Or.inl ⟨queue, item, read, member, same.trans work⟩
  · obtain ⟨record, present, fields⟩ := recorded
    exact Or.inr (Or.inl ⟨record, present, recorded_trans same fields⟩)
  · obtain ⟨record, member, fields⟩ := archived
    exact Or.inr (Or.inr ⟨record, member, recorded_trans same fields⟩)

theorem concrete_representation {state item : Term} {sealed : List Term}
    (represented : ConcreteRepresented state sealed item) : Represented state sealed item := by
  rcases represented with queued | recorded | archived
  · obtain ⟨queue, current, read, member, fields⟩ := queued
    exact Or.inl ⟨queue, current, read, member, queueWork_semantic fields⟩
  · obtain ⟨record, present, fields⟩ := recorded
    exact Or.inr (Or.inl ⟨record, present, item, record, SameWork.refl _, fields, Equivalent.refl _⟩)
  · obtain ⟨record, member, fields⟩ := archived
    exact Or.inr (Or.inr ⟨record, member, item, record, SameWork.refl _, fields, Equivalent.refl _⟩)

theorem execution_preserves {s t item : Term} {sealed : List Term}
    (work : ∀ current, ConcreteRepresented s sealed current → ConcreteRepresented t sealed current)
    (records : ∀ record, ContainsRecord s record → ContainsRecord t record)
    (represented : Represented s sealed item) : Represented t sealed item := by
  rcases represented with queued | recorded | archived
  · obtain ⟨queue, current, read, member, fields⟩ := queued
    have before : ConcreteRepresented s sealed current := Or.inl ⟨queue, current, read, member, rfl, rfl, rfl, rfl⟩
    exact represented_trans fields (concrete_representation (work current before))
  · obtain ⟨record, present, fields⟩ := recorded
    exact Or.inr (Or.inl ⟨record, records record present, fields⟩)
  · exact Or.inr (Or.inr archived)

theorem Equivalent.record {s t record : Term} (same : Equivalent s t) (present : ContainsRecord s record) :
    ∃ next, ContainsRecord t next ∧ Equivalent record next := by
  obtain ⟨records, read, member⟩ := present
  have values := same.get (a "messages")
  rw [read] at values
  obtain ⟨other, nextRead, length, related⟩ := values.list
  obtain ⟨next, nextMember, equivalent⟩ := list_member length related member
  exact ⟨next, ⟨other, nextRead, nextMember⟩, equivalent⟩

theorem Equivalent.represents {s t item : Term} {sealed : List Term}
    (same : Equivalent s t) (represented : Represented s sealed item) : Represented t sealed item := by
  rcases represented with queued | recorded | archived
  · obtain ⟨queue, current, read, member, fields⟩ := queued
    have values := same.get (a "input_queue")
    rw [read] at values
    obtain ⟨other, nextRead, length, related⟩ := values.list
    obtain ⟨next, nextMember, equivalent⟩ := list_member length related member
    exact Or.inl ⟨other, next, nextRead, nextMember, fields.trans equivalent.work⟩
  · obtain ⟨record, present, witness, reference, fields, encoded, equivalent⟩ := recorded
    obtain ⟨next, nextPresent, related⟩ := same.record present
    exact Or.inr (Or.inl ⟨next, nextPresent, witness, reference, fields, encoded, equivalent.trans related⟩)
  · exact Or.inr (Or.inr archived)

theorem sealed_equivalent_represents {state item : Term} {sealed decoded : List Term}
    (same : Equivalent (list sealed) (list decoded))
    (represented : Represented state sealed item) : Represented state decoded item := by
  rcases represented with queued | recorded | archived
  · exact Or.inl queued
  · exact Or.inr (Or.inl recorded)
  · obtain ⟨record, member, witness, reference, fields, encoded, equivalent⟩ := archived
    obtain ⟨other, sameList, length, related⟩ := same.list
    have equal : decoded = other := Term.list.inj sameList
    subst other
    obtain ⟨next, nextMember, nextValue⟩ := list_member length related member
    exact Or.inr (Or.inr ⟨next, nextMember, witness, reference, fields, encoded, equivalent.trans nextValue⟩)

theorem archive_represents {s t item : Term} {live sealed dropped kept : List Term}
    (queue : QueuePreserved s t) (before : s.get (a "messages") = list live)
    (partition : live = dropped ++ kept) (after : t.get (a "messages") = list kept)
    (represented : Represented s sealed item) : Represented t (sealed ++ dropped) item := by
  rcases represented with pending | recorded | archived
  · obtain ⟨items, current, read, member, fields⟩ := pending
    exact Or.inl ⟨items, current, queue.trans read, member, fields⟩
  · obtain ⟨record, ⟨messages, read, member⟩, fields⟩ := recorded
    have same : messages = live := Term.list.inj (read.symm.trans before)
    rw [same, partition] at member
    rcases List.mem_append.mp member with removed | retained
    · exact Or.inr (Or.inr ⟨record, List.mem_append_right _ removed, fields⟩)
    · exact Or.inr (Or.inl ⟨record, ⟨kept, after, retained⟩, fields⟩)
  · obtain ⟨record, member, fields⟩ := archived
    exact Or.inr (Or.inr ⟨record, List.mem_append_left _ member, fields⟩)

end ValueSemantics
end VerifiedKernel.Session.WorkConservation
