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
| Group | A Salix Agent work scope within a Tenant. Comma Workspace references its current Group and generation. The Group owns its outbound SSH client key and trusted SSH host keys (see [Outbound SSH Session](#outbound-ssh-session)). Its Cloud VM switch (`cloud_vm_enabled` on the Group record, [Salix.Control.Groups](../../systems/apps/salix_web/lib/salix/control/groups.ex)) alone decides whether its Agents may start the Group's Cloud VM and place Tasks there ([CloudVM.allowed?/1](../../systems/apps/salix_agent/lib/salix_agent/cloud_vm.ex)); no Agent has a Cloud VM setting. Comma sets it from the Workspace's `vm.enabled`, BFT from the Project's `vm_enabled`. Before the rollout, migration `20261019120001_group_cloud_vm_switch` ([SalixAgent.Migrations.GroupCloudVMSwitch](../../systems/apps/salix_agent/lib/salix_agent/migrations/group_cloud_vm_switch.ex)) turned it on for every Group with a live Agent that had `vm.enabled` or a Cloud VM binding. After the rollout, the release's post-rollout job ([Comma.Release](../../systems/apps/comma/lib/comma/release.ex)) runs that pass again, removes `vm` from every Agent record, then sets each Workspace's and Project's Group switch from the product's own fact. The marker `group_cloud_vm_switch_v1` in `salix_cutover_markers` records the next page, so a run cut off resumes there and a run after the last page does nothing. BFT queues a switch refused by a Salix node of the release before until a new node takes it. |

Owners and entry points:
[Comma accounts](../../systems/apps/comma_core/lib/comma/accounts.ex),
[Workspace and Membership](../../systems/apps/comma_core/lib/comma/data/schemas.ex),
[Workspace authorization](../../systems/apps/comma_core/lib/comma/workspaces.ex),
[BFT Organization](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/organization.ex).

The client core's [Electron session lifecycle](../../clients/packages/core/src/session/electron-lifecycle.ts) owns local Auth Session recovery; [Main's session host](../../clients/apps/electron/src/main/modules/session/session-host.ts) keeps its bearer and gate.
A configured backend change removes credentials for other origins before login, without changing server sessions or unrelated profile data.

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
[TaskActivityProjection](../../systems/apps/salix_im/lib/salix_im/task_activity_projection.ex) owns only a disposable display index under `ctl/group_task_activity/<group>/`.
ConversationStore writes it through Conversation owner mutation and repair. The Group owner rebuilds it from canonical metadata with a persistent cursor.
Each rebuild page reads at most 20 canonical metadata candidates, with four concurrent operations and five-second caller budgets.
Only eligible Tasks need Conversation owner repair. Caller timeout does not cancel accepted owner work. Larger Groups use queued continuation.
The foreground API and APNs share this indexed top-two query. Rebuild pending returns a retryable error and does not end an existing activity.
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

Telegram Task review cards reuse the existing provider Participant and status delivery. At Task creation, [TaskConversationInput](../../systems/apps/salix_im/lib/salix_im/task_conversation_input.ex) asks the product adapter for the Workspace owner's bound private chat and adds one `task_status_personal` Participant. It subscribes to all status events and to no Messages. Only review, escalation and failure send new cards. Intermediate states retire the previous card, so a later review round sends a new card. [TelegramTaskCards](../../systems/apps/comma_web/lib/comma_web/telegram_task_cards.ex) authorizes each send against the current [Telegram link](../../systems/apps/comma_core/lib/comma/telegram_links.ex) and never resends an uncertain card. Its card, latest-card and change-prompt records are disposable interaction state. Reads reject a card after 14 days and a prompt after 24 hours. No job deletes the records. They hold IDs and the carded review version, never authority. A Task that stays in one attention status keeps one live card. The card records the end of its attention interval before an edit, so failed retirement cannot suppress a later review. Retirement clears the latest-card pointer only after a successful edit. Transient edits of a known message use the Participant owner's existing three-attempt budget. Exhaustion retains the failed delivery and card target. Ordered Participant delivery completes that budget before it processes a later card. Each click re-resolves the sender and calls `Comma.Conversations.accept_task_review/5` or `send_message/5`, so the Conversation owner keeps Task status and the Mini App stays read-only. This adds no Task, status, or card identity.

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


### Product analytics projection

[Comma.Analytics](../../systems/apps/comma_core/lib/comma/analytics.ex) projects existing Users and activity to PostHog.
The User ID remains the person identity. Canonical email is a server-owned person property, never an event property.
Website and web app first touch use the SDK anonymous identity until the session authority identifies an existing User.
The shared [attribution policy](../../clients/packages/analytics/src/index.ts) stores only bounded public campaign fields.
PostHog owns no account, authorization, Task, or financial lifecycle. Reuse needs no new domain entity or durable activity ledger.
The bounded activity queue is volatile. A unique Oban job owns the profile-scan cursor and next due time.
Source facts remain with their existing owners. Profile sweeps emit no registration events.
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
A Model Choice `{"kind": "platform", "tier": ...}` names an Agent tier. An Agent that follows the platform default takes its role's tier. Its calls carry `credential_scope` `platform` and are metered against the
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
The Worker Participant's payload carries it to the delivery that creates the Worker Session. The product checks it first: Comma checks it as `agent.create_worker` does, and BFT rejects it.
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
A Task placed on the Group's Cloud VM while it sleeps, wakes or was never made is kept for its station: the VM is woken or made, and the station invited once the VM is ready ([SalixWeb.StationTasks](../../systems/apps/salix_web/lib/salix_web/station_tasks.ex)). `cloud_vm.start` is for running commands there.
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
See [TaskPlacement](../../systems/apps/salix_im/lib/salix_im/task_placement.ex) and [TaskPlace](../../systems/apps/salix_agent/lib/salix_agent/task_place.ex).

A member of the Workspace may run a Task that exists on another model, and so perhaps in another place (Comma's `PUT …/conversations/:id/run`, [SalixIM.TaskRun](../../systems/apps/salix_im/lib/salix_im/task_run.ex)): the place is always named, and it and the model are checked as a new Task's are (`SalixIM.TaskPlacement.resolve/4`). The station that runs it now is invited first, with `replace` when it ran the Task already (a new Session takes the old one's place in the Task's thread); a station that refuses, or one too old to replace its Session, refuses the switch and nothing changes. A Worker inside Salix in the middle of a turn refuses the switch until the turn ends. Then the stations that ran it leave it (`task.leave`: their Sessions are handed nothing more, what they post is refused, and their turns are interrupted, not waited for, so a step in progress may finish; one not connected, or one that did not answer, is told again when it next says hello), the new one takes part and is given the Task from its start, and the Task's owner records the new `runs_on` (none inside Salix) and the Worker participant's delivery and `session_model` together, and writes the Worker a `task_run_switched` Message. A Worker inside Salix runs in a new Session made with the model (a Session takes its model when it is made) and reads the Task from its source start; a station's new Session is handed what its station had not answered. The Task keeps its id, Messages, status, labels and Router. Clients offer the switch on the Task panel's model and where the Task's model cannot start: a station's Session whose turn does not start posts its notice with `cannot_start`, which Salix keeps as a `task_run_blocked` Message ([SalixWeb.StationTasks](../../systems/apps/salix_web/lib/salix_web/station_tasks.ex)). This adds no entity.
Salix keeps no Session for such a Worker. Salix is the station the Task is kept on, and a Session of the other station takes part in it, as between any two stations (`systems/station/docs/tasks.md`, [SalixWeb.StationTasks](../../systems/apps/salix_web/lib/salix_web/station_tasks.ex)): Salix invites the station before the Task is made (`task.invite`, answered at once; a refusal refuses the create), gives it every Message after what it had (`task.put`, until it has it), and takes what its Session writes as the Worker's Messages (`task.post`, once per key). The Worker Participant only authors those Messages: it is delivered nothing. Which Session of which station takes part, and how far it was given the Task, is a row of `station_task_sessions`.
Existing Sessions have no choice and follow their Agent.

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

- Value: `runs_on` is `{kind: station, device_id}` for an exact physical or VMM Station, or `{kind: cloud_vm}` for the Group's Cloud VM.
  The Group's Cloud VM switch permits startup and Task placement. `cloud_vm.start` accepts the caller or a same-Group Worker.
  A Worker binding supplies a default Task location and model; it grants no additional authority.
  New Group Cloud VMs use Cloudflare. Existing records retain their selected provider.
  `model` is a runtime Model Choice with provider `codex` or `claude`. Without a model id, the Station uses that runtime's authorized default.
  `binding_revision` counts rebinds.
- Owner and checks: Agent Control writes it on create, configure and `rebind_station_worker` (revision CAS). Only a Worker takes one; the model must be a catalog model of that runtime ([AgentControl](../../systems/apps/salix_agent/lib/salix_agent/agent_control.ex)).
- Tasks: a bound Worker is an internal Worker. `im_api.internal.task.create` gives each of its Tasks the binding's `runs_on` and model when the call names none; a call may name the same place and a model of the same runtime ([SalixIM.Provider.Internal](../../systems/apps/salix_im/lib/salix_im/provider/internal.ex)). The Task then runs on that station as any `runs_on` Task: a desktop station must be connected and take Tasks (`tasks` 2), the Cloud VM need not be running, and a named model must be one the station reports. A device that cannot take Tasks is refused with a reason ([StationReadiness](../../systems/apps/salix_store/lib/salix_store/station_readiness.ex)): `device_needs_station` (no `tasks`: the old connector; install the Comma desktop app or the station) or `station_outdated` (an older `tasks`; update the desktop app, or `stillfail update` on a standalone station). The BFT Devices page shows the same notice per device. Comma's Settings > Devices rows and device reads carry the same reason as `tasks_readiness` (`ready`, `device_needs_station`, `station_outdated`, or `offline` while the device is disconnected) with the station's `task_models`, projected from the device record the page already reads ([Comma.Devices](../../systems/apps/comma_core/lib/comma/devices.ex)).
- Creation: BFT's "Run on a station" ([BridgeForTeams.Agents](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/agents.ex)) and the raw Agent API create or move bound Workers. Agent Control refuses External Runtime Workers (`runtime_config` kinds external, connected_runtime, compute_workload); `runtime_config` takes only kind internal.
- Stored Pi and Kimi Workers retain their archive reason and data. Current Station bindings support Codex and Claude Code.

### Retired Sessions

Salix no longer runs External Sessions. Their stored records stay where they were written: one `state.json` object and one record stream per Session under `agents/<agent_id>/external_runtime/sessions/`. No release deletes them.

- Reads: [SalixAgent.RetiredSessions](../../systems/apps/salix_agent/lib/salix_agent/retired_sessions.ex) lists and reads them as `runtime_kind: "retired"`, `read_only: true` and status idle. [SalixAgent.Runtime](../../systems/apps/salix_agent/lib/salix_agent/runtime.ex) adds them to the Agent's Session list and reads one when the internal store has no Session of that id. Billing history includes the usage they recorded. They cannot be forked, compacted or consulted.
- Input: Session birth claims only the internal side ([SalixAgent.SessionBirth](../../systems/apps/salix_agent/lib/salix_agent/session_birth.ex)). A stored `external` birth marker or a stored retired Session keeps its id: a delivery to it answers `session_read_only`, a wait timeout or control entry is ignored, and no internal Session is created with that id ([SessionDelivery](../../systems/apps/salix_agent/lib/salix_agent/agent_actor/session_delivery.ex), [InternalSessionStore](../../systems/apps/salix_agent/lib/salix_agent/internal_session_store.ex)).
- Work: migration `20261010150002_retire_external_session_work` deletes their Session work candidates, which only pointed at work that will not run, and the candidate tables admit only internal Sessions.
- Conversation consumption: [ConversationConsumer](../../systems/apps/salix_agent/lib/salix_agent/conversation_consumer.ex) recognizes stored retired history and external birth markers as terminal sources. Log recovery completes without input or rejection writes to those Sessions, after any pending Triage command escalation through the Conversation owner. Storage failures remain retryable. An explicit Router reset can replace a retired Session with a new internal Session identity.
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
`scripts/generate-model-catalog.mjs` reads the pinned pi-ai model data and adds newer models from provider documentation.
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
The Actor and storage CAS select the current committed revision.
Materialized Session records retain the canonical queue work fields in the immutable `accepted_input` tuple.
This value reuses the Session record and queue identity. It adds no ledger, lifecycle owner, or billing authority.
The [materializer](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Query/Materialize.lean) creates it, and model/compaction projections omit it.
[InternalSession](../../systems/apps/salix_agent/lib/salix_agent/internal_session.ex) exposes handles, event application, and consumer queries.
The [Session commands](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Command.lean) own input acceptance and activation across external observations.
The [command driver](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/CommandDriver.lean) retains the native Revision and continuation through staged writes and CAS for input, activation, log, and recovery commands.
Persistence tasks carry that same cursor for asynchronous activation. It adds no durable record or lifecycle authority.
Fresh revisions retain snapshot absence until create-if-absent succeeds. Failed creation restores absence, not a committed baseline.
The [batch continuation](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/BatchExecution.lean) retains the remaining events and reducer continuation until the captured batch completes.
It is an operation-local Session projection, not another identity, durable record, or lifecycle owner.
The [pending revision](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/PendingRevision.lean) retains the baseline, working Session, events, and HWM in the kernel.
The [native Revision](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Revision.lean) retains snapshot absence, a committed Session/ETag, or this pending cursor.
Its planning continuation retains the materialization result through batch execution. Activation reuses the resulting pending revision before CAS.
Wait expiry selects its control event inside the kernel. These continuations add no identity, durable record, or lifecycle authority.
The [native read continuation](../../systems/native/verified_kernel/runtime/VerifiedKernel/Dispatch.lean) retains the requested object key, owner, Session, and observed ETag through load callbacks.
It checks the loaded scope before it initializes the committed Revision. The host supplies storage, codec, time, and configuration observations.
The continuation is an operation-local Runtime Session projection, not a durable entity or another lifecycle authority.
The host Revision exposes read-only projections. Fence and rollback use the native cursor, not a second lifecycle authority.
The [revision fence](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/RevisionFence.lean) carries this pending revision through preparation, fixed metadata writes, and CAS.
The [snapshot address](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/StorageAddress.lean) derives the existing hot key from the captured owner and Session.
Native fences and snapshot commits reject another address before they issue storage requests.
It returns the captured candidate as a committed native Revision on success. This projection adds no durable identity or lifecycle authority.
The [archive publisher](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/ArchivePublication.lean) owns captured-window cuts, adoption, and archive-advance construction.
Its resident cursor is a request-local Session projection. It adds no identity, durable record, or independent lifecycle authority.
The [storage continuation](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/StorageCommit.lean) retains the candidate Session between its CAS request and response.
It uses the existing native resource and has no durable identity or lifecycle outside that operation.
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
| Assistant Chat / Router Conversation | Comma's fixed Router Conversation for the current Group. Group users share this Conversation. A person's message there that names a model (`[name](comma:model/<id>)`, with `?effort=<effort>` when one is chosen: the composer's @ model) reaches no Participant: it starts a Task with that model and the rest of the words ([ModelMentionTask](../../systems/apps/salix_im/lib/salix_im/model_mention_task.ex)). The person owns that Task and writes its first Message; the uploads the words name are shared into the Task agent's VFS at the same paths, while files on the person's computer stay with their one Message. The Router answers with the Task and is told about it without a round of its own. |
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
The Conversation's `provider_status_version` deduplicates status publication and fences an interrupted metadata CAS during recovery. It is not an authorization value.
The product owner permits disposal of pre-cutover Agent and provider backlog. Stored Messages and admitted Session inputs survive.
The [Conversation recovery index](../../systems/apps/salix_store/lib/salix_store/conversation_log_recovery.ex) coalesces unfinished consumption by Conversation identity.
Conversation append marks its prepared tail before publication. Recovery completes prepared publication and retires the exact observed target after consumer progress.
Metadata CAS registers its next status publication version. Recovery fences an interrupted CAS without changing product facts or the Task business version.
Participant filter or binding changes also register recovery. Owner-local membership revisions reject cleanup from a stale observation.
This is a discovery projection, not another Message, delivery queue, or lifecycle owner. Recovery queries only due rows, not the Conversation catalog.
Participant mutation is separate from Message append.
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
It renders outside message bubbles and can fill the conversation width.
Its `ui_ref` projects the existing blob UUID rather than introducing another content identity.
The Message owns immutable HTML, JavaScript, initial data, and summary. Existing reply/thread relationships connect new versions.
The device owns temporary UI state, scoped by account, Workspace, and blob identity.
Existing Task and schedule owners retain business lifecycle authority.
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
A timed program asks `loop.next_run` for each run. An events program waits for its events.
The Worker reports each run as one result Message and never changes the status.

Under IFC enforcement, the assigned Worker may use its consumed Task command to build in private Agent VFS and create the requested Loop while it has not ended.
Creation records that Agent as creator and retains the Task audience label for later Loop effects and wakes.
The consumed command, Task, Worker and Session must match. This setup delegation grants neither a Drive write nor an unrelated provider effect.
Later Loop effects retain the existing creator authority, provider permissions and IFC audience checks.
An ordinary Task command still authorizes only its existing report path unless it carries separate execution grants.
The owning Router may use a consumed Worker report or owner-issued Loop notice to report in that Task or set it to `completed`, `escalated` or `failed`, including a same-status retry.
Source labels, current membership, the bound Session and any protected external return target remain checked.

A run is one `agent.notify` wake that reaches the Worker. The owner appends each wake as a private `agent_input` Message in the Task, deduplicated by its source `loop:<id>:<dedup_key>`.
The Loop counts the run on its row (`run_count`, `last_run_at`). The same source counts once.
Lifecycle notices of the Loop (exited, failed, budget) reach the Worker the same way. A Loop whose Worker left its Task pauses as `undeliverable`.

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
The Worker can still run commands on the Cloud VM with `env.exec`. One-shot Tasks keep the existing placement rules ([SalixIM.TaskPlacement](../../systems/apps/salix_im/lib/salix_im/task_placement.ex)).

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
- A paused Loop shows its trigger rule and the paused state with its reason.
- An ended Loop shows only `Ended`.
- A rule that the client cannot read does not show. A cron rule shows its time zone only when the UTC offset of that zone is not the reader's offset.

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

### Task Panel Dismissal

The chat Task panel docks the Tasks a chat created. A running Task always shows.
A User clears a settled one with Dismiss, or with Reveal in Chat. The dismissal records the run that the User acknowledged: the Task's `run_started_at`, or 0 for a Task from before Salix kept it.
Salix sets `run_started_at` on the Conversation when a Task's status becomes `active`, at creation or later. It is a value, not another entity.
Every device hides the row until the Task's latest run started after the acknowledged one. A Task that runs again shows again, and no device has to see it run. A rename, a label, or a review acceptance starts no run, so it does not bring the row back.

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
| Capability Request | An existing durable permission, location, OAuth, runtime-auth, or IFC decision request. Its owner stores expiry and the winning result; the Session separately owns execution and result publication. A request an Agent raises in a Comma Conversation records that Conversation (`surface_kind` `conversation`); Comma clients show it there as a request card, a projection of the request and not an entity ([routes](../../systems/apps/comma_web/lib/comma_web/agent_request_endpoints.ex), [card](../../clients/packages/app/src/components/chat/requests/AgentRequestCard.tsx)). |
| Tool / Provider Operation | An operation available to an Agent. An invocation is not a durable capability definition. |
| Skill | Instructions and resources projected into runtime files. Packaged built-ins belong to the running node. Stored user skills overlay them. Regular skills preload catalog entries. Miniskills use per-message selection. |
| Plugin Definition | A capability package with metadata and references. Referenced domains still own their resources. |
| Group Enablement | The Plugin enablement choice for a Group. This does not establish OAuth, MCP, or device readiness. |
| Plugin Installation | Comma's explicit installation evidence. It is separate from a default-enabled runtime capability. |
| IM Connect | A messaging integration connection and its provider context. It owns App-scoped Slack command aliases and synchronization state through [SlackCommands](../../systems/apps/salix_im/lib/salix_im/slack_commands.ex). A Group's single `voice` connect lists verified caller numbers and receives Router replies for every [Voice Call](#voice-call). A Group's single `signal` connect lists the Signal peers (people and Signal groups) bound to it on a [Signal Account](#signal-account). It is not the device Connector process. |
| OAuth Binding / MCP Connection | Authorization and service access relationships. Plugin enablement does not own their lifecycles. |
| Principal | The identity that requests a read or effect. Schedule and Group API-key principals, inbound or voice, act with their creator's authority. A key an Agent mints is created as `system`, which holds no membership. An Agent cannot mint a voice key. |
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
The `im_api.feishu.*doc*` operations use the connect's tenant app and its `tenant_access_token`.
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
`lark.search_docs`, `lark.list_drive_files` and `lark.search_meetings` run as the app and then as every active account, and `lark.get_meeting` and `lark.get_note` try them in that order, unless `account` names one (`app` for the app alone). Lark document, wiki and Minutes reads with `account` run as that person.
A meeting read is labelled with its participants and the reading account; a search with the accounts whose items it returns, and the fail-closed label when the app's items are among them; a note read with the reading account.
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
- Fields: name, description, icon (from the bundle), repository, live Version, visibility (`private`, `workspace` or `link`), creating User (none for an app the Router made), owner Workspace grants and sealed owner secrets.
- A Workspace row cannot be deleted while it has apps. A Workspace deletion path must call `Comma.MiniApps.delete_workspace_apps/1` first.

**Mini App Version**
- Identity: `(app_id, number)`, with a monotonic number. A deploy key is unique per app, so a repeated station request makes one Version.
- Lifecycle: `uploading`, then `ready` or `failed`. A `ready` Version is immutable. A failed Version's objects are deleted after 7 days.
- Retention: the live Version, the last 20 Versions, and every Version an Install pins.
- Fields: manifest, commit SHA, bundle and source archive objects, icon and cover objects (from the bundle), backend script name, bundle digest, build Task Conversation and deploy notes.
- The cover is a screenshot of the app's first screen that the Apps gallery shows. A deploy accepts at most 160 KiB and 1200 × 1200 pixels.
- The digest is a client cache key and provenance, not a security check.

**Mini App Link** has the Task Share token contract: one active link per app, a 32-byte random token, `active`, then `revoked`. Reset issues a new token.
The token lets a signed-in or guest Comma user run the app inside Comma. It is not public read authority.
Reset, revoke, or a change of visibility away from `link` also removes the Installs of other Workspaces.

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
Its key is Workspace, User, and toolkit. Verified installation completion or an owner's confirmed account choice replaces that toolkit's account ID.
It survives multi-step Google setup and the completion of an installation attempt. User or Workspace deletion removes it.
Its update timestamp fences renewed consent, even when the connected-account ID stays the same. Comma disconnect removes the receipt.
A receipt does not prove external user identity, current connection status, or read permission. Readers must check these separately.
Neither Settings nor a source list can create a receipt. For an old Composio connection, the owner can confirm its exact account in Plugins after Comma reads the provider's own identity. The one-time member identity backfill also writes it when the Workspace has only ever had its owner as a member, the toolkit has exactly one active account, and the provider identity read accepts it as a personal account. With more than one account, the owner chooses.
The confirmation attempt stores a generation, owner, account, provider identity, old receipt revision, and expiry in the existing Plugin Install Attempt. Comma checks these values again before it writes the receipt and queues source discovery. Cancellation, expiry, uninstall, or a later operation rejects the old attempt. An OAuth reconnection keeps the old account until the new connection completes. Completion then retires only the account that the old receipt named. Other accounts of the toolkit, such as meeting calendars, remain.
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
| Connector | The program that connects device capabilities and runtimes to Salix. A live Connector run is not a new device identity. A run holds one Connector credential of its Device at a time, recorded on the Device; it can switch to the Device's newest credential on its own socket, and it ends when the credential it holds expires or is revoked ([Registry.renew_run_credential](../../systems/apps/salix_env/lib/salix_env/registry.ex), [systems/station/README.md](../../systems/station/README.md)). |
| Command Environment | An execution environment selected within one Device. |
| Compute Pool / Node | Resource supply and a node that provides compute. Neither is the business Workload identity. |
| Compute Environment | A stable Project, Swarm, or Group ownership boundary. It is not an Allocation or a device query alias. |
| Workload | Stable work within Compute. New Workloads are shell, meeting_runtime or service; `external_worker` Workloads remain readable; default lists show only those that need recovery or cleanup. |
| Allocation / Runtime Instance | Resource allocation and a particular execution instance. Allocation.generation fences allocation authority. RuntimeInstance.connection_epoch fences container execution. ProviderBinding/Host Session.connection_epoch fences the control connection. Host reconnect preserves the allocation generation and execution identity. Only a meeting_runtime is fenced to one container instance; after a Guest restart, another Workload adopts the new instance of its verified container generation. Explicit release or revoke retires allocation authority. These facts do not replace Environment or Workload identity. |
| Compute Grant / Service Route | Compute access authority and service access routing. A Compute Grant is not a Billing Credit Grant. |
| Station | A still.fail station in one Salix Group (a Comma Workspace's or a BridgeForTeams Project's), reached directly by members with an offline-verified credential. It is not a Device or Connector. See [Station](#station). |
| Device Setup Offer | An offer in Home to set up one unprovisioned Comma device that a member's phone found nearby. It is not a Device: the device has no identity in Salix until it connects. See [Device Setup Offer](#device-setup-offer). |
| Device Secret | A Group's named, write-only key for one device on the user's local network, such as a miIO token. It is not a Device, a Connector credential or a Provider Credential. See [Device Secret](#device-secret). |

Internal Workspace member Agents select shared Shell Workloads per call through `workload_id`.
[Comma.ComputeAgentAccess](../../systems/apps/comma_core/lib/comma/compute_agent_access.ex) owns membership and Project Environment scope checks.
The [ComputeAccess seam](../../systems/apps/salix_agent/lib/salix_agent/compute_access.ex) supplies bounded discovery and authorization to Compute tools.
Workspace authority replaces per-Agent Grants for shared runtime and workspace operations only. It does not authorize private runtime carriers or service routing.
The Virtual Compute plugin provides discovery and process tools by default. An explicit Workspace plugin disable blocks both tool families.
Selection is a tool argument, not a new binding or entity. Disabled targets and stale allocation generations fail closed.
`compute.workloads.list` returns at most 20 entries with name, kind, template, capabilities, observed state, network policy, resource limits, and a cursor.
Discovery performs no Host probes. Observed readiness is not a guarantee of current execution availability.
Authorization precedes credential resolution. No default target or automatic Grant is created.
Shell commands use the current fenced Agent VMM Host session; Shell does not run a Runtime Agent.
[AgentVMMHostClient](../../systems/apps/salix_store/lib/salix_store/agent_vmm_host_client.ex) retains Runtime Agent readiness for other kinds and execution ownership operations.
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

A Station runs on a user's machine, a Group's managed Workload, or a Task's isolated Coding Sandbox in one Salix Group.
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
- Managed execution locations: a Group can have a VMM Station and a Cloudflare Station.
  [ComputeGroupStation](../../systems/apps/salix_store/lib/salix_store/compute_group_station.ex) prepares `station.default` in the authorized Host's existing Compute Environment.
  The Workload is a `service`, owned by its Group. Its owner relation adds no entity.
  Registration and Environment generation scope its identity. Repeated Host observations reuse it; replacement registrations cannot inherit its commands.
  A stopped or deleting Station Workload is not recreated by an observation.
  New Group Cloud VMs use Cloudflare. Existing Group Workloads keep their provider, archive, device identity, and accepted Tasks.
  A valid existing Group VMM Station is reused. Multiple eligible Host registrations return a placement conflict.
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
  A row holds the Task's title, status (`in_progress`, `needs_review`, `done`, `cancelled`, `archived`), creator, times, runtime, model and labels, and no message text. Its labels are the Group's label ids a person set on the station (`PUT /threads/:id/labels`, at most 20); the station owns them as it owns the status. A participant thread (`TASK/…`) is never indexed.
  The station sends pages on its Connector run (`task.index`, [SalixWeb.StationTaskIndex](../../systems/apps/salix_web/lib/salix_web/station_task_index.ex)) after it proves its key with `relay_register`, and only while it is an active station of the run's Group; else the answer is `not_this_group`.
  The station's connector ([task-index.ts](../../systems/station/src/connector/task-index.ts)) first asks what Salix holds with a page of no rows, sends what Salix lacks (all of it with `reset` for another epoch), and again after the station's writes move the index. A tombstone goes once the Salix of every connection holds it. A refusal other than `rate_limited` ends the sending until the next connection.
  Rows are numbered by revision within an epoch (`salix_stations.index_epoch`, `index_through`). A reset replaces the rows and a tombstone deletes one; a page Salix cannot continue from is not applied, and Salix answers what it holds.
  A page carries at most 200 rows and 64 KiB, a connection sends at most 4 pages a second, and a station holds at most 10,000 rows. Salix stamps the run's Device on each row.
  Removing the station, or moving it to another Group, deletes its rows. A Device that expires does not. The Device records the station its Connector proved (`station_id` in [Comma.Devices](../../systems/apps/comma_core/lib/comma/devices.ex) rows).
  Comma lists a Group's rows at `GET /v1/comma/groups/:group_id/station-tasks` (members, not a session restricted to one conversation; latest activity first, at most 500), and a task list stream opened with `?with=station_tasks` also says `station_tasks_invalidated` when a page changed what Salix holds ([Comma.Conversations](../../systems/apps/comma_core/lib/comma/conversations.ex) `station_tasks/3`).
  The client core keeps the last list read per workspace on the device (Account table `station_task`) and shows it as the `stationTasks` topic, read again while shown when that stream says so ([station-tasks.ts](../../clients/packages/core/src/station-tasks.ts)).
  The Tasks page lists them beside the Tasks Salix keeps, with the machine and model each runs on. The desktop app, which reaches the machines, makes a Task on one (`stations.newTask`, [tasks.ts](../../clients/packages/core/src/stations/tasks.ts)) and opens it on its station; other apps list them only.
  A Router sees the rows in `im_api.internal.task.list` (`station_tasks`, first page only), and reads and writes in such a Task through the station's Connector (`station:<station_id>:<thread>` as `conversation_id`; `task.read`, `task.say`, [SalixWeb.StationHostedTasks](../../systems/apps/salix_web/lib/salix_web/station_hosted_tasks.ex)); the Messages stay on the station, and a station that is offline answers neither. What a station says of its own Task carries no IFC label: in a Group whose IFC mode is `enforce`, the Router neither reads nor writes in it.
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

The wire contract is shared with the still.fail repository:
signed requests carry `x-stillfail-station`, `x-stillfail-ts` (300-second window) and `x-stillfail-signature` over `<tag>:<origin>:<station>:<ts>:<sha256hex(body)>`;
enrollment is `POST /v1/comma/stations/enroll` signed over `comma-station-enroll-v1:<origin>:<token>:<station>`;
presence is `GET /v1/comma/stations/connect` signed over `comma-station-connect-v1:<origin>:<station>:<ts>`, with `state` and `revoke` frames, the station's `reach` frames, and text `ping`/`pong`;
clients use `/v1/comma/stations/me`, `/v1/comma/workspaces/:id/stations` (list, rename, delete, SSE `events`) and `/v1/comma/workspaces/:id/station-credential`;
stations post notices to `/v1/comma/stations/notify` and read `/stations/install.sh` and `/stations/releases/station.json`.
Station bundles are still.fail release artifacts. Comma pins the manifest; the installer downloads the manifest's artifact
(checked against its sha256 when given) or the release-base bundle built from the pinned commit, and refuses anything else.

Device cutover (`COMMA_STATIONS_DEVICE_CUTOVER`, chart `stations.deviceCutover`, on unless set to `false`).
It adds no entity: it changes which existing path serves a user device, and only for a member who has enrolled a station in the Workspace.
Everyone else keeps the Connector. It applies only while the control plane is available.
Cloud VM and Compute Workload Workers, managed Group VM devices (a provider or provisioner, no member owner), and Groups that are not Comma Workspaces keep their paths.

- Install: [SalixEnv.DeviceInstall](../../systems/apps/salix_env/lib/salix_env/device_install.ex) asks [Stations.DeviceInstall](../../systems/apps/comma_web/lib/comma_web/stations/device_install.ex).
  For a member with a station, Settings > Devices and the Router install tool return the one-hour station enrollment command (`kind: "station"`) and create no Connector credential.
  The enrollment is issued as that member (the signed-in user, or the requester of the Router tool turn), who must not be a read-only member.
  A turn without a known requester, or with no known public origin, gets the Connector.
- Workers: a device Worker is bound to its device's station ([Station Binding](#station-binding)); the External Runtime path is retired for new Workers. A Task runs on a station through `runs_on` or its Worker's binding ([SalixWeb.StationTasks](../../systems/apps/salix_web/lib/salix_web/station_tasks.ex)), over the device's live Connector run; what the station's Session writes is the Worker's (`metadata.kind = "station_task"`), and Salix answers only the device whose Session takes part.
  Giving a station a Task is the `station.session` egress of `SalixAgent.IFC.Destination`; without a transcript to label, a Group in IFC `enforce` mode refuses `runs_on`.
- Tool transport: device tool calls ride the station's presence socket by default ([StationTools](../../systems/apps/comma_web/lib/comma_web/station_tools.ex), `tool` and `tool_result` frames).
  `COMMA_STATION_TOOLS_TRANSPORT=gateway` switches them to the separate iroh gateway ([Gateway](../../systems/apps/comma_web/lib/comma_web/stations/gateway.ex)); both carry the same §8 request and response.
- Station tools read stations through [GroupDirectory](../../systems/apps/comma_web/lib/comma_web/stations/group_directory.ex), the control plane's rows and presence.
  Agents see the `station.*` tools only when the gateway is configured and their Group has a station. The requester must have a role in the Group.

The Comma station ([systems/station](../../systems/station/README.md)) is still.fail's station with the Connector built in: the same program is a Station to members and a Connector to Salix.
It adds no entity. It connects to Salix with WebSocket or HTTPS, and to other stations and to client apps with iroh: `comma/mesh/1` ([@comma/mesh](../../clients/packages/mesh/README.md)) for client cores, with the member credential above.
Salix is the relay of last resort for those iroh connections ([StationRelay](../../systems/apps/salix_web/lib/salix_web/station_relay.ex)): a station that proves its iroh endpoint id on its Connector run sends packets in binary frames, which Salix forwards to the runs carrying the named endpoint in the sender's Group. A station in several Groups (a desktop signed in to several Workspaces) registers on a run in each, and sends a peer's packets on the run it last heard that peer on. The packets stay end-to-end encrypted; a registration lives only as long as that run's socket.
A member's client app reaches its Group's stations the same way through the client relay socket ([ClientRelaySocket](../../systems/apps/comma_web/lib/comma_web/client_relay_socket.ex)): it asks with its session for a one-minute, single-use ticket (`POST /v1/comma/workspaces/:id/station-relay`, a one-time credential), connects with it to `GET /v1/comma/station-relay`, and proves its endpoint id over the same challenge. The socket ends when the member leaves the Group, after three silent minutes, or after an hour.
How each of the client's connections runs now (direct, an iroh relay or Salix) is shown on the computer's card in Settings → Devices; it is not stored.

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
[ComputeNodeService](../../clients/apps/electron/src/main/modules/compute-node/index.ts) owns persisted node intent, binding scope, operation results, and read observations.
[AccountComputeNodeService](../../clients/apps/electron/src/main/modules/compute-node/account-service.ts) partitions that intent by canonical backend audience and stable User subject.
Its Session generation fences the entire command, including queued work and A-to-B-to-A login changes. Accepted late results persist only to their original partition.
Unowned historical records migrate only after the original subject, scope, and existing Host root are proved. They grant no current authority.
[AgentVMMInstallations](../../systems/apps/salix_store/lib/salix_store/agent_vmm_installations.ex) remains the cloud installation owner.
Linux headless installation reuses this Operation. Its `headless` delivery target belongs to the authorized User or Session and fixes the existing Workspace or Project Group.
Cue and BFT expose command-only sibling APIs at `compute-nodes/agent-vmm/install-commands`. These do not relax the native Main-only `install-operations` capability.
BFT preserves one live Host per Project. Comma permits multiple authorized Hosts.
[Headless](../../systems/apps/salix_store/lib/salix_store/agent_vmm_installations/headless.ex) projects the copy command, the public secret-free GET `agent-vmm/install.sh` bootstrap, and the public POST `install-operations/install.sh` script.
The command gives the ticket as one `<operation_id>.<one_time_secret>` argument. The bootstrap sends it in the POST body, never in a URL. Script reads do not mutate the Operation. Existing exchange, apply and ACK retain their owners.
An unconsumed ticket expires after 15 minutes. A consumed exchange keeps its fixed material deadline and exact Host identity.
After handoff closes, the script can only resume an existing protected native plan or completion receipt. It cannot mint another exchange.
The Server release descriptor selects the published `agent-vmm-host` package by platform: Mac zip or Linux arm64 tar.
Each platform carries its own release ID and transport digest. Missing Linux delivery does not disable existing Mac installation.
The Linux package uses the same native lifecycle owner for systemd and recovery. No new installer entity or login protocol is added.
A recovery challenge is a short-lived, single-use authorization value on that installation, not another identity or lifecycle.
Consumption moves only its delivery target to a current Session of the original subject. Normal mutations recheck active authorization under the same row lock.
An unexchanged request can be closed by its original subject before explicit new setup. Recovery of a completed exchange requires proof of its original Host root and registration.
`handed_off` proves material delivery, not enrollment, connection or initial Shell completion.
The material handoff expires 15 minutes after the exchange. The settlement sweeper closes an expired handoff in one transaction.
An enrolled Registration proves delivery, so the operation becomes `handed_off`.
Otherwise the Registration is revoked and the operation becomes `action_required` with `material_handoff_expired`, which frees the scope.
Main then starts one new installation for the same Workspace without a prompt. One automatic new installation is allowed per user enable; a second one waits for the user's explicit continue.
Native owns the acknowledged plan and its failure receipt, including the failed stage and whether the operation can resume.
Main reads the receipt only for the current account's exact installation. It projects safe reasons and available actions without storing another failure state.
Main resumes a retryable plan by itself, with the same request identity, on one backoff timer per intent (30 s cap). It has a bounded attempt budget and one overall deadline. Server terminal counters still end it.
A terminal failure shows one localized reason and one action.
After authorization expiry (`revocation_reason` `authorization_expired`), Main removes the old connection and authorizes a new installation by itself, within the same per-enable budget. Other revocations need an explicit user action. Missing or unreadable receipts do not prove a terminal failure.
Only an explicit manager revocation (`revocation_reason` `revoked`) with no data reset by Main since then says that a manager removed this Mac; its action is remove. A revocation without a reason, or an unreachable old installation, is `registration_invalid`: one "enable again" retires the old installation and authorizes a new one. After Main's own data reset, a revoked or absent registration is replaced by itself, whatever the reason.
A completed local removal shows not enabled, also when the cloud result is unresolved; that result stays in the removals archive.
A lost local registration of an applied installation (Host healthy, registration absent, not revoked by a manager) makes the installation stale. Main revokes the exact old installation (404 or already revoked counts as done) and authorizes one new installation. The first replacement after a Host reset or local data loss does not use the per-enable budget or the ended continuation. A later loss without a reset uses the normal budget.
An enable refused with `registration_not_found` or `terminal_registration` takes the same replacement path. Other known terminal refusals of these routes stop at needs attention; transient conflicts, rate limits and server errors retry within the continuation.
The setup UI displays this reason and follows these actions after refresh or restart. Shell state does not gate enabling the connection.
Electron tests with Native and cloud fixtures prove this projection, not real enrollment. Enrollment acceptance requires the real Native and Gateway boundary.
Native Host maintenance can permanently fence that installation after local removal or reset.
Main reads the fence for the current account's exact installation. It replaces an applied installation with a lost registration as above. Otherwise, it offers confirmed removal instead of resuming that installation.
Removal requests revocation of the exact old installation and verifies the local registration is absent or revoked before clearing this account's binding.
If the cloud installation is inaccessible and the local registration is absent, explicit detachment retains the unconfirmed remote outcome.
An explicit new setup creates a new installation. Missing plans alone do not prove local removal, and old Workloads retain their identities.
Recovery proves the original Host root and exact local registration, independently of enrollment health.
The challenge still binds audience, subject, current Session, Workspace, installation and server nonce.
Local revoked/disposed targets and cloud retired registrations reject recovery. Recovery changes only the installation delivery target.

`Registration.authorization_expires_at` is the sole durable seven-day authorization deadline, owned by AgentVMM and the server clock.
Valid authenticated Host hello or observation renews it. User login, settings reads and recoveries do not renew it.
Observation is degraded field by field: unknown or contradictory entries are dropped, and an unusable observation is not stored, but its authenticated contact still renews.
Revocation records `revocation_reason`: `authorization_expired` for the deadline and `revoked` for every other cause. A hello then fails with that code, and the Gateway reports it to the Host as `PermissionDenied`.
Observation is disposable health data and cannot own permanent authorization. Session expiry retires only its own capability.
The concrete threat is a stale Host credential continuing cloud commands after its bounded authorization ended.
Authentication, enrollment, configure, recovery, placement, command claim and runtime Session admission enforce the registration deadline.
Late contact cannot revive expired authority. Accepted result settlement retains its original owner without granting new command authority.
The migration grants already-expired records at most the existing 20-minute rollout budget. Normal seven-day deadlines remain later.
Old writers get a seven-day insertion default. The completed release enforces the normal policy, without a second activation gate.

Explicit revocation or deadline expiry seals only the exact registration in a short transaction.
[The settlement worker](../../systems/apps/salix_store/lib/salix_store/agent_vmm_settlement_sweeper.ex) processes at most 32 registrations and 32 due Commands per pass.
Retirement has a 32-query budget across indexed Registration, Binding, Allocation and Workload keysets. Empty branches consume this budget.
Each visited Workload cancels at most 32 never-delivered Commands and closes only its current-generation runtime. A full tour scales with retained history.
Retirement uses Workload then Allocation locks and a resumable cursor. Busy owners do not prevent later pages or trigger immediate retries.
Allocation `released` retires cloud allocation authority. Its operation outcome and physical observation remain independent.
Shell deletion `cloud_retired` ends cloud execution management, with `local_data_deleted=false`. It never projects as `deleted`.
Workspace owners can rename cloud metadata during cleanup or retirement. Owner admission remains. Rename keeps the last name, without changing deletion or Host authority.
Business Workloads retain identity, owner relations and service references. Their provider becomes unavailable.
Never-delivered commands can cancel. Sent commands, accepted inputs and unknown outcomes retain settlement facts and cannot replay.
Cloud closure does not assert that local children stopped. The local OS operator can dispose the precise environment or reset and enroll afresh.
New registrations cannot inherit old commands. Other registrations, user data and PersonalMesh remain outside retirement scope.

[LocalComputeOperator](../../clients/apps/electron/src/main/modules/compute-node/local-operator.ts) projects bounded local metadata and submits trusted operator confirmations.
Cloud mapping requires the current Workspace read permission and exact registration, Allocation, and generation. Read rights do not imply write rights.
The resource page reads at most 32 environments, one disk total, one optional receipt, and one cloud mapping batch every five seconds while visible.
Cached environment bytes are optional, with a 15-second freshness limit and exact boot, namespace, and generation checks. Missing values cause no Guest probe.
Manual Workload reads contain at most 32 items and current owner phases. No per-environment polling or automatic pagination is added.
A meeting_runtime Workload phase is `ready` from its runtime readiness. Another Agent VMM Workload is `ready` from container facts: observed and Allocation ready, container running, verified at the current Host connection epoch.
`problem` is null or `{code, retryable}`. It shows the last reconciler error of the current generation as a fixed code: `capacity_unavailable`, `image_unavailable`, `runtime_instance_changed`, `host_unreachable` or `other`. It holds no raw message and does not change the phase.
An Agent VMM Workload `location` has `registration_id` and the `device_id` of that registration's Comma Device, or null if the registration is missing. Each page reads these Devices in one batched query.

Confirmation freezes the existing Workspace and installation identity. Main rejects a changed binding before drain or removal.
Its `refresh` capability coalesces reads without installing, repairing, or changing desired state. `state.get` returns a snapshot.
Connection, admission, readiness and work activity remain independent. An unknown result is not success or proof that children stopped.
Main reads activity through the Comma installation GET after Workspace and exact Session delivery-target authorization. It never sends a Comma Session credential to the tenant API. Failed or absent activity observations are unknown; a genuine product 401 still invalidates the Session.
The UI presents a status and an applicable action. Diagnostic details retain technical facts. Salix creates the initial node Workload, idempotently, after the installation first becomes ready.
Disabling drains this registration's allocations. Normal removal revokes this Workspace registration and stops its environments into Retained.
Retained preserves private volumes and writable layers. Confirmed local disposal or an authorized Shell deletion removes its exact data scope. All paths preserve the shared Host and other registrations.
Local detachment after an inaccessible registration does not confirm remote revocation. Re-enabling does not promise restoration of previous work.

[ComputeWorkloadDeletion](../../systems/apps/salix_store/lib/salix_store/compute_workload_deletion.ex) owns the Shell deletion value on Workload.
It retains the request, exact Allocation generation, registration and Host revision. It adds no resource or task identity.
Deletion closes ordinary input admission before cleanup. Accepted work and unknown outcomes remain with their existing owners. An unknown outcome does not hold deletion; it is kept and never replayed.
A shared Allocation or business reference rejects Shell deletion. The existing registration Command transports only the accepted Allocation scope.
Host disposal retains its namespace mapping and replay fence before physical cleanup, including across reconnect and restart.
A discarded container or missing resource row is insufficient. Physical completion requires the exact Host disposal receipt or proof that creation never dispatched.
Registration expiry/revocation instead permits cloud retirement, with local data unconfirmed.
Workload.owner_ref is a relation to its existing meeting owner, written by SalixMeet at placement. It has no independent identity, lifecycle, or mutation authority. Legacy meeting relations are recovered once from the exact tenant/meeting-derived Workload ID and the current group projection. Unmapped legacy owners stay unknown; hot reads do not scan meeting state. Agent and service uses come from their existing indexed bindings, at most 32 of each per explicit detail read.
The cloud Workload and creation association remain after cleanup. Installation.initial_workload_id records the existing initial Shell relation. Initialization returns that Shell, including after deletion, instead of creating a replacement.
Legacy retained data without a proven mapping remains pending while authorized, then retires in the cloud. Cloud release never proves data deletion.
Allocation.dispatch_protocol identifies the new registration-command creation path. Command.delivery_started_at is an immutable dispatch fact, preserved against older writers.
Only that path with no dispatch evidence can complete deletion without Host cleanup. Historical allocations require exact Host proof.
A pre-acceptance revision rejection refreshes only the matching Allocation generation. An accepted receipt keeps its original request and revision.
An observed Host missing allocation-disposal-v1 produces host_update_required, without stopping independent work.
These transitions do not change retained TLA+ Session acceptance or native-evidence abstractions. Runtime regressions cover deletion and bounded authorization. No physical deletion liveness is claimed under an unavailable Host.

[Comma.Compute](../../systems/apps/comma_core/lib/comma/compute.ex) authorizes every creation and indexed request lookup.
`Workload.creation_request_scope/id/input` associates a client creation request with its canonical input. These values grant no authority and create no entity.
[Compute](../../systems/apps/salix_store/lib/salix_store/compute.ex) commits that association with Allocation and Workload in one transaction.
The unique scope/request index prevents duplicate placements. Same input returns the same objects, including after a lost response. Changed input returns a conflict.
A deliberate additional Shell uses a new request ID. Existing records and volumes are not merged or deleted. Associations remain with their Workload records.
Published clients without a key keep their original creation contract. New clients always send one, with no keyless fallback.
The client persists only one unconfirmed request per backend/account/Workspace before dispatch. Reload checks it without automatically replaying creation.
[Settings](../../clients/packages/app/src/components/useComputeNodeCategory.tsx) show This Mac and named Workloads through the shared settings components. Creation, details, rename, and exact deletion use the existing owners.
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
Comma and BFT share platform/artifact selection through [ConnectorInstall](../../systems/apps/salix_store/lib/salix_store/connector_install.ex).
BFT retains Runner supervision, multiple Group configuration, and its directories.
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
[Connector archive selection](../../systems/connector/salix-connect/main.go) and
[dependency declarations](../../systems/connector/salix-connect/dependency_installations.go) implement this distinction.

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

A coding Task runs on an L4ES sandbox of its own, with a GitHub repository checked out (`runs_on {kind: sandbox}`).
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
- Values on the Task: `runs_on {kind: sandbox, device_id}` and `repo {owner, name, base_ref, branch, pull_request?}`, kept on the conversation record at create ([TaskConversationInput](../../systems/apps/salix_im/lib/salix_im/task_conversation_input.ex)).
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
- Owner and lifecycle: [SalixWeb.CodingSandboxes](../../systems/apps/salix_web/lib/salix_web/coding_sandboxes.ex) creates, invites, saves, stops and replaces sandboxes, as [compute and devices](../compute-devices.md#coding-sandboxes) says.
  A Task's status change reaches it through `SalixIM.Ports.TaskStations.task_status/3`. A placement reserves it through `sandbox/1`.
  Replacement waits for confirmation that the previous sandbox stopped. Unknown invite and stop results cannot start a second execution carrier.
  The selected account restricts profile access. Missing owner facts fail closed rather than expose every tenant account.
- L4ES identity: L4ES admits Salix with workspace assertions that the Comma OAuth IdP key signs ([CommaWeb.Coding.L4ESAssertions](../../systems/apps/comma_web/lib/comma_web/coding/l4es_assertions.ex)). Members sign in to L4ES with Comma.
  The L4ES workspace is `comma:<group id>`. It is L4ES's own record, not a Comma or Salix entity.
  Its members are L4ES's records too. Before each sandbox create, Salix sets them to the Workspace's active non-viewer members ([CommaWeb.Coding.Members](../../systems/apps/comma_web/lib/comma_web/coding/members.ex)), by Comma user id. Comma's `WorkspaceMembership` is the authority for its Comma users there: the sync removes the others. Members that L4ES's own members add by login, such as GitHub users, stay. L4ES never asks Comma.
  Salix adds the release's sandbox image to it as an L4ES custom image (`comma-<sha prefix>`), also L4ES's record, named by the release's image manifest.
- Product surface: [CommaWeb.Coding.Endpoints](../../systems/apps/comma_web/lib/comma_web/coding/endpoints.ex) starts sessions and reads their state, changes, pull request and terminal link. Clients call them through `coding.*` ([core](../../clients/packages/core/src/coding.ts)).
  The session branch's pull request is GitHub's record, not a Comma or Salix entity: Comma reads it, edits it, marks it ready and merges it with the Group's GitHub account ([SalixWeb.GitHub](../../systems/apps/salix_web/lib/salix_web/github.ex)), and opens it there once the sandbox is gone. A Task made with `repo.pull_request` has that pull request's head as its session branch, so it is found as the branch's own. Where no open pull request has the session branch as its head, one of another head whose head is the branch's last commit is the session's, open or merged (a Task that continues a pull request): the station, after pushing, and Salix answer it, and Comma opens no second one.
- Station: [tasks/coding.ts](../../systems/station/src/tasks/coding.ts) keeps the checkout, pushes after turns, and answers `task.diff`, `task.save` and `task.pull_request`.

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
Users are ineligible. Recognized aliases and configured excluded email domains do not
receive the gift. These checks do not change login identity. BFT and self-hosted
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
| Group meeting preparation settings | Calendar enrollment choices owned by the existing Group, keyed by Group ID. Enabled state and revision authorize subsequent meeting effects. This configuration does not own a second MeetingPlan lifecycle. |
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
[connector tunnel](../../systems/connector/salix-connect/lan_tunnel.go).


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
- Value: `kind` (`miio_token` or `onvif_password`) fixes the accepted
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
- Relationships: `device.miio_request` takes `token_ref`, the name of a
  `miio_token`, and defaults its host to the saved host. A missing name fails
  with `saved_token_not_found`. The codec session cache keeps no key.
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
A Gmail trigger event reads that one source sooner. See [Member Source Items](#member-source-items).
A source recorded for the first time is a baseline and interrupts nobody. Only items that arrive or change later wait for consumers.
With waiting items and an open budget, the consumer screens at most 24 items and 2.4 KB of Home history without a Router turn.
Before the screening, the consumer groups the items into matters without a provider read or model call: items that name the same GitHub pull request, issue or Actions run, Linear issue, Notion page, Drive file, Slack thread or email address are one matter. A key that more than six items share joins nothing. The screening reads each matter through its newest item, with up to four others as `related`, and settles, retries or hands over every item of the matter together. Matters are run-local values, not entities.
It returns the most urgent item, what happens if the owner does nothing (`cost`, `due` time and whether it is `reversible`), its urgency (critical, high, ask, normal or low) and a plain-text message. Importance does not depend on whether the item is work or personal. Mail and notices addressed to the owner are about the owner unless the evidence shows otherwise. The server sets a floor under critical, high, normal and low: a cost due within 48 hours, or a cost that cannot be undone and is due within seven days, is critical; any other cost is at least high. `ask` and `unclear` keep their level. `ask` marks a matter that waits on an unnamed person whom the owner plausibly is; the Router asks the owner instead of reminding them.
The screening also reads the owner's latest Home matters, at most 20 changed within 60 days, as the notebook shows them: subject, state, level, the Router's decision and reason, cost and due time. It may answer that the item `continues` one of them, a later step of or new evidence about the same matter in another thread; the handoff carries that matter's subject, level and decision to the Router, and the notebook shows the two together. The screening also reads the owner's Router memory file `/memory/semantic/user.md`, the portrait first. The portrait adds no entity: it is a section of that file between `<!-- comma:portrait -->` markers, at most 1,536 bytes, one line per entry: a name or account of the owner, a duty, ongoing work, a place, a preference or an exclusion, each with the date it was last confirmed. The Router corrects it with its memory tools. Only a Workspace whose owner is its only member gets a portrait.
A portrait line can end with `watch:` targets that the input names: Slack channels (at most eight) and GitHub repositories (at most three); an exclusion's targets are never read. In the first collection of each hour, the Slack member read adds the last day's bot posts and requests in those channels, at most five threads each and ten in total, as `posted_where_your_work_is`, and the GitHub read adds each repository's failed Actions runs of the last day as `failed_in_your_repo`. The judgment gets each item's minutes since arrival; a login or verification code at most ten minutes old is critical, and the proactive skill sends it only to Home.
A collection queues the day's portrait refresh. It reads the owner's own Slack messages of 30 days, at most 15 thread starts, at most 30 of the owner's own pool items from other sources (pull requests, assigned issues, edited pages), the Home history and the rest of the file, and asks the Router model once without tools. The server keeps an entry only with evidence from that input or as an unchanged earlier entry, and drops an entry not confirmed for 60 days unless it is an exclusion or a preference. It then rewrites only the portrait section through the Router's workspace operation, billed as storage. A failed refresh changes nothing. The notebook lists the portrait.
The server validates the item ID and hands critical, high and ask items, with their urgency and assessment, to the canonical Router session as hidden Home input. Normal and low items stay in the daily briefing.
Before a handoff, the consumer reads at most three of the matter's links with the owner's managed GitHub or Slack grant, outside the item locks: an Actions run's status and attempt, a pull request's or issue's state, and the last messages of the Slack thread. The handoff carries them as `linked`.
The Router reads current context and decides whether to notify the owner. The screening result is evidence, not a user-visible reply.
The consumer routes only while the judged item still waits, unchanged. It holds the item and source state rows locked during the handoff. A revocation, source change, or new collection commits before the check, which routes nothing, or after the accepted input.
The consumer records its outcome and the rated urgency on each judged item, and the assessment on the judged matter's items.
When the unclear item is mail whose pooled excerpt was cut off, the check first reads that message in full once through the owner's consented mail account, as the mail Task does, and judges the same items again with its text; this spends one re-judgment. An `unclear` or unusable judgment decides nothing: the items stay pending as `retry`, after new arrivals, and are judged again, at most three times, before they settle as `invalid`. After an `unclear` answer, the same check judges the other items again without the unclear one, at most twice. A pool item whose matter the owner's watch follows is not handed over again by the check. The judgment rates only from the evidence and does not lower a level to stay quiet; the Router rereads the source before any message. For a handed-over matter, `recommendation.read` returns the item from the latest Routine snapshot, or the pool item when no fresh snapshot names it.
Home Conversation metadata holds two budgets per owner. At most twelve automatic Router handoffs in 24 hours bound the Router's cost.
ConversationActor spends the handoff budget when it reserves the hidden input. While it is closed, items keep waiting. Other judged items wait after each handoff.
The Router records its decision on the matter with `proactive.act`: `notify`, `quiet` with a reason, or `snooze` to recheck later. The value keeps the latest decision and reason.
While the notification budget is closed, the check hands over no non-critical item: judged items stay pending until the spacing passes. When even a critical matter could not notify, the check judges nothing.
`notify` on an automatic matter spends the notification budget: at least 30 minutes apart and at most five in 24 hours. A critical matter skips the spacing, not the daily cap. `notify` fails while that budget is closed. Staying quiet spends no notification.
Replies, reminders the owner scheduled and reports from watches the owner asked for do not spend the budget.
Only a Router decision creates a visible reminder: the need, an offered next step, then the source link.
Background checks and due reminders cannot select personal IM delivery targets. Queued effects from the removed personal reminder sender fail closed.
The Router uses ordinary reply tools. `proactive.act` with `track` updates source state without sending a message.
Fixed system receipts, Task status cards, and direct Telegram Task topics retain their existing delivery contracts.
Snooze, handled and other actions append hidden app events. Earlier reminders keep a stored `mail_reference` block. Clients render only their text.
A proactive watch is a Background Loop with a Comma owner source binding, enrolled only when the owner asks Comma to follow one matter. Comma installs one bundled source-neutral program. Its `agent.notify` wakes become the owner's Home matter, not automatic, on the one proactive handoff path; the Router input keeps the Loop's origin and label. Salix lets a product that owns a Loop deliver its wakes through the authorization adapter's `deliver/4`; other Loops wake their Session directly.
Generic Loops remain Agent-authored. The binding pins a Workspace, user, connection, and consent revision. Slack, GitHub, Linear, and Notion watches pin the Group's active managed OAuth binding. The Loop may call only the pinned plugin MCP read and receives a bounded projection of it. A new watch that cannot start leaves no Loop; a replaced watch returns to its earlier recipe. Each Agent admits at most 16 product bindings. Loop pause/resume and durable events retain their existing owners.
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
It also lists the latest published Routine briefing, also while a run refreshes it or after a failed run, with what happened to each item since, and marks quiet pool items that the briefing includes. Routine publication queues a render.
It groups matters by what needs the owner, what comes up later, what waits, what the Router did not interrupt them about with its reason, and what is done. Each Home value keeps the time it last changed for this order.
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
When the Composio settings have webhook ingress, collection also creates one trigger for the owner's Gmail source and records its ID.
A trigger event only schedules a read of that one source, at least one minute after the source's previous read. The event data is neither stored nor shown.
The provider trigger stays provider-owned. Removing the source deletes only the recorded ID.
Items grant no source authority. Consent and bindings authorize every collection.
Implementation: [item pool](../../systems/apps/comma_core/lib/comma/member_source_items.ex),
[collection](../../systems/apps/comma_web/lib/comma_web/member_source_ingest.ex),
[triggers](../../systems/apps/comma_web/lib/comma_web/member_source_triggers.ex),
[ingress](../../systems/apps/salix_web/lib/salix_web/composio_webhook.ex),
[retention](../../systems/apps/comma_core/lib/comma/workers/member_source_item_retention.ex).

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
The failed attempt records the catalog source and the member's Profile id and name, never a credential.
The Participant status publishes them as a bounded `issue_detail` with that issue only.
Clients name the provider and Profile, link its billing page when known, and open
Model & API at that Profile.

Implementation: [LLMMetering](../../systems/apps/billing_core/lib/billing_core/metering/llm_metering.ex),
[Drive](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Drive.lean),
[Cloudflare](../../systems/apps/salix_web/lib/salix_web/compute_providers/cloudflare.ex),
[VoiceMetering](../../systems/apps/billing_core/lib/billing_core/voice_metering.ex).

An idle Session projects the financial reason.
