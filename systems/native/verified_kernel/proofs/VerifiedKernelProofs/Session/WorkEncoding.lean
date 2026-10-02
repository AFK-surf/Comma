import VerifiedKernelProofs.Session.WorkRefinement

namespace VerifiedKernel.Session.WorkConservation
open Data StateQuery
set_option maxHeartbeats 4000000
set_option Elab.async false

def DeliveryEncoding (item payload id event : Term) : Prop :=
  event.get (b "type") = b "delivery" ∧
  event.get (b "message_id") = id ∧
  event.get (b "source_message_id") =
    (payload.get (b "source_message_id")).default (item.get (b "dedupe_key")) ∧
  event.get (b "dedupe_key") = item.get (b "dedupe_key") ∧
  event.get (b "content") = payload.get (b "content") ∧
  event.get (b "accepted_input") = acceptedInput item

theorem mapM_exact {α β : Type} {f : α → KernelM β} {g : α → β}
    (correct : ∀ x value j r, f x j = .ok (value, r) → value = g x)
    {xs : List α} {ys : List β} {j r : List Term}
    (h : xs.mapM f j = .ok (ys, r)) : ys = xs.map g := by
  induction xs generalizing ys j r with
  | nil => exact pure_ok h
  | cons x xs ih =>
    rw [List.mapM_cons] at h
    obtain ⟨value, _, first, h⟩ := bind_ok h
    obtain ⟨tail, _, rest, h⟩ := bind_ok h
    rw [pure_ok h, correct x value _ _ first, ih rest]
    rfl

def RuntimeEncoding (item payload id event : Term) : Prop :=
  event.get (b "type") = b "runtime_message" ∧
  event.get (b "message_id") = id ∧
  event.get (b "runtime_message_id") =
    ((payload.get (b "runtime_message_id")).default (payload.get (b "source_message_id"))).default
      (item.get (b "dedupe_key")) ∧
  event.get (b "source_message_id") = payload.get (b "source_message_id") ∧
  event.get (b "content") = payload.get (b "content") ∧
  event.get (b "summary") = (payload.get (b "summary")).default (payload.get (b "content")) ∧
  event.get (b "accepted_input") = acceptedInput item

theorem delivery_encoding_putPresent {item payload id event : Term} {name : String}
    (encoded : DeliveryEncoding item payload id event)
    (outside : ["type", "message_id", "source_message_id", "dedupe_key", "content",
      "accepted_input"].all (fun key => name != key) = true)
    (value : Term) : DeliveryEncoding item payload id (putPresent event name value) := by
  simp only [List.all_cons, List.all_nil, Bool.and_true, Bool.and_eq_true, bne_iff_ne] at outside
  obtain ⟨type, message, source, dedupe, content, accepted⟩ := outside
  obtain ⟨htype, hmessage, hsource, hdedupe, hcontent, haccepted⟩ := encoded
  exact ⟨(putPresent_get_other _ _ type).trans htype, (putPresent_get_other _ _ message).trans hmessage,
    (putPresent_get_other _ _ source).trans hsource, (putPresent_get_other _ _ dedupe).trans hdedupe,
    (putPresent_get_other _ _ content).trans hcontent, (putPresent_get_other _ _ accepted).trans haccepted⟩

/-- The encoder keeps queue payload identity and content, before any transcript reducer runs. -/
theorem delivery_encoding {session item payload id event : Term} {j r : List Term}
    (h : deliveryEvent session item payload id j = .ok (event, r)) :
    DeliveryEncoding item payload id event := by
  unfold deliveryEvent at h
  obtain ⟨wake, _, _, h⟩ := bind_ok h
  repeat'
    replace h := bind_ok h
    obtain ⟨value, _, read, h⟩ := h
    have eq := (access_ok read).1
    subst value
  obtain rfl := pure_ok h
  -- The optional fields are outside the encoding. Check the literal map once, not per branch.
  repeat (refine delivery_encoding_putPresent ?_ (by decide) _)
  simp +decide [DeliveryEncoding, stringKeyed, Term.get, BEq.beq, Term.text]

theorem stringKeyed_present_lookup (entries : List (String × Term)) (key : String) :
    (stringKeyed (entries.filter (fun pair => pair.2 != nil))).get (b key) =
      ((entries.find? (fun pair => pair.2 != nil && pair.1 == key)).map Prod.snd).getD nil := by
  simp only [stringKeyed, Term.get, List.find?_map, List.find?_filter, Function.comp_def,
    binary_key_beq]
  simp [Function.comp_def, nil]
  rfl

theorem runtime_encoding {session item payload id event : Term} {j r : List Term}
    (h : runtimeEvent session item payload id j = .ok (event, r)) :
    RuntimeEncoding item payload id event := by
  unfold runtimeEvent at h
  obtain ⟨wake, _, _, h⟩ := bind_ok h
  iterate 7
    replace h := bind_ok h
    obtain ⟨value, _, read, h⟩ := h
    have eq := (access_ok read).1
    subst value
  obtain ⟨carried, _, carriedRead, h⟩ := bind_ok h
  have carriedValue := mapM_exact (g := fun name => (name, payload.get (b name)))
    (fun name value j r read => by
      obtain ⟨field, _, fieldRead, read⟩ := bind_ok read
      rw [(access_ok fieldRead).1] at read
      exact pure_ok read) carriedRead
  subst carried
  obtain ⟨kind, _, kindRead, h⟩ := bind_ok h
  have kindValue := (access_ok kindRead).1
  subst kind
  obtain rfl := pure_ok h
  simp only [RuntimeEncoding, stringKeyed_present_lookup]
  simp +decide [List.find?_cons, acceptedInput]
  repeat' apply And.intro
  all_goals first
    | rfl
    | (split
       · rfl
       · rename_i missing; exact (bne_nil_false missing).symm)

theorem queueItemEvent_encoding {session item id hwm event nextId nextHwm : Term} {j r : List Term}
    (h : queueItemEvent session item id hwm j = .ok ((event, nextId, nextHwm), r)) :
    ∃ payload j₁ j₂,
      stringify ((item.get (b "payload")).default empty) j₁ = .ok (payload, j₂) ∧
      (DeliveryEncoding item payload id event ∨ RuntimeEncoding item payload id event) := by
  unfold queueItemEvent at h
  obtain ⟨raw, _, rawRead, h⟩ := bind_ok h
  have rawValue := (access_ok rawRead).1
  subst raw
  obtain ⟨payload, j₂, normalized, h⟩ := bind_ok h
  obtain ⟨kind, _, _, h⟩ := bind_ok h
  split at h
  all_goals
    obtain ⟨emitted, _, encoded, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    have eq := pure_ok h
    have same : event = emitted := congrArg Prod.fst eq
    subst emitted
    refine ⟨payload, _, j₂, normalized, ?_⟩
    first
      | (head_is encoded [runtimeEvent]; exact Or.inr (runtime_encoding encoded))
      | exact Or.inl (delivery_encoding encoded)

/-- A stored record carries the normalized queue payload, independently of the emitted event. -/
def QueuedRecord (item record : Term) : Prop :=
  record.get (a "accepted_input") = acceptedInput item ∧
  RecordShape.WellFormed record ∧
  ∃ payload j r, stringify ((item.get (b "payload")).default empty) j = .ok (payload, r) ∧
    ((record.get (a "source_message_id") =
        (payload.get (b "source_message_id")).default (item.get (b "dedupe_key")) ∧
      record.get (a "dedupe_key") = item.get (b "dedupe_key") ∧
      record.get (a "content") = payload.get (b "content")) ∨
     (record.get (a "runtime_message_id") =
        ((payload.get (b "runtime_message_id")).default (payload.get (b "source_message_id"))).default
          (item.get (b "dedupe_key")) ∧
      record.get (a "source_message_id") = payload.get (b "source_message_id") ∧
      record.get (a "content") = (payload.get (b "content")).default
        ((payload.get (b "summary")).default (payload.get (b "content")))))

theorem generated_record_payload {session item event record : Term}
    (generated : Generated session item event) (fields : InputRecordFields event record) :
    QueuedRecord item record := by
  obtain ⟨_, _, _, _, _, _, encoded⟩ := generated
  obtain ⟨payload, j, r, normalized, delivery | runtime⟩ := queueItemEvent_encoding encoded
  · obtain ⟨kind, _, source, dedupe, content, encodedFact⟩ := delivery
    rcases fields with ⟨_, _, rs, rd, rc, storedFact, shape⟩ | ⟨wrong, _⟩
    · exact ⟨storedFact.trans encodedFact, shape, payload, j, r, normalized,
        Or.inl ⟨rs.trans source, rd.trans dedupe, rc.trans content⟩⟩
    · rw [kind] at wrong
      cases wrong
  · obtain ⟨kind, _, identity, source, content, summary, encodedFact⟩ := runtime
    rcases fields with ⟨wrong, _⟩ | ⟨_, _, ri, rs, rc, storedFact, shape⟩
    · rw [kind] at wrong
      cases wrong
    · exact ⟨storedFact.trans encodedFact, shape, payload, j, r, normalized,
        Or.inr ⟨ri.trans identity, rs.trans source, by simpa [content, summary] using rc⟩⟩

/-- Planning, encoding, and actual batch reduction retain the queue payload in the final record. -/
theorem materialized_queue_payloads {state next : Term} {events : List Term}
    {wake : Bool} {hwm : Term} {limit : Int} {j r : List Term}
    (planned : materialize state limit j = .ok (.tuple [list events, Term.bool wake, hwm], r))
    (applied : AppliedBatch state events next) :
    ∃ session items selected ack consumes j₁ j₂ j₃,
      unackedItems state j₁ = .ok (items, j₂) ∧
      materializeBatch state items limit j₂ = .ok ((selected, ack, consumes), j₃) ∧
      field state "session_id" j = .ok (session, j₁) ∧
      TranscriptExtends state next ∧
      (Ordered items → ∀ item ∈ items, Retired ack consumes item →
        ∃ record, ContainsRecord next record ∧ QueuedRecord item record) := by
  obtain ⟨session, items, selected, ack, consumes, j₁, j₂, j₃, pending, plan, sid, kept, covered⟩ :=
    materialized_input_fields planned applied
  refine ⟨session, items, selected, ack, consumes, j₁, j₂, j₃, pending, plan, sid, kept, ?_⟩
  intro ordered item member retired
  obtain ⟨event, _, generated, record, _, present, fields⟩ := covered ordered item member retired
  exact ⟨record, present, generated_record_payload generated fields⟩

end VerifiedKernel.Session.WorkConservation
