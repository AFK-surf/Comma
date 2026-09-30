import VerifiedKernelProofs.Session.WorkLedgerClosure

namespace VerifiedKernel.Session.WorkConservation
open Data StateQuery
set_option Elab.async false
set_option maxHeartbeats 2000000

def NoQueueAppend (events : List Term) : Prop :=
  ∀ event ∈ events, event.get (b "type") ≠ b "queue_append"

theorem tag_no_append {value : Term} (different : (value == b "queue_append") = false) : value ≠ b "queue_append" := by
  intro same
  rw [same] at different
  cases different

theorem record_event_no_append {event : Term} (kind : RecordEvent event) :
    event.get (b "type") ≠ b "queue_append" := by
  obtain ⟨_, delivery | runtime⟩ := kind
  · simp +decide [delivery]
    exact tag_no_append rfl
  · simp +decide [runtime]
    exact tag_no_append rfl

theorem encoded_items_no_append {session : Term} {items : List Term}
    {initial final : List Term × Term × Term × Bool} {journal rest : List Term}
    (call : materializeItems session items initial journal = .ok (final, rest))
    (noAppend : NoQueueAppend initial.1) : NoQueueAppend final.1 := by
  induction items generalizing initial journal rest with
  | nil => rw [pure_ok call]; exact noAppend
  | cons item items ih =>
    unfold materializeItems at call
    rw [List.foldlM_cons] at call
    obtain ⟨next, _, head, tail⟩ := bind_ok call
    obtain ⟨⟨event, nextId, hwm⟩, _, generated, head⟩ := bind_ok head
    obtain ⟨wake, _, _, head⟩ := bind_ok head
    have same := pure_ok head
    subst next
    apply ih tail
    intro emitted member
    rcases List.mem_cons.mp member with rfl | old
    · exact record_event_no_append (generated_record_event ⟨_, _, _, _, _, _, generated⟩)
    · exact noAppend emitted old

theorem retry_events_no_append {state : Term} {records events journal rest : List Term}
    (call : activationRetryEvents state records journal = .ok (events, rest)) : NoQueueAppend events := by
  unfold activationRetryEvents at call
  repeat' first
    | (have same := pure_ok call; subst events
       intro event member
       simp only [List.mem_cons, List.not_mem_nil, or_false] at member
       subst event
       simp +decide [stringKeyed, Term.get])
    | (have same := pure_ok call; subst events; intro event member; simp at member)
    | split at call
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | dsimp only at call
  all_goals exact tag_no_append rfl

theorem materialize_no_append {state : Term} {events journal rest : List Term}
    {wake : Bool} {hwm : Term} {limit : Int}
    (call : materialize state limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest)) : NoQueueAppend events := by
  unfold materialize at call
  obtain ⟨session, _, _, call⟩ := bind_ok call
  obtain ⟨items, _, _, call⟩ := bind_ok call
  obtain ⟨⟨selected, ack, consumes⟩, _, _, call⟩ := bind_ok call
  obtain ⟨id, _, _, call⟩ := bind_ok call
  obtain ⟨⟨records, nextId, hwm', wake'⟩, _, encoded, call⟩ := bind_ok call
  have recordsSafe := encoded_items_no_append encoded (by intro event member; simp at member)
  dsimp only at call
  split at call
  rotate_left
  obtain ⟨_, _, _, call⟩ := bind_ok call
  rotate_left
  all_goals
    obtain ⟨acks, _, acked, call⟩ := bind_ok call
    obtain ⟨consumed, _, consumedCall, call⟩ := bind_ok call
    obtain ⟨retries, _, retryCall, call⟩ := bind_ok call
    have result := pure_ok call
    have same : events = records.reverse ++ acks ++ consumed ++ retries := by
      injection result with terms
      injection terms with first
      exact Term.list.inj first
    rw [same]
    intro event member
    simp only [List.mem_append, List.mem_reverse] at member
    rcases member with ((record | ackMember) | consumeMember) | retryMember
    · exact recordsSafe event record
    · have same := pure_ok acked
      subst acks
      simp only [List.mem_cons, List.not_mem_nil, or_false] at ackMember
      all_goals first
        | exact ackMember.elim
        | (subst event; simp +decide [stringKeyed, Term.get]; exact tag_no_append rfl)
    · obtain ⟨item, _, _, _, step⟩ := mapM_outputs consumedCall event consumeMember
      obtain ⟨_, _, _, step⟩ := bind_ok step
      obtain rfl := pure_ok step
      simp +decide [stringKeyed, Term.get]
      exact tag_no_append rfl
    · exact retry_events_no_append retryCall event retryMember
  all_goals exact tag_no_append rfl

theorem inner_new_identity_record {state event next : Term} {source : ByteArray} {journal rest : List Term}
    (noAppend : event.get (b "type") ≠ b "queue_append")
    (call : inner state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) (.binary source))
    (present : IdentityPresent (next.get (a "input_dedupe")) (.binary source)) :
    ∃ record, IdentityFactOrigin event source (.record record) ∧ ContainsRecord next record := by
  by_cases log : event.get (b "type") = b "session_log_message"
  · obtain ⟨record, _, stored, identity, content⟩ := log_new_identity_fact
      (by simpa +decide [inner, log] using call) absent present
    exact ⟨record, .log log identity content, stored⟩
  by_cases delivery : event.get (b "type") = b "delivery"
  · obtain ⟨record, _, stored, identity, content, input⟩ := delivery_new_identity_fact
      (by simpa +decide [inner, delivery] using call) absent present
    exact ⟨record, .delivery delivery identity content input, stored⟩
  by_cases runtime : event.get (b "type") = b "runtime_message"
  · obtain ⟨record, _, stored, identity, content, input⟩ := runtime_new_identity_fact
      (by simpa +decide [inner, runtime] using call) absent present
    exact ⟨record, .runtime runtime identity content input, stored⟩
  by_cases seed : event.get (b "type") = b "transcript_seed"
  · obtain ⟨items, raw, record, enumerated, included, stored, fields⟩ := seed_new_identity_fact
      (by simpa +decide [inner, seed] using call) absent present
    exact ⟨record, .seed seed enumerated included fields, stored⟩
  have frame := inner_nonwriter_ledger_frame (binary_ne_false noAppend) (binary_ne_false log)
    (binary_ne_false seed) (binary_ne_false runtime) (binary_ne_false delivery) call
  unfold IdentityPresent at present
  unfold IdentityAbsent at absent
  rw [frame, absent] at present
  contradiction

theorem reduced_batch_new_identity_records {state next : Term} {source : ByteArray} {events : List Term}
    (execution : ResidentReducedBatch state events next) (ordinary : Ordinary events)
    (noAppend : NoQueueAppend events)
    (present : IdentityPresent (next.get (a "input_dedupe")) (.binary source)) :
    IdentityPresent (state.get (a "input_dedupe")) (.binary source) ∨
      ∃ event ∈ events, ∃ record, IdentityFactOrigin event source (.record record) ∧ ContainsRecord next record := by
  induction execution with
  | nil => exact Or.inl present
  | cons call activity tail ih =>
    have ordinaryTail : Ordinary _ := fun event member => ordinary event (List.mem_cons_of_mem _ member)
    have noAppendTail : NoQueueAppend _ := fun event member => noAppend event (List.mem_cons_of_mem _ member)
    rcases ih ordinaryTail noAppendTail present with middle | ⟨event, included, record, origin, stored⟩
    · rcases identity_present_or_absent _ (.binary source) with old | absent
      · exact Or.inl old
      · rw [activity "input_dedupe" (by decide) (by decide)] at middle
        obtain ⟨record, origin, stored⟩ := inner_new_identity_record
          (noAppend _ List.mem_cons_self) call absent middle
        exact Or.inr ⟨_, List.mem_cons_self, record, origin,
          record_survives (extends_trans (activity_frame_extends activity) (resident_reduced_extends tail ordinaryTail)) stored⟩
    · exact Or.inr ⟨event, List.mem_cons_of_mem _ included, record, origin, stored⟩

/-- The actual planner can retire queue entries without losing the facts that support their ledger identities. -/
theorem materialize_ledger_supported {state next : Term} {events journal rest sealed : List Term}
    {wake : Bool} {hwm : Term} {limit : Int}
    (ready : QueueReady state) (supported : LedgerSupported state sealed)
    (planned : materialize state limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
    (execution : ResidentBatch state events next) : LedgerSupported next sealed := by
  have routed := materialize_routed planned
  obtain ⟨reduced, _⟩ := resident_routed_reduces execution routed
  have ordinary := materialize_ordinary planned
  intro source present
  rcases reduced_batch_new_identity_records reduced ordinary (materialize_no_append planned) present with
    old | ⟨event, _, record, origin, stored⟩
  · obtain ⟨originInput, fact, origin, represented⟩ := supported source old
    exact ⟨originInput, fact, origin, identity_fact_preserves
      (fun _ work => ValueSemantics.materialize_preserves ready planned execution work)
      (fun _ stored => record_survives (resident_reduced_extends reduced ordinary) stored) represented⟩
  · exact ⟨event, .record record, origin, identity_record_present stored sealed⟩

end VerifiedKernel.Session.WorkConservation
