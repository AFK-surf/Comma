# Client contracts

## AirDrop files

Signed-in Main runs one anonymous OpenDropKit listener. Settings → General `showInAirDrop` defaults on.
Name: `airDropName`, else `<profile name or email local part>’s Comma`.
Disabling hides Comma. Renaming restarts it. Both fail transfers.
Offers use the focused chat toast, otherwise Notch before Tasks. Both answer Main through `airDrop.state`/`airDrop.act`.
Accept stages draft files for review/send. Reception never sends Messages. Decline/dismissal/timeout reject before upload.
Missing chat/directories cause explained rejection. Sender names are unauthenticated.

Main owns transfer state (`offer`/`receiving`/`completed`/`failed`), title/subtitle, QuickLook, and received paths.
Single files show names, then larger previews. Placeholders preserve size. Multi-file titles count offers, then attachments.
Helper progress arrives about once/second. Views cap it at 99% until persistence. Unknown sizes show indeterminate rings without percentages.
`transfer_warning` only logs. `receiving` requires listener confirmation. Saved-file events prove persistence, not sender acknowledgement.

Expanded Notch shows only transfers. Compact titles widen within a limit. Results last 4 s, then Tasks return.
Toast expiry: completion 6 s, failure 10 s. Unattached files await Finder/dismissal. `airDrop.act` holds focus. Release restarts expiry.
`showInNotch` defaults on. Off ends NotchHost. On replays Main's latest scene. `notchSideWidth` affects Task Notch only.

Main pins the arrival destination. Navigation/account changes/shutdown reject stale intake. Intake failure retains files with Show in Finder.
Helpers publish files beside sender packages such as Live Photo `.pvt` directories. Files attach. Empty bundles disappear. Nonempty bundles remain, counted as not added.
Images use upload intake. Other files use local registration. Oversized full-resolution HEIC-to-JPEG results use a 4096px longest edge.
Thumbnails decode at most 48 megapixels and render within 4096px. Draft limits: 8 uploaded images, 50 local references, 1 GiB local bytes.

`comma airdrop status` reports receiver/sender availability. `files` lists received files.
Agents use `comma-client`/live catalog with device operation permission. Native reception/UI needs no Agent permission or MCP connection. ChatCoordinator publishes attachments.
Files remain in `airdrop/received/<receiverId>`. Metadata: 200 entries. Queries: 100 maximum, with truncation status.
New receivers/app exit clear metadata, not files. Listening has no expiry/polling.
Approval limit: one offer, 25 s. Accepted attachment deadline: 5 minutes.
Stop/sign-out/session-generation change/exit/parent stdin closure cancel reception. Helper limit: 30 s decline, four connections.

### Native helper

Builds use `clients/apps/electron/scripts/opendropkit-release.json`.
Use an AFK-surf-owned fine-grained `OPENDROPKIT_RELEASE_TOKEN`, limited to private `AFK-surf/OpenDropKit` Contents read.
Store it in Actions/Dependabot secrets. Each fetch receives it. Dependabot workflows receive only Dependabot secrets.
Local fetch: `OPENDROPKIT_RELEASE_TOKEN=$(gh auth token) pnpm --dir clients --filter @comma/electron build:native:airdrop`.
GitHub API archives must match pinned SHA-256 before extraction. `.native-cache` needs no token. Missing releases/downloads fail builds. No checkout required.
Packages include helper/GPL-3.0 license without AirDrop identity entitlements. macOS rejects privately entitled helpers without relaxed signature enforcement.
Override: `COMMA_OPENDROPKIT_BINARY`, beside `OpenDropKit-LICENSE`.

To update:

1. Publish through OpenDropKit's release workflow.
2. Set `OPENDROPKIT_RELEASE_TOKEN`.
3. Run `pnpm --dir clients --filter @comma/electron pin:opendropkit vX.Y.Z`.
4. Review the release/pin.
5. Run `pnpm --dir clients --filter @comma/electron build:native:airdrop`.
6. From `clients`, run `node scripts/airdrop-smoke.mjs`.
7. Commit the pin/protocol changes.

Client E2E covers fetched helpers. Client Build covers packaged helpers. Tests cover local TLS/refusal/parent shutdown, not radio discovery.
Missing helpers are unavailable. Reception requires `receive --json --require-approval --exit-on-stdin-close`.
Main answers `approval_requested` with correlated stdin `approval_response`. Only approved, correlated `transfer_saved` records enter intake.

### Send files

Selected files/recipients use `find`, `send`, `operation`, and `cancel`. Scans/sends return `operationId` within the Client API budget.
Main retains ephemeral state. One outbound operation runs alongside reception. Progress counts transport bytes, not receiver acknowledgement.

`find` uses Bonjour/assisted wake-up for 5 s, returning at most 64 devices. Main stops unfinished scans after 25 s.
Opaque peer IDs last 2 minutes. Resolve ambiguous unverified names. Helpers prefer computer names, without per-peer HTTPS reads.
Peer resolution: 5 s. Discovery continues through connection/approval/transfer. Completion/failure/cancellation stops discovery. JSON excludes contacts/credentials.

`send` needs paths, a peer ID, and UUID `requestId`: 1-50 distinct regular files, at most 1 GiB, one request/upload.
Paths are absolute Mac paths or `/drive`, mapped through default Synch `sourcePath`. Recordings include custom/retained legacy folders.
AirDrop never downloads/copies files or changes sync. Files must remain local inside mapped folders without symbolic links.
Missing files report sync/move/deletion errors. Copy other Task VFS files to `/drive` with `fs.copy_file`, then sync. No backend change.
Directories/symlinks fail. Any unresolved/unsendable file fails the batch before helper startup. Device operation permission covers API/client-environment access.

Request-ID reuse requires identical ordered paths/peer. Other inputs fail. Main retains 20 operations until sign-out/exit.
Agents poll at most once/5 s for 5 minutes, without automatic retries. Success requires `send_completed` and successful helper exit.
Timeout/cancellation/connection failure cannot prove retention. Cancellation cannot recall files. Session changes cancel work and clear recipients/history.

Send/reception share anonymous Bonjour/HTTPS, a self-signed identity, and no Keychain. Recipients need Everyone. Contacts Only rejects anonymous senders.
Assisted wake-up permits sleeping Bonjour devices. No system-transfer fallback or alternate recipient exists.
Local tests verify bytes/refusal/cancellation with system sender and independent OpenDropKit receiver. Remote contacts/release-signed packaging need separate validation.

## Native Apple clients

[Targets](../clients/apps/apple/project.yml): iOS18/watchOS11, iPhone sidebar/iPad split, Task sheets retain Home.
Core: app/backend HTTPS/Keychain Auth Sessions/canonical Router. Session changes cancel streams/stale results.
≤2 foreground SSE: Home + Group Tasks/Task Participants, auth30s. Background closes. Bounded coalesced reads, no Task timers.
Pages transcript/history/Tasks:24/100/50, explicit more. Cumulative draft text/response/source/connection checks. Cancel keeps text until canonical recovery.
Retries reuse IDs. Canonical Messages reconcile bubbles. Attachments8×10MB/Message, authorized Message/file downloads, script-free Dynamic UI summaries.
Watch pairs once: revocable Keychain/network bearer: Home/Tasks/messages/review. Phone revocation revokes Watch. Disconnect errors preserve accepted work.

One switchable/stoppable Live Activity. Saved auto-follow: new Comma/iOS Tasks after sidebar baseline.
Off revokes push-to-start. Failure keeps retry ID. Manual/device alerts remain.
Review checks versions, attention ≠ completion. Terminal states end UI.
Lock Screen/Dynamic Island/Watch Smart Stack: title/status, no fake %, stale2min. Links reauthorize Tasks. Widgets: no bearer.

Ordinary: explicit installation-local intent, new accounts off. Intent/OS permission/acknowledged subscription differ.
Legacy unknown choice: server-acknowledged authenticated `DELETE /v1/comma/notifications/devices`, current Auth Session `device` only. Others/activity slots unchanged.
Unsubscribe failure: unknown/last acknowledged, never falsely off. Serialize captured authority, fence stale account/Workspace. Foreground/taps reauthorize.
Scope: current Workspace default Group. Offline changes can retain old scope.
Only `ready_for_review`/`escalated`/`completed`/`failed`: generic en/zh-Hans, no title/content/Workspace/identity. Opt-out keeps Live Activity titles.

APNs: Auth Session targets, not compute Devices. Register/send reauthorize Session/Group owner/exact Task. Canonical Agent/Participant facts.
One owner subscription/Group. Recovery/fan-out100/page, four workers. No missed-start replay. ID rotation fences late deletes. Invalid/revoked targets removed.
Dev/release bundle/env/locale validation ([schema](../systems/config/config.example.json)). Activity topic: main ID + `.push-type.liveactivity`.
Secret `config.json`: `comma.apns.{sandbox,production}`. No env/cross-profile fallback.
Legacy env: only absent `comma.apns`, explicit dual-env key/verified legacy topic.
Keep nullable rows, no guessing/backfill/deletion. Only operator-trusted `legacy_bundle_id`. Re-register validated identity. Locale defaults English.
Missing config: `push_unavailable`, no registrations. Bad topic/ambiguous `BadDeviceToken`: retain. HTTP410: clean.
Row locks dedup normal sends, not crash exactly-once. Acceptance ≠ delivery/display. Device APNs/ActivityKit/Watch unverified.

## Native capability authority

Electron Main owns bearer authority; SecureStore holds tokens. `/v1` strips renderer auth, injects Main's credential, and resends unanswered reads once.
Renderer/shared code cannot import Main implementations or receive secrets.
Declare leaves in `clients/packages/native-bridge/src/capability-leaves.ts`:

- `defineNativeCapability`: typed command/result.
- `defineNativeEvent`: fire-and-forget event.
- `defineNativeState`: owner-controlled replay-last snapshot/get/subscribe.

Leaves declare zod I/O, permissions, handlers, and mock/web fallbacks. Generate contracts, bridge types, bindings, and manifest. Never hand-edit them.
Renderers use `getNativeBridge()`; aliases grant no authority.
Only owner mutation/snapshot paths publish through composition-root wiring, never renderer/gateway/dev surfaces.
No raw IPC outside the gateway; the legacy allowlist only shrinks. Mark unavailable paths `needs-capability`/`planned`, not fake data.

## Session and history boundaries

Product authentication differs from runtime Sessions. Reloads recover canonical history in the same Conversation.
Auth changes stop prior work and reject late results. Never reuse another account's credentials/Messages/browser state/imports.
Profiles/protocols preserve flavor, app identity, and update channel. Diagnose updates with version/feed. Development does not prove packaged startup/updates.
Host tests cover login/logout/reload/account switches/stale responses.

Shared host gate: retryable failures spin/retry at 0/1/3/10/30 seconds. Main deadline: 5 s.
Exhaustion shows failure. Online/Retry restarts. Credential/protocol failures and failed sign-outs require explicit retry.
Web checks Cookies at startup/retry/product 401/409/peer hints, not focus. Live-lease signed-in tabs retain views after failed checks.
They recheck after 1/3/10/30 seconds. 409 adopts the Cookie session. Account changes remount/toast.
Session responses permit extra fields. `token` is a protocol mismatch. Content requires verified credentials/product leases.
Identity-free recovery requires initialization/indeterminate state. Main checks stored credentials/backend/generation/account before publication.

Owners supply Conversation/Task facts. Drafts/optimistic Messages/streams are projections, not durable history. Sends do not prove provider delivery.
Reconcile pending/canonical Messages without duplicates/lost updates. Task views immediately show known properties.
Visible cards cache recent Messages before navigation. See [history preparation](salix/conversation-owner-actor.md#history-and-projections).
Metadata cannot mark history read or enable review/label mutations. Terminal errors hide summaries. Newer summary status wins.
Home/Task render six initial units, eight per upward expansion, at most four Messages/unit.
Viewport fill/explicit targets can expand without splitting logical turns. Agent-only histories open at the tail.
See [Conversations](salix/conversation-owner-actor.md) and [Tasks](salix/tasks-background-execution.md).

## Browser and desktop

Browser navigation/permissions/side-chat/memory sessions/shortcuts have distinct native owners.
Web mocks cannot prove Electron permission/Keychain/protocol/window behavior.
Separate app commands/browser requests. Page content grants no tool/account authority.

### Embedded Task panel

Comma Web `/task-panel.html?group_id=…&workspace_id=…` checks Task access.
Telegram `/tasks` verifies signed launches for bound users’ 24-hour read-only Group sessions. Failure offers Comma login.
Startup shows progress. Web Cookie authority locks the exchange, saves recovery, and adopts the session ID.
WeChat `任务列表` requires Comma login. URL IDs grant no access.
Pages load 20 Tasks. `conversation_id` reads properties and Worker. `workspace_id` shows the last 20 cross-channel messages, latest Worker first.
Details link to Comma Web. Read failures clear content.

### Public Task Share page

Comma Web `/s/<token>` shows one shared Task. It holds no Comma session and sends no credentials.
The Task header's Share dialog previews the latest messages of the Task. It creates, updates, resets, or stops the link.
See [Task Share](architecture/DOMAIN_CONCEPTS.md#task-share).

## Chat dynamic UI

Workers deliver Task widgets. Routers retain routing/blocks. [Tool rules](../systems/apps/salix_agent/lib/salix_agent/tools/dynamic_ui.ex) apply.
`dynamic_ui` is immutable Message/blob content. Web/unsupported protocols show summaries.
Activation needs canonical Agent Messages/bound blobs. Reads need Conversation authorization, not supplied blob references.

Iframe: `comma-ui://runtime/`, `sandbox="allow-scripts"`, no native overlay/preload/credentials/same-origin permission.
MessageChannel binds its window. `null` origin grants no identity. Runtime rebuilds allowlisted components. Only scripts require DOM-free Workers.
Refresh proposes input. Countdowns use absolute time. CSP blocks connection APIs/nested frames/forms, but permits HTTPS images/styles/fonts/scripts.
HTML scripts load after bootstrap disables public/prototype `importScripts`. Libraries must be self-contained/DOM-free. Resource URLs can disclose data. Exclude private data.
Electron strips Cookie/Authorization/Referer. Resources/frameless HTTPS scripts share eight concurrent requests and 128 attempts/ten seconds/window.
Redirects spend that budget and remain HTTPS. No transfer-byte/process-memory quotas exist.
Workers cannot create Workers/SharedWorkers. Electron blocks child navigation/non-resource widget requests.
Worker requests can lack frame attribution. CSP enforces networking, not attribution/CORS. `main/security.ts` owns Session request hooks.

`comma.card` fills empty elements with fitting client templates. ui.create checks `comma.data` against the [card contract](../clients/packages/chat-contract/src/dynamic-ui/cardContract.ts).
That contract generates manual fields. Hosts supply tokens/copy/icons/logos. Templates render text, HTTPS links, bounded lists, and readable entries.

Per window: three widgets. Offscreen Workers release after 1.5 seconds with a 240px margin. Hidden windows retain runtimes.
Hosts cache authorized payloads by identity/version. Unloaded widgets retain height.
Per widget: 256 KiB content, 500 nodes, depth 20, eight charts, 60 updates/second (one/Worker task).
Charts: 64 values, 800 × 320 canvas. Intervals: once/second. Height reports: ten/second. Watchdog: 1.5 seconds. No hard Worker memory quota.

Help defines twelve archetypes/layout axes/shared shell. Widgets own detail. Prose adds conclusions/caveats. Trusted HTTPS clicks open sidebar.
Follow-ups retain widgets. Redesigns create immutable versions in the original Task. Widgets use Comma appearance, not OS.
Themes retain runtime/state. Motion uses Comma tokens/reduced motion. Creation/restoration has no entrance animation.
Height follows content, capped at 12,000px, without expand/collapse. Chat owns scrolling. Bound channels forward native wheel input. Workers cannot emit scroll intent.

State: 32 KiB/version keyed by API endpoint/account/Workspace/immutable blob. Card progress has separate 32 KiB.
Storage events sync windows. Local events sync copies. New versions start empty. Storage failures show error/summary.
Reopening never polls business APIs or creates reminders/Tasks.
`comma.request` proposes text outside iframe. Users must add it to the trusted composer and send.
Drafts retain original Task/Conversation reply targets. Proposals cannot invoke Agents/native capabilities.
Server scheduling owns reminders. Countdown zero does not prove notification delivery.

## SSH terminal client

`comma_ssh` provides opt-in OTP SSH. `comma_tui` owns input/editing/layout/rendering.
See [setup](development.md#ssh-terminal-development) and [credentials](identity-security.md#ssh-account-access).
Clients use `comma`, public keys, and PTY. OTP verifies signatures before email enrollment. Known keys open revocable Auth Sessions.
One workspace opens chat. Multiple show a picker. `Comma.AssistantChats.ensure_chat`/`Comma.Conversations` reuse desktop Router Conversations.
No new Routers/Runtime Sessions/Conversations result. Mutations use `ConversationServer -> ConversationActor`.

UI: Messages/input/activity/workspaces/keys. Enter submits. Alt+Enter inserts lines. Paste never submits.
Up/Down traverse lines, then inputs at composer boundaries. Down past newest restores draft/cursor. Edits start drafts.
Connections retain 100 inputs, excluding enrollment/workspace selections. Wheel/PgUp/PgDn scroll chat/help.
Commands: `/help`, `/workspace`, `/keys`, `/revoke KEY_ID`, enrollment `/resend`, `/quit`, Ctrl+D.
Unknown commands fail locally. `/stop` reports unsupported cancellation. Busy sends retain drafts and require Enter later.
Nothing queues/resends automatically. Attachments direct users to Comma.

Strip content controls before trusted colors. Credential-free `init`/`update`/`view` models return host effects.
Emoji widths depend on fonts. OTP owns cryptography.

Footer caches fifty authorized canonical Tasks. Initial/coalesced-invalidations reads run at most four/second, without per-Task polling.
Incomplete pages show `≥N running`. Failures show `Tasks unavailable`. Reconnect restores subscriptions. Workspace changes clear count/subscriber.
Subscribe before snapshots. Validate drafts separately from committed Messages.
Owner loss requests reconnect. Private Runtime Session history remains hidden.

Bounds: 64 KiB decoder, 16 KiB composer, 100 Messages, 8,000 characters/Message, 240x100 layout, 20 renders/second,
256-message mailbox checks, two-second output timeout, twenty-second command deadline. Timer references reject stale timeouts.
Timeout/service failure restores terminal with persistent reconnection/uncertain-delivery guidance. Authorization fails closed. Disconnect preserves accepted work.
N chats cost O(N)/30 seconds for idle authorization. Invalidations add at most four bounded snapshot/status reads/second/chat.
No timers scan workspace children. Authorize Session/workspace before commands/refreshes. Lost account/membership closes terminal/subscription.
Sends retain one request ID. Uncertain acknowledgments never trigger resends. Reconnect restores canonical history. Check before resending.
Unsent text is connection-local. Comma retains older history/rich attachments.
[SSH source](../systems/apps/comma_ssh/lib/comma_ssh/chat.ex).
