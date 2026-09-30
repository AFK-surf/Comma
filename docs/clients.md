# Client contracts

## AirDrop files

Signed-in Electron Main runs one anonymous OpenDropKit listener when `showInAirDrop` is on, the macOS Settings → General default.
Its name is `airDropName`, else `<profile name or email local part>’s Comma`.
Disabling hides Comma; renaming restarts it. Both fail active transfers.
Offers use the current chat toast or, without chat focus, the Notch before tasks. Both answer the same offer.
Accept stages files in that chat's draft for user review/send. Decline, dismissal, or timeout rejects before upload.
Missing chat or offered directories cause immediate explained rejection. Sender names are unauthenticated.

Main owns `airDrop.state` and `airDrop.act`; toast and Notch project the same status, title, and subtitle.
Transfers move from `offer` to `receiving`, then `completed` or `failed`.
Main generates QuickLook thumbnails. A single file shows its name during the offer and a larger preview afterward.
Kind placeholders preserve size until previews arrive. Received paths stay in Main.
The helper reports `transfer_progress` about once/second. Toast and Notch show progress capped at 99% until files are saved.
Unknown sizes show an indeterminate ring and no percentage. `transfer_warning` is logged, not fatal.

Notch expansion shows only the transfer card.
Multi-file titles count offered files, then added files. Single-file completion shows its preview.
Long titles widen the compact Notch within a limit. Results last 4 s, then tasks return.
Completed toasts last 6 s, failures 10 s. Unattached files wait for Show in Finder or dismissal.
Focus holds results through `airDrop.act`. Release restarts the countdown.
`showInNotch` (Settings → General, default on) gates all Notch scenes in Main: off ends NotchHost; on replays the latest scene.
`notchSideWidth` sizes the Task Notch only.

The destination is pinned on arrival. Navigation, account changes, and shutdown prevent stale attachment intake.
Intake failure retains files and offers Show in Finder.
Sender packages such as Live Photo `.pvt` bundles arrive as directories; the helper publishes their files beside them.
Those files attach. Empty bundles are removed; nonempty bundles remain and count as not added.
Images use upload attachment intake; other files use local-file registration.
Oversized full-resolution HEIC-to-JPEG results re-encode to a 4096px longest edge.
Composer thumbnails decode up to 48 megapixels and render within 4096px.
Picker budgets apply: 8 uploaded images, 50 local references, and 1 GiB local bytes per draft.
Reception never sends a Message.

Client API `comma airdrop`: `status` reports reception/sender availability; `files` lists received files.
Agents discover operations through `comma-client` and the live catalog, subject to device operation permission.
Native reception and its UI require no Agent permission. No MCP connection is added; ChatCoordinator publishes attachment state.
`receiving` requires helper listener confirmation.

Files stay in `airdrop/received/<receiverId>`. Metadata holds 200 entries; queries return at most 100 with a truncation indicator.
A new receiver or app exit clears metadata, not files. Listening has no expiry or polling.
Only one offer awaits approval, for 25 s. Accepted transfers have a 5-minute attachment deadline.
Stop, sign-out, session-generation change, app exit, or parent stdin closure cancels pending reception.
The helper independently declines after 30 s and allows 4 connections.
Saved-file events prove persistence, not sender acknowledgement.

Native builds fetch the release pinned in `clients/apps/electron/scripts/opendropkit-release.json`.
`OPENDROPKIT_RELEASE_TOKEN` needs Contents read access to the private `AFK-surf/OpenDropKit` repository.
Use an AFK-surf-owned fine-grained token limited to that repository. Store it in Actions and Dependabot secrets.
CI passes it to each fetch step; Dependabot workflows receive only Dependabot secrets.
Local fetch: `OPENDROPKIT_RELEASE_TOKEN=$(gh auth token) pnpm --dir clients --filter @comma/electron build:native:airdrop`.
Authenticated downloads use the GitHub API. Each archive must match the pinned SHA-256 before extraction.
Later builds reuse `.native-cache` without a token. Missing releases/download failures fail the build; no source checkout is needed.
The script packages the helper and GPL-3.0 license. It signs without AirDrop identity entitlements.
macOS rejects privately entitled helpers without relaxed signature enforcement.
Locally, set `COMMA_OPENDROPKIT_BINARY` to extracted `opendropkit`, beside `OpenDropKit-LICENSE`.

To update:

1. Publish through the OpenDropKit release workflow.
2. Set `OPENDROPKIT_RELEASE_TOKEN`; run `pnpm --dir clients --filter @comma/electron pin:opendropkit vX.Y.Z`.
3. Review the release and generated pin.
4. Run `pnpm --dir clients --filter @comma/electron build:native:airdrop`.
5. From `clients`, run `node scripts/airdrop-smoke.mjs`.
6. Commit the pin and required protocol changes.

Client E2E tests the fetched helper; Client Build tests packaged helpers.
They cover local TLS transfer, refusal, and parent shutdown, not nearby-device radio discovery.
An absent helper reports unavailable. The CLI requires `receive --json --require-approval --exit-on-stdin-close`.
Main answers `approval_requested` with a correlated stdin `approval_response`.
Only approved, correlated `transfer_saved` records enter intake.

### Send files

User-selected files/recipient use `find`, `send`, `operation`, and `cancel`.
Scans and sends return an `operationId` within the Client API budget. Main keeps ephemeral state.
A send's `transfer` progress counts bytes given to transport, not acknowledged by the receiver.
One outbound operation runs per app; reception can continue concurrently.

`find` browses Bonjour with assisted wake-up for five seconds, returning at most 64 devices.
Main stops unfinished scans after 25 seconds. Completed scans supply opaque Bonjour peer IDs valid for two minutes.
Resolve ambiguous unverified names before sending. The helper prefers computer names, without per-recipient HTTPS lookups.
The send helper resolves the peer again within five seconds and retains discovery through connection, approval, and transfer.
Discovery stops on completion, failure, or cancellation. JSON excludes contacts and credentials.

`send` requires `paths`, a peer ID, and a UUID `requestId`: 1–50 distinct regular files, at most 1 GiB total, in one request/upload.
Paths can be absolute Mac paths or `/drive` paths. Main maps `/drive` through the default Synch space's published `sourcePath`.
The recordings lookup also supports custom and retained legacy folders. AirDrop never downloads, copies, or changes sync configuration.
Files must be local and remain inside the mapped folder without symbolic links. Missing files report sync/move/deletion errors.
First copy Task VFS files outside `/drive` there with `fs.copy_file` and sync them locally. No backend change is needed.
Directories and symbolic links are unsupported. Any unresolved or unsendable file fails the entire batch before helper startup.
Existing device operation permission grants API and client-environment access.

A retained `requestId` returns the same operation only for identical ordered paths and peer; changed inputs fail.
Main retains twenty operations until sign-out/app exit. Agents poll at most once/five seconds for five minutes, without automatic delivery retries.
Success requires `send_completed` and a successful helper exit.
Timeout, cancellation, and connection failure cannot establish receiver retention; cancellation cannot recall files.
Session changes cancel work and clear recipients/history.

Sending and reception share the anonymous Bonjour/HTTPS helper, with its own self-signed identity and no Keychain access.
Recipients must accept AirDrop from everyone; Contacts Only rejects anonymous senders.
Assisted wake-up lets sleeping devices answer Bonjour. No system-transfer fallback or alternate recipient is used.
Local integration tests verify bytes, refusal, and cancellation through the system sender and an independent OpenDropKit receiver.
Remote contact delivery and release-signed packaging need separate validation.

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
Authentication changes stop prior work and reject late results. Never reuse another account's credentials/messages/browser state/imports.
Profiles/protocols preserve app flavor. Test login, logout, reload, account switches, and stale responses at the host boundary.

Both hosts share one gate; retryable failures spin and retry after 0/1/3/10/30 s.
Main keeps a 5 s request deadline. Exhaustion shows connection failure; online or Retry restarts.
Non-retryable credential/protocol failures and failed sign-outs need explicit retry.
Web checks its Cookie at startup, retry, product 401/409, and peer hints, not focus.
A signed-in tab with a live lease keeps its view if a check fails; it rechecks after 1/3/10/30 s.
409 adopts the Cookie's session; account changes remount the product and toast.
Session responses may add fields; `token` is a protocol mismatch.
Content requires verified credentials and a product lease.
Recovery without caller identity requires initialization or indeterminate state.
Before publication, Main rereads stored credentials and checks backend, operation generation, and account.

Owners supply Conversation/Task facts. Drafts, optimistic messages, and streams are projections, not durable history.
A local send does not prove provider delivery. Reconcile pending and canonical messages without duplicates or lost updates.
Task views show known properties immediately. Visible cards cache recent Messages before navigation; see [history preparation](salix/conversation-owner-actor.md#history-and-projections).
Metadata alone cannot mark history read or enable review/label mutations. Terminal errors hide summaries; newer summary status wins.
Home and Task share six initial render units, eight per upward expansion, and up to four Messages per unit.
Viewport fill and explicit targets can expand the window without splitting logical turns. Agent-only histories open at the tail.
See [Conversations](salix/conversation-owner-actor.md) and [Tasks](salix/tasks-background-execution.md).

## Browser and desktop

Browser navigation, site permissions, side-chat, memory sessions, and shortcuts have distinct native owners.
A web mock cannot establish Electron permission, keychain, protocol, or window behavior.
Separate app commands from browser-origin requests. Page content grants no tool/account authority.

### Embedded Task panel

Comma Web `/task-panel.html?group_id=…&workspace_id=…` checks Task access.
Telegram `/tasks` verifies signed launches for bound users’ 15-minute read-only Group sessions. Failure offers Comma login.
Startup shows progress. Web Cookie authority locks the exchange, saves recovery, and adopts the session ID.
WeChat `任务列表` requires Comma login. URL IDs grant no access.
Pages load 20 Tasks for filtering. `conversation_id` reads properties and Worker. `workspace_id` reads its latest 20 messages across channels.
Details link to Comma Web. Failed reads and timeouts clear content.

### Public Task Share page

Comma Web `/s/<token>` shows one shared Task. It holds no Comma session and sends no credentials.
The Task header's Share dialog previews the latest messages of the Task. It creates, updates, resets, or stops the link.
See [Task Share](architecture/DOMAIN_CONCEPTS.md#task-share).

## Chat dynamic UI

Workers deliver widgets in Tasks; Routers preserve routing and blocks. See [tool rules](../systems/apps/salix_agent/lib/salix_agent/tools/dynamic_ui.ex).

`dynamic_ui` is immutable Message content in a blob. Web and unsupported protocols show its summary.
Activation requires canonical Agent messages and bound blobs; reads require Conversation authorization, not caller-supplied blob references.

An iframe embeds `comma-ui://runtime/` with `sandbox="allow-scripts"`, without native overlay, preload bridge, credentials, or same-origin permission.
MessageChannel binds the iframe window; `null` origin is not identity.

The runtime rebuilds allowlisted components. Only scripts need the DOM-free Worker.
Refresh proposes input; countdowns use absolute time.
CSP blocks connection APIs, nested frames, and forms, but allows HTTPS images, stylesheets, fonts, and scripts.
HTML-declared scripts load at startup, after the bootstrap disables public and prototype `importScripts`. Libraries must be self-contained and DOM-free. Resource URLs can send data externally. Exclude private data.
Electron strips Cookie, Authorization, and Referer. Per window, resources and frameless HTTPS scripts share eight concurrent requests and 128 attempts per ten seconds.
Redirects spend this budget and must remain HTTPS. No transfer-byte or process-memory quota applies.
Agent Workers cannot construct Workers or SharedWorkers. Electron blocks child navigation and non-resource requests from widget frames.
Worker requests can lack frame attribution. CSP, not attribution or CORS, enforces their network boundary.
`main/security.ts` owns the Session request hook.

`comma.card` fills an empty element with a client template in a fitting layout.
ui.create checks `comma.data` card data against the [card contract](../clients/packages/chat-contract/src/dynamic-ui/cardContract.ts), which generates the manual fields.
Hosts supply tokens, copy, icons, and logos. Templates render text, link only to HTTPS, bound lists, and skip unreadable entries.

Each window runs at most three widgets. Offscreen Workers release after 1.5 seconds, with a 240px viewport margin.
Hidden windows retain runtimes. Hosts cache authorized payloads by identity/version. Unloaded widgets retain height.
Limits per widget: 256 KiB content, 500 nodes, depth 20, eight charts, and 60 updates/second (one per Worker task).
Charts allow 64 values and an 800 × 320 canvas. Intervals run at most once/second. Height reports run at most ten times/second.
A watchdog terminates unresponsive Workers after 1.5 seconds. Worker memory has no hard quota.

Help defines 12 archetypes, layout axes, and a shared shell.
Widgets own detail; prose adds conclusions/caveats. Trusted HTTPS clicks open the host sidebar.
Follow-ups retain widgets; redesigns create immutable versions in the original Task.
Widgets inherit Comma appearance, not OS appearance. Theme updates retain runtime/state.
Motion uses Comma tokens and reduced-motion preferences. Creation/restoration have no entrance animations.
Content sets height, capped at 12,000 pixels. No expand/collapse controls.
Chat owns scrolling. The runtime forwards native wheel input through the bound channel. Workers cannot emit scroll intent.

Local state: 32 KiB/version, keyed by API endpoint, account, Workspace, and immutable blob. Card progress: own 32 KiB.
Storage events sync windows. Local events sync copies. New versions start empty. Storage failures show an error and summary.
Widgets never poll business APIs or create reminders or Tasks on reopening.

`comma.request` proposes text outside the iframe. The user must add it to the trusted composer and send it.
Drafts retain the original Task and Conversation reply target. Proposals cannot invoke Agents or native capabilities.
Server scheduling owns reminders. Countdown zero does not prove notification delivery.

## Updates

Diagnose updates with version/feed.
Keep flavor, app identity, protocol, profile, and update channel consistent.
Development does not prove packaged startup/update behavior.

## SSH terminal client

`comma_ssh` provides opt-in OTP SSH; `comma_tui` owns input, editing, layout, and rendering.
See [local setup](development.md#ssh-terminal-development) and [credential ownership](identity-security.md#ssh-account-access).

Clients use `comma`, a public key, and PTY. OTP verifies signatures before email enrollment; known keys open revocable Auth Sessions.
One workspace opens chat, multiple show a picker.
`Comma.AssistantChats.ensure_chat`/`Comma.Conversations` reuse the desktop Router Conversation without creating Routers, Runtime Sessions, or Conversations.
Mutations use `ConversationServer -> ConversationActor`.

The UI shows messages, input, activity, workspaces, and keys.
Enter submits. Alt+Enter adds a line. Paste never submits.
Up/Down traverse lines, then inputs at composer boundaries. Down past newest restores draft/cursor. Edits start a draft.
Each connection retains 100 chat inputs, excluding enrollment/workspace selections. Wheel/PgUp/PgDn scroll chat/help.
`/help` toggles help. Other commands: `/workspace`, `/keys`, `/revoke KEY_ID`, `/resend` during enrollment, `/quit`, and Ctrl+D.
Unknown commands fail locally; `/stop` reports unsupported cancellation.
Busy submissions retain drafts and require Enter when ready; nothing queues/resends automatically. Attachments direct users to Comma.

Footer is gray; You/Comma labels cyan/green. Strip content controls before trusted colors.
Credential-free `init`/`update`/`view` models return effects to hosts.
Rows cache by content/width; scrolling slices visible rows. `ucwidth`/Elixir handle cells/graphemes; emoji widths depend on fonts.
Tests cover fragmented input; OTP owns cryptography.

The footer counts authorized canonical running Tasks. Each connection caches fifty indexed Tasks.
Read initially/on coalesced invalidations, at most four/second. Never poll per Task.
Incomplete pages show the lower bound `≥N running`; read/subscription failures show `Tasks unavailable`.
Reconnect restores subscriptions; workspace changes clear count/subscriber.
One channel/chat subscription precedes snapshot reads. Draft response/source validation is separate from committed Messages.
Chat owner loss requests reconnection; private Runtime Session history stays hidden.

Bounds: 64 KiB decoder, 16 KiB composer, 100 Messages, 8,000 displayed characters/Message, 240x100 layout,
20 renders/second, 256-message mailbox checks, two-second SSH output timeout, twenty-second command deadline.
Timer references fence stale timeouts. Timeout/service failure restores the terminal with persistent reconnection/uncertain-delivery guidance.
Authorization fails closed; disconnect does not cancel accepted work.

For N chats, idle authorization checks cost O(N)/thirty seconds. Coalesced invalidations add at most four bounded snapshot/status reads/second/chat.
No timer scans workspace children. Authorize Session/workspace before commands/refreshes. Lost account/membership closes terminal/subscription.
Submissions have one request ID; uncertain acknowledgments never trigger resends.
Reconnect reloads canonical history: check before resending. Unsent text is connection-local; Comma retains older history/rich attachments.

Source: [chat adapter](../systems/apps/comma_ssh/lib/comma_ssh/chat.ex).
