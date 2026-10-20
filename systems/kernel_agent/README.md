# Kernel agent

Kernel agent is a single-tenant agent runtime with one session and many
conversations. It stores all state on the local filesystem. Its only
dependency is the verified kernel (`systems/native/verified_kernel`).

The runtime tests two claims about the kernel:

- **Completeness.** The kernel decides every branch of the agent loop.
  A host that only moves bytes can run a correct agent.
- **Independence.** The kernel works without `salix_agent` and the other
  Salix applications.

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

| Module | Job |
| --- | --- |
| `Store` | File CAS for the session object. One outbound log per conversation. |
| `Driver` | Kernel revision cursors, fences, and the command driver. |
| `Session` | Input, and the effects of the kernel's session driver: storage, commands, configuration, tools, model calls, and timers. |
| `Tools` | The tool catalog: send to a conversation, and `fs.*` in a workspace. A path must stay in the workspace and must not cross a symbolic link. |
| `LLM` | HTTP to the provider, and a scripted model for tests. |

The session acts as the agent's Router. Each input carries a trusted origin
of kind `internal` `user_chat` that names its conversation. The kernel
derives the reply target from that origin.

The kernel names the storage key and encodes the snapshot. The host writes
the bytes with a compare-and-swap on the SHA-256 ETag.

## What the kernel decides

The kernel alone decides admission, activation, the provider request,
response parsing, the tool-round order, reply admission, settlement, retry,
the round budget, compaction, context overflow, and crash repair. The tests
check the outcomes. The loop, compaction, and repair host queries
(`LoopHost`, `CompactionHost`, `RepairHost`) are described in the
[verified kernel README](../native/verified_kernel/README.md). This runtime
and production `salix_agent` use the same queries.

This runtime runs no background tools and no recoverable envelopes. For the
restart plan, it answers guidance with `:not_recoverable` and raises on
`encode_recovered` and `encode_failed`.

## Session driver

The kernel query `session_step {machine, event, nil}`
(`VerifiedKernel.Session.Drive`) sequences the whole session for this
runtime and for the production session actor. Each step asks the host for
one effect, and the host answers with `{:done, value}`.
`SalixVerifiedKernel.SessionStep` runs each step and keeps large values on
the host side.

| Effect | Host work | Answer |
| --- | --- | --- |
| `:recover`, `{:apply_recovery, recovery}` | Run the `recover` command. Keep the recovery checkpoint. | The command result, or `:ok` |
| `{:commit, events, opts, mode}`, `{:write, events}`, `:fence`, `:refresh` | Stage events and make them durable. | `:ok` |
| `{:plan, mode}` | Materialize the revision. | `{outcome, changed}` |
| `{:command, name, args}` | Run a kernel command (`activate`). | The command result |
| `:round_config`, `{:round_prepare, kind}` | Give the prompt, the compaction facts, and the round configuration. | `{:ok, config}` |
| `{:speculate, args}` | Start the model call beside the activation fence. This runtime does not. | `:sequential` |
| `{:call_model, request, facts}`, `{:call_failed, committed}` | Start the model call in its own process. Log a call that failed. | `:started`, later `{:model, response}` or `{:model_lost, facts}` for a call that ended without a response. `:ok` |
| `{:round, facts}`, `{:build_record, spec}`, `{:run_tools, calls, flags}`, `{:store_results, pending, results}` | Keep the round facts. Run the loop's data effects. | The next loop event |
| `{:compaction_facts, mode}`, `{:compaction_prompt, plan}`, `{:summarize, plan, prompt}` | Give the compaction facts and prompt. Start the summary call. | The facts, the prompts, or `:started`. Later the summary outcome |
| `{:set_timer, kind, data}`, `{:cancel_timer, kind}` | Arm or cancel a timer. | `:ok` |
| `:idle`, `:await`, `:reprocess`, and failures | End the step: wait, or process again. | None |

The host starts processing with `{:process, entry}` after input, a timer, or
a start. The query reader answers `:clock`, `:nonce`, and the reads of crash
repair. The host keeps the machine term between steps. It reads only the
machine's phase. A step that returns an idle machine, or `:await`, has
ended.

The loop proofs cover `loop_step`. No theorem covers the driver. The tests
of both runtimes do.

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

## Known defects

- **A latent missing clause.** `Loop.outputCommitted` can emit
  `{:notify, :effect, _}`. `SalixAgent.Round` has no `notify` clause for it.
  Today the kernel emits only report and activity effects there.
- **Names.** The kernel reads its caps from the `:salix_agent` application
  environment. It tags state with `SalixAgent.InternalSession.State`. A
  standalone host must put configuration under `:salix_agent`.

## Not covered

- Explicit compaction requests, the provider compaction strategy (OpenAI
  Responses), and the recovery file that the recovery summary names. This
  runtime has no provider that compacts.
- Waits (`wait_for`), background tools, speculative dispatch, planned
  admission, streaming, attachments, IFC, Task workers, and provider IM.
- The fast activation path and the overlapped activation. The runtime uses
  only the full processing path.
- Ownership fences. One process owns the session. A CAS conflict is a crash.
- Full crash durability. The store does not sync the directory after a
  rename. A send can repeat after a crash between the send and its result
  commit.
- An atomic workspace check. The symbolic-link check runs before the file
  operation. A link that another process makes between the two is followed.
