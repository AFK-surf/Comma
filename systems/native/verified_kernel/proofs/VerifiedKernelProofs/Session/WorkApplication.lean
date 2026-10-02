import VerifiedKernelProofs.Session.WorkConservation
import VerifiedKernelProofs.Session.AppendOnly

namespace VerifiedKernel.Session.WorkConservation
open Data StateQuery

set_option maxHeartbeats 4000000
set_option Elab.async false

/-- A concrete transcript record, not a ghost queue-item witness. -/
def ContainsRecord (state record : Term) : Prop :=
  ∃ messages, state.get (a "messages") = .list messages ∧ record ∈ messages

def AppendedRecord (before after record : Term) : Prop :=
  ∃ messages, before.get (a "messages") = .list messages ∧
    after.get (a "messages") = .list (messages ++ [record])

theorem record_survives {s t record : Term} (kept : TranscriptExtends s t)
    (present : ContainsRecord s record) : ContainsRecord t record := by
  obtain ⟨xs, read, member⟩ := present
  obtain ⟨ys, next⟩ := kept xs read
  exact ⟨xs ++ ys, next, List.mem_append_left _ member⟩

/-- Successful append stores the complete supplied message, with only its sequence replaced. -/
theorem appendFields_stores {s e message t : Term} {j r : List Term}
    (h : appendFields s e message j = .ok (t, r)) :
    ∃ xs seq, s.get (a "messages") = .list xs ∧
      t.get (a "messages") = .list (xs ++ [message.put (a "seq") seq]) := by
  unfold appendFields at h
  obtain ⟨_, _, hf, h⟩ := bind_ok h
  obtain ⟨seq, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, hr, h⟩ := bind_ok h
  obtain ⟨_, _, ha, h⟩ := bind_ok h
  simp only [field, fetch_ok_iff] at hr
  obtain ⟨_, _, rfl, _⟩ := hr
  obtain ⟨xs, ys, read, hy, rfl, _⟩ := append_ok_iff.mp ha
  obtain rfl := Term.list.inj hy
  repeat' first
    | exact ⟨xs, seq, read, write_get h rfl⟩
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)
    | split at h
    | dsimp only at h



def RecordEvent (event : Term) : Prop :=
  event.get (b "from_queue") = a "true" ∧
    (event.get (b "type") = b "delivery" ∨ event.get (b "type") = b "runtime_message")

theorem binary_key_beq (left right : String) : (b left == b right) = (left == right) := by
  apply Bool.eq_iff_iff.mpr
  change (left.toByteArray.data == right.toByteArray.data) = true ↔ (left == right) = true
  simp only [beq_iff_eq]
  constructor
  · intro same
    exact String.toByteArray_inj.mp (ByteArray.ext same)
  · intro same
    subst right
    rfl

theorem binary_beq_true {t : Term} {key : String} (h : (t == b key) = true) : t = b key := by
  cases t <;> simp [b, Term.text, BEq.beq] at h
  exact congrArg Term.binary (ByteArray.ext (by
    simpa only [ByteArray.beq, beq_iff_eq, String.toUTF8_eq_toByteArray] using h))

theorem get_put_binary_other (v x : Term) {key other : String} (different : other ≠ key) :
    (v.put (b other) x).get (b key) = v.get (b key) := by
  have neq : (b other == b key) = false := by simp [binary_key_beq, different]
  cases v with
  | map entries =>
    simp only [Term.put, Term.get, List.find?_cons, neq]
    rw [find?_filter_of_imp]
    intro entry matched
    have same := binary_beq_true matched
    simp [same, binary_key_beq, Ne.symm different]
  | _ => simp [Term.put, Term.get, neq]

theorem putPresent_get_other (target value : Term) {name key : String} (different : name ≠ key) :
    (putPresent target name value).get (b key) = target.get (b key) := by
  unfold putPresent
  split
  · rfl
  · exact get_put_binary_other _ _ different

theorem recordEvent_putPresent {event : Term} {name : String} (shape : RecordEvent event)
    (fromQueue : name ≠ "from_queue") (type : name ≠ "type") (value : Term) :
    RecordEvent (putPresent event name value) := by
  obtain ⟨queued, kind⟩ := shape
  rw [RecordEvent, putPresent_get_other _ _ fromQueue, putPresent_get_other _ _ type]
  exact ⟨queued, kind⟩

theorem delivery_event_shape {session item payload id event : Term} {j r : List Term}
    (h : deliveryEvent session item payload id j = .ok (event, r)) : RecordEvent event := by
  unfold deliveryEvent at h
  repeat obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain rfl := pure_ok h
  -- The optional fields are outside `RecordEvent`. Check the literal map once, not per branch.
  repeat (refine recordEvent_putPresent ?_ (by decide) (by decide) _)
  simp +decide [RecordEvent, stringKeyed, Term.get, BEq.beq, Term.text]

theorem runtime_event_shape {session item payload id event : Term} {j r : List Term}
    (h : runtimeEvent session item payload id j = .ok (event, r)) : RecordEvent event := by
  unfold runtimeEvent at h
  repeat obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain rfl := pure_ok h
  simp only [RecordEvent, stringKeyed, Term.get, List.find?_map, List.find?_filter]
  simp +decide [BEq.beq, Term.text, nil]

theorem generated_record_event {session item event : Term} (h : Generated session item event) :
    RecordEvent event := by
  obtain ⟨id, hwm, id', hwm', j, r, h⟩ := h
  unfold queueItemEvent at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h <;>
    obtain ⟨encoded, _, he, h⟩ := bind_ok h <;>
    repeat obtain ⟨_, _, _, h⟩ := bind_ok h
  all_goals
    have eq := pure_ok h
    have same : event = encoded := congrArg Prod.fst eq
    subst event
    first
      | (head_is he [runtimeEvent]; exact runtime_event_shape he)
      | exact delivery_event_shape he


/-- Successful canonical event applications, including admission and activity bookkeeping.
The host supplies the complete journals for these calls. No storage effect is modeled here. -/
inductive AppliedBatch : Term → List Term → Term → Prop where
  | nil (s : Term) : AppliedBatch s [] s
  | cons {s middle next final e : Term} {events : List Term} {j r rest : List Term}
      (prepared : prepare s e j = .ok ((middle, some e), r))
      (activity : afterEvent s middle e r = .ok (next, rest))
      (tail : AppliedBatch next events final) : AppliedBatch s (e :: events) final

/-- Archive removal and legacy transcript rewriting are outside a materialization batch. -/
def Ordinary (events : List Term) : Prop := ∀ e ∈ events,
  (e.get (b "type") == b "session_microcompact") = false ∧
  (e.get (b "type") == b "archive_advance") = false

theorem applied_batch_extends {s t : Term} {events : List Term}
    (applied : AppliedBatch s events t) (ordinary : Ordinary events) : TranscriptExtends s t := by
  induction applied with
  | nil => exact extends_refl _
  | @cons s middle next final e events j r rest prepared activity tail ih =>
    have kind := ordinary e (by simp)
    exact extends_trans (prepare_extends kind.1 kind.2 prepared)
      (extends_trans (afterEvent_extends activity)
        (ih (fun event member => ordinary event (List.mem_cons_of_mem _ member))))

/-- The record is the exact argument of an actual append, with its actual assigned sequence. -/
def RecordWitness (event record : Term) : Prop :=
  ∃ before middle message j r seq,
    appendFields before event message j = .ok (middle, r) ∧
    AppendedRecord before middle (message.put (a "seq") seq) ∧
    record = message.put (a "seq") seq

end VerifiedKernel.Session.WorkConservation
