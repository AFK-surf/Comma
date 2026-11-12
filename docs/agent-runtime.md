# Agent runtime

## Agent and Session

Agents own identity, configuration, and station binding. PostgreSQL stores their configuration and current owner epoch.
Sessions own history and control state. Their actor commits a retained revision through `InternalSessionStore`.
The PostgreSQL transaction holds the Agent shared lock and Session row lock, then checks the captured epoch and expected revision.
Startup and unretained writes load storage. Revision conflicts discard the resident revision.
Activation commits materialization, visible-reply installation, the prompt snapshot, and active status in one transaction.
Fence assistant intent before effects. Replayable reads may overlap that fence.
Conversation, Participant, and login have separate lifecycles.
Passivation can leave Session actors resident. After a new claim, the Server retires local Session actors of older epochs. Session entry and canonical Router Session switches wait for the registered Server's startup. Unfinished startup returns a bounded unavailable error. Unbound actors bind to the current claim. Reclaim preserves Session identity and durable state.
Resolve configuration with the canonical Agent tenant, not a request-supplied owner.
Do not persist a live process or connector-run ID as the stable Agent identity.

Routers coordinate intent and delegate ordinary Worker Tasks.
Role instructions do not replace server tool authorization. See [Tools](tools-integrations.md) and [IFC](verification.md).

## Where a Task runs

A Task names its place with `runs_on`, or leaves it to the Worker's station binding, the Group's default place (`default_task_place`: `salix`, `sandbox`, `station {device_id}`, or `cloud_vm` where it is not retired) and then automatic placement ([TaskPlacement](../systems/apps/salix_im/lib/salix_im/task_placement.ex)). Automatic placement of a runtime-model Task tries an authorized VMM Station, the requesting member's own connected Station, then a sandbox of the Task's own where the Cloud VM is retired, else the Group's Cloudflare Cloud VM. A Loop Task runs inside Salix and takes no default.
Where a Group's Cloud VM is retired (`SalixAgent.Sandboxes.cloud_vm_retired?/1`: `cloud_vm_retired` on the Group or `SALIX_CLOUD_VM_RETIRED`), `runs_on {kind: cloud_vm}`, a Worker binding and a Group default of it are refused (`cloud_vm_retired`, which tells the Router what to give instead). A Group VM on its Agent VMM Host is named as its station (`{kind: station, device_id}`, the VM's device id); for a Cloudflare VM that form is refused too. A retired Cloudflare VM is not woken or made again; machine work goes to a sandbox Task ([Cloud VM stations](architecture/DOMAIN_CONCEPTS.md#cloud-vm-stations)). Elsewhere the Cloud VM serves as before ([compute and devices](compute-devices.md#execution-environments)).

### Cloud VM cutover

Missing L4ES configuration or signer never reopens retired CF execution.

After core rollout, `SalixWeb.Migrations.CloudVMCutover` runs once when `SALIX_CLOUD_VM_RETIRED` is on (`cloud_vm_cutover_v1`). It marks Groups retired and replaces Cloud VM defaults and bindings with sandbox, or the Agent VMM Host's station. It preserves that Host's Tasks. Each open CF Task gets one notice and closes: `ready_for_review` becomes `completed`, others `cancelled`. Only the CF station leaves. The pass requests stops for CF Workloads not archived. Failed records remain refused and count in the marker.

- Kept: Messages, Sessions, execution and billing records. Disposable: CF VM disks. Keep R2 archives read-only for 30 days, then delete them.
- Release: no CF Worker or image publication, drain, or provider wait. Keep teardown credentials until cleanup finishes.
- Check separately: marker `complete`, `failed` 0. Completion alone proves neither full success nor provider stop. Retry failed records with `run/1`.
- Background teardown: 55 min of reconciler retries, then `action_required`. Residual CF resources need operator cleanup, not a release gate.
- Recovery: before cutover, turn the switch off. Afterwards, repair forward.
- Users redo: dependencies, files not pushed or saved to Drive, and closed Tasks as sandbox Tasks.

## Tool calls from a Task's station

The agent in a [sandbox Task](compute-devices.md#coding-sandboxes) calls Salix registry tools as the Task's Worker, over the station's own connection: the station tools `salix_tools` and `salix_call {tool, args}`, and the `comma` command in the sandbox (`comma tools | describe <tool> | call <tool> [--json]`, JSON out), which calls those two tools through the station's MCP endpoint of the session that runs it. The requests are `task.tools` and `task.tool_call` ([station protocol](../systems/station/docs/tasks.md)). No Comma or Salix credential enters the sandbox.
Salix (`SalixWeb.StationTasks.tool_call/2`) takes a call only from a Session taking part in the Task, from the device of the Task's current sandbox, over that Workload generation's connection: another device, Session or a replaced sandbox is an error, as for `task.app_deploy`. Only a sandbox station offers the tools (L4ES starts it with `SALIX_CONNECTOR_JOIN=1`): a person's own machine, a Group's Cloud VM or a VMM Station offers none, and Salix refuses them.
The call runs through `SalixAgent.SessionToolDispatch` as the Worker Agent, with the Worker's own tool disclosure ([SalixAgent.StationToolCalls](../systems/apps/salix_agent/lib/salix_agent/station_tool_calls.ex)): a sandbox calls what a Worker on the Group's Cloud VM or a Station calls in Salix, including `env.*` (with `credential_env`) and `preview.*`, and nothing the Worker could not call. The context is the one the Worker's own round builds (`SalixAgent.RoundConfig`): its tool disclosure, plugin projection and skills under `/.runtime/skills`. `fs.*` is the Worker's files (`/drive/...` is the Workspace's Drive); `im_api.internal.read_conversation` without a `conversation_id` reads this Task's conversation. `im_api.internal.task.create` makes one sandbox Task of the Worker's own ([above](#where-a-task-runs)); its answer names a Task made for this Task's owner and no record's content, so it goes back whatever the mode.
The call acts for the person whose Task it is (its Comma owner, else the Slack or Feishu person in `ifc_requester`), never for the Worker (an agent's id commands no effect, IFC §3.1): its origin is the delegated-principal wrapper `{schedule, "station:<device>", person}` under the Task conversation's label (`SalixAgent.IFC.station_origin/3`, `provider: "schedule"`, the one form the kernel reads a sealed principal from with no Session behind it). Under audit or enforce the activation wire is a Session of one input, the call sealed with that origin; a Task with no person is refused before any dispatch (`no_requester`).
Returning a result to the sandbox is an egress: the Group's one Task Worker holds every Task's files, and a read never filters inside Salix. A labelled result is for the sandbox only when the Task's owner is a reader of its label by the kernel's reading of the Group's facts (`SalixIFC.reader?/3`); a result for someone else, an agent-private one (a read that labelled nothing) or one whose readers are unknown is not (`label_not_this_task`), nor is one the dispatcher did not label at all (`label_unknown`), a tool's own failure text excepted, and so is the answer of `im_api.internal.task.create`, the new Task's id and title. The verdict is archived as an IFC decision and the Group's mode decides as for a round: under enforce the refusal stands and the prepared writes are dropped; under audit it is recorded and the result goes back. A Group with the check off labels nothing and is not affected.
A call's `fs.*` writes commit to the Worker's workspace as a round's do (`SalixAgent.WorkspaceEvents`); `/drive/...` writes take effect as the tool runs; session events are dropped. Bounds: 4 calls in flight per station, arguments at most 1 MiB, a result at most 1 MiB (`truncated` when cut), and an answer within the tool's own timeout plus 5 s, at most 19 minutes (`StationToolCalls.deadline_ms/2`; the station and Codex wait 20 minutes), after which the station is told the call timed out; it may still have taken effect. A refused call answers `{error, message}` (`args_too_large`, `too_many_calls`, `no_requester`); a tool's own failure answers `error: true` with its text. Every call is archived as the Worker's tool call, logged (`station tool call`: Task, session, tool, outcome, duration, result bytes) and counted as `station_tool_call`.

## User dependency liveness

LLMs, compaction, tools, runtimes, and Connectors need bounded lanes, owner identities, deadlines, cancellation, and stale-result fences, and never block core control or another tenant indefinitely.

Late results never revive a cancelled owner or obsolete activation.
Core delivery staging uses a bounded RPC deadline and owner and Session fences.
Model requests have 600 s with retries, Router round requests 300 s.
A stream fails after 120 s without a first SSE event, or 30 s between events (`: keep-alive` comments are not events).
Go Connectors follow this contract. Salix owns liveness.

Unconditional progress excludes S3 and database availability.
Transient errors stay retryable; a storage outage is not poison input.
A bounded dependency error is a valid terminal outcome; unbounded silent retry is not.

## Input, compaction, and continuation

Accepted pending input must survive owner restart and compaction.
Model calls and capacity backoff permit bounded input admission. Storage recovery still blocks it.
Slot release notifies one eligible owner. Watches use the global dependency limit, one per owner. Timers cover missed wakes and full watch sets.
Reports and a thread's requests batch at activation; `ifc.request` picks requester.
Between activations a person precedes other bot, app, schedule, and Loop requests up to 5 min older.
A late provider request or compactor must not drop fresh input.
Keep durable input identity separate from model context.
A summary authorizes no additional disclosure or tool requests.
Compaction preserves runtime label facts through the host transformation.
Manual and automatic compaction share durable continuation boundaries.
Compaction commits an archive target; its worker publishes history and does bounded cleanup. [Storage](storage-search.md) covers sealing, recovery.

A canonical Router in a generic `wait_for` can yield to a queued human request.
A running async tool does not own that slot; its call record and source provenance survive.
Yield neither cancels the tool nor reports its result as the new request's.
Active rounds, `auto_wait`, reply repair, and blocking provider obligations keep their guards.
The yield commit rechecks the wait and transcript after current-source runtime input.
Yield neither ensures progress during storage failure nor interrupts a model request.
Active Routers cannot yield; queue pressure prompts delegation. Answered Slack activations with a person queued only reply, delegate or `end_turn` (`QueueYieldGuard`); an unanswered `done` needs `no_reply` (`UnansweredPersonGuard`).
IM and Comma guards keep queued input and send authorization.

Two consecutive unsettled rounds retire the turn; rounds of only refused (`guidance`) calls do not count.
The next activation names it, so the Router asks its person to resend.
Queued input and accepted async work survive; nothing claims delivery or cancellation. Waits use no rounds.
Guards stop at five identical results (a refused call's input does not count) or `input_round_cap` (120). Without a safe notification path, model or guard failures retire locally. Guard wakes do not reset counters.

## Runtime control and observability

The host owns storage transactions, scheduling, cancellation, transport, external authority, entropy, writes, and presentation effects.
Lean selects each step from observations and returns external requests or terminal results; [Verification](verification.md#shared-executable-kernel-boundary) has the full split.

Later result reads do not replace earlier reader-page bodies: page prefixes stay, provider cache hits are not guaranteed.
Inbound attachments become workspace-file path notes. Only tool reads by image-capable models request image bytes.
Projection cannot mutate the Session. Response acceptance owns those writes.
Request guidance grants no tool authority or delivery guarantee.

Restart planning reconciles durable capability requests with Session executions.
Stored outcomes survive, lookup retries are bounded, tools never re-execute.
Direct-poll results do not wake the model; see [callback recovery](tools-integrations.md#capability-request-recovery).

No transport retry follows successful stream data.
Chat streams need `[DONE]` or a known finish reason, else return retryable `incomplete_stream`.
`length` returns `output_token_limit` before argument validation. Completed invalid arguments are not retryable.
Status and alerts must expose terminal errors.

An archive failure cannot fail the Agent task; [Observability](observability.md) has loss and confidentiality limits.

### Request caching

A request is the stored prompt and context plus the delta that acceptance stores.
Turn rules, miniskill selections, and interaction-tool reminders are stored.
Chat and Responses send later runtime messages as `get_runtime_message` calls.
Anthropic gets runtime state as `system` messages and external content as user text.
Requests show a settled `end_turn` call and result the record omits.
Only kernel-built messages change role; text and external tags cannot.
Compaction, prompt changes, acknowledged attachments, archive advances, and extended tool-result groups can prevent cache reuse.
Tests prove request structure, not live cache hits, cost, or rule-following.
Claude thinking requests set `block_binding` to `drop_block`. The `llm_input_transformations` warning lists drops.

### Working state and durable fences

`InternalSessionStore.write_revision/3` changes an owner-local working Revision without acknowledging storage.
`durable_fence/4` commits the pending delta through PostgreSQL. Conflicts reject the old plan without replay against another owner state.

During bounded settlement, an unknown commit retains its address, expected revision, owner epoch, storage revision, and delta.
The Store settles that same submission without rerunning admission, tools, or workspace effects.
Bounded settlement exhaustion returns `commit_indeterminate` without authority for dependent effects. The Actor discards that command’s working view and reloads before later work. A conflicting committed revision rejects the submission.
The storage revision identifies the submission. It is not a content hash or a second owner.

Existing domain owners handle later work. Durable aliases and frontiers identify accepted inputs. Workspace effects retain their operation identity.
The async terminal owner retains results within its existing retry budget. Recovery reads tool receipts or marks calls interrupted; it never reruns the tool.
A synchronous result without an independent receipt can become interrupted after storage errors; it is not retained indefinitely.
Failed compaction does not adopt its summary; a later attempt reloads and checks the summary and cutoff. Control errors also reload before later work.

Input acknowledgments, including duplicates, and later effects wait for the fence.
A working-state ledger hit cannot confirm durable acceptance.
Only the Store's confirmed durable revision can resume the fence continuation. A successful read alone does not confirm a pending submission.
The first tool fence includes assistant intent and running-call recovery records.

After resolution and authorization, batches of at most four trusted replayable reads can start while persistence runs.
`Tools.replayable_read?/1` owns eligibility. HTTP, plugin, script, mixed, and larger batches dispatch only after intent persists.
Failed persistence cancels speculative dependencies and withholds results. No exactly-once external execution is promised.
The owner joins the fence before another mailbox entry can change the revision.

Provider output stays gated until the fence succeeds.
A completion queues without a wake while a batch sibling still runs. The last settlement wakes and materializes every queued result.
Speculation needs no due sibling settlement, a quiet mailbox, and no LLM, compaction, or reply-backoff hold.

Terminal results without workspace or skill events use the Session checkpoint as their receipt.
Mutations and callback setup keep workspace receipts. Recovery never repeats an interrupted effect automatically.
A failed fence keeps provider output gated, and settlement retry keeps the tool result.
The next activation uses the committed revision without repeating the completed tool.

### Delivery to first model request

A resident owner answers source-frontier queries from its committed revision. Cold sessions read storage.

`RoundConfigPrewarm` starts configuration after Agent classification for a nonresident Session.
Snapshots younger than `round_config_refresh_min_age_ms` (default 2 s) are reused. Older snapshots start one background refresh.
Committed configuration events invalidate the snapshot immediately. Changed runtime or catalog versions rebuild it.
Each activation resolves live provider credentials with the current Agent record. Failed resolution withholds dispatch.
Worker source grants bind per activation. A cached catalog never grants permission to dispatch a tool.
PG input, control, tool-terminal, and wait transactions do not access S3. Activation configuration, skills, credentials, and content retain their existing storage dependencies and failure behavior.

A fresh RPC head that names another owner fences the local ownership cell at its epoch before retry.
See the [TLA+ mapping](../tla/salix/README.md).
Wake returns placement errors. `queued` means the wake was sent, not that processing started.
A failed speculative activation CAS cancels the request and reloads storage.

## Condensed Workspace

With `condensed_workspace_enabled` on, internal Router and Worker Sessions keep the Group's [Condensed Workspace](architecture/DOMAIN_CONCEPTS.md) in context.
Provider state is the seen revision and `compacted_through`. New, compacted, or stale Sessions get the full list next round.
The latest writer gets its tool result instead. Delivery wakes no Session.
Warm Sessions adopt a flag change after a background configuration refresh. Disabling sends one notice.

After a response with tool calls, a parallel task asks `needs_update` and `off_track` about the list, the 16 newest conversation texts, and the tool calls. By owner decision, IFC does not filter it.
The next activation waits until 5 s after the start. A reminder asks to rethink on `off_track`, else to update on `needs_update`.
Failure or a refused budget sends nothing. A kind repeats only after a revision change or three checks.
Answers expire after 10 min or a restart.
The write check shares its [`decide` limits](../systems/apps/salix_agent/lib/salix_agent/decide/limits.ex). `:salix_agent, :condensed_workspace` sets cutoffs.

## Committed work scheduling

Session transactions derive `next_run_at` from the existing immediate-work reasons and persisted deadlines.
Post-commit notifications carry an address and SQL revision. They are hints with no execution authority.
The recovery worker pages due Sessions, Capability expiry, and result delivery within its existing page and time budgets.
A short PostgreSQL dispatch reservation limits duplicate wake requests. It does not consume inputs or change the Session revision.
Owner acquisition still uses the Agent epoch. Startup also pages internal Sessions with work reasons, including work without a deadline.
Wait timeout identity and admission stay in the Session owner. No separate S3 timer registration is required.
