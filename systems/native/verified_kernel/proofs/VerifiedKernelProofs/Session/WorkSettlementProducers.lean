import VerifiedKernelProofs.Session.WorkPresentationProducers
import VerifiedKernelProofs.Session.WorkApplication
import VerifiedKernelProofs.Session.WorkBatch
import VerifiedKernelProofs.Session.WorkMaterializeRouting
import VerifiedKernelProofs.Proof.NativeProducerTactic

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

open StateQuery in
/-- A consumed completion wake becomes the runtime message that materializing it would write. -/
theorem notice_raw_ordinary {sid wake id e : Term} {j r : List Term}
    (h : Settlement.notice sid wake id j = .ok (e, r)) : RawOrdinary e := by
  unfold Settlement.notice at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  have shape := runtime_event_shape h
  unfold StateQuery.runtimeEvent at h
  repeat obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain rfl := pure_ok h
  refine OrdinaryBatch.raw ?_ _ (List.mem_singleton_self _)
  intro event member
  simp only [List.mem_singleton] at member
  subst event
  refine ⟨stringKeyed_binary_keys _, ?_⟩
  rcases shape.2 with t | t <;> rw [t] <;> simp +decide [OrdinaryKind, b, Term.text]

theorem notices_raw_ordinary {sid start : Term} {wakes notices : List Term} {j r : List Term}
    (h : Settlement.notices sid start wakes j = .ok (notices, r)) : RawOrdinaryBatch notices := by
  unfold Settlement.notices at h
  intro e member
  obtain ⟨_, _, _, _, call⟩ := mapM_outputs h e member
  obtain ⟨_, _, _, call⟩ := bind_ok call
  exact notice_raw_ordinary call

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
      | (apply notices_raw_ordinary; assumption)
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
