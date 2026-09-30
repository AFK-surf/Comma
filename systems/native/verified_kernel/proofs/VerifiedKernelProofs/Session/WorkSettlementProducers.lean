import VerifiedKernelProofs.Session.WorkPresentationProducers
import VerifiedKernelProofs.Proof.NativeProducerTactic

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem raw_ordinary_filter {events : List Term} (safe : RawOrdinaryBatch events) (f : Term → Bool) :
    RawOrdinaryBatch (events.filter f) := fun e member => safe e (List.mem_filter.mp member).1

theorem terminal_events_ordinary {state record result output : Term} {input journal rest : List Term}
    (safe : RawOrdinaryBatch input)
    (call : Settlement.terminal state record result input journal = .ok (output, rest)) :
    output = nil ∨ ∃ events, output = list events ∧ RawOrdinaryBatch events := by
  unfold Settlement.terminal at call
  repeat' first
    | (rw [pure_ok call]; left; rfl)
    | (rw [pure_ok call]; right; refine ⟨_, rfl, ?_⟩)
    | (have bound := bind_ok call; clear call; rcases bound with ⟨_, _, _, call⟩)
    | split at call
  all_goals
    unfold_native "VerifiedKernel.Session.Settlement.terminalEvents"
    try unfold_native "VerifiedKernel.Session.Settlement.completedRepair"
    unfold Settlement.withoutWake
    try simp only [raw_ordinary_append]
    repeat' first
      | apply And.intro
      | exact raw_ordinary_filter safe _
      | exact ordinary_nil.raw
      | split
  all_goals apply OrdinaryBatch.raw
  all_goals simp +decide [OrdinaryBatch, OrdinaryKind, BinaryKeys, Term.get,
    b, Term.text, Term.isBinary]
  all_goals repeat' first
    | constructor
    | intro _
    | (rename_i member; rcases member with ⟨rfl, rfl⟩ | member)
    | (rename_i member; rcases member with ⟨rfl, rfl⟩)
    | rfl

theorem onboarding_events_ordinary {state output : Term} {results input journal rest : List Term}
    {router : Bool} (safe : RawOrdinaryBatch input)
    (call : Settlement.onboarding state results input router journal = .ok (output, rest)) :
    output = nil ∨ ∃ events, output = list events ∧ RawOrdinaryBatch events := by
  unfold Settlement.onboarding at call
  repeat' first
    | (rw [pure_ok call]; left; rfl)
    | (rw [pure_ok call]; right; refine ⟨_, rfl, ?_⟩)
    | (have bound := bind_ok call; clear call; rcases bound with ⟨_, _, _, call⟩)
    | split at call
  all_goals
    unfold_native "VerifiedKernel.Session.Settlement.terminalEvents"
    unfold_native "VerifiedKernel.Session.Settlement.completedRepair"
    simp only [raw_ordinary_append]
    repeat' first
      | assumption
      | apply And.intro
      | exact ordinary_nil.raw
      | split
  all_goals apply OrdinaryBatch.raw
  all_goals simp +decide [OrdinaryBatch, OrdinaryKind, BinaryKeys, Term.get,
    b, Term.text, Term.isBinary]
  all_goals repeat' first
    | constructor
    | intro _
    | (rename_i member; rcases member with ⟨rfl, rfl⟩ | member)
    | (rename_i member; rcases member with ⟨rfl, rfl⟩)
    | rfl

-- Keep branch splitting from simplifying the entire nested continuation.
set_option backward.split false in
theorem guard_settlement_events_ordinary {state result output : Term} {input journal rest : List Term}
    (safe : RawOrdinaryBatch input)
    (call : Settlement.guardSettlement state result input journal = .ok (output, rest)) :
    output = nil ∨ ∃ events, output = list events ∧ RawOrdinaryBatch events := by
  unfold Settlement.guardSettlement at call
  repeat' first
    | (execution_head_is call "Pure.pure"
       have returned := pure_ok call
       clear call
       rw [returned]
       first | (left; rfl) | (right; refine ⟨_, rfl, ?_⟩))
    | (execution_head_is call "Bind.bind"
       have bound := bind_ok call; clear call; rcases bound with ⟨_, _, _, call⟩)
    | dsimp only at call
    | split at call
  all_goals try unfold_native "VerifiedKernel.Session.Settlement.terminalEvents"
  all_goals try unfold Settlement.withoutWake
  all_goals try simp only [raw_ordinary_append]
  all_goals repeat' first
    | assumption
    | exact raw_ordinary_filter safe _
    | apply And.intro
    | exact ordinary_nil.raw
    | (apply OrdinaryBatch.raw
       simp +decide [OrdinaryBatch, OrdinaryKind, BinaryKeys, Term.get,
         b, Term.text, Term.isBinary]
       repeat' first
         | constructor
         | intro _
         | (rename_i member; rcases member with ⟨rfl, rfl⟩ | member)
         | (rename_i member; rcases member with ⟨rfl, rfl⟩)
         | rfl
       done)
    | split

syntax "solve_raw_batch" : tactic
macro_rules
  | `(tactic| solve_raw_batch) => `(tactic|
    (try simp only [raw_ordinary_append, raw_ordinary_pair]
     repeat' first
       | assumption
       | exact (status_event_ordinary _).raw
       | exact (ack_event_ordinary _ _).raw
       | exact ordinary_nil.raw
       | apply And.intro
       | split))

theorem settlement_batch_events_ordinary {state track unsettled reset router output : Term}
    {input results journal rest : List Term}
    (safe : RawOrdinaryBatch input) (unsettledSafe : RawOrdinaryBatch [unsettled])
    (resetSafe : RawOrdinaryBatch [reset])
    (call : Settlement.batch state (.tuple [list input, list results, track, unsettled, reset, router]) journal =
      .ok (output, rest)) : ∃ events, output = list events ∧ RawOrdinaryBatch events := by
  unfold Settlement.batch at call
  repeat' first
    | (rw [pure_ok call]; refine ⟨_, rfl, ?_⟩; solve_raw_batch)
    | (have bound := bind_ok call; clear call; rcases bound with ⟨value, _, prior, call⟩
       first
         | (execution_head_is prior "VerifiedKernel.Session.Settlement.terminal"
            rcases terminal_events_ordinary (by solve_raw_batch) prior with same | ⟨_, same, _⟩
            <;> subst value)
         | (execution_head_is prior "VerifiedKernel.Session.Settlement.guardSettlement"
            rcases guard_settlement_events_ordinary (by solve_raw_batch) prior with same | ⟨_, same, _⟩
            <;> subst value)
         | (execution_head_is prior "VerifiedKernel.Session.Settlement.onboarding"
            rcases onboarding_events_ordinary (by solve_raw_batch) prior with same | ⟨_, same, _⟩
            <;> subst value)
         | (have same := (asList_ok_iff.mp prior).1; cases same)
         | (have same := pure_ok prior; cases same)
         | skip)
    | unfold Term.default at call
    | split at call

end VerifiedKernel.Session.WorkConservation
