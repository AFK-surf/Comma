# Product feature map

Feature owners and tests, not deployment status.

## Chat and Tasks

`clients/packages/app/` owns shared product interactions.
Canonical Conversation and Task facts remain on the server.
Draft append, optimistic thinking, message replies, previews, and Task cards are client projections.
Send a draft only through the intended user action.
A stale asynchronous preview or send result must not affect another Conversation or account.

Retain tests that exercise send/cancel, keyboard interaction, error recovery, loading accessibility, and canonical reconciliation.
Use [Conversations](salix/conversation-owner-actor.md) and [Tasks](salix/tasks-background-execution.md) for durable guarantees.

## Files and navigation

Opening a file, previewing content, and sharing an attachment are different operations.
File cards keep preview and Open in actions. Download is in the preview sidebar, not a separate card button.
An Agent message shows a PNG, JPEG, GIF, or WebP file at the ratio it was produced at, in a hairline frame capped at 480 by 384 pixels, so an extreme ratio shrinks instead of being cropped.
It plays an MP4, M4V, or WebM file in a bounded frame: at most 480 by 384 pixels, with the frame ratio held between 3:4 and 21:9. The player has a full-window view and a download control.
Only Agent inline image and video frames use the shared 2-pixel radius token and retain a hairline border. User attachments and other preview surfaces keep their existing styles.
All other types stay file cards, SVG included. Media that does not load or decode also becomes a file card again.
Download eligibility does not guarantee remote file availability.
A source path is not permission to disclose its content or a provider-accessible URL.
Use the owner-backed file/capability path and handle unavailable content explicitly.
Drive mentions and catalogs must preserve current source scope and bounded lookup.
Do not perform a full resource scan on each interaction.

Browser navigation, side chat, site permissions, shortcuts, and memory sessions have native owners.
The macOS onboarding names the Side Chat shortcut after setup and ends with the Open Comma shortcut step, if set. Main suspends that shortcut and hides the main window during onboarding.
Closing its last tab collapses the right sidebar.
Pages and renderers cannot override native permission or account authority.
Use native tests for browser permissions, focus, keychain, protocols, and windows.
See [Clients](clients.md).

## Models and settings

Router and default Worker selectors are independent.
Owners can rename the Router (1 to 40 characters). Participants keep the join-time name; clients show the current one.
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
The caller gets a queue receipt and no reply channel.
The Router decides where, if anywhere, to answer.

Four surfaces mint these keys: the Comma app, the Salix dashboard, the tenant runtime API,
and the Router through the `inbound_api` tools.
The plaintext is returned once and never stored.
The creator is a stored fact, because a key acts with its creator's authority.
A key the Router mints holds no membership, so an Agent cannot mint itself new reach.
BFT has no surface of its own for these keys.
The separate `voice` key kind opens only voice calls: see [voice agent API keys](messaging-voice.md#voice-agent-api-keys).

`Salix.App.RouterInbox` owns the workflow and the URL that every surface hands out.

## Change acceptance

State the old behavior, intended behavior, and affected runtime boundary.
Use component tests for local interaction and end-to-end checks for cross-host behavior.
A screenshot proves appearance at one observed state, not authorization or delivery.

## Routine generation

Settings provides member mode. Member sources need no other setup.
New and unset profiles use member mode. Explicit generic choices remain.
Unset profiles hide generic snapshots and reject queued generic results.
Mode changes supersede runs and hide snapshots through source revision.
Discovered source additions keep the valid snapshot, stale if the replacement fails.

Schedules specify refresh starts, not delivery deadlines.
Member objectives retain actor, intent and constraints. Observed metrics are not requirements.
GitHub excludes work not updated in 30 days.
Truncation cannot create titles. Evaluate semantic quality on real accounts.

Hover shows quoted context above the objective without fetching.
Mentions and HTTP links use chips, not HTML. Excerpts stop at 600 characters without partial links.
Task clicks append "Help me" plus the objective and source URL after the unchanged draft, separated by a blank line, without sending.
Daily briefings do not retain hidden items across snapshots or automatically link existing tasks.

The snapshot `prompts` map stores objectives, contexts, labels, source IDs and URLs.
Cards, summary links and actions use `promptId`, decoded at the client API boundary.
Generation indexes candidates once, omitting empty facts and title-identical excerpts from model input.

### Business boundary

Refresh queues a durable briefing without blocking reads or installation. Failures retain only valid snapshots.

The five-second trigger-to-snapshot target is unverified. Empty fallbacks and source failures do not qualify.

### Ownership and execution

1. Core commits the fenced run, generation job, and deadline job together.
   Manual, source-change, and scheduled requests share this path. Manual requests then return `202`.
2. Shared Schedules sends `comma_recommendation` a profile ID. The receiver checks its schedule ID and enabled state.
   ACK follows durable run/job insertion. Re-delivery reuses `schedule:<id>:<scheduled_for>`.
   Disabled schedules or profiles without enabled sources ACK a skip.
3. `RecommendationGenerate` checks the original run deadline and account access.
   The existing read-only collector reads at most 12 sources, with concurrency 4,
   a 10-second per-source timeout, a 30-second collection budget, and 12 KB of
   retained data per source. Crashed reads become source failures, not collector exits.
   Separate 16 KiB source context cannot displace candidates.
   No per-candidate network or memory reads run. The run stores source URL evidence.
4. The member's Router selects, ranks and names suggestions in one request with its own template.
   A configured Routine template replaces only the model. Generic mode uses one worker request.
   The request uses the run deadline, dependency admission, metering, and archives.
5. Member, direct DeepSeek, and Anthropic use in-prompt schemas. Other requests use `response_format`.
   Each member row is validated alone. Unknown or repeated IDs, extra fields, and invalid text drop it.
   A non-selection response, or one whose rows all drop, fails the run. This is not a semantic proof.
6. `RecommendationDraft` builds v1. Comma owns timestamps, app names, IDs, URLs, warnings, previews, and confirmation.
   References follow suggestions. Long labels scroll on hover/focus unless motion is reduced.
   Slack record excerpts keep the primary message.
   Generic drafts with unknown IDs, extra fields, or invalid content fail the run.
7. Publication rechecks account access and locks the profile and run. It checks
   terminal state, the original deadline, generation, source revision, and the
   collected link evidence. Late or superseded results cannot replace snapshots.
   Settlement clears source evidence but retains generation counts.
   See [Routine job queues](observability.md#routine-job-queues).

Content is limited to 64 KB, six cards, four items per card, and 18 total items.
A provider error fails the run and keeps its valid snapshot. Invalid content is not repaired.
Crashes can retry unfinished work within its deadline; calls and billing are not exactly-once.

Workspace ownership and membership authorize reads and publication.
Rechecks reject queued work after revocation with `workspace_unavailable`.

### Capacity and terminal outcomes

Each node has eight generation slots and two separate control slots.
Two nodes run at most 16 concurrent generation jobs. Source collection
can use at most 32 calls per node; existing dependency admission also applies.
Source discovery remains on `comma_external`. No model wait holds a database
transaction. Reads load one member projection and enqueue source and schedule reconciliation with five-minute uniqueness per worker and profile.
Member snapshots check consent and OAuth bindings before display, without probing provider revocation.
Owners confirm old Composio accounts before personal reads. Discovery keeps the selected account when a newer one appears.
Empty member candidates skip model configuration and execution. Member candidates require a direct source
relationship, but the Router must still omit non-actionable or non-work items.
Notion needs no setup. A task database has a people property and a Notion status property.
Notion reads open items in at most five of them: a people property names the member and the status
is outside Notion's Complete group. The Router judges the named property as the member's role.
It also reads at most five pages that the member last edited or created in the past seven days,
with each page's outline and text tail. A draft qualifies only when its text shows unfinished work.
Comments that mention the member count on the five most recently edited Notion pages and changed Drive files.
Slack adds one-to-one direct messages and threads where someone else spoke last. GitHub and Linear add mentions.
Gmail keeps important mail until the member replies in its thread. Calendar covers the coming week.

A run has 480 seconds from durable insertion, including queue wait, collection,
and model work. Both model stages use the remaining budget. A queued job
that starts after the deadline fails before external calls. Publication enforces
the same deadline even if the timeout job has not run. Refresh and selected-source
changes supersede the previous active run and cancel its generation/deadline
jobs through Oban. Cancellation of an executing owner releases its dependency.

Each minute, Lifeline rescues at most 1,000 orphaned Routine jobs
whose attempted-at time is at least 480 seconds old. Recovered generation
settles expired runs before provider calls. Control jobs use the same recovery.
Durable settlement requires queue and database availability.
At expiry, reads expose `lastError: timed_out`: `error` without a valid snapshot,
or `stale` with one. This read-only projection does not settle runs.
An unexpired newer run returns `refreshing`, not the older timeout.

Partial source failure can publish useful results with source-specific warnings.
Gmail skips contextless messages with a source warning. All-contextless results fail; empty mailboxes succeed.
All-source failure, missing model configuration, invalid content, and model
failure produce bounded failed states. GET and settings changes do not create
or deliver to a renderer Agent. Settings reconcile their one schedule through
local database operations; periodic reads enqueue that work.

### Data cutover and recovery

Release migration `comma-20260912000001` requires `exclusive` mode. Old writers stop
before accepted work moves to jobs. No mixed-version generation path is retained.

Preserve all member profiles, source selections, OAuth connections, snapshots,
run rows, schedule IDs, occurrence anchors, renderer identities, and journals.
The migration queues one reconciliation per profile and generation/deadline jobs
for each pending or running run. It cancels only unfinished
`RecommendationContextSeal` jobs, which own no generation or user content.
This job cutover deletes no product data. Separately, member identity requires fresh
consent for legacy connections. GitHub, Linear, and Notion use native OAuth,
not legacy Composio accounts.

The reconciliation worker converts only the exact schedule owned by its profile.
It preserves the ID and occurrence anchor, changes the receiver and payload,
and removes the old Agent delivery fields. An ownership mismatch fails without
changing that schedule. An old acknowledged occurrence with no corresponding
run receives an idempotent generation or an explicit timeout if its budget
expired. Old renderer Agents are archived and stopped through their
lifecycle owner; their identity and session journals remain available.

Before release, inventory profiles, active runs, and legacy schedule ownership.
Require PostgreSQL backup/restore evidence. Record the mainline image, chart,
migration plan, and serving state through the release coordinator.

Verify that all profile reconciliation jobs completed, schedules use the product
receiver, old renderer Agents are archived, and pre-cutover runs are terminal.
Reconciliation allows five attempts, a 30-second execution timeout, and 15-second
retry delay. With healthy dependencies, budget 15 minutes for a small cohort.
Larger cohorts share two control slots per node. An unresolved reconciliation
is a release verification failure, not permission for unlimited retries.

Before cutover, use the release coordinator's existing failed-transaction
recovery. After the incompatible migration commits, use forward repair from
approved mainline artifacts. Do not run an old Agent writer against converted
schedules or restore older application code as a compatibility shortcut.
Staging uses an image and chart built from merged `main`. Production promotes
that staging-proven mainline artifact through the existing release flow.
See the [rollout checklist](release-operations.md).

### Verification

The regression suite tests the HTTP acknowledgement, source collector, LLM
facade, compiler, and publication together. It covers a blocked model while
reads and another refresh proceed, terminal failure with a retained snapshot,
access revocation, duplicate schedule occurrences, late publication, queue
cancellation, and orphan recovery. Compiler tests cover paragraphs, references,
action authority, partial failures, empty results, and card bounds. Migration
checks must run the real migration and compare preserved data.

Shared Schedules and DependencyJob keep their existing system-level contracts.
Their retained TLA+ models are unchanged;
feature lifecycle regressions remain in implementation tests. Historical
recommendation model anchors are not current TLC evidence.

Real OAuth authorization, model latency, and Electron protocol callbacks require
separate environment checks. Record the tested commit/environment and each
actual generation's result and duration. Local fixtures do not establish
production success. Do not record source content, access tokens, or model keys
in test reports.

## Create a Shell workload

The first creation UI uses the managed `shell.default` template.
It has a 512 PID limit and a 2 GiB writable disk limit. Its network policy denies egress.
The server owns the image, command, and resource policy. These forms do not accept arbitrary images or commands.

| Surface | Entry and authorization |
| --- | --- |
| Comma App | Settings > Compute node > Manage environments. Select the active workspace environment. Workspace authorization applies. |
| BFT Dashboard | Agent Swarm > Devices > Compute environments > Create Shell workload. Project administrators can create workloads. |
| Salix Dashboard | Compute Nodes > node > Workloads > Create Shell workload. The authenticated administrator uses the selected tenant and node environments. |
| Comma Admin | Compute nodes > node details > environment > Create Shell workload. The existing audited command requires a reason and confirmation. |

Creation calls the existing Compute placement owner.
The environment determines the eligible provider binding. Selecting a node's environment does not introduce a separate node-pinning policy.
Success means Salix accepted the workload. It does not prove that its runtime is ready.
Comma observes one visible page, at most 60 rounds every five seconds. Hidden panels stop polling.
New Comma clients persist one creation key and recover or retry that key after response loss. Other views use manual refresh. No view retries creation automatically.
The administrator command receipt and workload creation commit together. Replaying the same command does not create another workload.

The backend needs the published runtime bundle manifest in its configured runtime bundle directory.
A missing template or unavailable capacity rejects creation. Installing a VMM Host alone does not provide that backend manifest.
The existing reconciler owns runtime startup and reports subsequent failures.
The new UI does not change allocation or command settlement transitions in the retained system models.

## Compute Node workload initialization

**Enable this Mac** prepares a missing Host before backend enrollment.
All App channels download and reuse the shared Host by default.
Each App requests registration from its current session backend for its selected workspace.
One Host can retain registrations for production, staging, and local backends at the same time.
Build flavor does not select the registration backend.
Another registration does not update the Host.

Comma initializes a workload after an explicit Compute Node enable.
It observes one installation at most 31 times over a 30-second readiness window, plus bounded request timeouts.
When ready, it sends one authenticated `initialize-workload` request for that installation.
The backend resolves the installation from the current workspace and main-device session.
It uses only the available VMM binding for that registration and environment.
An environment row lock serializes concurrent initialization requests.
Reuse requires a desired-ready Shell, including failed startup, and a pending, allocating, or ready allocation.
Both records must belong to the current environment generation.
Otherwise, the existing Compute owner places a `shell.default` workload on that binding.
Response-loss retries reuse the existing workload. No separate initialization identity or lifecycle is stored.

Initialization errors require **Continue preparing Shell**. This resumes initialization without enabling the registration again. Refresh stays read-only.
Disabling Compute Node drains its registration workloads and releases their allocations through the existing lifecycle.
Re-enabling creates a new workload after drain, stop, or release. Startup failure retains the original Shell.
Normal removal revokes this registration and stops its environments into Retained, preserving private files. Force deletion needs local confirmation.
Deleting a workload does not trigger background replacement. A later explicit enable can initialize another workload.
Creation acceptance does not prove runtime readiness or give an Agent permission to execute commands.
Agent execution still requires the existing Compute grant and context.
