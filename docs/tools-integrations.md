# Tools and integrations

[UI](clients.md#chat-dynamic-ui).

## Admission and disclosure

Admission owns access. Resolve sources/destinations before dispatch. See IFC help.
Keep secrets out of catalogs, logs, clients and user redirects.
[Agent models](billing-models.md) and [Composio](identity-security.md#composio-trigger-authorization).
Find MCP via `mcp.list`, IM via `im.provider_apis_list`, management, Calendar, inbound API, SSH and labels via `help`. No hidden tools.

## Plugin and remote authorization boundaries

Reuse SDK/auth owners. Bind OAuth enrollment to tenant/operation.
Check the installed connection and scope at execution. Listings and stale status grant no access.
Separate approval, callback, credential storage, and dispatch.
Bound integration errors. Preserve unrelated Agent control.

`resources/salix-system-files/skills/` has read-only built-ins below stored user skills. See [miniskills](architecture/DOMAIN_CONCEPTS.md#miniskill-activation).

### Comma plugin authorization

Composio keeps old accounts until a verified install retires older active accounts in the same group and toolkit.
Other toolkits and newer or undated accounts remain. Cleanup errors do not fail the install.
Owners confirm old accounts for personal use. Comma checks group, toolkit, active status, and self identity at display and confirmation.
The receipt pins the account. Newer accounts cannot replace it. Unavailable accounts fail collection.
Confirmation queues source sync and one Routine run, even for the same source ID.
Reconnect keeps the old account and receipt until the new grant completes. Then it retires only that account.
Drive is optional. Gmail and Calendar are required. Settings links to Plugins. Display status grants no access.

GitHub, Linear, Notion, and Slack use Salix OAuth for APIs and recommendations. Notion alone needs separate MCP OAuth.
Linear requests `read` and `write`.
Native reauthorization gives the OAuth callback the attempt's 2-minute deadline.
The callback checks generation before binding writes. Cancellation keeps old access if it wins. Otherwise it conflicts.
Comma connects `setup.required_connections` in order and installs after all complete. MCP callbacks match the plugin and group.
App credentials use tenant overrides or defaults. Grants remain group-scoped.
Native sources need no Composio setup. Slack discovery and previews use only the managed binding.
Slack, GitHub, Linear, and Notion watches read `mcp.<provider>.*` on it.
Other saved Composio sources or consents require Composio. Discovery errors block sync.
Reauthorize old native grants. Removal disconnects declared native credentials. Clean old Composio accounts separately.
[X](architecture/DOMAIN_CONCEPTS.md#x-plugin-credentials).

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

Replay preserves expiry. Without one, requests expire 120 seconds after creation.
Missing execution deadlines require a request lookup, not assumed expiry.
Approval decisions differ from authorization receipts. Only the original decision winner can issue an IFC receipt.
After 30 seconds of unknown results, recovery records that uncertainty and never reissues the receipt, including after consumption.

### Runtime failure notification

Reply identity uses the accepted human source and trusted target. Context source IDs retain provenance.
Non-runaway model/guard failures use the authorized notification path when safe.
With no destination or unsafe foreign-work cleanup, they record local blocked retirement and ACK only materialized input, without a send.
Blocking cards and pending visible commits prevent this fallback. Queued input and accepted work retain their lifecycles. Runaway retirement is separate.

Reserve before sending. The notice's only transcript entry is a no-wake `runtime_failure_reply` runtime message.
Committed attempts never resend. Refused/unknown outcomes prove no delivery. Pending work keeps its source and cards.
Background completion can resume it. No-wake context cannot. Fixed notification text omits provider errors and credentials.
Each queued human input grants at most one bounded retry, without borrowing authority or permitting another notice.

`force_recover` reports `command_recorded`, `processing_observed` (a later model response), or `blocked`.
Wake acknowledgement and active status prove no model progress. The immediate observation is not a delivery guarantee.
Failed activations use their settlement path and inject no recovery message.

## IM providers

Salix owns provider connections, normalized Messages, Participants, and dispatch. Product entry points own authorization and setup progress.
Slack threads, Telegram chats, and Feishu conversations do not replace canonical Salix identity.

Adapters own formatting. Feishu defaults to Markdown, rendered as a post. Use `format: "text"` for literal text. Native mentions require provider IDs, not names.
Provider retries use idempotent admission. External send confirmation differs from model completion and canonical append.
Bound Slack concurrency and retries. Do not poll every Task or Participant for card updates.
Slack and Feishu Task cards share one projection. See [Task cards](architecture/DOMAIN_CONCEPTS.md).
See [Slack command threads and receipt lifecycle](architecture/DOMAIN_CONCEPTS.md#slack-command-source-receipts).

Triage has its own product admission contract. See [Bridge For Teams](bridge-for-teams/design.md).
See [Messaging, voice](messaging-voice.md) and [QQ, Lark bots](../systems/README.md#qq-bot).

Linear agent sessions map to Tasks. See [Linear agent installation](architecture/DOMAIN_CONCEPTS.md#linear-agent-installation).
Message-search visibility is checked after ranking and before content return. See [Storage](storage-search.md).
Routers and Workers read and edit Feishu and Lark cloud documents, and read Minutes, as the connect's bot. See [Feishu cloud documents](architecture/DOMAIN_CONCEPTS.md#feishu-cloud-documents).
`feishu.search_messages` reads a ClickHouse mirror, not Feishu search. Verified callbacks enter a PostgreSQL outbox before Router filtering. A failed insert fails the callback. Backfill walks each chat and thread. Search is scoped to the connect's tenant and app. Hits can be `stale` or `incomplete`.

## Agent browser use

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
It refuses loopback, private, link-local and other special addresses and internal names, and pins the connection to the checked address.
No redirects or retries. A non-2xx status is a result.

### Outbound SSH

See [Outbound SSH Session](architecture/DOMAIN_CONCEPTS.md#outbound-ssh-session).

## Verification

Retain authorization, OAuth ownership, interruption, provider-error, rendering, and delivery tests. Source-string inventories cannot prove these boundaries.

## Source-bound replies and explicit completion

Send standalone replies with `call(tool=im_api.internal.send_message)`. Omit `reply_mode` and `final_outcome`.
`TerminalReply` ignores them on standalone calls from stale prompts.
A standalone send delivers without ending the activation. This includes Worker reports to a Task and Router deliveries after a Worker result.
After delivery, the agent continues unfinished work or calls `end_turn` without another reply. It must not repeat a successful send.

The Router can send a current-source reply in the `end_turn` call that declares `outcome: "done"` or `outcome: "blocked"`.
`reply` contains a disclosed IM or Comma `tool` and its `params`, and can include an `ifc` source declaration.
Before dispatch, the runtime checks source, destination, tool permission, and content label.
It settles only after send success while the Session still matches the accepted source.
Failed or refused sends leave the turn open. Plain assistant text remains runtime-only.

A Comma reply in `end_turn` shows its draft only after the completed model response and committed intent.
`SessionToolDispatch` authorizes the final source, destination and IFC declaration before it publishes the complete text.
It rejects nonempty delivery filters regardless of field order. Repair rounds do not publish this draft.
The draft stays visible until the send result commits. No text shows during generation.
This guarantee does not cover audience filters in ordinary `call` streaming.

### Ownership and failure

Provider access controls and IFC checks still authorize delivery. No message content scanner decides completion.

Dispatched terminal bindings keep their settlement and recovery semantics.
Runtime failure notices, interactive Telegram cards, and optional channel welcomes keep their own lifecycle contracts.
The kernel still fences their ACK and settlement against later input. Reply and delivery journals are neither rewritten nor deleted.
A channel welcome binds outcome `done`. An interactive Telegram card binds outcome `blocked`. The `end_turn` outcome does not change these values.

A plain Slack reply target is advisory. An explicit `end_turn` without a reply completes the turn and retires the target.
Only a Task card obligation fences the ACK.
A retryable model failure keeps the source and its target for the retry, unless a failure notice already reached the source.
A final model failure or an exhausted guard without a destination settles locally when no send is pending.
A Worker whose input came from a Task then sends that Task one failure report.

Delivery is not a cross-provider transaction or an exactly-once guarantee.
An external success followed by a crash before local recording remains ambiguous. The runtime does not retry blindly.

### Private diagnostics

A tool failure without a public summary is a private diagnostic. It opens visible-reply repair.
A model call of `get_runtime_message`, the runtime's own message name, runs no tool. Its guidance opens no repair and uses no attempt. Its round still does not settle.
The model context keeps the diagnostic as committed, during and after repair. The request projection does not change an earlier message to enforce information flow.
Containment depends on the model: the request shows the diagnostic behind a `[private diagnostic]` header, and a prompt rule tells the model not to quote it.
A user-reportable failure shows only its public summary in every request.

For a lasting fact (an ended call, an unknown send outcome, a rate limit), return a stable `error_class` or `code`.
`public_summary` is text users can see. Tool failures use only `model_only` or `user_reportable`.

#### Slack reply routing and Task sources

Agent-facing Slack text sends use two separate operations:

- `im_api.slack.reply_message` requires `channel`, `text`, and `thread_ts`.
  Use the original source root (or the source message timestamp for a new incoming channel message), never the latest unrelated request's thread.
- `im_api.slack.post_channel_message` starts an explicitly requested new topic and rejects `thread_ts`.
  Never use it as a fallback for an unresolved reply destination.

`slack.post_message` remains for product-owned callers but is not disclosed as an agent operation.
Both agent operations keep the existing renderer, provider access controls and IFC checks.

Ordinary Task creation captures the selected trusted Slack source in the runtime-owned `source_refs.task_reply_source` field, independent of IFC mode.
Ordinary conversation updates cannot replace or remove it.
Every delivered Task message carries those coordinates in its model-visible source context.
The field is routing data, not an execution grant. Workers still report through the Task. Scheduled Task delivery restrictions are unchanged.
Tasks without the field do not invent a source from the current turn.

Existing Task execution grants keep their exact destination and installation.
The runtime reads historical Slack operation names in grants as the matching reply or channel operation. New grants use the current catalog.
Product-owned triage Tasks keep their read-only investigation sources, retry identity, and delivery policy.
