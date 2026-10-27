# Product feature map

Feature owners and tests, not deployment status.

## Chat and Tasks

`clients/packages/app/` owns shared product interactions.
Canonical Conversation and Task facts remain on the server.
Draft append, suggestions, optimistic thinking, message replies, previews, and Task cards are client projections.
Send a draft only through the intended user action.
Reply (menu, or iOS swipe right) gathers a message's thread. Sends answer it until closed.
A stale asynchronous preview or send result must not affect another Conversation or account.

Full chat offers four ranked follow-ups at most. Capsules send without consuming drafts.
The best is also the placeholder. Tab accepts it without sending or replacing text.
Both share ranked prompts of at most 12 graphemes. Longer prompts are dropped, not truncated. The single-line placeholder may ellipsize.

Retain tests for send/cancel, keyboard, error recovery, loading accessibility, and canonical reconciliation.
Use [Conversations](salix/conversation-owner-actor.md) and [Tasks](salix/tasks-background-execution.md) for durable guarantees.

## Files and navigation

Opening a file, previewing content, and sharing an attachment are different operations.
File cards keep preview and Open in actions. Download is in the preview sidebar, not a separate card button.
Download eligibility does not guarantee remote file availability.
An Agent's attachment downloads at any size. The endpoint streams the stored blob, whole or one byte range, and holds no file in memory.
An audio or video attachment plays, and an attachment downloads, from its [media URL](identity-security.md#attachment-media-urls), so its bytes do not pass through Comma.
The desktop app reads that URL through Main in the ranges a player asks for. It saves a chat file into Downloads as the file arrives, and Copy copies that saved file.
The web reads the media URL directly.
A preview reads only what it shows: an image streams, a PDF loads in ranges, and a text file reads its first 256 KB.
Add to Context on an attachment stores the same blob as a composer file in the Router VFS, so no bytes go through the client.
The phone apps download an attachment to the device before they open it, and upload a picked file from disk as they read it.
A source path is not permission to disclose its content or a provider-accessible URL.
Use the owner-backed file/capability path and handle unavailable content explicitly.
Drive mentions and catalogs keep current source scope and bounded lookup. No full resource scan runs on each interaction.

Drive's System Files show the owner the Router's `/memory`, `/imports`, `/Comma`, skills, and instructions.
Only `memory.write` paths, any episode date included, and the instructions are editable.
Saving the instructions sets the Router's own `router_system_prompt`. Settings › General › System prompt › Custom instructions edits the same text, and Reset clears it; BFT's Router Configure form edits it for org owners only.
Clearing them is refused while the shared `system_prompt` would take over.
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
The BFT daily brief sets no token budget: one model call writes the team brief each day, and one writes each member's; each run records its tokens.
The team brief is written from the human messages since the last one in the bot's public channels, and the brief before it: the bottom line, then at most three things the team must know today, each with state and owner. An admin picks the public channel it is posted to (none: not posted) and the time, 10:20 by default, on workdays where most members are; it names people only where it matters, and only if the organization shows names (pings 3 people at most).
Each member's brief is written from their messages since their last brief, the team brief, and their last brief, so the two tell team news the same way and it says what moved. Its parts follow the day's content: the bottom line first, then what needs them, what moved since last time, their own activity, team news that touches them, and what they can skip.
A thread that continued comes with its first message as context.
A link in it is a cited message or a URL from the messages; other links are removed, and keys and tokens of known formats keep only their prefix.
Briefs read only the bot's public channels, never direct messages.
In Slack, a member can ask the Swarm's bot to move their own brief, and an owner or admin the team brief (`daily_brief.set_time`, the requester from the signed message).
Briefs go out on workdays: Monday to Friday, without the days off and with the make-up workdays an admin sets; the first brief after days off covers them, up to 12 days back. A brief the model cannot write is not sent; a passing failure is tried again in about an hour.
See [Bridge For Teams](bridge-for-teams/design.md) and [Meetings](meetings-calendar.md).

## Mini-apps

A user asks Comma to build an app. The Router calls `internal.apps.create`. The [owner](../systems/apps/comma_core/lib/comma/mini_apps.ex) creates the [Mini App](architecture/DOMAIN_CONCEPTS.md#mini-app) and a private repository `comma-app-<slug>` in the Workspace's connected GitHub account, from the public template `AFK-surf/comma-app-template`.
A `main` push that changes `resources/mini-app-template` mirrors it to the public repository as one snapshot commit. Defaults: Node, Vite, TypeScript, React and shadcn/ui.
Without GitHub, the Router gets `github_not_connected` and asks the user to connect GitHub.
The Router creates a Coding Task with `runs_on {kind: sandbox}`, the repository and `mini_app {app_id}`. Builds share the Workspace sandbox limit, never the Cloud VM.
The coding agent builds, tests and calls `app_deploy`, which creates a preview Version and a Task `mini_app` card.
The Router returns a Comma URL for Workspace members: the latest preview, then the live Version after Publish. External chats show only the URL.

Publish uses the card's Version. It opens a missing Task pull request, accepts review, merges that Version's commit, and sets it live.
A different pull request head refuses before review: "Deploy the latest changes first" if the head has no Version, else it names the newer Version. A GitHub merge refusal preserves live. Retrying Publish after accepted review merges and sets the Version live.
Rollback changes the live Version and leaves the repository unchanged. The Router can [publish and manage apps](tools-integrations.md#mini-app-build-tools-and-backends).

Visibility is `private` (the creator; all members for an app the Router made), `workspace` or `link`.
Links (`https://app.comma.surf/a/<token>`) open in Comma web or Mac. Registered viewers can Install the app in their Workspace or remix it into their own GitHub repository.
Web viewers can sign in or continue as guests. Guests reach only their link app's routes. They cannot list, create, install or remix apps.

Apps use only declared capabilities.
The viewer grants `identity.basic`, `ai.chat`, `web.search`, `drive.app_folder`, `calendar.read` and `notifications` once per Workspace.
The viewer confirms `tasks.create`, `files.pick` and `links.open` each time.
`chat.draft` and `clipboard.write` need no grant. The grant sheet names the backend `egress` hosts. Settings > Apps revokes grants and removes Installs.
Acting as the user (send, create a Task) needs a click in Comma's UI. Apps can only propose it.
Guests get `signup_required` for `ai.chat`, `ai.decide` and `web.search`, and `unsupported` for `tasks.create` and `drive.app_folder`. `calendar.read` is Mac only. Drive access needs Workspace access, so a link-only viewer has none.

`comma.ai.decide({state, questions})` calls the configured decision model with only app-supplied state. All `comma.ai.*` calls share the `ai.chat` grant.
The [SDK contract](../resources/mini-app-template/README.md#decision-model) defines `choice`, `noul` and `score` questions, result units, and input limits (1 to 8 questions, 12 KiB).
Calls share existing decision limits and the two-second dependency budget. Rate limits return `rate_limited`. Missing configuration or provider failures return `unavailable`.

`comma.web.search(query)` calls Exa through the server. The grant sheet names Exa.
Queries contain 1 to 2,000 characters. Calls return at most five `{title, url, text}` results with excerpts of at most 1,200 characters.
The call uses the existing app rate limits, makes one provider request, and has a 15-second receive timeout.
Missing configuration and provider failures return `unavailable`. Credentials stay on the server. Search needs no app backend or egress declaration.

Storage: `device` (1 MiB per app, 32 KiB per value, on one device), `user` (10 MiB per viewer per app), `app` (100 MiB per app). Values are at most 1 MiB.
A bundle has `index.html` of at most 8 MiB, at most 25 MiB and 2,000 files in total. A backend is at most 3 MiB compressed.

Billing: builds use Coding Task billing. Hosting (bundles, backend requests, Durable Object storage, app documents) is free for now (owner decision, 2026-10-24). No hosting meter or catalog key exists.
Comma meters `ai.chat` and `ai.decide` to the viewer's Workspace through the normal LLM path.
Decision billing and archives use the viewer Workspace's existing Router session.
Comma checks the owner Workspace's paid-work availability on deploy, open, backend calls, storage writes, Drive writes, `ai.chat`, `ai.decide` and `web.search`.
A refusal (`insufficient_credits`, `account_inactive`, `missing_account`) returns `app_paused`: the whole app pauses for every viewer. A pause stores and deletes nothing. The next check after credits return runs the app again.

A platform administrator disables an app through the audited admin command (`disable_mini_app`). Takedown stops bundle reads and backend calls at once and deletes the Version scripts.
A Report action is on every app. A report is the log line `mini_app_report` with telemetry `[:comma_product, :mini_app, :report]`.

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
On this Mac, each agent (Codex, Claude Code) runs with the account source the person chose: the Mac's own login, a local model server (Ollama, LM Studio: an address this Mac reaches, kept on its station and never sent to Comma's servers), the Workspace's shared accounts, or none. A Task that chooses a local model's model runs on this Mac. Comma does not read the Mac's logins before the person chooses its own login.
The device card shows the agents and access first, then the sandbox.
Workspace owners manage cloud resources.
Installation ACK, enrollment, connection and Shell readiness are independent. Comma resumes failed setup by itself, also after restart, within a bounded budget and deadline.
A handoff without ACK or enrollment expires after 15 minutes. Comma then starts one new installation automatically, as it does after authorization expiry.
Shells reconnect. Initialization keeps one initial Shell, even after deletion.
Reads never create. Salix creates the initial Shell when the installation first becomes ready. New Shell uses a new request.

Details show files, limits and location. Rename keeps the last name. Retry and deletion check the Workload generation.
Owners may read, rename or request Shell deletion offline. Business Workloads require their owner.
Deletion closes input admission and settles accepted work before disposing the exclusive Allocation. Updates must finish or cancel first.
Offline deletion shows **Waiting for original Mac**. A new connection cannot clean the old target.
Seven days without authenticated Host contact expires registration authority. Login expiry alone does not.
Expired or revoked registrations cannot reconnect, renew, enable or recover. Cloud retirement runs in bounded pages.
After expiry, Comma replaces the registration with a new installation by itself. Other revocations need the user.
Default Workload pages exclude completed deletions and cloud-retired records before pagination.
Recoverable failures and cleanup in progress remain visible. Exact detail reads retain the terminal outcome and unconfirmed local data.
Owners, deletion receipts, and unknown execution results survive list removal.
Only exact Host disposal receipts or proven absence of dispatch establish **Deleted**. Missing rows and 404s do not prove deletion.
Local operators can clean the old environment or reset and register anew. Other registrations stay intact.
The [authorization contract](architecture/DOMAIN_CONCEPTS.md#7-devices-and-compute) defines exact scope and settlement guarantees.

Reauthorization reads bounded candidates. Zero candidates or failed proof shows a reason and retry.
One candidate opens confirmation. Multiple candidates need selection.
Confirmation names account, Workspace, machine and service. Main fences the current login and installation.
Host identity proof survives enrollment failure. Recovery changes delivery authority, not enrollment or revocation.
Update, repair and uninstall preserve data.
A failed or stuck maintenance recovers by itself. Comma first updates to the pinned Host if it can open the local data. A temporary failure retries the same request. If the update fails three times, fails for good, or the pinned Host cannot open the data, Comma erases local compute data and reinstalls (owner-approved). The card then says so.
A retryable failed request frozen on another Host release continues on the pinned release. Replacing a user-started reset or uninstall requires confirmation again.
After the current client request returns, uninstall can replace stuck native maintenance. It keeps local data.
**Clear all compute data** requires trusted Main/native confirmation of exact scope.
Workspace removal retires that registration and retains files. Local detachment does not prove cloud revocation.
Stopping compute does not promise restoration. Agent execution still requires its Compute grant and context.
