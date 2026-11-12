# Domain concept inventory

Read this inventory before adding a domain entity or another representation of one.
Reuse an existing concept unless a distinct identity, ownership, or lifecycle requires a new entity.
If a new entity is necessary, update this inventory in the same change.

This inventory describes current Comma, Salix, and Bridge For Teams (BFT) concepts.
It does not authorize the proposed entity consolidation or rename existing APIs.
The sections group related concepts for navigation, not new services or database boundaries.
A concept can be an entity, value, relationship, command, or projection. It does not necessarily need a table.

Use [the product model](PRODUCT_MODEL.md) for detailed cardinalities and workflow semantics.
Use [the documentation index](../README.md) for current contracts.
Implementation and direct tests establish current behavior, not the existence of a name in this list.

## Maintenance contract

Before introducing an entity:

1. Find the nearest concepts below and inspect their owners.
2. Prefer an existing entity, relationship, value, or explicit projection.
3. Explain why those options cannot represent the required behavior.
4. Document the new entity's identity, scope, owner, lifecycle, and relationships in this inventory.
5. Add implementation links and distinguish authoritative facts from references or projections.
6. Update affected entries when renaming, merging, retiring, or changing ownership of existing concepts.

Do not create a second authority for an existing fact under a new name.
A different page, transport, provider, DTO, or storage layout alone does not require a new domain entity.
Preserve authorization, data ownership, and product-specific cardinalities when reusing concepts.
Calling stored data a projection does not authorize its deletion.

## 1. Identity and scope

| Concept | Meaning and boundary |
| --- | --- |
| User | A product identity that signs in and requests work. Comma and BFT own their respective users. A Comma `guest` User is a throwaway identity for [guest mode](#guest-mode). It never becomes a registered User. A Comma User holds the app language (`en` or `zh-CN`): a value on the User, not a device setting. Every signed-in device and server-written text (Routine, proactive messages, reminders, Telegram cards) follow it. A device keeps a local copy only to render before sign-in. |
| Login Identity | An authentication identity associated with a product User. It is not an Agent or an external message sender. |
| Auth Session | Login credentials, expiry, and access scope. It is not an Agent Runtime Session. |
| Workspace | Comma's authorization scope and product entry to its current Agent work scope. It also references billing and Drive resources. A `guest` Workspace has only a Router agent and shares the guest Tenant. A `standard` Workspace also starts with its Router alone; its Tasks run on its Group's Task agent. The stored default Worker id of older Workspaces is no longer read. |
| Owner / Membership | A user's authority within a product scope. It is not Conversation participation. |
| Tenant | The Salix isolation scope. Comma Workspace and BFT Organization store their respective Tenant mappings. Its existing config records own [Slack command templates](../../systems/apps/salix_im/lib/salix_im/slack_command_templates.ex); Apps copy these values without inheritance. |
| Group | A Salix Agent work scope within a Tenant. Comma Workspace references its current Group and generation. The Group owns its outbound SSH client key and trusted SSH host keys (see [Outbound SSH Session](#outbound-ssh-session)). Its Agents may start the Group's Cloud VM and place Tasks there while the Group can have one and it is not retired ([CloudVM.allowed?/1](../../systems/apps/salix_agent/lib/salix_agent/cloud_vm.ex)); no Group, Workspace, Project or Agent has a Cloud VM switch (product decision, Yue Wu, 2026-10-26: a Group whose Tenant has a VM provider, or whose VM is on an Agent VMM Host, may use its Cloud VM, a Group whose switch was off included; a switch that forbids cloud execution would be a new one). The record's `cloud_vm_retired` is written when the Group is created where sandboxes are set up, on every Group by the [Cloud VM cutover](../agent-runtime.md#cloud-vm-cutover), and on the Groups of a deleted account's Workspaces ([Groups.retire_cloud_vm/2](../../systems/apps/salix_web/lib/salix/control/groups.ex)). |

Owners and entry points:
[Comma accounts](../../systems/apps/comma_core/lib/comma/accounts.ex),
[Workspace and Membership](../../systems/apps/comma_core/lib/comma/data/schemas.ex),
[Workspace authorization](../../systems/apps/comma_core/lib/comma/workspaces.ex),
[BFT Organization](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/organization.ex).

The shared [native Session lifecycle](../../clients/packages/core/src/session/electron-lifecycle.ts) owns Auth Session recovery for Electron, iOS, and Android. Each host keeps its bearer and gate: Electron [Main](../../clients/apps/electron/src/main/modules/session/session-host.ts), iOS [SessionCustody](../../clients/apps/apple/iOS/Core/SessionCustody.swift), and the Android host. A saved Session opens its account cache before the background network check. See [native session recovery](../identity-security.md#saved-native-sessions).
A configured backend change removes credentials for other origins before login, without changing server sessions or unrelated profile data.

A native device can keep other accounts signed in beside the one in use. Each kept account is an ordinary Auth Session whose credential the host keeps beside the active one (`kept` in the host's credential store, at most seven). This adds no entity: one Auth Session per account is in use at a time, and the core opens only that account's cache.
Add account moves the active credential to the kept list without revocation, then shows sign-in.
Switching swaps a kept credential with the active one, restores its Session from storage, then checks it with the server. A `401` on that check signs out only that account.
A new sign-in to a kept account replaces its credential and queues the old one for revocation. Signing out a kept account queues its credential for revocation.
The core keeps the account cache of a kept account and deletes the cache of an account that is no longer signed in on the device ([Session](../../clients/packages/core/src/session.ts)).
Notifications, the Desktop Connector and other background work follow only the account in use. iOS unregisters push for the account it sets aside. The web keeps one Cookie Session and has no kept accounts.

Native Apple login reuses [Login Identity](../../systems/apps/comma_core/lib/comma/accounts/identity.ex) with `provider=apple`, Apple's issuer and token subject.
[AppleAuth](../../systems/apps/comma_core/lib/comma/apple_auth.ex) verifies Apple's keys, client ID, nonce and token lifetime.
Existing emails require OTP before linking. [AuthChallenges](../../systems/apps/comma_core/lib/comma/auth_challenges.ex) owns expiring, single-use nonce attempts and linking codes.
[WatchPairing](../../systems/apps/comma_core/lib/comma/watch_pairing.ex) uses the same challenge owner for a two-minute grant.
The grant creates an ordinary [Auth Session](../../systems/apps/comma_core/lib/comma/accounts/auth_session.ex) with `parent_session_id`.
Parent revocation rejects grants and child sessions. Natural parent expiry does not expire an issued child session.
[CommaCore](../../clients/packages/apple-core/Sources/CommaCore/CommaClient.swift) owns each app's Keychain credential and stale-response fence.

APNs targets are delivery-credential projections of Auth Session and Workspace, not compute Devices or new Task identities.
[Notifications](../../systems/apps/comma_core/lib/comma/notifications.ex) owns each session/kind slot, token rotation, authorization and expiry.
A registration ID correlates token updates and deletion. It grants no authority. Revoked sessions and inaccessible Workspaces/Tasks reject delivery.
Activity clients can allocate this existing UUID before POST and retain it until the enrollment or deletion settles.
This addresses a committed registration whose response was lost. It does not create a version, ordering authority or new credential.
The server still authorizes the Session/kind slot. UUID collisions cannot replace another Session's target.
The client serializes HTTP settlement and exact-ID deletion. The UUID recovers a committed POST with a lost response; it does not fence a server request that has not committed. HTTP timeout is not proof of server termination, so this transport claims no end-to-end linearizability.
Each projection records a validated main-app bundle ID, APNs environment, and alert locale. These values create no new app or Device identity.
Ordinary alert intent remains installation-local. The current Auth Session owns its `device` slot, including explicit opt-out and legacy reconciliation.
Missing Tasks do not revoke this Session-owned address. Group index rebuilds update the aggregate Activity without creating a Task alert.
[NativePush](../../systems/apps/comma_core/lib/comma/workers/native_push.ex) re-reads owner facts and sends bounded APNs projections.
[TaskActivityCoordinator](../../clients/apps/apple/iOS/TaskActivityCoordinator.swift) displays one Workspace activity with the two latest running or attention Tasks.
The source is the existing Group and its canonical Conversations, regardless of message provider or client platform.
[TaskActivityProjection](../../systems/apps/salix_im/lib/salix_im/task_activity_projection.ex) reads the two latest eligible Tasks from canonical PostgreSQL rows.
Conversation owner transactions update their status and timestamps. The foreground API and APNs use the same indexed query.
There is no separate display index or rebuild lifecycle.
Live Activity title/status/timestamps mirror Conversation facts. Apple owns presentation and lifetime. Widgets and notifications cannot change Task status.
`tasks_v1` identifies the aggregate transport schema, not a new Task version or authority. Legacy token rows remain without incompatible delivery.
The aggregate-target migration uses the existing online expand phase, with old runtime read/write compatibility explicitly false.
Mixed server versions can reject enrollment or remove a new activity address. This does not alter canonical Tasks, Messages or Auth Sessions.
After server rollout and client upgrade, foreground registration restores update addresses. Preserved push-to-start addresses also permit background recovery.
The iOS app delegate starts restoration of the Keychain-owned Session and existing Workspace on a background launch without a SwiftUI scene.
The account/origin-local selected Workspace ID is a hint, validated against the bounded authorized list. An ActivityKit scope can supply a first-upgrade hint; a late Activity cannot override a saved selection.
This path opens no chat pane or SSE connection, creates no Workspace, and acknowledges no Router Message.
Foreground invalidations share one refresh worker per selected Workspace, with at most five batches per second. A later invalidation fences an in-flight Activity read and schedules a successor.
After each paginated recovery sweep, the listener waits 60 seconds. An unacknowledged remote start becomes eligible for retry after 120 seconds. APNs still controls device presentation.
Dismissal suppresses the same Task ID cohort. Changed candidates or normal activity expiry permit renewed tracking.

[RouterNotifications](../../systems/apps/comma_core/lib/comma/router_notifications.ex) projects unread replies from the existing canonical Router Conversation.
The Workspace owner retains the observed/read Message positions and counts in `Workspace.router_notification_state`.
`comma_router_notification_messages` retains unread canonical Message IDs, sequence positions and count ordinals, without message content or credentials.
These rows have no independent Message lifecycle. Exact canonical read acknowledgments advance the durable read position and remove covered projection rows.
Enrollment establishes a history baseline. Each reconcile reads at most 100 new Messages. An owner job continues larger backlogs.
Visible Router replies include canonical provider assistant receipts. Inbound, hidden and tool Messages do not count.
Auth Session device targets retain their last accepted Router sequence and absolute badge count. Read acknowledgments fan out badge updates.
The active unobscured Home marks only displayed committed Messages read. Task sheets and background delivery preserve unread state.
For a saved opt-in with explicit OS authorization, iOS requests the complete alert/sound/badge options once after upgrade. The saved fact records a request, not permission. Current OS settings still control presentation.
Unknown intent, opt-out, denial, and provisional authorization do not trigger this automatic request.
Reuse is sufficient because these projections have no independent account, Task, Message or execution identity.

Telegram Mini App access reuses [Auth Session](../../systems/apps/comma_core/lib/comma/accounts/auth_session.ex) with `session_source=channel_task_panel`. Its `channel_subject` is the verified Telegram user ID; Workspace and Group fields scope a 24-hour, read-only cookie. The current [Telegram link](../../systems/apps/comma_core/lib/comma/telegram_links.ex) owns the expected connection ID. [TelegramMiniAppAuth](../../systems/apps/comma_web/lib/comma_web/telegram_miniapp_auth.ex) checks it on every read and returns 401 if the connection changed, so a reconnect cannot revive a cookie from before disconnect. Task reads use the existing [Conversation](../../systems/apps/comma_core/lib/comma/conversations.ex) kind check; a panel cookie cannot read Router chat. This adds no User, Task, or Session identity.

Telegram Task review cards reuse the existing provider Participant and status delivery. At Task creation, [TaskConversationInput](../../systems/apps/salix_im/lib/salix_im/task_conversation_input.ex) asks the product adapter for the Workspace owner's bound private chat and, for a Task whose `metadata.origin.provider` is `telegram`, adds one `task_status_personal` Participant. A Task asked for elsewhere (Lark, Slack, the app) sends no card, also when it holds that Participant from before this rule. It subscribes to all status events and to no Messages. Only review, escalation and failure send new cards. Intermediate states retire the previous card, so a later review round sends a new card. [TelegramTaskCards](../../systems/apps/comma_web/lib/comma_web/telegram_task_cards.ex) authorizes each send against the current [Telegram link](../../systems/apps/comma_core/lib/comma/telegram_links.ex) and never resends an uncertain card. Its card, latest-card and change-prompt records are disposable interaction state. Reads reject a card after 14 days and a prompt after 24 hours. No job deletes the records. They hold IDs and the carded review version, never authority. A Task that stays in one attention status keeps one live card. The card records the end of its attention interval before an edit, so failed retirement cannot suppress a later review. Retirement clears the latest-card pointer only after a successful edit. Transient edits of a known message use the Participant owner's existing three-attempt budget. Exhaustion retains the failed delivery and card target. Ordered Participant delivery completes that budget before it processes a later card. Each click re-resolves the sender and calls `Comma.Conversations.accept_task_review/5` or `send_message/5`, so the Conversation owner keeps Task status and the Mini App stays read-only. This adds no Task, status, or card identity.

Native Slack, Feishu and Lark Task cards reuse one provider Participant with `role_label: "task_card"`. [TaskCardProjection](../../systems/apps/salix_im/lib/salix_im/task_card_projection.ex) owns the shared projection. It holds the title, lifecycle, latest public output and the last three visible Messages. [SlackTaskCard](../../systems/apps/salix_im/lib/salix_im/slack_task_card.ex), [FeishuTaskCard](../../systems/apps/salix_im/lib/salix_im/feishu_task_card.ex) and [LarkTaskCard](../../systems/apps/salix_im/lib/salix_im/lark_task_card.ex) own only the provider address, layout and write evidence. The Conversation owner keeps Task status. This adds no Task, status, or card identity.

QQ cannot edit messages, so [QQTaskCard](../../systems/apps/salix_im/lib/salix_im/qq_task_card.ex) uses the same kind of Participant (target key `qq_task_card`) to send a new Markdown card for each visible state change; the delivery receipt suppresses repeats. [TaskWorkerWatch](../../systems/apps/salix_im/lib/salix_im/task_worker_watch.ex) reuses its Session Activity subscription for working and blocked notices, and the Conversation owner checks the current Worker Session before appending one. An ambiguous send is not replayed, because QQ has no receipt lookup.

The Feishu card is one interactive message that replies to the source message. Later deliveries update it in place. A new post replaces a recalled, deleted or expired card once. Before the first post, the publisher reads the source message and rejects a `chat_id` that does not hold it. The card does not record thread participation or bind the thread to the Task. Feishu Task cards add no Router reply obligation, because the verified kernel fences only Slack card obligations.

Feishu sends no message-metadata event, so the API response is the only write evidence. Each post sends a `uuid` from the card identity and the message that it replaces. Feishu sends at most one message per `uuid` in one hour. After an ambiguous post, the runtime replays the same `uuid` and adopts the returned address. If the replay cannot prove the address within 50 minutes, the runtime quarantines the card. It never posts a second card for the same address.

The account scope and Agent work scope are distinct responsibilities.
Comma presents both through Workspace. BFT separates Organization from Agent Swarm.
These mappings do not make their IDs interchangeable.

### Review login credential

The existing Comma User owns one optional `review_login_code_hash` value. This is not a new User kind or Login Identity.
Accounts owns the User. Admin sets, replaces or clears the credential through the existing audited user update.
`review_login_code` accepts six ASCII digits, `null` to clear, or omission to preserve.
Setting requires a registered User with explicit Admin `deny`. Admin grants are refused while the credential exists.
Both writes lock the User. Credentials never enter public User DTOs, logs or audit content. Admin returns configuration status only.

The database stores an HMAC under the existing auth secret with a separate purpose prefix.
The deployment key protects database-only reads from offline enumeration, not combined database/key compromise.
The credential has no expiry. Auth-key rotation requires saving the code again. Releases do not provision credentials.

AuthChallenges issues a normal expiring, single-use email-login challenge with a server-owned review marker and User binding.
Only that marker selects the review verifier. Review requests skip mail and its circuit check but retain all request/attempt limits.
Verification reads the User's current hash and email before issuing a normal Auth Session with `auth_method=review_code`.
Replacement/removal rejects old pending challenges, not verification already admitted concurrently or sessions already issued.
Clearing restores random email OTP and preserves Admin deny. Existing session revocation remains separate.
Ordinary users retain random OTP. Apple/Google linking and SSH enrollment still require mailbox proof.

Implementation: [User](../../systems/apps/comma_core/lib/comma/accounts/user.ex),
[Admin](../../systems/apps/comma_core/lib/comma/admin.ex),
[AuthChallenges](../../systems/apps/comma_core/lib/comma/auth_challenges.ex),
[HTTP/Redis regression](../../systems/apps/comma_web/test/review_login_test.exs).


### App registration abuse evidence

[Abuse](../../systems/apps/comma_core/lib/comma/auth/abuse.ex) protects hosted app email-code requests and new Google or Apple User creation.
Enforcement requires `comma.auth.abuse.enabled: true`. The default is false. `Abuse.enforced?/0` owns this hosted-mode decision.
With enforcement off, web, Electron and native callers without `native_proof: true` keep the original login flow.
Opted-in native callers collect PoW and platform proof through a native challenge with `enforce: false`.
That challenge needs no configured provider. Missing Apple environment or Play project number stays absent.
Observation logs a bounded outcome and admits the action even when proof, context, secret or expiry checks fail.
Challenge, continuation setup, store and extra request-limit failures also admit the original business operation.
Observation never selects CAPTCHA. Normal OTP, OAuth and continuation authentication still fail closed.
Logs contain only action, platform, provider, mode, verdict and PoW/proof stage enums. They contain no raw identifiers, email, IP or proof material.
It does not change User, Login Identity, Auth Session or gift authority. Returning identities and linking do not repeat the check.
The new checks apply after serving replicas converge. Older replicas retain their prior admission policy during rollout.
SSH enrollment and other unnamed creation paths keep their current contracts. This is not a universal registration boundary.
Self-hosted mode uses the existing product-mode decision. Missing hosted configuration never selects it.

The existing [OneTimeCredentials](../../systems/apps/comma_core/lib/comma/auth/one_time_credentials.ex) owner stores abuse challenges and OAuth registration continuations.
Both expire after five minutes and retain purpose, consumption and existing peer-limit authority.
Challenges bind the API origin, action, normalized email, platform and exact continuation ID.
The server consumes the abuse challenge before proof verification. Enforced native failure issues a new CAPTCHA-only challenge from that saved context.
When enforced, only accepted proof permits continuation consumption. Account and identity resolution then runs again before creation.
The continuation keeps verified claims and original client context, without raw provider tokens.
`POST /v1/comma/auth/email/login` accepts platform and abuse evidence.
When enforced or native collection is requested, missing proof returns HTTP 428 with `captcha_required` or `native_proof_required`.
The successful mail and OTP payloads stay unchanged. OTP completion needs no second abuse proof.
New OAuth registrations return an opaque `registration_continuation` beside the challenge.
`POST /v1/comma/auth/registration/complete` accepts that credential and abuse evidence, then reuses the original verified claims and client metadata.
Enforced abuse dependency failure returns HTTP 503 `auth_abuse_unavailable`. Existing rate limits retain HTTP 429.
The shared client core sequences web and Electron CAPTCHA, native proof, and CAPTCHA fallback. The local chain runs the core, Main session host and Router from the same checkout.
No challenge peek, signed acceptance receipt, second claim store or retry ledger exists.
Redis consumption, delivery and PostgreSQL commits are not atomic. An uncertain response can need a fresh bounded attempt.

Enforced mobile admission requires a 12-bit PoW and independent platform proof. Labels and PoW alone cannot authorize an enforced action.
Proof bytes are UTF-8 `comma-abuse:<id>:<secret>`. Apple receives their SHA-256 digest. Play receives its unpadded base64url encoding.
PoW hashes those bytes, a colon and a decimal nonce of 1 to 20 bytes.
The client bounds solver work. Twelve bits is an initial setting, not a mobile latency guarantee.
Turnstile verifies success, the configured API hostname, action and challenge ID in `cdata`.
Its public page URL contains only that ID and action. The core keeps the secret and continuation.
Clients bind completion to the current source window, exact API origin and operation. The page has no bearer or native bridge.

[AppleKey](../../systems/apps/comma_core/lib/comma/auth/abuse/apple_key.ex) owns reusable verification material that cannot fit a one-time challenge's TTL.
Its key ID identifies cryptographic material, not a User or Device. Scope is the exact normalized auth email target, app and proof environment.
It stores the existing auth email fingerprint, P-256 public key and last accepted assertion counter, without private keys or raw proof tokens.
[Apple](../../systems/apps/comma_core/lib/comma/auth/abuse/apple.ex) enrolls verified material and atomically accepts only a greater counter under the same target binding.
Repeat enrollment never resets a known counter. Key loss selects CAPTCHA and never invalidates an Auth Session.
Keys stay until exact-target cleanup or explicit auth retirement. There is no idle expiry or key-count capacity policy.
Email change and due account deletion remove current-fingerprint rows only. Other accounts' rows remain.
The fingerprint uses `auth.rate_limit_secret`. After rotation, old rows cannot match the current fingerprint and can remain stored.
Restoring the old secret can restore that match. Cleanup does not promise erasure, anonymization or permanent revocation of historical material.

[AppleVerifier](../../systems/apps/comma_core/lib/comma/auth/abuse/apple_verifier.ex) uses maintained CBOR, OTP path/signature validation and an OTP-compiled nonce ASN.1 schema.
The Apple root is private to verifier composition. Tests replace only that root with generated signed fixtures.
The adapter checks chain, validity through SystemsClock, certificate nonce, key ID, App ID, environment, initial counter and credential ID.
It verifies later signatures and increasing counters. It adds no binary-version allowlist or validation-category admission rule.
The evaluated Rust `appattest` SDK did not expose its counter or accept caller-selected time/environment, and constrained assertions to 37 bytes.
Its handwritten DER decoder would also require a separate adapter or fork. The narrow OTP adapter avoids that extra runtime boundary.

[Play](../../systems/apps/comma_core/lib/comma/auth/abuse/play.ex) obtains its bootstrap token explicitly from GKE metadata through Goth.
The existing runtime Workload Identity owns that bootstrap. It is sent only to Google's IAM Credentials API.
`comma.auth.abuse.play.decoder_service_account` selects the target service account without a private key or environment credential override.
[IAM `generateAccessToken`](https://docs.cloud.google.com/iam/docs/reference/credentials/rest/v1/projects.serviceAccounts/generateAccessToken) issues its token with the sole `playintegrity` scope.
Only that minted token reaches the Play decoder. The path has at most three bounded HTTP calls, without retry or token caches.
[Goth's metadata source](https://goth.hexdocs.pm/Goth.Token.html#fetch/1) cannot impersonate or change scope.
Its workload-identity source requires an external subject-token and STS exchange first.
The [Google Elixir API repository](https://github.com/googleapis/elixir-google-api) is archived and no longer maintained.
The narrow IAM REST adapter reuses the existing HTTP owner and avoids a new runtime, credential identity or federation configuration.
Missing permissions or provider configuration keep the existing observation and enforcement outcomes. They do not add a startup gate.
It checks request hash, package, release signing certificate, token age, `PLAY_RECOGNIZED` and `MEETS_DEVICE_INTEGRITY`.
Play licensing, minimum versions and strong-integrity verdicts are not additional requirements.
Unrecognized builds use CAPTCHA when enforcement is enabled. Observation still admits the action.
Proof calls have no automatic retries. Each HTTP call has a three-second connection budget, three-second receive budget and 64 KiB response bound.
Apple evidence is at most 24 KiB encoded, Play tokens 16 KiB, CAPTCHA tokens 2 KiB, and action credentials 200 bytes each.
Only named request, input and work bounds apply. There is no appliance, User or key-count reservation.
Local tests exercise cryptography and scripted independent provider replies. Real Apple and Play verdict acceptance still requires real devices and provider setup.

### Product analytics projection

[Comma.Analytics](../../systems/apps/comma_core/lib/comma/analytics.ex) projects existing Users and activity to PostHog.
The User ID remains the person identity. Canonical email is a server-owned person property, never an event property.
Website and web app first touch use the SDK anonymous identity until the session authority identifies an existing User.
The shared [attribution policy](../../clients/packages/analytics/src/index.ts) stores only bounded public campaign fields.
PostHog owns no account, authorization, Task, or financial lifecycle. Reuse needs no new domain entity or durable activity ledger.
The bounded activity queue is volatile. A unique Oban job owns the profile-scan cursor and next due time.
Source facts remain with their existing owners. Profile sweeps emit no registration events.
Task events name where a Task runs (`task_kind`: coding, sandbox, station or cloud), its runtime and model, its status and duration.
An ended Task (completed, cancelled or failed) gets one [unique Oban job](../../systems/apps/comma_web/lib/comma_web/task_ended_analytics.ex) per status version. For a sandbox Task, the job adds the token use, change totals and pull request state that the Task's Workload `facts` held last.
Task events never carry a title, Message, repository, branch or pull request.
[Export](../../systems/apps/comma_core/lib/comma/analytics/export.ex) rechecks registered Users and configured exclusions before delivery.
Guest placeholders and BFT identities are excluded. See [operations and loss limits](../observability.md#comma-product-analytics).

### Guest mode

Guest mode lets a person try Comma in the web client without sign-in. The Electron app and other bearer clients still require sign-in. It adds no entity. It adds a `kind` value to User and Workspace, a Tenant profile, and one Comma Operation type.

- **Guest User.** `comma_users.kind = 'guest'` marks the User. Its email is an undeliverable `g-<hex>@guest.comma.invalid` placeholder. A database check keeps the kind and the placeholder domain together. Registered sign-in paths reject that domain. The guest has no Login Identity and gets no sign-up credits. It never becomes a registered User.
- **Guest Auth Session.** `POST /v1/comma/auth/guest` creates the User and an ordinary `user_login` Auth Session with `auth_method = 'guest'`. Only the web Cookie transport can create a guest; other clients get `guest_web_only`. The request must carry a solved [GuestPow](../../systems/apps/comma_core/lib/comma/guest_pow.ex) challenge from `GET /v1/comma/auth/guest`. The client finds a nonce so that SHA-256 of the challenge and nonce starts with the policy's number of zero bits. The default of 12 bits takes well under 0.5 s on a phone. The challenge is signed, expires after ten minutes, and creates at most one guest. Guest creation has no client-address limit. [CommaWeb.GuestRoutes](../../systems/apps/comma_web/lib/comma_web/guest_routes.ex) is a fail-closed route allowlist. A guest reads its session and profile, bootstraps its Workspace, and uses its Router chat. Other routes return `guest_signup_required`.
- **Guest Workspace.** `comma_workspaces.kind = 'guest'` has no Worker agent, no Task agent and no Cloud VM. Its Group is in the shared guest Tenant. The unique Tenant index covers only `standard` Workspaces. Guest Workspaces reject VM changes and skip Synchronicity, so the placeholder email stays in Comma.
- **Guest Tenant profile.** [SalixStore.TenantProfiles](../../systems/apps/salix_store/lib/salix_store/tenant_profiles.ex) stores the `product_profile` tenant config. A `router_only` Tenant admits only Routers with the `comma_guest_router` purpose and no VM. [AgentControl](../../systems/apps/salix_agent/lib/salix_agent/agent_control.ex) applies this rule at agent creation and keeps the guest purpose, VM, tool and runtime fields fixed. The Cloudflare provider refuses a VM in the Tenant. The profile also sets the Tenant's per-node dependency admission limit, which all guests share.
- **Guest tool policy.** [SalixAgent.GuestPolicy](../../systems/apps/salix_agent/lib/salix_agent/guest_policy.ex) is a fail-closed tool allowlist for the guest Router purpose. Disclosure and dispatch both apply it. It excludes agent, plugin, MCP, environment, device, Task and account tools, so one guest cannot publish Tenant-scoped definitions to another.
- **Handoff and import.** `POST /v1/comma/auth/guest/handoff` revokes the guest sessions and stores a one-hour claim hash on the guest User. The claim is an HttpOnly `comma_guest_claim` Cookie and never appears in a response body. `POST /v1/comma/guest-imports` lets a registered User redeem that Cookie once from the web. It creates a `guest_import` Comma Operation. [GuestImport](../../systems/apps/comma_core/lib/comma/workers/guest_import.ex) writes a Markdown transcript of the guest Router chat to the account Router's files and sends one ordinary user message that attaches it. A retry reuses the file path and `client_request_id`, so the Conversation keeps one import message.
- **Clients.** The Session principal carries `kind`. A missing value means `registered`. Only the web offers guest mode. It solves the proof of work with WebCrypto. It keeps only an expiry marker in `localStorage`, because the claim is an HttpOnly Cookie. The Session settles `signed_out` with reason `guest_handoff`. The next registered web sign-in, startup reconcile or focus probe redeems the claim. A transient failure keeps it until expiry. A rejected or expired claim is dropped. Renderers never receive the claim. Guest UI shows Home, the Router chat and a sign-up banner only.
- **Policy.** The Comma Admin dashboard owns the `comma_guest_policy` singleton: enabled state, guest Tenant, daily creation limit, Tenant concurrency, guest session lifetime and proof-of-work difficulty. `create_guest_tenant` creates a new router-only Tenant for new guests. Existing guest Workspaces stay in their Tenant. There is no config file setting.

Owner: [Comma.GuestMode](../../systems/apps/comma_core/lib/comma/guest_mode.ex). A guest Router uses the platform default Router model. The guest has no credits, so that model must be on the free Router list.
Guest Users, Workspaces and Groups stay after import or expiry. Deletion of guest data needs a separate owner decision.

### Account deletion

A registered User deletes their own account. It adds no entity: it uses the User `status` value `deleted`, the Workspace `status` value `deleted` and one Comma Operation type, `account_deletion`.

- **Confirmation.** `POST /v1/comma/me/account-deletion/code` mails an `account_deletion` [AuthChallenges](../../systems/apps/comma_core/lib/comma/auth_challenges.ex) code to the account email. A User with a review login code confirms with that code. `POST /v1/comma/me/account-deletion` confirms with the code. A wrong code answers 400, so the session that sent it stays signed in.
- **Seven days to take it back** (product decision, Heyang Zhou, 2026-11-01). Confirming revokes every Auth Session and the account's station credentials and sets `comma_users.deletion_scheduled_at` seven days ahead; nothing else changes yet, and the answer carries that time. A new login session (`session_source` `user_login`: email code, Google, Apple, Telegram, SSH) clears it, which takes the deletion back; an Ops-issued session does not. The hourly [AccountDeletionSweep](../../systems/apps/comma_core/lib/comma/workers/account_deletion_sweep.ex) deletes the accounts whose time has come, re-reading the schedule under the User row lock.
- **Subscriptions.** Both requests answer 409 `subscription_active` while a subscription of an owned Workspace still renews. The User turns off renewal in the Stripe portal. Comma does not cancel the subscription. A subscription that does not renew ends at its period end.
- **One transaction, after the seven days.** [Comma.AccountDeletion](../../systems/apps/comma_core/lib/comma/account_deletion.ex) revokes every Auth Session and the account's station credentials, marks the owned Workspaces `deleted`, deletes their Mini Apps (`Comma.MiniApps.delete_workspace_apps/1`), and removes the account's Login Identities, channel links, Task Shares, Task Request grants and sent requests, recommendation profiles and per-user state. The User row stays without personal data: a `d-<hex>@deleted.comma.invalid` email, no name, avatar or locale, and `deleted_email_hash`, a keyed hash of the old email. Workspaces, billing records and audit events keep their User reference. The email is free for a new account. [SignupCredits](../../systems/apps/comma_core/lib/comma/billing/signup_credits.ex) gives no registration credits to an email with a deleted account. Gmail deletion also records canonical Gmail occupancy as described under hosted registration below.
- **Outside effects.** [AccountDeletion worker](../../systems/apps/comma_core/lib/comma/workers/account_deletion.ex) removes each deleted Workspace Group's IM connections and retires its Cloud VM (`cloud_vm_retired`), so no Agent of it starts one. Avatar objects go through the existing avatar cleanup.
- **Kept content.** The Salix Conversations, files and Session history of a deleted Workspace stay in its Tenant, where no account can reach them. Erasing them needs a Salix storage erasure path, which does not exist yet.
- **Clients.** Delete account sits alone in a Danger zone section of Settings, as a destructive (red) control. The person confirms three times: the explanation, then the account email typed by hand (the code is mailed only once it matches), then the mailed code. The core calls `accountDeletion.requestCode` and `accountDeletion.delete`. The explanation says the account is deleted after seven days and that signing in again takes it back. After the confirmation the core treats its session as refused, so every surface shows sign-in. Guests have no deletion entry.

### Login email change

A registered User changes the email they sign in with. It adds no entity: the User keeps its id, and with it the Workspaces, their content, billing, Auth Sessions and Login Identities (Google and Apple match the provider's subject). Only `comma_users.normalized_email` changes. Owner: [Comma.EmailChange](../../systems/apps/comma_core/lib/comma/email_change.ex).

- **Self-service needs both mailboxes.** `POST /v1/comma/me/email-change/code` mails an `email_change_current` code to the account email. `POST /v1/comma/me/email-change/new-email-code` checks that code, then mails an `email_change_new` code to the new email; that challenge names the email it replaces. `POST /v1/comma/me/email-change` checks the new code and changes the email in one transaction. A wrong code answers 400 and the session stays signed in.
- **Lost mailbox.** A person who cannot read the account mailbox has no self-service path (product decision, Jimmfly, 2026-11-01). Support checks who they are and changes the email in Comma Admin: `PUT /v1/comma/admin/users/:id/email`, an audited Admin command with confirmation `change-email:<user id>`.
- **Refusals.** The new email must not belong to another User (409 `email_taken`); its owner can delete that account first, which frees the email when the deletion's seven days are over. Until then the change answers 409 `email_pending_deletion` with `deletion_scheduled_at`, and the clients say signing in with that email takes the deletion back (product decision, Jimmfly, 2026-11-01). The first code must have been mailed to the account's current email (409 `email_changed` after a support change), and it is checked before the new email's lookup, so a signed-in User cannot test emails without codes; a taken email uses the first code up. A change made after the new code was mailed voids it (409 `email_changed`). Guests, deleted and disabled Users, and Users with a review login code cannot change their email.
- **Registration credits.** The change keeps a keyed hash of the old email in `comma_released_emails`; [SignupCredits](../../systems/apps/comma_core/lib/comma/billing/signup_credits.ex) gives no registration credits to a new account with it, as after a deletion.
- **What stays on the old email.** Stripe customers keep their billing email; the person changes it in the billing portal. Station push targets written as the old email no longer resolve.
- **Clients.** The core calls `emailChange.requestCode`, `emailChange.requestNewCode` and `emailChange.confirm`. After a change the core checks the session with the server again and reads the profile again, so every surface shows the new email.

## 2. Agents and execution

| Concept | Meaning and boundary |
| --- | --- |
| Agent | A durable executor identity with configuration and lifecycle. It is not one model call or one Actor process. |
| Router | The current coordinating Agent for a Group. An unconfigured Group can have none. A chat-ready Group requires one. |
| Worker | An Agent that performs delegated work. One Worker can serve multiple independent Tasks. Triage's Group-owned selection references an ordinary Worker. An administrator chooses that Worker. An empty selection pauses new Triage assignments without creating an Agent. |
| Task agent | The Worker that runs a Group's Task when the Task names no Worker. It is a relationship on the Group record (`task_agent_id`), not a new entity: the Agent is an ordinary internal Worker that Salix owns. See [Task agent](#task-agent). |
| Model Choice | A catalog, station-runtime or platform model choice stored as a value on an Agent (`model`), an internal Runtime Session, or a Group as its default Task model (`default_task_model`). An Agent without one follows the Platform Model of its role. A Session's choice replaces its Agent's for that Session only. |
| Platform Model | The one model members can choose besides their own Profiles' (Comma: "Comma"). Members see only its name. The platform configures, per tier, the internal model that serves it and pays for it. It is a Model Choice kind and one platform configuration record, not a template. |
| Model Catalog | Platform data that names models across sources. A catalog model has a model id, a display name, its maker, and one request id and protocol for each source that serves it. A source is an API-key provider or a subscription plan. It owns no credentials, tenant data, or Agent bindings. |
| Runtime Session | An Agent's input, model, and tool execution context. A configured current Router has one canonical Session. A Worker can have many. An internal Session can hold its own model choice, which replaces its Agent's model for that Session only. |
| Retired Session | A Session that ran on the retired External Runtime (Codex, Claude Code, Pi or Kimi run by the Go connector `salix-connect` or a Compute Workload). Its stored records stay as read-only history; it takes no input, and its id is never born again. Workers bound to a station replace the External Runtime. See [Retired Sessions](#retired-sessions). |
| Station Binding | Where a Worker's Tasks run: a value on the Worker's Agent record (`station_binding`), not an entity. It names a station (`runs_on`: a device's station, or the Group's Cloud VM) and the runtime model it runs for them. See [Station Binding](#station-binding). |
| Session Activity | One accepted execution activity. It is separate from an input batch, Task lifecycle, and device availability. |
| Participant Status | The exact Participant's public activity and optional draft surface. The Participant resolves its Session privately. |
| Condensed Workspace | One opt-in, ordered list of short statements about current facts per Group, keyed by Group ID with a monotonic revision. Every internal Router and Worker Session of the Group keeps the latest list in context. The Group field `condensed_workspace_enabled` turns it on. Agents write through `condensed_workspace.update`, and the Comma Workspace owner edits it directly. Turning it off keeps the statements. It grants no authority. |

Owners and entry points:
[AgentControl](../../systems/apps/salix_agent/lib/salix_agent/agent_control.ex),
[Triage Worker selection](../../systems/apps/salix_agent/lib/salix_agent/triage_worker.ex),
[AgentModel](../../systems/apps/salix_agent/lib/salix_agent/agent_model.ex),
[AgentRoleActor](../../systems/apps/salix_agent/lib/salix_agent/agent_role_actor.ex),
[InternalSessionActor](../../systems/apps/salix_agent/lib/salix_agent/internal_session_actor.ex),
[RetiredSessions](../../systems/apps/salix_agent/lib/salix_agent/retired_sessions.ex),
[Participant owner](../../systems/apps/salix_im/lib/salix_im/conversation_participant_actor.ex),
[Condensed Workspace store](../../systems/apps/salix_store/lib/salix_store/condensed_workspaces.ex),
[Condensed Workspace runtime](../../systems/apps/salix_agent/lib/salix_agent/condensed_workspace.ex).

The Condensed Workspace is a new entity because no existing concept holds Group-wide facts that every Session must keep in context.
Router `/memory` belongs to one Agent, is never loaded automatically, and has no size limit.
Project Knowledge holds source-backed BFT facts that a provider retrieves per question.
`SalixStore.CondensedWorkspaces` owns the statements, revision and last writer. The Group record owns only the flag.
Sessions hold delivered copies as runtime messages. These copies are not a second authority.

A write applies `add`, `replace` and `remove` atomically and advances the revision once. An unknown id fails the batch and returns the current list.
A statement holds at most 2 KiB. Guidance recommends 4 KiB in total. Above 16 KiB, a write removes statements from the end and names them.
An Agent write uses the Group memory IFC destination. Before it applies, the decision model asks one `noul` question per new or replaced statement: is it a current fact that other Agents need?
Below 15%, the tool rejects the update with a `rejection_id`. The same operations with that id as `force_override` skip the check.
The thresholds (15% here, 50% for an update reminder, 70% for a rethink reminder) come from 62 labelled cases against jev-1.13 on 2026-10-05. They are not a statistical calibration.
The id digests Group, Session and operations. It binds the override to the rejected content and is not a credential.
A check that cannot run does not block the write. Comma edits skip it, and Comma allows only the Workspace owner.
The list grants no authority and changes no ownership, so no TLA+ model covers it.
The round check reads only the 16 newest user and assistant messages with text through the kernel query `request_conversation_tail`, not the whole transcript.
The Runtime Activity tab shows that read (`cw_evidence`) and the next activation's wait for the answer (`cw_wait`), with their wall-clock share.
See [the runtime contract](../agent-runtime.md#condensed-workspace) for delivery and the round check.

An Agent's model is its Model Choice (`model`). An Agent without one follows the Platform Model
of its role on each round: a Router the `router` tier, a Worker the `worker` tier, and a meeting
Agent the `summary` tier ([AgentModel](../../systems/apps/salix_agent/lib/salix_agent/agent_model.ex)).
A role whose tier is not configured has no model. Such an Agent can be created but fails its rounds with `platform_model_unconfigured` until the platform configures the tier.
Templates and Agent defaults are retired: no code reads or creates a template, a platform default pointer or a Tenant creation default.
Agent creation and configuration reject `template_id`. A `template_id` that an Agent record from an earlier release still holds is ignored.
A BFT Organization stores an allowed model list and per-role default models as Model Choice values ([Organization](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/organization.ex)); a new Router gets a copy of the Router default. The Organization's default Task model (`default_task_model`, formerly the default Worker model) is the model a Task inside Salix runs in a swarm that has no default Task model of its own ([BridgeForTeams.Models](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/models.ex) `default_task_model/1`).
Migration `20261010000101_convert_org_template_models` converts the earlier template settings once, after Salix migration `20261009210001`.
A subscription-pool template becomes its catalog model. An own-endpoint template becomes its model on the Custom Profile that Salix made for it.
A global template becomes the platform model of a default's role and leaves the allowed list. Gone or refused templates are dropped.
The pass fills only empty settings and leaves the template columns unchanged.
The stored template records, Tenant template records and `ctl/system/agent_defaults.json` stay until a release task clears them.
A deployment that names its one model (`llm.default_template`, a local or self-hosted installation) sets it up as the tier of each role not configured yet when Comma provisions a Workspace ([CommaWeb.SalixClient](../../systems/apps/comma_web/lib/comma_web/salix_client.ex)).
A Platform Model change affects every Agent that follows it.
Comma exposes its current Router and the Workspace's default Task model (Settings > Models); the response keeps an empty `workers` page, and `…/agent-models/workers` answers one, only for desktop apps already shipped. New Workers follow the platform model unless the Router chooses a catalog model.
A Group's default Task model is a Model Choice value on the Group record (`default_task_model`), not an entity ([SalixAgent.TaskModel](../../systems/apps/salix_agent/lib/salix_agent/task_model.ex)). It is a catalog choice or the platform `worker` model, which its product sets: Comma's Settings > Models, and BFT's Agent Swarm settings (a catalog choice must be on the Organization's allowed list; an admin can also clear it). A BFT Router passes `model` on each Task the user named a model for instead of relying on the Worker's model. A Task inside Salix that names no model, through any create path, stores it as its Worker Session's choice ([SalixIM.TaskConversationInput](../../systems/apps/salix_im/lib/salix_im/task_conversation_input.ex)). A Group that has set none leaves the Worker's own model, which is the platform model unless the Worker has its own (BFT Workers configured in the dashboard). Choosing Comma's built-in model stores the platform model, so it outranks a Worker's earlier model. Comma migration `20261019100001_derive_default_task_models` gave each Workspace whose Task Worker had its own model that model as the default, once ([Comma.Migrations.DefaultTaskModels](../../systems/apps/comma_core/lib/comma/migrations/default_task_models.ex)).
BFT Workers are retired (2026-10-19): the dashboard and CLI make no new Worker (create, rebind and archive answer 410 `workers_retired`), a Worker made before stays as read-only history, and its running Tasks and Schedules finish. Triage Tasks run on the swarm's Task agent at its default place and default Task model. A Slack connection delivers to the swarm's Router or binds each new thread to a Task of the Task agent (`inbound_tasks`, with the model those Tasks run; none: the default Task model) ([SalixIM.ProviderConnects](../../systems/apps/salix_im/lib/salix_im/provider_connects.ex)). BFT migration `20261019160001_bind_worker_slack_connections_to_tasks` bound each connection that delivered to a Worker to Tasks with that Worker's model, once; a thread bound to the Worker before stays bound to it ([SalixAgent.Migrations.SlackTaskBindings](../../systems/apps/salix_agent/lib/salix_agent/migrations/slack_task_bindings.ex)).
No Router manages a Worker (Comma decided by 左子健, 2026-10-08; every product 2026-10-19, Workers retired): a Router is not offered `agent.list`, `agent.get`, `agent.create_worker`, `agent.update`, `agent.rebind_runtime` or `agent.archive` ([SalixAgent.ToolPolicy](../../systems/apps/salix_agent/lib/salix_agent/tool_policy.ex) `role_disabled_tools/1`), and it creates a Task without `agent_id`; the Group's [Task agent](#task-agent) takes it, the Task's `runs_on` chooses where it runs, else the Group's default place, and its `model` the model, else the Group's default Task model. A user's request for a Worker with a model, name or instructions becomes that `model` and content on each of their Tasks. Comma's `agent.models` lists the catalog models that the Tenant's usable Profiles serve ([CommaWeb.AgentManagement](../../systems/apps/comma_web/lib/comma_web/agent_management.ex)). In BFT a Task may take a catalog model the Router chose only when the Organization's allowed list has it (an empty list allows any; an allowed entry without an effort allows every effort, one with an effort only that effort; a choice without an effort takes `medium` when the model offers it); a refused one is `model_not_allowed` and creates no Task ([Salix.Bindings.AgentManagement](../../systems/apps/salix_web/lib/salix/bindings/agent_management.ex), `BridgeForTeams.Models.router_choice/2`). The platform model and a station's runtime models need no allowance. A BFT Router's `agent.models` lists only what that check accepts: an allowed model the Organization's Profiles can serve (an allowed entry without `allow_paid` needs a subscription), with only its allowed efforts and the allowed entries as `choices` (`BridgeForTeams.Models.router_model_filter/1`). Product-started Tasks, such as mail drafts and desktop meetings, run on the Group's [Task agent](#task-agent) too ([CommaWeb.AgentManagement](../../systems/apps/comma_web/lib/comma_web/agent_management.ex)), and a Linear Task runs where and on what the Workspace's defaults say. This adds no entity.

Quick Chat sends an ordinary user Message to the Workspace's fixed Home Conversation.
[QuickChat](../../clients/packages/core/src/quick-chat.ts) uses the same message endpoint as typed Chat.
The source marker `metadata.message_type: quick_chat` identifies voice input. It grants no authority and adds no entity.
The Conversation owner retains the sender, request identity, permissions, and ordered log.
The [Session input command](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Command.lean) binds each human request's source context to that request in the same input batch.
This scheduling value grants no authority. Context for a later request stays queued until that request can activate.
Current-source tool completions can still pass later requests. Each terminal reply settles only its own request after a successful send.
The Router decides whether to answer, clarify, continue the intended Task, or create a new Task under its ordinary policy.
Sending words does not create a Task or start a Worker. A Router reply can carry the actual Task reference.
A Task's Comma summary names the Message it was created from (`parent_message_id`, from the Task's `source_refs`). It grants no authority.
The desktop Notch row of sent words shows the running Task made from their Message in the same row ([QuickChatService](../../clients/apps/electron/src/main/quick-chat.ts)).

Each Task report names its stored `parent_conversation_id` to the delegator, as a routing fact with no authorization authority.
Worker deliveries name no parent. The Router uses the report's parent to deliver results or questions to Home.

The prompt combines the server's dictation transcripts (`recordings.transcribe`), prefixed by any retained draft.
A failed clip keeps its on-device words.
Natural pauses close audio clips. Continuous speech also closes clips, each at most 60 seconds.
The helper queues contiguous clips through Main, with at most two encoding or transcription requests in flight.
Slow replies do not drop queued audio. Server words replace only their clip, in audio order.
Return shows a pending Notch row immediately, retains in-flight requests, and transcribes the remaining clips and final tail.
Send-time clips wait for transcription admission. Each failed background clip can retry once during send, then keeps its local words.
It does not transcribe completed clips or the whole recording again.
After 30 seconds without completed preparation, Main makes the row retryable with the finalized local words and rejects late results.
Helper exit also makes a pending preparation retryable. Clicking edit or keeping a draft does not wait for network transcription.
Audio closed without sending can therefore already have reached transcription.

Electron routes Comma API GET event streams through one fixed, non-persistent network session.
Other Comma API requests, including transcription uploads, use the default pool.
Both use Main's credential and lease checks ([API proxy](../../clients/apps/electron/src/main/protocol.ts)).
The Electron dictation deadline is 10 seconds, including admission, HTTP queueing and response reads.
The [Electron core](../../clients/packages/core/src/hosts/node.ts) aborts requests cancelled before response headers and closes streams when their scope ends.

Dictation uses the transcription tier with reasoning effort `low`. Its model must accept `reasoning_effort`, as Gemini 3 Flash does.
[Transcribe.hedged/2](../../systems/apps/salix_llm/lib/salix_llm/transcribe.ex) retries after 3.5 seconds or a failure, with a 9-second budget.
Quick Chat is speech to text only: it shows no words that nobody said.
For audio without speech (room noise, typing, a cough), the model writes a whole made-up request in about half of its answers.
Dictation is therefore asked with voice facts. A clip or segment without a voiced 40 ms frame is not asked, and words more than its voiced time can hold are dropped.
A live segment in which the provider heard no words has none, whatever the model wrote. If the provider failed before it heard a word, the model's words stand.
Meeting recordings retain the tier's configured reasoning effort.

Quick Chat retains the limit of 16,000 UTF-8 bytes and the ordinary Home authorization and billing checks.
The response names the accepted Message, not the Conversation's latest Message or a Task.
A network error, timeout, or HTTP 5xx triggers one automatic retry with the same `client_request_id` and words.
Unknown outcomes retain that identity. Explicit retries also keep it, so an accepted Message cannot duplicate through a lost response.

Main submits pending sends in Return order, even when later transcripts finish first.
After a send fails, later sends can proceed. Explicit retries wait behind already pending sends and retain the original request identity.
An unaccepted Message appends at its later retry time. Reusing an accepted request id with different words fails without changing the original Message.
The desktop retains a focused Workspace known at Return.
Otherwise it selects the current focus, or first listed Workspace, when the words are ready to send.
If the list names no Workspace, the send waits up to 30 seconds before Main marks the row retryable.
After selection, every retry keeps that Workspace and the same user's request identity.
The Notch shows the user's words immediately. It stops the progress animation after Message acceptance and keeps those words without a status subtitle.
A sent row opens Home. Actual Tasks appear through the existing Task list, without guessing a Task from a nearby Message.
Failed sends remain Main-owned rows. These rows are transient projections, not new Task or Message authorities.

The Platform Model replaces global templates for platform-funded models (decided by 左子健, 2026-10-08).
[PlatformModels](../../systems/apps/salix_agent/lib/salix_agent/platform_models.ex) stores its name and, per tier (`router` and `worker` for Agents and Tasks; `summary` for meeting notes and the meeting Agent; `transcription` for meeting audio),
the internal model: a platform Profile, the model id that Profile is asked for, an optional protocol and reasoning effort, and the
context, output and image limits the runtime uses (`ctl/system/platform_models.json`, edited on the dashboard's Platform model page).
A Model Choice `{"kind": "platform", "tier": ...}` names an Agent tier. An Agent that follows the platform default takes its role's tier.
The `worker` tier runs its configured model, or, while the platform route table below is on, the model the table returns for the Task: `{"kind": "platform", "tier": "worker", "model": id}`, a catalog model id (or a platform Custom endpoint's model) that the first enabled platform API key serving it runs ([AccountPool](../../systems/apps/salix_agent/lib/salix_agent/account_pool.ex) `platform_key/1`).
A routed choice can include `reasoning_effort`, selected from the model's supported efforts.
An omitted effort uses the provider default, not the fixed Worker tier's effort.
Members see it only as the Platform Model's name. Its calls carry `credential_scope` `platform` and are metered against the
member's credits. Its public view holds only its name, so neither members nor the Router see the internal model, endpoint or limits.
Migration `20261008200001_platform_models` ([Migrations.PlatformModels](../../systems/apps/salix_agent/lib/salix_agent/migrations/platform_models.ex))
moves the platform's models off global templates in one pass (run again by `20261009010001_platform_models_chat_completions`, which also takes a template without a protocol as Chat Completions, and by a later pass that turns the deployment's `meetings.summary_template` and `meetings.asr_template` into the `summary` and `transcription` tiers): each role's platform default template becomes a platform Profile
(LMHub for an LMHub endpoint, else Custom; an existing Profile with the same endpoint and key is reused) and its tier's internal model;
the Router default template's media becomes the media settings when none are stored; and each Router or Worker pinned to a global
template, with no model choice, takes `{"kind": "platform", "tier": <role>}` and keeps its `template_id` for the previous release.
A default template without an endpoint or key leaves its tier unconfigured and its role on the template.
A provider that needs more than an endpoint and a key gets a source of its own with an adapter, not Profile fields
([ProviderAdapters](../../systems/apps/salix_agent/lib/salix_agent/provider_adapters.ex)). The internal LMHub gateway is such a
platform-only source: only the platform Tenant can connect it, it may use the cluster's plain HTTP address, members and stations
do not see it (`/v1/comma/model-catalog` and `systems/profiles/sources.json` omit it), and its adapter adds the user agent the
gateway admits the deployment by (`SALIX_LMHUB_USER_AGENT`, chart `runtime.lmhubUserAgent`, release spec `lmhubUserAgent`).

A Model Choice is a value, not another template or entity ([SalixAgent.ModelChoice](../../systems/apps/salix_agent/lib/salix_agent/model_choice.ex)).
A catalog choice holds a catalog or Custom Profile model id, an optional reasoning effort, `allow_paid`, and an optional pinned Profile.
A runtime choice holds a model and effort for a Codex or Claude Code Worker, on a Compute runtime or a connected device.
`ModelChoice.record/2` answers the unstored model record a choice stands for (model id, provider configuration, limits and presentation); `llm_config/1`, `media/2` and `public_json/1` read it.
Comma and BFT store catalog, runtime and platform selections this way.
Migration `20261008000101_agent_model_choices` copies each Agent's Tenant-private catalog or runtime template into `model` and keeps the `template_id`, so processes of the previous release resolve the same model until the rollout completes. The conversion checks template ownership but preserves choices whose Profile was deleted or whose model left the catalog. It preserves the model id, pinned Profile, effort and payment choice. Requests still use the normal model and Profile checks. Migration `20261009210001_template_pin_choices` ([SalixAgent.Migrations.TemplatePinChoices](../../systems/apps/salix_agent/lib/salix_agent/migrations/template_pin_choices.ex)) gives every Router and Worker still pinning a template its `model`: a subscription-pool template becomes the catalog choice of its model, an own-endpoint template becomes a Custom Profile of the Tenant (one per template) whose model the Agent chooses, and any other pin follows the platform model of its role.
The Session state field `model` stores a Session's catalog choice.
The Session takes it at birth, from the first delivery, and a `session_update` replaces or clears it. A fork copies it.
While it is set, rounds, compaction and the status read resolve that choice instead of the Agent's model ([LlmResolver](../../systems/apps/salix_agent/lib/salix_agent/llm_resolver.ex)).
The Agent's prompt, tools and runtime still apply, and its round snapshot stays shared by its Sessions.
A Router sets it through the optional `model` of `im_api.internal.task.create` for a Worker on the internal runtime.
The Worker Participant's payload carries it to the delivery that creates the Worker Session. The product checks it first: Comma checks it as `agent.create_worker` does, BFT applies its organization model policy, and a standalone Salix Group resolves its Tenant's catalog choice.
The optional Group value `task_model_selection` reuses this Model Choice. It adds no model, Task, or rule entity.
The Group owns the bounded policy. For an internal Task without an explicit model, the Conversation owner selects before commit.
It stores the selected value on the Worker Participant. Explicit models and normal Task placement retain their existing rules.
Product-created Tasks use the prepared delegator Participant for decision attribution when no Router round supplied a Session.
`routes` stores user-defined entries with unique keys, descriptions and catalog Model Choices. Empty and disabled tables preserve normal Worker model selection.
The Dashboard can add and delete entries. Decisions retain the matched key, selected Model Choice and configuration revision. Existing Tasks keep their models.
`jev` chooses a configured candidate. The retired difficulty table (`tag_rules`) was converted to `routes` entries `d1` through `d10` ([SalixWeb.Migrations.DifficultyRouteTables](../../systems/apps/salix_web/lib/salix_web/migrations/difficulty_route_tables.ex)).
`explicit` requires every internal Task caller to supply an allowed model and effort, checked at the common creation entry. An optional Profile pin uses the existing Model Choice authorization.
The committed Task metadata retains policy mode, decision source, rule provenance and usage, without copying the Task body or complete decision. Retries keep the committed model; policy changes affect new Tasks only.
Salix owns adaptive routing statistics when this policy includes `learning`. The state remains a Group-owned policy value, not a new Task or model entity.
Each feedback receipt references the existing Task Conversation ID. One Task contributes at most once, including after evidence-window eviction.
The policy generation hashes the complete configured policy except `enabled`. Changes to questions, actions, prices or settings start new evidence.
Disabling and re-enabling the same policy retains its evidence. Existing Tasks retain their committed selection and generation.
See [TaskModelSelection](../../systems/apps/salix_im/lib/salix_im/task_model_selection.ex) and [the runtime contract](../billing-models.md#task-model-selection).

The platform route table (`routing` in `ctl/system/platform_models.json`, the dashboard's Platform model page) is a value of the Platform Model with the shape of a Group `routes` table; each entry names a model of the `worker` tier, chosen from the models the platform's API keys serve.
The editor and platform learning offer each model with its supported reasoning efforts, plus the provider default.
Learning keeps separate evidence for each model and effort pair.
It applies to a new internal Task whose model is Comma's built-in model (`{"kind": "platform", "tier": "worker"}`: the Task's own, the Group's default Task model, or the Worker's following model) in a Group whose own table is absent, disabled or empty. A Group's own table always wins.
It also applies to a Task a Slack thread bound to Tasks makes when the connection's model is the built-in model ([TaskConversationInput](../../systems/apps/salix_im/lib/salix_im/task_conversation_input.ex) `ensure_with_id/5`); that Task's own Worker Session asks for the decision, once, before its first commit.
Its decision metadata carries `routing_scope: "platform"` (Group decisions carry `"group"`). Group routing usage statistics leave platform-routed Tasks out.
It adds no entity: decisions, receipts and evidence are the same values as a Group table's.

A Task can run on a Station. Explicit `runs_on`, Worker Station Binding, and the Group's configured default location keep their selected target.
A Router's `im_api.internal.task.create` always names `runs_on.kind` and is refused without it. `{kind: default}` names no place, so the binding, the configured location or automatic placement below decides.
Product-created Tasks (`SalixIM.TaskPlacement.create_task_conversation/4`) may still omit `runs_on`.
A runtime model without a chosen location uses automatic placement: the Group's VMM Station, the requester's authorized physical Station, then enabled Cloudflare.
A catalog-model Task without a machine choice runs inside Salix. Explicit `runs_on: {kind: salix}` stays there.
The runtime choice uses `provider: codex|claude` and can name a model advertised in the Station's `task_models`.
Without a model id, the Station uses that runtime's authorized default.
Managed Stations use cloud-authorized profiles, including the platform worker model supplied through [StationLLM](../../systems/apps/salix_web/lib/salix_web/station_llm.ex).
A physical Station uses its local machine login only after the owner enables that source.
Task creation stores the selected Device before execution. Accepted or uncertain invitations retain that target across retries.
A Task placed on the Group's Cloud VM while it sleeps, wakes or was never made is kept for its station: the VM is woken or made, and the station invited once the VM is ready ([SalixWeb.StationTasks](../../systems/apps/salix_web/lib/salix_web/station_tasks.ex)). `cloud_vm.start` is for running commands there; where sandboxes are set up it is retired with the Cloud VM (not offered, `cloud_vm_retired` if called), and a Worker creates one sandbox Task for such work ([agent runtime](../agent-runtime.md#where-a-task-runs)).
Only confirmed nonacceptance permits another automatic candidate. Missing identity mapping cannot authorize another person's Station.
[StationTaskWatch](../../systems/apps/salix_im/lib/salix_im/station_task_watch.ex) follows the stored location after disconnection.
These choices and projections add no entity.
A Group's `default_task_place` is a value on its record: `{kind: salix}`, `{kind: cloud_vm}`, or `{kind: station, device_id}`.
A coding Task's explicit `{kind: sandbox}` uses its [coding sandbox](#coding-sandboxes). Sandbox is not a Group default or an automatic Station candidate.
Comma exposes it in Settings > Models. BFT exposes it in Agent Swarm settings.
The product checks the configured location through the same placement contract as an explicit `runs_on`.
Without a configured location, a runtime-model Task uses automatic placement.
Without either a runtime model or a chosen location, a Task stays inside Salix.
A Loop Task runs inside Salix. A Station binding or runtime model refuses Loop creation.
The BFT dashboard delegates New task through the Group's Router and uses the shared placement checks.
Meeting runtime placement has its own per-Meeting lifecycle.
A Router's Task from a person's Message in Comma, when that person has more than one computer connected (their own connected Stations that take Tasks, `SalixWeb.TaskStations.personal_computers/1`), is checked by [SalixIM.ComputerChoice](../../systems/apps/salix_im/lib/salix_im/computer_choice.ex). A Task aimed at one of them, `{kind: station}` or a Task inside Salix whose title or content carries that computer's device id or station id, is refused (`computer_choice_required`) until the conversation's newest 30 Messages show the person's choice, and the Router asks with a question card.
Only a structured answer refuses a Task on another computer (`computer_choice_other`): the choice picked on a question card, or a local-account card's bound computer. Words are a plain text match on names, ids and distinguishing name words, not an understanding of intent: a mention of the Task's computer lets it through, a clause with a negation counts for nothing, and a mention of another computer settles nothing, so the Router asks once. A which-computer card answered in words the match cannot place stands, so the Router does not ask twice. One computer, or a Task aimed at none, is not asked. A Worker binding, the Group's default place and automatic selection are the Router not aiming, and are unchanged. A failed lookup refuses nothing.
See [TaskPlacement](../../systems/apps/salix_im/lib/salix_im/task_placement.ex) and [TaskPlace](../../systems/apps/salix_agent/lib/salix_agent/task_place.ex).

A member of the Workspace may run a Task that exists on another model, and so perhaps in another place (Comma's `PUT …/conversations/:id/run`, [SalixIM.TaskRun](../../systems/apps/salix_im/lib/salix_im/task_run.ex)): the place is always named, and it and the model are checked as a new Task's are (`SalixIM.TaskPlacement.resolve/4`). The station that runs it now is invited first, with `replace` when it ran the Task already (a new Session takes the old one's place in the Task's thread); a station that refuses, or one too old to replace its Session, refuses the switch and nothing changes. A Worker inside Salix in the middle of a turn refuses the switch until the turn ends. Then the stations that ran it leave it (`task.leave`: their Sessions are handed nothing more, what they post is refused, and their turns are interrupted, not waited for, so a step in progress may finish; one not connected, or one that did not answer, is told again when it next says hello), the new one takes part and is given the Task from its start, and the Task's owner records the new `runs_on` (none inside Salix) and the Worker participant's delivery and `session_model` together, and writes the Worker a `task_run_switched` Message. A Worker inside Salix runs in a new Session made with the model (a Session takes its model when it is made) and reads the Task from its source start; a station's new Session is handed what its station had not answered. The Task keeps its id, Messages, status, labels and Router. Clients offer the switch on the Task panel's model and where the Task's model cannot start: a station's Session whose turn does not start posts its notice with `cannot_start`, which Salix keeps as a `task_run_blocked` Message ([SalixWeb.StationTasks](../../systems/apps/salix_web/lib/salix_web/station_tasks.ex)). A sandbox Task without a repository stays on its sandbox (`runs_on {kind: sandbox}`) and switches only its runtime model there: its sandbox's station replaces its Session, nothing is placed, authorized or counted again, and a sandbox that is not running takes no Session (`sandbox_not_running`: a Message to the Task starts it); the Task's run lists the models its station runs (`task_models`) while it is connected. A coding Task is not switched: its Session holds the checkout. This adds no entity.
Salix keeps no Session for such a Worker. Salix is the station the Task is kept on, and a Session of the other station takes part in it, as between any two stations (`systems/station/docs/tasks.md`, [SalixWeb.StationTasks](../../systems/apps/salix_web/lib/salix_web/station_tasks.ex)): Salix invites the station before the Task is made (`task.invite`, answered at once; a refusal refuses the create), gives it every Message after what it had (`task.put`, until it has it), and takes what its Session writes as the Worker's Messages (`task.post`, once per key). The Worker Participant only authors those Messages: it is delivered nothing. Which Session of which station takes part, and how far it was given the Task, is a row of `station_task_sessions`.
Existing Sessions have no choice and follow their Agent.

#### Routing usage statistics

[RoutingMetrics](../../systems/apps/salix_web/lib/salix_web/dashboard/routing_metrics.ex) is a read-only projection of existing Task decisions, Session telemetry and model reference prices. It adds no entity or storage authority.

The Dashboard routing tab shows usage for Tasks created in the last 1, 7 or 30 days.
It reads at most 1,000 recent Group Tasks and 20,000 recorded model calls, without per-Task RPC or polling.
Partial Task history is labeled. Excess call volume requires a shorter period. Unavailable telemetry never becomes zero usage.
Saved configuration filters use the committed `routes` revision. All configurations keep separate route, revision and model rows.
The original Worker Session links usage to a decision even after a Task changes models.
Historical decisions without that ID use only an unchanged Worker Participant with the same Model Choice. Otherwise, usage stays unknown.
Completion rate is completed / (completed + failed), using current Task statuses, which can reflect later runs. It is not a quality grade or learning feedback.
Mean model time sums recorded model-call durations per Task with all recorded durations. Missing durations are excluded. It excludes tools and queueing. Selection time and tokens remain separate.
Input includes cache reads and writes. Reference API prices from the pinned models.dev catalog estimate each recorded Worker's call, with supported context tiers.
These estimates are not charges. They exclude subscription fees, discounts, Router work, route selection and tools. Unknown prices or usage stay unknown.
The displayed cost is the priced subtotal. The page flags incomplete Task, usage-report and pricing coverage.
Completed per estimated dollar uses completed or failed Tasks whose recorded calls all have prices and usage, including failed Tasks' costs. The page shows its inverse, estimated cost per completed Task.
It describes this cohort, not model quality or comparative superiority. These reports do not modify learning state or billing.

#### Adaptive Task routing

A route table learns when its `learning` switch is on (`task_model_selection.learning: true`, the Dashboard's "Learn from task results").
A Group table's evidence is the Group's. The platform route table keeps one evidence store for every Group it routes (scope `platform` in place of a Group id), and its arms are the models the platform's API keys serve, priced by the catalog. Neither reads or writes the other's evidence (decided by Haowen Sun, 2026-11-03): their route keys and descriptions differ, so no evidence could carry over.
Platform evidence takes Task results only: the feedback API answers 409 for a platform-routed Task, so no tenant can steer the platform's table.
A route is one row: a key and a description. The learner assumes nothing about what a key means, and routes never share evidence.
The arms of a route table are every Model Choice and reasoning effort the route editor offers the Group when the Task is made.
Catalog models carry a list `price` (`scripts/generate-model-catalog.mjs`). An arm without a price is never sampled; a route whose own model has no price keeps it.

After the decision model chooses the route, `SalixAgent.TaskRouting.Learner` chooses the arm. Its value is its expected completion rate (a uniform Beta prior) divided by its expected USD cost for one Task.
At most one Task in ten explores: it samples each arm's completion rate from its Beta posterior. Every other Task takes the best mean value among the route's configured arm and the arms with at least five samples.
The Task's id seeds both draws, so a retry chooses alike. Evidence is the last 1,024 samples of a route, kept by its key and description: a changed description starts new evidence, and other edits keep it.
The Task's selection metadata records the route's evidence (`learning_generation`), the arm (`learning_arm`) and why it was chosen (`learning_reason`).

A Task gives one sample when its status is published: a review a person accepted is `completed`, and a failed Task is `task_failure`, with the Worker Session's token use. Other endings give none.
An evaluator can grade a Task instead:
`POST /v1/runtime/agent-groups/:group_id/routing-learning/feedback/:conversation_id` accepts at most 4 KiB of JSON with `outcome`, optional `quality` and optional `resources`.
Outcomes: `completed`, `task_failure`, `timeout`, `infrastructure`, `unattributed`. Quality ranges from zero to one and applies only to completion.
Resources contain `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_write_input_tokens` and optional `seconds`. Total input includes both cache categories.
The tenant must own the Group. The Task must be in review or have status `completed`, `failed` or `cancelled`.
Salix takes the route and arm from committed selection metadata, and checks the original Worker Session ID and Participant model.
Identical feedback returns `duplicate: true`. Conflicting feedback, replacement Worker Sessions and changed routes return HTTP 409.
`GET /v1/runtime/agent-groups/:group_id/routing-learning` returns each route's samples and arms, the arm a Task takes when it does not explore first.
Infrastructure and unattributed outcomes do not count as successes or failures.
Permanent Task receipts prevent replay after window eviction. A PostgreSQL row lock and transaction commit each receipt and state update together. Group deletion removes both.
Resource and quality estimates use EMA. Timeouts do not estimate normal completion cost or duration.
Eligible actions meet the sample and posterior thresholds and have measured resources.
Selection ranks single-attempt completion probability, quality and time utility per estimated dollar. Otherwise, the initial table applies.
Exploration limits are estimates, not charge caps. Concurrent Tasks can share a probe choice. Learning adds no reference-model retry.
Disabling routing retains evidence. Changing the configured policy starts a separate generation. Existing Task models stay fixed.
To freeze a learned table, read it, remove `learning`, and save it through the Group API.
See [Learner](../../systems/apps/salix_agent/lib/salix_agent/task_routing/learner.ex), [storage](../../systems/apps/salix_store/lib/salix_store/task_routing_learning.ex), and [Task integration](../../systems/apps/salix_web/lib/salix/task_routing_learning.ex).

### Task agent

A Group's Task agent runs each Task of the Group that names no Worker, for every product ([SalixAgent.TaskAgent](../../systems/apps/salix_agent/lib/salix_agent/task_agent.ex)).
It is not an entity: the Group record holds its Agent id (`task_agent_id`, next to `default_task_model`), and the Agent is an ordinary internal Worker.
Reuse is sufficient because a Worker already has the Session, Participant and memory relationships a Task needs. Where the Task runs and its model stay values of the Task and the Group.

- Owner: Salix. Products, Routers and people do not create, name, configure, bind or archive it. `TaskAgent.ensure/2` answers the recorded Agent. A Group without one gets an Agent with a fixed id made from the Group id (`agt1_<group body>_0000000000000000001`, a snowflake body never generated), created as a Salix-owned preallocated Agent, so concurrent and repeated calls converge on one Agent before the Group records it. A guest (router-only) Tenant has no Task agent (`guest_group`).
- Comma: Comma migration `20261019230001_adopt_group_task_agents` ([Comma.Migrations.GroupTaskAgents](../../systems/apps/comma_core/lib/comma/migrations/group_task_agents.ex)) made the Worker that ran each Workspace's Tasks before (its stored default Worker, else its first unarchived internal Worker) its Group's Task agent, once; it created no Agent. That Worker keeps its name, so shipped desktop apps show the same executor. A Workspace without such a Worker gets the Agent Salix makes. Comma neither provisions nor reads a Workspace Worker: every Comma Task, Router-, product- or Linear-started, runs on the Task agent. Comma clients show a Task's place and model instead of its Agent ("on Mac Studio · Claude Sonnet"): Task reads and the Task status stream carry `run` (`place`: inside Comma, the Cloud VM or a station by name; `model`), read once per stream ([CommaWeb.SalixClient](../../systems/apps/comma_web/lib/comma_web/salix_client.ex) `task_run/2`). The Settings > Models `worker` entry and the admin `agent-models/worker` alias name the Task agent.
- Visibility: the Agent is not `hidden`, so Task code and memory consultation treat it as any Worker. The Router tools `agent.list`, `agent.get`, `agent.update`, `agent.rebind_runtime` and `agent.archive` leave it out ([AgentManagement](../../systems/apps/salix_agent/lib/salix_agent/agent_management.ex)), and BFT's Agent lists ask for pages without it (`page_agents/3` with `exclude_task_agent`, [BridgeForTeams.Agents](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/agents.ex)). A Salix node of the release before ignores that option and lists it until the rollout completes.

### Station Binding

A Worker can carry where its Tasks run: `station_binding` on its Agent record ([SalixAgent.StationBinding](../../systems/apps/salix_agent/lib/salix_agent/station_binding.ex)).
It is a value of the Worker, not an entity: the Worker, the station and the Task keep their identities and owners, and the binding only names a place and a model.

- Value: `runs_on` is `{kind: station, device_id}` for an exact physical or VMM Station, `{kind: sandbox}` for a sandbox of each Task's own, or `{kind: cloud_vm}` for the Group's Cloud VM. The [Cloud VM cutover](../agent-runtime.md#cloud-vm-cutover) rebinds each `{kind: cloud_vm}` Worker, its model kept and its revision advanced (`AgentControl.rebind_cloud_vm/2`): to `{kind: sandbox}`, or, in a Group whose Workload is on an Agent VMM Host, to that VM's station `{kind: station, device_id}`; afterwards no binding names `{kind: cloud_vm}`. The station form of a Group's own VM is accepted only on its Agent VMM Host (`SalixStore.ComputeGroupStation.vmm_group_vm?/2`); for a Cloudflare VM it is refused as `{kind: cloud_vm}` is.
  The Group's Cloud VM, one its Tenant's provider makes or on its Agent VMM Host, permits startup and Task placement. `cloud_vm.start` accepts the caller or a same-Group Worker, where the Cloud VM is not retired.
  A Worker binding supplies a default Task location and model; it grants no additional authority.
  New Group Cloud VMs use Cloudflare. Existing records retain their selected provider.
  `model` is a runtime Model Choice with provider `codex` or `claude`. Without a model id, the Station uses that runtime's authorized default.
  `binding_revision` counts rebinds.
- Owner and checks: Agent Control writes it on create, configure and `rebind_station_worker` (revision CAS). Only a Worker takes one; the model must be a catalog model of that runtime ([AgentControl](../../systems/apps/salix_agent/lib/salix_agent/agent_control.ex)).
- Tasks: a bound Worker is an internal Worker. `im_api.internal.task.create` gives each of its Tasks the binding's `runs_on` and model when the call names none; a call may name the same place and a model of the same runtime ([SalixIM.Provider.Internal](../../systems/apps/salix_im/lib/salix_im/provider/internal.ex)). The Task then runs on that station as any `runs_on` Task: a desktop station must be connected and take Tasks (`tasks` 2), the Cloud VM need not be running, and a named model must be one the station reports. A device that cannot take Tasks is refused with a reason ([StationReadiness](../../systems/apps/salix_store/lib/salix_store/station_readiness.ex)): `device_needs_station` (no `tasks`: the old connector; install the Comma desktop app or the station) or `station_outdated` (an older `tasks`; update the desktop app, or `comma-station update` on a standalone station). The BFT Devices page shows the same notice per device. Comma's Settings > Devices rows and device reads carry the same reason as `tasks_readiness` (`ready`, `device_needs_station`, `station_outdated`, or `offline` while the device is disconnected) with the station's `task_models`, projected from the device record the page already reads ([Comma.Devices](../../systems/apps/comma_core/lib/comma/devices.ex)).
- Creation: BFT's "Run on a station" ([BridgeForTeams.Agents](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/agents.ex)) and the raw Agent API create or move bound Workers. Agent Control refuses External Runtime Workers (`runtime_config` kinds external, connected_runtime, compute_workload); `runtime_config` takes only kind internal.
- Stored Pi and Kimi Workers retain their archive reason and data. Current Station bindings support Codex and Claude Code.

### Retired Sessions

Salix no longer runs External Sessions. Their stored records stay where they were written: one `state.json` object and one record stream per Session under `agents/<agent_id>/external_runtime/sessions/`. No release deletes them.

- Reads: [SalixAgent.RetiredSessions](../../systems/apps/salix_agent/lib/salix_agent/retired_sessions.ex) lists and reads them as `runtime_kind: "retired"`, `read_only: true` and status idle. [SalixAgent.Runtime](../../systems/apps/salix_agent/lib/salix_agent/runtime.ex) adds them to the Agent's Session list and reads one when the internal store has no Session of that id. Billing history includes the usage they recorded. They cannot be forked, compacted or consulted.
- Input: PostgreSQL Session birth is the identity authority ([InternalSessionStore](../../systems/apps/salix_agent/lib/salix_agent/internal_session_store.ex)). Import preserves external markers and markerless retired history as retired rows. Delivery answers `session_read_only`; no internal Session can reuse that identity. Historical S3 body availability does not control online admission.
- Work: PostgreSQL birth rows retain retired identity. The due dispatcher and owner-start work query select only internal Sessions.
- Conversation consumption: [ConversationConsumer](../../systems/apps/salix_agent/lib/salix_agent/conversation_consumer.ex) recognizes the PostgreSQL retired birth as a terminal source. Log recovery completes without input or rejection writes to those Sessions, after any pending Triage command escalation through the Conversation owner. Storage failures remain retryable. An explicit Router reset can replace a retired Session with a new internal Session identity.
- Meeting bots keep their LLM capability ([SalixAgent.MeetingLLMCapability](../../systems/apps/salix_agent/lib/salix_agent/meeting_llm_capability.ex)): it is minted per meeting connect, bound to the Connector run, and used only for `/llm/chat` ([SalixWeb.RuntimeProxy](../../systems/apps/salix_web/lib/salix_web/runtime_proxy.ex)).

Every Agent takes the platform's media settings: one image generation, video generation,
vision describer and analyzer configuration each, paid for by the platform ([MediaSettings](../../systems/apps/salix_agent/lib/salix_agent/media_settings.ex),
stored at `ctl/system/media_settings.json`, edited on the dashboard's Media settings page).
Image input follows the chosen model. A catalog choice that the Tenant's own Codex subscription serves
generates images with `gpt-image-2` through that subscription pool instead
([billing-models](../billing-models.md#codex-subscription-images)). This adds no entity.

Members choose their own Profiles' models or Comma's built-in model (decided by 左子健, 2026-10-08), so the
Comma Model Selection Policy that listed selectable global templates is retired. The administrator support path
sets a catalog choice or the platform model. The `comma_model_selection_policy` table stays until a later release drops it.

The Model Catalog is separate from Profiles because a Profile binds models to one provider
connection. The catalog says that `openai/gpt-5.5` at OpenRouter and `gpt-5.5` at OpenAI are
the same model, which no account can express.
Its identity is the catalog model id, platform-wide. [SalixAgent.Models](../../systems/apps/salix_agent/lib/salix_agent/models.ex)
owns it as read-only data compiled from `priv/model_catalog.json`.
`scripts/generate-model-catalog.mjs` reads the committed models.dev snapshot. `scripts/refresh-model-catalog.mjs` updates that snapshot.
Source mappings and subscription limits stay in `scripts/model-sources.json`.
Context window caps by vendor and family stay in `scripts/model-limits.json`; a cap is a product limit, not a model fact.
Models and routes the snapshot lacks stay in `scripts/model-additions.json`. A model or route leaves the catalog only when its `removed` names it.
A release changes the catalog. No runtime path changes it. The Gemini plan's
routes come from `scripts/antigravity-models.json`, the Antigravity list of the pinned
CLIProxyAPI SDK, because the subscription worker sends Antigravity model ids unchanged.
Sources name what an account pool account connects to. Model choices and accounts may
reference catalog ids and source ids; the catalog references neither.

A Profile has one structure and one logic for Comma and its stations:
[systems/profiles](../../systems/profiles/src/lib.rs) holds the sources, the Profile, which Profiles
serve a request and in what order, and how a runtime is given one. Salix loads it as a NIF
([SalixAgent.Profiles](../../systems/apps/salix_agent/lib/salix_agent/profiles.ex)); a station loads it
in its mesh addon. Both store a Profile as that structure: an AccountPool record is the Profile
with the server's fields beside it (sealed credentials, versions, email); a station's config.json
profile is the Profile with the station's beside it (home, key, share). The APIs keep their earlier
shapes. This adds no entity.

A catalog choice is a Model Choice with a catalog model id, a reasoning effort
and `allow_paid`, and no endpoint or credential. [AccountPool](../../systems/apps/salix_agent/lib/salix_agent/account_pool.ex)
chooses the Profile for each request: enabled subscription accounts whose plan serves the
model first, then, when `allow_paid` is true, enabled API-key accounts whose source serves it.
Only the Tenant's own Profiles serve a catalog choice; the platform pays only for the Comma
model (decided by 左子健, 2026-10-08: members choose their own Profiles' models or one Comma
model, whose underlying model they do not see).
A platform Profile is an ordinary API-key Profile stored under the reserved platform Tenant
(`SalixStore.Ids.platform_tenant_id/0`).
Salix operators add, disable and delete platform Profiles on the dashboard's Platform Profiles page
([PlatformProfileLive](../../systems/apps/salix_web/lib/salix_web/dashboard/live/platform_profile_live.ex)).
`agent.models` and the catalog choice never list or accept a platform Profile's models.
`agent.models` and the BFT model list use the local catalog and Profile state.
The routing editor uses that same local list, scoped to its optional tenant-owned Profile and product model policy.
Saving refreshes local account state. Inference keeps the normal model and Profile authorization checks.
A Profile's `disabled_models` lists the model ids its owner turned off, at most 500.
The Profile serves none of them: not automatically, not when an Agent keeps to it, and not in
`agent.models` or the Comma picker. The list holds exclusions, so a model added to the catalog
starts on.
A Cloud VM runtime bound to a subscription account receives the whole credential, so the
runtime's own CLI does not read the list either.
Every subscription provider is a plan. Its pool route sets the wire protocol;
the catalog route gives only the request id.
A request that fails before output moves to the next candidate, across providers.
It never falls back to platform credentials, and it is billed as tenant-funded.
A catalog route binds its Profile only at dispatch. Every step before dispatch therefore
stays provider-neutral: the request is not encoded for a protocol or a request id, and each
candidate's provider encodes it. Paths that post a resolved route themselves, such as the
site LLM proxy, send a catalog or subscription route through the same dispatch.
An Agent kept to an API-key Profile pays for it: its choice is stored with `allow_paid` true.
When no Profile can serve the choice at all, the request fails without retries as `model_unavailable`,
and the stop notice tells the member to choose another model or enable an account that serves it.
An OpenCode Go Profile can also be signed in with the member's OpenCode Console account ([OpenCodeConsole](../../systems/apps/salix_agent/lib/salix_agent/open_code_console.ex), a device code). It stays an `opencode-go` API-key Profile: the Console's access token is its key, the single-use refresh token is sealed beside it, and AccountPool renews the token three days before it runs out, one renewal at a time per Profile. A later sign-in to the same Console account renews that Profile. Requests through an OpenCode Go key carry `x-opencode-session`, one per Session.
A Custom Profile lists the model ids its endpoint serves. A catalog choice can also name
one of these ids when it is not in the catalog. Only that API key serves such an id, so the choice
is pay-per-use: it is stored and read with `allow_paid` true ([ModelChoice](../../systems/apps/salix_agent/lib/salix_agent/model_choice.ex)).
When that Profile is removed, a stored choice still reads as the model id: the settings page shows it, and
the Agent's input stops as `model_unavailable` until the member chooses another model. The Profile's optional `model_info` says, per
listed id, its context and output limits, whether it takes images and its reasoning efforts;
an id it says nothing of has no efforts, a 32,000-token output limit, no context limit and no
image input.

A runtime choice is a Model Choice for a Worker on a Codex or Claude Code
runtime. It holds a catalog model id that the runtime can run, the runtime provider
and a reasoning effort. It has no endpoint or credential, because the runtime uses its own login.
On a connected device, dispatch sends the Session's runtime choice, else the Worker's. The model,
model provider and effort that the device reports for the runtime, live or recorded in an older
binding, are observations and not choices. Without a choice, dispatch sends no model, and the
runtime runs its own default. BFT gives a new Codex or Claude Code Worker the provider's flagship
(`claude-fable-5-1`, `gpt-6-astra`) at `medium` effort ([BridgeForTeams.RuntimeModels](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/runtime_models.ex)).
Its Configure form changes the choice. Detect asks the Connector which models the runtime
lists now (`runtime_models`) and offers the catalog models among them.
The [Session kernel](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Query.lean) owns immutable internal Session values and their admission and lifecycle decisions.
The Actor and [PostgreSQL Store](../../systems/apps/salix_agent/lib/salix_agent/internal_session_store/pg.ex) select the current committed revision.
Materialized Session records retain canonical queue work fields in the immutable `accepted_input` tuple.
This value reuses the Session record and queue identity. It adds no ledger, lifecycle owner, or billing authority.
The [materializer](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Query/Materialize.lean) creates it, and model/compaction projections omit it.
[InternalSession](../../systems/apps/salix_agent/lib/salix_agent/internal_session.ex) exposes handles, event application, and consumer queries.
The [Session commands](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Command.lean) own input acceptance and activation across external observations.
The [command driver](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/CommandDriver.lean) retains the native Revision and continuation through staged writes and commit confirmation.
The [batch continuation](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/BatchExecution.lean) retains remaining events and reducer continuation until the captured batch completes.
These are operation-local Session projections, not new identities, durable records, or lifecycle owners.
The [pending revision](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/PendingRevision.lean) retains the baseline, working Session, events, and HWM.
The [native Revision](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Revision.lean) retains an absent or committed baseline and its pending work.
Its planning continuation retains materialization results. Activation reuses the pending revision before commit.
Wait expiry selects its control event inside the kernel.
The [storage delta](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/StorageDelta.lean) describes changes to existing Session facts.
The Store holds one frozen submission: Session address, expected revision, captured owner epoch, storage revision, and delta.
Unknown settlement reuses this submission. It does not rerun events or grant a new owner epoch.
Agent and Session row locks protect the authority check and commit together. Storage errors do not create a committed baseline.
The host Revision exposes read-only projections. It is not a second lifecycle authority.
The [archive publisher](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/ArchivePublication.lean) owns captured-window cuts, adoption, and archive-advance construction.
Its resident cursor is a request-local Session projection. It adds no identity, durable record, or independent lifecycle authority.
The [presentation policy](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Presentation.lean) owns diagnostic disclosure and repair transitions.
The [settlement policy](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Settlement.lean) owns terminal acknowledgments and onboarding completion.
The [restart planner](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Restart.lean) selects recovery batches from external observations.
The [request projection](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Request.lean) owns context selection, source annotations, attachment provenance, runtime-page sizing, and request guidance.
It encodes the final provider request from the resident Session. External attachment reads do not transfer the Session or intermediate message lists.
It is a transient projection of Runtime Session, not another Session identity or durable owner.
The [provider projection](../../systems/native/verified_kernel/runtime/VerifiedKernel/Provider/Dispatch.lean) owns agent-loop wire encoding, response parsing, stream reconstruction, and retry decisions.
Its stream value is request-local and resident in the kernel. It has no durable identity, storage format, or lifecycle outside the network request.
The [HTTP adapter](../../systems/apps/salix_llm/lib/salix_llm/http.ex) performs network I/O and delivers the kernel's callbacks.
The Actor executes requests through its [I/O adapter](../../systems/apps/salix_agent/lib/salix_agent/internal_session/command.ex).
Command continuations and Actor checkpoints are ephemeral values. They create no additional durable identity or lifecycle owner.
The [runtime failure-reply projection](../../systems/apps/salix_agent/lib/salix_agent/guard_failure_reply.ex) retains one notification attempt and its outcome for the current Session activation across compaction. Notification settlement does not complete accepted tool work or provider-card obligations. The Session owns the projection and retires it after acknowledgment. It is not another request or delivery owner.

[PrivateChatStatus](../../systems/apps/salix_im/lib/salix_im/private_chat_status.ex) projects Session Activity to native Telegram, WeChat and Signal typing indicators.
The current Router owner scopes this transient presentation to accepted source messages and the active IM Connect peer.
Provider tickets and refresh timers remain in memory. They add no Message, Task lifecycle, or durable identity.

## 3. Conversations and messages

| Concept | Meaning and boundary |
| --- | --- |
| Assistant Chat / Router Conversation | Comma's fixed Router Conversation for the current Group. Group users share this Conversation. A person's message there that names a model (`[name](comma:model/<id>)`, with `?effort=<effort>` when one is chosen: the composer's @ model) reaches no Participant: it starts a Task with that model and the rest of the words ([ModelMentionTask](../../systems/apps/salix_im/lib/salix_im/model_mention_task.ex)). The person owns that Task and writes its first Message; the uploads the words name are shared into the Task agent's VFS at the same paths, while files on the person's computer stay with their one Message. The Router answers with the Task and is told about it without a round of its own. A message that names, and no model, a person the author may send Task requests to (`[name](comma:request/<grant id>)`: the composer's @ request) also reaches no Participant: the rest of its words go to each person it names as a Task request of their own from the Workspace owner ([RequestMention](../../systems/apps/salix_im/lib/salix_im/request_mention.ex), through `SalixIM.Ports.TaskRequests`), once per Message; its files stay in the chat. |
| Conversation | The aggregate for visible collaboration facts. Its main kinds are user_chat and agent_task. |
| Message | An ordered Conversation fact with an explicit sender, content, reply relationships, and optional attachments. Home can show owner-projected platform content. Views omit delivery control events and provider prompt envelopes. |
| Participant | A Conversation delivery target. An Agent target identifies an Agent and an explicit Session. It is not a Message sender alias. |
| Reply / Thread Reference | Relationships between messages. Internal replies use canonical Message IDs. |
| Delivery | Sending a committed Message to a Participant target. Message persistence and target receipt are different facts. |
| Draft | Transient Participant text. It is not a Message, append intent, delivery receipt, or success signal. |

Owners and entry points:
[Comma.AssistantChats](../../systems/apps/comma_core/lib/comma/assistant_chats.ex),
[RouterConversationInput](../../systems/apps/salix_im/lib/salix_im/router_conversation_input.ex),
[ConversationServer](../../systems/apps/salix_im/lib/salix_im/conversation_server.ex),
[ConversationActor](../../systems/apps/salix_im/lib/salix_im/conversation_actor.ex),
[ConversationMessage](../../systems/apps/salix_im/lib/salix_im/conversation_message.ex),
[Participant owner](../../systems/apps/salix_im/lib/salix_im/conversation_participant_actor.ex).

Conversation mutations pass through ConversationServer to ConversationActor.
Message body locations and `body_updated_at` are PostgreSQL projections of the same Message, not separate lifecycle owners.
[Conversation archival](../../systems/apps/salix_im/lib/salix_im/conversation_archive.ex) uses existing Message revisions and the Conversation revision for immutable addresses.
[Its worker](../../systems/apps/salix_im/lib/salix_im/conversation_archive_worker.ex) schedules bounded owner commands for idle or accumulated hot bodies.
Publication updates locations and evicts matching PostgreSQL bodies together. Body changes return that Message to the same archive path.
Conversation deletion retains current catalog and PostgreSQL cleanup.
Updated owners also remove visible retired or unpublished objects in the owned segments prefix.
Older owners can leave uncataloged objects after deletion, without later automatic cleanup.
Every Agent Participant consumes the Conversation's ordered log, including internal and external Router, Worker, and Meeting runtimes.
The existing Session owns progress by Participant ID and commits progress with pending input.
This progress is Session state, not another queue or domain entity. Session birth owns runtime placement.
Router reset transfers all source positions into the new Session generation.
Conversation owns the deployment start position. Participant activation owns the reassignment start position.
An existing Conversation initializes at its current tail before the first new append or source read.
The owner permits exclusion of predeployment unadmitted inputs. Stored history and already admitted Session work survive.
Reassignment uses the current tail, including reuse of an existing Router, Session, and Participant.
Provider ingress stores checked input facts with the Message. Context-only input retains its no-wake policy and original provenance.
Explicit redelivery is a Message request referencing the original Message, not a separate delivery owner.
See [ConversationSource](../../systems/apps/salix_im/lib/salix_im/conversation_source.ex)
and [ConversationConsumer](../../systems/apps/salix_agent/lib/salix_agent/conversation_consumer.ex).
Provider Participants consume the same Message log and own their completed cursor and exact platform receipts.
Provider commands and status projections are targeted app events, not a second queue or delivery entity.
The Conversation's `provider_status_version` deduplicates status publication and identifies committed recovery work. It is not an authorization value.
The product owner permits disposal of pre-cutover Agent and provider backlog. Stored Messages and admitted Session inputs survive.
The [Conversation recovery index](../../systems/apps/salix_store/lib/salix_store/conversation_log_recovery.ex) coalesces unfinished consumption by Conversation identity.
One PostgreSQL transaction publishes each append with its metadata tail, refs, search target, and recovery target.
Metadata changes also publish their target in the same transaction. Recovery consumes committed facts and retires the exact observed target after consumer progress.
Recovery does not complete prepared S3 publication or repeat a metadata mutation.
Participant filter or binding changes also register recovery. Owner-local membership revisions reject cleanup from a stale observation.
This is a discovery projection, not another Message, delivery queue, or lifecycle owner. Recovery queries only due rows, not the Conversation catalog.
Ordinary Message append does not mutate Participants. Explicit Conversation creation initializes metadata, Participants, and an optional first Message in one transaction. Participant owners retain subsequent lifecycle and delivery mutations.
Visible canonical replies require an explicit provider send operation. Plain model output does not append a Message.

`platform_message` is a presentation value on an existing Message, not another message identity or delivery authority.
It carries the messaging provider, display role, and safe body or attachment label for Home.
Provider input keeps its original Agent target and private prompt. A successful Router send with a receipt identity records a display event with no delivery targets.
The Conversation owner stores the send value. Bounded reads derive the input value from its trusted sender body.
Home readers are every Group user, outside the IFC reader model. Groups with IFC labelling, or an unreadable Group record, present neither value.
WeChat replies reuse Message reply relationships. The owner resolves the checked input through its request identity and stores the parent Message ID.
This display relationship does not change the WeChat request or create a delivery target.
Implementation: [platform projection](../../systems/apps/salix_im/lib/salix_im/platform_message.ex),
[provider dispatch](../../systems/apps/salix_im/lib/salix_im/provider.ex),
[chat projection](../../clients/packages/core/src/chat/model/conversationChannel.ts).

A widget (`dynamic_ui`) is a versioned Message content value backed by existing attachment blobs, not a separate application entity.
Its `version` is the lowest runtime level that shows it. The Agent tool derives it from the card kinds and chart form the widget uses.
A client carries one runtime level. It shows the summary of a widget above that level, so an older client never shows a widget in part.
The [level contract](../../clients/packages/chat-contract/src/dynamic-ui/level.ts) states when a change raises the level.
It renders outside message bubbles and can fill the conversation width.
Its `ui_ref` projects the existing blob UUID rather than introducing another content identity.
The Message owns immutable HTML, JavaScript, initial data, and summary. Existing reply/thread relationships connect new versions.
The device owns temporary UI state, scoped by account, Workspace, and blob identity.
Existing Task and schedule owners retain business lifecycle authority.
A checklist item can carry actions. Like card actions, a click only proposes a request that the user sends; the Router then acts with its own tools, such as calendar, reminders or Routine.
A Worker composes UI content within its existing Task. Router routing and Task ownership stay unchanged.
Implementation: [Agent tool](../../systems/apps/salix_agent/lib/salix_agent/tools/dynamic_ui.ex),
[attachment owner](../../systems/apps/salix_im/lib/salix_im/conversation_attachments.ex),
[client widget](../../clients/packages/app/src/components/chat/dynamic-ui/DynamicUiWidget.tsx).

A question card (`question`) is an Agent Message content value, not an entity, and its answer is an ordinary user Message with a `question_answer` block.
It is not a Capability Request: the Agent's turn ends when it asks, so no tool call waits for the answer, and the transcript keeps both facts.
The Conversation owner admits an answer against the question it replies to. Clients read the card's state from the transcript; nothing stores it.
Implementation: [contract](../../systems/apps/salix_im/lib/salix_im/conversation_question.ex),
[client state](../../clients/packages/core/src/chat/model/questionStates.ts),
[card](../../clients/packages/app/src/components/chat/question/QuestionCard.tsx).

A Mac app card (`mac_app_item`) is an Agent Message content value, not an entity: one item a Mac apps tool made or found (an event, a reminder, a note, a person, a place), copied from the tool result.
The Mac app keeps the item. The card is a snapshot and is not updated when the item changes.
Salix keeps only the known fields, at most five cards, and adds a plain-text fallback block for clients that cannot draw them.
Implementation: [contract](../../systems/apps/salix_im/lib/salix_im/mac_app_item.ex),
[tool result cards](../../clients/apps/electron/src/main/modules/mac-apps/cards.ts),
[card](../../clients/packages/app/src/components/chat/mac-apps/MacAppItemCards.tsx).

A Mini App card (`mini_app`) is an Agent Message content value, not an entity: `{app_id, app_version, name, summary}` of one deployed [Mini App](#mini-app) Version.
The Task's worker Message carries a text block with the same summary, so Router delivery, Task Share and notifications see only the summary.
Clients draw the card with the Version inline and hide the duplicate text.
Implementation: [contract](../../systems/apps/salix_im/lib/salix_im/conversation_message.ex),
[client part](../../clients/packages/core/src/chat/model/conversationChannel.ts),
[card](../../clients/packages/app/src/components/apps/).

### IM question cards

A Slack, Feishu, or Lark send's `question` parameter is a send parameter, not an entity, like the Comma question card above.
It puts one to six options (the recommended one last and preselected) or a text field on the message, with a button that sends the answer.
Anyone in the chat may answer. The first answer enters the Router as that person's message in the card's thread, through the same ingress as what they type there.
The provider receipt keyed by the card's message takes one answer per card; a later press only tells the presser.
The card then shows who answered what. That update is presentation: a failed update leaves buttons whose press the receipt refuses.
Agents cannot send interactive Slack blocks themselves; only the runtime draws the card.
QQ keeps its own buttons (`qq.send_message`), and Telegram keeps `question.request`.
Implementation: [contract](../../systems/apps/salix_im/lib/salix_im/question_card.ex),
[Slack card](../../systems/apps/salix_im/lib/salix_im/provider/slack/question_card.ex),
[ingress](../../systems/apps/salix_im/lib/salix_im/provider_http.ex),
[Lark ingress](../../systems/apps/salix_im/lib/salix_im/lark_inbound.ex).

## 4. Tasks

| Concept | Meaning and boundary |
| --- | --- |
| Agent Task | Durable delegated work represented by an agent_task Conversation. It is not a Runtime Session. |
| Task Lifecycle | The business state owned by Conversation.status. Session termination does not establish Task completion. |
| Human Review | Version-checked acceptance by a human. Router completion after verified delivery is a separate path, not evidence of human acceptance. |
| Task Label / Proposal | A Group's classification catalog and label approval decisions. These are not IFC confidentiality labels. |
| Archive / Restore | Shared Task archive transitions with a saved restore status. Archival is not deletion or an independent running lifecycle. Any ended Task can be archived. Archive clears a Task Schedule binding in the same write; the Schedule answers `inactive` at its next window and is deleted. Restore does not rebind it. |
| Task Share | A public, read-only link to one Task up to a saved Message cutoff. It is Comma product authorization, not a Task fact or a login. |
| Task Request Grant / Task Request | A Workspace owner's permission for one person to ask that Workspace for Tasks, and one such ask waiting for the owner's decision. Neither is a Task, a Membership or a Conversation. See [Task Request](#task-request). |
| Loop Task | A Task for work that repeats or keeps watching something. It is a Task that shows one Background Loop it requested, not another entity: the Loop holds the work's cadence, limits, runs and state. It is not a Task Schedule. |
| Task Panel Dismissal | A User's acknowledgement that clears one settled Task from the chat Task panel on every device. It is not Task lifecycle, Archive, or review acceptance. See [Task Panel Dismissal](#task-panel-dismissal). |

Owners and entry points:
[ConversationActor](../../systems/apps/salix_im/lib/salix_im/conversation_actor.ex),
[Task labels](../../systems/apps/salix_store/lib/salix_store/task_labels.ex),
[TaskArchive](../../systems/apps/salix_im/lib/salix_im/task_archive.ex).

Conversation status remains the sole Task lifecycle authority.
The owning Router may complete a plain one-shot Task after verified delivery with no pending work or human decision.
It completes a [Loop Task](#loop-tasks) the same way when the Loop Task's work is done. A Loop Task's Loop that ends at its run limit or end time completes it too.
Schedule-bound, product-assigned Triage and legacy Workflow Tasks cannot use this completion path.
Human acceptance of a Task without a bound Schedule checks the exact reviewed version before completion.
Scheduled runs cannot complete their parent Task through that acceptance command.

A user can end an in-progress or in-review plain Task or Loop Task by hand as completed or cancelled.
[TaskManualStatus](../../systems/apps/salix_im/lib/salix_im/task_manual_status.ex) checks the exact version in the Conversation owner and records `manual_status_change` on the Conversation.
The owner then appends one runtime system Message to the Router, and one to the Worker on cancellation.
The Worker notice is a soft stop: a running step can finish. Schedule-bound Tasks reject this path.
Triage and legacy Workflow Tasks accept only the review acceptance, `ready_for_review` to `completed`, as the accept command does.
While the Task keeps the manual status, its Router can change the status only in a turn started by a human Message sent after the change.
Any later status change clears `manual_status_change`.
This adds no Task, status or decision entity.

A Task milestone is a `milestone` block on an ordinary Agent Message, not an entity or a Task field.
Existing values cannot carry it: Task status is one lifecycle value, and Session records are disposable runtime history outside the transcript.
An Agent records one when it finishes a key step. Milestones only append, and the Message's time is the step's time.
Clients project them only as the Task's Activity, never in a transcript, grouped under the requests and Loop runs before them and linked to the shown Message with the result.
A milestone-only Message notifies no Participant and does not change Task status.
A station-hosted Task keeps the same value on its station's entries: a `chat_post` post carries the milestones, and a post of milestones alone is a `milestone` entry.
That entry kind is a storage layout for the same Message value, not an entity.
See [Task milestone content](../salix/conversation-owner-actor.md#task-milestone-content).

### Loop Tasks

A Loop Task is an Agent Task for delegated work that repeats or keeps watching something, such as a daily digest or the handling of each new comment on a pull request.
It adds no entity and no status. It is a Task that shows one [Background Loop](#6-files-and-proactive-work) that the Task requested.
The Background Loop is the only record of the work's cadence, limits, runs and state. The Task holds its Messages, its Router and its Worker, and shows the Loop.
Reuse is sufficient: the Task already owns the Messages and the Worker, and the Background Loop already runs unattended programs, wakes a Session, takes events and holds its own lifecycle.
A Loop Task is not a Task Schedule. A `task.create` with both `loop` and `schedule` is refused, and a `task.update` cannot add a Schedule to a Loop Task.
A proactive watch stays a Background Loop that follows one existing matter in Home. It belongs to no Task.

- Identity and scope: the Task's Conversation ID, in the Task's Group. The Background Loop keeps its own ID and records the Task as `task_conversation_id`.
- Owner: the Loop runtime owns the Loop row and every fact on it. The Task's ConversationActor owns the Task status and its Messages. The Task has no `loop` value.
- The request: `cadence` is exactly one of `every_minutes` (5 to 1440), `cron` (five fields) with an IANA `timezone`, or `events`. The optional limits are `max_runs` (1 to 1000), `ends_at` and `until` (a stop condition of at most 500 bytes). Unknown keys are refused. The Loop stores them as `trigger`, `max_runs`, `ends_at` and `stop_condition`.
- The `events` text is the `On updates` trigger rule that clients show. It is a label of 1 to 32 characters (graphemes). It names only the source and the change, such as `New comments on PR #12` or `PR #12 新评论`. The conditions, the people and the work go in the Task content, and the stop condition goes in `until`. The limit applies to new requests.
- A cron cadence without a timezone gets the request's device timezone, else its source timezone. With neither, the create is refused. The Router gives `ends_at` as RFC 3339 with an offset. It must be in the future.

The Router's request writes the Loop `pending` before the new Task and its command exist. A repeated create of an existing Task leaves its Loop alone.
The command carries the request, and the Worker's delivery of it tells the Worker how to run it.
The Worker gives the pending Loop its program with `loop.sdk`, `loop.build` and `loop.create`, with no cadence of its own. The Loop becomes `active`.
A timed program asks `loop.next_run` for each run. An events program waits for its events: a webhook URL, a Composio trigger, or a product event such as `meeting.completed` ("after every meeting").
The Worker reports each run as one result Message and never changes the status.

Under IFC enforcement, the assigned Worker may use its consumed Task command to build in private Agent VFS and create the requested Loop while it has not ended.
Creation records that Agent as creator and retains the Task audience label for later Loop effects and wakes.
The consumed command, Task, Worker and Session must match. This setup delegation grants neither a Drive write nor an unrelated provider effect.
Later Loop effects retain the existing creator authority, provider permissions and IFC audience checks.
An ordinary Task command authorizes the Worker to act for the Task's person (its Comma owner, else `ifc_requester`) under the Task's label, as the Task's sandbox does, in every turn that the creating agent's command or the reminder started, while the Task is active (`SalixIM.TaskExecution`). This covers tools other than IM operations, and `internal.task.create` for a child Task (owner decision, Heyang Zhou, 2026-11-04). Other IM operations still need execution grants, and Composio operations still need a Composio grant. Source labels, destinations and the person's current membership stay the kernel's to check.
The runtime's reminder to a Worker that stopped without a result (`task_worker_nudge`) authorizes that report path too, so the Worker can say what blocked it.
Execution grants (`execution_requests`, `SalixIM.TaskExecution`) act for the person who asked. IM operations come only from the personal Comma owner's request and only in the turn of the Task's first command.
A Composio grant (`composio.execute`: a tool slug, optionally a Group account and pinned arguments) can also come from a person's Slack, Feishu or Lark message. It is usable in every Worker turn that the creating Router's command or the reminder started, while the Task is active. A call must match the slug and every pinned value.
`ifc_requester` records the person whose Task it is. A sandbox station acts for its Comma owner, else for that person (`SalixWeb.StationTasks`). A Task that a Worker or station creates belongs to its parent's person. A Task whose creation audit denied keeps this person and inherits no audience.
The owning Router may use a consumed Worker report or owner-issued Loop notice to report in that Task or set it to `completed`, `escalated` or `failed`, including a same-status retry.
Source labels, current membership, the bound Session and any protected external return target remain checked.

A run is one `agent.notify` wake that reaches the Worker. The owner appends each wake as a private `agent_input` Message in the Task, deduplicated by its source `loop:<id>:<dedup_key>`.
The Loop counts the run on its row (`run_count`, `last_run_at`). The same source counts once.
Lifecycle notices of the Loop (exited, failed, budget) reach the Worker the same way.
A Worker that takes its Task up in a new Session (a switch of the Task's model or place, `SalixIM.TaskRun`) keeps its Loop: the next wake moves the Loop to that Session and wakes the Worker there.
A Loop whose Worker left its Task pauses as `undeliverable`. The Reconciler's minute sweep takes one page of at most 20 such Task Loops (a partial index) and runs again each whose Task has its Worker again, in that Worker's Session. A Loop of an archived Agent stays paused.
A stranded Loop pauses as `undeliverable` at once when its Agent is archived, and only after one node sees the Agent missing for 24 hours when the Agent cannot be read. A rollout or data import can hide an Agent that exists. This pause sends one lifecycle notice.

- The run that reaches `max_runs` is counted and ends the Loop.
- The first wake, `loop.next_run` or load at or after `ends_at` ends the Loop. The Reconciler's minute sweep ends the rest. There is no dedicated deadline timer.
- A Loop that ends on its own keeps `task_settle_pending` until the Task owner takes the end. The Task then becomes `completed`, and the Router gets one notice. The Reconciler retries a page of at most 20 such Loops each minute. A Task that ended or is archived keeps its status.
- A Loop that stops on its own (`exited`, `failed`, `budget`, `quota`, `event_deadline`, `undeliverable`) does not change the Task. Its Worker says why in the Task.

| Task status | Effect on the Task's Loop |
| --- | --- |
| `active`, `escalated` | None. The Loop runs or waits on its own state. |
| `ready_for_review` | Refused while the requested Loop has not ended: one report is one run, not the end of the work. |
| `completed`, `cancelled`, `failed` | The status publication ends the requested Loop with the status as its reason, and deletes a Loop that the Task did not request. |
| `archived` | The status publication ends the requested Loop as `cancelled`. Restoring the Task does not run it again. |

Each status publication of the Task brings its Loop in line with the status. An indexed query by Task finds it. If this fails, the publication keeps its recovery row, and the sweeper tries again.
An ended Loop keeps its row, so the Task still shows it. Deleting a Task deletes its Loops.
While the requested Loop has not ended and is `active`, `TaskWorkerWatch` does not ask the Router to decide the status after a Worker result. A failed read of the Loop counts as active.

A later human request can give an ended Loop Task a new Loop with `task.update`, `loop` and a full `command` for one run.
The owning Router and active Worker must remain in the Task. Archived Tasks must first be restored.
A Loop Task whose Worker runs on a station, made before Loop Tasks ran only inside Salix, gets no new Loop: the Router creates a new Loop Task.
The server deletes the ended Loop and writes the new one `pending`, with a new ID and no runs. It then sets the Task active and appends the command.
A repeated request finds the new Loop pending and keeps it. The old program's ID is gone, so nothing it sends reaches the Task.

A Loop Task runs inside Salix. Its Worker creates the Loop with `loop.build` and `loop.create`, which need a Worker Session inside Salix. A station's Session, the Group Cloud VM's too, has no Salix tools, so its Loop would stay `pending`.
A `task.create` with `loop` refuses a station or the Group Cloud VM, as an explicit `runs_on` or as the Worker's station binding, and a model of kind runtime. The Group's default place does not apply to a Loop Task.
The Worker can still run commands on the Cloud VM with `env.exec` where it is not retired; where it is retired, the Loop's Worker creates sandbox Tasks for a run that needs a machine (`im_api.internal.task.create` on its allowlist: the conversation the Loop Task came from is the new Task's parent, the Loop Task its origin, the Group's Router its delegator; the Group's live-sandbox limit and credits bound how many; [agent runtime](../agent-runtime.md#where-a-task-runs)). One-shot Tasks keep the existing placement rules ([SalixIM.TaskPlacement](../../systems/apps/salix_im/lib/salix_im/task_placement.ex)).

Comma projects `loop` only for Tasks with a requested Loop: on list pages, `task_summaries`, pinned Tasks, the pin response and the single-Task read.
The Task copies that the status, review, edit, archive and activity responses return carry it too. The preview has none, and no public field is named `schedule`.

- The Loop row decides `state`: `pending`; `active`; `paused` with its pause reason (`budget`, `exited`, `quota` and `undeliverable`; a user or archive pause has no reason); `paused` with reason `failed` for a failed Loop; or `ended` with `reason` from `ended_reason`.
- The fields are `cadence`, `max_runs`, `ends_at`, `until`, `started_at`, `wake_count` (the run count) and `last_wake_at`. `next_run_at` is present only for an active Loop with a timed cadence. `ended_at` is present only when ended.
- Comma reads the Loops of a response's Tasks with one indexed read per 50 Tasks. A failed read fails the response.
- The projection never shows the Loop ID, config, program path, webhook or failure text.

Each Loop has a trigger type: `Scheduled`, `On updates`, or `Other trigger` for a cadence that the client cannot read. An ended Loop keeps its trigger type.
Desktop and iOS show that type on the Task card chip, the Properties heading, the accessible names and the Loop type filters.

Desktop Properties, the desktop hover card and the iOS details card show the same Loop details below the type:

- An active Loop shows only its trigger rule, or `Running` if the client cannot read the rule.
- A pending Loop shows its trigger rule and `Setting up`.
- A paused Loop shows its trigger rule and the paused state with its reason (`Stopped` for a Loop that stopped on an error).
- An ended Loop shows only `Ended`.
- A rule that the client cannot read does not show. A cron rule shows its time zone only when the UTC offset of that zone is not the reader's offset.

A paused Loop does not change its Task's status, so the Task stays in progress while nothing runs.
On desktop, every place that shows such a Task as running shows the Loop's state instead of the spinner and `In progress`: the Task card, the chat's Tasks panel, the Tasks list row, the Task header and the Task's tab.
A Loop that stopped on an error (`failed`, `exited`, `undeliverable`) shows the error glyph in the error colour and `Stopped` with its reason. Any other paused Loop shows the pause glyph in the warning colour and `Paused` with its reason. Properties and the hover card use the same glyphs.

The clients do not show the next run, last run, run count, end time or stop condition of a Loop, including hover and accessibility text.
The trigger rule filter excludes ended Loops.
Reopening the Task alone does not restore the details of an ended Loop. A new Loop supplies its own details.

The Router's `internal.task.list` carries a compact `loop` from the Task's Loop: `cadence`, `status`, `runs`, the limits, `last_run_at` and `ended`. The `task.create` and restart results carry the same from the request, with `status` `pending`. Only an `active` Loop runs: `pending` means the Worker has not created it yet.
The Router recognizes Loop requests as [Task delegation](PRODUCT_MODEL.md#task-delegation) describes.

Implementation:
[TaskLoop](../../systems/apps/salix_im/lib/salix_im/task_loop.ex),
[ConversationActor](../../systems/apps/salix_im/lib/salix_im/conversation_actor.ex),
[Task Loop port](../../systems/apps/salix_im/lib/salix_im/ports/task_loops.ex),
[Background Loops](../../systems/apps/salix_agent/lib/salix_agent/loops.ex),
[Task owner port](../../systems/apps/salix_agent/lib/salix_agent/loops/task_owner.ex),
[Task owner binding](../../systems/apps/salix_web/lib/salix/bindings/task_loop_owner.ex),
[Comma projection](../../systems/apps/comma_core/lib/comma/conversations.ex),
[placement](../../systems/apps/salix_web/lib/salix/bindings/agent_conversations.ex),
[Router policy](../../systems/apps/salix_agent/lib/salix_agent/tool_policy.ex),
[tests](../../systems/apps/salix_im/test/task_loop_test.exs),
[end-to-end tests](../../systems/apps/salix_cluster/test/loop_tasks_test.exs).

### Task Share

A Workspace owner can publish one `agent_task` Conversation at a public URL, `/s/<token>` on the Comma Web origin.
The link shows the visible Messages and lets a reader download the files that Agents sent in the Task.

Reuse is insufficient. An Auth Session is a login for a known User with a short expiry. A share reader has no User, and the link lasts until revocation.
A Participant is a delivery target, not a read audience. Archive is Task lifecycle state. A Salix Site serves Agent VFS files without Conversation authorization.
Conversation metadata cannot hold the link: the public lookup needs a unique token index, and the link must not pass through ConversationActor.

- Identity: a row ID and a unique 32-byte random token. The token is the only public authority.
- Scope: one `agent_task` Conversation in the Workspace's current Group. At most one active share exists per Task.
- Owner: [Comma.TaskShares](../../systems/apps/comma_core/lib/comma/task_shares.ex), table `comma_task_shares` in Comma PostgreSQL.
- Lifecycle: active, then revoked. Update moves the cutoff and keeps the token. Reset revokes the token and issues a new one with the same cutoff. Workspace or creator deletion removes the row. Task archive does not revoke it.
- Relationships: it references the Workspace, Group, Conversation, and creating User. It holds no Message or blob copy.

The share stores `through_seq`, the Conversation's Message tail when the owner creates or updates it.
Readers see only Messages at or before that sequence. Later follow-ups stay private until the owner updates the link.

The canonical Salix log stays the only history. The `snapshot` column is a disposable projection that Update rebuilds.
It holds the public Message count and an artifact manifest of at most 500 entries. Its scan reads at most 5,000 Messages in pages of 1,000.
Downloads do not trust the manifest. They reread one canonical Message by sequence.

Every public read resolves the token, then checks that the creator still owns the ready Workspace of that Group.
It also checks that the Conversation still resolves as an `agent_task`. Any failed check returns the same `404`.

A Task a station hosts (`station:<station_id>:<thread>`) has no Salix log. Its chat is its station's, read over the station's Connector as the Router reads it (`task.read`), and the Group's Task index must hold it.
Its link opens while the station is connected; otherwise a read fails with `503`. The station gives its Messages' words alone, so such a share has no artifacts.
Its `snapshot` also keeps the Task's title, which the owner's list shows while the station is offline.

The public projection is an allowlist. It keeps `seq`, role, creation time, and content blocks.
It drops system rows, internal deliveries, app events, and Comma context Messages.
It removes private `comma:` fences, text after the protocol marker, and a user's workspace upload list.
These markers apply to the whole Message, in block order. A fence or marker in one block also hides the text of later blocks. Attachment blocks keep their original index.
It returns no user, Agent, Participant, Group, Workspace, Conversation, or Message ID, and no VFS path or blob ref.

Artifacts are downloadable `file` and `image` blocks of Agent Messages. A widget shows only its summary. A `conversation_ref` block, a `[title](comma:task/<id>)` mention, and a bare `comma:task/<id>` all become an unlabeled Task reference.

[Public endpoints](../../systems/apps/comma_web/lib/comma_web/task_share_endpoints.ex) under `/v1/comma/public/shares/` read no Cookie or bearer credential.
A Redis token bucket limits each peer and each link. If the limiter cannot decide, the request fails with `503`.
Responses send `no-store`, `no-referrer`, and `noindex`. Downloads also send `attachment`, `nosniff`, and `sandbox`.

The owner API under `/v1/comma/groups/:group_id/conversations/:conversation_id/share` needs a full Workspace owner session.
The share is a human disclosure by an authorized reader. The IFC model does not govern it.

`GET /v1/comma/groups/:group_id/task-shares` lists the active shares of the Group, most recently shared first.
It needs the same owner session. The query reads the share rows of one Workspace through its index.
A page holds at most 50 shares and resolves their Task summaries through `task_summaries`, one Task read per share. A share whose Task no longer resolves leaves the page.
Settings > Shared tasks reads this list and stops a link through the owner API.

Implementation: [Task Share page](../../clients/packages/app/src/components/share/PublicTaskShareApp.tsx),
[Share dialog](../../clients/packages/app/src/components/tasks/TaskShareButton.tsx),
[Shared tasks settings](../../clients/packages/app/src/components/tasks/useSharedTasksCategory.tsx),
[client core requests](../../clients/packages/core/src/task-shares.ts).

### Task Request

A person can ask another person's Workspace for a Task. The request runs nothing until the Workspace owner accepts it; then it becomes an ordinary Task of that Workspace.

Reuse is insufficient. A Membership gives authority in the Workspace: its chats, Tasks and settings. A sender gets none of it. A Task cannot wait for a decision before it exists, and a Task Share is a read link with no sender. A Router chat Message (the Linear path) lets an Agent decide; here only the owner decides.

- Identity: a grant has a `trg_` row ID and, while it is an invite, a unique 32-byte random token. A request has a `trq_` row ID and is unique per sender and `client_request_id`.
- Scope: a grant names one `standard` Workspace and, once accepted, one User. A request names its grant, the Workspace and the sender. A request a person sends to their own Workspace names no grant (see below).
- Owner: [Comma.TaskRequests](../../systems/apps/comma_core/lib/comma/task_requests.ex), tables `comma_task_request_grants` and `comma_task_requests` in Comma PostgreSQL.
- Grant lifecycle: `invited` (seven days), `active` once a signed-in person other than the owner accepts the invite, then `revoked`. Accepting clears the token, so an invite works once. A second grant accepted for the same person and Workspace revokes the first. Revoking declines the grant's pending requests.
- Request lifecycle: `pending`, then `accepted`, `declined` or `withdrawn`. These four race for one decision: each leaves `pending` only if the request is still there. `accepted` is the decision, taken before the Task or Router Message is made; accepting again finishes what it started (both are idempotent by `client_request_id`), and a start that fails returns the request to `pending`, or declines it when its grant was revoked meanwhile. A pending request older than seven days reads as `expired` and can no longer be accepted; nothing rewrites it.
- Relationships: an accepted request names its Task (`group_id`, `task_id`). The Task's `source_refs.task_request` and `metadata.task_request` name the request and the sender (User id and name); the Task summary shows it as `origin: task_request`, `requested_by` (their name) and `requested_by_id` (their User id). Account deletion removes the grants the User created or held and the requests they sent.

Authority: a grant needs its Workspace owner's act: creating an invite, or accepting one that grants back. The owner creates an invite and gives its link (`/#/settings?category=task-requests&invite=<token>` on the Comma Web origin, which opens Settings › Task requests with the token filled in) to the person. Without an active grant a send answers `404` and the owner sees nothing.
Before accepting, the person reads whose invite it is and what accepting gives the inviter (`GET /v1/comma/task-request-invites/<token>?workspace_id=`, answering `back`: the Workspace and mode, or null). One invite connects both ways: the person accepts it naming a Workspace (`workspace_id`), and when they own it, accepting also grants the inviter that Workspace in `review` mode with the default limits, so either can then send the other requests. A grant the inviter already holds there keeps its settings; a Workspace the person cannot grant from, or one at its grant limit, grants nothing back (the answer's `reciprocal`). Each side is an ordinary grant that its own Workspace's owner changes or revokes alone.
The owner can also give an invite to someone nearby (Settings › Task requests › Add someone nearby): Main scans AirDrop for Comma receivers (OpenDropKit `receive --model Comma`) and sends the picked one a new invite link as an AirDrop link. On the other Mac, an offer of exactly that one link is held, not saved to a chat: the connect card reads and accepts the invite in the core, then answers the offer, so the sender's send succeeds only once the invite is accepted. On any desktop the same happens on the local network: Main advertises `_comma-nearby._tcp` under the AirDrop name while the person is shown nearby, browses for it, and posts the link to the receiver's HTTP endpoint, whose response is the answer; a receiver both ways find is listed once, by AirDrop, matched by the AirDrop receiver id its advertisement carries (OpenDropKit's `listening` `service`), never by name. Either way carries the link and nothing else; the token, read by the server, says whose invite it is, not the advertised name ([NearbyService](../../clients/apps/electron/src/main/modules/airdrop/nearby.ts), [LanNearby](../../clients/apps/electron/src/main/modules/airdrop/lan-nearby.ts), `nearby.*` native leaves). This adds no entity.
Each grant has a mode, a daily limit (1-200 sends in a sliding 24 hours) and a pending limit (1-50). Only the owner's full session reads, changes or decides; an Agent cannot accept a request.

Accepting creates the Task through `SalixIM.TaskPlacement.create_task_conversation/4`, delegated by the Group's Router, owned by the Workspace owner, with the owner as the first Message's author. The owner can edit the title and words and choose a place and model, checked as any Task's are. The Task's `client_request_id` is `comma-task-request:<id>`, so accepting twice answers the same Task. The owner pays for it as for any of their Tasks.
The owner can instead send the request to their Router chat (`to: router`): it becomes the owner's own Message there, with the same `client_request_id`, billed as any Message they write, and the Router decides what to do. The request records how it was accepted (`accepted_as`: `task` or `router`).
A grant in `auto_accept` mode accepts each request when it arrives, at the Workspace's default place and model. If that place is a station (the owner's own machine), the request stays pending for the owner instead.

Clients call it a Request. Waiting requests are Inbox notifications among the Tasks, by when they came, with the attention dot until answered. A Request filter of their own narrows the Inbox by person: each person who asked something of the person (their waiting requests and the Tasks made of them), each person the person sent requests to, or neither; the Tasks page's narrows by the person each Task's request came from, or to Tasks from no request. People are told apart by their User id. A row or card names the person by avatar and name. A request has no platform or Loop, so those filters leave it out. Clients read them when the Inbox opens, when the window regains focus, and when the owner's task list stream, opened with `?with=task_requests`, says `task_requests_invalidated`: a request to the Workspace came or was withdrawn (a Phoenix PubSub broadcast per Workspace). A request that comes while a window is open raises a toast there with the sender's avatar and name, the request's words and View, which opens it in the Inbox. Opening one shows it in the detail pane as the Task it would become: the Task's header, a placeholder conversation behind a blur, and the New task window as a card where the Task's message box would be. There the owner edits the words, chooses where and on what the Task runs (Comma's cloud on a catalog model, a coding sandbox with a repository, or a station), sends it to the Router or declines it. Making the Task opens its conversation in the same pane. The window's choice goes to the server as `runs_on`, `model`, `repo` and `account_id`, checked as any Task's are.

A Workspace owner can also name the recipient in their Router chat's @ menu (see Assistant Chat / Router Conversation). A sender writes a request in the New task window: where they hold an active grant, its title switches to New request, which names the recipient instead of a place and model and takes no files. Settings › Task requests opens the same window for one recipient.

The sender follows each request as the Task they asked for: a receipt kept with the request (`task_status`, `task_reply`, `task_updated_at`), not a Conversation of their own. Salix's Task status observer ([CommaWeb.TaskStatusObserver](../../systems/apps/comma_web/lib/comma_web/task_status_observer.ex)) queues one check per published status of a Task made from a request ([CommaWeb.TaskRequestReceipts](../../systems/apps/comma_web/lib/comma_web/task_request_receipts.ex)); the check keeps the Task's status. Once the Task waits for review, needs input or ended, the check wakes the owner's Router with the Task's latest reply as another Agent's words (event `task_request_report`, source id `task-request-report:<id>:<status>`). The Router decides what the sender gets and sends it with `task_request.report`. Only that report goes back, once: `task_reply` and `reported_at` hold it, and the same transaction queues telling it. A different report later is refused. A request sent to the Router names itself in its Message. The Router's Task names it (`task_request_id` of `internal.task.create`, checked at creation and kept in the Task's source refs) and reports the same way; another Task is refused. A report needs a finished Task; the Router's own replies stay in its chat. The owner's decision (including declining by revoking the grant, and an acceptance undone when its Task could not be made) and each kept change reach the sender's task list stream (`task_requests_invalidated`). The sender's Inbox shows each request they sent and did not withdraw among the Tasks, with what came of it, and a result raises a toast. A request row's menu withdraws a sent request while it waits and declines a waiting one. A decided sent request can only be hidden, with an Inbox deleted mark on this device, until its decision or its Task's status changes: the Task is the owner's, and the sender cannot stop it. A request names the sender's Group it was written in (`sender_group_id`: the Router chat it was named in, or the Workspace of the New task window); that Router is told a new result without a round of its own: that there is one and the Task's status, never the reply's words, which are another person's Agent's and could pass in the Router's input for the person's own. The kept reply stays with the request after the Task is deleted. The sender reads nothing else of the Task.

A Router can send a request for the person it serves (`task_request.targets`, `task_request.send`, [SalixAgent.Tools.TaskRequests](../../systems/apps/salix_agent/lib/salix_agent/tools/task_requests.ex)): the requester is the sender of the message the turn answers, from its server-sealed principal, never from the model. A Comma user is the requester only in their own Workspace's Group. A chat app's user (a Slack user of one connect, as in a Comma for Teams swarm) is the Comma account linked to them.
Such a chat user's targets also hold their own `standard` Workspaces, by `workspace_id`: the Router is how they reach their own Comma from the chat. Owning the Workspace is the authority, so the request names no grant. It waits in their Inbox like a `review` request, unless the owner set their own requests to accept automatically (the Workspace's `own_request_mode`, `review` by default, Settings › Task requests under the linked chat accounts; then it is accepted as an `auto_accept` grant's request is, a station place still waiting). It counts against the default limits per Workspace and is not among their sent requests.
A request a chat user sends, to their own Workspace or through a grant, names the chat message it was asked in (`source`, a value on the request: the Router's Group, the provider, the message id and the provider's reply coordinates such as Slack's channel and thread, never who sent it). When the owner's Router reports a result, a queued job wakes that Router with a product-authored input (`provider_system`, event `task_request_result`, source id `task-request-result:<id>`, so a retry is the same input) at those coordinates: the request, the Task's status, the report quoted as another Agent's words, and, for a request to their own Workspace, the Task's link. The Router replies there as it answers any message. The chat user is the sender, who reads that reply in their Inbox anyway; the person who asked in the chat chose to ask there.

A **Provider User Link** (`comma_provider_user_links`, [Comma.ProviderUserLinks](../../systems/apps/comma_core/lib/comma/provider_user_links.ex)) names that account. Reuse is insufficient: a Login Identity signs a person in, and a channel link (Telegram, WeChat) binds one Workspace's own connection; this binds a chat user of any connect to a Comma User. Identity: a `pul_` row ID, unique while active per (connect, chat user). It keeps which chat account it is as the chat app says it (`subject_name`, `subject_email`, `subject_workspace`: a Slack, Lark or Feishu user's name, email and their Slack workspace's or tenant's name, else the Comma for Teams organization of the connect) and through which bot (`subject_bot`), which tell apart a person's links to several swarms on one chat app ([SalixIM.ProviderAccounts](../../systems/apps/salix_im/lib/salix_im/provider_accounts.ex)), read when the Router starts the link, or the next time it resolves one made before; Settings shows them with the link. Lifecycle: `pending` with a one-hour 32-byte token, made when a Router needs the account; `active` once a person opens the posted link signed in and confirms (`/#/settings?category=task-requests&link=<token>`), which ends any earlier link of that chat user; removed by its User in Settings or by account deletion. Until linked, the tool call answers `link_required` with the link for the Router to post and stays open as an `account_link` capability request recorded on the link (`waiting_requests`: every conversation that asked). Linking completes them all ([SalixAgent.CapabilityRequests](../../systems/apps/salix_agent/lib/salix_agent/capability_requests.ex) `complete_account_link/3`), and a wait recorded after the link completed ends at once, so each Router goes on with the request without the person asking again; an unlinked request expires with the link.

Implementation: [endpoints](../../systems/apps/comma_web/lib/comma_web/task_request_endpoints.ex),
[Task create](../../systems/apps/comma_web/lib/comma_web/salix_client.ex) (`create_requested_task/3`),
[client core requests](../../clients/packages/core/src/task-requests.ts),
[Task requests settings](../../clients/packages/app/src/components/tasks/useTaskRequestsCategory.tsx),
[Inbox requests](../../clients/packages/app/src/components/inbox/TaskRequestInbox.tsx).

### Task Panel Dismissal

The chat Task panel docks the Tasks a chat created. A running Task always shows.
A done, cancelled, or archived Task leaves the panel without a dismissal, and shows again when it runs again.
A User clears one that waits for review or input, or that failed, with Dismiss, or with Reveal in Chat. The dismissal records the run that the User acknowledged: the Task's `run_started_at`, or 0 for a Task from before Salix kept it.
Salix sets `run_started_at` on the Conversation when a Task's status becomes `active`, at creation or later. It is a value, not another entity.
Every device hides the row until the Task's latest run started after the acknowledged one. A Task that runs again shows again, and no device has to see it run. A Router dismisses its own completed or cancelled non-Loop Task for the Task's `owner_user_id` through `im_api.internal.task.dismiss`; a Task without one owner is refused. A rename, a label, or a review acceptance starts no run, so it does not bring the row back.

Reuse is insufficient. Archive is shared Task lifecycle state for the whole Group, and this choice belongs to one User.
The client core's device-local marks are lost on another device, another profile, or a reinstall.
Task review acceptance changes Task status. A dismissal changes only what one User's panel shows.

- Identity: the User and the Task (`task_id`). The Task id is an opaque value. A dismissal reads no Task and grants nothing.
- Scope: one User, across Workspaces and devices.
- Owner: [Comma.TaskPanelDismissals](../../systems/apps/comma_core/lib/comma/task_panel_dismissals.ex), table `comma_task_panel_dismissals` in Comma PostgreSQL.
- Lifecycle: Dismiss creates the row or moves `dismissed_at` to now. The `revision` never moves back. The Task's next run ends its effect, and the row stays until it is among the oldest. Each User keeps the 300 most recently dismissed rows. User deletion removes the rows.
- Relationships: it references the User. It holds no Task, Workspace, or Message copy.

In Telegram, Clear on a failed, completed, or cancelled Task card makes the same dismissal for the bound owner, at the Task's current run. [TelegramTaskCards](../../systems/apps/comma_web/lib/comma_web/telegram_task_cards.ex) re-resolves the sender for each click, as it does for review acceptance. `/tasks` leaves out the owner's dismissed settled Tasks by the same rule. The Mini App stays read-only and its All tasks list still shows every Task.

`GET` and `POST` on `/v1/comma/me/task-panel-dismissals` need a full session. A write takes 1 to 300 `{task_id, revision}` pairs, with ids of at most 256 bytes. Each answer lists the User's rows, most recently dismissed first.

The [client core](../../clients/packages/core/src/task-panel-dismissals.ts) keeps a copy in the account database with the other marks, so the panel shows at once and works offline.
It reads the server's list when the panel's marks topic goes live, and again when the User comes back to the window, at most once per 30 seconds.
It sends each dismissal in the background. A dismissal made while a read is out is laid over its answer. A failed send is sent again on the next dismissal or read.
The first read of an account sends the dismissals that the device kept before the server kept them. Ones kept before dismissals recorded a run go at 0, never at the device's time, so no device clock hides a later run. The account remembers this handover only after the server takes them.

### Cloud browser resource of a Runtime Session

Browser Run reuses Runtime Session identity. The `(agent_id, session_id)` key owns one provider binding, not another Session or Conversation.
[BrowserBindings](../../systems/apps/salix_store/lib/salix_store/browser_bindings.ex) owns durable command admission and control state.
[Browser](../../systems/apps/salix_agent/lib/salix_agent/browser.ex) creates and closes the remote resource.
Cloudflare owns the live browser and inactivity expiry. Local driver processes own CDP connections only.
[BrowserStorage](../../systems/apps/salix_store/lib/salix_store/browser_storage.ex) owns encrypted cookies and first-party local storage under the existing `(tenant_id, group_id)` Group identity.
This is Group-owned credential data, not another profile identity or disposable projection. Router and Worker Runtime Sessions share it across Tasks.
Group admission permits one active browser until confirmed closure or bounded lost-create recovery. Driver loss, command inactivity, or lease expiry cannot transfer ownership.
Background saves do not claim command admission. Writes compare provider identity, pending state, and command/save times to reject stale results.
Creation restores saved storage before publishing readiness. A 1 MiB Group budget evicts least recently used cookies or whole origins.
Admission recovers known provider bindings, including the caller’s own, only after a scoped lookup confirms expiry. Lookup failure retains ownership.
Lost creates without a provider ID permit recovery after the configured idle timeout plus 60 seconds, under the row lock.
Recovery rejects changed bindings and fences late create results.
Self-open preserves live browsers/tabs and restores saved storage after confirmed expiry. Live browsers remain owned during task pauses and human handoff until provider expiry.
Passive streams/checkpoints cannot renew or restart the ten-minute idle driver. Explicit commands can.
An active human-control lease retains the driver until lease expiry. Pending handoff alone does not.
Idle expiry checks one binding, then rechecks at lease expiry while control remains active.
Close retains saved data. An authenticated human can clear it after provider deletion or from Settings when no browser is active.
Group deletion holds admission while cleanup runs. It removes saved storage and records the tombstone only after successful cleanup.
Same-identity provider migration retains storage. Group replacement requires an explicit retained-data decision, not an implicit profile merge.
The binding retains uncertainty across process loss and permits explicit close before reuse. Human disconnect never transfers control to the agent.
[BrowserSettings](../../systems/apps/salix_store/lib/salix_store/browser_settings.ex) extends provider-credential configuration with a global default and tenant override.
It does not create another tenant or credential identity. See [storage and recovery](../storage-search.md#browser-run-settings-and-runtime-resources).

## 5. Capabilities, integrations, and information authority

| Concept | Meaning and boundary |
| --- | --- |
| Capability Request | An existing durable permission, location, OAuth, plugin install, runtime-auth, or IFC decision request. Its owner stores expiry and the winning result; the Session separately owns execution and result publication. A request an Agent raises in a Comma Conversation records that Conversation (`surface_kind` `conversation`); Comma clients show it there as a request card, a projection of the request and not an entity ([routes](../../systems/apps/comma_web/lib/comma_web/agent_request_endpoints.ex), [card](../../clients/packages/app/src/components/chat/requests/AgentRequestCard.tsx)). An `oauth_authorization` request may carry `input`, what the person fills in on its card first: a `secret`, or a Workspace's own Lark or Feishu `app` (Comma cards and Workspace owners only). The value is never logged, kept with the request, or returned. A sandbox Worker's request has its card in the Task and its call waits for the answer. A CLI login in a sandbox (the station's `login` tool) shows the same card with provider `cli`, its `input` a device code, a page, or a code to paste back; a finished login's files are kept as the Task person's secret credential `cli-login-<program>` and restored on their next login, outside tool calls. |
| Tool / Provider Operation | An operation available to an Agent. An invocation is not a durable capability definition. |
| Skill | Instructions and resources projected into runtime files. Packaged built-ins belong to the running node. Stored user skills overlay them. Regular skills preload catalog entries. Miniskills use per-message selection. |
| Plugin Definition | A capability package with metadata and references. Referenced domains still own their resources. |
| Group Enablement | The Plugin enablement choice for a Group. This does not establish OAuth, MCP, or device readiness. |
| Plugin Installation | Comma's explicit installation evidence. It is separate from a default-enabled runtime capability. |
| IM Connect | A messaging integration connection and its provider context. It owns App-scoped Slack command aliases and synchronization state through [SlackCommands](../../systems/apps/salix_im/lib/salix_im/slack_commands.ex). A Group's single `voice` connect lists verified caller numbers and receives Router replies for every [Voice Call](#voice-call). A Group's single `signal` connect lists the Signal peers (people and Signal groups) bound to it on a [Signal Account](#signal-account). A Feishu or Lark connect keeps one stored copy of its app's Contacts data range ([Feishu](../../systems/apps/salix_im/lib/salix_im/provider/feishu/directory_snapshot.ex), [Lark](../../systems/apps/salix_im/lib/salix_im/provider/lark/directory_snapshot.ex)): a disposable projection of the provider's directory, not a person entity. A background sync after the connect is made or its app changes, and after a lookup finds the copy missing, unfinished or a day old, replaces its people wholesale once it has read the whole range. `*.lookup_users` and the Data policy person search match a name there first and walk the live directory on a miss. Retiring the connect deletes the copy. It is not the device Connector process. |
| OAuth Binding / MCP Connection | Authorization and service access relationships. Plugin enablement does not own their lifecycles. A connection an agent requests is personal: its `owner` names the person who asked, and `credential_env` resolves it only for work done for them. Salix's own labelled reads, such as a Lark connect reading as a signed-in member, are not limited this way. A connection with no `owner` is the Group's (`shared: true`, plugin setup, and every connection made before owners). A connection is one of three kinds behind the same `credential_env` reference: a provider sign-in (a built-in adapter, or `custom.<key>`, a Workspace's own standard OAuth provider, with browser or device flow), a `secret` a person typed into Salix's form, or a remote MCP connection. |
| Principal | The identity that requests a read or effect. Schedule and Group API-key principals, inbound or voice, act with their creator's authority. A schedule or Loop made without an allow verdict (check `off`, or denied under `audit`) records the person who asked as its creator, with no label, so its prompt reads as `agent_private`. A key an Agent mints is created as `system`, which holds no membership. An Agent cannot mint a voice key. |
| IFC Label / Policy | Audience restrictions and information-flow rules. These are not Task labels or product membership roles. |
| API Key / Provider Credential | Credentials for inbound authority or provider access. An Agent Group API Key has a `kind`: `inbound` (`salix_gk_`) opens the Router post-message API and Loop events, and `voice` (`salix_vk_`) opens only voice readiness and sessions. [GroupApiKeys](../../systems/apps/salix_web/lib/salix/control/group_api_keys.ex) owns both kinds. They are not product users, templates, or billing identities. |
| Mini App | A Workspace's sandboxed web application that a Coding Task builds and Comma clients run. See [Mini App](#mini-app). |
| Mini App Version | One immutable deploy of a Mini App: a frontend bundle, a source archive, and an optional backend script. |
| Mini App Link / Install | A Mini App's sharing token, and another Workspace's relationship to a shared Mini App with its capability grants. |

Owners and entry points:
[CapabilityRequests](../../systems/apps/salix_agent/lib/salix_agent/capability_requests.ex),
[Provider manuals](../../systems/apps/salix_im/lib/salix_im/provider/manuals.ex),
[SkillCatalog](../../systems/apps/salix_agent/lib/salix_agent/skill_catalog.ex),
[BuiltinSkills](../../systems/apps/salix_agent/lib/salix_agent/builtin_skills.ex),
[SkillProjection](../../systems/apps/salix_agent/lib/salix_agent/skill_projection.ex),
[Plugin control](../../systems/apps/salix_web/lib/salix/control/plugins.ex),
[Comma.Plugins](../../systems/apps/comma_core/lib/comma/plugins.ex),
[Installation records](../../systems/apps/comma_core/lib/comma/plugin_installations.ex),
[IFC Principal](../../systems/apps/salix_ifc/lib/salix_ifc/principal.ex),
[IFC Label](../../systems/apps/salix_ifc/lib/salix_ifc/label.ex),
[IFC Policy](../../systems/apps/salix_ifc/lib/salix_ifc/policy.ex).
See [integration contracts](../tools-integrations.md), [messaging and voice contracts](../messaging-voice.md) and [identity contracts](../identity-security.md) for connection and credential owners.

Built-in Skill definitions and resources come only from the running release's skills directory.
The node caches their metadata and reads their files locally. It does not persist or reconcile built-ins.
The runtime projection overlays stored global imports, Tenant, Group, and Agent skills in their existing precedence order.
It ignores previously stored global entries with `origin: builtin`, without deleting their records or blobs.
Copying a built-in creates durable blobs and a user-owned skill. Copies remain available after the source leaves a later release.
Plugin visibility, write authorization, and user-skill ownership remain unchanged. Built-ins follow each node's image during a rolling deployment.

### X plugin credentials

The X plugin reuses Plugin Definition, Plugin Installation, and the Group-owned MCP binding. It adds no credential entity or billing identity.
BFT and Salix requests first use the Group's managed X OAuth Binding. Alias `x` takes priority. Otherwise, the Group must have exactly one X account.
Multiple accounts without alias `x` require an explicit choice. The existing OAuth owner refreshes expiring tokens.
Only confirmed absence selects the optional App-only Bearer Token in the MCP binding's `config_values.X_BEARER_TOKEN`.
Disabled, revoked, incomplete, or unreadable OAuth connections fail closed. They never select the App-only Token.
Public responses omit the token. Models receive tool schemas and results, not the credential. The server injects the token into X requests.
App-only credentials permit only named public reads. OAuth exposes the official MCP tools, including writes, within the granted account scopes.
Dispatch applies the App-only restriction with the credential resolved for that request. Cached discovery grants no write authority.
X OAuth binding creation, replacement, alias or enabled changes, and deletion trigger background MCP discovery refresh.
The worker reads 64 Group objects per page and refreshes one enabled X binding at a time. It skips Comma App-only bindings.
OAuth completion does not wait for MCP discovery. Until refresh completes, Agents retain the previous tool catalog. Failed refresh requires MCP reconnect.
X enforces OAuth scopes. Remote annotations do not grant App-only write access.
X bills the developer app that issued the selected credential. Tenant app overrides and platform defaults retain their existing scope.
Setup performs MCP initialization and discovery, not a paid content query. Connection success does not prove endpoint permissions or available credit.
An existing OAuth account needs no new login. Setup needs no device, subscription change, or X write operation.
BFT and Salix App-only Token updates retain OAuth priority. Removing that token keeps the MCP binding and OAuth account.
Uninstall deletes the declared MCP binding and its App-only Token. It preserves the independently authorized OAuth account and X app.
Installation and connection readiness remain separate facts. A later credential failure does not erase installation evidence.
BFT Agent Swarm admins connect, replace, and disconnect the same Group-owned credential from the swarm plugin page.
BFT checks project permissions before credential writes. Enabling the plugin remains separate from connecting its credential.

The client core owns plugin credential submission. A window owns the password field.
Tokens pass only through the transient install call and API request. Topics, notices, and SQLite contain no submitted token.
The existing session lease fences the request. Sign-out clears the open credential form.
Comma App supports only App-only Bearer Tokens for X. Its setup always asks for a token, even with an existing OAuth account.
Comma stores `config_values.X_AUTH_MODE = app_only` with that token in the existing MCP binding.
This credential selection prevents OAuth lookup and refresh for that binding. It is not a new credential identity.
Reads use the saved token. Writes remain blocked. Token removal retains the selection and cannot activate an unrelated OAuth account.
The selection alone does not count as a configured credential. Uninstall preserves the independent OAuth account.

X OAuth app setup reuses the tenant-owned OAuth Provider App and Group-owned OAuth Connection and Binding.
Organization admins save the Client ID and Client Secret. Swarm admins then authorize an X account on Connections.
The adapter uses PKCE S256, confidential-client authentication, token refresh, and revocation through the existing managed OAuth flow.
Default scopes are `tweet.read`, `tweet.write`, `users.read`, `media.write`, `follows.read`, `follows.write`, `dm.read`, `dm.write`, `bookmark.read`, `bookmark.write`, and `offline.access`.
Existing grants keep the access they have. Reconnect OAuth to grant writes, media uploads, follows, or Direct Messages. Saving an app grants no account access.
The MCP request resolves current credentials through `MCPCredentials`. It never stores OAuth tokens in MCP configuration or exposes them to models.
X credential lookup reads at most one 64-record Group page, then only records needed to find the alias. An incomplete lookup fails closed.
This is a request budget, not an account limit. Large Groups need an indexed lookup before this path can resolve later records.
Create app opens the X Developer Console. X documents no creation-page prefill contract, so BFT supplies copyable configuration values.
X's official xurl bridge owns a local credential store. Salix must retain tenant apps and Group bindings, so its adapter reuses Req and the existing HTTP integration fixture.

Owners: [plugin setup](../../systems/apps/salix_web/lib/salix/control/plugin_setup.ex),
[Comma installation](../../systems/apps/comma_web/lib/comma_web/plugin_connections.ex),
[BFT setup](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/plugins.ex),
[X OAuth](../../systems/apps/salix_store/lib/salix_store/oauth/adapters/x.ex),
[MCP definition](../../systems/apps/salix_mcp/lib/salix_mcp/builtins.ex),
[MCP dispatch](../../systems/apps/salix_mcp/lib/salix_mcp/gateway.ex).

### Mac apps plugin

The Mac apps (Calendar, Reminders, Contacts, Messages, Mail, Notes, Music, Maps, System Control, Vision) reuse Plugin Definition, Plugin Installation, the Group-owned MCP binding, Device and Connector. They add no entity.
The per-app switches are a preference of one Mac, held by Comma's Main, not a domain fact. A Plugin per app would need ten installations sharing one binding.

- Plugin: the system plugin `mac-apps`, which only Comma on a Mac lists. Its one connection has kind `device_client`: the installing member's own Mac connects it, not an OAuth grant.
- Binding: `mac`, `placement: device`, pinned to the device's own Connector runtime (`RuntimeIds.device_runtime_id(device_id, "connector", "default")`), with the value `owner_user_id`.
  Installing from another Mac or as another member moves the binding to that device and owner. Uninstall deletes it.
- Transport: the MCP definition's target `client:mac-apps` has transport `comma-client`. SalixMCP.Connection sends each JSON-RPC message with the Connector method `client_mcp`.
  The station forwards it to Main's client-control endpoint, which answers for the apps turned on. No port, URL or token on the device reaches Salix.
- Owner: SalixMCP.Provider runs a `client:` binding only for a turn whose requester (CommaWeb.MacAppsRequester: the person's own turn, or a Worker's turn on the first command of an ordinary one-shot Task created from that person's own Router message, SalixIM.TaskExecution.task_requester/1) owns the device the binding reaches, read from the device registry; `owner_user_id` only records who installed it. Turns without a person, later commands into a Task, schedule fires, Loop wakes, scheduled and Loop Tasks fail. An Agent's `mcp_manager` cannot create or change such a binding, and only this system definition may use the `comma-client` transport.
- Server: MacAppsHost, a Swift MCP server Main starts as its child, so macOS attributes permissions to Comma. A tool call never prompts; only the user's switch requests a permission, including macOS's question about capturing the screen without its window picker (turning Vision on takes one capture). A tool of an app turned off is not listed, and the Agent is told to ask the user to turn it on.
- Lifecycle of the switches: Main's file `<userData>/mac-apps/switches.json`, read on every MCP message and shared by every workspace connected on that Mac. A change installs the plugin again, which rediscovers the tools. Uninstall deletes the workspace's binding and leaves the switches.

Owners: [plugin setup](../../systems/apps/salix_web/lib/salix/control/plugin_setup.ex),
[Comma installation](../../systems/apps/comma_web/lib/comma_web/plugin_connections.ex),
[MCP transport](../../systems/apps/salix_mcp/lib/salix_mcp/connection.ex),
[owner check](../../systems/apps/salix_mcp/lib/salix_mcp/provider.ex),
[station forwarding](../../systems/station/src/connector/connector.ts),
[Main](../../clients/apps/electron/src/main/modules/mac-apps/index.ts),
[server](../../clients/apps/electron/native/macos/MacAppsHost/Sources/MacApps/MacAppsService.swift).

### Blender plugin

Blender on a member's computer reuses Plugin Definition, Plugin Installation, the Group-owned MCP binding, Device and Connector, as the Mac apps do. It adds no entity.
A connected Blender window and a render job are local state of Comma's Main on that computer, not domain facts.

- Plugin: the system plugin `blender`, listed only to Comma on macOS or Windows that sends the client capability `blender-plugin`. Its one connection has kind `device_client`. Binding `blender`, target `client:blender`, transport `comma-client`; the owner rule of the Mac apps applies to it unchanged.
- Bridge: a switch of that computer, held by Main in `<userData>/blender/switch.json` and shared by every workspace connected there. The first `initialize` from Salix (a workspace installed the plugin) turns it on unless the user already chose; the user's choice survives restarts. Uninstall deletes the workspace's binding and leaves the switch. On, Main writes Comma's bridge script into each Blender version's user `scripts/startup` folder, which Blender loads at start and on Reload Scripts without an add-on preference; Comma never writes Blender's preferences. Off removes only Comma's script and its bridge file, and every call answers `plugin_off`. A background Blender never connects. The script reads Main's loopback port and a per-run token from `<userData>/blender/bridge.json` (this OS user only) and runs each request on Blender's main thread; a request of a connection that has closed is dropped before it runs, and Python already running is not stopped.
- Blender apps: the Blenders in the usual places, plus the ones the user chose in Plugins (`apps.json`). `session op=open` and Plugins start one, with a new scene or a `.blend` file.
- Tools: `session`, `scene`, `execute`, `capture`, `render`, `job`. `execute` runs Python with the user's own permissions; an undo step brackets it, and undo does not revert files it wrote or anything it sent. `capture` draws the viewport's or the camera's view offscreen, so a covered window still gives the current scene. Pictures are JPEG, 1280 px on the long edge by default, below 4 MB.
- Render jobs: `render` saves a copy of the scene and renders it in a background Blender; Main owns each job in `<userData>/blender/jobs/<id>`. One `job` wait request holds at most 20 s. SalixMCP.Provider asks again within the same tool call while the job runs and the call's deadline leaves time, so a render's end reaches the model without waking it in between. A wait that runs out keeps the job running. A job Main was running when it restarted reads as `interrupted`.

Owners: [plugin](../../systems/apps/salix_web/lib/salix/control/plugins.ex),
[render wait](../../systems/apps/salix_mcp/lib/salix_mcp/provider.ex),
[Main](../../clients/apps/electron/src/main/modules/blender/index.ts),
[bridge script](../../clients/apps/electron/src/main/modules/blender/comma_bridge.py).

### Miniskill activation

A miniskill is an existing Skill with `activation: per-message` in SKILL.md frontmatter.
An absent activation field means `regular`. SkillStore retains the same identity, scope, files, owner, and lifecycle.
The dashboard can create this mode, and file edits can change it. Miniskills require a name and description. Their instruction bodies have no miniskill-specific size limit.
Plugin visibility and scope still determine eligibility. Supporting files keep their existing runtime paths.
Only regular skills contribute entries to the preloaded prompt catalog.
Built-in third-party service miniskills reference the regular `service-access` skill for shared access and purchase-safety steps.
`make test-resources` rejects a built-in catalog whose worst-case selection request exceeds the runtime limits.

For internal Sessions, MiniskillSelector evaluates newly materialized human inputs before Agent dispatch.
It uses the configured decision provider, fee authorization, admission budgets, and attributed archive seam.
The request contains the current message, up to six preceding user/assistant messages, and every eligible miniskill's name and description.
History uses retained Session messages in chronological order. Each input sees only messages before it, including earlier coalesced inputs.
Tool outputs, tool-call arguments, and archived-history reads are excluded.
Miniskill resolution does not enforce IFC on information sent to the decision provider.
Selected metadata retains agent-private provenance for subsequent agent actions.
One independent relevance question per candidate returns a probability. Candidates at or above 0.65 sort by probability, then Skill ID.
At most five skill metadata entries attach per input. This threshold is a tuning value, not a correctness guarantee.
The internal request profile allows 64 KiB; the public `decide` tool retains its eight-question, 12 KiB contract.
The catalog has a 48 KiB limit. Every message has a 2 KiB text limit, including the current message.
Oversized messages retain their beginning and end with an omission marker. Six preceding messages remain eligible regardless of their original size.
An oversized complete catalog produces no selection. No candidate subset substitutes for it.

Preparation uses the cached skill projection while live credentials and round configuration refresh.
Cold Sessions first join existing catalog prewarming. Selection currently completes before compaction and attachment preparation.
A one-second absolute deadline bounds selection and its final join. No retry or larger-model fallback extends it.
Coalesced inputs share this deadline. Selection reads no skill body.
The main model receives only each selected skill's ID, name, and description.
It decides whether to read that skill through the existing runtime file tools.
Timeout, provider errors, and saturation produce empty selections without dropping user input.

Accepted selections, including empty outcomes, join the existing Session activation checkpoint.
Provider computation can overlap this checkpoint. Deltas and results wait for durable success.
This value adds no decision entity. Retries reuse it; a crash before commit can repeat inference.
The same commit appends one no-wake runtime message (`miniskill_selection`) per input with selected skills. It holds only the selected metadata and stays in the transcript like other context-provider messages.
Later requests and compaction read it from history.
The provider request archive captures the stored message. Telemetry records bounded outcomes, wait, selected count, and bytes.
The Runtime Activity tab shows miniskill selection duration and its wall-clock share, with overlapping configuration time counted once.
Provider accuracy and latency require workload evaluation; fixture tests establish runtime behavior only.

Implementation: [selection](../../systems/apps/salix_agent/lib/salix_agent/miniskill_selector.ex),
[Skill projection](../../systems/apps/salix_agent/lib/salix_agent/skill_projection.ex),
[Session input query](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Query/Round.lean),
[provider rendering](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Request.lean).

### Slack command source receipts

[SlackCommandThread](../../systems/apps/salix_im/lib/salix_im/slack_command_thread.ex) owns a provider-ingress receipt for the existing IM Connect and Slack trigger.
It is not a Task, Conversation, Message, Participant, or independent work queue.
The existing event receipt records arrival, but cannot store a pending public write and its returned thread timestamp.
This receipt stores those facts without creating another task identity.
Its dedicated `ctl/im_slack_command_threads/<connect_id>/<trigger_hash>.json` prefix keeps it separate from Triage event receipts.

The receipt moves from `posting` to `posted` after Slack returns a timestamp and storage confirms it.
A provider rejection moves it to `rejected`, which permits a retry for the same trigger.
An unknown result remains `posting`. Do not delete it or repeat a potentially successful post.
A `posted` receipt remains available when Router admission fails. A retry reuses its timestamp and the existing Router source-message identity.
A new user invocation has a new trigger and is a new request.

The receipt stores a payload fingerprint, random attempt owner, state, creation time, and confirmed timestamp.
It stores no prompt, token, or response URL.
The fingerprint compares a retry with the first authenticated request. It prevents a trigger from redirecting another prompt or channel.
It is a consistency check, not a separate cryptographic authority. A mismatch rejects the retry.
The random owner identifies the CAS writer. It is not a renewable lease or permission to take over uncertain work.

Receipts have no automatic TTL or physical deletion job. Their count grows with distinct triggers, including rejected attempts.
This retention preserves duplicate suppression and uncertain-write evidence. It does not claim exactly-once delivery or automatic recovery.
Disabling a connect prevents use. Deleting a connect logically retires its receipts because authenticated ingress rejects the tombstoned connect.
Physical deletion is not part of that soft-delete operation.
Any future purge must preserve the connect tombstone, stop its writers, and use the exact per-connect prefix.
Do not purge receipts from an active connect as a retry mechanism.

Both `/newgpttask` and `/newclaudetask` use the same ingress layer.
The connected bot publishes `<@sender_id> : <@bot_user_id> original prompt` in the source channel before Router admission.
The two IDs are real Slack mentions. The adapter escapes control syntax in the prompt to prevent extra notifications.
The Router receives the unchanged prompt with its command-specific worker instruction.
No LLM selects a language or builds the source message.
Prompts that exceed 39,000 characters after escaping are rejected before publication.

The saved timestamp becomes trusted `thread_ts` and `message_ts`.
Existing reply obligations and automatic Task-card publication target that thread. Router guidance prohibits another root message.
Success returns an empty HTTP 200. Validation, publication, and deadline errors return private guidance.
Other unclassified admission failures retain retryable HTTP 503. A visible root can exist without an admitted Task.

The [HTTP ingress](../../systems/apps/salix_im/lib/salix_im/provider_http.ex) runs in a request-linked task with one 2.5-second deadline.
That deadline covers identity reads, Router checks, receipt CAS, publication, settlement, and admission.
On expiry, the HTTP process kills the local attempt. Remote writes can still complete, so the receipt remains in place.
The existing Slack Web API adapter handles transport and errors. A second SDK would duplicate that boundary.
Reference contracts: [slash commands](https://docs.slack.dev/interactivity/implementing-slash-commands/) and [chat.postMessage](https://docs.slack.dev/reference/methods/chat.postMessage/).
[HTTP regressions](../../systems/apps/salix_web/test/router_test.exs) cover duplicate callbacks, literal prompt rendering, and slow claim/settlement with late completion.
They do not prove a live Slack task-card-to-result flow.
The retained TLA+ inbox, lease, and Task delivery abstractions remain unchanged. No feature-level model claims this receipt protocol.

For unlocked plugins, Comma's installed result requires explicit enabled state and an installation record.
A system default or an installation record alone does not establish that result.
Installation, enablement, and live connection readiness remain distinct facts.

Comma iMessage uses an authorized User/Workspace-to-private-chat binding.
This is a product authorization relationship, not another Conversation or IM Connect identity.
[Comma.IMessageLinks](../../systems/apps/comma_core/lib/comma/imessage_links.ex) owns the binding and its temporary, ten-minute claim command.
The Workspace ID identifies the binding. A sender can bind to one Workspace.
The authenticated Workspace owner can replace, cancel, or disconnect it.
The stored connect ID references the Salix-owned IM Connect.
The per-relay cursor is receiver progress, not another message or delivery identity.
The binding has two transports: the Willow relay and Photon shared lines. The `transport` value on the binding and the attempt, and `runtime_mode` on the IM Connect, select the adapter.
A Photon binding reuses this relationship. It has the same Workspace identity, owner, lifecycle, and Router delivery, and a new transport alone does not justify a new entity.
A Photon attempt also names the handle that must send its code, the assigned line, and the Photon line assignment ID. The assignment is a provider seat that the binding references, not a product identity.
The Photon cursor row is receiver progress for one Photon project. It keeps the handled Message IDs of its overlap window.

A Workspace owner also connects WeChat, Telegram, iMessage or Signal from their Router chat (`channel.link`, [SalixAgent.Tools.ChannelLink](../../systems/apps/salix_agent/lib/salix_agent/tools/channel_link.ex); the Comma side is [CommaWeb.ChannelLinkTools](../../systems/apps/comma_web/lib/comma_web/channel_link_tools.ex)). No entity is added: the tool starts the same attempt Settings › Channels starts (a WeChat QR login, a Telegram OIDC attempt, an iMessage claim, a Signal claim), for the owner of the Group's Workspace only, from the message's server-sealed principal (a Comma user, or a chat user linked to the owner's account). The Router posts what the attempt needs (the QR code, the login link, the command to send), and the call stays open as a `channel_link` capability request until the attempt completes where it always did (the QR poll, the OIDC callback, the claim message), which ends every call waiting for that provider (`complete_channel_link/4`); an attempt that runs out ends the call as the request expires (the expiry sweep settles `channel_link` requests as it does `location` ones). A WeChat QR code is the payload WeChat gave, rendered to a PNG on the Comma side (as Settings renders it) and written into the Router's workspace by the tool, so the Router sends it as an image content block, never as text or a link. A WeChat attempt a Router started is polled by [CommaWeb.WeChatLinkWatch](../../systems/apps/comma_web/lib/comma_web/wechat_link_watch.ex) every 3 s while the request is open, since nothing else polls it without the Settings page; one process per attempt, not restarted. When that attempt ends without connecting (expired, cancelled in Settings, replaced by a newer attempt), only its own call fails (`fail_channel_link_request/4`); another Router call waiting for a newer attempt goes on. When WeChat asks for a verification code after the scan, the waiting call returns `verification_code_required` with the attempt, the Router asks the user, and a second `channel.link` call with `attempt_id` and `verify_code` submits it for the same attempt and waits again. Salix IM tells the product of a Signal binding through [SalixIM.Ports.ChannelLinks](../../systems/apps/salix_im/lib/salix_im/ports/channel_links.ex). X stays in Settings: it takes keys.

A Workspace owner also installs a plugin from their Router chat (`plugin.request_install`, [SalixAgent.Tools.PluginInstall](../../systems/apps/salix_agent/lib/salix_agent/tools/plugin_install.ex); the Comma side is [CommaWeb.PluginInstallTools](../../systems/apps/comma_web/lib/comma_web/plugin_install_tools.ex)). No entity is added: an installed plugin answers at once; otherwise the call stays open as a `plugin_install` capability request whose card in the Conversation installs the plugin as the Plugins page does (`plugin.install`: its authorization, key or scan). Any install of the plugin, by the card or the Plugins page, ends every call waiting for it ([Comma.Plugins](../../systems/apps/comma_core/lib/comma/plugins.ex) `install/4` calls `complete_plugin_install/3`); a decline on the card or the request's expiry (10 minutes, settled by the expiry sweep) ends it too. Only the owner of the Group's Workspace, from the message's server-sealed principal, gets a card. A plugin with a `device_client` connection (the Mac apps, Blender) gets none: it is installed from Comma on that computer.

Comma WeChat reuses IM Connect for QR attempts and active connections.
[Comma.WeChatLinks](../../systems/apps/comma_core/lib/comma/wechat_links.ex) owns current and pending Workspace references.
[WeChatConnects](../../systems/apps/salix_im/lib/salix_im/wechat_connects.ex) owns the provider credential and attempt lifecycle.
The Workspace owner starts, cancels, replaces or disconnects this relationship.
A confirmed bot identity belongs to one active connect. A new attempt does not create a new product User.
[WeChatMessages](../../systems/apps/salix_im/lib/salix_im/wechat_messages.ex) projects observed provider messages for ID-only incoming quotes.
The existing IM Connect and peer scope the provider message ID. Completed ingress receipts avoid repeat staging; Router source-ID deduplication owns durable admission.
The IM Connect also owns its bounded pending polling batch and CAS revision through [ProviderConnects](../../systems/apps/salix_im/lib/salix_im/provider_connects.ex).
Pending inputs survive process exits. Each head completes after Router admission or a direct product-command reply; the last head advances the provider cursor. No separate inbox identity is added.
The polling lease reduces duplicate requests but does not authorize cursor advancement. Quote projections grant no send or read authority.
Successful authorized ingress and egress create immutable records of direct items, without nested quotes or context tokens.
Records are at most 64 KiB, read by exact key, and unavailable for quote resolution after seven days. This is logical expiry, not a storage deletion policy.
A new connect cannot read its predecessor's records. Missing records and expired provider media fail explicitly, without reconstructing absent content.
No canonical Message, Conversation or participant lifecycle is added.

### Voice Call

A Voice Call is one live call between a caller and a Group's Router. GPT-Live speaks with the caller through one carrier: Twilio or the `comma.voice.v1` API over WebSocket or HTTPS.
Reuse is insufficient: a call is not a Session, Conversation, Message or Participant. It is a live media transport with its own admission, deadline, drain and charge. The IM Connect only binds callers and receives Router replies.
Identity is the call ID (`vc_` and 26 base32 characters) that Salix mints at admission, together with the carrier and carrier call ID. Twilio supplies its `CallSid`. A WebSocket call uses its call ID. The carrier call ID keys the charge.
Scope is one Group. A phone call binds through a verified caller number of the Group's voice IM Connect. A WebSocket call binds through a voice agent API key of that Group.
[CallActor](../../systems/apps/salix_voice/lib/salix_voice/call_actor.ex) owns the call on the node that holds its media. `:pg` groups find it. At most one call per Group is live in the cluster.
The lifecycle is admitted, attached, live, ending and ended. A call ends on completion, a hang-up, a busy Group, its deadline, an attach timeout, a model or carrier error, key revocation or drain.
A call keeps no durable state. After it ends, only its charge, the canonical Messages from its delegations and start and end inputs, and its metrics remain. A call does not resume after node loss. The caller calls again.
Each delegation, one call-start input when the call is ready and one call-end input after it, enters the Router Conversation as provider input through `ConversationServer -> ConversationActor`. The Router answers through the `voice.*` Provider Operations.
The Group's voice IM Connect is the delivery connect and holds the `ProviderIdentity` number reservations. Revoking the voice agent API key ends its calls. The Group billing owner receives the charge.
The caller profile is a per-call projection, not an entity: [Profile](../../systems/apps/salix_voice/lib/salix_voice/profile.ex) decides it with Jev from recent Router session text before the model starts, and nothing stores it. See [voice profile](../messaging-voice.md#voice-profile).
Implementation: [SalixVoice](../../systems/apps/salix_voice/lib/salix_voice.ex),
[VoiceConnects](../../systems/apps/salix_im/lib/salix_im/voice_connects.ex),
[Provider.Voice](../../systems/apps/salix_im/lib/salix_im/provider/voice.ex),
[VoiceMetering](../../systems/apps/billing_core/lib/billing_core/voice_metering.ex).
The [HTTPS carrier](../../systems/apps/salix_web/lib/salix_web/voice_http.ex) reuses this CallActor and API-key carrier identity. Its random handle and owner-node hint locate a transient stream, authorize nothing, and disappear with it. They add no domain entity or billing identity.
See [voice contracts](../messaging-voice.md#voice-calls).

### Signal Account

A Signal Account is one Signal account that Comma registered as a primary device. It sends and receives Signal messages and calls for the Groups whose Signal IM Connects bind senders to it.
Reuse is insufficient: an IM Connect belongs to one Group, but one Signal Account serves many Groups. Its key and session state changes on almost every message and needs exactly one writer.
Identity is a Comma-chosen account ID (UUID). It maps to one Signal ACI and device ID, which are unique among stored accounts. Scope is the platform (the shared number) or one Organization (a tenant-configured number).
[Account.Server](../../systems/apps/salix_signal/lib/salix_signal/account/server.ex) owns the account. It runs on the `SalixCluster` ring owner of the account ID. It claims the account with a new owner epoch, and every write checks that epoch in the same transaction.
The lifecycle is registering, active, re-registering and retired. Only active accounts run. A revoked device credential moves the account to re-registering.
[Storage](../../systems/apps/salix_signal/lib/salix_signal/storage.ex) keeps the account record, pre-keys, sessions, remote identities, groups, sender keys, admitted envelopes and sent content in the `signal_*` tables, encrypted at rest. These rows are owned durable data. Their loss forces re-registration and a safety-number change for every contact.
An envelope is acknowledged only after its session advance and admission commit together. The Signal provider receives admitted messages at least once, behind a durable cursor. They enter the Router Conversation as provider input through `ConversationServer -> ConversationActor`.
Groups relate to an account only through their `signal` IM Connect. A binding names one peer (an ACI, or a Signal group) and the account it was claimed on. The `ProviderIdentity` reservation `signal:peer:<account>:<peer>` routes that peer to exactly one connect. A peer binds by sending a one-time claim code to the account. Unbound senders get no reply and reach no Router.
Which account a tenant's new claims use is a setting, not a relationship: the platform account, or the tenant's own account that overrides it. Existing bindings keep their account. A bound peer's call becomes a [Voice Call](#voice-call) through the Group's `voice` connect.
Implementation: [Accounts](../../systems/apps/salix_signal/lib/salix_signal/accounts.ex),
[Account](../../systems/apps/salix_signal/lib/salix_signal/account.ex),
[Messaging.Pipeline](../../systems/apps/salix_signal/lib/salix_signal/messaging/pipeline.ex),
[SignalConnects](../../systems/apps/salix_im/lib/salix_im/signal_connects.ex),
[Provider.Signal](../../systems/apps/salix_im/lib/salix_im/provider/signal.ex),
[IMHandler](../../systems/apps/salix_signal/lib/salix_signal/im_handler.ex),
[Settings](../../systems/apps/salix_signal/lib/salix_signal/settings.ex).
See [Signal contracts](../messaging-voice.md#signal).

### Feishu cloud documents

Feishu document access reuses IM Connect, Tool / Provider Operation, and IFC Label.
It adds no document entity, credential, or stored projection. Each read is live; document content is not cached or indexed.
The `im_api.feishu.*doc*` operations use the connect's app and its `tenant_access_token`. A connect made by a scan owns its app's App Secret, as a Lark connect does; any other Feishu connect uses the tenant's Feishu app.
The bot can open a document only when the document is shared with a chat that includes the bot, shared with the app, or open by link inside the tenant.
`mcp.feishu.*` remains the per-user path. Routers and Workers hold every document operation. Workers also hold every Feishu read operation and no other messaging operation.
Task execution grants do not change.

Supported documents are Docx and Docx pages in a wiki. Spreadsheets, Base, legacy `/doc/` documents, and Lark international hosts fail before any provider request.
Content reads and edits use the `docs_ai/v1` API of the official Lark CLI. Content larger than 60 KB is staged in the Agent VFS.
Writes are never retried. An ambiguous provider result is an unknown outcome.
A new document without a parent stays in the app's space. The bot closes its link before it shares the document with `share_chat_id` or `share_user_id`.
If the link cannot be closed, the bot deletes the new document and reports the failure.
A media insert first creates an empty block. If the upload or the bind fails, the bot removes that block.
Inbound Feishu message text keeps rich-text link targets, so a shared document link reaches the Agent as a URL.

Lark meetings reuse IM Connect, Tool / Provider Operation, IFC Label, and the tenant-owned OAuth Provider App with Group-owned OAuth Connection and Binding.
They add no meeting entity, credential, or stored projection.
Each Lark person who signs in is one Binding of provider `lark` with its own alias, so a Group holds several accounts.
The Provider App is the bot's Lark app. Lark grants a refresh token with `offline_access`; the existing OAuth owner refreshes it and marks a refused grant for reauthorization.
`lark.search_docs`, `lark.list_drive_files` and `lark.search_meetings` run as the app and then as every active account, and `lark.get_meeting` and `lark.get_note` try them in that order, unless `account` names one (`app` for the app alone). Lark document, spreadsheet, Base, wiki and Minutes reads, and Lark document content writes, with `account` run as that person.
A meeting read is labelled with its participants and the reading account; a search with the accounts whose items it returns, and the fail-closed label when the app's items are among them; a note read with the reading account.
A Lark or Feishu video meeting the bot is invited to is one Meeting of provider `lark` or `feishu` and runtime source `lark_bot` (`SalixMeet.LarkBot`). It adds no entity: the platform holds the bot in the meeting, and the Meeting's leader reads its transcript and chat from the platform. A calendar meeting with a Feishu/Lark link that the Group's settings join is also one such Meeting: its provider is the settings' destination (Slack, Feishu or Lark), and `lark_bot` names the bot's own connect. A meeting the bot is in through an invitation and through the calendar stays one Meeting (an index by connect and meeting number).
Feishu meetings follow the same rules with provider `feishu` (`SalixIM.Provider.Feishu.Meetings`, `feishu.*` operations). Their Provider App is the organization's Feishu app.

A read label never names more readers than the document has.
A link open to anyone is `public`. A link open inside the tenant is the connect's space.
Otherwise the label is the join of the collaborating chats and people. Departments, wiki spaces, and parent folders add no reader.
If Feishu does not disclose the audience (listing collaborators needs share permission), the read gets the fail-closed label.
With the check off, a read makes no permission request.

A write destination never names fewer readers than the document has. Folder, wiki, and department readers cannot be listed.
New content, media, or a comment in an existing document resolves to the connect's space, or to `public` when the link is open to anyone.
A setting that Feishu does not disclose is a public destination with unknown writers. Under `enforce`, content from a narrower scope needs a receipt.
Creation is decided for the parent location, or as Agent-private without a parent, and also for the share target.
Sharing with a chat or a person is decided like a send to that conversation. A department or a tenant link is the space.
Deleting, moving, or copying a document's own blocks, resolving a comment, removing a member, and deleting a document carry no content.
BFT includes the document and Minutes scopes in the bot scope import. An existing app must import them again and publish a new version.

Feishu Minutes (妙记) use the same connect, roles, and read labels; the permission type is `minutes`.
Feishu offers Minutes edits only to a user identity, so the bot reads details, AI artifacts, transcripts, and media, and searches recordings.
A transcript above 60 KB and the media file are staged in the Agent VFS. Media comes from a pre-signed HTTPS URL that receives no app token.
`feishu.request_minute_access` asks the owner for access and carries no content.
`feishu.request_doc_access` asks the owner of a document, spreadsheet, or Base for access as a signed-in person, never as the app, and the approval adds that person.
Its optional remark reaches the owner, so IFC treats it as an unclassified egress (`{public}`).

Document, spreadsheet, and Base reads, and document content writes (`update_doc`, `insert_doc_media`, and the comment writes), take `account` and then run as that signed-in person.
The order is: the app, then the account of the person who asked, then a new sign-in, then an access request as that person. A write as a person needs that person's agreement first.
A denied call returns the next step of that order. Creation, sharing, link settings, and deletion run as the app only. They and every other operation refuse `account`.
The default sign-in reads documents only. Table reads and document edits need user scopes that a sign-in asks for only on demand. The batch import offers them, and a default sign-in does not ask for them, so an app without them still lets people sign in.
A sign-in that names only these scopes asks for them on top of the default sign-in. Any other list replaces the defaults. A denied call names the scopes to ask for.
A read as a person is labelled from the audience that this person can list, as for a document read. If it is not disclosed, the read gets the fail-closed label.
A write as a person gets the same destination as the same write as the app. The app reads the link setting. If the app cannot read it, the destination is public with unknown writers.

A Lark connect has the same document and Minutes operations as `im_api.lark.*`, with the same roles, labels, and destinations.
They use the Lark connect's own app credentials and Lark's own modules. A Lark connect accepts `larksuite.com` links; a Feishu link fails before any provider request.
See [Lark documents](../../systems/apps/salix_im/lib/salix_im/provider/lark/docs.ex) and [Lark Minutes](../../systems/apps/salix_im/lib/salix_im/provider/lark/minutes.ex).

[Document operations](../../systems/apps/salix_im/lib/salix_im/provider/feishu/docs.ex),
[Minutes operations](../../systems/apps/salix_im/lib/salix_im/provider/feishu/minutes.ex),
[read labels](../../systems/apps/salix_im/lib/salix_im/ifc/read_labels.ex),
[destination facts](../../systems/apps/salix_im/lib/salix_im/ifc/facts.ex),
[destination classes](../../systems/apps/salix_agent/lib/salix_agent/ifc/destination.ex),
[worker operations](../../systems/apps/salix_im/lib/salix_im/provider.ex),
[tests](../../systems/apps/salix_im/test/feishu_docs_test.exs).

### Mini App

A user asks Comma to build an app. A Coding Task on an L4ES coding sandbox writes it in a GitHub repository and deploys it with the station tool `app_deploy`.
Comma clients (Mac and web) run the app in a sandboxed frame. The app has no origin, page or URL of its own.

Reuse is insufficient:
- A Salix Site is a public VFS directory of one Agent. It has no product owner, Workspace authorization, publication state or Version identity.
- A `dynamic_ui` widget is an immutable value of one Message. It has no backend, shared storage or lifecycle outside its Conversation.
- A Coding Task is the build work, not the app: one app has many Coding Tasks. Task Share discloses a transcript, not a running app.
- A GitHub repository holds source. It does not record what is live, sharing, grants or storage.
- A Plugin packages refs to tools, skills and MCP. It has no hosted artifact or Versions.

**Mini App**
- Identity: a row ID (UUID) and a random slug `[a-z0-9]{8}`. The slug is an internal name for scripts, not a hostname.
- Scope: one Comma Workspace and its current Group.
- Owner: [Comma.MiniApps](../../systems/apps/comma_core/lib/comma/mini_apps.ex), table `comma_mini_apps` in Comma PostgreSQL.
- Lifecycle: `active`, then `disabled` (by the owner, or by a platform takedown that the owner cannot undo), then `deleted`. Delete revokes the Link and removes Installs at once. The cleanup job then deletes the Cloudflare scripts, all objects under `miniapps/apps/<id>/` and the rows. It never deletes the GitHub repository.
- Fields: name, description, icon and ordered screenshots (from the selected Version bundle), repository, live Version, visibility (`private`, only its creating User; `workspace`, where an app the Router made starts; or `link`), creating User (for an app the Router made, the Comma User who sent the message the turn answered, from its server-sealed principal or a chat user's Provider User Link; none when it names none), owner Workspace grants and sealed owner secrets.
- A Workspace row cannot be deleted while it has apps. A Workspace deletion path must call `Comma.MiniApps.delete_workspace_apps/1` first.

**Mini App Version**
- Identity: `(app_id, number)`, with a monotonic number. A deploy key is unique per app, so a repeated station request makes one Version.
- Lifecycle: `uploading`, then `ready` or `failed`. A `ready` Version is immutable. A failed Version's objects are deleted after 7 days.
- Retention: the live Version, the last 20 Versions, and every Version an Install pins.
- Fields: manifest, commit SHA, bundle and source archive objects, icon, cover and screenshot objects (from the bundle), backend script name, bundle digest, build Task Conversation and deploy notes.
- The cover is a screenshot of the app's first screen that the Apps gallery shows. A deploy accepts at most 160 KiB and 1200 × 1200 pixels.
- Screenshots (at most six, each at most 2 MiB) show on the app's details page. Artwork is a Version value, not a separate entity: publication, pins and rollback select matching media.
- The digest is a client cache key and provenance, not a security check.

An iOS or Android execution is an in-memory client projection of a Mini App and its selected Version, not a new domain entity.
The native host retains its WebView and Core session per account, Workspace and app. Back hides the execution; Continue reuses it without reopening or approving cloud access again.
An explicit different Version or access path replaces that app's retained execution. Complete close, account or Workspace changes, and local uninstall or disable release it.
Memory pressure can release suspended executions. Process termination loses unsaved page state. WebKit, Android WebView and the OS control offscreen scheduling. This does not grant continuous OS background execution.
On iOS and Android, `files.pick` uses a host-owned photo or camera picker. The manifest must declare it. Each request requires explicit photo confirmation for the named Mini App.
The picker returns only confirmed JPEG or PNG bytes. It does not expose library identifiers, image metadata, or continuous camera access.
Suspension and close cancel pending photo requests. A foreground change also invalidates a confirmed photo result that still awaits Core authorization.
The request holds at most six images, 4 MiB per image and 8 MiB total. The iOS host limits imported files to 32 MiB. Both hosts limit image dimensions to 2048 pixels.
The iOS host also supports declared draft, clipboard, HTTPS link, Task proposal, app-folder Drive, identity, and notification capabilities.
The Core owns grants. Identity and app-folder access use existing once-per-app grants. Links and Task proposals require native confirmation each time.
The host fills the current draft without sending it. Suspension cancels pending host confirmations. Device storage and Mac Calendar stay unavailable.
Implementation: `clients/apps/apple/iOS/MiniApps/MiniAppSession.swift` and `clients/packages/core/src/miniapps.ts`.
App Store distribution of this bridge requires prior Apple permission under Review Guideline 4.7.2. A system permission prompt does not establish that permission.

**Mini App Link** has the Task Share token contract: one active link per app, a 32-byte random token, `active`, then `revoked`. Reset issues a new token.
The token lets a signed-in or guest Comma user run the app inside Comma. It is not public read authority.
Reset, revoke, or a change of visibility away from `link` also removes the Installs of other Workspaces.

Web and Mac executions keep an opaque iframe origin. Declared USB and Bluetooth capabilities delegate browser APIs through Permissions Policy.
The browser owns device grants at the top-level Comma origin. These grants can be reused by other apps with the same capability.
The SDK broker still owns per-app grants for microphone and other SDK effects. No frame hostname or separate app domain is required.

**Mini App Install** is a relationship of a viewer Workspace and a Mini App. It holds that Workspace's capability grants and follows `live` or pins one Version.

**Pairwise viewer ID**: an app sees an HMAC of (Comma User ID, app ID) under a server key. It is not a Comma User ID, and nothing stores it per viewer.

Builds are ordinary Coding Tasks with the Task value `mini_app {app_id}`. Placement accepts it only on a sandbox with the app's repository.
The deploy request is valid only from the Task's sandbox on its current Workload generation.
The Workspace Router manages shared and installed apps through the same product operations as the user API.
Its current Workspace binding and the owner's active membership supply authority. Member-private apps remain outside the shared Router's scope.
Publishing derives the build Task from the stored Version, accepts review, merges that commit and sets it live.
The [Router adapter](../../systems/apps/comma_web/lib/comma_web/mini_app_management.ex) adds no entity or lifecycle owner.

App storage `user` and `app` documents use the Site documents layout: one object per key with CAS, under the app's prefix.
Device storage is a client-core document per account, Workspace and app, like `dynamicUiState`.

Implementation: [owner](../../systems/apps/comma_core/lib/comma/mini_apps.ex),
[HTTP endpoints](../../systems/apps/comma_web/lib/comma_web/mini_app_endpoints.ex),
[Salix ports](../../systems/apps/comma_web/lib/comma_web/mini_app_port.ex),
[placement](../../systems/apps/salix_im/lib/salix_im/task_placement.ex),
[station deploy request](../../systems/apps/salix_web/lib/salix_web/station_tasks.ex),
[station tools](../../systems/station/src/tools/apps.ts),
[dispatch Worker](../../systems/cloudflare/miniapp-dispatch/src/app.ts),
[client core](../../clients/packages/core/src/miniapps.ts),
[runtime](../../clients/packages/chat-contract/src/mini-app/runtime.ts),
[tests](../../systems/apps/comma_web/test/mini_apps_test.exs).

## 6. Files and proactive work

| Concept | Meaning and boundary |
| --- | --- |
| Artifact / Attachment | A work result and its message delivery reference. File existence alone does not establish attachment delivery. |
| Agent Workspace / VFS | The Agent's file workspace. It is not Comma's authorization Workspace. |
| Comma Drive / Drive Binding | User file access and synchronization, plus the Group's authority to access a Drive. |
| Schedule / Schedule Run | A time-based definition and one occurrence of its execution. They have separate identities and lifecycle facts. A Background Loop's trigger is a value on the Loop, not a Schedule. |
| Heartbeat | A periodic Agent-work schedule. It is not the Connector's connection heartbeat. |
| Background Loop | An Agent-owned eBPF program that spinfoam runs on the Agent's lease-holder node: the VFS path and hash of its compiled object, config, target Session, status, and checkpoint. It has no per-Loop capability grants: every Loop may call the closed host allowlist with its creator's authority. It has no occurrences (not a Schedule), no history (not a Runtime Session), and no visible collaboration facts (not a Task). Its declared trigger, limits, run count and end are values on the row. It can belong to one Task: `task_conversation_id`, set at creation and never changed, is a relationship value on the row, and a Task has at most one Loop. A Task's requested Loop is `pending` until the Task's Worker gives it its program, and `ended` keeps the row. See [Loop Tasks](#loop-tasks). Its incarnation is a fence value on the row, not another entity. A `script.run` program also runs in spinfoam but is a transient part of one tool call (no row, no incarnation, no checkpoint), not an entity. |
| Calendar Item / Occurrence | A calendar object and one concrete occurrence. A Calendar Task does not contain the full Agent Task. |
| Meeting / Meeting Task | Meeting work and its Task representation, including recording and results. Meeting and Runtime Session identities remain distinct. A Router `meeting.join` from a Comma user's message makes a Meeting with provider `comma` and a `comma_ref` (Conversation, message, sender, the Router that posts status); this is a source value, not another entity. |
| Recommendation Profile / Run / Snapshot | Member-scoped settings, one generation attempt, and the current Comma Center result within a Workspace. Runs write in the User's app language; a language change starts one run per Profile with enabled sources. |
| Member Source Item | One normalized item that reaches a member through a connected source, with its current version. Collection writes it. Proactive attention reads arrivals and changes. Member Routine runs read current items. |

MeetingPlan Tasks end through the Conversation owner after terminal publication, before the existing activation handoff settles.
Meeting `done` maps to Task `completed`. Meeting `failed` and `cancelled` keep those Task statuses.
The activation retry also retries the Task status write. Exhausted terminal publication closes the Task before delivery failure settles.
Calendar cancellation closes the plan Task through the same owner command.
The command checks the plan reference and excludes preparation research Tasks. An ended or archived Task keeps its status and version.
The preparation deadline alone does not end the meeting Task. Research Tasks and desktop recording Tasks keep their separate lifecycles.

Implementation: [MeetingTaskCompletion](../../systems/apps/salix_meet/lib/salix_meet/meeting_task_completion.ex) and `ConversationServer.finish_meeting_plan/4`.

Owners and entry points:
[Attachments](../../systems/apps/comma_core/lib/comma/conversation_attachments.ex),
[AgentWorkspace](../../systems/apps/salix_agent/lib/salix_agent/agent_workspace.ex),
[Drive mapping](../../systems/apps/comma_core/lib/comma/synchronicity.ex),
[Schedules](../../systems/apps/salix_agent/lib/salix_agent/schedules.ex),
[Background Loops](../../systems/apps/salix_agent/lib/salix_agent/loops.ex),
[CalendarItem](../../systems/apps/salix_calendar/lib/salix_calendar/item.ex),
[MeetingState](../../systems/apps/salix_meet/lib/salix_meet/meeting_state.ex),
[MeetingTasks](../../systems/apps/comma_core/lib/comma/meeting_tasks.ex),
[Recommendations](../../systems/apps/comma_core/lib/comma/recommendations.ex).

An Attachment downloads at any size, streamed whole or in one byte range.
Its media URL ([`ConversationAttachments.presign/2`](../../systems/apps/comma_core/lib/comma/conversation_attachments.ex)) is the blob store's signed, expiring URL for the attachment's blob.
It has no row and no lifecycle of its own, so it is not an entity: the Session that mints it is authorized once, when it mints it.
Add to Context stores an Attachment as a composer upload (`/uploads/…` in the Router VFS) that points at the same blob.
That file is an ordinary upload with the upload's authorization, not a second identity for the Attachment.

For a user Message in a Task, the Conversation owner binds composer upload paths to blobs in the Group Router's VFS before acceptance.
The Message's `owner_uploads` value holds these references and their source Agent. Caller-supplied blob references cannot set this value.
Each Message binds at most 64 distinct uploads. An unavailable upload rejects the send. Accepted retries keep the original references.
Stations receive these files through `task.put` and `task.file`, then store them in the Session's uploads before delivery to the runtime.
This reuses Message and Attachment values and adds no identity or lifecycle.

A Task file is an Attachment of a visible Agent Message in a Task. The Task file index (`salix_task_files`) is a projection of these Attachments, not an entity.
Its key is the Group, the Task, the Message sequence and the block index. It holds no bytes and no blob ref, and a download reads the Message again.
The Conversation source transaction writes, retitles and deletes its rows. Reuse of the Conversation search projection was insufficient: that projection indexes visible text for relevance, not attachment blocks, and it is eventually consistent.
The Task panel, Drive's Task Files space, the command palette and the Router's `internal.list_task_files` read it.
See [Task files](../salix/conversation-owner-actor.md#task-files).
[Index](../../systems/apps/salix_im/lib/salix_im/task_files.ex),
[store](../../systems/apps/salix_store/lib/salix_store/task_files.ex),
[client](../../clients/packages/core/src/task-files.ts).

A Background Loop can own one secret webhook URL. The secret is a recoverable credential on the Loop row, not another identity.
The owning Agent enables, rotates, lists, or revokes it. Loop deletion removes it. Pause retains it but refuses delivery.
The [ingress](../../systems/apps/salix_web/lib/salix_web/loop_webhook.ex) accepts event data only and grants no additional tool authority.

A Background Loop can also own one Composio trigger binding. This is a relationship on the Loop, not another lifecycle entity.
The binding selects an existing provider trigger and connected account within the effective Composio settings scope.
The owning Agent changes or removes it. Pause retains it and skips events. Loop deletion removes it.
A provider trigger can serve several Loops and a pooled member source. It remains provider-owned until explicit group-authorized deletion.
The ingress signals a pooled source only with the trigger and account IDs, never the event data.
The existing Composio settings record owns the secret ingress URL. Its owner registers or rotates that URL through the settings API.
Changing provider credentials clears the URL credential.
The Loop owns a bounded map of pending event envelopes until guest ACK. This is accepted work within its existing lifecycle.
A receipt uses the existing event ID within that Loop. It has no independent owner or product lifecycle.
The Reconciler replays it across incarnations. Timeout retains it in a failed Loop. Explicit resume retries it, and Loop deletion discards it.
Implementation: [binding](../../systems/apps/salix_store/lib/salix_store/loops.ex),
[trigger tools](../../systems/apps/salix_agent/lib/salix_agent/tools/composio_triggers.ex),
[settings](../../systems/apps/salix_web/lib/salix/control/composio_settings.ex).

A Background Loop can also subscribe to one product event (`product_event` on the Loop row, set and removed with `loop.subscribe`). It is a relationship on the Loop, not another entity, and may coexist with a URL or a Composio trigger.
The known events are listed in `SalixAgent.Loops.product_events/0`; `meeting.completed` is the first.
A meeting that ends `done` with complete notes publishes it from its activation step (`SalixMeet.Ports.Events`), whether or not the Router handoff runs. Each active subscriber in the meeting's Group gets one event `meeting.completed:<meeting_id>`.
The payload holds product facts only: `meeting_id`, `provider`, `started_at`, `ended_at`, `duration_seconds`, `participant_count`, and scheduled times for calendar meetings. Meeting text never rides in the event: the Worker reads it with `meeting.get` as untrusted data.
A failed delivery fails the activation claim, and the claim's retry delivers again as a duplicate.
Implementation: [delivery](../../systems/apps/salix_agent/lib/salix_agent/loops.ex),
[publish point](../../systems/apps/salix_meet/lib/salix_meet/ports/events.ex).

A Background Loop can declare one trigger: `every_minutes`, or `cron` with an IANA `timezone`. It is a value on the Loop, not a Schedule.
`loop.create` takes it. Without a timezone it uses the timezone of the request that the round serves, else UTC. A Task's requested Loop takes the Task's cadence instead.
The program asks `loop.next_run` for the time of its next run, after the last run that it keeps in its checkpoint. The host computes it from the trigger and records it as `next_run_at`.
After missed windows, the answer is the latest missed one, so the Loop runs once. A next run at or after `ends_at` ends the Loop.
Nothing fires a Loop on time from outside: the program waits with `sf_event_next` until the time, so events still reach it. One wait returns after at most 24 hours.

A Loop that a Worker creates while it works a Task belongs to that Task. The Worker's Session serves one Task.
The round names the Task through a trusted source Message of that Task, through the Task's Loop that woke it, or through a Task Loop that its Session already runs.
A second Loop for the same Task is refused, whatever the status of the first. Router rounds and other rounds create Loops that belong to no Task.
The Loop tools of a Task round manage only that Task's Loop, and also Loops that the same Session created before Loops recorded their Task.
Every other round manages only the Agent's Loops that belong to no Task. A Loop outside this scope reads as not found.
The Task owner pauses the Loop with reason `task` while its Loop Task waits for a person. Only the Task owner resumes it: `loop.resume` refuses it.
Implementation: [Loop scope and Task operations](../../systems/apps/salix_agent/lib/salix_agent/loops.ex),
[cron receiver](../../systems/apps/salix_cluster/lib/salix_cluster/loop_triggers.ex),
[migration](../../systems/apps/salix_store/priv/repo/migrations/20261013120001_add_agent_loop_task.exs).

The Recommendation Profile retains GitHub, Linear, and Notion enabled choices while their sources are absent.
These three app-keyed booleans are member settings, not connections or credential authority.
The additive column starts empty and captures existing source choices on the first settings or discovery update.
The Profile owns their lifetime. Absent sources cannot authorize collection.
A settled Run keeps its generation counts, and the Profile keeps the published generation's copy.
These counts are measurement facts of the existing entities. They hold no source content and never cross the API.
The Profile's `relevance_mode` selects generic or member collection. New profiles start in member mode. Unset profiles also use member mode. Explicit generic choices remain unchanged. Each Run freezes that mode at allocation.
The internal mode setter supersedes active runs and clears the snapshot without changing refresh settings.
Discovery that only adds selected sources keeps the Snapshot valid for the new source revision while its replacement Run generates.
A removed, disabled, or rebound selected source clears the Snapshot.
[Member selection](../../systems/apps/comma_core/lib/comma/recommendation_member_selection.ex) derives bounded candidate IDs from admitted source facts.
These are transient projection references, not entities.
The member's Router judges these candidates in one [bounded model request](../../systems/apps/comma_web/lib/comma_web/recommendation_renderer.ex) with its own model.
The request runs without tools, a conversation turn, or a Router session.
It selects, ranks, and names each suggestion. A generic briefing uses one Worker request.
Member selection ranks suggestions across sources and keeps at most 18. A source has no quota. One connected mailbox is one source.
In rank order, a suggestion joins its source's card of up to four, else starts another card of that source with a numbered card ID.
A suggestion that would need a seventh card, or follows 18 kept suggestions, drops. The kept suggestions are the highest ranked that the cards hold.
Eligible matters compete for these slots, regardless of source, work or personal category.
An omitted matter is not evidence that it is resolved or irrelevant.
The server validates each returned row alone. A row that breaks its schema, names an unknown or repeated ID, or has undisplayable text drops.
A response that is not a selection, or whose rows all drop, rejects the generation. The valid previous snapshot remains.
This validation checks shape and source binding, not semantic faithfulness.
A failed generation logs its bounded failure reason. No source content is added to these diagnostics.
Record excerpts remain in the hover. The composer receives a first-person request for the objective, then the source URL.
Slack keeps its primary message, not a replacement neighbor.
Source-owned facts, references, and composer actions remain server projections. No decision entity or separate lifecycle is stored.
The Snapshot stores one structured prompt per selected reference: source ID, objective, source context, and localized context label.
Current clients do not show the label. Older clients print it above the quoted context in the composer.
Cards, summary links, and composer actions share that content through `promptId`. The client derives display strings during API decoding.
The client words the first-person request in the app language when it fills the composer.
The prompt map belongs to the existing Snapshot. It has no independent identity, lifecycle, or authorization authority.
Generation prepares the candidate projection once. Duplicate excerpts and empty fact maps are omitted from model input.
[Source context](../../systems/apps/comma_web/lib/comma_web/recommendation_source_context.ex) attaches bounded platform excerpts to retained candidate URLs.
This is a transient projection of the same authorized read, not a memory or preference entity.
It keeps record status, descriptions, and search neighbors without per-candidate network calls. Search neighbors are not a complete thread.
Each source has a separate 16 KiB context budget. It cannot reduce the 12 KB candidate budget.
Record links and provider IDs are outside the 12 KB candidate budget. Each source's record limit bounds them.
A cut that drops records reports the source as partially read. Mail candidates reach the Router without their links.
The Router judges actionable matters and material risks from that evidence, including both work and personal life.
Member mode limits relevance to the member, not to their job. Personal and social categories do not disqualify an actionable matter.
Consequences of inaction, deadlines, reversibility, and the member's relationship set priority.
Promotions, resolved matters, and chatter without an action remain excluded. Missing context does not prove completion.
Source reads use existing tool DependencyJobs. Crashes return source failures, and owner cancellation stops the read and releases admission.
The model request uses the existing LLM DependencyJob admission and the original run deadline.
It retains the judging Agent and Run identity through existing billing and encrypted archive seams.
Source evidence and Snapshot validation share [HTTP destination extraction](../../systems/apps/comma_core/lib/comma/recommendation_contract.ex).
A source field that starts with a URL can still contain prose. Whitespace separates its URLs from that prose.
Formatting quoted context must not create a different destination or break its source binding.
Each product adapter builds a source quote from the provider record at collection: title, author, status facts, and the words a person wrote with their format (plain, Markdown, HTML, Slack or mail text).
[One module](../../systems/apps/comma_web/lib/comma_web/recommendation_source_quote.ex) turns each format into quote markup: one line per source line, "• " list items, `<https://…|label>` links, Slack mentions, and `&lt;`, `&gt;` and `&amp;` for literal characters. Mail ends before the messages it quotes.
The Snapshot renders the quote in the member's language within 601 UTF-16 units. The client shows quote markup and does not guess source formats. A new product adds an adapter, not a client parser.

Comma-origin managed OAuth consent retains the authenticated owner's user and workspace IDs on the existing connection.
This provenance is private. HTTP parameters cannot supply it, and a group-visible binding does not imply it.
[RecommendationMemberIdentity](../../systems/apps/comma_web/lib/comma_web/recommendation_member_identity.ex) reads the live binding and connection for Linear, GitHub, Notion, and Slack.
It uses the Linear viewer, GitHub user, explicit Notion user owner, or Slack authorized user and team. Organization and bot IDs cannot identify the member.
This is a projection of the existing OAuth relationship, not a new identity entity or permission grant.
A legacy connection without this provenance is a system fault, not a member task: the run skips the source and logs `routine_source_identity_missing`. The one-time [member identity backfill](../../systems/apps/comma_web/lib/comma_web/member_identity_backfill.ex) stamps it when the Workspace has only ever had its owner as a member and the binding is in that Workspace's default group. Any other legacy connection still needs a reconnect.
[Member Source Consent](../../systems/apps/comma_core/lib/comma/member_source_consents.ex) is Comma's private relationship between a member and the Composio account they authorized.
Its key is Workspace, User, toolkit and connected account. A member can consent to several accounts of one toolkit, such as a work and a personal Gmail; each consented account is its own member source with its own items, identity check and collection state. A receipt keeps the provider identity it was checked against when Comma read it (`provider_subject`). A Routine profile reads at most 12 sources, native bindings and Composio accounts together, in name order; an account past the twelfth is not read. Verified installation completion or an owner's confirmed account choice adds that account's receipt, so every account the owner connects through Comma gets a receipt without a further choice; collection reads it within the source cap above. In a Workspace whose owner is its only member, every active account of a member toolkit (Gmail, Google Calendar, Google Drive, Outlook) in its default group is the owner's, also one the Router connected: during source discovery, [source adoption](../../systems/apps/comma_web/lib/comma_web/member_source_adoption.ex) gives each provider identity one receipt, on its newest active connection, and removes the receipt of an older active connection of that identity. It skips a bot or an account Comma cannot identify, and reads the provider only for an account without a stored identity. A shared Workspace adopts nothing. Installation completion retires the older connections of the same provider identity only, with their receipts; another account of the toolkit stays. In a shared Workspace, choosing an account in Plugins switches the toolkit to that account: its other receipts go, and Plugins offers only the accounts not consented yet. A sole owner has nothing to choose for the adopted toolkits: Plugins offers no account, and a confirmation only adds one.
It survives multi-step Google setup and the completion of an installation attempt. User or Workspace deletion removes it.
Its update timestamp fences renewed consent, even when the connected-account ID stays the same. Comma disconnect removes that account's receipt and its items; other accounts of the toolkit keep theirs.
A receipt does not prove external user identity, current connection status, or read permission. Readers must check these separately.
Neither Settings nor a source list can create a receipt. For an old Composio connection, the owner can confirm its exact account in Plugins after Comma reads the provider's own identity. The one-time member identity backfill also writes it when the Workspace has only ever had its owner as a member, the toolkit has exactly one active account, and the provider identity read accepts it as a personal account. With more than one account, the owner chooses one in Plugins; in a Workspace whose owner is its only member, source adoption reads each of them.
The confirmation attempt stores a generation, owner, account, provider identity, old receipt revision, and expiry in the existing Plugin Install Attempt. Comma checks these values again before it writes the receipt and queues source discovery. Cancellation, expiry, uninstall, or a later operation rejects the old attempt. An OAuth reconnection keeps the old account until the new connection completes. Completion then moves that receipt to the new account and retires only the account that the old receipt named. Other accounts of the toolkit, consented or not, remain.
An installation attempt cannot own this relationship because completion clears its provider state. A Plugin Installation does not exist during partial setup.
A Recommendation Profile cannot store it without creating default-UTC scheduling state before the first client read. The separate relationship avoids that side effect.
The collector has an internal member option for Linear and GitHub. For Linear, it pins the consented connection and reads the viewer's assigned, unfinished issues.
It checks the returned viewer and organization, rejects changed connections, and retains the subject beside model data.
The candidate window is at most 40 recently updated issues. It sorts admitted records by due date, priority, and stable ID before the byte bound.
The same request reads the member's Linear inbox. At most 10 unarchived issue and comment mentions from seven days lead the source, with the comment text as context.
GitHub verifies the live numeric user ID, then reads up to 40 assigned open issues/PRs and 20 requested reviews.
Review search uses the verified account's current login. It drops closed records and deduplicates the two sets.
It also searches open work updated in seven days that mentions that login, at most 10. The five newest read their comments and keep the latest one that names the member.
One GraphQL search reads up to 20 open pull requests that the login authored and updated in 30 days. Each keeps its draft flag, latest-commit check rollup, and review decision as context. A changed check or review result changes the pooled item.
It also reads the member's GitHub notifications from seven days, at most 20. Mention notifications stay with the mention search. Pull request, issue, and commit subjects link to their pages. Other subjects, such as a failed workflow run, link to the repository page that lists them.
One more GraphQL request reads the state and latest comment of the issue and pull request subjects of those notifications. The context then shows, for example, that the member's own pull request is merged and who commented last. An unreadable subject keeps the notification without them.
A record found by more than one request keeps its first relationship: requested review, mention, authored pull request, assignment, then notification.
All requests share the collector's existing per-source deadline. Subscription notifications (reason `subscribed`) do not establish work relevance.
Feishu and Lark read with the Workspace owner's own sign-in, made with the bot app that their scan created. The app's scan asks for the user scopes as well as the bot scopes.
Right after the scan, the same dialog shows a device code (RFC 8628) for the sign-in, as the official larksuite/cli does. No redirect URI is necessary.
Only the person whose scan made the app can confirm it: a sign-in whose `open_id` differs from the connect's owner is refused.
The grant is the Group's `feishu` or `lark` OAuth Binding under its own alias (`feishu-member`, `lark-member`), so an Agent's own credential of the provider never replaces it. It carries the Comma member receipt and the member as owner: a `credential_env` resolves it only for work done for them, and the connect's own reads as a signed-in person never list it. An MCP binding's `oauth_binding_refs` does not check owners yet, for any owned credential. It refreshes with that app (`app_source`), not a tenant provider app. Uninstalling the plugin deletes it with the bot and forgets its pooled items.
A sign-in that is not confirmed leaves the plugin installed. Plugins then shows the sign-in as not connected, and Connect asks again. An app made before the user scopes first gets a scan that updates it.
The read checks the token's `open_id` against the grant. It reads messages from seven days that mention the member, the member's direct messages, and calendar invitations of the next three days that wait for an answer.
Group and direct messages are fetched in separate batches, so a scope the app lacks for one leaves the other readable. The newest message in each chat stands for that chat. The member's own messages are never candidates. Feishu and Lark are member-only sources: generic collection does not discover them.
Unsupported member sources fail instead of using generic data. The runtime selects this path for profiles in member mode.
Member Runs read this collection through [Member Source Items](#member-source-items), the only member read path. A Run collects first when the pool is too old for it.
Runs retain private source subjects with evidence. Publication checks current bindings and copies subjects to the Profile.
Every public envelope rechecks those bindings before exposing a member snapshot. Mode changes cannot expose a snapshot from the other mode.
These checks observe Comma's current consent and connection state, not instantaneous provider-side revocation. Provider errors still fail collection.
Successful empty member reads skip model generation and publish no recommendation cards. Failed reads retain the existing failure or partial-source warning contract.
Composio member discovery selects the receipt's exact account. A newer account cannot replace it without confirmation or a completed OAuth reconnection. Composio member reads check the exact account's group, toolkit, and active status, then resolve its provider self identity.
Identity and member reads call each provider's official versioned API through a proxy session pinned to that account. Composio keeps the credential.
No Composio tool slug, argument name, or reshaped response is part of these reads. No other path replaces a failed request.
Member reads request independent relationships concurrently. Every member request, including GitHub, Linear, and Notion requests, ends by the source deadline.
A relationship that fails or runs out of time drops only its own items and adds a partial-source warning.
Only a failed identity read, or a source with nothing readable, fails the source. Comment reads that return 403 or 404 contribute nothing without a warning.
Slack rejects bot identities. In a seven-day window it keeps up to 20 mentions from other senders.
It also keeps the latest one-to-one direct message in up to 10 conversations, and up to 10 threads with the member whose latest message is from someone else.
Slack managed reads use the consented user token and verify the live user and team against the OAuth subject.
The [shared Slack reader](../../systems/apps/comma_web/lib/comma_web/recommendation_slack_member_source.ex) retains the same relationships and request bounds.
Discovery lists only the managed Slack binding. A Composio Slack account is never a Routine source. The Profile retains the member's enabled choice. Slack link previews and watch reads use the same binding.
Old Composio accounts remain stored. Without an active managed binding, existing Composio sources still need their exact consent receipt.
Gmail uses the authenticated mailbox and reads inbox threads from seven days addressed to it, whether read or unread.
It reads the 15 most recent important threads and the 15 most recent threads, each thread once.
Important threads come first. Ordinary mail cannot displace them from the important read window or precede them within the byte budget.
Important threads alone can still exceed that budget. All retained threads share the separate context budget.
Provider importance and social labels do not exclude a thread. The Router judges whether its evidence needs action.
A message the member sent later in the same thread closes it. One item per thread remains. Promotional, spam, and trash labels are excluded.
Calendar uses the primary calendar and keeps the coming week's self-organized or self-attended events, excluding declined and cancelled events.
Drive requires verified ownership for recently changed files. It does not treat all visible or shared files as personal work.
It also reads open comments by others that name the member's address on the five most recently changed files. A file without comment access contributes none.
Composio publication/display fences use the local consent receipt, not a remote provider probe. External account changes are observed at collection or source reconciliation.
Notion member reads need no configuration. The retired `member_source_rules` column remains stored but unused.
Notion verifies the token's user owner. It queries at most five task databases, which have a people property and a Notion status property.
An open item names the member in a people property and has a status outside the Complete group. The property name reaches the Router as the member's role.
It also reads at most five pages that the member last edited or created within seven days, with their outline and text tail.
On the five most recently edited pages, open comments by others from seven days that mention the member lead the source.
Each candidate relationship is necessary, not sufficient, evidence for a useful task. The Router must omit items without concrete member relevance or a reason to act.
The authenticated Settings form owns mode, never provider identity or consent. Routine does not read Comma long-term memory or work preferences. The retired `work_context` column remains stored but unused. Existing migration sources remain unchanged. Changes reuse source-revision invalidation and preserve the refresh schedule. The member draft compiler drops tasks without same-source evidence references and removes summary paragraphs not grounded in retained tasks. This guards grounding, not semantic relevance. Live-provider relevance, provider shape verification, and performance validation remain incomplete.

A member can dismiss one Routine row's source item: a row's "Don't remind me" in the apps, or the owner's Router through `recommendation.dismiss`.
The dismissal is a value on the Recommendation Profile, not another entity: a digest of the item's source ID and URL with its time.
The Profile keeps the 200 most recent. It reuses the source item's existing identity, the key that rows and attention items already carry.
Every envelope read leaves the item's rows, prompts and attention items out of the snapshot, as for handled mail. A member summary, which the server writes as one linked clause per item, loses only that item's clause. Any other summary keeps only its title and the paragraph break after it, because its prose can name the item without a link. Clients show no prose for that summary.
Later runs leave its URL out of the evidence the model may cite, and the proactive check settles its pool versions as `dismissed`.
A dismissal is a member preference. It does not resolve or hide the item at its source.

A member can also add a matter to Routine through the owner's Router (`recommendation.add`), such as a to-do from a checklist card's "加到例程" action.
An added matter is a value on the Recommendation Profile, not another entity: `{id, title, detail, url, addedAt}`, at most four, newest first.
Every envelope read with a briefing shows them as its first card (`routine-added`), then bounds the briefing to the card and row limits clients read; the briefing's last rows give way.
"Don't remind me" on a row with a URL removes the matter; the Router removes any by its id (`recommendation.remove_added`). No run reads or selects them.
The client that dismisses shows the answered envelope at once; other open clients, and any client after a Router dismissal, show it at their next envelope read.
A briefing in state `stale`, or made more than a day ago, shows when it was made.
Implementation: [Recommendations](../../systems/apps/comma_core/lib/comma/recommendations.ex).

A Recommendation is a product projection, not a Conversation Message.
Its prompt action fills a composer draft. The user must send it to enter the Chat path.
Every Routine row is a prompt action in both relevance modes. A row title is the member's own task.
Its composer text asks Comma for help with that task in the first person, such as "Help me decide...", so Comma does not take over the member's part.
The member selection prompt therefore asks for titles that start with their verb.
The draft compiler turns a text row that the model left as a plain source link into that request, followed by the link. Model-written prompts stay as written.
A row that stands for an existing Task, which is mail with a confirmed Task, opens that Task instead. It leaves the rail when the Task ends. A prompt row that only mentions a Task keeps its prompt.
Comma Workspace references a Synchronicity organization and default network. Salix owns the Group's Drive binding.
Workspace readiness requires Billing and Salix provisioning. Synchronicity availability affects only Drive operations, including Drive enrollment, browsing, and file access.
It cannot block Workspace bootstrap, tasks, chat, or other Workspace operations.
For configured standard Workspaces, [WorkspaceConvergence](../../systems/apps/comma_core/lib/comma/workers/workspace_convergence.ex) commits readiness and a separate [SynchronicityProvision](../../systems/apps/comma_core/lib/comma/workers/synchronicity_provision.ex) job together.
The existing Workspace owns its Synchronicity mapping. The job adds no entity or readiness authority.

The `comma_drive` queue runs at most two jobs per node and deduplicates unfinished jobs by Workspace. Each job has twelve attempts.
An exhausted or rejected Drive job leaves the Workspace active. `Comma.Synchronicity.enqueue/1` retries Drive setup after operator repair.
After rollout, release recovery pages retry failed Workspace provisioning under a new existing operation generation, with at most 100 Workspaces per page.
Recovery preserves Workspace, Billing, and Salix identities. It rechecks core provisioning before readiness and leaves the prior terminal operation intact.
A client with no Synchronicity node (the web client) reads the Drive through [Drive browse](../../systems/apps/comma_web/lib/comma_web/drive_browse.ex): the owner's hosted-replica view through the same binding, read-only. It is a read path, not another Drive identity.

### Agent migration import

Importing an export of another agent platform (OpenClaw, Hermes, Claude Code, Codex, Pi) adds no entity. It is a set of Router tools over the Agent Workspace, the Skill catalog and the Router's instructions.

- `migration.import` reads a zip the user uploaded to the Router VFS. Sizes are enforced while inflating. It leaves out known credential files (by name and private-key content), transcripts, logs and databases, stores every other file unchanged under `/imports/<platform>/<stamp>/files/` and writes `manifest.json` with one entry per file. Its writes carry the zip's own audience. It copies dated logs to `/memory/episodes/` and, where the Group does not label files, creates one Group skill (origin `imported`) per skill folder whose id and name are free.
- The `agent-migration` built-in skill places the rest with `memory.write`, `skill.create` and `migration.append_instructions`, and records each outcome with `migration.resolve`. Appended persona text goes into one delimited section per import in `router_system_prompt`, after the instructions the Router ran with; a repeat call replaces that section only. Only a person writing in the Comma app can cause it.
- `migration.finish` fails while any manifest entry has no outcome or `/memory/index.md` is older than the import. It then writes `REPORT.md`.

Owners: [Migration](../../systems/apps/salix_agent/lib/salix_agent/migration.ex), [platform layouts](../../systems/apps/salix_agent/lib/salix_agent/migration/platforms.ex), [tools](../../systems/apps/salix_agent/lib/salix_agent/tools/migration.ex), [skill](../../resources/salix-system-files/skills/agent-migration/SKILL.md).

## 7. Devices and compute

| Concept | Meaning and boundary |
| --- | --- |
| Device | A stable managed device identity. Device connectivity does not establish runtime authentication or readiness. A user's Device that never connected and has every credential revoked is deleted at that user's next credential mint on the same surface. At that mint, a user's Device of the Group that is offline with no activity for more than 30 days is removed with its credentials revoked ([Registry.sweep_devices](../../systems/apps/salix_env/lib/salix_env/registry.ex), [ConnectorTokens.remove_device](../../systems/apps/salix_env/lib/salix_env/connector_tokens.ex)). A Device without an owner, such as a Group's Cloud VM, does not expire. |
| Connector | The part of the station that connects device capabilities and runtimes to Salix. People and Agents only ever see it called the station; `connector` remains in code names, wire fields, metrics and logs. A live Connector run is not a new device identity. A run holds one Connector credential of its Device at a time, recorded on the Device; it can switch to the Device's newest credential on its own socket, and it ends when the credential it holds expires or is revoked ([Registry.renew_run_credential](../../systems/apps/salix_env/lib/salix_env/registry.ex), [systems/station/README.md](../../systems/station/README.md)). |
| Command Environment | An execution environment selected within one Device. |
| Compute Pool / Node | Resource supply and a node that provides compute. Neither is the business Workload identity. |
| Compute Environment | A stable Project, Swarm, or Group ownership boundary. It is not an Allocation or a device query alias. |
| Workload | Stable work within Compute. New Workloads are shell, meeting_runtime or service; `external_worker` Workloads remain readable; default lists show only those that need recovery or cleanup. |
| Allocation / Runtime Instance | Resource allocation and a particular execution instance. Allocation.generation fences allocation authority. RuntimeInstance.connection_epoch fences container execution. Agent VMM Registration owns the current control connection. Host Session.connection_epoch must match it. Host reconnect preserves the allocation generation and execution identity. Only a meeting_runtime is fenced to one container instance; after a Guest restart, another Workload adopts the new instance of its verified container generation. Explicit release or revoke retires allocation authority. These facts do not replace Environment or Workload identity. |
| Agent VMM Registration | The tenant/group/Host authorization relationship, owned by [AgentVMM](../../systems/apps/salix_store/lib/salix_store/agent_vmm.ex) and [Registration requests](../../systems/apps/salix_store/lib/salix_store/agent_vmm_registrations.ex). It owns the request idempotency key, short-lived claim ticket, original product owner and delivery target, Host commitment, credential hash, initial Shell key, current gateway, connection epoch and connected state. Its Environment supplies the existing Project/Workspace owner. Installation Operation is retired into this relation, without a second ID or material handoff lifecycle. One Host identity can have independently authorized Registrations. ProviderBindings select execution configuration, not independent connection authority. |
| Compute Grant / Service Route | Compute access authority and service access routing. A Compute Grant is not a Billing Credit Grant. |
| Station | A Comma station in one Salix Group (a Comma Workspace's or a BridgeForTeams Project's), reached directly by members with an offline-verified credential. It is not a Device or Connector. See [Station](#station). |
| still.fail station | A still.fail station connected to a Group through its Comma connect: a Device of the Group that takes Tasks and sends its still.fail workspace's statistics. It is not a Station: that workspace stays in still.fail cloud and Salix is not its control plane. See [still.fail station](#stillfail-station). |
| Device Setup Offer | An offer in Home to set up one unprovisioned Comma device that a member's phone found nearby. It is not a Device: the device has no identity in Salix until it connects. See [Device Setup Offer](#device-setup-offer). |
| Device Secret | A Group's named, write-only key for one device on the user's local network, such as a miIO token. It is not a Device, a Connector credential or a Provider Credential. See [Device Secret](#device-secret). |

A Host identity has one public deviceId and its root proof key. They are not separate installation entities.
The public name remains stable for existing protocol references. A root value alone does not grant any Registration's authority.
A single claim binds a preauthorized Registration to that Host and a credential the Host already saved.
Registration recovery verifies current product authorization and the original root, then replaces the credential and fences the previous connection.
Comma retains its original subject constraint. BFT uses current Project management and exact Runner/organization ownership.
Seven days without authenticated contact rejects the old credential, not the Registration's durable identity or Workloads.
Explicit revocation and local disposal remain terminal. Ticket cleanup preserves the original request's idempotency fact.

Protocol compatibility is a value of the existing connection, not a new identity or lifecycle owner.
The Controller accepts its implemented protocol range and reports unsupported operations at that boundary.
Main interprets helper results where it consumes them. It does not probe versions as a global installation gate.
Diagnostic reads, exact drain/removal, and target-bundle recovery remain available where supported.
Version mismatch does not authorize workload termination, replacement of identity or data deletion.
Native receipts own local side effects. Main's intent and UI are projections, not separate lifecycle authorities.

Internal Workspace member Agents select shared Shell Workloads per call through `workload_id`.
[Comma.ComputeAgentAccess](../../systems/apps/comma_core/lib/comma/compute_agent_access.ex) owns membership and Project Environment scope checks.
The [ComputeAccess seam](../../systems/apps/salix_agent/lib/salix_agent/compute_access.ex) supplies bounded discovery and authorization to Compute tools.
Workspace authority replaces per-Agent Grants for shared runtime and workspace operations only. It does not authorize private runtime carriers or service routing.
The Virtual Compute plugin provides discovery and process tools by default. An explicit Workspace plugin disable blocks both tool families.
Selection is a tool argument, not a new binding or entity. Disabled targets and stale allocation generations fail closed.
`compute.workloads.list` returns at most 20 entries with name, kind, template, capabilities, observed state, network policy, resource limits, and a cursor.
Discovery performs no Host probes. Observed readiness is not a guarantee of current execution availability.
Authorization precedes credential resolution. No default target or automatic Grant is created.
Shell commands use the current fenced Agent VMM Host session.
[AgentVMMHostClient](../../systems/apps/salix_store/lib/salix_store/agent_vmm_host_client.ex) retains execution ownership operations.
Host session expiry, registration revocation, allocation generation, connection epoch, and runtime update pauses still apply.
Future shared types must declare supported capabilities. Missing targets and denied workspace access return public actionable errors.
A supplied target cannot redirect an explicit Grant. Invalid Grants cannot fall through to Workspace authority.
[Compute tools](../../systems/apps/salix_agent/lib/salix_agent/tools/compute.ex) retain explicit Compute Grant checks for service routing and grant-based callers.
Expired or revoked grants fail closed.

Cloudflare Group execution reuses the original Agent tool DependencyJob while the VM becomes ready.
The existing Workload `runtime_selection_until` value bounds pre-dispatch demand.
Concurrent callers extend that hold with a maximum. Cancellation does not clear another caller's hold.
The default exec readiness budget is five minutes. Each admitted waiter reads only its target, at most once per second.
Existing DependencyAdmission limits concurrency. Direct operational dispatch remains immediate unless it opts into waiting.
After readiness, the existing Workload operation admission precedes one exec dispatch. Unknown sent results cannot replay.
No new command queue, Workload identity, or execution owner is introduced.

An Agent VMM Controller installation is a provider execution fact. It is not a
Compute Node, Environment, or Workload. The existing project and provider
relationship selects the installation. Agent VMM owns the installation, volume
identity, encryption key, and location conversion. VMMD owns the Guest image,
loop device, LUKS mount, and exact deletion. The Controller container receives
only its mounted data directory.

Owners and entry points:
[Comma.Devices](../../systems/apps/comma_core/lib/comma/devices.ex),
[SalixEnv.Control](../../systems/apps/salix_env/lib/salix_env/control.ex),
[Compute authority](../../systems/apps/salix_store/lib/salix_store/compute.ex),
[ComputeContract](../../systems/apps/salix_store/lib/salix_store/compute_contract.ex),
[ServiceRoutes](../../systems/apps/salix_store/lib/salix_store/service_routes.ex).

[ChatDevices](../../systems/apps/comma_core/lib/comma/chat_devices.ex) is a read-only Device projection for authorized private chats.
It adds no Device, Conversation, Task, or authorization owner.
One replaceable navigation record per IM Connect stores up to six device IDs and two opaque cursors, at most 16 KiB.
The record has a fifteen-minute logical expiry. It contains no device facts, credentials, or authority.
A random list marker identifies a displayed list only. It rejects stale numbered choices, including concurrent page changes.
Comma rechecks the current User/Workspace binding and exact Device scope on each action.
Reads do not probe devices. Loss of this disposable projection requires a new list command, without loss of product facts.
No physical deletion deadline or exactly-once provider reply is claimed.

### Station

A Station runs on a user's machine, a Group's managed Workload, or a Task's isolated sandbox in one Salix Group. Tasks run on two kinds of environment: a Station on the user's or Group's own hardware, or a sandbox the platform manages ([execution environments](../compute-devices.md#execution-environments)).
The Group is the station's workspace: the Group id is the `workspace` a station holds and the `ws` of a member credential.
Salix is the stations' control plane: it replaces still.fail cloud's control plane and also provides Cloud VM stations.
It is an experimental integration. Membership is the owning product's: Comma's User, Auth Session, Workspace and Membership, or BridgeForTeams' Organization and Project roles.
A Station owns its sessions, chats, and agent processes. Device, Connector, and Inbox identities do not represent these ownership duties.
Members reach the Station over iroh with a member credential. Salix delegates Tasks through the authenticated Station protocol.
On a machine with a Station, no device-side Connector is installed by this integration.

- Identity: the hex Ed25519 public key of the station (its iroh node id). Every signed request proves it.
- Scope and owner: [SalixStore.Stations](../../systems/apps/salix_store/lib/salix_store/stations.ex) owns `salix_stations` (keyed by tenant and Group, `kind` `device` or `cloud_vm`, `enrolled_by` an opaque product user id),
  `salix_station_signing_keys` and `salix_station_revocations` (per Group). It holds no membership logic. Every Group has a roster, whichever product owns it.
- Members: the product that owns a Group answers a user's role in it, and the Group's name, through [SalixStore.StationMembers](../../systems/apps/salix_store/lib/salix_store/station_members.ex)
  ([Comma.Stations.Members](../../systems/apps/comma_core/lib/comma/stations/members.ex): Membership role and Workspace name; [BridgeForTeams.StationMembers](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/station_members.ex): Organization owner/admin, else Project role, and Project name).
  Any role but a read-only one (Comma's `viewer`) enrolls a station, which is then theirs (`enrolled_by`); a manager role (owner, admin) renames and removes; any role lists and gets credentials.
  The same port answers whether the Group's workspace is in use: an active Comma Workspace; an active Project that is not archived, in an active Organization.
  While it is not, the Group's stations get 404 as removed ones do, the control plane places no Cloud VM station there, and no notice is pushed. The rows stay. A Group no product owns is refused by no one.
- Agent account source (a value in the station's config, not an entity): each Workspace and runtime (Codex, Claude Code) has `none`, `local`, `endpoint` (a model server the computer reaches, such as Ollama on localhost; its address stays on the station) or `workspace`, default `none` until the person chooses ([sources.ts](../../systems/station/src/accounts/sources.ts)).
  `local` uses this computer's own login. The station reads `~/.codex`, `~/.claude` and their session folders only while some Workspace has `local` for that runtime. `workspace` uses only the accounts Salix lends through that Workspace's desktop connection. `none` refuses new sessions with a reason and keeps existing ones. Sources never mix.
  Machine profiles from before this contract count as `none` until the person chooses `local` again. The desktop app reads and sets sources through the station's local admin interface (a 0600-token Unix socket or named pipe, address in `run/local-admin.address`), not over the mesh.
  Over the network a source changes only one way: to `local`, by the computer's owner, after the owner answers a confirmation in a Comma conversation. [device.ask_local_account](../../systems/apps/salix_agent/lib/salix_agent/tools/device_connection.ex) posts a question card whose wording and choices the server writes, naming the computer and the runtime. The Message carries the server-only binding `local_account {device_id, runtime}`, which no Agent parameter can set ([SalixWeb.LocalAccountChoice](../../systems/apps/salix_web/lib/salix_web/local_account_choice.ex)).
  `device.use_local_account` acts only on the turn whose sealed input is the owner's answer to that card picking `use_local_account`, and only for the bound computer and runtime. Salix then sends `account_source {runtime, source: "local", by}` on that Workspace's desktop connection, which sets the source of the connection's own Workspace only and answers once the login's profile is checked. A station that does not report `account_source` 1 is refused before it is asked. Another member, another answer, another computer or runtime, or no answer changes nothing; `none` stays `none` until the owner chooses.
- Change notices: whoever changes the roster, keys or revocations tells the presence sockets through [SalixStore.Stations.Events](../../systems/apps/salix_store/lib/salix_store/stations/events.ex), over the PubSub that `salix_store` itself runs.
  Every node that can write the roster runs it, whichever subsystems the node serves, so a revocation written on a node that serves no stations reaches the node that holds the socket.
- Wire: [Comma.Stations](../../systems/apps/comma_core/lib/comma/stations.ex) serves the `/v1/comma/stations/*` contract (provider `comma`) from Salix's rows. A Comma client names its Comma Workspace; the Workspace gives the Group.
- Move from Comma's tables, in one rolling release: [Comma.Stations.SalixCopy](../../systems/apps/comma_core/lib/comma/stations/salix_copy.ex) copies Comma's rows, keys (same kid and key material) and revocations to each Workspace's Group. The marker `station_roster_v1` in `salix_cutover_markers` says the phase.
  The owner chose a rolling release with transition code over the `exclusive` release mode for this move. This is an exception to the rule against rolling-window readers in [release operations](../release-operations.md#data-safety-and-recovery), for this release only.
  1. Before the rollout, online migration `20261011100001_open_station_roster_window` makes Salix's rows Comma's and writes phase `window`.
  2. During the rollout, servers of the release before still write `comma_stations`, `comma_station_signing_keys` and `comma_station_revocations`. Servers of this release write Salix's tables and never Comma's.
     [Comma.Stations.Window](../../systems/apps/comma_core/lib/comma/stations/window.ex) merges Comma's rows into Salix before each read: a station's lookup, a Group's roster, the `state` frame, a credential, an enrollment.
     A merge adds what Salix lacks, takes a later enrollment, applies a removal made after Salix's enrollment, keeps the later time of a revocation, and adds a signing key (to verify only when Salix already has a key of that status). It never undoes what a server of this release wrote.
     Sockets of this release also hear Comma's PubSub (Workspace-id topics), and removals, revocations and replaced sockets are told there too. Presence counts sockets on either kind of server, and a device tool call goes to the PubSub the station's socket listens on.
  3. After the rollout, the release's post-rollout job (`comma-release finish-agent-configuration`, the page of `Comma.Release.transfer_agent_configuration_page/1` after Group Compute and Cloudflare locations) runs `SalixCopy.finish/1`: one last merge, then phase `complete`.
     From then on `Window` answers from one cached read of the marker and reads neither Comma's tables nor Comma's PubSub. Compose (`Comma.Release.migrate/0`, stack stopped) goes to `complete` at once.
  An enrollment token is redeemed only by a server of the release that issued it (the old one names a Comma Workspace, the new one a Group): during the rollout a refused token is issued again.
  Not carried over the window: a station renamed through a server of the release before; a signing key activated, replaced or removed there (operator commands only; run none during the rollout).
  Rollback: servers of the release before do not read Salix. A station enrolled, removed or renamed and a revocation written through this release's servers are unknown to them. Before they start again after `complete`, run `SalixCopy.reopen/0`, so that what they write is merged when this release returns.
  The release after this one deletes `SalixCopy`, `Window`, the three Comma schemas and the post-rollout page. A later release drops the tables.
- Workspace id: the `workspace` of the enroll answer and the `state` frame, and the `ws` of a member credential, are the id Salix keeps for the Group in `salix_station_workspaces`
  ([SalixStore.Stations.Workspaces](../../systems/apps/salix_store/lib/salix_store/stations/workspaces.ex)). No product code computes it. A Group with no row is told its Group id.
  The move writes a row for each Comma Workspace that has a station which is not removed, with the Workspace id: those stations and their clients' credentials see no change.
  Every other Group (each BridgeForTeams Project, a Workspace with no station, a new one) is told its Group id.
  `Workspaces.rename/3` changes the id a Group is told and adds the id before to the row's `previous_ids`, which is only added to. The frame and the enroll answer carry them as `workspace_was`, oldest first.
  A station takes a new `workspace` whose `workspace_was` leads back to the first id it has as the same workspace: it keys remote jobs, their directories and its peer requests by that first id, and admits credentials, peer requests and tool calls under any of the ids
  ([station docs](../../systems/station/docs/cloud.md#control-planes-stillfail-cloud-comma)). A desktop client that kept a credential a station refuses asks for a new one, once.
  A later release renames the Comma rows to their Group ids. It is that data change only, for a Group whose every station that is not removed reports (`salix_stations.version`, sent at each connect) a version that knows `workspace_was`.
- Lifecycle: a single-use, one-hour enrollment token ([OneTimeCredentials](../../systems/apps/comma_core/lib/comma/auth/one_time_credentials.ex)) admits it.
  Re-enrollment into the same Group is idempotent; into another Group moves it. Removal sets `removed_at`; the station then gets 404 or close code 4004.
  A new token takes a removed station back.
- Managed execution locations: a Group can have one VMM Station per authorized Host registration and a Cloudflare Station.
  [ComputeGroupStation](../../systems/apps/salix_store/lib/salix_store/compute_group_station.ex) prepares `station.default` in the authorized Host's existing Compute Environment.
  The Workload is a `service`, owned by its Group. Its owner relation adds no entity.
  Registration and Environment generation scope its identity. Repeated Host observations reuse it; replacement registrations cannot inherit its commands.
  A stopped or deleting Station Workload is not recreated by an observation.
  New Group Cloud VMs use Cloudflare. Existing Group Workloads keep their provider, archive, device identity, and accepted Tasks.
  Preparation resolves the exact registration and its Environment, independently of other Hosts. A valid legacy Group VMM Station on that registration is reused.
  Multiple eligible Host registrations still return an automatic-placement conflict. Explicit Station targets retain their selection.
  The VMM image exclusively creates a missing configuration with `tools.access: full` before startup. Existing configurations, including off/read and malformed files, remain untouched. Physical Stations default to off.
  Configuration follows the existing `COMMA_STATION_CONFIG`, `EMBER_CONFIG`, then data/config.json precedence. The existing owner/admin API controls later changes.
  Comma and BFT share placement; each product owns its installation and member authorization.
- Managed Station admission: the control plane places the Station identified by an authenticated Workload connection.
  `SalixStore.ComputeStation` derives the connection target from the current Workload and its Group or Task owner.
  Connection registration, credentials, platform model access, and new commands use that target and current owner authorization.
  A stable Device does not authorize an older Workload generation. Terminal or replaced connections cannot obtain new credentials.
  Owner-specific readiness and recovery remain in `ComputeGroupStation` and `CodingSandboxes`. This projection adds no stored entity.
  For Group-owned Workloads, [StationPlace](../../systems/apps/salix_web/lib/salix_web/station_place.ex) asks for the key and admits it into the Group roster.
  Coding Task Stations remain addressed by their Task Device under the Sandbox lifecycle.
  Roster admission and the exact Workload's `station_id` update commit together. The key records admission, not a peer acknowledgment or online status.
  A lost placement acknowledgment retains this association for retry. A replacement removes only that Workload's previous Station key.
  Other managed Stations in the same Group remain. A key in another Group is refused.
  `enrolled_by` nil identifies control-plane placement.
- Station Device lookup: `station_device_lookup` projects the existing `(tenant_id, group_id, device_id)` relationship to a proved Station key and device owner.
  Verified relay registration writes it. Indexed Group and owner lookup reads one bounded candidate page.
  Each candidate is checked against its exact Registry record and product membership before admission.
  The projection adds no entity or authorization authority. One desktop Station can have Device relationships in several Groups.
  Device deletion removes its projection; a later verified registration rebuilds a missing row.
- Online is a projection: an open presence socket on any node, tracked by [StationPresence](../../systems/apps/comma_web/lib/comma_web/station_presence.ex). It is not stored.
  Where an online station's mesh endpoint may be reached (its home relay and direct addresses, which it sends in a `reach` frame when they change) is kept in that presence entry only.
  Its peers get it in `peers` and clients in the stations list and `station` events. These are dialing hints: iroh authenticates the station by its key. They go when the socket goes.
- Station Task index: a projection of the Tasks a station hosts (its own page chats, [station docs](../../systems/station/docs/tasks.md)), not an entity. The station owns the Tasks and their status.
  Salix keeps the latest copy so members and the Router can list them while the station is offline: [SalixStore.StationTaskIndex](../../systems/apps/salix_store/lib/salix_store/station_task_index.ex), table `salix_station_task_index`, keyed by station id and thread.
  A row holds the Task's title, status (`in_progress`, `needs_review`, `done`, `cancelled`, `archived`), creator, times, runtime, model and labels, and no message text. Its labels are the Group's label ids a person set on the station (`PUT /threads/:id/labels`, at most 20); the station owns them as it owns the status. A still.fail station's row also says what the chat asks of whom (Chats as station-hosted Tasks, below): `attention`, `waits_for`, `note` and `url`, none of them from a station from before. A participant thread (`TASK/…`) is never indexed.
  The station sends pages on its Connector run (`task.index`, [SalixWeb.StationTaskIndex](../../systems/apps/salix_web/lib/salix_web/station_task_index.ex)) after it proves its key with `relay_register`, and only while it is an active station of the run's Group; else the answer is `not_this_group`.
  The station's connector ([task-index.ts](../../systems/station/src/connector/task-index.ts)) first asks what Salix holds with a page of no rows, sends what Salix lacks (all of it with `reset` for another epoch), and again after the station's writes move the index. A tombstone goes once the Salix of every connection holds it. A refusal other than `rate_limited` ends the sending until the next connection.
  Rows are numbered by revision within an epoch (`salix_stations.index_epoch`, `index_through`). A reset replaces the rows and a tombstone deletes one; a page Salix cannot continue from is not applied, and Salix answers what it holds.
  A page carries at most 200 rows and 64 KiB, a connection sends at most 4 pages a second, and a station holds at most 10,000 rows. Salix stamps the run's Device on each row.
  Removing the station, or moving it to another Group, deletes its rows. A Device that expires does not. The Device records the station its Connector proved (`station_id` in [Comma.Devices](../../systems/apps/comma_core/lib/comma/devices.ex) rows).
  Comma lists a Group's rows at `GET /v1/comma/groups/:group_id/station-tasks` (members, not a session restricted to one conversation; latest activity first, at most 500), and a task list stream opened with `?with=station_tasks` also says `station_tasks_invalidated` when a page changed what Salix holds ([Comma.Conversations](../../systems/apps/comma_core/lib/comma/conversations.ex) `station_tasks/3`).
  The client core keeps the last list read per workspace on the device (Account table `station_task`) and shows it as the `stationTasks` topic, read again while shown when that stream says so ([station-tasks.ts](../../clients/packages/core/src/station-tasks.ts)).
  Comma's owner collection chain (every 15 minutes) hands each row that concerns the workspace owner to the owner's Router as a Home matter (account `station_task`), once per stop, and closes it when the row no longer concerns the owner ([CommaWeb.ProactiveStationTask](../../systems/apps/comma_web/lib/comma_web/proactive_station_task.ex)). A row with an `attention` concerns the people in its `waits_for`, whoever created it; a row with neither (a station from before) concerns its creator while it is `needs_review` and active in the last 7 days. The matter links the row's `url` and quotes its `note` to the Router as the agent's own words; a `need` or `failed` of the last 7 days is urgent (`high`), the rest `normal`, and the owner's automatic handoff budget bounds how many reach the Router a day.
  The Tasks page lists them beside the Tasks Salix keeps, with the machine and model each runs on. The desktop app, which reaches the machines, makes a Task on one (`stations.newTask`, [tasks.ts](../../clients/packages/core/src/stations/tasks.ts)) and opens it on its station; other apps list them only.
  A Router sees the rows in `im_api.internal.task.list` (`station_tasks`, first page only), and reads and writes in such a Task through the station's Connector (`station:<station_id>:<thread>` as `conversation_id`; `task.read`, `task.say`, [SalixWeb.StationHostedTasks](../../systems/apps/salix_web/lib/salix_web/station_hosted_tasks.ex)); the Messages stay on the station, and a station that is offline answers neither. What a station says of its own Task carries no IFC label: the IFC check reads it as an unlabelled read (agent-private), and decides a write into it as a write into a Conversation whose audience Salix does not know.
- Station Stats index: a projection of a station's statistics in one structure, not an entity: what its agents spent (by day, chat, person, account, runtime and model: calls, tokens, cost at list prices) and the chats they worked in.
  Each row names its `source`: `self`, the station's own records, or `stillfail`, what a [still.fail station](#stillfail-station) sends of its workspace. Salix keeps the `source` dimension.
  The station builds the rows of the last 31 days as it starts, a minute after usage is recorded and every hour, and sends them as it sends its Task index (`stats.index`, the same epoch/rev pages and rate; [SalixWeb.StationStatsIndex](../../systems/apps/salix_web/lib/salix_web/station_stats_index.ex)).
  Salix keeps the latest copy in `salix_station_stats_index` ([SalixStore.StationStatsIndex](../../systems/apps/salix_store/lib/salix_store/station_stats_index.ex)), its epoch and revision on `salix_stations` (`stats_epoch`, `stats_through`), a still.fail station's in `salix_stillfail_stations`; removing or moving the station, or removing the still.fail Device, deletes its rows.
  [SalixStore.StationStats](../../systems/apps/salix_store/lib/salix_store/station_stats.ex) adds a Group's rows up by person, model, day, source or station and lists its chats; BridgeForTeams reads it through `BridgeForTeams.Salix.Client.station_usage/5` and `station_tasks/2`; the Agent Swarm still.fail page ([DashboardSwarmStillfail](../../systems/apps/bridge_for_teams_web/lib/bridge_for_teams_web/controllers/dashboard_swarm_stillfail.ex), `clients/apps/bft/src/SwarmStillfailPage.tsx`) lists the swarm's still.fail stations and the last 30 days' usage by person, gives the line a new one connects with, and removes them.
- Member credential: an EdDSA JWT (`iss=comma`, `typ=comma-member+jwt`, 30 days, never past its session's expiry) bound to the user, the Group (`ws`), the product's role, the client iroh key and the session
  ([Credential](../../systems/apps/salix_store/lib/salix_store/stations/credential.ex), `SalixStore.Stations.issue_credential/5`).
  [SigningKeys](../../systems/apps/salix_store/lib/salix_store/stations/signing_keys.ex) owns the Ed25519 keys (KEK custody and pending/signing/verify_only rotation as for the OAuth IdP).
  [Revocations](../../systems/apps/salix_store/lib/salix_store/stations/revocations.ex) keeps `sid` and `sub` rows per Group. The product names the Groups:
  Comma writes `sid` rows when an Auth Session is revoked or signed out and `sub` rows when an account is disabled ([Comma.Stations.Revocations](../../systems/apps/comma_core/lib/comma/stations/revocations.ex));
  BridgeForTeams writes `sub` rows when a member is removed from a Project or an Organization ([Memberships](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/memberships.ex)).
  The product's database and Salix's are separate: the rows are written before the product's change commits, and stations are told after ([Events](../../systems/apps/salix_store/lib/salix_store/stations/events.ex)).
  Stations are told revocations of the last 31 days. They are values on the existing session and membership lifecycles, not new identities.
- Push: station notices reuse the Auth Session-owned APNs `device` addresses through [Notifications](../../systems/apps/comma_core/lib/comma/notifications.ex). Recipients are active members of the Comma Workspace that is the station's Group, matched by email.
- HTTP and presence: [StationEndpoints](../../systems/apps/comma_web/lib/comma_web/station_endpoints.ex) and [StationSocket](../../systems/apps/comma_web/lib/comma_web/station_socket.ex).
- Defaults ([Config](../../systems/apps/comma_core/lib/comma/stations/config.ex)): the control plane is on wherever a KEK exists.
  The KEK is `COMMA_STATION_SIGNING_KEK`, else HKDF-SHA256 of the subscription storage key under a station label.
  The origin is `COMMA_STATION_ORIGIN`, else the request's own ([StationOrigin](../../systems/apps/comma_web/lib/comma_web/station_origin.ex)).
  Relays default to n0's public iroh relays and the release manifest to still.fail's stable `station.json`.

The wire contract is shared with the still.fail repository, whose stations can enroll here:
signed requests carry `x-comma-station-station`, `x-comma-station-ts` (300-second window) and `x-comma-station-signature` (Comma also takes the same names under `x-stillfail-`, what still.fail stations and stations from before the rename send) over `<tag>:<origin>:<station>:<ts>:<sha256hex(body)>`;
enrollment is `POST /v1/comma/stations/enroll` signed over `comma-station-enroll-v1:<origin>:<token>:<station>`;
presence is `GET /v1/comma/stations/connect` signed over `comma-station-connect-v1:<origin>:<station>:<ts>`, with `state` and `revoke` frames, the station's `reach` frames, and text `ping`/`pong`;
clients use `/v1/comma/stations/me`, `/v1/comma/workspaces/:id/stations` (list, rename, delete, SSE `events`) and `/v1/comma/workspaces/:id/station-credential`;
stations post notices to `/v1/comma/stations/notify` and read `/stations/install.sh` and `/stations/releases/station.json`.
Station bundles are the Comma station's standalone release (`systems/station/README.md`). A Comma release pins the manifest of its revision; the installer downloads the manifest's artifact
(checked against its sha256 when given) or the release-base bundle built from the pinned commit, and refuses anything else.

User devices are stations. This adds no entity: a new device joins as a station.

- Install: [SalixEnv.DeviceInstall](../../systems/apps/salix_env/lib/salix_env/device_install.ex) asks [Stations.DeviceInstall](../../systems/apps/comma_web/lib/comma_web/stations/device_install.ex).
  Settings > Devices and the Router install tool (`device.create_station_install_command`) return the one-hour station enrollment command (`kind: "station"`) and create no Connector credential.
  The enrollment is issued as the member who asked (the signed-in user, or the requester of the Router tool turn: for a chat app's user, such as a Slack user, the Comma account of their [Provider User Link](#task-request)), who must not be a read-only member (`requester_required`).
  A Group that is not a Comma Workspace, a request that names no member, no known public origin, or a control plane without its signing keys answers `station_install_unavailable`: the computer joins through the Comma desktop app.
- Workers: a device Worker is bound to its device's station ([Station Binding](#station-binding)); the External Runtime path is retired for new Workers. A Task runs on a station through `runs_on` or its Worker's binding ([SalixWeb.StationTasks](../../systems/apps/salix_web/lib/salix_web/station_tasks.ex)), over the device's live Connector run; what the station's Session writes is the Worker's (`metadata.kind = "station_task"`), and Salix answers only the device whose Session takes part.
  Giving a station or the Cloud VM a Task is the `station.session` egress of `SalixAgent.IFC.Destination`, a public destination. In a Group in IFC `enforce` mode, a Task an agent makes goes there only when the sources its `task.create` declared are public (`private_sources_to_machine`, `SalixIM.TaskPlacement`). A sandbox of the Task's own is read by the Task's person, as the Task is, so it takes any Task. A Task a person makes in a product is not checked.
- Tool transport: device tool calls ride the station's presence socket by default ([StationTools](../../systems/apps/comma_web/lib/comma_web/station_tools.ex), `tool` and `tool_result` frames).
  `COMMA_STATION_TOOLS_TRANSPORT=gateway` switches them to the separate iroh gateway ([Gateway](../../systems/apps/comma_web/lib/comma_web/stations/gateway.ex)); both carry the same §8 request and response.
- Station tools read stations through [GroupDirectory](../../systems/apps/comma_web/lib/comma_web/stations/group_directory.ex), the control plane's rows and presence.
  Internal Router and Worker calls use the same current member authority through `station.*` and `env.*` Station targets.
  Direct commands and relative files use `home/.comma-work/<scope>` for the stable Workspace key, Agent, and conversation.
  The existing `workspaceKey` normalizes renamed Workspaces. The directory name only encodes this scope and adds no identity or security boundary.
  Explicit relative working directories resolve under that scope. Absolute paths still address shared files. `HOME` and existing files do not move.
  Incomplete contexts retain home-relative behavior. Process results show cwd and the original caller context for coordination.
  These directories prevent accidental conflicts. They do not restrict authorized commands or process ids. Agents stop only their own processes.
  Delegated Station chats retain their existing separate Session workspaces. Sandbox callbacks retain their closed tool allowlist.
  Agents see the `station.*` tools only when the gateway is configured and their Group has a station. The requester must have a role in the Group.
  In a Comma for Teams Project, a Feishu or Lark sender without a member's account also has the Project role `user` when the Project's chat app is available to them (the app's availability range, which the tenant's administrators set) and they have an organization email (owner decision, 2026-11-12; [SalixStore.StationMembers](../../systems/apps/salix_store/lib/salix_store/station_members.ex) `app_member_role/2`, [CommaWeb.Stations](../../systems/apps/comma_web/lib/comma_web/stations.ex)). They sign in nowhere; the station gets that email as the caller (`user_email`, `requester_email`), and `user_id` `<provider>:<connect>:<open_id>`.
  The threat is anyone in a chat with the bot running commands on the Project's computers. The authority is Feishu's or Lark's visibility check of the app for that person, asked on every station call (application permission `application:application:self_manage`), so an administrator's change applies to the next call; only name and email are kept, for at most an hour ([AppAvailability](../../systems/apps/salix_im/lib/salix_im/provider/feishu/app_availability.ex)).
  It fails closed: outside the range, no email, a missing permission or a failed check refuse the call (`requester_refused`), and the model is told who can fix it. Comma Workspaces keep needing an account.

<a id="stillfail-station"></a>

### still.fail station

A still.fail station is a still.fail station connected to a Group through its Comma connect (AFK-surf/still.fail `station/src/comma/`).
It is a Device with a connector credential (device `meta.device_kind` `stillfail`, named still.fail), not a Station of the roster: its workspace stays in still.fail cloud and Salix is not its control plane.

- Identity and scope: the Device, in one Group. [SalixEnv.StillfailDevices](../../systems/apps/salix_env/lib/salix_env/stillfail_devices.ex) makes one with the line its station connects with, `comma <server> <token>`, shown once, lists the Group's, and removes them. Comma's still.fail plugin ([CommaWeb.PluginConnections](../../systems/apps/comma_web/lib/comma_web/plugin_connections.ex)) makes one for the installing member, and the CFT Agent Swarm still.fail page for the swarm's Group. A member pastes the line into the station's connects.
- Tasks: the station dials `/v1/connect` and speaks the Tasks protocol as a Comma station does (`task.invite`, `task.put`, `task.post`, `task.status`, `task.leave`, `task.hello`). Each Task is a still.fail chat whose people are the Task's. `task.put` names a person author by `name` and `email` where the Group's product knows them (`SalixStore.StationMembers.member/3`), and a `task.post` may carry a `question`, which becomes the Message's question card.
- Statistics: on the same run the station sends the Stats index of its still.fail workspace, source `stillfail`: the usage and chats of the last 31 days of each station of that workspace, a person by their email where still.fail knows it. Salix holds the epoch and revision in `salix_stillfail_stations` ([SalixStore.StillfailStations](../../systems/apps/salix_store/lib/salix_store/stillfail_stations.ex)), and the rows under `station_id` `stillfail-<device>`. A Station keeps those on its own row; such a Device has none, and a Station row would put it on the roster. A run proves no station key, so Salix takes its pages as the Device's only when the Device says `device_kind` `stillfail` ([SalixEnv.StillfailDevices](../../systems/apps/salix_env/lib/salix_env/stillfail_devices.ex) `station/1`).
- Chats as station-hosted Tasks: the station also sends those chats as a Task index (`task.index`, held in the same record), thread `<thread>` on its own station and `<thread>@<station>` on another of its workspace, a chat waiting for its person as `needs_review`. A row also says what the chat asks of whom: `attention` (`need`: the agent stopped and waits for a person; `done`: it finished and the person has not read the result; `failed`: its last turn failed; absent when it asks nothing), `waits_for` (the emails of the people it concerns now, at most 8), `note` (the agent's own line, at most 300 characters) and `url` (`https://`, opens the chat in still.fail). The Router's `im_api.internal.station_task.list` returns them and filters by `attention` and `waits_for`. They are the Group's station-hosted Tasks like a Station's (Station Task index, above): the Router reads one (`task.read`) and writes in it as itself (`task.say`); the still.fail station answers for a chat of its home workspace on its pages, on another of its stations over its mesh, and refuses a Slack or Feishu chat. A client cannot open such a Task on a station, as it has no endpoint id.
- Router: `station.list` returns the Group's still.fail stations apart from the roster (`stillfail_stations`: device id, name, whether connected), with a note that leads to `im_api.internal.station_task.list` and `im_api.internal.usage.query` (source `stillfail`), the chat tools on a task id, and `im_api.internal.task.create` with `runs_on` `{kind: station, device_id}` ([SalixAgent.Tools.Stations](../../systems/apps/salix_agent/lib/salix_agent/tools/stations.ex)). They take no `env.*` or `station.*` call.
- Comma's Settings › Devices: the Device's projection says `device_kind` `stillfail` ([Comma.Devices](../../systems/apps/comma_core/lib/comma/devices.ex)), and the installing member's list shows it as a still.fail station: still.fail's mark, connected or offline, the models it reports (`task_models`), and Disconnect, which is the device removal. It has no access value and answers no coding-agent probe: both are refused with `unsupported_for_kind`.
- Lifecycle: removing the Device (uninstalling the plugin, removing it on the CFT page, its expiry) revokes its credential and deletes its record and rows ([SalixEnv.ConnectorTokens](../../systems/apps/salix_env/lib/salix_env/connector_tokens.ex) `remove_device/1`).

The Comma station ([systems/station](../../systems/station/README.md)) began as a fork of still.fail's station, with the Connector built in: the same program is a Station to members and a Connector to Salix.
It adds no entity. It connects to Salix with WebSocket or HTTPS, and to other stations and to client apps with iroh: `comma/mesh/1` ([@comma/mesh](../../clients/packages/mesh/README.md)) for client cores, with the member credential above.
Salix is a relay for those iroh connections ([StationRelay](../../systems/apps/salix_web/lib/salix_web/station_relay.ex)): a station that proves its iroh endpoint id on its Connector run sends packets in binary frames, which Salix forwards to the runs carrying the named endpoint in the sender's Group. Which goes first is the control plane's (`COMMA_STATION_ROUTE_POLICY`, sent with the relay URLs, for a desktop's station and clients): `salix-first`, the default, ranks Salix with direct paths and races them by round trip, with an iroh relay as the backup; `relay-first` goes direct, then an iroh relay, then Salix. A running endpoint keeps the policy it bound with: the station and clients read `route_policy` only at bind, so a configuration change moves nothing already open and needs a rebuilt endpoint. A station with several Workspaces has one endpoint, which goes `relay-first` only when every run present at bind says so. Under `relay-first`, a local test found Salix took over about 30 seconds after the iroh relay went down, as the path has to go idle first, and an open connection did not move back within 60 seconds of the relay's return; a new connection takes the relay. Packets are bounded before each socket: a station or client holds about 128 KiB it has not written (a client's check can pass that by one packet), and Salix puts a packet in a socket's mailbox only with fewer than 128 messages waiting there, on the socket's own node, and drops it otherwise. That bounds the backlog; it does not put control first. Packets, heartbeats and answers share one WebSocket and TCP connection, and a control message waits behind what is already queued, including what TCP holds. The phones' carrier (`carry.rs`) has no such bound yet. A Salix node also has a budget over all its relay connections, in bytes and packets (`COMMA_STATION_RELAY_NODE_BYTES_PER_SECOND`, `COMMA_STATION_RELAY_NODE_PACKETS_PER_SECOND`), charged before the lookup and per carrier, and it sends to other nodes without waiting on the distribution channel, dropping when that is busy. The default, 2 MiB/s and 2,000 packets a second, is an experiment's value, not a measured capacity, and applies to all relay traffic, not only a desktop's. The budget is counted over aligned 250 ms windows, so traffic either side of a boundary can pass two windows' budget. `bin/comma rpc 'SalixWeb.StationRelay.halt()'` stops all relay packets on every node, on open connections too, and leaves the Connector and requests running; `resume()` undoes it, and `COMMA_STATION_RELAY_STOPPED=true` holds it across a restart. A Gate that is not reading has no cap of its own: it grows at the rate the budget lets through. A station in several Groups (a desktop signed in to several Workspaces) registers on a run in each, and sends a peer's packets on the run it last heard that peer on. The packets stay end-to-end encrypted; a registration lives only as long as that run's socket.
A member's client app reaches its Group's stations the same way through the client relay socket ([ClientRelaySocket](../../systems/apps/comma_web/lib/comma_web/client_relay_socket.ex)): it asks with its session for a one-minute, single-use ticket (`POST /v1/comma/workspaces/:id/station-relay`, a one-time credential), connects with it to `GET /v1/comma/station-relay`, and proves its endpoint id over the same challenge. The socket ends when the member leaves the Group, after three silent minutes, or after an hour.
How each of the client's connections runs now (direct, an iroh relay or Salix) is shown on the computer's card in Settings → Devices and in a screen's panel; it is not stored.

A desktop's own station has no roster row and no cloud.json: a key has one row, in one Group, and a roster row shows a station to every member. With Settings → Debug → Computers over the mesh on (on by default since defaults revision 2, which also turned on a saved off; read when the app starts), the instance file says `mesh`, and the Connector run asks with its proof of the key (`relay_register` with `mesh`). Salix answers that Group's workspace ids, credential keys, revocations, relay URLs and route policy, and the Device's owner ([SalixWeb.StationPlace](../../systems/apps/salix_web/lib/salix_web/station_place.ex) `device_mesh/1`, `Comma.Stations.device_mesh/3`), and nothing while the owner has no role in the Group or a read-only one. It listens before it reads, and sends the same again as `station_mesh`, numbered in the order the changes were heard, after a revocation or a key change; a run that cannot be told ends. The station hears none of this unless its own instance file asked, and an older number never stands over a newer one.
The station then binds its endpoint with `comma/mesh/1` alone, announced on neither the LAN nor the DHT: a connection opens through Salix, or a relay the client tries, and finds a direct path by itself. It keeps one set of these facts per run, so one key serves each Workspace the desktop is signed in to: a credential's `ws` picks the facts that judge it ([device-mesh.ts](../../systems/station/src/mesh/device-mesh.ts)). It admits only the Device's owner in that Group. A member credential of another member or a read-only member is refused. When its credential ends or its facts no longer admit it, the connection closes. A run that drops leaves what is open for 60 seconds, admitting no one new; past that it closes, and a client's view comes back by itself once the run returns, saying so meanwhile. It serves the computer's screens (`/screens`, `/screens/<id>/view`, [screens.ts](../../systems/station/src/mesh/screens.ts)) while its access is Full, and `GET /overview`. Other routes stay refused until each is decided for a computer: the admin API is one for the whole machine, across Workspaces. Through Salix, a view asks at most 8 Mbit/s of its source, about half of a Salix node's default 2 MiB/s for all its relayed connections (QUIC's own bytes and bursts aside); it lowers the encoder's rate as acknowledgements fall behind. No screen of the Computer Use helper offers a preview (`peek`): a look must not wake the display. While it serves these views, the station tells its agents the same screens through its device connection (`screen_links`, Salix's `device.screens`, [links.ts](../../systems/station/src/screens/links.ts)): each with its `comma:screen/<device id>/<screen id>` link, which a Message line holding only that link shows as the screen's card. These are values of the Device, not entities. A Windows station serves its main display as the same `display` screen through `comma-desktop-screen` ([win-desktop.ts](../../systems/station/src/screens/win-desktop.ts), [desktop-screen.md](../../systems/station/docs/desktop-screen.md)). A station says in its connector's capabilities whether it serves a display on the mesh (`screen_view`); the Device's projection gives it, a value of the Device, not an entity. Every client offers a view by `screen_view`. An old or self-hosted server that does not send the field is a long-term case: the client core then infers it from the platform, an owner-approved compatibility policy (true for `darwin` or no known OS, false for any other OS; a true only lets the client try). A current server sends false for an old station that does not say the capability ([desktop-screen.md](../../systems/station/docs/desktop-screen.md)).
The client core finds these stations in the person's own Devices (`station_id`), keeps a connection to each, and shows them apart from the roster (`ownComputers` of the `stations` topic). Every client with the mesh (the desktop app unless its Debug setting turns it off, the web page, and the iOS and Android apps) shows such a screen over the mesh, and says the computer is out of reach when the mesh does not reach it within 8 seconds; there is no other way to a screen. The Debug setting's Salix-only value binds the client's endpoint with no IP path and no iroh relay. The relays are `COMMA_STATION_RELAY_URLS` (`Comma.Stations.Config`), for clients and these stations alike; by default n0's public relays, as an empty list also says. Salix alone is the client's choice, in that Debug setting.
With the same setting the screen's panel also lists the computer's Android emulators and the phones its owner chose on the station's own adb (`android:<serial>`) and a Mac's iOS Simulators (`simulator:<udid>`), screen sources of the station, not Devices, starts its virtual devices and boots and shuts down its simulators, and a screen link in a message (`comma:screen/<device>/<screen>`) shows as a card with a look-only preview. The owner's phone choices (USB on or off, each phone shown, each phone offered to agents) are station config, not an entity ([devices.ts](../../systems/station/src/screens/devices.ts)). A Worker leases such a device through `env.android` in its `device` mode ([android-agent.ts](../../systems/station/src/screens/android-agent.ts)); the lease is the station's in-memory state, not an entity. The first lease of a phone in a Conversation needs a `computer_use_start` Capability Request (capability `android_phone`) that the computer's owner approves on its card there. A Worker leases a booted simulator through `env.screen` the same way ([simulator-agent.ts](../../systems/station/src/screens/simulator-agent.ts)); its first lease in a Conversation needs the same Capability Request with capability `ios_simulator`, and a person driving the simulator in Control holds the agent's input off.

### Local VMM disposal

A local disposal records the OS operator's accepted deletion of an exact local Environment or remote registration.
The Host store owns its immutable scope, replay fence, namespace checkpoints, and existing operation receipt.
The registration and Environment remain the resource identities. Disposal does not transfer cloud authority or replace their owners.
A generic operation has no durable target mapping. Resource rows can disappear during deletion, so they cannot preserve the replay fence.
The fence survives cleanup and restart. A new authorized installation uses new identities and does not inherit disposed data.
Implementation: [Host disposal store](https://github.com/AFK-surf/agent-vmm/blob/main/internal/host/store/local_disposal.go).

### Comma node settings and Shell creation

Settings > Devices presents the local node in the local device card and Workspace Workloads in a separate list.
Its device list holds only the signed-in user's own Devices that connected at least once; the Group's Cloud VM is a separate section ([Comma.Devices.computers](../../systems/apps/comma_core/lib/comma/devices.ex)).
This shared page adds no entity or lifecycle authority. Workloads without a proven device association keep their own owner status.
Computer access is a value of the device, not an entity: one `off`, `read` or `full` per computer, kept once by its station (`tools.access`, [device/access.ts](../../systems/station/src/device/access.ts)) and followed by both its device connection and its device tools.
Only the device's owner (`owner_user_id`) sets it, with `PUT /v1/comma/workspaces/:id/devices/:device_id/access` ([Comma.Devices.set_access](../../systems/apps/comma_core/lib/comma/devices.ex)); the 2-level `allow_operations` of clients from before maps onto it.
A station from before or the Go connector has two levels. It gets Read and Full as `allow_operations`; Off is refused with its upgrade reason (`station_outdated`, `device_needs_station`).
[useDeviceSettingsCategory](../../clients/packages/app/src/components/devices/useDeviceSettingsCategory.tsx) composes these views.
An owner has one Compute Environment, enforced by its tenant/owner unique index.
[ComputeNodeService](../../clients/apps/electron/src/main/modules/compute-node/index.ts) owns persisted node intent, binding scope, and read observations.
Native owns accepted local actions and their durable request receipts. Main projects those receipts without another result authority.

[AccountComputeNodeService](../../clients/apps/electron/src/main/modules/compute-node/account-service.ts) partitions intent by canonical backend audience and stable User subject.
Its Session generation fences each command, including queued work and A-to-B-to-A login changes.
Accepted late results remain in their original account partition. Historical records grant no authority without proof of their original subject, scope, and Host root.

[AgentVMMRegistrations](../../systems/apps/salix_store/lib/salix_store/agent_vmm_registrations.ex) owns the cloud request, claim ticket, Host binding, credential hash, and initial Shell relation.
Registration is the sole cloud identity for this relationship. The client request ID supplies idempotency within the existing product owner.
A request creates no ProviderBinding or Workload. The first claim binds the exact Host and its previously saved credential to that Registration.

The server returns public Gateway configuration. It stores only ticket and credential hashes, with no material exchange or delivery acknowledgment.
The claim preserves current enablement, including a stop accepted before the first claim.
BFT permits one live Registration per Project across Group changes. Comma permits multiple authorized Hosts within its Workspace Environment.

[Comma routes](../../systems/apps/comma_web/lib/comma_web/router.ex) use `/v1/comma/workspaces/:workspace_id/compute-nodes/agent-vmm/registrations`.
POST creates or resolves the request through `Idempotency-Key`. GET `/requests/:request_id` resolves a lost response without creating another request.
GET `/:registration_id` returns the Registration projection, `work_activity`, and `shell_phase`.

The product status is `processing`, `ready`, `stopped`, `action_required`, or `removed`. These values do not replace connection or Workload facts.
Reads return no ticket or credential. Repeating authorization returns the same Registration without another descriptor.
POST `/:registration_id/retry` explicitly renews a pending ticket on that Registration. There is no lifetime retry counter.

POST `/:registration_id/enable`, `/disable`, and `/revoke` mutate the exact Registration under current product authority.
Comma checks the original subject, backend audience, and current Workspace permission. A historical delivery Session does not gate current management.

POST `/requests/:request_id/cancel` and request creation use the same product-owner lock.
Cancellation revokes the exact existing Registration. If the request is absent, cancellation creates its revoked Registration without a ticket, Host, or credential.
A late authorization resolves that same revoked ID and cannot issue a descriptor, binding, or Workload.

The response includes `host_bound`, so Main can distinguish an unclaimed request from an accepted Host binding.
A missing or unresolved HTTP response does not prove cancellation. Main retains unresolved local or cloud outcomes.

Headless installation (Linux arm64, or macOS on Apple silicon) uses the same Registration. Its delivery target records the authorized User or Session and product scope.
Comma and BFT expose command projections through `compute-nodes/agent-vmm/install-commands`.
[Headless](../../systems/apps/salix_store/lib/salix_store/agent_vmm_registrations/headless.ex) returns the public GET `/v1/compute/agent-vmm/install.sh` bootstrap.

The copy command supplies `<registration_id>.<ticket>`. The bootstrap posts it and the machine's platform (`linux-arm64` or `darwin-arm64`) to `/v1/compute/agent-vmm/registrations/install.sh`, never in a URL.
The Linux stage 2 runs as root (the bootstrap asks for `sudo`). The macOS stage 2 runs as the Mac user: it publishes the release's `Agent VMM Host.app` (or updates an installed Host of another release in place) and claims the Registration with the Host as that user's login agent.
Script reads do not claim the Registration or change its lifecycle.

Native saves the fixed Host identity and candidate credential before POST `/v1/compute/agent-vmm/registrations/claim`.
A pending first claim requires its fifteen-minute ticket. The same accepted candidate can retrieve public configuration after ticket expiry.
That replay still checks the exact Host, explicit revocation, and the seven-day credential deadline.
Ticket cleanup clears expired pending secrets and occupancy while preserving the request's idempotency fact.

The Server release descriptor selects the published `agent-vmm-host` package: Mac zip or Linux arm64 tar.
Each platform retains its release ID and transport digest. Missing Linux delivery does not disable existing Mac installation.
The Linux package uses the same native lifecycle owner for systemd and recovery. It adds no installer entity or login protocol.

Main resumes the saved native request within one continuation window of 45 minutes. One backoff timer per intent has a 30-second cap.
There is no attempt-count limit. An explicit Continue starts another window for the same saved action and request.
A failed removal cannot become an enable. A successful native receipt stops automatic command continuation.
When the exact first-claim receipt reports `invalid_ticket` or `ticket_expired`, explicit Continue can renew the ticket on the same Registration. It retains the native request, candidate credential, and Host identity. Background continuation does not renew tickets.
If the server refuses renewal, Main can only observe the original candidate through its saved claim; refusal does not authorize another Registration.
If connection observations are still pending, Main uses the same window and timer for read-only observation until ready or an actionable result.
Window expiry pauses those reads without changing the successful receipt or issuing another command. There is no per-Workload polling or second timer.
A failed first preparation pauses its window and offers Continue when this process proves that native was never called. Restart discards that in-memory proof.
Explicit setup after owner uninstall uses the existing shared-Host confirmation and preserve-data reinstall, then continues the original configure request. Background work cannot create a reinstall request.

Missing or unreadable receipts leave the result unknown. A readable saved configure request can be explicitly continued with the same ID; this does not declare its prior effects absent or complete.
Native converts a legacy receipt's missing target only from its exact protected plan or completion, preserving the original result and owner fences.
The native owner's exact-request `request_blocked` error stops local continuation without proving a Registration target, reset completion, or cloud revocation.
Main retains the request and binding. The user can explicitly disconnect that cloud connection before a new setup.
A missing local Registration, expired credential, or Host reset does not authorize automatic replacement.
Main offers credential recovery for the known Registration. It does not automatically reset data or create another Registration.

The UI preserves the current reason and applicable action after refresh or restart. Initial Shell state does not gate connection enablement.
Fixture tests prove these projections. Acceptance of the Host connection requires the real Native and Gateway boundary.

Recovery uses the original Host root, including when its local Registration row is missing.
Main supplies current Session authorization to native through protected stdin. The credential and proof remain outside renderer state and command arguments.
POST `/:registration_id/recovery/challenge` binds the replacement credential hash, audience, subject, current Session, Workspace, Registration, revision, nonce, and expiry.

POST `/:registration_id/recovery` verifies that proof and replaces the credential on the same Registration.
Recovery renews its seven-day deadline and fences the old control connection. It preserves enablement, policy, Workload identities, and data.
A replay with the same accepted candidate returns public configuration without another replacement or deadline renewal.

Comma retains the original subject constraint. BFT checks current Project management and exact Runner or organization ownership.
Local explicit revocation or disposal, and cloud revocation, reject recovery. Recovery does not restore disposed data or revive revoked Registrations.

`Registration.authorization_expires_at` is the sole durable seven-day credential deadline. AgentVMM and the server clock own it.
A valid authenticated Host hello or observation renews it before expiry. A new credential accepted through root proof starts another seven-day period.
User login and settings reads do not renew it. Session expiry ends only that Session's capability.

Observation drops unknown or contradictory fields. An unusable observation stores no health data, but its valid authenticated contact still renews authorization.
The deadline prevents a stale Host credential from continuing cloud commands indefinitely.
After expiry, authentication, placement, command claim, and runtime Session admission reject the old credential with `authorization_expired`.

Expiry does not revoke the Registration, retire Workloads, remove local data, or prevent authorized credential recovery.
Accepted result settlement retains its original owner without new command authority. Existing revoked records remain revoked.

Only explicit revocation seals the exact Registration for cloud retirement.
[The settlement worker](../../systems/apps/salix_store/lib/salix_store/agent_vmm_settlement_sweeper.ex) cleans at most 32 expired pending tickets per pass.
It settles at most 32 due Commands per pass and resumes explicit-revocation retirement.

Retirement uses at most 32 indexed queries and 32 Workload transactions per pass. Its Registration, Binding, Allocation, and Workload pages include empty branches.
A full tour scales with retained history.
Each visited Workload cancels at most 32 never-delivered Commands and closes only its current-generation runtime.
Retirement uses Workload then Allocation locks and a resumable cursor. Busy owners remain for a later pass without immediate retries.

Allocation `released` ends cloud allocation authority. Its operation outcome and physical observation remain independent.
Shell deletion `cloud_retired` ends cloud execution management with `local_data_deleted=false`. It never projects as `deleted`.

Workspace owners can rename metadata during cleanup or retirement. Rename keeps owner admission and changes no deletion or Host authority.
Business Workloads retain identity, owner relations, and service references. Their provider becomes unavailable.

Sent Commands, accepted inputs, and unknown outcomes retain their settlement facts and cannot replay.
Cloud closure does not prove that local children stopped. The OS operator can dispose the exact Environment or Registration under local authority.
New Registrations cannot inherit old Commands. Other Registrations, user data, and PersonalMesh remain outside retirement scope.

[LocalComputeOperator](../../clients/apps/electron/src/main/modules/compute-node/local-operator.ts) projects bounded local metadata and submits trusted operator confirmations.
Cloud mapping requires current Workspace read permission and the exact Registration, Allocation, and generation. Read rights do not imply write rights.
The visible resource page reads at most 32 environments, one disk summary, one optional receipt, and one cloud mapping batch every five seconds.
The Guest supplies physical image/runtime, build-cache and pool-private categories from local quotas. Missing categories remain unknown.
Its Runtime owns bounded cleanup of canonical image roots after grants and accepted-operation pins end. Shared content follows containerd references.

Cached environment bytes have a fifteen-second freshness limit and exact boot, namespace, and generation checks. Missing values cause no Guest probe.
Manual Workload reads contain at most 32 items and current owner phases. They add no per-environment polling or automatic pagination.
A `meeting_runtime` Workload becomes `ready` from runtime readiness. Other Agent VMM Workloads require a ready Allocation and running container at the current Host connection epoch.

`problem` is null or `{code, retryable}`. It reports the current generation's last reconciler error without changing the phase.
Its fixed codes are `capacity_unavailable`, `image_unavailable`, `runtime_instance_changed`, `host_unreachable`, and `other`. It contains no raw message.
An Agent VMM Workload location contains `registration_id` and its Comma `device_id`, or null when unavailable.
Each page reads those Devices in one batch.

Confirmation fixes the current Workspace and Registration. Main rejects a changed binding before drain or removal.
`refresh` coalesces reads without installation, repair, or desired-state changes. `state.get` returns a snapshot.
Connection, admission, readiness, and work activity remain independent. An unknown result cannot prove success or stopped children.

Main reads activity through the Comma Registration GET under current Workspace permission, original subject, and backend audience checks.
It does not send a Comma Session credential to the tenant API. Failed activity reads remain unknown. A genuine product 401 still invalidates the Session.

Disabling drains this Registration's allocations. Removal revokes the exact cloud Registration and uses native to stop its environments into Retained.
Main reports removal complete only after cloud revocation and successful native completion, or proof that the canceled request never reached native acceptance.
A failed or unreadable boundary retains the unfinished action. An explicit new setup follows completed removal and uses a new request.

Retained preserves private volumes and writable layers. Confirmed local disposal or authorized Shell deletion removes only its accepted data scope.
These paths preserve the shared Host and other Registrations. Re-enabling does not promise restoration of previous work.

[ComputeWorkloadDeletion](../../systems/apps/salix_store/lib/salix_store/compute_workload_deletion.ex) owns the Shell deletion value on Workload.
It retains the request, exact Allocation generation, Registration, and Host revision. It adds no resource or task identity.
Deletion closes ordinary input admission before cleanup. Accepted work and unknown outcomes remain with their existing owners.

An unknown outcome does not hold deletion. Its owner keeps it and never replays it.
A shared Allocation or business reference rejects Shell deletion. The existing Registration Command transports only the accepted Allocation scope.
Host disposal saves its namespace mapping and replay fence before physical cleanup, including across reconnect and restart.

A discarded container or missing resource row cannot prove completion. Physical completion requires the exact Host disposal receipt or proof that creation never dispatched.
Explicit Registration revocation permits cloud retirement with local data unconfirmed. Credential expiry does not start retirement.

`Workload.owner_ref` relates the Workload to its existing meeting owner. SalixMeet writes it at placement without another identity or mutation authority.
Legacy meeting relations derive once from the exact tenant/meeting Workload ID and current Group projection. Unmapped legacy owners remain unknown.
Hot reads do not scan meeting state. Agent and service references use existing indexed bindings, at most 32 each per explicit detail read.

The Workload and creation association remain after cleanup. `Registration.initial_workload_id` records the existing initial Shell relation.
Salix creates that Shell idempotently after the first authenticated ready connection. Initialization returns the same Shell after deletion without a replacement.
Legacy retained data without a proven mapping remains pending. Explicit revocation permits cloud retirement without proof of local data deletion.

`Allocation.dispatch_protocol` identifies the Registration Command creation path. `Command.delivery_started_at` preserves the immutable dispatch fact against older writers.
Only that path without dispatch evidence can complete deletion without Host cleanup. Historical allocations require exact Host proof.
A pre-acceptance revision rejection refreshes only the matching Allocation generation. An accepted receipt keeps its original request and revision.
A Host without `allocation-disposal-v1` reports `host_update_required` without stopping independent work.

These transitions preserve retained TLA+ Session acceptance and native-evidence abstractions. Runtime regressions cover deletion and credential admission.
An unavailable Host prevents any physical deletion liveness claim.

[Comma.Compute](../../systems/apps/comma_core/lib/comma/compute.ex) authorizes every creation and indexed request lookup.
`Workload.creation_request_scope/id/input` associates a client creation request with its canonical input. These values grant no authority and create no entity.
[Compute](../../systems/apps/salix_store/lib/salix_store/compute.ex) commits that association with Allocation and Workload in one transaction.
The unique scope/request index prevents duplicate placements. Same input returns the same objects, including after a lost response. Changed input returns a conflict.
A deliberate additional Shell uses a new request ID. Existing records and volumes are not merged or deleted. Associations remain with their Workload records.
Published clients without a key keep their original creation contract. New clients always send one, with no keyless fallback.
The client persists only one unconfirmed request per backend/account/Workspace before dispatch. Reload checks it without automatically replaying creation.
[Settings](../../clients/packages/app/src/components/devices/useDeviceSettingsCategory.tsx) show This Mac and named Workloads through the shared settings components. Creation, details, rename, and exact deletion use the existing owners.
Workload pages contain at most 100 items. A visible page observes one Workspace page at five-second intervals for at most 60 rounds.
Each round uses at most one page read and one exact request lookup. Hidden pages stop. Reaching the observation budget does not cancel work or declare failure.

`Workload.runtime_update` was the image update operation of External Runtime Workloads. Updates are retired; a stored active phase still pauses that Workload's input ([ComputeWorkloadUpdate](../../systems/apps/salix_store/lib/salix_store/compute_workload_update.ex)).
The `external` runtime image class and its `external.codex`, `external.claude` and `external.pi` templates are removed. A stored `external_worker` Workload remains readable and appears in default lists while it needs recovery or cleanup. When the reconciler meets a Workload whose template is no longer in the catalog, the Agent VMM provider makes no allocation, image or container request, and the claim is parked once as action-required `runtime_template_retired` with no timer retry; a running container and its volume are left as they are. Starting a deletion clears the parked claim, so deletion still runs.
An authorized Workspace member deletes a stored `external_worker` Workload like a Shell: the Host disposes its allocation (container and volume). Its leftover `external_worker_bindings` and `external_worker_operations` rows are not owners and are removed when the deletion starts; a Shell's binding still blocks its deletion.
`comma-release` no longer publishes an external catalog. The `compute_runtime_release` table keeps its stored row; no code reads or writes it.

Compute Runtime authentication, control, and migration reuse the authorized exact
Runtime Instance target. They do not add a remote Host proxy or a second Workload
owner. Authentication keeps its credential target lock. Quiet and migration retain
their own operation owners and recheck the exact target after each live RPC.

Current naming has an important exception:
SalixEnv.Control.get_environment and list_group_environments return Devices.
get_command_environment selects an environment inside a Device.
The transient [ExecutionTarget](../../systems/apps/salix_store/lib/salix_store/execution_target.ex) value distinguishes DeviceEnvironment, DeviceRuntime, and ComputeWorkload.
It carries existing IDs only. Each existing owner retains authorization and current-route resolution.
Do not infer a new entity or a Compute relationship from these historical method names.

The existing Connector credential owns initial-registration expiry and its committed registration timestamp.
These fields add no identity or supervisor. [DeviceInstall](../../systems/apps/salix_env/lib/salix_env/device_install.ex) asks for local consent before first contact.
[ConnectorTokens](../../systems/apps/salix_env/lib/salix_env/connector_tokens.ex) retains revocation and registration admission.
The BFT Runner installer selects its platform artifacts through [ConnectorInstall](../../systems/apps/salix_store/lib/salix_store/connector_install.ex).
The BFT Runner starts no Connector; it maintains the Agent VMM Host.
Cloud installation links issue the same Connector credential from the current Group Compute device and connector IDs.
They do not grant tenant API keys or create another device identity. Non-runtime Go bootstrap preserves the original HOME.

### Group Compute lifecycle

A Group owns its default Cloud VM Workload and can use a separate Station Workload in an authorized Host Environment.
Each location retains its own Workload and Allocation. These relations reuse existing identities and tables.
Workload owns device associations, active operations, archives, runtime installation intents, billing timestamps, and bounded transition state.
Allocation and ProviderBinding own Cloudflare resource and Worker release observations. Account bindings retain their existing owner and credential references.
Device inventory remains a capability projection. Deleting or disabling an Agent does not release the Group environment.
Group deletion or explicit Group release owns that decision, including when no Agent remains enabled.

[Compute](../../systems/apps/salix_store/lib/salix_store/compute.ex) commits Group operations under row locks.
The SQL commit acknowledges activity admission. Caller loss does not remove accepted operations or release intent.
Gateway WebSocket attempts retain their exact Sandbox and Container profile in the existing Workload activity.
Definitive connection failures settle their own attempts. Uncertain handshakes coalesce into one pending start per location.
A successful connection or ready response settles those pending starts, without clearing active requests or another location's claims.
Claims do not expire by age. Historical targetless attempts require exact operator repair.
Confirmed disposal removes qualified claims for that exact location and generation, up to the sealed control revision.
Lifecycle clients retain the operation's Workload ID and generation. Control preparation and claim admission compare that owner under the Workload lock before granting a permit.
The existing discard receipt records the stopped carrier. It does not prove request effects succeeded or inputs were never sent.
Other locations, legacy claims, and non-Gateway operations remain outside that disposal.
The Workload projects a fixed Cloudflare control permit from its existing operation and generation.
The Sandbox DO enforces that permit and stores one pending carrier command. It does not own lifecycle or data disposal.
Connector admission history and execution seals survive restarts. A sealed carrier can settle only its qualified, exact-location claims.
[ComputeReconciler](../../systems/apps/salix_env/lib/salix_env/compute_reconciler.ex) selects Cloudflare and VMM through fixed provider branches.
One indexed cursor and bounded claim page serve both providers. CloudVM retains settings only.

Each node can start a background Compute scan round on its existing five-second cadence. Task completion can continue only an active persisted round.
Completion keeps the periodic deadline. A peer that clears the round prevents stale completions from starting another round.
One tagged timer per node serves both paths, with at most four provider tasks per node.
The explicit `sweep/1` operations API can start one round per call and continue it within the requested attempt limit.

A round uses a fixed high watermark and stable `(tenant_id, workload_id)` order. Workload timestamp changes cannot move earlier rows ahead again.
The watermark reads only Workload and Environment keys. Each candidate query checks full provider eligibility and returns at most 128 eligible candidates.
Claims retain lease, retry, and action-required behavior.

The existing per-page tenant cap is not strict fairness. A finite, unchanged key universe reaches later tenants despite timestamp changes in earlier tenants.
Progress requires successful database access and available task slots. Later eligibility changes remain covered by subsequent rounds.
Background selection skips a locked shared cursor and waits for normal cadence. An exact Host wake keeps the blocking cursor lock and serial claim path.

An empty Host wake hint cannot start a global round. Ready Group Workloads remain eligible for archive, metering, and recovery checks.
Missing, stale, or expired shell sessions recover even when the Host connection epoch has not changed.
After all nodes update, the residual round finishes before a fresh stable-key round. Existing timestamp columns need no schema cutover or shutdown.

[Cloudflare](../../systems/apps/salix_web/lib/salix_web/compute_providers/cloudflare.ex) implements provider operations and projects Group Workload facts.
There is no CloudVM RecordActor, source-read fallback, or second scheduled sweeper.

[ComputeMigration](../../systems/apps/salix_store/lib/salix_store/compute_migration.ex) transfers at most 20 legacy source objects per page.
The existing release handoff runs after old writers exit. Each transaction commits mapped facts and its cursor together.
Unknown durable fields or unresolved transitions stop admission. Source objects remain available for forward repair.
The existing cutover marker admits Group reads and writes after the final page. It does not admit provider destruction.
After admission, a repeated handoff cannot overwrite the new writer. Local empty-store bootstrap must first prove an empty source.

Completed provider cutovers remain readable as historical Workload facts. New Group VM
Workloads use Cloudflare. The Workload remains the archive and runtime authority.
Cloudflare Group disks are temporary, disposable Agent environments under the [Cloud VM data policy](../compute-devices.md#cloud-vm-data-policy).
Archive and restore are best effort. After the restore budget expires, the reconciler checks for completed restoration, then requests exact owner-led disposal.
Confirmed disposal advances the generation. Later demand starts an empty VM. A pending destroy retains its operation for bounded reconciliation.
Central Salix data and unknown execution outcomes retain their existing owners.

Cloudflare archive admission checks accepted Session demand, active operations, installation, and selection holds.
The shared Connector owner confirms quiet and fences new work. A transactional native-state snapshot retains dormant Session identities.
Each native quiet attempt has a 90-second budget, including ownership waits and native writes.
Salix and Gateway allow 100 seconds for the control transport. The archive token lease is separate from this execution budget.
Quiet inspects one 32-Session page at a time, with at most four concurrent native checks or drains.
Workers join before the page releases admission fences. A failed quiet check stops that archive attempt.
It does not revoke approved local disk disposal.
These bounds do not promise successful quiet for an arbitrary number of slow Sessions.
The archive retains files, credentials, permissions, and internal executable links. External links and unsupported entries fail closed.
Older Connectors retain the 64 MiB compressed and 32 MiB per-file archive limits.
New Connectors export up to 4 GiB in 4 MiB parts directly to R2 with Salix-signed URLs.
Older archive generations remain in Salix S3 until a later archive replaces them.
Restore can use a complete Salix S3 copy of the same generation when R2 is unavailable.
The Workload records the archive generation and queues old or failed generations for bounded cleanup.
The current Connector retains the 16 GiB expanded bound without a total entry limit.
Older Connectors can still reject 100,000 entries until the migration upgrades them.
Full-disk Group archives retain installed dependency trees, including local edits and mixed user files.
Fault recovery uses the same archive operation, manifest, pointer, and previous generation with `scope=recovery`.
That exporter omits Agent workspaces, managed dependency packages, and workspace sweep archives.
The Connector retains exact native continuation and credential paths, including paths inside an omitted tree.
Other files use the full archive selection rules. Export requires quiet and acknowledged runtime events.
Those archive requirements do not establish a local-disk retention guarantee.
The recovered Agent receives a notice about omitted data. Normal idle archives retain their full scope.
Installation declarations and directory markers cannot authorize omission. Existing approved cache omissions remain.
Workspace sweep archives retain their separate scope. Historical omitted archives still consume their saved restore intent.
Best-effort installation cannot prove recovery of bytes omitted from an old archive.
[Connector archive selection](../../systems/station/src/connector/archive.ts) implements this distinction.

A Group VM retains bounded dependency installation declarations without new omission or restore intent.
A missing source directory removes its declaration before export. The Salix managed runtime and credentials remain archived.
Historical omitted declarations can rebuild after wake without delaying Device readiness. The Agent can stop that installer and use the normal shell.
A limit error stops the archive attempt. The Cloud VM data policy permits a subsequent exact owner reset.
Restore imports an archive only into a Connector with no active connection. Archives never carry or restore the legacy External Session state directory.

After archive persistence, the exact quiet token permanently fences the old process before provider destruction.
An uncertain release or destruction retains the archive and interrupted transition. It cannot reopen input against a stale checkpoint.
Idle and image-release archives support explicit pre-commit cancellation. Age alone does not transfer archive ownership.
Container image releases use the same archive path before stopping active Group Containers.
The image release ignores Containers without a business Workload association. Their disks are disposable during image replacement.
Group release retains the stopped Workload and its archive.
An interrupted wake keeps its Workload operation until the reconciler resumes it or reports a bounded recovery error.
An explicit [restore retry](../../systems/apps/salix_env/lib/salix_env/compute_reconciler.ex) compares the exact wake, archive, target, control permit, phase deadline, and parked claim under the Workload lock.
It starts one new bounded episode without changing those identities or clearing Gateway claims. Automatic retries do not renew it.
A restore runs only in a Container's start, before its station. A Container whose restore did not finish is replaced.
Creating an Agent or turning on the Group's Cloud VM switch does not create a Group VM. An authorized `cloud_vm.start`, or a command for the exact default Cloud VM environment, creates the Group Workload on first use. A Task for the Cloud VM's station creates or wakes the Group Workload too, through the station's giving ([SalixWeb.StationTasks](../../systems/apps/salix_web/lib/salix_web/station_tasks.ex)). Read-only Device discovery projects that default identity before creation, then projects it from the Workload while its Connector is offline. Discovery does not create the VM.
The image release fence permits a restricted archive repair connection to the exact archiving Container.
It also permits exact non-starting confirmation and sealing of a waking target.
The current recovery path uses admission proof or a quiet full checkpoint before destruction.
These implementation checks do not revoke the product-approved disposable-disk scope.
A destructive reset must fence the old carrier and keep unknown effects unresolved.
It must not restore old pending execution as current work. Central Sessions and accepted queues remain under their owners.
The release fence still blocks new starts until publication completes.
Local tests do not prove cloud-provider progress.

### Cloud VM stations

Retiring. By owner decision (2026-10), platform-managed execution is a per-Task [sandbox](#coding-sandboxes): the Cloudflare Cloud VM, one long-lived VM per Group with an archived disk, is retired in a later release, and nothing new is built on it. A Group created where sandboxes are set up never has one (`cloud_vm_retired` on the Group record), and where the deployment says so (`SALIX_CLOUD_VM_RETIRED` on, the cutover release) every Group's is retired (`SalixAgent.Sandboxes.cloud_vm_retired?/1`). Retirement remains in force when L4ES configuration or its signer is missing. There it is retired already: a Task, a Worker binding or a Group default that names `{kind: cloud_vm}` is refused (`cloud_vm_retired`), a retired Cloudflare VM is not woken or made again, and a sandbox stands in its stead ([where a Task runs](../agent-runtime.md#where-a-task-runs)). `cloud_vm.start` is not offered, `env.exec` to a retired Cloudflare VM answers `cloud_vm_retired`, the Task watch sends the Router to a sandbox Task (not for a VM on an Agent VMM Host, `SalixAgent.Sandboxes.group_vm_retired?/1`), and notices 66 and 67 tell Routers. No product place picker offers it; Devices pages and the admin show it while its Workload is not archived (`SalixAgent.Sandboxes.cloud_vm_shown?/1`). The release that turns the switch on converts what names the Cloud VM, closes its open Tasks with a notice, and stops each Cloudflare Workload not archived ([SalixWeb.Migrations.CloudVMCutover](../../systems/apps/salix_web/lib/salix_web/migrations/cloud_vm_cutover.ex), [Cloud VM cutover](../agent-runtime.md#cloud-vm-cutover)); Cloudflare's teardown releases a VM with no container without an archive. `SalixAgent.Migrations.DefaultTaskPlaces`, which wrote Cloud VM defaults, derives none for a retired Group. The Group VM on an Agent VMM Host (the Group Workload's provider is `agent_vmm`, `SalixStore.ComputeGroupStation.group_vm_on_vmm_host/1`) stays as a VMM Station: the cutover names it in the Group's default place and Worker bindings as `{kind: station, device_id}` with its device id, and leaves its Tasks. Placed so, a Task is kept while the VM is not connected and the VM woken, as for `{kind: cloud_vm}`. Comma's place pickers offer it in that form, under the Cloud VM's name, where its Agents page names the device (`task_place.cloud_vm_station`, [CommaWeb.SalixClient](../../systems/apps/comma_web/lib/comma_web/salix_client.ex)). A Task there that cannot move keeps the VM's own options. BridgeForTeams's swarm settings name that default the Cloud VM. A Host registered for a Group whose Workload is on Cloudflare, or that has none, does not count: the VM's device names that Workload, and its station form is refused as the Cloud VM is. This entry is the contract elsewhere ([execution environments](../compute-devices.md#execution-environments)).

The Cloudflare Container runs the Comma station, the same station a person's machine runs.
It connects out to `/v1/connect` with its Workload's connect credential
([WorkloadCredential](../../systems/apps/salix_store/lib/salix_store/compute/workload_credential.ex)),
which names the Workload and its generation and ends with that generation; a reset advances it.
[Connect](../../systems/apps/salix_web/lib/salix_web/connect.ex) registers the connection as the Group's Cloud VM device, on the VM's own transport.
The Gateway starts, keeps alive and stops the Container; nothing reaches the Container through it.
The station is not a Workload runtime identity, Worker or Task entity: it is the Group VM's Device.

A Task that runs on a station names it (`runs_on`) and may choose its runtime, model and reasoning effort (`model`, a runtime Model Choice among the station's `task_models`).
[StationTasks](../../systems/apps/salix_web/lib/salix_web/station_tasks.ex) tells the station of the Task with those values; the Group's Cloud VM is started or woken first.
Once the station has a delegation, Salix asks it where its Session of the Task stands (`task.status`: running, waiting, idle, cannot start, gone), so [StationTaskWatch](../../systems/apps/salix_im/lib/salix_im/station_task_watch.ex) can tell a long turn from a Worker that stopped without a result, remind it once and then tell the Router with the Worker watch's Messages; the status is read, not kept.
The watch lives in the Task's owner, started on demand. After a node start or placement change, each node's [StationTaskWatchRecovery](../../systems/apps/salix_im/lib/salix_im/station_task_watch_recovery.ex) starts again, from the station rows, the owners of the active station Tasks placed on that node; it owns nothing and adds no entity.
The station picks the account that serves the model from its profiles.
Salix lends a Cloud VM's station the workspace's accounts as profiles over the station's share protocol
([StationProfiles](../../systems/apps/salix_web/lib/salix_web/station_profiles.ex)): Claude and Codex subscriptions, and Anthropic API keys.
Salix also lends them to a member's device station, such as the desktop app's station for one workspace, after its Connector run proves the station with `relay_register`.
It sends no placement and no platform model there. The owner must have a role that may enroll a station (not read-only); else the list is empty and `share.*` is refused. A workspace with no accounts sends an empty list.
A subscription's login and renewal stay with the AccountPool; the station borrows a short-lived token for each process it starts.
An API key's profile carries its key.

Archives move over the station's connection ([DurableArchive](../../systems/apps/salix_web/lib/salix_web/cloud_vm/durable_archive.ex)).
The station packs its root, with consistent snapshots of its databases, as tar+zstd into R2.
A wake writes a manifest of the archive's signed part URLs to R2 and starts the Container with one signed URL of that manifest.
The image unpacks the archive onto the empty disk, then starts the station.
The station therefore says hello with its own key, place, Sessions, and Task progress. A Container that cannot restore exits and starts no station.
Cloudflare links `/home/sprite` to `/workspace/.salix/sprite-home` to retain migrated entry paths.
The station's databases live under `/workspace/.comma/station`, so the archive carries its chats.
Central Salix Sessions, queues, and account credentials are product facts. Cloudflare disk copies are disposable under the Cloud VM data policy.
Targets share the Group VM trust domain. They are not separate hostile-code sandboxes.

[RuntimeLifecycle](../../systems/apps/salix_web/lib/salix_web/cloud_vm/runtime_lifecycle.ex) submits Cloudflare wake intent and holds selection for at most 30 seconds.
Compute owns whole-resource archive and wake. These fields do not create another VM or Task entity.
The existing Session work projection supplies conservative runnable demand. Human-action waits do not require an active VM.
The station parks for an archive only while no request, process or chat is busy.
Idle suspension retains the station's chats. Dispatch wakes the same VM.
See [local setup](../development.md#cloud-vm-stations).

### Coding sandboxes

A sandbox Task runs on an L4ES sandbox of its own (`runs_on {kind: sandbox}`). With a GitHub repository (`repo`) it is a coding Task, with that repository checked out; without one it is a plain sandbox Task: the same sandbox, lifecycle, limit and metering, with no GitHub grant, git identity, checkout, diff or pull request.
This adds no entity: the session is a Task, its sandbox is a Compute Workload, and its station is that Workload's Device.

- Reuse: the Task keeps the conversation, Messages, status and owner, and the station protocol delegates it (`task.invite`, `task.put`, `task.post`).
  Group Stations serve reusable execution locations. A repository Task uses an isolated machine and a GitHub grant under its Task owner.
  The grant is L4ES configuration on the sandbox, not a Comma or Salix entity. L4ES's proxy holds the Group's token, and the sandbox does not.
  The Task's active Router participant can replace this ACL through `internal.task.update {conversation_id, github}`, or remove it with `github: false`.
  L4ES owns the saved ACL. Salix omits the initial grant when starting an existing sandbox, so stop/start preserves ACL changes.
  A deleted sandbox receives the initial Task grant when rebuilt. Repository `write` includes read access across branches. `push_refs` restricts writes only.
  Updates replace the complete ACL: `repos`, `push_refs`, `user`, `graphql`, and `anonymous`. Omitted options return to defaults, including unrestricted refs without `push_refs`.
  L4ES validates and stores the ACL without replacing the token. The operation accepts no command, Schedule, or Loop changes.
  Success means the ACL is saved and delivery is queued, not that the proxy applied it. Requests in flight can finish under the previous ACL.
  A sandbox started without a grant needs another start to enable access after an ACL update. An unavailable sandbox returns an error.
  When `repo.branch` is omitted, Task creation generates the branch before sandbox reservation. The initial ACL includes that branch's full ref.
  With `repo.pull_request`, placement reads that open pull request: its head branch, which must be in the same repository, becomes `repo.branch`, and its base becomes `repo.base_ref`. The initial ACL then pushes to the pull request's head, so the Worker updates it directly.
  Both use the existing Workload identity and authenticated Station protocol. Their owners keep separate preparation, recovery, and disk policies.
- Values on the Task: `runs_on {kind: sandbox, device_id}` and, for a coding Task, `repo {owner, name, base_ref, branch, pull_request?}`, kept on the conversation record at create ([TaskConversationInput](../../systems/apps/salix_im/lib/salix_im/task_conversation_input.ex)).
  A Worker may be bound to it (`station_binding.runs_on {kind: sandbox}`, [StationBinding](../../systems/apps/salix_agent/lib/salix_agent/station_binding.ex)): each of its Tasks then gets a sandbox of its own and takes one of the Group's live-sandbox slots; where sandboxes are not set up, its Tasks are refused (`sandbox_unavailable`). A Loop Task refuses a bound sandbox, as it refuses any station. The sandbox may be a Group's default place (`default_task_place {kind: sandbox}`, [TaskPlace](../../systems/apps/salix_agent/lib/salix_agent/task_place.ex)), and where the Cloud VM is retired it is the last automatic candidate, after the requester's own Station ([where a Task runs](../agent-runtime.md#where-a-task-runs)); the clients offer it where the server says sandboxes are set up (Comma: `task_place.sandboxes`; BridgeForTeams: `Salix.Client.sandbox_places/1`).
  Where the Cloud VM is retired, a Worker creates plain sandbox Tasks for work that needs a machine, from its round, a Loop run or a sandbox ([SalixIM.Provider.Internal](../../systems/apps/salix_im/lib/salix_im/provider/internal.ex)): from within its own Task; the new Task's parent is the conversation the Worker's Task was made from, so the Group's Router, which delegates it, hands its result back there, and the Worker's Task is its origin (`source_refs.origin_task_conversation_id`); the call takes `content`, `title`, `runs_on {kind: sandbox}`, `repo` and `model` only; a Task a Worker created creates none (`task_depth`); the Group's live-sandbox limit and its credits bound how many.
  The device id is `dev-sbx-<conversation>` for every sandbox of the Task. `start.repo` carries the repository to the station.
  Public device and environment lists show coding sandboxes only while connected. Exact reads and internal Registry lists retain disconnected records.
  Agent calls express repository isolation with `runs_on.kind=sandbox` and `repo`. Other locations reject repository arguments, including on creation retries.
  User choices can name a model or machine. Salix resolves provider resources, credentials, and unspecified model defaults.
- Workload: kind `coding_sandbox`, provider `l4es`. Its Environment has `owner_type` `task` and the conversation id as owner, on the tenant's `pool_coding_<tenant>` Pool.
  Each sandbox run is one Allocation. A new run advances the Environment and Workload generation and revokes old-generation connection authority.
  The Workload spec holds the sandbox's state (`starting`, `ready`, `stopped`, `lost`, `failed`, `ended`), the L4ES sandbox name (`disk`), and when its GitHub token expires (`github_expires_at`) ([SalixStore.CodingSandboxes](../../systems/apps/salix_store/lib/salix_store/coding_sandboxes.ex)).
  It also holds `facts`: the token use, the branch's change totals and its pull request, as the sandbox and GitHub answered them last. They are values, not records: the sandbox and GitHub stay the authorities.
  The owner reads them when the Session ends a turn, and the coding endpoints keep what a read of the whole branch finds. Each part keeps the read that started last.
  The Task's run carries them (`facts`), so its panel shows them before its own reads of the sandbox answer.
  The L4ES sandbox is semi-persistent: runs reuse it and its data disk, which is disposable L4ES state, not a Comma or Salix entity.
- Limit: a Workspace's most live (`starting`, `ready`) sandboxes is a value, not an entity: the tenant config `coding_sandboxes` (`max_sandboxes`, 1-100), else the deployment default `SALIX_L4ES_MAX_SANDBOXES`.
  Only a Comma admin sets it, through an audited Admin command. Placement and the L4ES workspace assertion read the same value ([SalixWeb.L4ES](../../systems/apps/salix_web/lib/salix_web/l4es.ex)).
- Callback: the sandbox's Session calls Salix registry tools as the Task's Worker (`task.tools`, `task.tool_call`; the station tools `salix_tools`, `salix_call` and the `comma` command there). This adds no entity: the call is the Worker's tool call, dispatched as a round's is, for the Task's owner under the delegated principal `{schedule, "station:<device>", {comma_user, owner}}` and the Task's label, within a closed allowlist ([SalixAgent.StationToolCalls](../../systems/apps/salix_agent/lib/salix_agent/station_tool_calls.ex), [agent runtime](../agent-runtime.md#tool-calls-from-a-tasks-station)). Authority is the sandbox's: the Task's current device and Workload generation, as `task.app_deploy`; a sandbox station alone offers the tools. A result goes back to the sandbox only when the Task's owner is a reader of its label (an egress, decided by the kernel on the Group's facts; under audit the refusal is archived and the result goes back).
- Owner and lifecycle: [SalixWeb.CodingSandboxes](../../systems/apps/salix_web/lib/salix_web/coding_sandboxes.ex) creates, invites, stops and replaces sandboxes, as [compute and devices](../compute-devices.md#coding-sandboxes) says.
  A Task's status change reaches it through `SalixIM.Ports.TaskStations.task_status/3`. A placement reserves it through `sandbox/1`.
  Replacement waits for confirmation that the previous sandbox stopped. Unknown invite and stop results cannot start a second execution carrier.
  The selected account restricts profile access. Missing owner facts fail closed rather than expose every tenant account.
- L4ES identity: L4ES admits Salix with workspace assertions that the Comma OAuth IdP key signs ([CommaWeb.Coding.L4ESAssertions](../../systems/apps/comma_web/lib/comma_web/coding/l4es_assertions.ex)). Members sign in to L4ES with Comma.
  The L4ES workspace is `comma:<group id>`. It is L4ES's own record, not a Comma or Salix entity.
  Its members are L4ES's records too. Before each sandbox create, Salix sets them to the Workspace's active non-viewer members ([CommaWeb.Coding.Members](../../systems/apps/comma_web/lib/comma_web/coding/members.ex)), by Comma user id. Comma's `WorkspaceMembership` is the authority for its Comma users there: the sync removes the others. Members that L4ES's own members add by login, such as GitHub users, stay. L4ES never asks Comma.
  Salix adds the release's sandbox image to it as an L4ES custom image (`comma-<sha prefix>`), also L4ES's record, named by the release's image manifest.
- Product surface: [CommaWeb.Coding.Endpoints](../../systems/apps/comma_web/lib/comma_web/coding/endpoints.ex) starts sessions and reads their state, changes, pull request and terminal link. Clients call them through `coding.*` ([core](../../clients/packages/core/src/coding.ts)).
  The session branch's pull request is GitHub's record, not a Comma or Salix entity: Comma reads it, edits it, marks it ready and merges it with the Group's GitHub account ([SalixWeb.GitHub](../../systems/apps/salix_web/lib/salix_web/github.ex)), and opens it there once the sandbox is gone. A Task made with `repo.pull_request` has that pull request's head as its session branch, so it is found as the branch's own. Where no open pull request has the session branch as its head, one of another head whose head is the branch's last commit is the session's, open or merged (a Task that continues a pull request): the station, after pushing, and Salix answer it, and Comma opens no second one.
- Station: [tasks/coding.ts](../../systems/station/src/tasks/coding.ts) keeps the checkout and answers `task.diff` and `task.pull_request`.
  The agent controls commits and pushes during coding work. Turn completion and sandbox shutdown leave the repository unchanged.
  Explicit pull-request creation pushes existing commits. Explicit Mini App deployment commits and pushes the source before packaging.

## 8. Billing and entitlements

| Concept | Meaning and boundary |
| --- | --- |
| Billing Account | The charge owner linked to a product owner. It is not a login account or a provider customer ID. It owns one pending subscription Checkout value. [SubscriptionCheckout](../../systems/apps/billing_commerce/lib/billing_commerce/subscription_checkout.ex) fixes the request under its row lock, creates the Stripe Session outside the transaction, and retains unknown results for retry. A paid Subscription or confirmed Session expiry clears this value. |
| Package / Package Version | A product package and its immutable commercial terms version. Provider price IDs are external mappings. |
| Subscription / Cycle / Purchase | A subscription, an issuance period, and a one-time purchase source. The Subscription owns one pending upgrade/downgrade operation and its Stripe Schedule mapping. Stripe owns the scheduled future tier. A Cycle retains payment allocations, each identified by its invoice and PaymentIntent. [PaidCycles](../../systems/apps/billing_commerce/lib/billing_commerce/paid_cycles.ex) issues an existing Grant per allocation. Its single `credit_grant_id` is not the authority for the collection. |
| Entitlement | Granted capabilities and limits. It is not the remaining credit balance. |
| Credit Grant / Lot | One issued batch of credits with consumption and compensation attribution. |
| Meter Event / Charge | Resource usage evidence and its priced debit. Retrying the same event must not create a new charge identity. |
| Fee Control | Cost availability admission. It is separate from usage metering and charging. |

The public purchase catalog follows Stripe purchase metadata. The private billing summary resolves its current plan through the Subscription's exact provider price mapping. Hiding sales preserves the current plan, its cadence, and its management actions.

Internal subscription redemption reuses Subscription and Cycle. The Package Version's billing period selects one or twelve monthly Cycles, starting in the redemption's UTC calendar month. The scheduler issues each Cycle once. Redemption does not authorize renewal beyond that term.

Owners and entry points:
[Billing accounts](../../systems/apps/billing_core/lib/billing_core/accounts.ex),
[PackageCatalog](../../systems/apps/billing_commerce/lib/billing_commerce/package_catalog.ex),
[Subscriptions](../../systems/apps/billing_commerce/lib/billing_commerce/subscriptions.ex),
[Entitlements](../../systems/apps/billing_core/lib/billing_core/entitlements/policy.ex),
[Credits](../../systems/apps/billing_core/lib/billing_core/credits.ex),
[Charges](../../systems/apps/billing_core/lib/billing_core/charges.ex),
[FeeControl](../../systems/apps/billing_core/lib/billing_core/fee_control.ex).

Self-hosted Workspace convergence reuses Credit Grant and the existing
`unlimited_metered` entitlement policy. It issues one idempotent grant per Workspace
through [WorkspaceConvergence](../../systems/apps/comma_core/lib/comma/workers/workspace_convergence.ex).
BillingCore remains the grant and admission authority. No separate self-hosted billing identity is introduced.

Hosted Comma registration reuses User eligibility and Credit Grant. New self-service
Eligible Users receive 20,000,000 credits without expiry in their earliest non-deleted
owned Workspace, only on their registration UTC day. Historical and admin-created
Users are ineligible. Plus addresses and configured excluded email domains do not
receive the gift. New `gmail.com` registrations can receive the gift with dots in
the username when email verification succeeds and no prior registered User has
that canonical Gmail address. Gmail eligibility removes username dots and the plus
tag. It does not map `googlemail.com` or other domains to Gmail.
A prior User consumes eligibility even without a gift, including disabled,
admin-created, plus-address, and deleted Users. These checks do not change login identity.
The canonical rule applies after release convergence. Older replicas retain the prior gift policy during rollout.

The existing `comma_released_emails` projection owns canonical Gmail occupancy.
Its primary key contains purpose-separated canonical HMACs alongside the existing exact released-email HMACs.
For canonical rows, `released_at` records the first occupancy reservation time.
OTP, Google, and Apple registration pass verified-email evidence at User creation.
Registration reserves canonical occupancy and creates the User in one transaction.
Only the first reservation can make a new User eligible. Later aliases remain separate Users without gift eligibility.
An indexed email projection accounts for registered Gmail Users from before this change.
Email change reserves its source and destination Gmail addresses through the same unique occupancy authority.
Final deletion records the current Gmail address before it clears the email.
The User retains a Boolean claimant marker to distinguish new registration from historical pending eligibility.
The hash uses the existing auth secret with a separate purpose to prevent guessed-email tests by database readers.
It grants no login authority. A missing key skips Gmail gift eligibility without blocking account creation.
Existing exact released-email and deleted-email hashes continue to prevent exact reuse.
Historical deleted or released dotted addresses cannot supply canonical history from their exact hashes.
Canonical history protection starts with this change. No historical gift, eligibility repair, or hash backfill occurs.
Historical pending dotted registrations without a stored claim remain ineligible. BFT and self-hosted
Workspaces receive no registration gift. [SignupCredits](../../systems/apps/comma_core/lib/comma/billing/signup_credits.ex)
locks the Comma User and issues a fixed per-User Grant through BillingCore's own
Repo. A shared BillingCore transaction lock enforces the configured daily USD cap,
which defaults to 2,000. The transaction samples the UTC day after acquiring the lock
and counts issued original credits by Grant insertion time. Spending or revocation
does not free this budget. A normal skip ends User eligibility without delaying
Workspace readiness. Existing Grants remain authoritative after consumption or Workspace deletion.
Workspace convergence delivers the gift before readiness; post-rollout release
convergence closes the old-worker window with bounded User pages and the same helper.
There is no Redeem Code, Purchase, or additional claim entity.

A restricted email address can give one person many Users: its domain is in the
excluded domain list, or an MX host of its domain is under `mx.cloudflare.net`
(Cloudflare Email Routing, where catch-all addresses are free).
[EmailRestriction](../../systems/apps/comma_core/lib/comma/auth/email_restriction.ex)
decides it from the User's current email; it is a rule on that value, not an entity.
Registration reads the MX records before its transaction and makes a routed address
ineligible for the gift. Monthly free credits skip restricted addresses. A Workspace
whose owner's address is restricted starts no managed sandbox (L4ES):
[SandboxAdmission](../../systems/apps/comma_web/lib/comma_web/coding/sandbox_admission.ex)
refuses it before the fee control with the denial `sandbox_restricted`. The
Workspace's own stations are not affected. A restricted address signs in to no other
service through the Comma OAuth/OIDC identity provider: the authorize page answers
`restricted_email`, and resource owner lookups fail, so its earlier tokens and
refreshes stop working too. It still signs in to Comma. The MX records are read on
each decision; a failed or timed-out lookup restricts nobody.

Free hosted Comma Users receive one Credit Grant of 5,000,000 credits per UTC calendar month in their earliest
non-deleted owned Workspace. The grant expires at the end of the month, so unspent credits do not carry over.
[FreeMonthlyCredits](../../systems/apps/comma_core/lib/comma/billing/free_monthly_credits.ex) issues it at Workspace
convergence and in an hourly bounded pass. A free User is an active registered User with an eligible email address
(the plus-address and excluded-domain rules of registration credits) and no live Subscription on an owned Workspace.
The Grant is `usage_credits.resource_kinds = ["vm", "storage"]` in its policy snapshot. It is a value of Credit Grant,
not a new entity. Admission and charging count a Grant only for a resource kind it lists; a Grant without a list pays
for every kind. Hosted LLM and voice use therefore cannot spend it. The billing summary keeps it out of
`current_credits` and `active_grants`, and reports it as `non_llm_credits`.

Comma's free Router list is a Fee Control policy value, not a package, grant, or new model identity.
[Comma.Billing.RouterModels](../../systems/apps/comma_core/lib/comma/billing/router_models.ex) owns the global provider/SKU list in `comma_billing_policy`.
Admin updates the bounded singleton through the existing audit authority. Its revision prevents concurrent edits from overwriting each other.
The Workspace Router relation determines eligibility. Each main-model Meter Event retains its admitted exemption until settlement.
See [free Router billing](../billing-models.md#free-comma-router-models).

## 9. BFT product concepts and representations

| Concept | Meaning and boundary |
| --- | --- |
| Organization / Org Membership | BFT's account and authorization scope. Organization maps to Salix Tenant. |
| Agent Swarm / Project | BFT's Agent work scope, stored under the historical Project name. It maps to Salix Group. |
| Group meeting preparation settings | Calendar enrollment choices owned by the existing Group, keyed by Group ID. Enabled state and revision authorize subsequent meeting effects. This configuration does not own a second MeetingPlan lifecycle. With calendar scope `members`, each Google Calendar account connected to the Group gets an existing Comma Calendar (identity kind `meeting_enrollment_member`) as its own scan unit; no new entity is added. The settings' bot is where reminders, join notices and minutes go; `calendar_source` (Google or the Feishu/Lark bot's own calendars) and `destination_confirmed_at` (an admin chose the bot) are values of the same configuration, not a second setting. |
| BFT Agent | A product reference to a Salix Agent. The product row owns association and slot facts, not a second runtime configuration. |
| Calendar Task projection | A read-only calendar representation of a scheduled canonical Task, not another editable Task aggregate. |
| Triage / Receipt / Bucket | Message triage, processing evidence, and grouping. BFT's workbench scopes access to Salix-owned triage facts. |
| Triage follow-up | A retained context entry owned by `TriageProductRuntime`, with one Schedule for its next check. Explicit duplicate maintenance reuses `superseded_by`. It preserves evidence and leaves one selected entry active. It does not resolve the source goal. |
| Project Knowledge / Assertion / Alias | Source-backed shared knowledge and identity aliases. These do not replace product users, projects, or memberships. |
| Sourced Context / Context Bundle | Source-backed material and its shared lifecycle identity. Source adapters do not independently decide retention authority. |
| Daily brief member | A BFT User in one Organization who receives the personal brief, with the Slack user ID it reads for. It is not a second User or Slack identity authority: the BFT User owns login, and the Slack workspace owns the user ID. |
| Daily brief run | One written brief: the team's (`team_brief`) or a member's (`personal_brief`), with its window, token use, coverage, and the text the model wrote, kept until retention so the next brief can tell what changed. It is a record of what was sent, not a Message: message text stays in the Salix Slack mirror. A pass reads source data as `SourceItem`s from a source adapter (`DailyBrief.Sources.Slack`). |

Owners and entry points:
[Organization](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/organization.ex),
[Project](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/project.ex),
[Group meeting settings](../../systems/apps/salix_store/lib/salix_store/meeting_calendar_settings.ex),
[Meeting configuration authority](../../systems/apps/salix_meet/lib/salix_meet/calendar_configuration.ex),
[BFT Agent](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/agent.ex),
[Canonical item commands](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/conversations.ex),
[Calendar projection adapter](../../systems/apps/salix_calendar/lib/salix_calendar/source_adapter/salix_task_schedule.ex),
[Triage](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/triage.ex),
[Follow-up owner](../../systems/apps/salix_store/lib/salix_store/triage_product_runtime.ex),
[ProjectKnowledge](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/project_knowledge.ex),
[SourcedContextObject](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/sourced_context_object.ex),
[ContextLifecycle](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/context_lifecycle.ex),
[DailyBrief](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/daily_brief.ex).

User Assistant Chat and WorkspaceItem are retired with the My Space board. BFT has no per-user Chat
binding or local board item. The `user_assistant_chats` and `workspace_items` tables keep only stored
rows, which the conversation and session identity migrations still rewrite.
BFT Agent's salix field is virtual. It is not a persisted copy of Salix Agent configuration.
ContextLifecycle supports explicit deletion and erasure. A worker drains due requests on every Pod.
A member may request deletion of a `personal` bundle whose subjects include that member; other requests need an administrator.
It does not yet schedule retention periods or implement legal holds.

## Desktop concepts and naming traps

Browser Tab, Browser Session, Site Permission, and Meeting Recording are client concepts.
Browser Session is neither Auth Session nor Agent Runtime Session.
See [Browser sidebar](../../clients/apps/electron/src/main/modules/browser-sidebar/index.ts),
[Site permissions](../../clients/apps/electron/src/main/modules/browser-sidebar/site-permissions.ts),
and [Meeting recorder](../../clients/packages/core/src/meeting/recorder.ts) (the client core decides; Main's
[meeting parts](../../clients/apps/electron/src/main/modules/meeting-recorder/index.ts) capture and keep files).

Historical Comma.Data.Session describes migration and archive data.
Serving login authority is [Comma.Accounts.AuthSession](../../systems/apps/comma_core/lib/comma/accounts/auth_session.ex).
Do not infer current authentication ownership from the old schema name.

Actors, stores, RPC, CAS, outboxes, projections, and generation fences are implementation mechanisms.
They do not each require a new product entity.
Distinct Session, Task, Message, Draft, Skill, and Plugin semantics remain necessary even when their representations overlap.

### Subscription runtime credential projection

The [subscription runtime owner](../../systems/apps/salix_web/lib/salix_web/subscription_runtime_auth.ex)
binds an existing tenant organization account to a Connector runtime or a Compute Workload.
Device bindings use tenant, Group, device, and device-runtime identity. Compute bindings use tenant and Workload, with project scope.
Both are the same account-selection relationship, not a new account or Session.
The existing Agent runtime binding alone cannot select the credential shared by all sessions on one native process.
The server stores this account selection durably in `runtime_subscription_bindings`.
It survives socket and process replacement. Workload bindings also survive RuntimeInstance replacement.
The [Compute owner](../../systems/apps/salix_web/lib/salix_web/compute_subscription_auth.ex) resolves the current instance for each delivery.
Explicit unbinding removes the relationship after confirmed native revocation.
Device Codex account changes replace the selected account atomically and issue a new delivery revision.
The same app-server accepts external tokens without deleting native login storage. No task wait or process restart is required for binding.
Disabled or deleted accounts make the relationship unavailable rather than selecting another account.
AccountPool owns encrypted credentials and their account type.
Subscription OAuth accounts own refresh and quota state.
Codex and Claude OAuth accounts support both Device and Workload bindings. Claude receives only the access token in its child environment.
Provider API key accounts own a name, an HTTPS endpoint, a protocol, and an authentication scheme.
An account created for a Model Catalog source also records that source, its endpoints by protocol, and a key hint.
A Custom account may have no key. It then has no key hint, and requests to it carry no authentication header.
The product calls these accounts Profiles.
They reuse the existing account identity, encrypted credential field, version, and binding lifecycle.
The connector holds a runtime copy of the selected credential in native process memory.
It can create a secret-free launch projection for a managed native process.
Delivery status and revisions are coordination state of this relationship, not separate credential identities or security authorities.
See [the binding contract](../compute-devices.md#managed-runtime-credential-binding).

### SSH login and terminal projection

SSH keys reuse Login Identity under `Comma.Accounts`. The canonical key and its
account binding remain in `comma_user_identities`. Revocation reuses `disabled_at`.
One account can have multiple SSH identities. A key has one account owner and
cannot transfer or silently enroll after revocation. SSH connections create
ordinary Auth Sessions with a reference to that identity. Google identity
cardinality remains unchanged. See [SSH account access](../identity-security.md#ssh-account-access).

The terminal model, authentication handoff, and chat subscriber are ephemeral
connection projections. They own no account or execution lifecycle. The terminal
uses the existing shared Router Conversation through Comma's authorization layer.
It never creates a second Router Session or persists participant aggregates.

The persisted SSH host key is endpoint configuration, not a User, Login Identity,
or compute Device. Its owner is the Comma SSH listener. A shared database record
preserves the endpoint identity across process and replica replacement. Its
lifecycle is first-use creation, continued reuse, and explicit operator rotation.
The private material is separate from OAuth signing keys because SSH clients
pin a different protocol identity with an independent trust lifecycle.

Implementation: [Login Identity](../../systems/apps/comma_core/lib/comma/accounts/ssh_identities.ex),
[endpoint key](../../systems/apps/comma_core/lib/comma/ssh_host_key.ex),
[terminal chat](../../systems/apps/comma_ssh/lib/comma_ssh/chat.ex).

### Outbound SSH Session

Agents connect to remote hosts with the `ssh.*` tools. This direction is
separate from inbound SSH login above: the Group is the SSH client.

Two values belong to the existing Group. They add no entity.

- The Group SSH client key is one Ed25519 key, stored unencrypted as PKCS#8 PEM
  at `ctl/ssh/groups/<group_id>/identity.pem`. The first use creates it with a
  create-once write, so concurrent callers get the same key. It has no rotation.
- The trusted host keys are one JSON record at
  `ctl/ssh/groups/<group_id>/known_hosts.json`. Compare-and-swap writes change it.
  Each entry is keyed by the host name that the Agent typed and the port, not by
  the resolved address. A Tailcat server's entry is keyed by
  `tailcat:<server node key>`, which the Tailcat tunnel authenticates, not by
  its address. The first connection records the host key before user
  authentication continues. A changed key fails closed and shows both
  fingerprints. `ssh.known_hosts.remove` deletes one entry. The record holds at
  most 512 hosts.
- A host key restriction is a value of the trusted host keys record
  (`restricted`: fingerprint to IFC tag). A CFT owner or admin sets it on the
  Data policy page; no `ssh.*` tool changes it. It is keyed by the key's
  fingerprint, so every name and route that reaches the same server is
  restricted, and removing an entry does not lift it.

Every `ssh.*` result that reaches a host carries the IFC label `{group}`: the
Group SSH key authenticates, so anyone in the Group could run the same command
([SSH audience](../../systems/apps/salix_agent/lib/salix_agent/ssh/audience.ex)).
A restricted host adds `{tag}`. Every call on a restricted host, an open
session included, needs a requester cleared for the tag or a Group supervisor; others get
`host_restricted`. A schedule or Loop uses its creator. A host reached through
another host is restricted only by the key the Agent connects to.

Group deletion removes both objects before it removes the Group record.

An Outbound SSH Session is a new runtime entity. A Compute process belongs to a
Workload in the Group VM, and a remote-shell target is a consenting user device
reached through the gateway. Neither one represents a platform-originated SSH
connection with its own interactive terminal.

- Identity: `ssh_session_id`, scoped to one Agent session
  (`{agent_id, session_id}`). A retry of the same `ssh.open` tool call returns
  the same session. Another Agent session cannot find it.
- Owner: one `SalixAgent.SSH.Session` process, supervised by the session actor
  of its Agent session through a supervisor that the actor starts on the first
  `ssh.open`. It holds the OTP SSH connection, one PTY shell channel, 1 MiB of
  output, and a VT100 screen. Exec and SFTP channels use the same connection
  for one tool call. Tool jobs run beside their session actor, so lookups are
  local and need no placement.
- Lifecycle: connecting, open, then closed or failed. It closes on `ssh.close`,
  shell exit, disconnect, 30 minutes without a tool call, and 8 hours of age.
  It ends with its session actor, for example on Agent stop, archive, fencing
  or node drain. It is not durable. It never reconnects or replays input. A
  closed session keeps its final output for five minutes.
- Relationships: a session actor with SSH sessions is not idle, so it is not
  stopped or evicted for idleness. An Agent session has at most 4 open SSH
  sessions.
- Destination policy: the host must resolve to public addresses only. The
  connection uses the checked address. Through a gateway device, Salix does
  not check or resolve the host.
- Tailcat transport: `ssh.open` with `tailcat` (an address or a DNS name with a
  `tailcat=` TXT record) connects through the node's Tailcat gateway, one Go
  process per Pod started on first use. Each SSH connection gets its own Unix
  socket stream and its own Tailcat client with a new ephemeral node key. The
  Group has no Tailcat key: its Agents run on many nodes at once, and two peers
  with one node key would replace each other at the server. So a Tailcat server
  cannot admit the Group by key (`--allow`); the Group SSH key authenticates.
  The gateway uses DERP relays only from the trusted DERP map and dials only a
  port on the Tailcat server itself. It owns no durable state, and its exit ends
  its SSH connections like a disconnect.
- Gateway device transport: `ssh.open` with `via_device_id` and `host` asks that
  LAN gateway's connector to dial `host` (`lan_tcp_dial`). One relay process
  per connection carries the bytes as `stream` frames over the connector
  socket, with a per-direction window of acknowledged bytes. The tunnel is
  not durable: it ends with the SSH connection, the connector socket, or the
  connector's command scope. The known_hosts entry is keyed by
  `device:<device_id>:<host>`, because one name can mean different hosts on
  different networks.

Implementation: [tools](../../systems/apps/salix_agent/lib/salix_agent/tools/ssh.ex),
[sessions](../../systems/apps/salix_agent/lib/salix_agent/ssh/sessions.ex),
[session process](../../systems/apps/salix_agent/lib/salix_agent/ssh/session.ex),
[terminal emulator](../../systems/native/verified_kernel/runtime/VerifiedKernel/Terminal.lean),
[client key](../../systems/apps/salix_agent/lib/salix_agent/ssh/identity.ex),
[trusted host keys](../../systems/apps/salix_agent/lib/salix_agent/ssh/known_hosts.ex),
[destination policy](../../systems/apps/salix_agent/lib/salix_agent/egress/destination.ex),
[Tailcat gateway owner](../../systems/apps/salix_agent/lib/salix_agent/ssh/tailcat_gateway.ex),
[Tailcat gateway](../../systems/tailcat-gateway/gateway.go),
[device relay](../../systems/apps/salix_agent/lib/salix_agent/ssh/device_relay.ex),
[connector tunnel](../../systems/station/src/connector/lan-tunnel.ts).


### Device Secret

A Device Secret is a key that a LAN codec tool needs to talk to one device on
the user's network, for example the 32-hex miIO token of a Xiaomi lamp. The
user gives it once in a conversation. The Agent saves it and later names it
(`token_ref`). Salix reads the value only at dispatch and uses it as the codec
key, so the value never returns to a model, a tool result or a client.

Existing credential owners cannot represent it:

- An OAuth Binding, an MCP credential and an X plugin credential authorize a
  provider account and are resolved for HTTP requests to that provider. A
  device token has no provider, account or refresh, and it is never sent: it
  only keys the encryption of UDP packets.
- A Connector credential authenticates a Device to Salix. The secret is for
  the opposite direction, from Salix to a device behind a gateway, and one
  gateway reaches many such devices.
- An API Key / Provider Credential is inbound authority or platform provider
  access, not user-supplied device material.
- The Group SSH key and trusted host keys are generated or observed by Salix
  and are readable by the Agent. A Device Secret is supplied by the user and
  is write-only.

Facts:

- Identity: `(group_id, name)`. Saving an existing name replaces its value and
  metadata and keeps `created_at`.
- Scope and owner: the existing Group. In Comma this is the Workspace's
  default Group, so every Agent of the Workspace can use the secret.
  [DeviceSecrets](../../systems/apps/salix_agent/lib/salix_agent/device_secrets.ex)
  owns one JSON record per Group at `ctl/device_secrets/groups/<group_id>.json`,
  changed only by compare-and-swap. The record holds at most 128 secrets.
- Value: `kind` (`api_token`, `miio_token` or `onvif_password`) fixes the accepted
  format. The value is sealed with AES-256-GCM under a key derived from the
  deployment credential root for purpose `device-secret-v1`. The AAD binds the ciphertext to the
  Group, name and kind. The root protects a copied object store; application
  compromise is outside this boundary.
- Metadata in clear: name, kind, optional host and model, `created_at`,
  `updated_at` and `last_used_at`. A successful use writes `last_used_at` at
  most once per hour, and a failed write does not fail the use.
- Lifecycle: the Agent creates, replaces and deletes secrets with
  `device.secret_save`, `device.secret_list` and `device.secret_delete`.
  Workspace owners list and delete them with `GET` and
  `DELETE /v1/comma/workspaces/:workspace_id/device-secrets[/:name]`. No API
  returns a value. Group deletion removes the record before it removes the
  Group record. There is no Workspace export.
- Relationships: `device.lan_script` takes `secrets`, which maps an args key
  to a secret's name: Salix puts the value into the script's args at
  dispatch, defaults `args.host` to the saved host, and removes the value from
  what the script returns. A missing name fails with `saved_token_not_found`.
  The gateway that runs the script receives the value.
  `device.lan_request` takes `auth.secret_ref`, the name of an
  `onvif_password`, and inserts a WS-Security UsernameToken with its
  PasswordDigest into the SOAP body at dispatch. With `auth.type:
  "http_digest"` it answers a `401` Digest challenge with the same password,
  and for an `rtsp://` url it answers the camera's RTSP challenge with it
  ([RtspSnapshot](../../systems/apps/salix_agent/lib/salix_agent/rtsp_snapshot.ex)).
- Information flow: `device.secret_save` is a `:persist` effect with the
  Group's audience, because every Agent of the Group can list the name, host
  and model and can use the value.

Implementation: [store](../../systems/apps/salix_agent/lib/salix_agent/device_secrets.ex),
[tools](../../systems/apps/salix_agent/lib/salix_agent/tools/device_secrets.ex),
[miIO tool](../../systems/apps/salix_agent/lib/salix_agent/tools/miio.ex),
[ONVIF auth](../../systems/apps/salix_agent/lib/salix_agent/onvif_ws_security.ex),
[Comma routes](../../systems/apps/comma_web/lib/comma_web/router.ex).

### Device Setup Offer

When the Comma Android app opens, it scans BLE briefly for unprovisioned Comma
devices (the T-Circle-S3 advertises its model, state and a 4-hex short id) and
reports them with `POST /v1/comma/workspaces/:workspace_id/nearby-devices`.
A new device gets an offer: a Router Message in Home with fixed template text
and a `device_setup_offer` content block, which the reporting phone renders
as a Connect button into Add device.

Existing concepts cannot represent it. A Device exists only once its
Connector connects, and the offer is about a device before that. A Capability
Request answers one Agent tool call, and no Agent asked here. A Home matter
(`MailInteraction` value) is an owner's source item that the Router judges,
and this offer needs no model and no Router decision. Task status cards follow
a Task.

- Identity: `offer_id` (`dso_…`). Offers in `open`, `started` or `dismissed`
  suppress new offers for the same Workspace and short id for 30 minutes,
  under a transaction lock. `done` and `expired` offers do not suppress new offers.
- Scope and owner: [DeviceSetupOffers](../../systems/apps/comma_web/lib/comma_web/device_setup_offers.ex)
  owns `comma_device_setup_offers` rows in one Workspace and its Group.
  Reporting and resolving need the same admission as minting a connector
  token: a full session of the Workspace owner.
- Lifecycle: `open`, then `started` (setup began on the phone; another 30
  minutes), `dismissed`, `done` (the device connected) or `expired` (30
  minutes without completion). Terminal statuses do not change. A matching
  device connection completes all `open` or `started` offers for the same
  Workspace and short id.
- Relationships: the Home Message is appended once (`client_request_id`
  `device-setup-offer:<offer_id>`). Each status change takes the next
  `revision` and queues a hidden `device_setup_offer.updated` app event with
  the whole card. A job that reads a newer revision skips its stale snapshot.
  Repeated `started` actions also take a new revision when they extend setup.
  Clients select the highest revision across the initial Message and update
  events, not the latest Message sequence. A delayed event must not replace
  a higher revision. The Router receives the offer as context that does not wake it,
  and answers a text reply that setup happens on the phone.
  Reaching `done` appends one more template Router Message in Home
  (`device-setup-offer-connected:<offer_id>`) that says the device is
  connected and points to its Access in Settings › Devices; it is pushed
  like any Router Message.
- Device match: device records hold no MAC address. A Workspace device matches
  when its id is the one the app gave with `started`, or its name, alias or
  hostname ends with `-<short id>`. An online match gets no offer. Salix calls
  the product's device-connect observer after a Connector connects; a match
  closes the offer as `done`.
- The "automatic messages" switch does not apply: it governs background
  attention on the owner's sources, and this offer answers the member's own
  app opening without a model call. The Router Message notifies like other
  Router replies.

Implementation: [offers](../../systems/apps/comma_web/lib/comma_web/device_setup_offers.ex),
[Home product events](../../systems/apps/salix_im/lib/salix_im/conversation_server.ex),
[connect observer](../../systems/apps/salix_env/lib/salix_env/registry.ex).

### Linear agent installation

[Comma.LinearInstallations](../../systems/apps/comma_core/lib/comma/linear_installations.ex) owns a Linear Installation: one Linear organization that installed Comma as an agent, held by the Workspace that installed it.
It is a product authorization relationship like the iMessage and Telegram bindings, not a Conversation, IM Connect, or Agent.
Reuse is insufficient because no existing concept holds an `actor=app` OAuth installation with its organization identity and app user id.
The holding Workspace's owner creates it and removes it for everyone. A Linear `OAuthApp revoked` webhook retires it; retired installations accept no sessions and post no activities, and the next connect installs again.
The access token is a Salix OAuth connection referenced by `connection_id`; the installation adds no credential identity.
The deployment's Linear OAuth application is configured under `:comma_web, :linear_agent`; installation uses `actor=app` with scopes `read write app:assignable app:mentionable`.

A Linear Member links one Linear user of that organization to one Workspace (`comma_linear_members`, same owner module).
It is a product identity link, not a Workspace member or an Agent: it records which Linear user the Workspace's owner is and the completion policy. It names no Worker: a Task for a delegated issue runs where and on what the Workspace's defaults say. The stored `worker_agent_id` is ignored and answered as null for desktop apps already shipped.
Reuse is insufficient because Workspaces have one owner and no concept names a user of an external organization.
Its identity is the pair (installation, Linear user id); a Workspace holds at most one link, and the latest authorization wins on both sides.
A person creates it from their Workspace: they authorize as themselves (`actor=user`, scope `read`), which tells Comma their Linear user and organization; the person's token is revoked as soon as it is read. When the organization has no active installation, the callback continues in the same window to the `actor=app` installation, which the person's Workspace then holds; an installation that landed meanwhile is joined instead, and its holder stays. The install step refuses an organization other than the linked one; it revokes that token only when no Workspace holds that organization.
An `OAuthApp revoked` webhook retires the installation only after its own token fails a check, since a person revoking their own authorization reports the same event.
The owner removes the link; removing the installation removes every link. A link that disappears leaves its Tasks in their Workspace.
A Workspace that holds one organization's installation while linked to another sees and manages only the linked one; the held installation stays until that organization removes Comma.

`POST /v1/comma/integrations/linear/webhook` verifies `Linear-Signature` (HMAC-SHA256 over the raw body with the application's webhook secret) and a five-minute `webhookTimestamp` window, then answers inside Linear's five-second budget. Task creation runs after the answer.

A Linear AgentSession maps to one `user_chat` Conversation with the Router in the Workspace of the member whose Linear user created it (`agentSession.creatorId`). [CommaWeb.LinearAgentSession](../../systems/apps/comma_web/lib/comma_web/linear_agent_session.ex) creates it with the Workspace owner and the Router as Participants, owned by the owner, and appends the issue as a `provider_user` Message the Router answers; the Router's Messages there become `response` activities, so a question, a triage or a summary needs no Worker; the Router's own model calls are billed like any chat message.
The Workspace owner opens that chat in Comma by the session's link and writes in it like the Workspace chat: [Comma.Conversations](../../systems/apps/comma_core/lib/comma/conversations.ex) reads and accepts Messages for a `user_chat` whose `owner_user_id` is the Workspace owner and whose `source_refs` carry `linear`, beside Tasks and the Workspace chat. Linear sees whole exchanges: a Router Message answers the latest human Message before it, and only an answer to a Linear prompt becomes a `response`; an exchange the owner started in Comma stays in Comma.
The `comma_linear_agent_sessions` row is the creation receipt and an inbound route index from the session to that chat and its Workspace, like the Telegram topic projection. A redelivered `created` webhook finds the same chat. It adds no Conversation, Session, or lifecycle authority.
A creator without a link gets one `error` activity that says how to connect; nothing starts.
Follow-up prompts append `provider_user` Messages to the chat whose `source_message_id` is the Linear activity id.

When the Router creates a Task while answering that chat, the Task carries the chat as `parent_conversation_id` and inherits its owner. At creation, `TaskConversationInput` asks the product (`origin_provider_participants_adapter`) for the Participants such a Task keeps: the session's `linear` Participant. The session row records the Task (`task_conversation_id`): one at a time, a Task created while the bound one still runs gets no Participant, and one created after it reached review or ended takes the binding over; the Task that lost the binding posts nothing more. Once the Task is seen to exist, the issue moves to its team's first `started` state unless it is already started, completed or canceled, and the session gets the Task link, labelled with the Task's title so the links of successive Tasks read apart; a Task that never comes to exist loses the binding again.
The `stop` signal appends the request to the chat, then ends the bound Task as the owner of its Workspace through the existing manual status transition (`cancelled`, a soft stop) and answers once; without a Task it answers that nothing is running. The cancelled status then posts no error. A redelivered stop answers nothing; a stop after the Task ended says so and changes nothing.
An `Issue` webhook ends the same way the Task still working (`active` or `escalated`) for that issue when the issue moves to a `completed` or `canceled` state, is deleted, or is taken away from Comma's app user (its `delegateId`, or `assigneeId`, leaves the app user): the reason lands in the Task as a Linear Message, the Task ends as cancelled by the owner, and the session hears that Comma stopped, except for a deleted issue, whose session is gone. A Task in review keeps its answer; any other issue change is ignored, including edits to an issue that was already closed. The sessions of an issue are found by (installation, issue id).

Outbound mirroring uses one `linear` provider Participant with role `linear_agent_session` on the chat and on the Task. Its payload carries the installation id, the session id and the surface (`chat` or `task`).
In the Task, Worker Messages become `thought` activities. A `ready_for_review` or `completed` status becomes one `response` whose body is the latest Worker text; a repeated status with the same body posts nothing. `failed` and `cancelled` become `error`.
A Message naming a GitHub pull request adds that link to the session beside the Comma links.
Issue state moves are best effort and never gate the Task: a review or completion applies the member's policy (`unchanged`, the team's In Review state, or its first `completed` state) unless the issue is already completed or canceled.
Conversations own their lifecycle. Linear session state follows the posted activities and never changes them.

### Telegram Task topic projection

[TelegramTaskTopics](../../systems/apps/salix_im/lib/salix_im/telegram_task_topics.ex) maps a Comma-managed private chat topic to an existing Task Conversation.
The connection and Task own the creation reservation. A topic address provides an indexed inbound route.
The existing Telegram Participant owns outbound delivery. These records add no Task, Session, or lifecycle authority.
An address never moves between Tasks. Disconnect retires transport access, without deleting the Task or its messages.
Topic creation uncertainty requires operator recovery. Topic closure does not cancel work.
The inbound index uses the existing bot, chat, and topic address. It rejects a retired connection after reconnect or Workspace switch.

### Comma proactive attention relationships

Proactive attention adds no lifecycle entity. Automatic messages are on by default, and the owner can turn them off in Routine settings.
Home Conversation metadata owns that switch beside the budget. ConversationActor checks it in the same write that reserves an automatic message.
While it is off, the collection chain stops, trigger events read nothing, and the consumer judges nothing.
Turning it on again resets the owner's Member Source Items. The next collection records a new baseline, so nothing that arrived while it was off interrupts.
One collection job per owner runs in the existing Oban queue every 15 minutes, at most 96 bounded member collections a day.
Home entry starts the chain. A waiting or running collection absorbs later entries, and each collection schedules its successor. The chain stops when the owner no longer holds the Workspace.
Collection reuses the Routine member collector and candidates and records them as Member Source Items. When items wait, it queues the proactive consumer.
The existing Lifeline also recovers orphaned collection, consumer and notebook jobs after eight minutes. Each pass selects at most 1,000 Routine and proactive jobs combined.
Financial refusals keep items pending. A denied billing account cancels the current judgment job without immediate retries. A later collection queues another judgment.
Routine failures retain their billing cause and previous briefing. Insufficient credits expose `lastError: insufficient_credits` through the Routine API.
A Gmail or Outlook trigger event reads that one source sooner. See [Member Source Items](#member-source-items).
A source recorded for the first time is a baseline and interrupts nobody. Only items that arrive or change later wait for consumers.
With waiting items, the consumer screens each matter in its own model call, at most eight calls at once and 24 matters for each check, each with 2.4 KB of Home history and without a Router turn. A batch call reasons over every item and outlasts the timeout, so matters are not batched. Closed budgets limit handoffs and notifications, not this screening.
The screening is the only place that decides whether a matter interrupts the owner. The Router delivers that decision and does not judge importance again. One bar decides, the same in the screening prompt and in the proactive skill: a matter interrupts only when the owner must act before the next daily briefing, or when a cost that cannot be undone lands within seven days and the owner may need the days. It does not interrupt when the latest evidence shows the matter resolved, taken up by another person or an agent, or already answered by the owner. A person who mentions the owner directly and asks them to look, answer or decide is waiting on the owner now, even when the message is short and names no deadline. Remarks in a thread that do not address the owner do not count. An agent or bot that asks the owner counts only when its request lapses (a sign-in, a code, an approval window) or when it blocks another person, a customer or a deployment now. An agent that waits for the owner's review, opinion or go-ahead on its own work is briefing. A request that lapses unless the owner acts, such as an invitation, an approval, a code or an offer, meets the bar when it lapses within three days. An automated report about work, such as a failed CI run, a monitoring alert or a digest, is briefing unless the evidence shows a person blocked now, users of the owner's product affected now, or the owner asked to be told. When people in the report's thread wait on the owner, or on a person the owner plausibly is, it is judged as their request. A production system, job or monitor that is the owner's duty and has stopped working counts as users affected now, even when its alert names only a bot. A blocked development workflow, such as a stuck CI run or a pull request that cannot merge, is briefing. A notice about the owner's own account, device or money, such as a sign-in they may not recognize, a new credential or a payment, is judged by its cost. Every other matter of the owner goes to the daily briefing and the notebook.
Before the screening, the consumer groups the items into matters without a provider read or model call: items that name the same GitHub pull request, issue or Actions run, Linear issue, Notion page, Drive file, Slack thread or email address are one matter. A key that more than six items share joins nothing. The screening reads each matter through its newest item, with up to four others as `related`, and settles, retries or hands over every item of the matter together. Matters are run-local values, not entities.
Before the screening, the consumer reads the current state of the candidate matters' links with the owner's managed GitHub or Slack grant, outside the item locks: an Actions run's status and attempt, a pull request's or issue's state, the last messages of a Slack thread, and for a message posted straight in a channel, the channel's messages in the hour after it. It reads at most three links for each matter and at most eight matters for each check, newest first. A mail whose pooled excerpt was cut off, or whose attachments were not read, is read in full once through the owner's consented mail account before the screening, at most eight mails for each check. The screening reads them as `linked`, and the handoff carries the same `linked`. A link that cannot be read is left out. A handed-over matter whose links were not read before the screening is read at the handoff; the handoff carries that read as `linked_after_screening`, evidence the screening did not have, for which the Router may withhold the matter.
For each matter, the screening returns whose move it is (`role`), what happens if the owner does nothing (`cost`, `due` time and whether it is `reversible`), and a `decision`: `interrupt`, `briefing`, `resolved` or `ask`, with a one-sentence `reason` that cites the evidence. An `interrupt` matter also gets a plain-text message. The role is `act` (the owner must do something), `waiting` (another person or an agent has the next move), `calendar`, `someday` or `reference`. Seeing an item is not owning it: a subscription or another person's pull request is `reference`. Importance does not depend on whether the item is work or personal. Mail and notices addressed to the owner are about the owner unless the evidence shows otherwise. The server does not change a decision. `ask` marks a matter that waits on an unnamed person whom the owner plausibly is; the Router asks the owner instead of reminding them. `resolved` settles the matter when `linked` or the Home history shows it closed or answered.
The screening also reads the owner's latest Home matters, at most 20 changed within 60 days, as the notebook shows them: subject, state, level (the projection of the screening decision: `interrupt` is high, `ask` is ask, `briefing` is normal, `resolved` is low), the Router's decision and reason, cost and due time. It may answer that the item `continues` one of them, a later step of or new evidence about the same matter in another thread; the handoff carries that matter's subject, level and Router decision to the Router, and the notebook shows the two together. The screening also reads the owner's Router memory file `/memory/semantic/user.md`, the portrait first. The portrait adds no entity: it is a section of that file between `<!-- comma:portrait -->` markers, at most 1,536 bytes, one line per entry: a name or account of the owner, a duty, ongoing work, a place, a preference or an exclusion, each with the date it was last confirmed. The Router corrects it with its memory tools. Only a Workspace whose owner is its only member gets a portrait.
The screening also reads the owner's proactive notebook as last rendered (`/Comma/Notebook.md`, see below) with each candidate: what needs the owner, the briefing, what comes up later, what waits on others, the owner's open threads, the watches and the portrait. It leaves out what Comma did not interrupt the owner about and what is done, and cuts the rest at a line end within 10,000 bytes. It reads the notebook only while the owner is the Workspace's only member, also before a render deletes it. It reads each candidate with that context. A candidate that delivers, answers, changes or repeats something the notebook lists, also from another source or thread, such as a release mail for a release the owner asked about in Slack, is judged as part of it, and its reason and message say how it relates. The same bar decides. A candidate that relates to nothing listed is judged alone. A notebook that is missing or withdrawn is left out.
A portrait line can end with `watch:` targets that the input names: Slack channels (at most eight) and GitHub repositories (at most three); an exclusion's targets are never read. In the first collection of each hour, the Slack member read adds the last day's bot posts and requests in those channels, at most five threads each and ten in total, as `posted_where_your_work_is`, and the GitHub read adds each repository's failed Actions runs of the last day as `failed_in_your_repo`. The judgment gets each item's minutes since arrival; a login or verification code at most ten minutes old is `interrupt`, and the proactive skill sends it only to Home.
A collection queues the day's portrait refresh. It reads the owner's own Slack messages of 30 days, at most 15 thread starts, at most 30 of the owner's own pool items from other sources (pull requests, assigned issues, edited pages), the Home history and the rest of the file, and asks the Router model once without tools. The server keeps an entry only with evidence from that input or as an unchanged earlier entry, and drops an entry not confirmed for 60 days unless it is an exclusion or a preference. It then rewrites only the portrait section through the Router's workspace operation, billed as storage. A failed refresh changes nothing. The notebook lists the portrait.

The team glossary adds no entity either. It is the Router memory file `/memory/semantic/glossary.md` that the meeting paths read (`Salix.Bindings.MeetingGlossary`): its correct forms go to the recording ASR, and its corrections (`heard → Right`) replace text in transcripts and meeting memory. The Router writes its own lines with `memory.write` when a person corrects a name; Comma never changes or expires them and adds nothing they already hold. Comma keeps a section between `<!-- comma:glossary` markers ([member glossary](../../systems/apps/comma_web/lib/comma_web/member_glossary.ex)) with two kinds of entries. A correction comes only from the owner's own words: the server keeps one only when both forms appear in the owner's messages of one desktop meeting Task, and it does not expire. A name (`→ Right`) only guides ASR spelling; the Router model may find it in the owner's messages or in `/memory/semantic/people.md`, its form must appear there. It stays while `people.md` holds it; otherwise it expires 60 days after the owner's new messages last showed it, as the server, not the model, checks. A line of the section Comma does not recognize stays as the Router's, and a section without its end marker ends at its first line that is not an entry. The section's start marker holds where the last refresh stopped reading. A refresh reads the messages the owner wrote after it (not those Comma sends under the owner's name, such as the recording instruction), from meeting Tasks active since then and the Home conversation, at most 16,000 bytes, and the next one continues; it lists at most 4,000 Tasks active since then, newest first, and does not read older ones beyond them. The first refresh reads meeting Tasks of the last 60 days. Comma's section stays at the end of the file, so a Router line wins a heard form, and the owner's newer correction replaces Comma's older one. Without new messages and with an unchanged `people.md` it asks no model. At most one refresh runs a day per Workspace, queued with the portrait's collection and by a daily sweep ([sweep](../../systems/apps/comma_web/lib/comma_web/member_glossary_sweep.ex)) of Workspaces whose owner was seen in the last day, one page of 500 Workspaces a job. Only a Workspace whose owner is its only member gets the refresh.

The server validates the matter IDs and hands each `interrupt` or `ask` matter whose role is `act`, with its assessment, reason and `linked`, to the canonical Router session as hidden Home input. One check hands over at most three matters, earliest `due` first, then oldest arrival. Other roles settle as `waiting` or `quiet` with their role. `briefing` matters stay in the daily briefing and the notebook. An `interrupt` matter that this check did not hand over stays pending and is screened again at the next check.
The judgment also says what ties the item to the owner (`link`: named, assigned, authored, review_requested, account, portrait, conversation, subscribed or none). An item whose link is `subscribed` or `none` reaches no one: watching or being copied is not responsibility.
The judgment also says whether the item only `repeats` a listed matter: a copy, a resend or another alert of the same failure, with no new cost, deadline, person waiting or change of state. A Home matter of the same key that changed within 24 hours (seven days once handled), or the earlier matter the item `continues` once it was decided `quiet` or handled in that time, absorbs the item only when the judgment says it repeats that matter, unless it decides `interrupt` where the earlier matter did not, gives an earlier due time or makes it reserve-eligible. The server tells a copy from a new event in the same thread or chain only through that answer. A later step that is not a copy reaches the Router with the earlier matter, its state, decision and reason (`continues`), and the Router weighs what the owner already decided. The item settles as `duplicate` with the matter it repeats (`of`).
An item that the judgment did not rate stays pending as `retry`, a bounded number of times; nothing settles it without a rating.
A judgment the model cannot finish (a timeout or a permanent provider error, such as an output limit) ends the check without job retries. Its items stay pending with the failure counted (`failures`), apart from the attempts that bound unusable answers, so a failure a whole batch shares, such as a provider outage, never settles an item. Items a failed judgment returned are judged apart from new arrivals: after a backoff of 15 minutes that doubles with each failure up to 6 hours, when nothing new waits or an hour after the backoff, fewest failures first, in a batch that halves with each failure. An item that failed alone is marked `isolated`; it keeps being retried at its backoff, and the notebook lists it, until it is judged or expires with the pool.
The Router reads current context, writes the reminder and sends it. It withholds a handed-over matter only for evidence that the screening did not have, such as a Home message or a source read after the handoff. It records that with `quiet` and `reason_kind` `new_evidence`. The screening result is evidence, not a user-visible reply.
The consumer routes only while the judged item still waits, unchanged. It holds the item and source state rows locked during the handoff. A revocation, source change, or new collection commits before the check, which routes nothing, or after the accepted input.
The consumer records the outcome and assessment when it settles a rated matter. Routed, briefing and resolved settlements also keep the screening decision and reason. Deferred settlements keep the budget reason instead; duplicate settlements keep the repeated matter reference. Only the handoff carries link evidence; the pool does not keep it.
An `unclear` or unusable screening decides nothing: the matter's items stay pending as `retry` and are screened again, at most three times, before they settle as `invalid`. Other matters of the check are screened apart and do not wait for it. A pool item whose matter the owner's watch follows is not handed over again by the check. The judgment decides only from the evidence. For a handed-over matter, `recommendation.read` returns the item from the latest Routine snapshot, or the pool item when no fresh snapshot names it.
Home Conversation metadata holds two budgets per owner, each an ordinary pool and a reserve. At most twelve ordinary and four reserve automatic Router handoffs in 24 hours bound the Router's cost.
A matter is reserve-eligible only when its assessment's role is `act`, it has a cost, and the cost is due between one day ago and one day ahead, or three days ahead when it cannot be undone, or it cannot be undone and names no time, such as a sign-in the owner may not recognize. A cost that is already landing is due now. The urgency label, the sender and the folder do not decide it; the judgment weighs junk-folder claims by their evidence. The check asks for the reserve with `pool` `reserve`; [MailInteraction](../../systems/apps/salix_im/lib/salix_im/mail_interaction.ex) checks eligibility again from the stored assessment at every spend. It spends the ordinary pool while that is open and the reserve only after it closes; other matters never spend the reserve.
ConversationActor spends the handoff budget when it reserves the hidden input, in the same write that checks it, so concurrent handoffs cannot overspend a pool. The scheduled Routine briefing (`pool` `scheduled`, accepted only on its `["routine", "briefing"]` key) spends no handoff but a cap of its own, two in 24 hours; one generation hands over once by its request ID.
The Router records its decision on the matter with `proactive.act`: `notify`, `quiet` with a reason, or `snooze` to recheck later. The value keeps the latest decision and reason. A `quiet` that withholds a matter the screening decided to interrupt names the evidence the screening did not have and carries `reason_kind` `new_evidence`.
When the handoff or the notification pool the matter may use is closed, the check hands nothing over. The item settles as `deferred` with the `reason` (`handoff_budget`, `notification_budget` or `budgets`), the `pool` and `next_at`, when the pool opens or, for an `act` matter with a due time, when the due time enters the reserve window if that is sooner. A `waiting` item with a due time also gets that `next_at`. Such items wait again from `next_at` (`trigger` `budget`) at most four times (`rechecks`); after that they stay in the owner's next actions. A wait for the matter's own due time (`trigger` `due`) always runs. `next_at` is always later than the check.
`notify` on an automatic matter spends the notification budget: an ordinary pool at least 30 minutes apart and at most five in 24 hours, and a reserve of two for a reserve-eligible matter, which also skips the spacing. `notify` fails while the pool it may use is closed. Staying quiet spends no notification.
The proactive replay keeps a fixed set of real matters from owners who agree to it. It is stored outside the repository because it holds private source content. Each matter carries the decision that the owner's feedback or a reviewed sample confirms. A change to the screening prompt, the bar, the evidence reads or the budgets reports three measures on the full set: the share of handoffs that the Router delivers, the confirmed `interrupt` matters that were not delivered, and the 90th percentile time from arrival to delivery. Each item runs three times, because the model can decide one item differently on two runs; the report names the items whose decision changes between runs. A change is tuned on one part of the set and accepted on matters that did not take part in the tuning. A single case does not accept or reject a change.
The screening timeout comes from the measured latency of one matter's screening, so that at most 2% of screenings fail on time. A failed screening counts toward that measure.
An automatic handoff marks its hidden input `proactive_handoff`; continuations of that turn keep the origin. While an activation holds such an input, `im_api.internal.task.create` must name the owner's message that asks for the Task as `source_message_id`, and a turn that only such inputs started cannot create a draft Task (`proactive.act` `draft`): importance does not delegate work. The Router offers the step and the owner's answer creates the Task. Watch wakes, schedules and Loops keep the origins and authority the owner gave them; no automatic handoff carries standing authority to start work.
Replies, reminders the owner scheduled and reports from watches the owner asked for do not spend the budget.
Only a Router decision creates a visible reminder: the need, an offered next step, then the source link.
Background checks and due reminders cannot select personal IM delivery targets. Queued effects from the removed personal reminder sender fail closed.
The Router uses ordinary reply tools. `proactive.act` with `track` updates source state without sending a message.
Fixed system receipts, Task status cards, and direct Telegram Task topics retain their existing delivery contracts.
Snooze, handled and other actions append hidden app events. Earlier reminders keep a stored `mail_reference` block. Clients render only their text.
A proactive watch is a Background Loop with a Comma owner source binding, enrolled only when the owner asks Comma to follow one matter. Comma installs one bundled source-neutral program. Its `agent.notify` wakes become the owner's Home matter, not automatic, on the one proactive handoff path; the Router input keeps the Loop's origin and label. Salix lets a product that owns a Loop deliver its wakes through the authorization adapter's `deliver/4`; other Loops wake their Session directly.
Generic Loops remain Agent-authored. The binding pins a Workspace, user, connection, and consent revision. Slack, GitHub, Linear, and Notion watches pin the Group's active managed OAuth binding. The Loop may call only the pinned plugin MCP read and receives a bounded projection of it; a Slack thread read keeps its end, where replies arrive. A new watch that cannot start leaves no Loop; a replaced watch returns to its earlier recipe. Each Agent admits at most 16 product bindings. Loop pause/resume and durable events retain their existing owners.
Collection deletes the default Home and Gmail Loops that earlier releases enrolled. It discards their pending events and reads those items from the sources.
A Task may hold existing `source_refs.comma_mail` or `source_refs.proactive` correlation metadata. ConversationServer and ConversationActor own atomic association writes.
This metadata grants no source authority. Every provider read independently checks current consent.
ConversationSearch projects the account/thread for positive discovery only. Routine reads canonical Task status and never creates a Task from lookup absence.
Home Conversation metadata owns bounded source interaction values, keyed by account/source reference. These are not new entities.
The existing snapshot retains at most 18 selected source references and contexts before UI Task rewriting.
Gmail retains canonical account/thread/message identity and optional Task correlation. Other matters use compact source URL references and
the pool evidence version for deduplication, never authorization. Earlier snapshots without a version use their quoted source excerpt. Routine and the proactive consumer share these keys, so handled state hides the matching Routine row.
No generated suggestion title or refresh generation can undo handled state. Older snapshots need a refresh for structured recipes.
Non-mail rechecks read published Routine evidence with its generation/time, not live provider state.
The current Routine member binding and source revision still authorize every read.
A single bounded Home read removes matching handled matters from the Routine rail and attention overview.
A failed Routine run has a status read recipe that expires on recovery. Missing or stale snapshots do not prove completion.
Existing mail_interactions keys and durable values remain in place. Personal App, Telegram and WeChat actions use this same owner.
The value holds current message, owner, generation, handled state, one Schedule, optional Task, and an exact pending command. An automatic handoff adds its assessment and the earlier matter it continues.
ConversationServer and ConversationActor serialize actions. They reserve, perform idempotent effects, append a Message or app event, and finalize.
A failed operation remains pending. The owner can resume it after reload. Due retries resume their saved result before stale-generation checks.
The shared scheduler's `comma_mail` receiver owns timing and occurrence settlement. It preserves its Schedule until the due result commits.
Handled and snooze changes fence older final Home appends. A latest canonical Task read stops ended work without cross-Actor atomicity claims.
A resolved reply delivers once to the existing active Task through its Actor. It cannot reopen a terminal Task.
Routine projects handled source state and canonical Task status. A distinct new message can start new attention after the old message was handled or its linked Task ended.
Capacity is 128 sources and 256 KB per Home value. At capacity a new matter drops the oldest settled matters: handled, quiet or failed, with nothing pending, no Schedule and no Task. Matters still followed are never dropped; when none can be dropped, new tracking fails.
The due decision projects at most eight recent mail messages, 4 KB body text, and 1.2 KB Home history. Omitted evidence is explicit.
A watch Loop screens fresh evidence with the decision tool. Only confident, complete quiet decisions avoid the Router.
Uncertain, invalid, or unavailable screening decisions wake the canonical Router for a fresh source read and a Home decision.
A due reminder rechecks its source. A resolved matter or ended Task stops it. Every other recheck reaches the Router, including one that cannot decide. The due event itself never sends a user message; the Router sends the reminder the owner asked for unless it is resolved.
Comma conversations are also a proactive source. An owned Task that becomes escalated or failed is handed to the owner's Router as a Home matter with key `["task", task_id]`.
Salix calls the product's Task status observer when it publishes a Task status; the publication recovery row makes that call at least once per change. For an escalated or failed Task the observer queues one Oban job per status version; other statuses touch no Comma state. It never mutates the Task.
The job re-reads the Task, requires the Workspace owner, and presents the matter as automatic with the observation `status:message_tail_seq`. One escalation hands over once, also after the owner answered. The switch and the handoff budget apply.
The collection chain closes the matter when the Task left escalated or failed, which re-arms the next escalation even after the matter was handled, and when the owner wrote in the Task after it asked. It checks at most eight task matters from Home metadata and never lists Tasks.
`proactive.state` lists the owner's bound personal chats as `personal_targets`: the exact Telegram or WeChat reply tool and arguments, never credentials. A WeChat target is ready only after the owner wrote once since binding. The Router sends a reminder it decided on to each ready target after its Home reply only while `app_active` is false; the server sends nothing through them. `app_active` is true when a signed-in desktop App reported use in the last ten minutes. The App reports use at most once a minute through `POST /v1/comma/auth/session/activity`, only while the computer had input in the last five minutes, its main window is open, and its system and Router message notifications are on and allowed by the OS. Then a Router reply in Home reaches the owner as a banner or in the open window. [Sessions](../../systems/apps/comma_core/lib/comma/accounts/sessions.ex) records it as `active_at` on the existing Auth Session; it adds no presence entity.  One `notify` spends one notification for every channel.
A published scheduled Routine briefing is handed to the Workspace owner's Router as the automatic Home matter `["routine", "briefing"]`, observed at its generation, with its first items as evidence. The Router notifies only when an item needs the owner today.
Draft actions create one Task through the durable creation receipt. Retries recover that Task. Source-only reminders create no Task.
The proactive notebook is a projection, not an entity. It is one Markdown file, `/Comma/Notebook.md`, in the Router's VFS. The owner reads it in Drive's System Files, read-only, without a device.
The server renders it from the owner's Home values, watch Loops, pool source states and the latest judged pool items. No model writes it.
It also lists the owner's open [Open Threads](#open-threads) and the latest published Routine briefing, also while a run refreshes it or after a failed run, with what happened to each item since, and marks quiet pool items that the briefing includes. Routine publication queues a render.
It groups matters by what needs the owner, what comes up later, what waits, what the Router did not interrupt them about with its reason, and what is done. Each Home value keeps the time it last changed for this order. Judged pool items whose role is `act` and that were not handed over, quiet or deferred with the reason and `next_at`, come up later; `waiting` items wait. `proactive.state` lists the same items as `next_actions` and `waiting` for the Router, under the same single-member rule. A change to the source item, a due-time recheck or a deferral's `next_at` judges it again.
Matter changes, owner-scheduled due reminders, collections and proactive checks queue one render. Renders merge within one minute. A render equal to the stored file writes nothing, and source read times show only the hour.
A lost or edited file is replaced by the next render.
Every member's Router turn can read the Router's VFS. The notebook holds private source titles, so it is written only while the owner is the Workspace's only member. Otherwise the render deletes it.
`proactive.state` returns its VFS path when the file exists, so the Router can point to it.
Implementation: [product controls](../../systems/apps/comma_web/lib/comma_web/proactive.ex),
[proactive notebook](../../systems/apps/comma_web/lib/comma_web/proactive_notebook.ex),
[proactive consumer](../../systems/apps/comma_web/lib/comma_web/proactive_check.ex),
[attention judgment](../../systems/apps/comma_web/lib/comma_web/recommendation_renderer.ex),
[member portrait](../../systems/apps/comma_web/lib/comma_web/member_portrait.ex),
[matters](../../systems/apps/comma_web/lib/comma_web/proactive_matters.ex),
[linked evidence](../../systems/apps/comma_web/lib/comma_web/proactive_evidence.ex),
[bundled watch and consent](../../systems/apps/comma_web/lib/comma_web/proactive_watch.ex),
[personal destinations](../../systems/apps/comma_web/lib/comma_web/proactive_delivery.ex),
[Routine projection](../../systems/apps/comma_web/lib/comma_web/proactive_routine.ex),
[mail Task projection](../../systems/apps/comma_web/lib/comma_web/recommendation_mail_tasks.ex),
[Home owner value](../../systems/apps/salix_im/lib/salix_im/mail_interaction.ex),
[Home API and receiver](../../systems/apps/comma_web/lib/comma_web/home_mail.ex).

### Member source items

A Member Source Item is one normalized item that reaches a member through a connected source: mail, a message, a pull request, an issue, a document comment or an event.
Reuse is insufficient: a Recommendation Run holds source evidence only until it settles, and a Snapshot keeps only selected items. Consumers need arrivals and changes across runs.
Identity is the Recommendation Profile, the source account and the item URL digest. Scope is one member in one Workspace.
Collection is the only writer of item content. It stores bounded excerpts, never raw provider payloads: title, a 1,200-character excerpt, a 600-character prompt context, a 1.2 KB context, relationship, recipient, facts and mail IDs.
A version fingerprint covers all bounded stored evidence, including dates, roles and surrounding context, not only the shortened prompt. A changed version waits for consumers again. Each consumer owns its own outcome on the item.
Collection also stores the record's source quote, which the Routine card shows under its task and a briefing link shows on hover. It is display text outside the version, so each collection rewrites it in place, and a new wording keeps the version, the outcomes and the queue position.
An item waits for consumers only while its source's latest successful collection returns it and no later attempt failed as a whole. Mail the member answered leaves the result and stops waiting.
Mail collection also reads the junk or spam folder. It keeps at most 10 recent junk items outside inbox threads, with the relationship `in_your_junk_folder`. A failed junk read leaves only those items out.
An item expires 5 days after collection last saw it. An hourly sweep deletes it. Each source keeps at most 400 items.
Each source also has one collection state in the pool: the last attempt, the last successful collection and the items it returned, the member subject, any failure and the trigger ID.
The state has no lifecycle of its own. Collection writes it, and it leaves with the source's items.
Disabling or removing a source, rebinding its app, disconnecting its account or removing the app deletes the source's items and state at once. Leaving member mode deletes all of them. The setting change and the deletion commit together. Recording rechecks the locked profile selection and current source binding, so late reads cannot restore withdrawn items. Source purges share the profile lock. Profile deletion deletes both.
A source collected for the first time, or not collected for 5 days, records a baseline: its items are history, not arrivals, so expired history never returns.
A member Routine Run reads each source's latest successful collection, in the order the source returned its items.
It collects first when a source was not attempted within the Run's window, when its latest attempt failed, or when the member changed the account binding.
The window is the 15-minute collection interval for a scheduled Run and one minute for other Runs.
Collection runs every 15 minutes for the owner, and when a Routine Run needs it.
When the Composio settings have webhook ingress, collection also creates one trigger for each owner Gmail or Outlook source and records its ID.
A trigger event only schedules a read of that one source, at least one minute after the source's previous read. The event data is neither stored nor shown.
Mail screening uses the provider receipt time for age, not the first collection time. A missing or invalid receipt time leaves age unknown.
The provider trigger stays provider-owned. Removing the source deletes only the recorded ID.
Items grant no source authority. Consent and bindings authorize every collection.
Implementation: [item pool](../../systems/apps/comma_core/lib/comma/member_source_items.ex),
[collection](../../systems/apps/comma_web/lib/comma_web/member_source_ingest.ex),
[triggers](../../systems/apps/comma_web/lib/comma_web/member_source_triggers.ex),
[ingress](../../systems/apps/salix_web/lib/salix_web/composio_webhook.ex),
[retention](../../systems/apps/comma_core/lib/comma/workers/member_source_item_retention.ex).

### Open threads

An Open Thread is something the Workspace owner left open in their own messages: a promise (`promised`), a question nobody answered yet (`asked`) or a problem they raised (`blocked`).
Reuse is insufficient. A Member Source Item is what reaches the member, expires after 5 days and has collection as its only writer; an open thread comes from the owner's own messages, lasts weeks and keeps the owner's correction.
A Home matter is the Router's reminder state with budgets and decisions; an open thread interrupts no one by itself and spends nothing. The proactive screening reads the open ones through the notebook, so a later arrival about one is judged with it. The portrait is free text without per-entry state.
Identity is the Recommendation Profile, the source, the provider thread (`slack:<channel>/<thread ts>`) and the kind. Scope is the owner of a single-member Workspace.
`CommaWeb.OpenThreads` is the only writer of content. Once a day, beside the portrait, it reads through the first enabled Slack source and asks the Router model without tools, billed as the portrait. Discovery is best effort. Each refresh reads the newest 100 own messages of 30 days, with the first 15 messages of at most 15 of their threads, read one at a time, and sends the model those after the source's cursor (the first refresh starts a day back), in batches that each fit 60 messages and 24 KB; a message too large alone is cut to fit. The cursor then moves to the newest message sent. When more than 100 messages arrived since the last refresh, the older ones are skipped and the job logs it. A failed batch moves nothing, so a retry may judge earlier batches again. A question someone answered counts as resolved; an acknowledgement alone does not. An answer lists at most 5 open threads. Tracking reads, one thread at a time, the messages since the last check of at most 10 open uncorrected threads, those read longest ago first (`tracked_at`), so every open thread takes its turn; a read without news counts as a turn. It asks the model once which of those with news are closed. A thread's checked position moves only when the model judged it, so news the model did not judge is read again. The cursor is a per-source row (`comma_open_thread_cursors`) with the threads' lifecycle.
The server keeps a thread only when it cites a permalink of those messages, and only that thread's cited messages are its evidence. A later message in the same thread updates it. A thread the answer leaves out keeps its state.
The owner corrects a thread through the Router with `proactive.thread`, only while they are the Workspace's only member: `resolved`, `dismissed` or `open`. A resolved or dismissed thread keeps that status and its text until it expires; no extraction changes it. `open` returns it to the extraction. A correction takes the profile lock that recording holds, so it lands wholly before or after an extraction.
Silence never closes a thread. A thread expires 45 days after its latest evidence: reads leave it out, and the hourly retention sweep that deletes expired source items deletes it. Retention is longer than the 30-day read window, so a correction outlives the messages that could bring the thread back.
A profile keeps at most 40 uncorrected threads; the oldest beyond that leave. Corrections leave only by retention.
It runs only while automatic messages are on and the owner is the Workspace's only member. Otherwise the job deletes the owner's threads.
Recording holds the profile lock that source purges and setting changes take. Under it, the job checks again that the source is enabled, that the account the read used is still the source's current member account, and that the owner still holds a single-member Workspace with automatic messages on. A read that a rebind, revocation or setting change overtook records nothing.
Open threads share the item pool's source lifecycle: disabling or removing the source, rebinding or disconnecting its account, removing the app, leaving member mode or turning automatic messages on again deletes them with the source's items. Profile deletion deletes them.
The notebook lists at most 5 open threads by priority: a due date first, then promises, then the newest, and counts the rest. `proactive.state` lists every open one and the 12 latest resolved ones as `open_threads`, so the Router can show what the notebook only counts. The proactive screening reads the ones the notebook lists as context for each candidate; an open thread starts no screening by itself and does not reach the briefing or a handoff.
Implementation: [threads](../../systems/apps/comma_core/lib/comma/open_threads.ex),
[extraction](../../systems/apps/comma_web/lib/comma_web/open_threads.ex),
[retention](../../systems/apps/comma_core/lib/comma/workers/member_source_item_retention.ex),
[Router correction](../../systems/apps/comma_web/lib/comma_web/proactive.ex).

### Platform alert handling

[Alert Router Incident](../../systems/apps/alert_router/lib/alert_router/data/incident.ex) owns the source alert, Slack root, owner, and latest attributed report.
A Slack user claim or owner transfer changes the existing owner. A report does not verify recovery or close the source alert.
The handling revision fences scheduled reminders after a report or owner change. It is not a separate lifecycle entity.
[EventRecord](../../systems/apps/alert_router/lib/alert_router/data/event_record.ex) retains both source events and handling notices.
The existing delivery workers own channel/thread delivery, leases, and uncertain-result reconciliation for both.
[Remind](../../systems/apps/alert_router/lib/alert_router/workers/remind.ex) schedules one overdue notice per handling revision.
It does not own incident closure or service recovery. See [alert handling](../observability.md#slack-cards-and-investigation-progress).

### Paid-work admission

`BillingCore.FeeControl` owns availability; runtime owners own operation outcomes.
[BillingAvailability](../../systems/apps/salix_agent/lib/salix_agent/billing_availability.ex)
normalizes `billing_unavailable`, its reason, message and retryability. It stores no balance.
`insufficient_credits`, `account_inactive` and `missing_account` end the current attempt
without automatic business retry. Billing infrastructure errors retain existing recovery.

Paid platform LLM calls require at least one spendable credit before dispatch, including
background and auxiliary calls. Free Router models, tenant credentials, account pools
and unlimited grants retain their existing exemptions. This is availability admission,
not a reservation or a guarantee that an unknown-duration call cannot exhaust its balance.
Actual incurred usage still reaches the existing charging seam.

Cloud VM creation, archive wake, runtime installation and paid voice start check at request
and execution boundaries. A known refusal returns immediately through tools and Session
errors, instead of waiting for READY. It does not discard files, archives, credentials or
prior usage. A suspended resource remains recoverable under its existing lifecycle;
a rejected command is not automatically replayed when credits return.
Installation refusal retires only unclaimed pending targets. An accepted installation
keeps its existing claim owner and can commit its result.

Internal Sessions commit existing `llm_call_failed` at the materialized transcript HWM,
with `retryable=false`, then use existing failure notification and settlement. Matching
input cannot trigger another provider call after restart. Accepted messages, running tools
and their results remain. Explicit resume or new input authorizes again. Existing
`runtime_failure_reply` carries the financial reason after notification/compaction;
financial failures must not appear as model connection failures.
A tenant-funded call (tenant credentials or an account pool) whose provider reports an
exhausted account (HTTP 402, `insufficient_quota`, `billing_error`, a too-low credit
balance) uses the same path with reason `provider_quota_exhausted`. Its notice names the
provider account instead of Comma credits, and chat raises a provider toast rather than the credit toast.
A platform-funded call with the same provider report uses the path with reason `model_unavailable`.
The member cannot fund the platform's provider account. The Participant issue asks them to choose
another model or try again later, and the notice keeps the model failure text.
Each such refusal, and each platform-funded call whose key the provider rejects (401 or 403),
is counted in `salix_llm_platform_account_failures_total`, which pages operators (`platform_model_account_failed`).
The platform's DeepSeek balance is read every 5 minutes into `salix_llm_platform_account_balance`;
a low balance raises `platform_model_account_low_balance` before the account runs out.
The failed attempt records the catalog source and the member's Profile id and name, never a credential.
The Participant status publishes them as a bounded `issue_detail` with that issue only.
Clients name the provider and Profile, link its billing page when known, and open
Model & API at that Profile.

Implementation: [LLMMetering](../../systems/apps/billing_core/lib/billing_core/metering/llm_metering.ex),
[Drive](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Drive.lean),
[Cloudflare](../../systems/apps/salix_web/lib/salix_web/compute_providers/cloudflare.ex),
[VoiceMetering](../../systems/apps/billing_core/lib/billing_core/voice_metering.ex).

An idle Session projects the financial reason.
