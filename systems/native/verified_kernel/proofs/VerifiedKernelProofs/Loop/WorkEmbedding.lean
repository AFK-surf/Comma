import VerifiedKernelProofs.Loop.Shape
import VerifiedKernelProofs.Loop.HostEvents
import VerifiedKernelProofs.Session.WorkSettlementProducers
import VerifiedKernelProofs.Session.WorkGuardProducers
import VerifiedKernelProofs.Session.WorkRevisionExpiry
import VerifiedKernelProofs.Session.WorkMaterializeRouting
import VerifiedKernelProofs.Session.WorkLeanBoundary

/-! # Accepted work in the agent loop (property D)

Every commit and every provider-wait yield write of `Loop.step` is a
`RawOrdinaryBatch`, the batch contract of the accepted-work refinement.

* `loop_commit_ordinary` and `loop_write_ordinary` are step-local. The commit
  theorem needs `MachineSafe` for the input machine, because one commit
  carries a timeout event from the host-held machine.
* `step_machine_safe` and `LoopChain.safe` discharge that premise for every
  machine that the kernel returned and the host passed back unchanged.
* `loop_commit_staging`, `activation_write_staged`, `loop_commit_resident_step`
  and `loop_commit_run` place a loop commit or yield write into `Staging`,
  `ResidentStep` and `NativeProductRun`, so `NativeProductRun.refinement`
  covers histories whose writes are loop commits. `hostWrite` states the host
  contract for its UTF-8 scrubbing and lifecycle timestamps. -/

namespace VerifiedKernel.Session.LoopProof
open Data
open WorkConservation
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem ask_runaway_retirement (s args : Term) :
    Loop.queryAsk s "runaway_retirement" args = Settlement.retireRunaway s := by rfl
theorem ask_guard_local (s args : Term) :
    Loop.queryAsk s "guard_failure_local_settlement" args = Settlement.guardLocalSettlement s := by rfl
theorem ask_guard_prepare (s args : Term) :
    Loop.queryAsk s "guard_failure_prepare" args = guardPrepareNative s args := by rfl
theorem ask_guard_cleanup (s args : Term) :
    Loop.queryAsk s "guard_failure_cleanup_events" args = guardCleanupNative s args := by rfl
theorem ask_finish_output (s args : Term) :
    Loop.queryAsk s "finish_output" args = finishOutputCall s args := by rfl
theorem ask_settle (s args : Term) :
    Loop.queryAsk s "settle_tool_batch" args = Settlement.batch s args := by rfl
theorem ask_wait_timeout (s args : Term) :
    Loop.queryAsk s "wait_timeout_event" args = Command.waitTimeout s args := by rfl
theorem ask_yield (s args : Term) :
    Loop.queryAsk s "provider_wait_yield_events" args = StateQuery.waitYieldEvents s args := by rfl

theorem ask_onboarding_eq (s args : Term) :
    Loop.queryAsk s "onboarding_settlement" args = (do
      let .tuple [results, events, router] := args | fail "function_clause"
      Settlement.onboarding s (← asList results) (← asList events) router.truthy) := by rfl

theorem onboarding_answer {s results events router out : Term} {j j' : List Term}
    (h : Loop.queryAsk s "onboarding_settlement" (.tuple [results, events, router]) j = .ok (out, j')) :
    ∃ rs es j'', results = list rs ∧ events = list es ∧
      Settlement.onboarding s rs es router.truthy j'' = .ok (out, j') := by
  rw [ask_onboarding_eq] at h
  dsimp only at h
  obtain ⟨rs, _, hr, h⟩ := bind_ok h
  obtain ⟨es, _, he, h⟩ := bind_ok h
  obtain ⟨rfl, rfl⟩ := asList_ok_iff.mp hr
  obtain ⟨rfl, rfl⟩ := asList_ok_iff.mp he
  exact ⟨rs, es, _, rfl, rfl, h⟩

theorem batch_args {s e r t u rs ro out : Term} {j j' : List Term}
    (h : Settlement.batch s (.tuple [e, r, t, u, rs, ro]) j = .ok (out, j')) :
    (∃ xs, e = list xs) ∧ ∃ ys, r = list ys := by
  unfold Settlement.batch at h
  dsimp only at h
  obtain ⟨xs, _, hx, h⟩ := bind_ok h
  obtain ⟨ys, _, hy, h⟩ := bind_ok h
  exact ⟨⟨xs, (asList_ok_iff.mp hx).1⟩, ⟨ys, (asList_ok_iff.mp hy).1⟩⟩

/-- Close `OrdinaryBatch` goals over kernel-built event maps. -/
syntax "kernel_ordinary" : tactic
macro_rules
  | `(tactic| kernel_ordinary) => `(tactic|
    (simp +decide [OrdinaryBatch, OrdinaryKind, BinaryKeys, Term.get, b, Term.text, Term.isBinary]
     all_goals repeat' first
       | constructor
       | intro _
       | (rename_i member; rcases member with ⟨rfl, rfl⟩ | member)
       | (rename_i member; rcases member with ⟨rfl, rfl⟩)
       | rfl))

theorem status_idle_ordinary (sid : Term) : OrdinaryBatch [statusIdle sid] := status_event_ordinary sid

theorem ack_ordinary (sid hwm : Term) : OrdinaryBatch [ackEvent sid hwm] := ack_event_ordinary sid hwm

theorem failure_ack_ordinary (sid hwm : Term) : OrdinaryBatch [failureAckEvent sid hwm] := by
  simp only [OrdinaryBatch, List.mem_singleton, forall_eq, failureAckEvent]
  constructor
  · rfl
  · simp +decide [OrdinaryKind, Term.get, b, Term.text]

theorem overflow_ordinary (eventId created hwm seq compacted : Term) :
    OrdinaryBatch [overflowEvent eventId created hwm seq compacted] := by
  unfold overflowEvent; kernel_ordinary

theorem failed_ordinary (eventId info hwm created : Term) :
    OrdinaryBatch [failedEvent eventId info hwm created] := by
  unfold failedEvent; kernel_ordinary

theorem unsettled_ordinary (eventId aid bytes created : Term) :
    OrdinaryBatch [unsettledEvent eventId aid bytes created] := by
  unfold unsettledEvent; kernel_ordinary

theorem reset_ordinary (eventId aid count created : Term) :
    OrdinaryBatch [resetEvent eventId aid count created] := by
  unfold resetEvent; kernel_ordinary

theorem notice_assistant_ordinary (sid aid call : Term) :
    OrdinaryBatch [noticeAssistant sid aid call] := by
  unfold noticeAssistant; kernel_ordinary

theorem wait_set_ordinary (sid wait : Term) : OrdinaryBatch [waitSetEvent sid wait] := by
  unfold waitSetEvent; kernel_ordinary

theorem retire_runaway_ordinary {state output : Term} {journal rest : List Term}
    (call : Settlement.retireRunaway state journal = .ok (output, rest)) :
    output = nil ∨ ∃ events, output = list events ∧ OrdinaryBatch events := by
  unfold Settlement.retireRunaway at call
  repeat' first
    | exact (fail_ok call).elim
    | (execution_head_is call "Pure.pure"; rw [pure_ok call]; left; rfl)
    | (execution_head_is call "Pure.pure"; rw [pure_ok call]; right; refine ⟨_, rfl, ?_⟩
       unfold_native "VerifiedKernel.Session.Settlement.terminalEvents"
       simp only [ordinary_append]
       refine ⟨⟨⟨?_, ?_⟩, ?_⟩, ?_⟩
       · intro event member
         obtain ⟨target, _, rfl⟩ := List.mem_map.mp member
         kernel_ordinary
       all_goals first
         | exact ordinary_nil
         | (split <;> first | exact ordinary_nil | kernel_ordinary)
         | kernel_ordinary)
    | (execution_head_is call "Bind.bind"
       have bound := bind_ok call; clear call; rcases bound with ⟨_, _, _, call⟩)
    | dsimp only at call
    | split at call

theorem guard_local_ordinary {state output : Term} {journal rest : List Term}
    (call : Settlement.guardLocalSettlement state journal = .ok (output, rest)) :
    output = nil ∨ ∃ events, output = list events ∧ OrdinaryBatch events := by
  unfold Settlement.guardLocalSettlement at call
  repeat' first
    | exact (fail_ok call).elim
    | (execution_head_is call "Pure.pure"; rw [pure_ok call]; left; rfl)
    | (execution_head_is call "Pure.pure"; rw [pure_ok call]; right; refine ⟨_, rfl, ?_⟩
       unfold_native "VerifiedKernel.Session.Settlement.terminalEvents"
       kernel_ordinary)
    | (execution_head_is call "Bind.bind"
       have bound := bind_ok call; clear call; rcases bound with ⟨_, _, _, call⟩)
    | dsimp only at call
    | split at call

theorem yield_events_ordinary {state expected output : Term} {journal rest : List Term}
    (call : StateQuery.waitYieldEvents state expected journal = .ok (output, rest)) :
    ∃ events, output = list events ∧ OrdinaryBatch events := by
  unfold StateQuery.waitYieldEvents at call
  repeat' first
    | exact (fail_ok call).elim
    | (execution_head_is call "Pure.pure"; rw [pure_ok call]; refine ⟨_, rfl, ?_⟩; done)
    | (execution_head_is call "Pure.pure"; rw [pure_ok call]; refine ⟨_, rfl, ?_⟩
       first
         | exact ordinary_nil
         | (intro event member
            simp only [List.mem_cons, List.not_mem_nil, or_false] at member
            rcases member with rfl | rfl | rfl
            all_goals exact ⟨stringKeyed_binary_keys _, by
              simp +decide [OrdinaryKind, StateQuery.stringKeyed, Term.get, b, Term.text]⟩))
    | (execution_head_is call "Bind.bind"
       have bound := bind_ok call; clear call; rcases bound with ⟨_, _, _, call⟩)
    | dsimp only at call
    | split at call


theorem finish_output_form {state args out : Term} {j j' : List Term}
    (h : finishOutputCall state args j = .ok (out, j')) :
    ∃ evs o p, out = .tuple [a "ok", list evs, o, p] := by
  simp +decide only [finishOutputCall, Presentation.table, List.lookup, Option.getD,
    String.reduceBEq] at h
  unfold_execution_head h
  run_split
  all_goals exact ⟨_, _, _, rfl⟩

theorem list_ne_nil (xs : List Term) : list xs ≠ nil := fun same => Term.noConfusion same

theorem list_inj {xs ys : List Term} (same : list xs = list ys) : xs = ys := by
  injection same

theorem single_raw {e : Term} (safe : RawOrdinary e) : RawOrdinaryBatch [e] := by
  intro x member
  rw [List.mem_singleton.mp member]
  exact safe

theorem wait_timeout_ordinary {state args ev : Term} {journal rest : List Term}
    (call : Command.waitTimeout state args journal = .ok (ev, rest)) (present : (ev == nil) = false) :
    OrdinaryBatch [ev] := by
  rcases wait_timeout_shape call with rfl | ⟨routed, kind⟩
  · exact absurd present (by decide)
  · intro e member
    rw [List.mem_singleton.mp member]
    exact ⟨routed.1, by rw [kind]; simp +decide [OrdinaryKind, b, Term.text]⟩

theorem final_output_ordinary {state record aid unsettledId created tag outputEvents fopts plan
    onboarding : Term} {events : List Term} {machine : Term}
    (checked : Loop.hostEventsList (wrap (mkey record "leading") ++ [mkey record "assistant"]) = a "ok")
    (finish : Answers state "finish_output"
        (.tuple [mkey record "leading", mkey record "assistant", aid, fact machine "vphase",
          Term.bool (mkey machine "terminal").isMap,
          unsettledEvent unsettledId aid (contentBytes (mkey machine "content")) created])
        (.tuple [tag, outputEvents, fopts, plan]))
    (onboardingCase : ((plan.get (a "onboarding?")).truthy = true ∧ ∃ router : Bool,
          Answers state "onboarding_settlement" (.tuple [list [], outputEvents, Term.bool router]) onboarding) ∨
        ((plan.get (a "onboarding?")).truthy = false ∧ onboarding = nil))
    (committed : (if onboarding.isList then onboarding else outputEvents) = list events) :
    RawOrdinaryBatch events := by
  have hosted := raw_ordinary_append.mp (host_events_raw_ordinary checked)
  obtain ⟨j, j', call⟩ := finish
  rw [ask_finish_output] at call
  obtain ⟨evs, o, p, form⟩ := finish_output_form call
  simp only [Term.tuple.injEq, List.cons.injEq, and_true] at form
  obtain ⟨rfl, rfl, rfl, rfl⟩ := form
  have safe := finish_output_ordinary (fun xs same => by rw [same] at hosted; exact hosted.1) hosted.2
    (unsettled_ordinary _ _ _ _).raw call
  rcases onboardingCase with ⟨_, router, ⟨j1, j2, ob⟩⟩ | ⟨_, rfl⟩
  · obtain ⟨rs, es, j3, _, same, ob⟩ := onboarding_answer ob
    cases list_inj same
    rcases onboarding_events_ordinary safe ob with rfl | ⟨settled, rfl, settledSafe⟩
    · have := list_inj committed
      subst this
      exact safe
    · cases list_inj committed
      exact settledSafe
  · cases list_inj committed
    exact safe

/-- Every commit source commits a raw ordinary batch. The carried timeout event
of a host-held machine is an assumption. -/
theorem commit_source_ordinary {state machine event opts mode : Term} {events : List Term}
    (source : CommitSource state machine event events opts mode)
    (carried : mkey machine "entry" = b "wait_timeout" → RawOrdinary (mkey machine "timeout_event")) :
    RawOrdinaryBatch events := by
  cases source with
  | overflow =>
    exact raw_ordinary_pair.mpr ⟨(overflow_ordinary _ _ _ _ _).raw, (status_idle_ordinary _).raw⟩
  | modelFailure =>
    refine raw_ordinary_append.mpr ⟨raw_ordinary_pair.mpr ⟨(failed_ordinary _ _ _ _).raw,
      (status_idle_ordinary _).raw⟩, ?_⟩
    split
    · exact (failure_ack_ordinary _ _).raw
    · exact ordinary_nil.raw
  | boundaryIdle => exact (status_idle_ordinary _).raw
  | guardRetire events entry retire =>
    obtain ⟨j, j', call⟩ := retire
    rw [ask_runaway_retirement] at call
    rcases retire_runaway_ordinary call with same | ⟨evs, same, safe⟩
    · exact (list_ne_nil _ same).elim
    · cases list_inj same; exact safe.raw
  | guardLocal retire events entry _ _ settle =>
    obtain ⟨j, j', call⟩ := settle
    rw [ask_guard_local] at call
    rcases guard_local_ordinary call with same | ⟨evs, same, safe⟩
    · exact (list_ne_nil _ same).elim
    · cases list_inj same; exact safe.raw
  | notice retire settle reply sid aid disposition callId attempt _ _ _ _ _ _ _ _ _ _ _ _ prepare attemptMap =>
    obtain ⟨j, j', call⟩ := prepare
    rw [ask_guard_prepare] at call
    refine raw_ordinary_pair.mpr ⟨(notice_assistant_ordinary _ _ _).raw, ?_⟩
    rcases guard_prepare_event_ordinary call with rfl | safe
    · cases attemptMap
    · exact safe.raw
  | noticeCleanup now events entry cleanup =>
    obtain ⟨j, j', call⟩ := cleanup
    rw [ask_guard_cleanup] at call
    rcases guard_cleanup_events_ordinary call with same | ⟨evs, same, safe⟩
    · exact (list_ne_nil _ same).elim
    · cases list_inj same; exact safe.raw
  | finalOutput record nmid sid aid unsettledId created tag outputEvents fopts plan onboarding events
      entry phase nextId fresh checked aidIs session finish onboardingCase committed =>
    exact final_output_ordinary checked finish onboardingCase committed
  | intent record nmid entry phase nextId fresh checked =>
    exact host_events_raw_ordinary checked
  | settle hostEvents hwm base stored nmid sid unsettledId unsettledAt resetId resetAt router events
      entry phase nextId fresh checked session settleAnswer =>
    obtain ⟨j, j', call⟩ := settleAnswer
    rw [ask_settle] at call
    obtain ⟨⟨xs, rfl⟩, ⟨ys, rfl⟩⟩ := batch_args call
    obtain ⟨evs, same, safe⟩ := settlement_batch_events_ordinary (host_events_raw_ordinary checked)
      (unsettled_ordinary _ _ _ _).raw (reset_ordinary _ _ _ _).raw call
    cases list_inj same
    exact safe
  | waitExtend => exact (wait_set_ordinary _ _).raw
  | waitTimeoutFresh waitId source timeout entry answer present =>
    obtain ⟨j, j', call⟩ := answer
    rw [ask_wait_timeout] at call
    exact (wait_timeout_ordinary call present).raw
  | waitTimeoutCarried value entry timer => exact single_raw (carried timer)

/-- D, step-local: every commit of a kernel loop step is a raw ordinary batch,
given that a carried timeout event in the machine is ordinary. -/
theorem loop_commit_ordinary {state machine event machine' opts mode : Term} {effects events : List Term}
    (h : StepOK Loop.queryAsk state machine event machine' effects)
    (carried : mkey machine "entry" = b "wait_timeout" → RawOrdinary (mkey machine "timeout_event"))
    (mem : commitEffect events opts mode ∈ effects) : RawOrdinaryBatch events :=
  commit_source_ordinary (step_commit_source h mem) carried

/-- The provider-wait yield writes a raw ordinary batch. -/
theorem loop_write_ordinary {state machine event machine' : Term} {effects events : List Term}
    (h : StepOK Loop.queryAsk state machine event machine' effects)
    (mem : writeEffect events ∈ effects) : RawOrdinaryBatch events := by
  cases step_write_source h mem with
  | yield _ _ _ _ _ entry next identity nextId acked humans yielded nonempty =>
    obtain ⟨j, j', call⟩ := yielded
    rw [ask_yield] at call
    obtain ⟨evs, same, safe⟩ := yield_events_ordinary call
    cases list_inj same
    exact safe.raw

/-! ## The machine invariant

The host holds the loop machine between steps. The only machine field that a
commit carries unchanged is the timeout event of a `wait_timeout` entry.
Every machine that the kernel returns keeps that event ordinary. -/

theorem single_raw_inv {e : Term} (safe : RawOrdinaryBatch [e]) : RawOrdinary e := safe e (by simp)

theorem raw_ordinary_non_map {v : Term} (plain : v.isMap = false) : RawOrdinary v := by
  intro normalized journal rest call
  unfold shallowStringify at call
  obtain ⟨xs, _, read, _⟩ := bind_ok call
  cases v <;> simp_all [entries, Term.isMap, fail, throw, throwThe, MonadExceptOf.throw, StateT.lift,
    Functor.map, Except.map]

/-- The carried timeout event of a machine whose entry is `wait_timeout` is ordinary. -/
def MachineSafe (machine : Term) : Prop :=
  mkey machine "entry" = b "wait_timeout" → RawOrdinary (mkey machine "timeout_event")

def SafeOut (out : Term) : Prop := ∃ machine effects, out = .tuple [machine, list effects] ∧ MachineSafe machine

theorem mkey_map_cons (k k' : String) (v : Term) (rest : List (Term × Term)) :
    mkey (Term.map ((b k, v) :: rest)) k' = if k = k' then v else mkey (Term.map rest) k' := by
  simp only [mkey_eq_get, Term.get, List.find?_cons, binary_key_beq]
  by_cases same : k = k'
  · simp [same]
  · have ne : (k == k') = false := by simpa using same
    simp [ne, same]

theorem mkey_map_nil (k : String) : mkey (Term.map []) k = nil := rfl

theorem safe_nil_entry {m : Term} (absent : mkey m "entry" = nil) : MachineSafe m := by
  intro he
  rw [absent] at he
  cases he

syntax "safe_norm" : tactic
macro_rules
  | `(tactic| safe_norm) => `(tactic|
    (try simp (disch := decide) only [loop_key_mkey, loop_phase_put, mkey_put_same, mkey_put_other,
      mkey_map_cons, mkey_map_nil, ↓reduceIte] at *))

syntax "close_safe" : tactic
macro_rules
  | `(tactic| close_safe) => `(tactic|
    (refine ⟨_, _, rfl, ?_⟩
     unfold MachineSafe
     try split
     all_goals
       safe_norm
       first
         | assumption
         | (intro he; cases he)
         | (intro _; exact raw_ordinary_non_map rfl)))

theorem guardOutcome_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% guardOutcome) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop guardOutcome
  run_split
  all_goals close_safe

theorem park_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% park) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop park
  run_split
  all_goals first
    | close_safe

theorem guardNotice_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% guardNotice) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop guardNotice
  unfold_loop finalStop
  run_split
  all_goals first
    | close_safe

theorem noticeCleanup_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% noticeCleanup) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop noticeCleanup
  run_split
  all_goals first
    | close_safe

theorem finalize_safe {state m out : Term} {terminal : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% finalize) Loop.queryAsk state m terminal j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop finalize
  run_split
  all_goals first
    | close_safe

theorem finalRecord_safe {state m out : Term} {record : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% finalRecord) Loop.queryAsk state m record j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop finalRecord
  run_split
  all_goals first
    | close_safe
    | exact finalize_safe safe h
    | exact finalize_safe safe prior

theorem modelFailure_safe {state m out : Term} {info : Term} {recover : Bool} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% modelFailure) Loop.queryAsk state m info recover j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop modelFailure
  run_split
  all_goals first
    | close_safe

theorem modelFailed_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% modelFailed) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop modelFailed
  run_split
  all_goals first
    | close_safe

theorem toolTurn_safe {m out : Term} {outcome : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% toolTurn) m outcome j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop toolTurn
  run_split
  all_goals first
    | close_safe

theorem intentRecord_safe {state m out : Term} {record : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% intentRecord) state m record j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop intentRecord
  run_split
  all_goals first
    | close_safe
    | exact toolTurn_safe safe h
    | exact toolTurn_safe safe prior
    | (obtain ⟨_, rfl⟩ := advance_ok (hyp% (loop% advance) m _ _ _ = _)
       obtain ⟨_, rfl⟩ := advance_ok (hyp% (loop% advance) _ _ _ _ = _)
       close_safe)

theorem toolsDone_safe {state m out : Term} {results async : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% toolsDone) Loop.queryAsk state m results async j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop toolsDone
  run_split
  all_goals first
    | close_safe
    | (obtain ⟨_, rfl⟩ := advance_ok (hyp% (loop% advance) m _ _ _ = _)
       close_safe)

theorem resultsStored_safe {state m out : Term} {events hwm base stored : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% resultsStored) Loop.queryAsk state m events hwm base stored j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop resultsStored
  run_split
  all_goals first
    | close_safe

theorem safe_after_park {next parked : Term} {prefix_ : List Term}
    (parkOut : SafeOut (.tuple [next, parked])) : SafeOut (.tuple [next, list (prefix_ ++ wrap parked)]) := by
  obtain ⟨m, effs, same, safe⟩ := parkOut
  simp only [Term.tuple.injEq, List.cons.injEq, and_true] at same
  obtain ⟨rfl, _⟩ := same
  exact ⟨_, _, rfl, safe⟩

theorem outputCommitted_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% outputCommitted) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  have safe' := safe
  unfold MachineSafe at safe
  unfold_loop outputCommitted
  run_split
  all_goals first
    | close_safe
    | exact safe_after_park (park_safe safe' prior)

theorem continuation_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% continuation) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  have safe' := safe
  unfold MachineSafe at safe
  unfold_loop continuation
  run_split
  all_goals try (obtain ⟨_, rfl⟩ := advance_ok (hyp% (loop% advance) m _ _ _ = _))
  all_goals first
    | close_safe
    | (refine safe_after_park (park_safe ?_ prior)
       unfold MachineSafe
       safe_norm
       exact safe)

theorem expire_safe {state m busy out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% expire) state m busy j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop expire
  run_split
  all_goals try split_decide
  all_goals run_split
  all_goals close_safe

theorem expireEntry_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% expireEntry) state m j = .ok (out, j')) : SafeOut out := by
  have safe' := safe
  unfold MachineSafe at safe
  unfold_loop expireEntry
  run_split
  all_goals first
    | close_safe
    | (refine expire_safe ?_ h
       unfold MachineSafe
       safe_norm
       exact safe)

theorem activation_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% activation) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop activation
  run_split
  all_goals first
    | close_safe
    | (refine expireEntry_safe ?_ h
       unfold MachineSafe
       safe_norm
       exact safe)

theorem timeoutEntry_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% timeoutEntry) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop timeoutEntry
  run_split
  all_goals first
    | close_safe
    | (refine expireEntry_safe ?_ h
       unfold MachineSafe
       safe_norm
       intro _
       have call := (hyp% Loop.queryAsk state "wait_timeout_event" _ _ = _)
       rw [ask_wait_timeout] at call
       exact single_raw_inv (wait_timeout_ordinary call (not_true_false ‹_›)).raw)

theorem classify_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% classify) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  have safe' := safe
  unfold MachineSafe at safe
  open_classify
  -- Select the helper lemma by the execution head. A failed `exact` against another helper
  -- unfolds both helper bodies before it fails.
  all_goals first
    | (execution_head_is h "VerifiedKernel.Session.Loop.finalize"; refine finalize_safe ?_ h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.toolTurn"; refine toolTurn_safe ?_ h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.modelFailure"; refine modelFailure_safe ?_ h)
    | (execution_head_is prior "VerifiedKernel.Session.Loop.finalize"; refine finalize_safe ?_ prior)
    | (execution_head_is prior "VerifiedKernel.Session.Loop.toolTurn"; refine toolTurn_safe ?_ prior)
    | (execution_head_is prior "VerifiedKernel.Session.Loop.modelFailure"
       refine modelFailure_safe ?_ prior)
  all_goals first
    | exact safe'
    | (unfold MachineSafe
       safe_norm
       exact safe)

theorem step_safe_out {state machine event out : Term} {j j' : List Term} (safe : MachineSafe machine)
    (h : Loop.stepWith Loop.queryAsk state (.tuple [machine, event]) j = .ok (out, j')) : SafeOut out := by
  have safe' := safe
  unfold MachineSafe at safe
  unfold Loop.stepWith at h
  unfold_loop finalStop
  run_split
  all_goals first
    | (execution_head_is h "Pure.pure"; close_safe)
    | close_safe
    | (execution_head_is h "VerifiedKernel.Session.Loop.finalRecord"
       exact finalRecord_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.intentRecord"
       exact intentRecord_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.toolsDone"
       exact toolsDone_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.resultsStored"
       exact resultsStored_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.expire"
       exact expire_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.classify"
       exact classify_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.outputCommitted"
       exact outputCommitted_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.modelFailed"
       exact modelFailed_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.noticeCleanup"
       exact noticeCleanup_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.guardOutcome"
       exact guardOutcome_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.continuation"
       exact continuation_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.guardNotice"
       refine guardNotice_safe ?_ h
       first
         | exact safe'
         | (refine safe_nil_entry ?_
            safe_norm
            simp))
    | (execution_head_is h "VerifiedKernel.Session.Loop.modelFailure"
       refine modelFailure_safe (safe_nil_entry ?_) h
       safe_norm
       simp)
    | (execution_head_is h "VerifiedKernel.Session.Loop.activation"
       refine activation_safe ?_ h
       first
         | exact safe'
         | (intro he
            safe_norm
            simp only [↓reduceIte, show ("round" = "entry") = False from by decide] at he
            exact absurd he (binary_ne (by decide)))
         | (unfold MachineSafe
            safe_norm
            exact safe))
    | (execution_head_is h "VerifiedKernel.Session.Loop.timeoutEntry"
       refine timeoutEntry_safe ?_ h
       first
         | exact safe'
         | (intro _
            refine raw_ordinary_non_map ?_
            safe_norm
            simp [nil, Term.isMap]))

/-- The kernel keeps every machine it returns safe: a carried timeout event is
ordinary. -/
theorem step_machine_safe {state machine event machine' : Term} {effects : List Term}
    (h : StepOK Loop.queryAsk state machine event machine' effects) (safe : MachineSafe machine) :
    MachineSafe machine' := by
  obtain ⟨j, j', h⟩ := h
  obtain ⟨m, effs, same, safeOut⟩ := step_safe_out safe h
  simp only [Term.tuple.injEq, List.cons.injEq, and_true] at same
  rw [same.1]
  exact safeOut

/-- The machine before the first event is safe. -/
theorem initial_machine_safe : MachineSafe nil := fun he => Term.noConfusion he

/-- Machines that the host passes back unchanged, starting from `nil`. This is
the machine-integrity assumption: the host never edits a loop machine. -/
inductive LoopChain : Term → Prop
  | initial : LoopChain nil
  | step {state machine event machine' : Term} {effects : List Term}
      (prior : LoopChain machine) (h : StepOK Loop.queryAsk state machine event machine' effects) :
      LoopChain machine'

theorem LoopChain.safe {machine : Term} (chain : LoopChain machine) : MachineSafe machine := by
  induction chain with
  | initial => exact initial_machine_safe
  | step _ h ih => exact step_machine_safe h ih

/-- D, step-local: every commit of a kernel loop step on a machine that the
kernel produced is a raw ordinary batch. -/
theorem loop_chain_commit_ordinary {state machine event machine' opts mode : Term}
    {effects events : List Term} (chain : LoopChain machine)
    (h : StepOK Loop.queryAsk state machine event machine' effects)
    (mem : commitEffect events opts mode ∈ effects) : RawOrdinaryBatch events :=
  loop_commit_ordinary h chain.safe mem

/-! ## Embedding into the accepted-work refinement -/

section
open WorkConservation.CurrentExecution CommandDriver ArchivePublication
/-- D: a loop commit that the host writes to the working revision is an
ordinary staging step. `hostWrite` is the host contract: the host transforms
the committed events into `written` (UTF-8 scrubbing and lifecycle timestamps)
without changing their batch classification. -/
theorem loop_commit_staging {state machine event machine' opts mode hwm : Term}
    {effects events written : List Term} {objects : ArchivePublication.Objects} {cursor : Revision.Cursor}
    {next : PendingRevision.Cursor}
    (h : StepOK Loop.queryAsk state machine event machine' effects)
    (carried : mkey machine "entry" = b "wait_timeout" → RawOrdinary (mkey machine "timeout_event"))
    (mem : commitEffect events opts mode ∈ effects)
    (hostWrite : RawOrdinaryBatch events → RawOrdinaryBatch written)
    (write : PendingRevision.Execution
      (PendingRevision.resident (some cursor.candidate.pack) (a "write") (.tuple [list written, hwm])) next) :
    Staging objects cursor objects (.pending next) :=
  .ordinary (hostWrite (loop_commit_ordinary h carried mem)) write

/-- The provider-wait yield write, followed by any staging from the written
revision (for example the plan and the activation CAS), is one staging
execution. -/
theorem activation_write_staged {state machine event machine' hwm : Term}
    {effects events written : List Term} {objects last : ArchivePublication.Objects} {cursor finish : Revision.Cursor}
    {middle : PendingRevision.Cursor}
    (h : StepOK Loop.queryAsk state machine event machine' effects)
    (mem : writeEffect events ∈ effects)
    (hostWrite : RawOrdinaryBatch events → RawOrdinaryBatch written)
    (write : PendingRevision.Execution
      (PendingRevision.resident (some cursor.candidate.pack) (a "write") (.tuple [list written, hwm])) middle)
    (rest : Staging objects (.pending middle) last finish) :
    Staging objects cursor last finish :=
  .trans (.ordinary (hostWrite (loop_write_ordinary h mem)) write) rest

/-- A loop commit that lands by CAS is a resident store step. -/
theorem loop_commit_resident_step {versions : VersionBytes} {state machine event machine' opts mode hwm : Term}
    {effects events written : List Term} {before : ResidentWorld} {after : HotStore}
    {source : CapturedRevision} {next : PendingRevision.Cursor} {continuation outcome : Term} {etag : ByteArray}
    (h : StepOK Loop.queryAsk state machine event machine' effects)
    (carried : mkey machine "entry" = b "wait_timeout" → RawOrdinary (mkey machine "timeout_event"))
    (mem : commitEffect events opts mode ∈ effects)
    (hostWrite : RawOrdinaryBatch events → RawOrdinaryBatch written)
    (captured : source ∈ before.captured)
    (write : PendingRevision.Execution
      (PendingRevision.resident (some source.cursor.candidate.pack) (a "write") (.tuple [list written, hwm])) next)
    (submission : WriteSubmission (Revision.Cursor.pending next).candidate continuation)
    (cas : HotCAS before.store.hot
      (.tuple [a "cas", submission.requestedKey, submission.requestedBytes, submission.requestedBase])
      (.tuple [a "ok", .binary etag, outcome]) after)
    (tokens : after.versioned versions) :
    ResidentStep versions before
      ⟨⟨after, before.store.objects⟩,
        ⟨source.owner, source.session, .committed submission.stamped (.binary etag)⟩ :: before.captured⟩ :=
  .commit captured (loop_commit_staging h carried mem hostWrite write) submission cas tokens


/-- A loop commit extends a native product run by one store step, so
`NativeProductRun.refinement` covers histories whose writes are loop commits. -/
theorem loop_commit_run {framing : CodecFraming} {versions : VersionBytes}
    {codec : SnapshotCodec}
    {roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded])}
    {before : ResidentWorld} {past : List ResidentWorld} {prior : ResidentReachable versions before past}
    {receipts : List ProductReceipt} {labels : List ProductLabel}
    {state machine event machine' opts mode hwm : Term}
    {effects events written : List Term} {after : HotStore}
    {source : CapturedRevision} {next : PendingRevision.Cursor} {continuation outcome : Term} {etag : ByteArray}
    (run : NativeProductRun (framing := framing) codec roundtrip prior receipts labels)
    (chain : LoopChain machine)
    (h : StepOK Loop.queryAsk state machine event machine' effects)
    (mem : commitEffect events opts mode ∈ effects)
    (hostWrite : RawOrdinaryBatch events → RawOrdinaryBatch written)
    (captured : source ∈ before.captured)
    (write : PendingRevision.Execution
      (PendingRevision.resident (some source.cursor.candidate.pack) (a "write") (.tuple [list written, hwm])) next)
    (submission : WriteSubmission (Revision.Cursor.pending next).candidate continuation)
    (cas : HotCAS before.store.hot
      (.tuple [a "cas", submission.requestedKey, submission.requestedBytes, submission.requestedBase])
      (.tuple [a "ok", .binary etag, outcome]) after)
    (tokens : after.versioned versions) :
    NativeProductRun (framing := framing) codec roundtrip
      (.next prior (loop_commit_resident_step h chain.safe mem hostWrite captured write submission cas tokens))
      receipts labels :=
  .store run (loop_commit_resident_step h chain.safe mem hostWrite captured write submission cas tokens)

end

end VerifiedKernel.Session.LoopProof
