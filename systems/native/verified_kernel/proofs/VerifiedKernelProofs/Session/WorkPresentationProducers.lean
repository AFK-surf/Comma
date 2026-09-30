import VerifiedKernelProofs.Session.WorkEventKeyAdmission

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem transition_events_ordinary {transition session hwm : Term} {events journal rest : List Term}
    (call : Presentation.transitionEvents transition session hwm journal = .ok (events, rest)) :
    OrdinaryBatch events := by
  unfold Presentation.transitionEvents at call
  repeat' first
    | (rw [pure_ok call]; simp +decide [OrdinaryBatch, OrdinaryKind, BinaryKeys, Term.put, Term.get, b, Term.text, Term.isBinary])
    | exact (fail_ok call).elim
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
  all_goals repeat' first
    | constructor
    | intro _
    | (rename_i member; rcases member with ⟨rfl, rfl⟩ | member)
    | (rename_i member; rcases member with ⟨rfl, rfl⟩)
    | rfl

def finishOutputCall : Op :=
  (Presentation.table.lookup "finish_output").getD (fun _ _ => fail "function_clause")

theorem ordinary_append {xs ys : List Term} :
    OrdinaryBatch (xs ++ ys) ↔ OrdinaryBatch xs ∧ OrdinaryBatch ys := by
  constructor
  · intro safe
    exact ⟨fun e h => safe e (List.mem_append_left _ h),
      fun e h => safe e (List.mem_append_right _ h)⟩
  · rintro ⟨left, right⟩ e h
    rcases List.mem_append.mp h with h | h
    · exact left e h
    · exact right e h

theorem ordinary_nil : OrdinaryBatch [] := by intro e h; cases h

theorem raw_ordinary_append {xs ys : List Term} :
    RawOrdinaryBatch (xs ++ ys) ↔ RawOrdinaryBatch xs ∧ RawOrdinaryBatch ys := by
  constructor
  · intro safe
    exact ⟨fun e h => safe e (List.mem_append_left _ h),
      fun e h => safe e (List.mem_append_right _ h)⟩
  · rintro ⟨left, right⟩ e h
    rcases List.mem_append.mp h with h | h
    · exact left e h
    · exact right e h

theorem raw_ordinary_pair {x y : Term} :
    RawOrdinaryBatch [x, y] ↔ RawOrdinaryBatch [x] ∧ RawOrdinaryBatch [y] :=
  raw_ordinary_append (xs := [x]) (ys := [y])

theorem ordinary_pair {x y : Term} :
    OrdinaryBatch [x, y] ↔ OrdinaryBatch [x] ∧ OrdinaryBatch [y] :=
  ordinary_append (xs := [x]) (ys := [y])

theorem status_event_ordinary (session : Term) : OrdinaryBatch
    [.map [(b "type", b "status"), (b "session_id", session), (b "status", b "idle")]] := by
  simp only [OrdinaryBatch, List.mem_singleton, forall_eq]
  constructor
  · rfl
  · simp +decide [OrdinaryKind, Term.get, b, Term.text]

theorem ack_event_ordinary (session hwm : Term) : OrdinaryBatch
    [.map [(b "type", b "ack"), (b "session_id", session), (b "last_ack_message_id", hwm)]] := by
  simp only [OrdinaryBatch, List.mem_singleton, forall_eq]
  constructor
  · rfl
  · simp +decide [OrdinaryKind, Term.get, b, Term.text]

theorem finish_output_ordinary {state leading assistant hwm phase terminal unsettled output plan : Term}
    {events journal rest : List Term}
    (leadingSafe : ∀ xs, leading = list xs → RawOrdinaryBatch xs)
    (assistantSafe : RawOrdinaryBatch [assistant]) (unsettledSafe : RawOrdinaryBatch [unsettled])
    (call : finishOutputCall state (.tuple [leading, assistant, hwm, phase, terminal, unsettled]) journal =
      .ok (.tuple [a "ok", list events, output, plan], rest)) : RawOrdinaryBatch events := by
  simp +decide only [finishOutputCall, Presentation.table, List.lookup, Option.getD,
    String.reduceBEq] at call
  unfold_execution_head call
  repeat' first
    | (have same := congrArg (fun t : Term => match t with
          | .tuple [_, .list xs, _, _] => xs | _ => []) (pure_ok call)
       dsimp only [list] at same
       rw [same]
       simp only [raw_ordinary_append, raw_ordinary_pair]
       repeat' first
         | assumption
         | exact (status_event_ordinary _).raw
         | exact (ack_event_ordinary _ _).raw
         | exact ordinary_nil.raw
         | apply And.intro
         | split)
    | (obtain ⟨_, _, prior, call⟩ := bind_ok call
       first
         | have extraSafe := (transition_events_ordinary prior).raw
         | have inputSafe := leadingSafe _ (asList_ok_iff.mp prior).1
         | skip)
    | split at call

def finishToolBatchCall : Op :=
  (Presentation.table.lookup "finish_tool_batch").getD (fun _ _ => fail "function_clause")

theorem finish_tool_batch_ordinary {state hwm wait checkpoint results returned : Term}
    {input events journal rest : List Term} (inputSafe : RawOrdinaryBatch input)
    (call : finishToolBatchCall state (.tuple [list input, hwm, wait, checkpoint, results]) journal =
      .ok (.tuple [a "ok", list events, returned], rest)) : RawOrdinaryBatch events := by
  simp +decide only [finishToolBatchCall, Presentation.table, List.lookup, Option.getD,
    String.reduceBEq] at call
  unfold_execution_head call
  repeat' first
    | (have same := congrArg (fun t : Term => match t with
          | .tuple [_, .list xs, _] => xs | _ => []) (pure_ok call)
       dsimp only [list] at same
       rw [same]
       simp only [raw_ordinary_append, raw_ordinary_pair]
       repeat' first
         | assumption
         | exact (status_event_ordinary _).raw
         | exact (ack_event_ordinary _ _).raw
         | exact ordinary_nil.raw
         | apply And.intro
         | split)
    | (obtain ⟨_, _, prior, call⟩ := bind_ok call
       first
         | have extraSafe := (transition_events_ordinary prior).raw
         | (have same := (asList_ok_iff.mp prior).1; cases same)
         | (have same := pure_ok prior; cases same)
         | skip)
    | split at call

end VerifiedKernel.Session.WorkConservation
