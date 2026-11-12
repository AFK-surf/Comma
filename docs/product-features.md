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

File cards separate Preview and Open in. Download lives in the preview sidebar.
Eligibility does not guarantee availability. Attachments stream at any size without whole-file buffering.
Audio/video playback and attachment downloads use [media URLs](identity-security.md#attachment-media-urls), bypassing Comma's byte path.
Desktop Main reads playback ranges, streams downloads to disk, and copies saved files. Web reads media URLs directly.
Previews stream images, range-read PDFs, and read the first 256 KB of text.
Focused PDFs accept ←/→ and Page Up/Down, except with modifiers or in editors. Single-page PDFs leave keys alone. HTML has no deck protocol.
Text/Markdown previews take highlighted annotations in an editable list.
Notes use window sessionStorage per Workspace/Group/Conversation/attachment: 100 notes, 4,000 chars per quote/comment.
Send gives Router/Worker preview quotes with context as a message, or a text file above 16,000 chars.
It keeps composer drafts. Local edits leave sent messages unchanged. No PDF/HTML/region annotations yet.

Add to Context reuses the attachment blob as a Router VFS composer file without client byte transfer.
Phone apps download before opening and stream uploads from disk.
Paths grant no disclosure or provider access. Use owner-backed file/capability paths and report unavailable content.
Drive mentions/catalogs retain source scope and bounded lookup, without full scans.

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
Each member's brief is written from their messages since their last brief and their main channels' talk, the team brief, and their last brief: the main line in one sentence, a section per topic, then what needs them, what moved, related work, and what to skip.
A thread that continued comes with its first message as context.
A link in it is a cited message or a URL from the messages; other links are removed, and keys and tokens of known formats keep only their prefix.
Briefs read the bot's public channels; a member may let their own brief read their direct messages with a read-only Slack grant (never stored).
In Slack, a member can ask the Swarm's bot to move or refocus their own brief, and an owner or admin the team brief (`daily_brief.*`, the requester from the signed message).
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

Visibility is `private` (the creator), `workspace` (the Router's apps) or `link`.
Links (`https://app.comma.surf/a/<token>`) open in Comma web or Mac. Registered viewers can Install the app in their Workspace or remix it into their own GitHub repository.
Web viewers can sign in or continue as guests. Guests reach only their link app's routes. They cannot list, create, install or remix apps.

Apps use only declared capabilities.
Grants are per Workspace, per call (`tasks.create`, `files.pick`, `links.open`, `camera`, `clipboard.read`) or none (`chat.draft`, `clipboard.write`, `screen.wake`, `fullscreen`, `share`, `haptics`).
The host runs [devices](../resources/mini-app-template/README.md#device-capabilities).
The grant sheet names the backend `egress` hosts. Settings > Apps revokes grants and removes Installs.
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

Shells use `shell.default`: public Internet, 2048 PIDs, and 16 GiB of writable disk.
Host rules block private and metadata addresses. CPU and memory are shared.
Tools include Python/pip/venv, Node/npm, Git/SSH, curl/wget, ffmpeg, pandoc, jq, C/C++/make, and archives.
Install user packages under `/workspace` or in a venv. The user is non-root. Root is read-only.
Existing Workloads keep their spec, image, files, and accepted execution. Reconnect does not upgrade them.

Salix owns image, command, and resource policy. Forms accept no arbitrary images or commands.
Compute placement uses the Environment's eligible binding. Acceptance does not prove runtime readiness.
Clients keep a creation key for response loss. Other views refresh manually. Reads never retry creation.
The admin receipt and creation commit together. Replaying creates no second Workload.

The backend needs its runtime bundle manifest. Missing templates or capacity reject creation.
An enrolled but disconnected Host returns `node_offline`. Host installation alone supplies no backend manifest.
The reconciler starts it and reports failures.

## Compute Node settings and initialization

**Devices** groups local Compute and Workspace Workloads. Old Compute links open it. Its card lists agents, access and sandbox without waiting for Shell.
Codex and Claude Code each select Mac login, local model server, Workspace account, or none. Read Mac logins only after selection. Local server addresses stay on the station and must be reachable from this Mac. Their Tasks run here.
One short-lived ticket authorizes a Registration. The Host saves credentials before claim. Lost replies repeat the claim. No enrollment token, material handoff or installation ACK exists. Salix creates one Shell with a stable key on first connection. Reads and deletion never recreate it.

The card has one status/action. Continue retains its target across restart. Pending enable permits cancel/removal. Failed removal never enables. Software/storage share a page. Diagnostics stay collapsed. Disk splits images/runtime, build cache and private data. Missing categories stay unknown.
Visible Workloads refresh after binding changes/mutations, including unknown replies. Shared-clock reads serialize one page plus at most one pending/selected off-page target.
Show one row status. Scope errors to their read or action, once; matching owner results clear them. Unknown deletion retains ID/generation. Legacy ID-only deletion needs fresh consent and exact generation/permission checks. Reuse its ID. Only owner receipts supply its original generation. Post-write 403/404 proves neither refusal nor deletion.

Local data groups use neutral headings/menu actions. Another connection never authorizes disposal. Main uses exact IDs. Unknowns stay neutral. Only native plans give complete deletion scope/count. Local deletion/Host clearing use one trusted Main/native confirmation. Repeats retain receipts. Local revocation prompts explicit cloud disconnection. Local management needs no cloud login. Cloud deletion confirms separately.

Details keep known names/facts during setup. Omit absent usage. Internet policy grants no LAN access. Rename retains the last name. Retry/deletion fence generation. Owners can read, rename or request Shell deletion offline. Business Workloads require their owner.
Deletion closes input and settles accepted work before exclusive Allocation disposal. Updates must finish/cancel first. Offline deletion waits for the original Mac. New connections cannot clean its target.
Default pages omit completed deletions/cloud-retired rows before pagination. Recoverable failure/cleanup stays. Exact details retain terminal outcomes and unconfirmed local data. Cloud retirement is not file deletion. Owners, receipts and unknowns survive list removal. Only exact Host disposal receipts or proven dispatch absence prove **Deleted**. Missing rows/404s do not. See [authorization](architecture/DOMAIN_CONCEPTS.md#7-devices-and-compute).

Native owns locks/receipts. An idle failed claim cannot lock the Host. Main retains one intent with bounded backoff and a 45-minute automatic window. Expiry pauses automatic work, explicit Continue keeps the request. Stop retains Registration. Removal revokes it and keeps files. Unknown work retains its exact target, never replays as new work.
After seven days without authenticated Host contact, reject the credential. Login expiry alone does not. Current product permission plus original-root proof recovers the same Registration, Workloads and files. Revoked/disposed/retired targets cannot recover. BFT keeps one live Host per stable Project across Group changes. Comma permits separate authorized Macs.

Update/repair/uninstall preserve data. Only explicit confirmed clearing may erase it, never failure counts, version mismatch or unreadable state. Unsupported operations fail at their owner. Remote too_old offers Host update. Too_new waits for service compatibility. Newer unsupported helpers require Comma update. Reads never download bundles. New repair artifacts supersede exact requests. Original artifacts stay fixed. Workspace removal retires its Registration. Local detachment does not prove cloud revocation.
