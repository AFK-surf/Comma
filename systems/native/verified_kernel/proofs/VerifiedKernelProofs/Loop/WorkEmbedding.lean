import VerifiedKernelProofs.Loop.HostEvents
import VerifiedKernelProofs.Loop.MachineSafety
import VerifiedKernelProofs.Session.WorkGuardProducers
import VerifiedKernelProofs.Session.WorkNativeProductTrace
import VerifiedKernelProofs.Session.WorkSettlementProducers

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
    Loop.queryAsk s "runaway_retirement" args = Settlement.retireRunaway s :=
  QueryAnswers.runaway_retirement s args
theorem ask_guard_local (s args : Term) :
    Loop.queryAsk s "guard_failure_local_settlement" args = Settlement.guardLocalSettlement s :=
  QueryAnswers.guard_local s args
theorem ask_guard_prepare (s args : Term) :
    Loop.queryAsk s "guard_failure_prepare" args = guardPrepareNative s args :=
  QueryAnswers.guard_prepare s args
theorem ask_guard_cleanup (s args : Term) :
    Loop.queryAsk s "guard_failure_cleanup_events" args = guardCleanupNative s args :=
  QueryAnswers.guard_cleanup s args
theorem ask_finish_output (s args : Term) :
    Loop.queryAsk s "finish_output" args = finishOutputCall s args :=
  QueryAnswers.finish_output s args
theorem ask_settle (s args : Term) :
    Loop.queryAsk s "settle_tool_batch" args = Settlement.batch s args :=
  QueryAnswers.settle s args
theorem ask_wait_timeout (s args : Term) :
    Loop.queryAsk s "wait_timeout_event" args = Command.waitTimeout s args :=
  QueryAnswers.wait_timeout s args
theorem ask_yield (s args : Term) :
    Loop.queryAsk s "provider_wait_yield_events" args = StateQuery.waitYieldEvents s args :=
  QueryAnswers.yield_events s args

theorem ask_onboarding_eq (s args : Term) :
    Loop.queryAsk s "onboarding_settlement" args = (do
      let .tuple [results, events, router] := args | fail "function_clause"
      Settlement.onboarding s (← asList results) (← asList events) router.truthy) :=
  QueryAnswers.onboarding s args

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

theorem notice_record_ordinary (sid aid call : Term) :
    OrdinaryBatch [noticeRecord sid aid call] := by
  unfold noticeRecord; unfold_native "VerifiedKernel.Session.Loop.noticeRecord"; kernel_ordinary

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
    refine raw_ordinary_pair.mpr ⟨(notice_record_ordinary _ _ _).raw, ?_⟩
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
