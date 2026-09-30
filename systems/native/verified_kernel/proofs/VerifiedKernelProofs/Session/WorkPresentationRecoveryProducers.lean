import VerifiedKernelProofs.Session.WorkSettlementProducers

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

abbrev preserveRequiredNative : Term → Term → Term → Term → KernelM (List Term) :=
  native_decl% "VerifiedKernel.Session.Presentation.preserveRequired"

theorem preserve_required_events_ordinary {facts session attempts diagnostic : Term} {events journal rest : List Term}
    (call : preserveRequiredNative facts session attempts diagnostic journal = .ok (events, rest)) :
    RawOrdinaryBatch events := by
  unfold preserveRequiredNative at call
  unfold_execution_head call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨produced, _, generated, call⟩ := bind_ok call
  have safe := transition_events_ordinary generated
  obtain ⟨revision, _, _, call⟩ := bind_ok call
  rw [pure_ok call]
  apply OrdinaryBatch.raw
  intro event member
  obtain ⟨source, sourceMember, rfl⟩ := List.mem_map.mp member
  refine ⟨binary_keys_put _ _ _ (safe source sourceMember).1, ?_⟩
  rw [get_put_converted_other _ _ (b "revision") rfl (by simp +decide [b, Term.text])]
  exact (safe source sourceMember).2

theorem wait_clear_event_ordinary (session : Term) : OrdinaryBatch
    [.map [(b "type", b "wait_clear"), (b "session_id", session)]] := by
  simp only [OrdinaryBatch, List.mem_singleton, forall_eq]
  constructor
  · rfl
  · simp +decide [OrdinaryKind, Term.get, b, Term.text]

theorem async_completion_events_ordinary {state result diagnostic output : Term} {input journal rest : List Term}
    (safe : RawOrdinaryBatch input)
    (call : Presentation.asyncCompletion state (.tuple [list input, result, diagnostic]) journal =
      .ok (output, rest)) : ∃ events, output = list events ∧ RawOrdinaryBatch events := by
  unfold Presentation.asyncCompletion at call
  repeat' first
    | (execution_head_is call "Pure.pure"; rw [pure_ok call]; refine ⟨_, rfl, ?_⟩
       try simp only [raw_ordinary_append, raw_ordinary_pair]
       repeat' first
         | assumption
         | exact raw_ordinary_filter safe _
         | exact (status_event_ordinary _).raw
         | exact (ack_event_ordinary _ _).raw
         | exact (wait_clear_event_ordinary _).raw
         | exact ordinary_nil.raw
         | apply And.intro
         | split)
    | exact (fail_ok call).elim
    | (execution_head_is call "Bind.bind"
       have bound := bind_ok call; clear call; rcases bound with ⟨_, _, prior, call⟩
       first
         | (execution_head_is prior "VerifiedKernel.Session.Presentation.transitionEvents"
            have extraSafe := (transition_events_ordinary prior).raw)
         | (execution_head_is prior "VerifiedKernel.Session.Presentation.preserveRequired"
            have extraSafe := preserve_required_events_ordinary prior)
         | (execution_head_is prior "VerifiedKernel.Data.asList"
            have same := (asList_ok_iff.mp prior).1; cases same)
         | skip)
    | dsimp only at call
    | split at call
    | (generalize Term.get _ (b "phase") = phase at call
       generalize Term.get _ (b "scheduled") = scheduled at call
       split at call)
  all_goals apply OrdinaryBatch.raw
  all_goals simp +decide [OrdinaryBatch, OrdinaryKind, BinaryKeys, Term.get,
    b, Term.text, Term.isBinary]
  all_goals repeat' first
    | constructor
    | intro _
    | (rename_i member; rcases member with ⟨rfl, rfl⟩ | member)
    | (rename_i member; rcases member with ⟨rfl, rfl⟩)
    | rfl

theorem recovered_completion_events_ordinary {state results hwm output : Term} {input journal rest : List Term}
    (safe : RawOrdinaryBatch input)
    (call : Presentation.recoveredCompletion state (.tuple [list input, results, hwm]) journal =
      .ok (output, rest)) : ∃ events, output = list events ∧ RawOrdinaryBatch events := by
  unfold Presentation.recoveredCompletion at call
  repeat' first
    | (rw [pure_ok call]; refine ⟨_, rfl, ?_⟩
       first
         | exact raw_ordinary_filter safe _
         | solve_raw_batch)
    | exact async_completion_events_ordinary safe call
    | (have bound := bind_ok call; clear call; rcases bound with ⟨_, _, prior, call⟩
       first
         | have extraSafe := (transition_events_ordinary prior).raw
         | (have same := (asList_ok_iff.mp prior).1; cases same)
         | skip)
    | dsimp only at call
    | split at call

end VerifiedKernel.Session.WorkConservation
