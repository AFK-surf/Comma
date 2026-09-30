# Tools and integrations

[UI](clients.md#chat-dynamic-ui).

## Admission and disclosure

Admission owns access. Test it. Resolve sources/destinations before dispatch. See IFC help.
Keep secrets out of catalogs, logs, clients and user redirects.
[Private templates](billing-models.md) and [Composio](identity-security.md#composio-trigger-authorization).
MCP: discover via `mcp.list`. Management, Calendar, inbound API, SSH and labels: discover via `help` namespaces. No hidden tools.

Common schemas preload; others use `help`. Session filters and Task/voice exceptions apply. Native schemas stay full.

## Plugin and remote authorization boundaries

Reuse SDK/auth owners. Bind OAuth enrollment to tenant/operation.
Check the installed connection and scope at execution. Listings and stale status grant no access.
Separate approval, callback, credential storage, and dispatch.
Bound integration errors. Preserve unrelated Agent control.

`resources/salix-system-files/skills/` supplies read-only built-ins below stored user skills. See [miniskills](architecture/DOMAIN_CONCEPTS.md#miniskill-activation).

### Comma plugin authorization

Comma Dev uses loopback mocks. Remote rejection cannot interrupt OAuth.
The signed-in window verifies every two seconds, one request at a time, also outside Plugins.
Sign-out stops checks. Each request has 30 seconds within a two-minute attempt.
Timeout releases Add. Late responses cannot replace new attempts. Focus can check early; completion returns Home in the starting workspace.

Composio keeps old accounts until a verified install retires older active accounts in the same group and toolkit.
Other toolkits and newer or undated accounts remain. Cleanup errors do not fail the install.
Owners confirm old accounts for personal use. Comma checks group, toolkit, active status, and self identity at display and confirmation.
The receipt pins the account. Newer accounts cannot replace it; unavailable accounts fail collection.
Confirmation queues source sync and one Routine run, even for the same source ID.
Reconnect keeps the old account and receipt until the new grant completes. Then it retires only that account.
Drive is optional; Gmail and Calendar are required. Settings links to Plugins. Display status grants no access.

GitHub, Linear, Notion, and Slack use Salix OAuth for APIs and recommendations. Notion alone needs separate MCP OAuth.
Linear requests `read` and `write`.
Native reauthorization gives the OAuth callback the attempt's two-minute deadline.
The callback checks generation before binding writes. Cancellation keeps old access if it wins; otherwise it conflicts.
Comma connects `setup.required_connections` in order and installs after all complete. MCP callbacks match the plugin and group.
App credentials use tenant overrides or defaults. Grants remain group-scoped.
Recommendation reads retain scope, refresh, count, concurrency, timeout, and output bounds.
Native sources need no Composio setup. Active managed Slack replaces old Composio sources and keeps their enabled choice.
Other saved Composio sources or consents require Composio. Discovery errors block sync.
Migration keeps choices, old accounts, and unrelated connections. Reauthorize old native grants.
Removal disconnects declared native credentials. Clean old Composio accounts separately.

`compute.exec`, `process.start`, connector `env.exec` and `web.http_request` accept `credential_env` references.
After Workload authorization, Salix resolves them into that subprocess's environment.
VMM Host/Guest Exec transports values without storing them in container configuration. Later commands need their own references.
Agents must never put tokens in commands, files, or tool arguments.

## Capability request recovery

`CapabilityRequests` owns status, expiry, and the winning result. Session owns execution and result publication.
The request owner stores its terminal result before callback delivery. Recovery reuses it after interrupted delivery or async-start commit.
Completed executions stay discoverable until the request owner confirms termination.
Late completions cannot replace terminal results. Recovery never reexecutes the tool.
Direct internal calls persist execution addresses before dispatch.

Replay preserves expiry; without one, requests expire 120 seconds after creation.
Missing execution deadlines require a request lookup, not assumed expiry.
Approval decisions differ from authorization receipts. Only the original decision winner can issue an IFC receipt.
After 30 seconds of unknown results, recovery records that uncertainty and never reissues the receipt, including after consumption.

Each Session projects its earliest callback deadline into the work index.
With eager work, its capability candidate stays in the deadline lane at recovery time zero, avoiding delays behind unrelated eager pages.
Recovery sweeps every 10 seconds, independent of model waits and input: 100 indexed candidates per page, 500 ms wake timeout, 2 second wake budget, rotating eager/deferred cursors.
Backlog or unavailable dependencies preclude a global 30 second recovery guarantee.
Failed settlement retains the durable candidate. After owner loss, Recovery rereads the Session and stored result without new input or in-memory retries.
Existing candidates retain their lane until Session write or recovery. No schema cutover is required.
Failed lookups retry after 5 seconds. After 30 seconds of observed lookup failure, execution ends with `capability_request_unavailable`.
Failed synchronization remains recorded without further scheduled retries or claimed expiry.
After dependency recovery, later activation or operator wake can retry that exact cleanup.

### Runtime failure notification

Reply identity uses the accepted human source and trusted target; context source IDs retain provenance.
Non-runaway model/guard failures use the authorized notification path when safe. With no destination or unsafe foreign-work cleanup, they record local blocked retirement and ACK only materialized input, without a send. Blocking cards and pending visible commits prevent this fallback; queued input and accepted work retain their lifecycles. The separate two-round runaway policy remains unchanged.

Reserve before sending. Committed attempts never resend; refused/unknown outcomes are not delivery proof. Pending work retains its source and cards. Background completion can resume it; no-wake context cannot. Fixed notification text omits provider errors and credentials. Each queued human input grants at most one bounded retry, without borrowing authority or permitting another notice.

`force_recover` reports `command_recorded`, `processing_observed` (a subsequent model response), or `blocked`. Wake acknowledgement and active status are not evidence of model progress. The immediate observation is conservative, not a delivery guarantee. Failed activations use their existing settlement path instead of injecting another recovery message.

## IM providers

Salix owns provider connections, normalized Messages, Participants, and dispatch. Product entry points own authorization and setup progress.
Slack threads, Telegram chats, and Feishu conversations do not replace canonical Salix identity.

Adapters own formatting. Native mentions use provider IDs, not arbitrary names.
Provider retries use idempotent admission. External send confirmation differs from model completion and canonical append.
Bound Slack concurrency and retries. Do not poll every Task or Participant for card updates.
See [Slack command threads and receipt lifecycle](architecture/DOMAIN_CONCEPTS.md#slack-command-source-receipts).

Triage has its own product admission contract. See [Bridge For Teams](bridge-for-teams/design.md).
See [Messaging and voice](messaging-voice.md) for iMessage, WeChat, Telegram, Signal and voice.
Message-search visibility is checked after ranking and before content return. See [Storage](storage-search.md).

## Agent browser use

`browser.*` uses Cloudflare Browser Run through Playwright CDP. Configure global defaults and tenant overrides at `/dash/browser`.
The Browser panel streams frames and accepts mouse and keyboard input after takeover.
See [browser settings, control, and recovery](storage-search.md#browser-run-settings-and-runtime-resources).

## Chat device browsing

Telegram `/devices` edits one message: details, refresh, pages. No links.
WeChat `设备列表`: quoted numbers or marked commands.
Each action reauthorizes the binding and reads six devices or one detail through `Comma.Devices`. No polling.
Check/expiry times shown. Restart expired lists.
WeChat links require login and Workspace confirmation. No permission edits.
Interrupted WeChat replies may repeat.

## HTTP JSON API requests

`web.http_request` sends one request to a public HTTP JSON API with the caller's method, headers, query and body. Model rounds, `script.run` and background Loops share it through session tool dispatch as public egress.
Tokens never enter arguments: `credential_env` references fill `${NAME}` placeholders in header and query values.
Loopback, private, link-local and other special addresses and internal names are refused, pinning the connection to the checked address. No redirects or retries; a non-2xx status is a result.

### Outbound SSH

`ssh.*` tools (PTY, exec, SFTP) use the Group SSH key and this policy, or Tailcat via trusted relays. See [Outbound SSH Session](architecture/DOMAIN_CONCEPTS.md#outbound-ssh-session).

## Files and command environments

A local path is not a shareable attachment or a remote command environment.
Resolve the owning device/environment and authorized file source before access.
Use stable device and environment IDs, then resolve the current live transport.
An external Agent runtime binding targets a stable discovered runtime, not the current socket.
See [Compute and devices](compute-devices.md).

## Verification

Retain authorization, OAuth ownership, interruption, provider-error, rendering, and delivery tests. Source-string inventories cannot prove these boundaries.
Tool definitions and adapter tests define the API.

## Internal host location deadlines

Each internal `location.request` registers a durable timer before the tool returns `running`.
The capability request selects one terminal outcome through CAS. A late host response cannot replace an expired outcome.
The timer delivers that outcome through the session-owned async completion path, then removes its marker.
Storage or delivery failure retains the marker for retry. The existing timer catch-up handles deadlines missed during an outage.
A session wait can end or change without cancelling this deadline. This behavior does not require a client callback.
This path creates timers for new requests. It does not scan or repair historical requests.

## Comma reply dispatch

Send standalone replies with `call(tool=im_api.internal.send_message)`.
Omit `reply`, `reply_mode`, and `final_outcome`. Put an unsent final reply in
`end_turn(reply={tool,params})`. See [source-bound replies](#source-bound-replies-and-explicit-completion).
Old calls: read-only.

## Source-bound replies and explicit completion

The Router can send a current-source reply in the same `end_turn` call that
declares `outcome: "done"` or `outcome: "blocked"`. `reply` contains a disclosed IM or Comma `tool` and its `params`. It can include an `ifc`
source declaration. Before dispatch, the runtime checks source, destination, tool permission, and content label. It settles only after send success while the Session still matches the accepted source. Failed or refused sends leave the turn open. Plain assistant text remains runtime-only.

A Comma reply in `end_turn` waits for the completed model response and committed
intent before its draft appears. `SessionToolDispatch` authorizes the final
source, destination and IFC declaration before it publishes the complete text.
This rejects nonempty delivery filters regardless of field order. Repair rounds
do not publish this draft. The draft stays visible until the send result commits.
This path does not show text during generation.
Ordinary `call` streaming retains its existing behavior. Its audience-filter
handling is outside this change and is not covered by this guarantee.

A standalone send delivers a message without ending the activation. The
model-visible `call` schema does not offer `reply_mode` or `final_outcome`.
`TerminalReply` ignores those fields on standalone model calls from stale
prompts. This includes Worker reports to a Task and Router deliveries after a
Worker result. After delivery, the agent continues unfinished work or calls
`end_turn` without another reply. It must not repeat a successful send.

Opening promises require execution. Worker Task routing and authorization remain unchanged. Widgets are output formats, not delegation lifecycles.

A request that answers a new human message in a Comma user chat ends with the
`opening=on` turn flag. The flag remains active until the model responds to
that message. It activates a prompt rule: send one short opening, or the direct
answer, before longer work. Tool continuations, Task conversations, and other
providers do not get the flag. The rule is a prompt instruction only. It does
not change the configured reasoning effort, and it does not guarantee a
first-reply time.

### History and client presentation

History retains the model's original `end_turn(reply)` call. Only dispatch
unwraps the nested send. A delivered event binds the assistant message and
call IDs. Request projection uses that event to replace a running placeholder
with a completion receipt, including when settlement consumes the completion
wake. The stored journal and earlier reader-page bodies remain unchanged.
Diagnostic redaction and page limits still apply.

Normal activation records the system prompt from the same configuration used
for tool dispatch. Runtime rules, skills, and configured instructions update
together. Unchanged configuration keeps the same prompt bytes and adds no
prompt event. History and accepted work remain intact. Compaction can use the
previous prompt before it records the current configuration. An upgrade notice
explains the old history representations once. It does not rewrite those records.

A Comma SSE snapshot includes Participant status and draft from the same owner
read. The client applies both with canonical Messages. This is a presentation
frame, not a transaction across Conversation and Participant owners. Absent
status preserves the previous projection. A stopped Participant clears visible
activity immediately. An active Participant can continue after a progress reply.

### Ownership and failure

`Session.Query.Round.replyTargets` derives destinations from trusted ingress.
The kernel builds the terminal-reply scope (`terminal_reply_context`) and admits
each call (`terminal_reply_admission`); `TerminalReply` supplies only the
canonical-Router fact. The kernel retains source validation and provider reply defaults. It
creates a terminal binding for a reply carried by an explicit `end_turn` call.
It does not create a binding for a standalone model send. The kernel's agent
loop (`loop_step`) classifies `end_turn`, unwraps its reply for dispatch, and
builds the runtime failure notice with its own binding and source checks.
Provider access controls and IFC checks still authorize delivery. No message
content scanner decides completion.

Previously dispatched terminal bindings retain their settlement and recovery
semantics. Runtime-owned failure notices, interactive Telegram cards, and
optional channel welcomes retain their special lifecycle contracts. The kernel still fences their ACK and
settlement against later input. Reply and delivery journals are neither rewritten nor deleted.
A channel welcome binds outcome `done`, and an interactive Telegram card binds
outcome `blocked`. The `end_turn` outcome does not change these values.

A plain Slack reply reminder is advisory. An explicit `end_turn` without a reply
completes the turn and retires the reminder. Only a Task card obligation fences
the ACK. A retryable model failure keeps the source and its reminder for the
retry, unless a failure notice already reached the source. A final model failure or an exhausted guard without a destination
settles locally when no send is pending.

Delivery is not a cross-provider transaction or an exactly-once guarantee.
An external success followed by a crash before local recording remains ambiguous.
The runtime does not retry blindly.

### Private diagnostics after repair

A tool failure without a public summary is a private diagnostic. The model sees
its text only during visible-reply repair. After repair, the request projection
shows a record: status `failed`, a valid `error_class` or guidance `reason`, and
the `effect` and `retry` facts from `Session/FailureOutcome.lean`. The record
has no diagnostic text. The redacted call keeps its tool name. A success made
during repair reads as `completed`.

For a lasting fact (an ended call, an unknown send outcome, a rate limit),
return a stable `error_class` or `code` and add it to that table.
`public_summary` is text users can see. Tool failures use only `model_only` or
`user_reportable`.

### Validation and observability

Tests cover authorized drafts, field-order-independent filter rejection, continued work after progress, send failure, and input before settlement.
They replay stale metadata on standalone Worker, Router, and Telegram sends. Interactive cards retain separate settlement checks.
Model-request, tool-result, and activation telemetry cover this path.

#### Slack reply routing and Task sources

Agent-facing Slack text sends use two separate operations:

- `im_api.slack.reply_message` requires `channel`, `text`, and `thread_ts`.
  Use the original source root (or the source message timestamp for a new
  incoming channel message), never the latest unrelated request's thread.
- `im_api.slack.post_channel_message` starts an explicitly requested new topic
  and rejects `thread_ts`. It must not be used as a fallback for an unresolved
  reply destination.

The ambiguous `slack.post_message` transport remains for product-owned callers
and historical records, but is not disclosed as an agent operation. Both new
operations retain the existing renderer, provider access controls and IFC checks.

Ordinary Task creation captures the selected trusted Slack source in the runtime-owned
`source_refs.task_reply_source` field, independently of IFC mode. Ordinary
conversation updates cannot replace or remove it. Every delivered Task message
carries those original coordinates in its model-visible source context, so an
asynchronous report does not depend on the Router remembering a previous turn.
The field is routing data, not an execution grant: Workers still report through
the Task, and scheduled Task delivery restrictions are unchanged. Tasks
created before this field existed do not invent a source from the current turn.

These are operation-contract and source-presentation changes, not new Session
settlement, persistence or IFC-authority semantics. The retained system-core
TLA+ abstractions and their mappings are unchanged; implementation regressions
cover source persistence, interleaved delivery, split transport validation and
exact-target reply settlement.

Existing immutable Task execution grants retain their exact destination and
installation. The runtime reads historical Slack operation names as the matching
reply or channel operation. New grants must use the current catalog. This keeps
accepted work usable after cutover; it does not allow old agent tool calls.
No durable records are deleted or rewritten. Recovery uses a forward repair if
a preserved grant cannot be resolved.

Product-owned triage Tasks keep their existing read-only investigation sources,
not the current delivery origin. Their retry identity and delivery policy do not change.
