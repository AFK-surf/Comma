# Product feature map

Feature owners and tests, not deployment status.

## Chat and Tasks

`clients/packages/app/` owns shared product interactions.
Canonical Conversation and Task facts remain on the server.
Draft append, optimistic thinking, message replies, previews, and Task cards are client projections.
Send a draft only through the intended user action.
Reply (menu, or iOS swipe right) gathers a message's thread. Sends answer it until closed.
A stale asynchronous preview or send result must not affect another Conversation or account.

Retain tests for send/cancel, keyboard, error recovery, loading accessibility, and canonical reconciliation.
Use [Conversations](salix/conversation-owner-actor.md) and [Tasks](salix/tasks-background-execution.md) for durable guarantees.

## Files and navigation

Opening a file, previewing content, and sharing an attachment are different operations.
File cards keep preview and Open in actions. Download is in the preview sidebar, not a separate card button.
Download eligibility does not guarantee remote file availability.
A source path is not permission to disclose its content or a provider-accessible URL.
Use the owner-backed file/capability path and handle unavailable content explicitly.
Drive mentions and catalogs keep current source scope and bounded lookup. No full resource scan runs on each interaction.

Drive's System Files show the owner the Router's `/memory`, `/imports`, `/Comma`, skills, and instructions.
Only `memory.write` paths are editable, any episode date included.
Under IFC, a scoped note shows only to its readers and keeps its label.

Use native tests for browser permissions, focus, keychain, protocols, and windows.
See [Clients](clients.md#browser-and-desktop) for native owners and page authority.

## Models and settings

Router and Worker selectors are independent. A new Workspace has no Worker.
Owners can rename the Router (1 to 40 characters). Participants keep the join-time name. Clients show the current one.
Creating a custom model does not select it or rewrite existing Task Agents.
Credentials remain transient in forms and protected in the owner store.
Subscription catalogs are discovery results, not execution guarantees.
A provider failure leaves manual entry and an actionable error, not a silent funded fallback.
See [Billing and models](billing-models.md).

## Collaboration products

Comma Workspaces and BFT Projects apply their own membership and product access checks.
A hidden menu is not authorization.
Triage selects one Worker, which decides whether and how to participate.
Personal meeting preparation separates shared public research from each recipient's private context.
See [Bridge For Teams](bridge-for-teams/design.md) and [Meetings](meetings-calendar.md).

## Inbound API

An external system posts one message to a Group's Router at
`POST /v1/agent-groups/{group_id}/router/post-message`.
It authenticates with one of that Group's inbound API keys.
The message crosses the Slack and Feishu ingress funnel, with `provider=api`.
The caller gets a queue receipt and no reply channel. The Router decides where, if anywhere, to answer.

Four surfaces mint these keys: the Comma app, the Salix dashboard, the tenant runtime API,
and the Router through the `inbound_api` tools. BFT has no surface for these keys.
The plaintext is returned once and never stored.
The creator is a stored fact, because a key acts with its creator's authority.
A key the Router mints holds no membership, so an Agent cannot mint itself new reach.
The separate `voice` key kind opens only voice calls: see [voice agent API keys](messaging-voice.md#voice-agent-api-keys).

`Salix.App.RouterInbox` owns the workflow and the URL that every surface hands out.

## Routine generation

### Ownership and execution

Publication rechecks account access and locks the profile and run. It checks
terminal state, the original deadline, generation, source revision, and the
collected link evidence. Late or superseded results cannot replace snapshots.
Settlement clears source evidence but retains generation counts.
See [Routine job queues](observability.md#routine-job-queues).

A provider error fails the run and keeps its valid snapshot. Invalid content is not repaired.
Crashes can retry unfinished work within its deadline. Calls and billing are not exactly-once.

Workspace ownership and membership authorize reads and publication.
Rechecks reject queued work after revocation with `workspace_unavailable`.

### Capacity and terminal outcomes

Source collection can use at most 32 calls per node. Dependency admission also applies.
Source discovery stays on `comma_external`. No model wait holds a database transaction.
Reads load one member projection and enqueue source and schedule reconciliation with five-minute uniqueness per worker and profile.
Member snapshots check consent and OAuth bindings before display, without probing revocation.
Account consent follows [Comma plugin authorization](tools-integrations.md#comma-plugin-authorization).
Empty member candidates skip model configuration and execution.

See [member source reads](architecture/DOMAIN_CONCEPTS.md#6-files-and-proactive-work) for member candidate sources and per-provider bounds.

### Data cutover and recovery

Release migration `comma-20260912000001` requires `exclusive` mode. No mixed-version generation path exists.
It preserves profiles, source selections, OAuth connections, snapshots, runs, schedule IDs,
occurrence anchors, renderer identities, and journals. It deletes no product data.
The reconciliation worker converts only the exact schedule its profile owns. An ownership mismatch fails without change.
Old renderer Agents are archived through their lifecycle owner. Their identity and session journals remain.
An unresolved reconciliation is a release verification failure, not permission for unlimited retries.

After the migration commits, repair forward from approved mainline artifacts.
Do not run an old Agent writer against converted schedules or restore older application code.
See the [rollout checklist](release-operations.md).

### Verification

Real OAuth authorization, model latency, and Electron protocol callbacks require
separate environment checks. Local fixtures do not establish production success.
Evaluate semantic quality on real accounts.
Do not record source content, access tokens, or model keys in test reports.

## Create a Shell workload

Shell creation uses the managed `shell.default` template.
It has a 512 PID limit and a 2 GiB writable disk limit. Its network policy denies egress.
The server owns the image, command, and resource policy. These forms do not accept arbitrary images or commands.

Creation calls the Compute placement owner. The Environment selects its eligible provider binding.
Success means Salix accepted the workload. It does not prove that its runtime is ready.
New Comma clients persist one creation key and recover or retry that key after response loss. Other views use manual refresh. No view retries creation automatically.
The administrator command receipt and workload creation commit together. Replaying the same command does not create another workload.

The backend needs the published runtime bundle manifest in its configured runtime bundle directory.
A missing template or unavailable capacity rejects creation. An enrolled Host that is not connected rejects it with `node_offline`. Installing a VMM Host alone does not provide that backend manifest.
The reconciler owns runtime startup and reports later failures.

## Compute Node settings and initialization

**Devices** groups local compute settings and Workspace Workloads. Old compute links open Devices.
Workspace owners manage cloud resources.
Installation ACK, enrollment, connection and Shell readiness are independent. Failed setup resumes the original plan after restart.
A handoff without ACK or enrollment expires after 15 minutes. Comma then starts one new installation automatically.
Shells reconnect. Initialization keeps one initial Shell, even after deletion.
Reads never create. New Shell uses a new request.

Details show files, limits and location. Rename checks revision.
Owners may read, rename or request Shell deletion offline. Business Workloads require their owner.
Deletion closes input admission and settles accepted work before disposing the exclusive Allocation. Updates must finish or cancel first.
Offline deletion shows **Waiting for original Mac**. A new connection cannot clean the old target.
Seven days without authenticated Host contact expires registration authority. Login expiry alone does not.
Expired or revoked registrations cannot reconnect, renew, enable or recover. Cloud retirement runs in bounded pages.
Shells show **Cloud connection ended** and unconfirmed local data. Owners and unknown results survive.
Only exact Host disposal receipts or proven absence of dispatch establish **Deleted**. Missing rows and 404s do not prove deletion.
Local operators can clean the old environment or reset and register anew. Other registrations stay intact.
The [authorization contract](architecture/DOMAIN_CONCEPTS.md#7-devices-and-compute) defines exact scope and settlement guarantees.

Reauthorization reads bounded candidates. Zero candidates or failed proof shows a reason and retry.
One candidate opens confirmation. Multiple candidates need selection.
Confirmation names account, Workspace, machine and service. Main fences the current login and installation.
Host identity proof survives enrollment failure. Recovery changes delivery authority, not enrollment or revocation.
Update, repair and uninstall preserve data. Failure continues the original request.
**Clear all compute data** requires trusted Main/native confirmation of exact scope.
Workspace removal retires that registration and retains files. Local detachment does not prove cloud revocation.
Stopping compute does not promise restoration. Agent execution still requires its Compute grant and context.
