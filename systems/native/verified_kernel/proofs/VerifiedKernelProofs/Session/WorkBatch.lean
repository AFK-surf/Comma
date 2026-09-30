import VerifiedKernelProofs.Session.WorkApplication

namespace VerifiedKernel.Session.WorkConservation
open Data StateQuery

set_option maxHeartbeats 2000000
set_option Elab.async false

theorem record_event_ordinary {e : Term} (kind : RecordEvent e) : Ordinary [e] := by
  intro event member
  have same : event = e := by simpa using member
  subst event
  obtain ⟨_, delivery | runtime⟩ := kind
  · simp +decide [delivery]
  · simp +decide [runtime]

theorem encoded_items_ordinary {session : Term} {items : List Term}
    {initial final : List Term × Term × Term × Bool} {j r : List Term}
    (h : materializeItems session items initial j = .ok (final, r))
    (ordinary : Ordinary initial.1) : Ordinary final.1 := by
  induction items generalizing initial j r with
  | nil =>
    have eq := pure_ok h
    subst final
    exact ordinary
  | cons item items ih =>
    unfold materializeItems at h
    rw [List.foldlM_cons] at h
    obtain ⟨next, j', first, rest⟩ := bind_ok h
    obtain ⟨⟨event, nextId, hwm⟩, j'', generated, first⟩ := bind_ok first
    obtain ⟨wake, j''', _, first⟩ := bind_ok first
    have eq := pure_ok first
    subst next
    apply ih rest
    intro e member
    rcases List.mem_cons.mp member with rfl | old
    · exact record_event_ordinary (generated_record_event ⟨_, _, _, _, _, _, generated⟩) _ (by simp)
    · exact ordinary e old

theorem mapM_outputs {α β : Type} {f : α → KernelM β} {xs : List α} {ys : List β}
    {j r : List Term} (h : xs.mapM f j = .ok (ys, r)) :
    ∀ y ∈ ys, ∃ x ∈ xs, ∃ j' r', f x j' = .ok (y, r') := by
  induction xs generalizing ys j r with
  | nil =>
    have eq := pure_ok h
    subst ys
    simp
  | cons x xs ih =>
    rw [List.mapM_cons] at h
    obtain ⟨y, j', first, h⟩ := bind_ok h
    obtain ⟨tail, r', rest, h⟩ := bind_ok h
    have eq := pure_ok h
    subst ys
    intro value member
    rcases List.mem_cons.mp member with rfl | later
    · exact ⟨x, by simp, j, j', first⟩
    · obtain ⟨item, member, j'', r'', call⟩ := ih rest value later
      exact ⟨item, List.mem_cons_of_mem _ member, j'', r'', call⟩

theorem retry_events_ordinary {s : Term} {records events : List Term} {j r : List Term}
    (h : activationRetryEvents s records j = .ok (events, r)) : Ordinary events := by
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

theorem materialize_ordinary {state : Term} {events : List Term} {wake : Bool} {hwm : Term}
    {limit : Int} {j r : List Term}
    (h : materialize state limit j = .ok (.tuple [list events, Term.bool wake, hwm], r)) : Ordinary events := by
  unfold materialize at h
  obtain ⟨session, _, _, h⟩ := bind_ok h
  obtain ⟨items, _, _, h⟩ := bind_ok h
  obtain ⟨⟨selected, ack, consumes⟩, _, _, h⟩ := bind_ok h
  obtain ⟨id, _, _, h⟩ := bind_ok h
  obtain ⟨⟨records, nextId, hwm', wake'⟩, _, encoded, h⟩ := bind_ok h
  have recordsOrdinary := encoded_items_ordinary encoded (by intro e he; simp at he)
  dsimp only at h
  split at h
  rotate_left
  obtain ⟨_, _, _, h⟩ := bind_ok h
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
    rw [same]
    intro event member
    simp only [List.mem_append, List.mem_reverse] at member
    rcases member with ((record | ackMember) | consumeMember) | retryMember
    · exact recordsOrdinary event record
    · have same := pure_ok acked
      subst acks
      simp only [List.mem_cons, List.not_mem_nil, or_false] at ackMember
      all_goals first
        | exact ackMember.elim
        | (subst event; simp +decide [stringKeyed, Term.get])
    · obtain ⟨item, _, _, _, call⟩ := mapM_outputs consumedCall event consumeMember
      obtain ⟨_, _, _, call⟩ := bind_ok call
      obtain rfl := pure_ok call
      simp +decide [stringKeyed, Term.get]
    · exact retry_events_ordinary retryCall event retryMember

end VerifiedKernel.Session.WorkConservation
