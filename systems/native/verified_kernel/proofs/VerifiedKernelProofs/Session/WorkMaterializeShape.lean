import VerifiedKernelProofs.Session.WorkEncoding
import VerifiedKernelProofs.Session.WorkOrder

namespace VerifiedKernel.Session.WorkConservation
open Data StateQuery

def MaterializedEvent (ack : Term) (consumes : List Term) (event : Term) : Prop :=
  RecordEvent event ∨
  (event.get (b "type") = b "queue_ack" ∧ ack ≠ nil ∧
    event.get (b "queue_ack_id") = i (queueId ack)) ∨
  (event.get (b "type") = b "queue_consume" ∧
    ∃ item ∈ consumes, event.get (b "queue_id") = i (queueId item)) ∨
  event.get (b "type") = b "session_event"

theorem encoded_items_records {session : Term} {items : List Term}
    {initial final : List Term × Term × Term × Bool} {j r : List Term}
    (h : materializeItems session items initial j = .ok (final, r))
    (before : ∀ e ∈ initial.1, RecordEvent e) : ∀ e ∈ final.1, RecordEvent e := by
  induction items generalizing initial j r with
  | nil => rw [pure_ok h]; exact before
  | cons item items ih =>
    unfold materializeItems at h
    rw [List.foldlM_cons] at h
    obtain ⟨next, _, first, rest⟩ := bind_ok h
    obtain ⟨⟨event, nextId, hwm⟩, _, generated, first⟩ := bind_ok first
    obtain ⟨wake, _, _, first⟩ := bind_ok first
    have equal := pure_ok first
    subst next
    apply ih rest
    intro e member
    rcases List.mem_cons.mp member with rfl | old
    · exact generated_record_event ⟨_, _, _, _, _, _, generated⟩
    · exact before e old

theorem retry_events_facts {s : Term} {records events : List Term} {j r : List Term}
    (h : activationRetryEvents s records j = .ok (events, r)) :
    ∀ event ∈ events, event.get (b "type") = b "session_event" := by
  unfold activationRetryEvents at h
  repeat' first
    | (have eq := pure_ok h; subst events
       intro event member
       simp only [List.mem_cons, List.not_mem_nil, or_false] at member
       subst event
       simp +decide [stringKeyed, Term.get])
    | (have eq := pure_ok h; subst events; intro e he; simp at he)
    | split at h
    | (replace h := bind_ok h; obtain ⟨_, _, _, h⟩ := h)
    | dsimp only at h

/-- The public query emits only the planned retirement coordinates, plus records and retry facts. -/
theorem materialize_coordinates {state : Term} {events : List Term} {wake : Bool} {hwm : Term}
    {limit : Int} {j r : List Term}
    (h : materialize state limit j = .ok (.tuple [list events, Term.bool wake, hwm], r)) :
    ∃ session items selected ack consumes j₁ j₂ j₃,
      field state "session_id" j = .ok (session, j₁) ∧
      unackedItems state j₁ = .ok (items, j₂) ∧
      materializeBatch state items limit j₂ = .ok ((selected, ack, consumes), j₃) ∧
      ∀ event ∈ events, MaterializedEvent ack consumes event := by
  unfold materialize at h
  obtain ⟨session, j₁, sid, h⟩ := bind_ok h
  obtain ⟨items, j₂, pending, h⟩ := bind_ok h
  obtain ⟨⟨selected, ack, consumes⟩, j₃, plan, h⟩ := bind_ok h
  obtain ⟨id, _, _, h⟩ := bind_ok h
  obtain ⟨⟨records, nextId, hwm', wake'⟩, _, encoded, h⟩ := bind_ok h
  have recordKinds := encoded_items_records encoded (by simp)
  dsimp only at h
  split at h
  rotate_left
  rename_i notNil
  have present : ack ≠ nil := by
    intro same
    subst ack
    simp +decide [nil] at notNil
  obtain ⟨ackId, _, ackRead, h⟩ := bind_ok h
  have ackValue := queueItemId_value ackRead
  subst ackId
  rotate_left
  all_goals
    obtain ⟨acks, _, acked, h⟩ := bind_ok h
    obtain ⟨consumed, _, consumedCall, h⟩ := bind_ok h
    obtain ⟨retries, _, retryCall, h⟩ := bind_ok h
    have eq := pure_ok h
    have same : events = records.reverse ++ acks ++ consumed ++ retries := by
      injection eq with terms
      injection terms with first
      exact Term.list.inj first
    refine ⟨session, items, selected, ack, consumes, j₁, j₂, j₃, sid, pending, plan, ?_⟩
    rw [same]
    intro event member
    simp only [List.mem_append, List.mem_reverse] at member
    rcases member with ((record | ackMember) | consumeMember) | retryMember
    · exact Or.inl (recordKinds event record)
    · have same := pure_ok acked
      subst acks
      simp only [List.mem_cons, List.not_mem_nil, or_false] at ackMember
      all_goals first
        | exact ackMember.elim
        | (subst event
           refine Or.inr (Or.inl ⟨?_, present, ?_⟩)
           all_goals simp +decide [stringKeyed, Term.get])
    · obtain ⟨item, member, _, _, call⟩ := mapM_outputs consumedCall event consumeMember
      obtain ⟨value, _, valueRead, call⟩ := bind_ok call
      have valueEq := queueItemId_value valueRead
      subst value
      obtain rfl := pure_ok call
      refine Or.inr (Or.inr (Or.inl ⟨?_, item, member, ?_⟩))
      all_goals simp +decide [stringKeyed, Term.get]
    · exact Or.inr (Or.inr (Or.inr (retry_events_facts retryCall event retryMember)))

end VerifiedKernel.Session.WorkConservation
