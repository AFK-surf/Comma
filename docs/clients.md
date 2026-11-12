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
Store it in Actions/Dependabot secrets. Fetches use it. Dependabot uses only its own secrets.
Local fetch: `OPENDROPKIT_RELEASE_TOKEN=$(gh auth token) pnpm --dir clients --filter @comma/electron build:native:airdrop`.
GitHub API archives must match pinned SHA-256 before extraction. `.native-cache` needs no token. Missing releases/downloads fail builds. No checkout needed.
Packages include helper/GPL-3.0 license without AirDrop identity entitlements. macOS rejects privately entitled helpers without relaxed signature enforcement.
Override: `COMMA_OPENDROPKIT_BINARY`, beside `OpenDropKit-LICENSE`.

Missing helpers are unavailable. Reception requires `receive --json --require-approval --exit-on-stdin-close`.
Main answers `approval_requested` with correlated stdin `approval_response`. Only approved, correlated `transfer_saved` records enter intake.

### Send files

Send/reception share anonymous Bonjour/HTTPS, a self-signed identity, and no Keychain. Recipients need Everyone. Contacts Only rejects anonymous senders.
Assisted wake-up permits sleeping Bonjour devices. No system-transfer fallback or alternate recipient exists.
Verify remote contacts and release-signed packages separately.

## Native Apple clients

[Targets](../clients/apps/apple/project.yml): iOS18/watchOS11, iPhone Task sheets retain Home, iPad split.
iPhone: client core. Watch: HTTPS/Keychain. Authority fences streams/results. Foreground SSE≤2, auth30s. Background closes. No Task timers.
Pages24/100/50, explicit more. Draft response/source/connection checks. Cancel retains text until canonical recovery.
Retry IDs/canonical Messages reconcile. Attachments8×10MB/Message, authorized downloads, iOS isolated Dynamic UI, Watch widget summaries.
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

## Comma device setup

[Client core](../clients/packages/core/src/device-setup/controller.ts) owns foreground iOS and macOS Bluetooth setup.
Android keeps its Kotlin flow. All four board sources project as Comma devices.
Apple hosts use CoreBluetooth. Protected `info` reads start system pairing. Peripheral identifiers belong to one scan session only.
The device supplies paged 2.4 GHz Wi-Fi results. Writes use responses and contain at most 512 UTF-8 bytes.

Setup creates credentials after Wi-Fi connects. The host stores revocation records before credentials reach the board.
iOS uses Keychain records with a SQLite index. Electron Main uses encrypted SQLite records through `safeStorage`.
The native core channel carries UI calls. Neither credential values nor GATT values enter the renderer.
Explicit revocation failures retain retry records, even if the device later connects.
A device that reports it saved its credentials confirms its record, even before it comes online.
Other unconfirmed records are confirmed by online status or `system_info`, or revoked after 15 minutes without that evidence.
An unavailable device read retains the record. Remove revokes known credentials before deleting the device and instructs the user to factory-reset it.

Each app runs one foreground setup, keeps at most 50 scan results and queues at most 100 native events.
The online check reads one device every two seconds for at most 90 seconds. Device list reads reconcile at most 20 pending records.
The simulator and fake ports verify UI and software behavior. Apple permission prompts, passkey and Just Works pairing, and prepared writes require physical-device checks.

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

Electron, iOS, and Android restore saved Sessions and account caches before startup validation (Peng, 2026-10-29).
See [native session recovery](identity-security.md#saved-native-sessions) for outage, retry, and revocation behavior.

Owners supply Conversation/Task facts. Drafts/optimistic Messages/streams are projections, not durable history. Sends do not prove provider delivery.
Devices keep draft text. Draft files last while the Conversation is shown and 30 s after. Android keeps it shown while composer pickers/camera are open (owner, 2026-10-29).
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
With `app_id`, the panel runs that app of `workspace_id` alone. A Telegram app button opens it.
Pages load 20 Tasks. `conversation_id` reads properties/Worker. `workspace_id` shows the last 20 cross-channel messages, latest Worker first.
Details open Comma Web. Failed reads clear content.

### Quick Chat

macOS 26 or Windows 10 2004+, non-guest login. Double-tap ⌘ (Windows: Ctrl) alone (presses and gap ≤0.4 s each) or choose Quick Chat in the menu-bar (Windows: tray) menu, which any click on its item opens.
Settings > Keyboard shortcuts records the shortcut (client setting `quickChatShortcut`, null = default): the helper watches a double-tapped lone modifier (⌘ ⌥ ⌃ ⇧; Windows: Ctrl Alt Shift); Main holds a chord as a global shortcut and sends the helper `listen`.
Settings > App defaults on. Off stops helper/releases shortcut.
Clips ≤60 s. Return finishes pending clips. Click/type edits. The modifier tap or chord resumes.
Words come from live dictation as spoken; its final words are sent. Without it, clip transcription shows them after each pause. Helpers: `clients/apps/electron/native/{macos,windows}/QuickChatHost`.
At Return an open Home shows the words as a message being sent; the final words replace them. A failed preparation fails it.
Close and Esc discard. Click away/30 s without new words close, keeping them.
Notch keeps sent words. Windows has no Notch: a failed send notifies and its words wait for the next Quick Chat. Accepted, it says Sent; a click opens Home in the words' workspace.
A running Task the Router makes from them takes the row until it stops; a click opens the Task.
Each Notch row has a × button: it leaves the Notch until its Task runs again.
Retry failed rows with the same words/id, or remove refusals. Sends keep Return order.
Router handles replies, Task continuation, or creation as typed Chat.

Live dictation: `POST /v1/comma/me/dictation/tickets` (a full session; guests get 403) returns a one-minute, single-use ticket and the socket URL.
`GET /v1/comma/dictation?ticket=…` takes 16 kHz mono s16le PCM and `{"type":"end"}`, and returns `partial` (the segment so far) and `final` words per segment, then `done`.
It uses the meetings' live ASR provider (`meetings.live_asr`). Without one, the ticket call returns 503 and clients use clip transcription.
It knows only Mandarin and English, so its words are partials. A segment's final words are the `transcription` model's dictation of its audio; the provider's if that fails or exceeds what the audio can hold; none if the provider heard no words.
Bounds: two sockets per member on a node, 3 minutes of audio, 5 minutes of socket, 30 seconds without audio. The server stores no audio. [Socket](../systems/apps/comma_web/lib/comma_web/dictation_socket.ex).

## Chat dynamic UI

Workers deliver Task widgets. Routers retain routing/blocks. [Tool rules](../systems/apps/salix_agent/lib/salix_agent/tools/dynamic_ui.ex) apply.
`dynamic_ui` is immutable Message/blob content.
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
It makes manual fields. The runtime has token defaults, the phone page icons. Hosts can supply tokens/copy/icons/logos/time zone. Templates render text, HTTPS links, bounded lists.
Cards are the default. The ui.create summary lists kinds.
Card text stays in the card: descriptions wrap, fixed-slot names/labels take one line with an ellipsis. Ids/filter keys stay unchanged.
The root is one `--container-md` column with `--spacing-lg` between visible top-level elements. Bare content gets a card shell.

Hosts cache authorized payloads by identity/version; Mac/web prefetch.
Loading, unloaded, released widgets keep an empty slot at last height.
Mac/web run up to three frames; a fourth displaces the oldest offscreen widget, resuming when visible; one with no slot creates no frame.
Summaries replace unavailable widgets: Web, static surfaces, a `version` above the runtime level, failures, visible reads over 1 s, displaced frames.
ui.create checks literal update targets; a failed part shows a note, widget-wide faults stop it.

iOS/Android open one widget per native sheet after a tap. Closing destroys it. The same origin, state, proposal, and authority rules apply.

Follow-ups retain widgets. Redesigns create immutable versions in the Task. Widgets use Comma appearance, not OS.
Themes retain runtime/state. Motion uses Comma tokens/reduced motion. Creation/restoration has no entrance animation.

Storage events sync windows. Local events sync copies. New versions start empty. Storage failures show error/summary.
Reopening never polls business APIs or creates reminders/Tasks.
`comma.request` proposes text outside iframe. Users must add it to the trusted composer and send.
Drafts retain original Task/Conversation reply targets. Proposals cannot invoke Agents/native capabilities.
Server scheduling owns reminders. Countdown zero does not prove notification delivery.

## Mini-app runtime

This section covers Mac and web. See the [iOS runtime](../clients/apps/apple/README.md#mini-apps) and the [Android runtime](../clients/apps/android/README.md#mini-apps).

A [Mini App](architecture/DOMAIN_CONCEPTS.md#mini-app) runs in an opaque iframe with `sandbox="allow-scripts allow-forms"`.
The [runtime](../clients/packages/chat-contract/src/mini-app/runtime.ts) loads from `comma-app://runtime/` on Mac or `/app-runtime/` from the web Worker.
CSP repeats the sandbox, permits the runtime script hash, and blocks network, nested frames and form submissions. Storage APIs and the native preload are unavailable.
Electron permits only the runtime URL, `blob:` and `data:`. It blocks frame navigation and redirects.
Declared `usb` and `bluetooth` capabilities add `usb *` and `bluetooth *` to the iframe policy. Device selection requires a user gesture and consent.
Electron supplies the chooser and keeps device grants in memory. Browser grants belong to the top-level Comma origin, not individual apps.
Apps with that capability can reuse authorized devices. A separate iframe origin does not change that boundary.
The microphone SDK lists capabilities. `start` is mono. `startChannels` selects channels. No app-domain mapping is required.

The host owns handshake, port, frame limits and liveness. It accepts only its frame's messages.
The runtime installs the SDK and loads one module script without relative imports. Stopped frames show "This app is paused".

The [core broker](../clients/packages/core/src/miniapps.ts) binds every SDK call to the session opened by the host, never frame-supplied identity.
It checks the manifest, platform, guest rules, and grants before each effect.
Its source comments define invocation, storage, session, and bundle-cache bounds.
Device storage belongs to one account, Workspace, and app.
`calendar.read` requires Calendar access in Mac apps. `notifications` uses the Web Notification API.

The host shows the app name, Report action, and author. Apps use the template's design guide unless the user requests another appearance.
Task and gallery cards open the app in the right panel. On Mac, the panel can move to a separate app window.
Publication is available while the Task is in review. Deleted, unshared, or disabled apps show an unavailable card with the reason.
The Apps page supports search, creation, and gallery or list views. Cards use the Version's cover, otherwise its icon.

Web `/a/<token>` serves the main app with `no-store`, `no-referrer`, and `noindex`, then opens `#/apps/link/<token>`.
"Open in Comma for Mac" uses `<scheme>://apps/link/<token>`. Main routes it to the same page.

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
