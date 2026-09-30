# Kernel agent

Kernel agent is a single-tenant agent runtime with one session and many
conversations. It stores all state on the local filesystem. Its only
dependency is the verified kernel (`systems/native/verified_kernel`).

The runtime tests two claims about the kernel:

- **Completeness.** The kernel decides every branch of the agent loop.
  A host that only moves bytes can run a correct agent.
- **Independence.** The kernel works without `salix_agent` and the other
  Salix applications.

The host is kept as small as possible on purpose. Earlier evaluations tagged
each piece of host code that made a decision, or built data that the kernel
then consumed, with a `HOST:` comment. The kernel now owns all of that logic.
The host keeps only I/O and the facts that it owns (see
[Host facts](#host-facts)).

## Run

```sh
cd systems/kernel_agent
mix test
KERNEL_AGENT_API_KEY=... mix kernel_agent.chat --root ./agent-data
```

In the chat task, each input line is `conversation> text`. The default
provider is Anthropic. Use `--protocol chat` and `--base-url` for an
OpenAI-compatible provider.

## Structure

| Module | Lines | Job |
| --- | --- | --- |
| `Store` | 75 | File CAS for the session object. One outbound log per conversation. |
| `Driver` | 160 | Kernel revision cursors, fences, and the command driver. |
| `Session` | 510 | Input, and the effects of the kernel's session driver: storage, commands, configuration, tools, model calls, and timers. |
| `Tools` | 200 | The tool catalog: send to a conversation, and `fs.*` in a workspace. A path must stay in the workspace and must not cross a symbolic link. |
| `LLM` | 115 | HTTP to the provider, and a scripted model for tests. |

The session acts as the agent's Router. Each input carries a trusted origin
of kind `internal` `user_chat` that names its conversation. The kernel
derives the reply target from that origin.

The kernel names the storage key and encodes the snapshot. The host writes
the bytes with a compare-and-swap on the SHA-256 ETag.

## What the kernel decides

The kernel alone decides these behaviors. The tests check their outcomes.

- Admission of input, and duplicate rejection.
- Activation: which queued input runs, and when a turn continues.
- The provider request: the context and the encoded body. The host supplies
  the tool specs.
- Response parsing, and classification of provider errors.
- The tool-round order: intent commits before tools run, and results commit
  before the round continues. The tests check only the result of the order.
- Reply admission: a send to another conversation is refused, and the turn
  stays open.
- Settlement: a reply in `end_turn` settles the turn in one model call.
- Plain final text does not settle a turn. The kernel asks for a decision.
- Human activations run one at a time. Input from another conversation
  waits while a model call runs, and the running response stays current.
- Model-failure retry of provider errors. A crashed model call is recorded
  as `llm_call_failed` at the round's position, as in production, and is not
  retried.
- The round budget: the session parks and sends one failure notice.
- Compaction: when a session compacts, which window it summarizes, the
  summarizing request, how the answer reads, and the events of the commit.
- Context overflow: one compaction recovery per rejected position. When the
  recovery cannot make the request fit, the kernel ends the request with a
  model-failure notice.
- Crash repair: after a kill during a model call, the restart plan closes
  the round and the next activation runs it again. After a kill during a tool
  call, the restart plan gives the call a failure result, and the model
  answers from it.

## Host logic moved into the kernel

The first evaluation found host logic in each loop effect. That logic now
lives in the kernel module `VerifiedKernel.Session.LoopHost` and in the
`call_envelope` operation. In this runtime, each loop effect takes one kernel
query. Production `salix_agent` uses the same queries: `loop_record`,
`tool_batch_events`, `notice_reply_scope`, `call_envelopes`, and, through the
session driver, `round_request`. It keeps its own tool pipeline (catalog,
disclosure, and execution) around `call_envelopes`.

| Effect or step | Kernel query | Production code it replaced |
| --- | --- | --- |
| `store_results` | `tool_batch_events`: result events at consecutive ids, side-effect events, reply-obligation events, and the batch settlement. | `Round.tool_events` and `tool_result_event`, and the event derivation in `ProviderReplyObligation`. |
| `build_record` | `loop_record`: the activation's runtime messages, the assistant event, the intent and activity phase, provider-meta repair, and the terminal-reply scope. | `Round.build_record` helpers (`assistant_event`, usage normalization, provider-meta rewrites), `ContextProviders.activation_commit_events`, and `ActivityEvent.tool_calls_phase`. |
| Failure-notice `run_tools` | `notice_reply_scope`: the scope under which `guardNotice` authorized the notice. | `TerminalReply.context` in the notice path. |
| `run_tools` | `call_envelopes`: envelope decode and envelope enforcement for each call. Both hosts then admit each call with `terminal_reply_admission`. | `Tools.decode_call_envelope` and its wrapper checks. Production keeps its catalog and disclosure checks around the kernel decode. |
| Round entry | `round_request`: the guard-notice entry, or the request and the complete round facts, with the request generation that the record of the response carries. It reads the round with `round_view`. | The `current_source_ids`, `round_presentation`, and `current_turn_source` sequence, and the request built in `SalixAgent.LLM`. |

The kernel's session driver (below) now answers these effects. The `LoopHost` queries have
runtime tests (`test/loop_host_test.exs` in the kernel). The loop proofs
still treat their answers as host data.

## Compaction

The kernel module `VerifiedKernel.Session.CompactionHost` owns compaction.
Production `salix_agent` and this runtime use the same queries. The host
does three things: it projects its model configuration, it runs the model
call, and it commits the events.

| Step | Kernel query | Production code it replaced |
| --- | --- | --- |
| Trigger | `compaction_required?`, `context_overflow_pending?`: a pending overflow recovery, or observed prompt tokens over 0.9 of the window. | `Compaction.automatic_required?` (now `activation_plan`) and `ContextOverflow.pending?`. |
| Admission | `compaction_prepare`: session status, new live messages, the pre-filter, the window, and the failure backoff. It answers with a result, a failure to commit, or a plan. | The `prepare_explicit` and `prepare_automatic` sequence, the configuration fingerprint, and the strategy choice. |
| Request | `compaction_request`: the compactable window without the unfinished activation, the prompt snapshot, inlined attachments, unanswered tool calls dropped, and the instruction. It can also encode the request for the provider. | `llm_summarize_request`, `provider_compact_request`, and `drop_incomplete_tool_requests`. |
| Answer | `compaction_outcome`: the summary between its tags, provider items, a skip, or a failure. | `extract_summary` and `normalize_compaction_outcome`. |
| Commit | `compaction_commit`: the fence against the summarized view, then the summary events, or the failure, backoff, and recovery-summary events. | `compaction_mutation_events`, the failure classification, and `fixed_recovery_summary`. |
| Results | `compaction_result_events`, `context_overflow_failure`: result events for a request that did not run, and the failure after a recovery without progress. | `compact_result_events`, `reason_string`, and the meta of the retired `Round.fail_context_overflow`. |

This runtime compacts before an activation and after a context overflow, as
production does. The summarizing call runs in its own process, so input keeps
arriving. The kernel tests (`test/compaction_host_test.exs`) cover each
query. The loop proofs do not cover compaction.

## Host logic moved into the kernel (second step)

The first evaluation left seven pieces of host logic. Each one is now a
kernel query. This runtime and production `salix_agent` use the same queries.

| # | Host logic | Kernel query | Production code it replaced |
| --- | --- | --- | --- |
| 1 | The step from a materialization that runs a round to the `activate` command. | `activation_plan`: compact first or not, the `activate` arguments, and whether the activation must land before the model call. | The compaction check, the argument tuple, and the guard-disposition check in the Actor's activation paths. |
| 2 | Crash repair before activation. | `guard_recovery`, `capability_observation`, and `restart_encode` (`VerifiedKernel.Session.RepairHost`). The host answers reads through the query reader. | In `Repair`: the runtime failure reply recovery, the capability request classification and its retry budget, and the missing and external-callback result events. |
| 3 | The conversation name in the input text. | `round_request` shows `[conversation <id>]` in front of a user message whose trusted origin sets `show_conversation`. | None. Production builds its source summary in `SalixIM.ConversationDelivery`. |
| 4 | Write validation in the command driver. | `validate_events`. | `State.validate_events` and its validators. |
| 5 | The activity revision of a fence. | `activity_revision`. The host supplies a fresh revision; the kernel keeps the current one while the monitored activity is unchanged. | The activity-revision rule in `InternalSessionStore`. |
| 6 | Configuration passed to kernel calls. | `activation_facts` reads the wait ceiling. `round_facts` builds the facts from the round configuration. | `WaitExtension.ceiling_seconds` and the facts map in `Round.round_facts`. |
| 7 | The model configuration of compaction, and the facts of a round that did not start. | The compaction queries read the provider `cfg`. `round_facts {config, :current, nil}` builds the facts of the current round. | None. Production passes its own compaction `config`, and its round facts use `round_facts`. |

The restart plan also asks for recovered and failed background-tool results
(`encode_recovered`, `encode_failed`) and for envelope guidance. Production
answers them with its async-tool completion and tool catalog code, which the
live paths share. This runtime runs no background tools and no recoverable
envelopes: it answers guidance with `:not_recoverable`, and raises on the
other two requests.

## Session driver

The kernel query `session_step {machine, event, nil}`
(`VerifiedKernel.Session.Drive`) sequences the whole session, for this
runtime and for the production session actor. It runs recovery, crash
repair, the activation decision, materialization, compaction, the `activate`
command, and model rounds. It also drives the agent loop (`loop_step`), and
answers the loop's data effects with the `LoopHost` queries. Each step asks
the host for one effect, and the host answers with `{:done, value}`.
`SalixVerifiedKernel.SessionStep` runs each step: it holds the loop state
and the rebuild input of a round on the host side, so these large values do
not cross the boundary on every step.

| Effect | Host work | Answer |
| --- | --- | --- |
| `:recover`, `{:apply_recovery, recovery}` | Run the `recover` command; keep the recovery checkpoint. | The command result, or `:ok` |
| `{:commit, events, opts, mode}`, `{:write, events}`, `:fence`, `:refresh` | Stage events and make them durable. | `:ok` |
| `{:plan, mode}` | Materialize the revision. | `{outcome, changed}` |
| `{:command, name, args}` | Run a kernel command (`activate`). | The command result |
| `:round_config`, `{:round_prepare, kind}` | Give the prompt, the compaction facts, and the round configuration. | `{:ok, config}` |
| `{:speculate, args}` | Start the model call beside the activation fence. This runtime does not. | `:sequential` |
| `{:call_model, request, facts}`, `{:call_failed, committed}` | Start the model call in its own process; log a call that failed. | `:started`, later `{:model, response}` or `{:model_lost, facts}` for a call that ended without a response; `:ok` |
| `{:round, facts}`, `{:build_record, spec}`, `{:run_tools, calls, flags}`, `{:store_results, pending, results}` | Keep the round facts; run the loop's data effects. | The next loop event |
| `{:compaction_facts, mode}`, `{:compaction_prompt, plan}`, `{:summarize, plan, prompt}` | Give the compaction facts and prompt; start the summary call. | The facts, the prompts, or `:started`; later the summary outcome |
| `{:set_timer, kind, data}`, `{:cancel_timer, kind}` | Arm or cancel a timer. | `:ok` |
| `:idle`, `:await`, `:reprocess`, and failures | End the step: wait, or process again. | None |

The host starts processing with `{:process, entry}` after input, a timer, or
a start. The query reader answers `:clock`, `:nonce`, and the reads of crash
repair. The host keeps the machine term between steps. It reads only the
machine's phase: a step that returns an idle machine, or `:await`, has
ended.

The production actor also answers the effects that this runtime does not
use: the overlapped activation (`:speculate`, `:await_fence`),
the fast activation path, explicit compaction, and Task workers. The loop
proofs cover `loop_step`. No theorem covers the driver; the tests of both
runtimes do.

## Host facts

These answers stay with the host. The kernel asks for them as facts or
effects.

- The canonical Router fact. This runtime's one session is its agent's
  Router.
- The busy state of wait delegates. This runtime has no delegates.
- The session role (`router`), the prompt, and the window of the context.
- The command effects `authorize`, `random`, `draft_clear`, `notify`, and
  `workspace`. They are host I/O.
- Entropy (the round nonce), the provider, and the tool catalog.

## Defects found

- **Kernel atoms.** Many atom literals of the Lean runtime were unknown in
  a VM without `salix_agent`. The count depends on which modules are loaded.
  Some appear in ordinary results, for example `accepted_input` in
  transcript messages. Others are failure reasons, for example
  `unknown_query`. Response decoding uses `:safe`, so this host crashed on
  its first transcript read. The kernel transport now registers every
  identifier-shaped string literal of the Lean runtime at compile time
  (`SalixVerifiedKernel.lean_atoms/0`).
- **Two failure paths for a crashed model call.** Production recorded a
  crashed call in Elixir (`fail_pending_llm`) and did not retry it. This
  runtime classified it as a retryable transport failure. The kernel now
  owns one path, `{:model_lost, facts}`, with the production behavior: it
  records the failure at the round's transcript position, and processes
  again only when input arrived during the call.
- **A latent missing clause.** `Loop.outputCommitted` can emit
  `{:notify, :effect, _}`. `Round.notify/2` has no clause for it. Today the
  kernel emits only report and activity effects there.
- **Names.** The kernel reads its caps from the `:salix_agent` application
  environment. It tags state with `SalixAgent.InternalSession.State`. A
  standalone host must put configuration under `:salix_agent`.

## Not covered

- Explicit compaction requests, the provider compaction strategy (OpenAI
  Responses), and the recovery file that the recovery summary names. The
  kernel builds the provider request and reads its items. This runtime has
  no provider that compacts.
- Waits (`wait_for`), background tools, speculative dispatch, planned
  admission, streaming, attachments, IFC, Task workers, and provider IM.
- The fast activation path and the overlapped activation. The runtime uses
  only the full processing path. That path is sufficient, and the others
  are optimizations.
- Ownership fences. One process owns the session. A CAS conflict is a crash.
- Full crash durability. The store does not sync the directory after a
  rename. A send can repeat after a crash between the send and its result
  commit.
- An atomic workspace check. The symbolic-link check runs before the file
  operation. A link that another process makes between the two is followed.
