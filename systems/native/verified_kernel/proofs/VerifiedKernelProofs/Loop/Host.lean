import VerifiedKernelProofs.Loop.Source
import VerifiedKernelProofs.Session.WorkResident
import VerifiedKernel.Session.PendingRevision

/-! # Host trace model (L3)

This module models the Elixir host that drives `Loop.stepWith Loop.queryAsk`.
The model is nondeterministic. It covers the round host in `round.ex`
(`loop`, `loop_commit`, `perform`), the session driver host in
`internal_session_actor.ex` (`run`, `effect`, `wait_timeout_drive`), which
performs the effects of `session_step`, other storage writers, crashes and
`restart_plan`.
Each transition appends ghost labels to a log. The labels are proof data. They
are not runtime state.

The host keeps three Session states:

* `durable`: the state in storage. Only a successful CAS or fence changes it.
  It never rolls back.
* `baseline`: the durable state that the host revision was read from.
* `working`: the host revision state (`loop_state`). It is `baseline` plus the
  pending writes when `pending` is true.

A failure resets `working` to `baseline`. A crash resets `working` and
`baseline` to `durable`. This follows `WorkProtocol`: durable state never rolls
back, and working state rolls back to durable state.

The model builds in two host contracts:

* H1: a commit lands `landed events opts` on the state that the step read, as
  `ResidentBatch`, and the effects after the commit run only after success.
  The store also scrubs text and stamps lifecycle times. The model does not
  show these rewrites.
* H6: a crash drops the machine and the awaited effect. No transition resumes
  a dropped machine. Recovery commits only the `restart_plan` output.

The model leaves the host answers free (`HostConfig`). The theorems that need
more (H2, H4, the Router fact) state it as hypotheses on `HostConfig`.

Model requests are gated. The ghost field `granted` records a model round
that the host granted and did not start. `materializeRun` (the activation step
returned `{:materialize, mode}` and `plan_revision` returned `run`), `fast`
(the fast activation of the async-terminal continuation) and a `stop` with
`context_overflow` (the host compacts, then starts one round) grant a round.
`request`, the entry of a `model_response` or `model_failure`, needs a granted
round and uses it. A crash drops the grant. `enter` admits every other entry
event. The direct `run_round` call of an operator or a test is not modeled.

Simplifications, each an over-approximation of the host:

* A round can start while the revision has pending writes. The host fences
  or commits them first.
* `commit_planned_results` writes its durable result commits as `env`
  transitions at any time.
* The activation commit of `materialize` is a working write, and `fence`
  makes it durable.
* `refresh` can reread the durable state at any time when no write is
  pending.
* A kernel step that fails, and every host error, is `abort` or `crash`.
* The activation outcome, the fast activation events and the fact answers are
  free (`HostConfig`). A granted round can wait while other entries run.
* A compaction provider call is not a label. The host runs at most one
  compaction before each granted round. -/

namespace VerifiedKernel.Session.LoopProof
open Data
open VerifiedKernel.Session.WorkConservation (ResidentBatch)
set_option Elab.async false

/-! ## Commit effects -/

/-- The `hwm` of a commit option list. `hwmOf (hwmOpts h) = h` for `h ≠ nil`. -/
def hwmOf : Term → Term
  | .list [.tuple [_, hwm]] => hwm
  | _ => nil

/-- The events that storage applies for a commit: the batch, then the `bump_hwm`
event of its `hwm` option (`InternalSession.write_revision/3`). -/
def landed (events : List Term) (opts : Term) : List Term :=
  events ++ PendingRevision.hwmEvents (hwmOf opts)

/-- The commit mode `%{"speculative" => true}` that selects the speculative
branch of `loop_commit`. -/
def specMode (mode : Term) : Bool := mode.isMap && mode.get (b "speculative") == a "true"

/-- `effects` contains no commit. -/
def NoCommit (effects : List Term) : Prop := ∀ events opts mode, commitEffect events opts mode ∉ effects

/-- The first run of the step, on the host revision, has a commit that is not
speculative. Only then does the host enter the CAS path of `loop_commit`. -/
def CasPath (working machine event : Term) : Prop :=
  ∃ machine' pre events opts mode post,
    StepOK Loop.queryAsk working machine event machine' (pre ++ commitEffect events opts mode :: post) ∧
    specMode mode = false

/-! ## Labels -/

/-- The kind of an environment write. -/
inductive EnvKind where
  /-- An input append (`queue_append` of fresh input). -/
  | input
  /-- A background completion, including `commit_planned_tool_results`. -/
  | completion
  deriving DecidableEq

/-- Ghost labels of the host trace. -/
inductive HostLabel where
  /-- A round starts with an entry event and a `nil` machine. A `model_response`
  or `model_failure` entry follows one provider request. A `wait_timeout` entry
  is a fired wait timer. -/
  | enter (event : Term)
  /-- `build_record` returned the record `record` for the spec `spec`. -/
  | record (spec record : Term)
  /-- A durable commit of `events` with the commit mode `mode` (CAS or fence success). -/
  | commit (events : List Term) (mode : Term)
  /-- The host applied `events` to its revision. The write is not durable. -/
  | written (events : List Term)
  /-- The activation commit applied `events` to the host revision. -/
  | activate (events : List Term)
  /-- The host hands the session to one model round. `mode` is the
  `materialize` mode of the activation step, or `fast` for the fast path of
  the async-terminal continuation. -/
  | grant (mode : Term)
  /-- The durable fence of pending writes succeeded. -/
  | fenced
  /-- The host executed `calls` for the assistant message `aid` in `mode`.
  `speculative` is true for the speculative branch of `loop_commit`. -/
  | dispatch (aid calls mode : Term) (speculative : Bool)
  /-- Executed tools returned `results`. -/
  | toolsReturned (results : Term)
  /-- `commit_planned_results` finished. Its durable writes are `env` labels. -/
  | plannedCommitted
  /-- Another writer committed `events`. -/
  | env (kind : EnvKind) (events : List Term)
  /-- Recovery committed the `restart_plan` output `events`. -/
  | restart (events : List Term)
  /-- The round stopped with `outcome`. -/
  | stop (outcome : Term)
  /-- A storage or host operation failed. The round ended. -/
  | failed
  /-- The actor crashed. The loop machine and the awaited effect are lost. -/
  | crash

/-! ## Host state -/

/-- What the host does next. -/
inductive Control where
  /-- No round runs. -/
  | idle
  /-- The host runs the kernel step for `machine` and `event`. -/
  | feed (machine event : Term)
  /-- The host runs `effects`, the rest of a step output. -/
  | perform (machine : Term) (effects : List Term)
  /-- Tools run. The host answers with `tools_done`. -/
  | running (machine calls : Term)

structure HostState where
  durable : Term
  working : Term
  baseline : Term
  pending : Bool
  /-- `host.calls`: the calls of the last tool record. The speculative branch
  executes these calls. -/
  calls : Term
  control : Control
  /-- Ghost: the host has granted one model round that has not started. -/
  granted : Bool := false

/-- The host and environment answers. The model leaves each answer free. The
theorems constrain them with hypotheses. -/
structure HostConfig where
  /-- `build_record`: the host revision state, the spec, and the record. -/
  record : Term → Term → Term → Prop
  /-- Tool execution: the calls and the results. -/
  tools : Term → Term → Prop
  /-- `store_results`: the host revision state, the pending batch, the results,
  and the `results_stored` event. -/
  store : Term → Term → Term → Term → Prop
  /-- The activation commit of `materialize`: the host revision state, the
  mode, the activation events, and the outcome of `plan_revision`. The
  outcome `run` starts a model round. -/
  activation : Term → Term → List Term → Term → Prop
  /-- The fast activation of the async-terminal continuation (the driver's
  `{:process_fast, entry}`): the host revision state and the activation
  events. It always starts a model round. -/
  fast : Term → List Term → Prop
  /-- `{:fact, name}`: the fact name and the host answer. -/
  fact : Term → Term → Prop
  /-- An environment write on the durable state. -/
  env : EnvKind → Term → List Term → Prop
  /-- The `restart_plan` output on the durable state. -/
  restart : Term → List Term → Prop

/-- The initial state: no round runs and the host revision is durable. -/
def HostInit (σ : HostState) : Prop :=
  σ.control = .idle ∧ σ.working = σ.durable ∧ σ.baseline = σ.durable ∧ σ.pending = false

/-- Host answers to blocking effects that carry no ghost label. -/
inductive HostReply (cfg : HostConfig) (working : Term) : Term → Term → Prop where
  /-- `perform(:continue)` re-enters the loop with `continue`. -/
  | continue : HostReply cfg working (a "continue") (a "continue")
  /-- `store_results` runs the workspace commit and answers `results_stored`. -/
  | store {pending results events hwm base stored : Term}
      (answer : cfg.store working pending results (.tuple [a "results_stored", events, hwm, base, stored])) :
      HostReply cfg working (.tuple [a "store_results", pending, results])
        (.tuple [a "results_stored", events, hwm, base, stored])
  /-- `{:fact, name}` answers `{:fact, value}`. -/
  | fact {name value : Term} (answer : cfg.fact name value) :
      HostReply cfg working (.tuple [a "fact", name]) (.tuple [a "fact", value])

/-- An entry event that follows one provider request: `model_response` or
`model_failure`. -/
def modelEntry : Term → Bool
  | .tuple [.atom "model_response", _, _] => true
  | .tuple [.atom "model_failure", _, _] => true
  | _ => false

/-! ## Transitions -/

/-- One host transition with its ghost labels. -/
inductive HostStep (cfg : HostConfig) : HostState → List HostLabel → HostState → Prop where
  /-- `loop(host, event)` and `activation_loop(data, revision, nil, event)`:
  a round starts with a `nil` machine. This entry is not a model response. -/
  | enter {σ : HostState} {event : Term} (idle : σ.control = .idle) (ungated : modelEntry event = false) :
      HostStep cfg σ [.enter event] { σ with control := .feed nil event }
  /-- A model round: the host sent one provider request and enters the loop
  with its `model_response` or `model_failure`. The request needs a granted
  round, and it uses the grant. -/
  | request {σ : HostState} {event : Term} (idle : σ.control = .idle) (model : modelEntry event = true)
      (granted : σ.granted = true) :
      HostStep cfg σ [.enter event] { σ with control := .feed nil event, granted := false }
  /-- `loop/3` when `split_commit` finds no commit: the step runs on the host
  revision and the host performs its effects. -/
  | local {σ : HostState} {machine event machine' : Term} {effects : List Term}
      (feed : σ.control = .feed machine event)
      (step : StepOK Loop.queryAsk σ.working machine event machine' effects)
      (noCommit : NoCommit effects) :
      HostStep cfg σ [] { σ with control := .perform machine' effects }
  /-- `loop_commit` on a clean revision: `commit_revision_dynamic` runs the step
  as the builder on the durable state and applies its commit by CAS. A CAS
  conflict is an `env` transition followed by this one. Retries that run out
  are `abort`. -/
  | commit {σ : HostState} {machine event machine' t mode opts : Term}
      {pre events post : List Term}
      (feed : σ.control = .feed machine event) (clean : σ.pending = false)
      (first : CasPath σ.working machine event)
      (step : StepOK Loop.queryAsk σ.durable machine event machine' (pre ++ commitEffect events opts mode :: post))
      (land : ResidentBatch σ.durable (landed events opts) t) :
      HostStep cfg σ [.commit events mode]
        { σ with durable := t, working := t, baseline := t, control := .perform machine' post }
  /-- `{:error, {:loop_rerouted, next, effects}}`: the step on the durable state
  has no commit. The host reads the revision and performs those effects. -/
  | reroute {σ : HostState} {machine event machine' : Term} {effects : List Term}
      (feed : σ.control = .feed machine event) (clean : σ.pending = false)
      (first : CasPath σ.working machine event)
      (step : StepOK Loop.queryAsk σ.durable machine event machine' effects)
      (noCommit : NoCommit effects) :
      HostStep cfg σ []
        { σ with working := σ.durable, baseline := σ.durable, control := .perform machine' effects }
  /-- `commit_revision_dynamic` on a pending revision: the step runs once on the
  host revision, and the durable fence persists the pending writes and the
  commit by CAS against the baseline. A fence conflict is `abort`. -/
  | fenceCommit {σ : HostState} {machine event machine' t mode opts : Term}
      {pre events post : List Term}
      (feed : σ.control = .feed machine event) (dirty : σ.pending = true)
      (step : StepOK Loop.queryAsk σ.working machine event machine' (pre ++ commitEffect events opts mode :: post))
      (notSpeculative : specMode mode = false)
      (land : ResidentBatch σ.working (landed events opts) t)
      (cas : σ.durable = σ.baseline) :
      HostStep cfg σ [.commit events mode]
        { σ with durable := t, working := t, baseline := t, pending := false, control := .perform machine' post }
  /-- The speculative branch of `loop_commit` with a successful fence: write the
  batch to the revision, start the fence, execute `host.calls`, and await the
  fence. The later `run_tools` effect returns the speculative results without a
  second execution. -/
  | speculative {σ : HostState} {machine event machine' t mode opts calls flags results async : Term}
      {pre events mid : List Term}
      (feed : σ.control = .feed machine event)
      (step : StepOK Loop.queryAsk σ.working machine event machine'
        (pre ++ commitEffect events opts mode :: (mid ++ [runToolsEffect calls flags])))
      (isSpeculative : specMode mode = true)
      (land : ResidentBatch σ.working (landed events opts) t)
      (executed : cfg.tools σ.calls results)
      (cas : σ.durable = σ.baseline) :
      HostStep cfg σ [.written events, .dispatch (mkey flags "aid") σ.calls (mkey flags "mode") true,
          .commit events mode, .toolsReturned results]
        { σ with durable := t, working := t, baseline := t, pending := false,
                 control := .feed machine' (.tuple [a "tools_done", results, async]) }
  /-- The speculative branch with a failed fence: the calls ran, the write is
  lost, and the round ends with an error. -/
  | speculativeFailed {σ : HostState} {machine event machine' t mode opts calls flags : Term}
      {pre events mid : List Term}
      (feed : σ.control = .feed machine event)
      (step : StepOK Loop.queryAsk σ.working machine event machine'
        (pre ++ commitEffect events opts mode :: (mid ++ [runToolsEffect calls flags])))
      (isSpeculative : specMode mode = true)
      (land : ResidentBatch σ.working (landed events opts) t) :
      HostStep cfg σ [.written events, .dispatch (mkey flags "aid") σ.calls (mkey flags "mode") true, .failed]
        { σ with working := σ.baseline, pending := false, control := .idle }
  /-- `perform` and the actor's driver `effect` for `notify`, `set_timer`
  and `cancel_timer`: no loop state changes. -/
  | skip {σ : HostState} {machine effect : Term} {rest : List Term}
      (perform : σ.control = .perform machine (effect :: rest))
      (kind : effectKind effect = .notify ∨ effectKind effect = .setTimer ∨ effectKind effect = .cancelTimer) :
      HostStep cfg σ [] { σ with control := .perform machine rest }
  /-- `{:write, events}` in the actor's driver `effect`: `write_revision`
  applies the events to the revision without storage I/O. -/
  | write {σ : HostState} {machine t : Term} {events rest : List Term}
      (perform : σ.control = .perform machine (writeEffect events :: rest))
      (land : ResidentBatch σ.working events t) :
      HostStep cfg σ [.written events] { σ with working := t, pending := true, control := .perform machine rest }
  /-- `continue`, `store_results` and `{:fact, name}`: the host answers with
  the next event. -/
  | reply {σ : HostState} {machine effect event : Term}
      (perform : σ.control = .perform machine [effect])
      (answer : HostReply cfg σ.working effect event) :
      HostStep cfg σ [] { σ with control := .feed machine event }
  /-- `build_record`: the host builds the record on its revision. A tool record
  sets `host.calls`. -/
  | record {σ : HostState} {machine spec record : Term}
      (perform : σ.control = .perform machine [.tuple [a "build_record", spec]])
      (built : cfg.record σ.working spec record) :
      HostStep cfg σ [.record spec record]
        { σ with calls := (if mkey spec "mode" == b "tools" then mkey spec "calls" else σ.calls),
                 control := .feed machine (.tuple [a "record", record]) }
  /-- `run_tools` without speculative results: the host executes the calls. -/
  | dispatch {σ : HostState} {machine calls flags : Term}
      (perform : σ.control = .perform machine [runToolsEffect calls flags]) :
      HostStep cfg σ [.dispatch (mkey flags "aid") calls (mkey flags "mode") false]
        { σ with control := .running machine calls }
  /-- The executed tools return. The host answers `tools_done`. -/
  | returned {σ : HostState} {machine calls results async : Term}
      (running : σ.control = .running machine calls)
      (executed : cfg.tools calls results) :
      HostStep cfg σ [.toolsReturned results]
        { σ with control := .feed machine (.tuple [a "tools_done", results, async]) }
  /-- `commit_planned_results`: the per-result durable commits are `env`
  transitions. The host then answers `continue`. -/
  | planned {σ : HostState} {machine pending results : Term}
      (perform : σ.control = .perform machine [.tuple [a "commit_planned_results", pending, results]]) :
      HostStep cfg σ [.plannedCommitted] { σ with control := .feed machine (a "continue") }
  /-- `{:materialize, mode}`: the activation commit applies its events to the
  revision. The fence makes them durable. The outcome is not `run`, so no
  model round starts. -/
  | materialize {σ : HostState} {machine mode t outcome : Term} {events : List Term}
      (perform : σ.control = .perform machine [.tuple [a "materialize", mode]])
      (plan : cfg.activation σ.working mode events outcome)
      (land : ResidentBatch σ.working events t) (other : outcome ≠ a "run") :
      HostStep cfg σ [.activate events] { σ with working := t, pending := true, control := .idle }
  /-- `{:materialize, mode}` with the outcome `run` (the driver's `{:plan,
  mode}`, then `activate`): the activation commit applies its events, and the
  host grants one model round. -/
  | materializeRun {σ : HostState} {machine mode t : Term} {events : List Term}
      (perform : σ.control = .perform machine [.tuple [a "materialize", mode]])
      (plan : cfg.activation σ.working mode events (a "run"))
      (land : ResidentBatch σ.working events t) :
      HostStep cfg σ [.activate events, .grant mode]
        { σ with working := t, pending := true, control := .idle, granted := true }
  /-- The fast activation of the async-terminal continuation
  (`process_session/3`, the driver's `{:process_fast, entry}`): the
  activation commit applies its events, and the host grants one model round. -/
  | fast {σ : HostState} {t : Term} {events : List Term}
      (idle : σ.control = .idle) (plan : cfg.fast σ.working events)
      (land : ResidentBatch σ.working events t) :
      HostStep cfg σ [.activate events, .grant (a "fast")]
        { σ with working := t, pending := true, granted := true }
  /-- `{:stop, outcome}` ends the round. After `context_overflow` the host
  compacts and starts one model round (the driver's `compact_round`), so this
  outcome grants a round. -/
  | stop {σ : HostState} {machine outcome : Term}
      (perform : σ.control = .perform machine [.tuple [a "stop", outcome]]) :
      HostStep cfg σ [.stop outcome]
        { σ with control := .idle, granted := σ.granted || outcome == a "context_overflow" }
  /-- `durable_fence` of pending writes, as the driver's `:fence` effect runs it. -/
  | fence {σ : HostState} (idle : σ.control = .idle) (dirty : σ.pending = true)
      (cas : σ.durable = σ.baseline) :
      HostStep cfg σ [.fenced] { σ with durable := σ.working, baseline := σ.working, pending := false }
  /-- `read_revision`: the host reads the durable state. -/
  | refresh {σ : HostState} (clean : σ.pending = false) :
      HostStep cfg σ [] { σ with working := σ.durable, baseline := σ.durable }
  /-- Another writer commits a batch to storage. -/
  | env {σ : HostState} {kind : EnvKind} {t : Term} {events : List Term}
      (plan : cfg.env kind σ.durable events)
      (land : ResidentBatch σ.durable events t) :
      HostStep cfg σ [.env kind events] { σ with durable := t }
  /-- A storage or host operation fails. The round returns an error, and the
  revision drops its pending writes. -/
  | abort {σ : HostState} (busy : σ.control ≠ .idle) :
      HostStep cfg σ [.failed] { σ with working := σ.baseline, pending := false, control := .idle }
  /-- The actor crashes. The machine, the awaited effect and a granted round
  are lost. The next owner reads the durable state. -/
  | crash {σ : HostState} :
      HostStep cfg σ [.crash]
        { σ with working := σ.durable, baseline := σ.durable, pending := false, control := .idle,
                 granted := false }
  /-- Recovery commits the `restart_plan` output. A running call gets a
  synthetic error result. Recovery never dispatches a call again. -/
  | restart {σ : HostState} {t : Term} {events : List Term}
      (idle : σ.control = .idle) (clean : σ.pending = false)
      (plan : cfg.restart σ.durable events)
      (land : ResidentBatch σ.durable events t) :
      HostStep cfg σ [.restart events] { σ with durable := t, working := t, baseline := t }

/-- A finite host trace and its ghost label log. -/
inductive HostRun (cfg : HostConfig) : HostState → List HostLabel → HostState → Prop where
  | refl (σ : HostState) : HostRun cfg σ [] σ
  | step {σ₀ σ σ' : HostState} {log labels : List HostLabel}
      (run : HostRun cfg σ₀ log σ) (next : HostStep cfg σ labels σ') :
      HostRun cfg σ₀ (log ++ labels) σ'

theorem HostRun.single {cfg : HostConfig} {σ σ' : HostState} {labels : List HostLabel}
    (next : HostStep cfg σ labels σ') : HostRun cfg σ labels σ' := by
  simpa using HostRun.step (HostRun.refl σ) next

theorem HostRun.trans {cfg : HostConfig} {σ₀ σ σ' : HostState} {log log' : List HostLabel}
    (first : HostRun cfg σ₀ log σ) (second : HostRun cfg σ log' σ') :
    HostRun cfg σ₀ (log ++ log') σ' := by
  induction second with
  | refl => simpa using first
  | step _ next ih => simpa [List.append_assoc] using HostRun.step ih next

/-- A CAS conflict: another writer commits first, and the same step runs again
on the new durable state. -/
theorem conflict_rerun {cfg : HostConfig} {σ : HostState} {kind : EnvKind} {u machine event machine' t mode opts : Term}
    {other pre events post : List Term}
    (feed : σ.control = .feed machine event) (clean : σ.pending = false)
    (first : CasPath σ.working machine event)
    (plan : cfg.env kind σ.durable other) (intervening : ResidentBatch σ.durable other u)
    (step : StepOK Loop.queryAsk u machine event machine' (pre ++ commitEffect events opts mode :: post))
    (land : ResidentBatch u (landed events opts) t) :
    HostRun cfg σ [.env kind other, .commit events mode]
      { σ with durable := t, working := t, baseline := t, control := .perform machine' post } := by
  have one := HostStep.env (cfg := cfg) plan intervening
  have two := HostStep.commit (cfg := cfg) (σ := { σ with durable := u }) feed clean first step land
  simpa using HostRun.step (HostRun.single one) two

/-! ## Label classes -/

/-- An entry that follows one provider request. -/
def HostLabel.modelRequest : HostLabel → Bool
  | .enter event => modelEntry event
  | _ => false

/-- A fired wait timer. -/
def HostLabel.waitExpired : HostLabel → Bool
  | .enter (.tuple [.atom "wait_timeout", _, _, _]) => true
  | _ => false

/-- Fresh input from another writer. -/
def HostLabel.freshInput : HostLabel → Bool
  | .env .input _ => true
  | _ => false

/-- A background completion. -/
def HostLabel.asyncCompletion : HostLabel → Bool
  | .env .completion _ => true
  | _ => false

end VerifiedKernel.Session.LoopProof
