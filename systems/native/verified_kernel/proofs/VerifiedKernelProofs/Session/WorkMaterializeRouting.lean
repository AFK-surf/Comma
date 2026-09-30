import VerifiedKernelProofs.Session.WorkEncoding
import VerifiedKernelProofs.Session.WorkInput
import VerifiedKernelProofs.Session.WorkAllocation

namespace VerifiedKernel.Session.WorkConservation
open Data StateQuery
set_option maxHeartbeats 4000000

def Routed (session event : Term) : Prop :=
  BinaryKeys event ∧ event.get (b "session_id") = session

theorem stringKeyed_binary_keys (entries : List (String × Term)) : BinaryKeys (stringKeyed entries) := by
  simp [BinaryKeys, stringKeyed, List.all_map, b, Term.text, Term.isBinary]

theorem putPresent_routed {session event value : Term} {key : String}
    (before : Routed session event) (different : key ≠ "session_id") :
    Routed session (putPresent event key value) := by
  unfold putPresent
  split
  · exact before
  · exact ⟨binary_keys_put _ _ _ before.1, (get_put_binary_other _ _ different).trans before.2⟩

theorem delivery_routed {session item payload id event : Term} {j r : List Term}
    (h : deliveryEvent session item payload id j = .ok (event, r)) : Routed session event := by
  unfold deliveryEvent at h
  obtain ⟨wake, _, _, h⟩ := bind_ok h
  repeat'
    replace h := bind_ok h
    obtain ⟨value, _, read, h⟩ := h
    have eq := (access_ok read).1
    subst value
  obtain rfl := pure_ok h
  apply putPresent_routed (key := "input_time") _ (by decide)
  apply putPresent_routed (key := "delivered_at_ms") _ (by decide)
  apply putPresent_routed (key := "billing_context") _ (by decide)
  exact ⟨stringKeyed_binary_keys _, by simp +decide [stringKeyed, Term.get]⟩

theorem runtime_routed {session item payload id event : Term} {j r : List Term}
    (h : runtimeEvent session item payload id j = .ok (event, r)) : Routed session event := by
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
  refine ⟨stringKeyed_binary_keys _, ?_⟩
  rw [stringKeyed_present_lookup]
  simp +decide [List.find?_cons]
  split
  · rfl
  · rename_i missing
    exact (bne_nil_false missing).symm

theorem queueItemEvent_routed {session item id hwm event nextId nextHwm : Term} {j r : List Term}
    (h : queueItemEvent session item id hwm j = .ok ((event, nextId, nextHwm), r)) : Routed session event := by
  unfold queueItemEvent at h
  iterate 3 obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  all_goals
    obtain ⟨emitted, _, encoded, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    have same : event = emitted := congrArg Prod.fst (pure_ok h)
    subst emitted
    first
      | exact runtime_routed encoded
      | exact delivery_routed encoded

theorem materializeItems_routed {session : Term} {items : List Term}
    {initial final : List Term × Term × Term × Bool} {j r : List Term}
    (h : materializeItems session items initial j = .ok (final, r))
    (before : ∀ event ∈ initial.1, Routed session event) : ∀ event ∈ final.1, Routed session event := by
  induction items generalizing initial j r with
  | nil => rw [pure_ok h]; exact before
  | cons item items ih =>
    unfold materializeItems at h
    rw [List.foldlM_cons] at h
    obtain ⟨next, _, first, rest⟩ := bind_ok h
    obtain ⟨⟨event, nextId, hwm⟩, _, encoded, first⟩ := bind_ok first
    obtain ⟨wake, _, _, first⟩ := bind_ok first
    have same := pure_ok first
    subst next
    apply ih rest
    intro current member
    rcases List.mem_cons.mp member with rfl | old
    · exact queueItemEvent_routed encoded
    · exact before current old

theorem field_value {s value : Term} {key : String} {j r : List Term}
    (h : field s key j = .ok (value, r)) : value = s.get (a key) := by
  simp only [field, fetch_ok_iff] at h
  exact h.2.2.1

theorem activationRetryEvents_routed {s : Term} {records events : List Term} {j r : List Term}
    (h : activationRetryEvents s records j = .ok (events, r)) :
    ∀ event ∈ events, Routed (s.get (a "session_id")) event := by
  unfold activationRetryEvents at h
  repeat' first
    | (have same := pure_ok h; subst events; intro event member; simp at member; done)
    | (have same := pure_ok h; subst events
       intro event member
       simp only [List.mem_cons, List.not_mem_nil, or_false] at member
       subst event
       exact ⟨stringKeyed_binary_keys _, by simp +decide [stringKeyed, Term.get]⟩)
    | split at h
    | (obtain ⟨value, _, read, h⟩ := bind_ok h
       try
         have same : value = s.get (a "session_id") := field_value read
         subst value)
    | dsimp only at h

theorem materialize_routed {s : Term} {events : List Term} {wake : Bool} {hwm : Term}
    {limit : Int} {j r : List Term}
    (h : materialize s limit j = .ok (.tuple [list events, Term.bool wake, hwm], r)) :
    ∀ event ∈ events, Routed (s.get (a "session_id")) event := by
  unfold materialize at h
  obtain ⟨session, _, sessionRead, h⟩ := bind_ok h
  have sessionValue := field_value sessionRead
  subst session
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨⟨_, _, consumes⟩, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨⟨records, _, _, _⟩, _, encoded, h⟩ := bind_ok h
  have recordsRouted := materializeItems_routed encoded (by simp)
  dsimp only at h
  split at h
  rotate_left
  obtain ⟨_, _, _, h⟩ := bind_ok h
  rotate_left
  all_goals
    obtain ⟨acks, _, acked, h⟩ := bind_ok h
    obtain ⟨consumed, _, consumedCall, h⟩ := bind_ok h
    obtain ⟨retries, _, retryCall, h⟩ := bind_ok h
    have same : events = records.reverse ++ acks ++ consumed ++ retries := by
      have eq := pure_ok h
      injection eq with terms
      injection terms with first
      exact Term.list.inj first
    rw [same]
    intro event member
    simp only [List.mem_append, List.mem_reverse] at member
    rcases member with ((record | ackMember) | consumeMember) | retryMember
    · exact recordsRouted event record
    · have same := pure_ok acked
      subst acks
      simp only [List.mem_cons, List.not_mem_nil, or_false] at ackMember
      all_goals first
        | exact ackMember.elim
        | (subst event; exact ⟨stringKeyed_binary_keys _, by simp +decide [stringKeyed, Term.get]⟩)
    · obtain ⟨_, _, _, _, call⟩ := mapM_outputs consumedCall event consumeMember
      obtain ⟨_, _, _, call⟩ := bind_ok call
      obtain rfl := pure_ok call
      exact ⟨stringKeyed_binary_keys _, by simp +decide [stringKeyed, Term.get]⟩
    · exact activationRetryEvents_routed retryCall event retryMember

end VerifiedKernel.Session.WorkConservation
