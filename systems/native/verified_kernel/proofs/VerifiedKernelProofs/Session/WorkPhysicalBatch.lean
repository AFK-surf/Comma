import VerifiedKernelProofs.Session.WorkCatalogExecution

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

theorem pruneResultRefs_owner {state next : Term} {journal rest : List Term}
    (call : pruneResultRefs state journal = .ok (next, rest)) : OwnerFrame state next := by
  unfold pruneResultRefs at call
  owner_walk call

theorem queueAck_owner {state event next : Term} {journal rest : List Term}
    (call : queueAck state event journal = .ok (next, rest)) : OwnerFrame state next := by
  unfold queueAck at call
  repeat' first
    | exact pruneResultRefs_owner call
    | (obtain ⟨_, _, prior, call⟩ := bind_ok call
       first | (have frame := owner_write prior rfl; refine Eq.trans ?_ frame) | skip)

theorem queueConsume_owner {state event next : Term} {journal rest : List Term}
    (call : queueConsume state event journal = .ok (next, rest)) : OwnerFrame state next := by
  unfold queueConsume at call
  repeat' first
    | exact pruneResultRefs_owner call
    | (obtain ⟨_, _, prior, call⟩ := bind_ok call
       first | (have frame := owner_write prior rfl; refine Eq.trans ?_ frame) | skip)

theorem materialized_inner_owner {state event next ack : Term} {consumes journal rest : List Term}
    (kind : MaterializedEvent ack consumes event)
    (call : inner state event journal = .ok (next, rest)) : OwnerFrame state next := by
  rcases kind with record | ⟨ack, _⟩ | ⟨consume, _⟩ | retry
  · obtain ⟨_, delivery | runtime⟩ := record
    · exact transcriptDelivery_owner (by simpa +decide [inner, delivery] using call)
    · exact transcriptRuntime_owner (by simpa +decide [inner, runtime] using call)
  · exact queueAck_owner (by simpa +decide [inner, ack] using call)
  · simp +decide [inner, consume] at call
    split at call
    · exact queueConsume_owner call
    · rw [pure_ok call]; rfl
  · exact sessionEvent_owner (by simpa +decide [inner, retry] using call)

theorem materialized_batch_owner {state next ack : Term} {events consumes : List Term}
    (execution : ResidentBatch state events next)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (kinds : ∀ event ∈ events, MaterializedEvent ack consumes event) : OwnerFrame state next := by
  induction execution with
  | nil => rfl
  | @cons state next final event events observations head tail ih =>
    obtain ⟨middle, normalized, journal, rest, prepared, activity⟩ := resident_execution_step head
    have frame : OwnerFrame state middle := by
      cases normalized with
      | none => rw [prepareTrusted_none prepared]; rfl
      | some normalized =>
        obtain ⟨_, read, _, call⟩ := prepareTrusted_stringify prepared
        have same := shallowStringify_binary_keys (canonical _ List.mem_cons_self) read
        subst normalized
        exact materialized_inner_owner (kinds _ List.mem_cons_self) call
    exact (ih (fun event member => canonical event (List.mem_cons_of_mem _ member))
      (fun event member => kinds event (List.mem_cons_of_mem _ member))).trans
      ((activity "agent_id" (by decide) (by decide)).trans frame)

theorem materialize_owner {state projected next : Term} {events journal rest : List Term}
    {limit : Int} {wake : Bool} {hwm : Term}
    (planned : StateQuery.materialize projected limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
    (execution : ResidentBatch state events next) : OwnerFrame state next := by
  obtain ⟨_, _, _, _, _, _, _, _, _, _, _, kinds⟩ := materialize_coordinates planned
  exact materialized_batch_owner execution (fun event member => (materialize_routed planned event member).1) kinds

theorem admitted_batch_sealed_images {state next : Term} {objects : Objects} {events sealed : List Term}
    (execution : ResidentBatch state events next)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (allowed : ∀ event ∈ events, Command.inputEventAllowed event = true)
    (backed : SealedImagesBacked objects state sealed) : SealedImagesBacked objects next sealed := by
  have fields := batch_catalog_frame execution canonical
    (fun event member => binary_ne_false (admitted_nonretiring (allowed event member)).2.2)
  exact backed.fields (admitted_resident_owner execution canonical allowed) fields.2.2 fields.1

theorem materialize_sealed_images {state projected next : Term} {objects : Objects} {events sealed journal rest : List Term}
    {limit : Int} {wake : Bool} {hwm : Term}
    (planned : StateQuery.materialize projected limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
    (execution : ResidentBatch state events next)
    (backed : SealedImagesBacked objects state sealed) : SealedImagesBacked objects next sealed := by
  have fields := materialize_catalog_frame planned execution
  exact backed.fields (materialize_owner planned execution) fields.2.2 fields.1

end VerifiedKernel.Session.WorkConservation
