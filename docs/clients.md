# Client contracts

## AirDrop files

Signed-in Main runs one anonymous OpenDropKit listener. Settings → General `showInAirDrop` defaults on.
Name: `airDropName`, else `<profile name or email local part>’s Comma`.
Disabling hides Comma. Renaming restarts it. Both fail transfers.
Offers use the focused chat toast, otherwise Notch before Tasks. Both answer Main through `airDrop.state`/`airDrop.act`.
Accept stages draft files for review/send. Reception never sends Messages. Decline/dismissal/timeout reject before upload.
Missing chat/directories cause explained rejection. Sender names are unauthenticated.

### Native helper

Builds use `clients/apps/electron/scripts/opendropkit-release.json`.
Use an AFK-surf-owned fine-grained `OPENDROPKIT_RELEASE_TOKEN`, limited to private `AFK-surf/OpenDropKit` Contents read.
Store it in Actions/Dependabot secrets. Each fetch receives it. Dependabot workflows receive only Dependabot secrets.
Local fetch: `OPENDROPKIT_RELEASE_TOKEN=$(gh auth token) pnpm --dir clients --filter @comma/electron build:native:airdrop`.
GitHub API archives must match pinned SHA-256 before extraction. `.native-cache` needs no token. Missing releases/downloads fail builds. No checkout required.
Packages include helper/GPL-3.0 license without AirDrop identity entitlements. macOS rejects privately entitled helpers without relaxed signature enforcement.
Override: `COMMA_OPENDROPKIT_BINARY`, beside `OpenDropKit-LICENSE`.

Missing helpers are unavailable. Reception requires `receive --json --require-approval --exit-on-stdin-close`.
Main answers `approval_requested` with correlated stdin `approval_response`. Only approved, correlated `transfer_saved` records enter intake.

### Send files

Send/reception share anonymous Bonjour/HTTPS, a self-signed identity, and no Keychain. Recipients need Everyone. Contacts Only rejects anonymous senders.
Assisted wake-up permits sleeping Bonjour devices. No system-transfer fallback or alternate recipient exists.
Remote contacts and release-signed packaging need separate validation.

## Native Apple clients

[Targets](../clients/apps/apple/project.yml): iOS18/watchOS11, iPhone Task sheets retain Home, iPad split.
iPhone: client core. Watch: HTTPS/Keychain. Authority fences streams/results. Foreground SSE≤2, auth30s. Background closes. No Task timers.
Pages24/100/50, explicit more. Draft response/source/connection checks. Cancel retains text until canonical recovery.
Retry IDs/canonical Messages reconcile. Attachments8×10MB/Message, authorized downloads, script-free Dynamic UI.
Watch revocable bearer: Home/Tasks/messages/review. Phone revocation revokes Watch. Errors preserve work.

Ordinary local intent: new accounts off. Intent/OS permission/acknowledgment differ.
Unknown intent: authenticated `DELETE /v1/comma/notifications/devices`, current Session device slot only.
Failed unsubscribe stays unknown/last acknowledged. Authority fences account/Workspace changes. Scope: Workspace default Group, old scope possible offline.
Router/provider assistant replies: generic en/zh-Hans banners, absolute unread badges. Inbound/tool/hidden Messages do not count.
Workspace read position/counts. Enrollment skips history. Reconcile100 Messages/turn, queued continuation.
`GET .../router-notifications`: unread state. `POST .../router-notifications/read`: canonical Message ID ACK.
Active unobscured Home acknowledges visible committed Messages. Task sheets/background do not. Foreground/session synchronize badges.
Review/escalation/completion/failure alerts omit title/content/Workspace/identity. Opt-out preserves Activity titles.

APNs reauthorizes Session/Group owner/facts. One subscription/Group. Recovery/fan-out100/page, four workers, missed starts/updates/badges.
Rotation fences late deletes. Revoked targets expire. Bundle/env/locale: [schema](../systems/config/config.example.json).
Secret `config.json`: `comma.apns.{sandbox,production}`, no profile fallback. Activity topic: main ID + `.push-type.liveactivity`.
Legacy env requires absent `comma.apns`, dual-env key/verified topic. Nullable rows remain. Only operator-trusted `legacy_bundle_id`. Locale defaults English.
Missing config: `push_unavailable`, no registrations. Bad topic/ambiguous `BadDeviceToken`: retain. HTTP410: clean.
Target leases serialize sends, not crash exactly-once. Acceptance ≠ display. Device APNs/ActivityKit/Watch need verification.

## Native capability authority

Electron Main holds bearers in SecureStore. Renderer/core `/v1` strips caller auth, injects Main's credential and retries unanswered reads once. Renderers/shared code get no Main imports/secrets.
`native-bridge/src/capability-leaves.ts` defines commands, events and owner-published replay-last states with zod I/O, permissions, handlers and mock/web fallbacks. `getNativeBridge()` aliases grant no authority.
Unavailable paths are `needs-capability`/`planned`, not fake data.

## Session and history boundaries

Product auth differs from runtime Sessions. Reloads recover that Conversation's canonical history.
Auth changes stop prior work and reject late results. Never reuse another account's credentials/Messages/browser state/imports.
Profiles/protocols retain flavor, app identity and update channel. Diagnose updates by version/feed. Development cannot prove packaged startup/updates.

Web 409 adopts Cookie session. Account changes remount/toast.
Session responses permit extra fields. `token` is a protocol mismatch. Content needs product leases.
Identity-free recovery requires initialization/indeterminate state.
Main/phone apps keep bearers. The core keeps refs. Snapshots move the gate first. Other generations fail. With the core away, only the last lease applies and 401 shuts it.

Owners supply Conversation/Task facts. Drafts/optimistic Messages/streams are projections, not durable history. Sends do not prove provider delivery.
Reconcile pending/canonical Messages without duplicates/lost updates. Task views immediately show known properties.
Visible cards cache recent Messages before navigation. See [history preparation](salix/conversation-owner-actor.md#history-and-projections).
Metadata cannot mark history read or enable review/label mutations. Terminal errors hide summaries. Newer summary status wins.
Viewport fill/explicit targets can expand without splitting logical turns. Agent-only histories open at the tail.
Visible Home follows ≤2 Task feeds for Worker status.
See [Tasks](salix/tasks-background-execution.md).

## Browser and desktop

Browser navigation, site permissions, memory sessions, and shortcuts have distinct native owners.
Separate app commands from browser requests. Pages, renderers, and page content cannot override native permission, tool, or account authority.

### Embedded Task panel

Comma Web `/task-panel.html?group_id=…&workspace_id=…` checks Task access.
Telegram `/tasks` uses [Mini App login](identity-security.md). Failure offers Comma login.
Startup shows progress. Core locks exchanges, saves recovery and adopts sessions.
WeChat `任务列表` requires Comma login. URL IDs grant no access.
Pages load 20 Tasks. `conversation_id` reads properties/Worker. `workspace_id` shows the last 20 cross-channel messages, latest Worker first.
Details open Comma Web. Failed reads clear content.

### Quick Chat

macOS 26, non-guest login. Double-tap ⌘ alone (each press ≤0.4 s, gap ≤0.4 s) or click the menu bar.
Settings > App defaults on. Off stops helper/hides shortcut.
Clips ≤60 s. Return finishes pending clips. Click/type edits. ⌘ resumes.
Close discards. Esc/click away/30 s without new words close and retain words.
Notch keeps sent words. After acceptance, it says Sent and a click opens Home in the words' workspace.
A running Task the Router makes from them takes over the row until it stops; a click opens the Task.
Retry failed rows with the same words/id, or remove refusals. Sends retain Return order.
Router handles replies, Task continuation, or creation as typed Chat.

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
It generates manual fields. Hosts supply tokens/copy/icons/logos/time zone. Templates render text, HTTPS links, bounded lists, and readable entries.

Hosts cache authorized payloads by identity/version. Unloaded widgets retain height.

Follow-ups retain widgets. Redesigns create immutable versions in the original Task. Widgets use Comma appearance, not OS.
Themes retain runtime/state. Motion uses Comma tokens/reduced motion. Creation/restoration has no entrance animation.

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

Commands: `/help`, `/workspace`, `/keys`, `/revoke KEY_ID`, enrollment `/resend`, `/quit`, Ctrl+D.
Unknown commands fail locally. `/stop` reports unsupported cancellation. Busy sends retain drafts and require Enter later.
Nothing queues/resends automatically. Attachments direct users to Comma.

Strip content controls before trusted colors. Credential-free `init`/`update`/`view` models return host effects.
OTP owns cryptography.

Owner loss requests reconnect. Private Runtime Session history remains hidden.

Timer references reject stale timeouts.
Timeout/service failure restores terminal with persistent reconnection/uncertain-delivery guidance. Authorization fails closed. Disconnect preserves accepted work.
N chats cost O(N)/30 seconds for idle authorization. Invalidations add at most four bounded snapshot/status reads/second/chat.
No timers scan workspace children. Authorize Session/workspace before commands/refreshes. Lost account/membership closes terminal/subscription.
Sends retain one request ID. Uncertain acknowledgments never trigger resends. Reconnect restores canonical history. Check before resending.
Unsent text is connection-local. Comma retains older history/rich attachments.
[SSH source](../systems/apps/comma_ssh/lib/comma_ssh/chat.ex).
