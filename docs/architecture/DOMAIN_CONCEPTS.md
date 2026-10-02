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
| Workspace | Comma's authorization scope and product entry to its current Agent work scope. It also references billing and Drive resources. A `guest` Workspace has only a Router agent and shares the guest Tenant. |
| Owner / Membership | A user's authority within a product scope. It is not Conversation participation. |
| Tenant | The Salix isolation scope. Comma Workspace and BFT Organization store their respective Tenant mappings. Its existing config records own [Slack command templates](../../systems/apps/salix_im/lib/salix_im/slack_command_templates.ex); Apps copy these values without inheritance. |
| Group | A Salix Agent work scope within a Tenant. Comma Workspace references its current Group and generation. The Group owns its outbound SSH client key and trusted SSH host keys (see [Outbound SSH Session](#outbound-ssh-session)). |

Owners and entry points:
[Comma accounts](../../systems/apps/comma_core/lib/comma/accounts.ex),
[Workspace and Membership](../../systems/apps/comma_core/lib/comma/data/schemas.ex),
[Workspace authorization](../../systems/apps/comma_core/lib/comma/workspaces.ex),
[BFT Organization](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/organization.ex).

[Electron Session](../../clients/apps/electron/src/main/modules/session/session-service.ts) owns local Auth Session recovery.
A configured backend change removes credentials for other origins before login, without changing server sessions or unrelated profile data.

Native Apple login reuses [Login Identity](../../systems/apps/comma_core/lib/comma/accounts/identity.ex) with `provider=apple`, Apple's issuer and token subject.
[AppleAuth](../../systems/apps/comma_core/lib/comma/apple_auth.ex) verifies Apple's keys, client ID, nonce and token lifetime.
Existing emails require OTP before linking. [AuthChallenges](../../systems/apps/comma_core/lib/comma/auth_challenges.ex) owns expiring, single-use nonce attempts and linking codes.
[WatchPairing](../../systems/apps/comma_core/lib/comma/watch_pairing.ex) uses the same challenge owner for a two-minute grant.
The grant creates an ordinary [Auth Session](../../systems/apps/comma_core/lib/comma/accounts/auth_session.ex) with `parent_session_id`.
Parent revocation rejects grants and child sessions. Natural parent expiry does not expire an issued child session.
[CommaCore](../../clients/packages/apple-core/Sources/CommaCore/CommaClient.swift) owns each app's Keychain credential and stale-response fence.

APNs targets are delivery-credential projections of Auth Session, Workspace and existing Task, not compute Devices or new Task identities.
[Notifications](../../systems/apps/comma_core/lib/comma/notifications.ex) owns each session/kind slot, token rotation, authorization and expiry.
A registration ID correlates token updates and deletion. It grants no authority. Revoked sessions and inaccessible Workspaces/Tasks reject delivery.
Each projection records a validated main-app bundle ID, APNs environment, and alert locale. These values create no new app or Device identity.
Ordinary alert intent remains installation-local. The current Auth Session owns its `device` slot, including explicit opt-out and legacy reconciliation.
[NativePush](../../systems/apps/comma_core/lib/comma/workers/native_push.ex) re-reads owner facts and sends bounded APNs projections.
[TaskActivityCoordinator](../../clients/apps/apple/iOS/TaskActivityCoordinator.swift) selects one Task for ActivityKit.
Live Activity title/status/timestamps mirror Conversation facts. Apple owns activity presentation and lifetime. No widget or notification changes Task status.
Reuse is sufficient because these credentials and projections have no independent account, Task or execution lifecycle.

Telegram Mini App access reuses [Auth Session](../../systems/apps/comma_core/lib/comma/accounts/auth_session.ex) with `session_source=channel_task_panel`. Its `channel_subject` is the verified Telegram user ID; Workspace and Group fields scope a 24-hour, read-only cookie. The current [Telegram link](../../systems/apps/comma_core/lib/comma/telegram_links.ex) owns the expected connection ID. [TelegramMiniAppAuth](../../systems/apps/comma_web/lib/comma_web/telegram_miniapp_auth.ex) checks it on every read and returns 401 if the connection changed, so a reconnect cannot revive a cookie from before disconnect. Task reads use the existing [Conversation](../../systems/apps/comma_core/lib/comma/conversations.ex) kind check; a panel cookie cannot read Router chat. This adds no User, Task, or Session identity.

Telegram Task review cards reuse the existing provider Participant and status delivery. At Task creation, [TaskConversationInput](../../systems/apps/salix_im/lib/salix_im/task_conversation_input.ex) asks the product adapter for the Workspace owner's bound private chat and adds one `task_status_personal` Participant. It subscribes to all status events and to no Messages. Only review, escalation and failure send new cards. Intermediate states retire the previous card, so a later review round sends a new card. [TelegramTaskCards](../../systems/apps/comma_web/lib/comma_web/telegram_task_cards.ex) authorizes each send against the current [Telegram link](../../systems/apps/comma_core/lib/comma/telegram_links.ex) and never resends an uncertain card. Its card, latest-card and change-prompt records are disposable interaction state. Reads reject a card after 14 days and a prompt after 24 hours. No job deletes the records. They hold IDs and the carded review version, never authority. A Task that stays in one attention status keeps one live card. The card records the end of its attention interval before an edit, so failed retirement cannot suppress a later review. Retirement clears the latest-card pointer only after a successful edit. Transient edits of a known message use the Participant owner's existing three-attempt budget. Exhaustion retains the failed delivery and card target. Ordered Participant delivery completes that budget before it processes a later card. Each click re-resolves the sender and calls `Comma.Conversations.accept_task_review/5` or `send_message/5`, so the Conversation owner keeps Task status and the Mini App stays read-only. This adds no Task, status, or card identity.

The account scope and Agent work scope are distinct responsibilities.
Comma presents both through Workspace. BFT separates Organization from Agent Swarm.
These mappings do not make their IDs interchangeable.

### Guest mode

Guest mode lets a person try Comma in the web client without sign-in. The Electron app and other bearer clients still require sign-in. It adds no entity. It adds a `kind` value to User and Workspace, a Tenant profile, and one Comma Operation type.

- **Guest User.** `comma_users.kind = 'guest'` marks the User. Its email is an undeliverable `g-<hex>@guest.comma.invalid` placeholder. A database check keeps the kind and the placeholder domain together. Registered sign-in paths reject that domain. The guest has no Login Identity and gets no sign-up credits. It never becomes a registered User.
- **Guest Auth Session.** `POST /v1/comma/auth/guest` creates the User and an ordinary `user_login` Auth Session with `auth_method = 'guest'`. Only the web Cookie transport can create a guest; other clients get `guest_web_only`. The request must carry a solved [GuestPow](../../systems/apps/comma_core/lib/comma/guest_pow.ex) challenge from `GET /v1/comma/auth/guest`. The client finds a nonce so that SHA-256 of the challenge and nonce starts with the policy's number of zero bits. The default of 12 bits takes well under 0.5 s on a phone. The challenge is signed, expires after ten minutes, and creates at most one guest. Guest creation has no client-address limit. [CommaWeb.GuestRoutes](../../systems/apps/comma_web/lib/comma_web/guest_routes.ex) is a fail-closed route allowlist. A guest reads its session and profile, bootstraps its Workspace, and uses its Router chat. Other routes return `guest_signup_required`.
- **Guest Workspace.** `comma_workspaces.kind = 'guest'` has no Worker agent and no Cloud VM. Its Group is in the shared guest Tenant. The unique Tenant index covers only `standard` Workspaces. Guest Workspaces reject VM changes and skip Synchronicity, so the placeholder email stays in Comma.
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
| Agent Template | Model and related configuration selected for an Agent. Global and Tenant-private templates are not Agent instances. Main-model display name and vendor metadata are values on the template, separate from its configuration alias and transport provider. An Agent either selects one template or follows its platform role default. |
| Agent Default | Platform pointers supply live role defaults. Tenant pointers supply initial choices for new Agents. These are values on existing configuration records. |
| Comma Model Selection Policy | One Comma-wide rule lists global Agent Templates that users can newly select. It does not own templates, defaults, or Agent bindings. |
| Model Catalog | Platform data that names models across sources. A catalog model has a model id, a display name, its maker, and one request id and protocol for each source that serves it. A source is an API-key provider or a subscription plan. It owns no credentials, tenant data, or Agent bindings. |
| Runtime Session | An Agent's input, model, and tool execution context. A configured current Router has one canonical Session. A Worker can have many. |
| Internal / External Runtime | Execution inside Salix or through an external runtime. Platform support does not imply product admission for every Agent role. |
| Session Activity | One accepted execution activity. It is separate from an input batch, Task lifecycle, and device availability. |
| Participant Status | The exact Participant's public activity and optional draft surface. The Participant resolves its Session privately. |

Owners and entry points:
[AgentControl](../../systems/apps/salix_agent/lib/salix_agent/agent_control.ex),
[Triage Worker selection](../../systems/apps/salix_agent/lib/salix_agent/triage_worker.ex),
[Templates](../../systems/apps/salix_agent/lib/salix_agent/templates.ex),
[AgentDefaults](../../systems/apps/salix_agent/lib/salix_agent/agent_defaults.ex),
[AgentRoleActor](../../systems/apps/salix_agent/lib/salix_agent/agent_role_actor.ex),
[InternalSessionActor](../../systems/apps/salix_agent/lib/salix_agent/internal_session_actor.ex),
[ExternalSessionActor](../../systems/apps/salix_agent/lib/salix_agent/external_session_actor.ex),
[Participant owner](../../systems/apps/salix_im/lib/salix_im/conversation_participant_actor.ex).

Agent Default reuses existing records instead of a proxy template. The platform layer
is the `ctl/system/agent_defaults.json` object. The Tenant layer is the `agent_defaults`
section of the Tenant record config. BFT publishes Organization creation defaults to that Tenant config.
Creation without a specific template copies the Tenant role pointer, including an empty pointer.
An existing Agent with an empty pointer resolves only the platform role default on each round.
An unset platform role uses the built-in `default` template (`gpt-test`).
Tenant changes never modify existing Agents. Platform changes affect Agents that select Default.
Comma exposes its current Router, a bounded page of Workers, and a separate new Worker default.
`AgentDefaults` owns resolution and pointer validation. Referenced templates cannot be deleted.

The Comma Model Selection Policy is a separate Comma-owned record because neither an Agent
Template nor an Agent Default represents a platform-wide user choice rule. Its only
identity is the Comma singleton. [Comma.ModelSelectionPolicy](../../systems/apps/comma_core/lib/comma/model_selection_policy.ex)
owns the rule and its revision. Admin updates change it. The initial `all` mode
preserves all existing choices. In `selected` mode, the ID list admits new user
selections of global templates. An empty list admits none. Tenant-private
templates and Default remain selectable. Existing Agent bindings and the Worker
creation default continue to resolve after an ID leaves the list. The rule does
not change runtime inference or the administrator support path.

The Model Catalog is separate from Agent Templates because a template binds one model
to one provider configuration. The catalog says that `openai/gpt-5.5` at OpenRouter and
`gpt-5.5` at OpenAI are the same model, which no template or account can express.
Its identity is the catalog model id, platform-wide. [SalixAgent.Models](../../systems/apps/salix_agent/lib/salix_agent/models.ex)
owns it as read-only data compiled from `priv/model_catalog.json`.
`scripts/generate-model-catalog.mjs` regenerates that file from the provider model data
in the pinned pi-ai package; a release changes it, no runtime path does. The Gemini plan's
routes come from `scripts/antigravity-models.json`, the Antigravity list of the pinned
CLIProxyAPI SDK, because the subscription worker sends Antigravity model ids unchanged.
Sources name what an account pool account connects to. Templates and accounts may
reference catalog ids and source ids; the catalog references neither.

A catalog choice is a private Agent Template with a catalog model id, a reasoning effort
and `allow_paid`, and no endpoint or credential. [AccountPool](../../systems/apps/salix_agent/lib/salix_agent/account_pool.ex)
chooses the Profile for each request: enabled subscription accounts whose plan serves the
model first, then, when `allow_paid` is true, enabled API-key accounts whose source serves it.
Every subscription provider is a plan. Its pool route sets the wire protocol;
the catalog route gives only the request id.
A request that fails before output moves to the next candidate, across providers.
It never falls back to platform credentials, and it is billed as tenant-funded.
A catalog route binds its Profile only at dispatch. Every step before dispatch therefore
stays provider-neutral: the request is not encoded for a protocol or a request id, and each
candidate's provider encodes it. Paths that post a resolved route themselves, such as the
site LLM proxy, send a catalog or subscription route through the same dispatch.
An Agent kept to an API-key Profile pays for it: its choice is stored with `allow_paid` true.
A Custom Profile lists the model ids its endpoint serves. A catalog choice can also name
one of these ids when it is not in the catalog. Such a choice has no reasoning efforts.

A runtime choice is a hidden private Agent Template for a Worker on a Codex or Claude Code
Compute runtime. It holds a catalog model id that the runtime can run, the runtime provider
and a reasoning effort. It has no endpoint or credential, because the runtime uses its own login.
Compute dispatch reads its model and effort only for fields that the runtime binding leaves blank.
A binding that sets a model, model provider or effort keeps the Worker read-only.
Codex and Claude Code accept only the runtime default or a runtime choice. Dispatch sends
them only a runtime choice made for that runtime. With any other template, such as a copied
creation default, an older catalog choice or a choice made before a rebind, they run their own
default model. Codex applies a changed choice at its next turn. It keeps an override on its
thread, so the Connector sends Codex's own reported default, for the thread's workspace, when
no choice is set. It maps an effort that the model does not support to the closest supported
effort. Claude Code applies a changed choice when the next input arrives while it is idle.
Input that arrives during a running turn does not restart it.
The binding does not change. [Templates](../../systems/apps/salix_agent/lib/salix_agent/templates.ex)
reuses one template for each choice and deletes it when no Agent uses it.

An external Runtime Session owns its runtime binding and accepted-input queue in
[ExternalSessionStore](../../systems/apps/salix_agent/lib/salix_agent/external_session_store.ex).
The Connector prepares one execution ID before native dispatch. The same execution
can accept later input batches while it remains active. For a Compute runtime, the Host
keeps a bounded usage right for that execution and exact Runtime Instance. Native
terminal evidence, event acknowledgement, local settlement, and Host release settle
that activity. A direct Device Connector has no Compute allocation or Host usage
right. It retains the native execution and input queue locally. After restart, native
recovery precedes replay of input whose delivery was not acknowledged.
The input batch, native execution, and Host usage right remain separate facts.
The Session owner commits the dispatch identity and input source scope before the Actor sends input.
A failed or uncertain Session write retains the queue and withholds that attempt.
Derived status failure does not revoke committed dispatch admission.
The observed start or steer mode survives a failed projection write.
An unavailable status read leaves the mode unknown. A send error then preserves prior execution and permits a later wake.
A missing legacy dispatch target does not prove that its queued input was never sent.
A financial refusal before native dispatch is an outcome of the existing input batch.
The Session owner records `billing_rejection` on the first original message record,
outside the user-controlled `data`, then moves the exact rejected prefix from queue to history.
The result keeps the original input IDs and normalized refusal. It adds no Job or ledger.
A crash between log append and queue update uses indexed record lookup to finish that
same refusal. An uncertain append reloads the existing log index before reuse.
New queue tails and previously accepted native/tool work remain separate.

The external Session owns a nullable `runtime_wait` value for accepted input awaiting device readiness.
It preserves the same queue and binding, with no readiness timer. The Actor clears the value after resolving the original target.
The existing Session work candidate projects the original `device_runtime_id`.
[RuntimeTargets](../../systems/apps/salix_env/lib/salix_env/runtime_targets.ex) projects readiness expiry in the existing runtime locator.
The device Registry publishes these hints with metadata. The shared notification listener requests bounded recovery.
Recovery joins the projections to rediscover eligible waits after notification loss or restart. Dispatch still checks authoritative state and permissions.
These projections add no subscription identity, device identity, queue, or independent work owner.
Ordinary Agent rebind affects new Sessions only. Explicit Session migration preserves the Session ID
and native ID, and changes this binding after source retirement. The nullable `migration`
value belongs to that Session: operation ID, source/target, phase, deadline, and error.
It adds no Migration entity or independent lifecycle. The Session Actor owns its transitions;
[ExternalSessionMigration](../../systems/apps/salix_agent/lib/salix_agent/external_session_migration.ex)
coordinates bounded operator steps. AgentControl owns the temporary `session_admission`
freeze and birth reservation. The Agent binding changes only after all selected Sessions commit.
The [Connector](../../systems/connector/salix-connect/external_runtime_migration.go) owns
native files and the per-Session durable source seal. A seal closes execution admission;
it does not authorize file deletion or revoke the shared Connector credential. An owner-approved
unmigratable Worker reuses permanent Agent archive as its terminal lifecycle. The bounded
`archive_unmigratable` operation then deletes only the exact connected-runtime Session rows and
files from that archived Worker's stored binding. This is cleanup of existing Agent and Session
facts, not a new entity or lifecycle authority.

Group provider cutover also uses the Session's `migration` value, but it has a separate
operator transition in [ExternalSessionStore](../../systems/apps/salix_agent/lib/salix_agent/external_session_store.ex).
An approved, settled Session can park under the exact Group operation. Its Salix Session ID,
history, and accepted input stay intact. If its native identity is absent or its imported
command is unavailable, the operator can start a new native identity after the target is ready.
An executable imported native identity cannot be reset. The Group Workload owns the provider
switch and admission hold; neither the Session nor the Connector becomes a second Group owner.

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
| Assistant Chat / Router Conversation | Comma's fixed Router Conversation for the current Group. Group users share this Conversation. |
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
[chat projection](../../clients/packages/app/src/components/chat/model/conversationChannel.ts).

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

## 4. Tasks

| Concept | Meaning and boundary |
| --- | --- |
| Agent Task | Durable delegated work represented by an agent_task Conversation. It is not a Runtime Session. |
| Task Lifecycle | The business state owned by Conversation.status. Session termination does not establish Task completion. |
| Human Review | Version-checked acceptance by a human. Router completion after verified delivery is a separate path, not evidence of human acceptance. |
| Task Label / Proposal | A Group's classification catalog and label approval decisions. These are not IFC confidentiality labels. |
| Archive / Restore | Shared Task archive transitions with a saved restore status. Archival is not deletion or an independent running lifecycle. |
| Task Share | A public, read-only link to one Task up to a saved Message cutoff. It is Comma product authorization, not a Task fact or a login. |

Owners and entry points:
[ConversationActor](../../systems/apps/salix_im/lib/salix_im/conversation_actor.ex),
[Task labels](../../systems/apps/salix_store/lib/salix_store/task_labels.ex),
[TaskArchive](../../systems/apps/salix_im/lib/salix_im/task_archive.ex).

Conversation status remains the sole Task lifecycle authority.
The owning Router may complete a plain one-shot Task after verified delivery with no pending work or human decision.
Recurring, product-assigned Triage and legacy Workflow Tasks cannot use this completion path.
Human acceptance of a non-recurring Task checks the exact reviewed version before completion.
Recurring runs cannot complete their parent Task through that acceptance command.

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
[Shared tasks settings](../../clients/packages/app/src/components/tasks/useSharedTasksCategory.tsx).

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
| Capability Request | An existing durable permission, location, OAuth, runtime-auth, or IFC decision request. Its owner stores expiry and the winning result; the Session separately owns execution and result publication. |
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

### Miniskill activation

A miniskill is an existing Skill with `activation: per-message` in SKILL.md frontmatter.
An absent activation field means `regular`. SkillStore retains the same identity, scope, files, owner, and lifecycle.
The dashboard can create this mode, and file edits can change it. Miniskills require a name, description, and at most 2 KiB of instructions.
Plugin visibility and scope still determine eligibility. Supporting files keep their existing runtime paths.
Only regular skills contribute entries to the preloaded prompt catalog.
Built-in third-party service miniskills reference the regular `service-access` skill for shared access and purchase-safety steps.
`make test-resources` rejects a built-in miniskill over 2 KiB, or a built-in catalog whose worst-case selection request exceeds the runtime limits.

For internal Sessions, MiniskillSelector evaluates newly materialized human inputs before Agent dispatch.
It uses the configured decision provider, fee authorization, admission budgets, and attributed archive seam.
The request contains the current message, up to six preceding user/assistant messages, and every eligible miniskill's name and description.
History uses retained Session messages in chronological order. Each input sees only messages before it, including earlier coalesced inputs.
Tool outputs, tool-call arguments, and archived-history reads are excluded.
Miniskill resolution does not enforce IFC on information sent to the decision provider.
Injected bodies retain the agent-private provenance label of skill-file reads for subsequent agent actions.
One independent relevance question per candidate returns a probability. Candidates at or above 0.65 sort by probability, then Skill ID.
At most five bodies attach per input. This threshold is a tuning value, not a correctness guarantee.
The internal request profile allows 64 KiB; the public `decide` tool retains its eight-question, 12 KiB contract.
The catalog has a 48 KiB limit. Every message has a 2 KiB text limit, including the current message.
Oversized messages retain their beginning and end with an omission marker. Six preceding messages remain eligible regardless of their original size.
An oversized complete catalog produces no selection. No candidate subset substitutes for it.

Preparation uses the cached skill projection while live credentials and round configuration refresh.
Cold Sessions first join existing catalog prewarming. Selection currently completes before compaction and attachment preparation.
A one-second absolute deadline bounds selection and its final join. No retry or larger-model fallback extends it.
Coalesced inputs share this deadline and a 10 KiB instruction-body budget, in input order.
Timeout, provider errors, and saturation produce empty selections without dropping user input.

Accepted selections, including empty outcomes, join the existing Session activation checkpoint.
Provider computation can overlap this checkpoint. Deltas and results wait for durable success.
This value adds no decision entity. Retries reuse it; a crash before commit can repeat inference.
The kernel renders bodies only for their active input scope. The next human input replaces them.
Bodies stay outside ordinary transcript and compaction summaries. Compaction reserves their byte count conservatively as tokens.
The provider request archive captures the rendered instructions. Telemetry records bounded outcomes, wait, selected count, and bytes.
The Runtime Activity tab shows miniskill selection duration and its wall-clock share, with overlapping configuration time counted once.
External runtimes can read skill files explicitly but do not receive automatic miniskill attachments.
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

A Voice Call is one live call between a caller and a Group's Router. GPT-Live speaks with the caller through one carrier: Twilio or the `comma.voice.v1` WebSocket API.
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

## 6. Files and proactive work

| Concept | Meaning and boundary |
| --- | --- |
| Artifact / Attachment | A work result and its message delivery reference. File existence alone does not establish attachment delivery. |
| Agent Workspace / VFS | The Agent's file workspace. It is not Comma's authorization Workspace. |
| Comma Drive / Drive Binding | User file access and synchronization, plus the Group's authority to access a Drive. |
| Schedule / Schedule Run | A time-based definition and one occurrence of its execution. They have separate identities and lifecycle facts. |
| Heartbeat | A periodic Agent-work schedule. It is not the Connector's connection heartbeat. |
| Background Loop | An Agent-owned eBPF program that spinfoam runs on the Agent's lease-holder node: the VFS path and hash of its compiled object, config, capability grants, target Session, status, and checkpoint. It has no occurrences (not a Schedule), no history (not a Runtime Session), and no visible collaboration facts (not a Task). Its incarnation is a fence value on the row, not another entity. A `script.run` program also runs in spinfoam but is a transient part of one tool call (no row, no incarnation, no checkpoint), not an entity. |
| Calendar Item / Occurrence | A calendar object and one concrete occurrence. A Calendar Task does not contain the full Agent Task. |
| Meeting / Meeting Task | Meeting work and its Task representation, including recording and results. Meeting and Runtime Session identities remain distinct. |
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
The member's Router judges these candidates in one [bounded model request](../../systems/apps/comma_web/lib/comma_web/recommendation_renderer.ex) with its own template.
An operator-configured Routine template replaces only the model. The request runs without tools, a conversation turn, or a Router session.
It selects, ranks, and names each suggestion. A generic briefing uses one Worker request.
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
The Router judges unfinished work and material risks from that evidence. Missing context does not prove completion.
Source reads use existing tool DependencyJobs. Crashes return source failures, and owner cancellation stops the read and releases admission.
The model request uses the existing LLM DependencyJob admission and the original run deadline.
It retains the judging Agent and Run identity through existing billing and encrypted archive seams.
Source evidence and Snapshot validation share [HTTP destination extraction](../../systems/apps/comma_core/lib/comma/recommendation_contract.ex).
A source field that starts with a URL can still contain prose. Whitespace separates its URLs from that prose.
Formatting quoted context must not create a different destination or break its source binding.

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
All requests share the collector's existing per-source deadline. Subscription notifications do not establish work relevance.
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
Discovery selects an active managed Slack binding instead of the old Composio source. The Profile retains the member's enabled choice.
Old Composio accounts remain stored. Without an active managed binding, existing Composio sources still need their exact consent receipt.
Gmail uses the authenticated mailbox and important inbox mail addressed to it, read or unread, that waits for a reply.
A message the member sent later in the same thread closes it. One item per thread remains. Promotional and social labels are excluded.
Calendar uses the primary calendar and keeps the coming week's self-organized or self-attended events, excluding declined and cancelled events.
Drive requires verified ownership for recently changed files. It does not treat all visible or shared files as personal work.
It also reads open comments by others that name the member's address on the five most recently changed files. A file without comment access contributes none.
Composio publication/display fences use the local consent receipt, not a remote provider probe. External account changes are observed at collection or source reconciliation.
Notion member reads need no configuration. The retired `member_source_rules` column remains stored but unused.
Notion verifies the token's user owner. It queries at most five task databases, which have a people property and a Notion status property.
An open item names the member in a people property and has a status outside the Complete group. The property name reaches the Router as the member's role.
It also reads at most five pages that the member last edited or created within seven days, with their outline and text tail.
On the five most recently edited pages, open comments by others from seven days that mention the member lead the source.
Each candidate relationship is necessary, not sufficient, evidence for a useful task. The Router must omit items without concrete work context or a reason to act.
The authenticated Settings form owns mode, never provider identity or consent. Routine does not read Comma long-term memory or work preferences. The retired `work_context` column remains stored but unused. Existing migration sources remain unchanged. Changes reuse source-revision invalidation and preserve the refresh schedule. The member draft compiler drops tasks without same-source evidence references and removes summary paragraphs not grounded in retained tasks. This guards grounding, not semantic relevance. Live-provider relevance, provider shape verification, and performance validation remain incomplete.

A Recommendation is a product projection, not a Conversation Message.
Its prompt action fills a composer draft. The user must send it to enter the Chat path.
Every Routine row is a prompt action in both relevance modes. A row title is the member's own task.
Its composer text asks Comma for help with that task in the first person, such as "Help me decide...", so Comma does not take over the member's part.
The member selection prompt therefore asks for titles that start with their verb.
The draft compiler turns a text row that the model left as a plain source link into that request, followed by the link. Model-written prompts stay as written.
A row that stands for an existing Task, which is mail with a confirmed Task, opens that Task instead. It leaves the rail when the Task ends. A prompt row that only mentions a Task keeps its prompt.
Comma Workspace references a Synchronicity organization and default network. Salix owns the Group's Drive binding.

## 7. Devices and compute

| Concept | Meaning and boundary |
| --- | --- |
| Device | A stable managed device identity. Device connectivity does not establish runtime authentication or readiness. |
| Connector | The program that connects device capabilities and runtimes to Salix. A live Connector run is not a new device identity. |
| Command Environment | An execution environment selected within one Device. |
| Compute Pool / Node | Resource supply and a node that provides compute. Neither is the business Workload identity. |
| Compute Environment | A stable Project, Swarm, or Group ownership boundary. It is not an Allocation or a device query alias. |
| Workload | Stable work within Compute. Kinds include shell, external_worker, meeting_runtime, and service. |
| Allocation / Runtime Instance | Resource allocation and a particular execution instance. Allocation.generation fences allocation authority. RuntimeInstance.connection_epoch fences container execution. ProviderBinding/Host Session.connection_epoch fences the control connection. Host reconnect preserves the allocation generation and execution identity. Explicit release or revoke retires allocation authority. These facts do not replace Environment or Workload identity. |
| Runtime Binding | An Agent's fixed external execution target. Codex identity uses the discovered entry path, including symbolic links. The resolved executable version and live epoch remain separate. |
| Compute Grant / Service Route | Compute access authority and service access routing. A Compute Grant is not a Billing Credit Grant. |

Cloudflare Group execution reuses the original Agent tool DependencyJob while the VM becomes ready.
The existing Workload `runtime_selection_until` value bounds selection and pre-dispatch demand.
Concurrent callers extend that hold with a maximum. Cancellation does not clear another caller's hold.
The default exec readiness budget is five minutes. Each admitted waiter reads only its target, at most once per second.
Existing DependencyAdmission limits concurrency. Direct operational dispatch remains immediate unless it opts into waiting.
After readiness, the existing Workload operation admission precedes one exec dispatch. Unknown sent results cannot replay.
No new command queue, Workload identity, or execution owner is introduced.

[ArchiveDiagnostics](../../systems/apps/salix_web/lib/salix_web/cloud_vm/archive_diagnostics.ex) stores bounded observations in the existing Workload archive value.
It owns neither an operation lifecycle nor recovery authority. See [diagnostic limits and queries](../observability.md#cloud-vm-archive-diagnostics).

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
[RuntimeBindingResolver](../../systems/apps/salix_agent/lib/salix_agent/runtime_binding_resolver.ex),
[ServiceRoutes](../../systems/apps/salix_store/lib/salix_store/service_routes.ex).

[ChatDevices](../../systems/apps/comma_core/lib/comma/chat_devices.ex) is a read-only Device projection for authorized private chats.
It adds no Device, Conversation, Task, or authorization owner.
One replaceable navigation record per IM Connect stores up to six device IDs and two opaque cursors, at most 16 KiB.
The record has a fifteen-minute logical expiry. It contains no device facts, credentials, or authority.
A random list marker identifies a displayed list only. It rejects stale numbered choices, including concurrent page changes.
Comma rechecks the current User/Workspace binding and exact Device scope on each action.
Reads do not probe devices. Loss of this disposable projection requires a new list command, without loss of product facts.
No physical deletion deadline or exactly-once provider reply is claimed.

### Local VMM disposal

A local disposal records the OS operator's accepted deletion of an exact local Environment or remote registration.
The Host store owns its immutable scope, replay fence, namespace checkpoints, and existing operation receipt.
The registration and Environment remain the resource identities. Disposal does not transfer cloud authority or replace their owners.
A generic operation has no durable target mapping. Resource rows can disappear during deletion, so they cannot preserve the replay fence.
The fence survives cleanup and restart. A new authorized installation uses new identities and does not inherit disposed data.
Implementation: [Host disposal store](https://github.com/AFK-surf/agent-vmm/blob/main/internal/host/store/local_disposal.go).

### Comma node settings and Shell creation

Comma presents the local node separately from the selected Workspace's Workloads. An owner has one Compute Environment, enforced by its tenant/owner unique index.
[ComputeNodeService](../../clients/apps/electron/src/main/modules/compute-node/index.ts) owns persisted node intent, binding scope, operation results, and read observations.
[AccountComputeNodeService](../../clients/apps/electron/src/main/modules/compute-node/account-service.ts) partitions that intent by canonical backend audience and stable User subject.
Its Session generation fences the entire command, including queued work and A-to-B-to-A login changes. Accepted late results persist only to their original partition.
Unowned historical records migrate only after the original subject, scope, and existing Host root are proved. They grant no current authority.
[AgentVMMInstallations](../../systems/apps/salix_store/lib/salix_store/agent_vmm_installations.ex) remains the cloud installation owner.
A recovery challenge is a short-lived, single-use authorization value on that installation, not another identity or lifecycle.
Consumption moves only its delivery target to a current Session of the original subject. Normal mutations recheck active authorization under the same row lock.
An unexchanged request can be closed by its original subject before explicit new setup. A completed exchange must use proof-based recovery.
[LocalComputeOperator](../../clients/apps/electron/src/main/modules/compute-node/local-operator.ts) projects bounded local metadata and submits trusted operator confirmations.
Cloud mapping requires the current Workspace read permission and exact registration, Allocation, and generation. Read rights do not imply write rights.
The resource page reads at most 32 environments, one disk total, one optional receipt, and one cloud mapping batch every five seconds while visible.
Cached environment bytes are optional, with a 15-second freshness limit and exact boot, namespace, and generation checks. Missing values cause no Guest probe.
Manual Workload reads contain at most 32 items and current owner phases. No per-environment polling or automatic pagination is added.

Confirmation freezes the existing Workspace and installation identity. Main rejects a changed binding before drain or removal.
Its `refresh` capability coalesces reads without installing, repairing, or changing desired state. `state.get` returns a snapshot.
Connection, admission, readiness and work activity remain independent. An unknown result is not success or proof that children stopped.
Main reads activity through the Comma installation GET after Workspace and exact Session delivery-target authorization. It never sends a Comma Session credential to the tenant API. Failed or absent activity observations are unknown; a genuine product 401 still invalidates the Session.
The UI presents a status and an applicable action. Diagnostic details retain technical facts. Initial enablement ensures the existing node Workload.
Disabling drains this registration's allocations. Normal removal revokes this Workspace registration and stops its environments into Retained.
Retained preserves private volumes and writable layers. Only confirmed local disposal deletes them. All paths preserve the shared Host and other registrations.
Local detachment after an inaccessible registration does not confirm remote revocation. Re-enabling does not promise restoration of previous work.

[Comma.Compute](../../systems/apps/comma_core/lib/comma/compute.ex) authorizes every creation and indexed request lookup.
`Workload.creation_request_scope/id/input` associates a client creation request with its canonical input. These values grant no authority and create no entity.
[Compute](../../systems/apps/salix_store/lib/salix_store/compute.ex) commits that association with Allocation and Workload in one transaction.
The unique scope/request index prevents duplicate placements. Same input returns the same objects, including after a lost response. Changed input returns a conflict.
A deliberate additional Shell uses a new request ID. Existing records and volumes are not merged or deleted. Associations remain with their Workload records.
Published clients without a key keep their original creation contract. New clients always send one, with no keyless fallback.
The client persists only one unconfirmed request per backend/account/Workspace before dispatch. Reload checks it without automatically replaying creation.
[Settings](../../clients/packages/app/src/components/useComputeNodeCategory.tsx) use advanced Shell creation and the existing shared settings components.
Workload pages contain at most 100 items. A visible page observes one Workspace page at five-second intervals for at most 60 rounds.
Each round uses at most one page read and one exact request lookup. Hidden pages stop. Reaching the observation budget does not cancel work or declare failure.

`Workload.runtime_update` is a Workload-owned operation value, not another identity or lifecycle authority.
[ComputeWorkloadUpdate](../../systems/apps/salix_store/lib/salix_store/compute_workload_update.ex) admits an exact tenant/project/revision and serving-catalog target.
[The coordinator](../../systems/apps/salix_env/lib/salix_env/compute_workload_update.ex) advances preparation, drain, stop, replacement, and verification through the existing reconciler.
Completion/cancellation retains the last result. A later operation replaces that value.
[ComputeRuntimeRelease](../../systems/apps/salix_store/lib/salix_store/compute_runtime_release.ex) stores the desired external catalog as a release-owned projection.
Its singleton scope is one deployment database. `comma-release` publishes it after core success from the successful immutable image.
The existing Helm serving revision fences late publications. The projection adds no release identity or Workload lifecycle authority.
The reconciler compares Runtime digests for equality and admits the existing Workload operation. Each active operation retains its target.
Automatic attempts preserve the same quiet, accepted-input, instance, and volume boundaries as manual attempts.
Automatic timeouts do not require an operator decision. Storage capacity rejection retains its explicit action requirement.
Cancellation suppresses automatic admission for that target. A later target can start another operation.
Workload identity, generation, Session/subscription bindings, and volumes survive replacement. RuntimeInstance retains execution fencing.

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

A Group owns one selected Compute Environment and default Workload. This reuses existing identities and tables.
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

Cloudflare archive admission checks accepted Session demand, active operations, installation, and selection holds.
The shared Connector owner confirms quiet and fences new work. A transactional native-state snapshot retains dormant Session identities.
Each native quiet attempt has a 90-second budget, including ownership waits and native writes.
Salix and Gateway allow 100 seconds for the control transport. The archive token lease is separate from this execution budget.
Quiet inspects one 32-Session page at a time, with at most four concurrent native checks or drains.
Workers join before the page releases admission fences. Slow or failed checks retain the source and require a later retry.
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
The product permits omission of Agent workspaces, managed dependency packages, and workspace sweep archives in that scope.
The Connector retains exact native continuation and credential paths, including paths inside an omitted tree.
Unknown files outside those paths retain the full archive rules. Recovery still requires quiet and acknowledged runtime events.
The recovered Agent receives a notice about omitted data. Normal idle archives retain their full scope.
Installation declarations and directory markers cannot authorize omission. Existing approved cache omissions remain.
Workspace sweep archives retain their separate scope. Historical omitted archives still consume their saved restore intent.
Best-effort installation cannot prove recovery of bytes omitted from an old archive.
[Connector archive selection](../../systems/connector/salix-connect/main.go) and
[dependency declarations](../../systems/connector/salix-connect/dependency_installations.go) implement this distinction.

A Group VM retains bounded dependency installation declarations without new omission or restore intent.
A missing source directory removes its declaration before export. The Salix managed runtime and credentials remain archived.
Historical omitted declarations can rebuild after wake without delaying Device readiness. The Agent can stop that installer and use the normal shell.
A limit error preserves the source resource. It does not authorize deleting runtime packages or user files.
Restore imports native state only into an unused Connector. Generic archives cannot overwrite an open runtime database.

After archive persistence, the exact quiet token permanently fences the old process before provider destruction.
An uncertain release or destruction retains the archive and interrupted transition. It cannot reopen input against a stale checkpoint.
Idle and image-release archives support explicit pre-commit cancellation. Age alone does not transfer archive ownership.
Container image releases use the same archive path before stopping active Group Containers.
The image release ignores Containers without a business Workload association. Their disks are disposable during image replacement.
Group release retains the stopped Workload and its archive.
An interrupted wake keeps its Workload operation until the reconciler resumes it or reports a bounded recovery error.
Creating or enabling an Agent does not create a Group VM. A valid `env.ensure_runtime` request or a command for the exact default Cloud VM environment creates the Group Workload on first use. Read-only Device discovery projects that default identity before creation, then projects it from the Workload while its Connector is offline. Discovery does not create the VM.
The image release fence permits a restricted archive repair connection to the exact archiving Container.
It also permits exact non-starting confirmation and sealing of a waking target.
An unused target can rebuild after its quiet admission proof and complete retained archive check.
An admitted or unknown target requires a critical checkpoint. Unknown execution outcomes still require exact repair.
Confirmed destruction preserves the wake ID and uses existing `archive_reason` values for the next restore stage.
The next permit starts that stage's budget once, after the release fence clears. Previous recovery generations remain held.
These are refinements of existing accepted-work and ownership contracts. Local tests do not prove cloud-provider progress.

### Cloud VM runtime preparation

The Group Workload owns `runtime_targets`, a configuration map with at most 16 entries.
A caller-supplied `request_id` identifies one installation intent within that VM. It is not a Worker or another runtime identity.
[CloudVM.Runtimes](../../systems/apps/salix_web/lib/salix_web/cloud_vm/runtimes.ex) owns preparation, status, and explicit retry.
The discovered Device runtime remains the execution target. `agent.create_worker` retains its existing connected-runtime binding contract.
Preparation does not create a Worker or change a Session binding.
The existing subscription binding stores automatic account selection from the same tenant pool.

The Router tool `env.ensure_runtime` accepts `provider` (`codex` or `claude`), `request_id`, and optional `retry`.
The Agent must enable a Cloudflare VM. Existing provisioning and billing checks still apply.
Reusing an ID returns the same intent. Changing its provider fails.
States are `pending`, `installing`, `installed`, and `failed`. Installation and authenticated readiness are separate facts.
The returned `target` uses `kind=connected` and the existing `device_runtime_id`.

One Group installs one target at a time. Each server permits four installation tasks.
The shared Compute reconciler resumes pending intents. The total preparation budget is 300 seconds, including VM startup.
An expired or interrupted attempt reports `runtime_install_timeout`. It requires `retry=true` to start another bounded attempt.
Retries preserve the entry path, native state, and account selection.
Readiness uses current Connector inventory and authentication. It does not prove a successful model request.

[RuntimeInstall](../../systems/apps/salix_web/lib/salix_web/cloud_vm/runtime_install.ex) installs the release lock's exact CLI versions.
It requires Node 20 or later, npm, and flock. Missing prerequisites fail without a VM rebuild.
The Cloudflare image contains the Go Connector and locked default Codex, Claude, and Pi commands.
Default packages live under `/opt/salix/default-harness` outside restored user package trees.
The image appends its command directory to PATH. Existing managed targets and PATH commands keep discovery priority.
[Connector startup](../../systems/connector/salix-connect/harness_startup.go) preserves the discovered command and credential identity.
Managed Cloudflare cold starts can try the original CLI, then one image default after a launch or protocol failure.
Existing live processes remain preferred. Each failed candidate must stop before the next starts.
Authentication, configuration, explicit native rejection, and unknown business sends do not trigger this retry.
Failed fresh candidates cannot publish business output. Native Session IDs and durable recovery obligations remain unchanged.
A confirmed normal process exit settles an existing native recovery execution through its Session owner.
Published managed entries retain their target identity when package dependencies disappear. Empty installation directories declare no target.
Codex readiness reads version evidence from the selected process generation. Older native servers receive one cached, bounded command-version probe.
Version failures leave that process alive and unavailable. They grant no authentication, recovery, or cross-version retry authority.
Managed Claude and Pi readiness use the same bounded startup selection before they query the selected command version.
A version failure reports unavailable without another launch. Native auth, configuration, and explicit rejection remain terminal.
Claude retries missing-executable or missing-module bootstrap failures only before a valid auth response.
Pi consumes correlated native responses and stream closure in order. Local model configuration still requires provider verification.
Readiness stops and joins each owned temporary process before another candidate starts.
The request budget is twenty seconds, with at most one three-second cleanup tail.
An installation without a published entry declares no target. Readiness does not create one.
Image defaults do not prove authentication or native continuation.
Its attachment delegates protocol handling to ConnectorSocket through
[ConnectorSession](../../systems/apps/salix_web/lib/salix_web/cloud_vm/connector_session.ex).
Installation uses the exact live Connector and refreshes inventory without restarting it.
Repair installs a new package directory and checks the CLI before it updates the requested wrapper.
Each wrapper retains its exact package path. A version cache reuses successful repairs without changing existing package trees or running children.
Disconnect ends transport requests without replaying unknown commands or stopping independent native work.

Packages and entry wrappers live under the VM user's `.local/share/salix` directory.
Cloudflare links `/home/sprite` to `/workspace/.salix/sprite-home` to retain migrated entry paths.
Its HOME and Connector state are under `/home/sprite/.local/share/salix/connector-home`. Its command and file root remains `/workspace`.
Native queues, Session state, credentials, and VM disks are retained product data.
Automatic unused-VM teardown and provider switching refuse to remove a VM with runtime intents.
This change adds no deletion or cross-provider migration of those targets.
Targets share the Group VM trust domain. They are not separate hostile-code sandboxes.

A trusted tenant runtime API can bind an existing organization account after discovery.
Codex uses subscription OAuth. Claude uses subscription OAuth or a compatible Provider API key account.
The existing subscription binding owner controls delivery, reconnect, rotation, and confirmed revocation.
Managed Claude execution rechecks that binding before native admission. An unavailable server cannot authorize an offline start.
Agent tools cannot choose accounts or supply credentials. The server selects an enabled, compatible account when no binding exists,
excluding subscription accounts in cooldown or with a known, unreset provider-wide exhausted quota window.
Unknown quota, expired windows, and model-specific limits do not exclude an entire multi-model runtime target.
Healthy automatic bindings remain selected. When pool observations show provider-wide exhaustion and another candidate exists,
reconciliation can revoke the automatic binding only after the Connector acknowledges idle-only revocation, then select a replacement.
Active native work and durable recovery obligations defer rotation; older Connectors reject the idle-only request safely.
Manual bind and unbind disable automatic selection and rotation for that target. Failed Tasks are not replayed automatically.

[RuntimeLifecycle](../../systems/apps/salix_web/lib/salix_web/cloud_vm/runtime_lifecycle.ex) submits Cloudflare wake intent and holds selection for at most 30 seconds.
Compute owns whole-resource archive and wake. These fields do not create another VM or Task entity.
The existing Session work projection supplies conservative runnable demand. Human-action waits do not require an active VM.
The Connector also checks durable inputs, recovery, unacknowledged results, native background tasks, and managed processes.
Kimi cannot prove native quiet while its Session process exists. Explicit stop must complete before archive.
Idle suspension retains native history, credentials, installed targets, and Session identities. Dispatch wakes the same VM.
See [local preparation and API paths](../development.md#cloud-vm-external-runtimes).

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
[ContextLifecycle](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/context_lifecycle.ex).

User Assistant Chat and WorkspaceItem are retired with the My Space board. BFT has no per-user Chat
binding or local board item. The `user_assistant_chats` and `workspace_items` tables keep only stored
rows, which the conversation and session identity migrations still rewrite.
BFT Agent's salix field is virtual. It is not a persisted copy of Salix Agent configuration.
ContextLifecycle supports explicit deletion and erasure. It does not yet schedule retention periods or implement legal holds.

## Desktop concepts and naming traps

Browser Tab, Browser Session, Site Permission, and Meeting Recording are client concepts.
Browser Session is neither Auth Session nor Agent Runtime Session.
See [Browser sidebar](../../clients/apps/electron/src/main/modules/browser-sidebar/index.ts),
[Site permissions](../../clients/apps/electron/src/main/modules/browser-sidebar/site-permissions.ts),
and [Meeting recorder](../../clients/apps/electron/src/main/modules/meeting-recorder/index.ts).

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
  connection uses the checked address.
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

Implementation: [tools](../../systems/apps/salix_agent/lib/salix_agent/tools/ssh.ex),
[sessions](../../systems/apps/salix_agent/lib/salix_agent/ssh/sessions.ex),
[session process](../../systems/apps/salix_agent/lib/salix_agent/ssh/session.ex),
[terminal emulator](../../systems/native/verified_kernel/runtime/VerifiedKernel/Terminal.lean),
[client key](../../systems/apps/salix_agent/lib/salix_agent/ssh/identity.ex),
[trusted host keys](../../systems/apps/salix_agent/lib/salix_agent/ssh/known_hosts.ex),
[destination policy](../../systems/apps/salix_agent/lib/salix_agent/egress/destination.ex),
[Tailcat gateway owner](../../systems/apps/salix_agent/lib/salix_agent/ssh/tailcat_gateway.ex),
[Tailcat gateway](../../systems/tailcat-gateway/gateway.go).


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
A Gmail trigger event reads that one source sooner. See [Member Source Items](#member-source-items).
A source recorded for the first time is a baseline and interrupts nobody. Only items that arrive or change later wait for consumers.
With waiting items and an open budget, the consumer screens at most 24 items and 2.4 KB of Home history without a Router turn.
It returns the most urgent item, its urgency (critical, high, normal or low) and a plain-text message.
The server validates the item ID and hands critical and high items, with their urgency, to the canonical Router session as hidden Home input. Normal and low items stay in the daily briefing.
The Router reads current context and decides whether to notify the owner. The screening result is evidence, not a user-visible reply.
The consumer routes only while the judged item still waits, unchanged. It holds the item and source state rows locked during the handoff. A revocation, source change, or new collection commits before the check, which routes nothing, or after the accepted input.
The consumer records its outcome and the rated urgency on each judged item.
An `unclear` or unusable judgment decides nothing: the items stay pending as `retry`, after new arrivals, and are judged again, at most three times, before they settle as `invalid`. A pool item whose matter the owner's watch follows is not handed over again by the check. The judgment rates only from the evidence and does not lower a level to stay quiet; the Router rereads the source before any message.
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
Generic Loops remain Agent-authored. The binding pins a Workspace, user, connection, and consent revision. Each Agent admits at most 16 product bindings. Loop pause/resume and durable events retain their existing owners.
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
The value holds current message, owner, generation, handled state, one Schedule, optional Task, and an exact pending command.
ConversationServer and ConversationActor serialize actions. They reserve, perform idempotent effects, append a Message or app event, and finalize.
A failed operation remains pending. The owner can resume it after reload. Due retries resume their saved result before stale-generation checks.
The shared scheduler's `comma_mail` receiver owns timing and occurrence settlement. It preserves its Schedule until the due result commits.
Handled and snooze changes fence older final Home appends. A latest canonical Task read stops ended work without cross-Actor atomicity claims.
A resolved reply delivers once to the existing active Task through its Actor. It cannot reopen a terminal Task.
Routine projects handled source state and canonical Task status. A distinct new message can start new attention after the old message was handled or its linked Task ended.
Capacity is 128 sources and 256 KB per Home value. New tracking fails at capacity. No entry is silently evicted.
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
The proactive notebook is a projection, not an entity. It is one Markdown file, `Comma/Notebook.md`, in the owner's Drive.
The server renders it from the owner's Home values, watch Loops, pool source states and the latest judged pool items. No model writes it.
It also lists the latest published Routine briefing, also while a run refreshes it or after a failed run, with what happened to each item since, and marks quiet pool items that the briefing includes. Routine publication queues a render.
It groups matters by what needs the owner, what comes up later, what waits, what the Router did not interrupt them about with its reason, and what is done. Each Home value keeps the time it last changed for this order.
Matter changes, owner-scheduled due reminders, collections and proactive checks queue one render. Renders merge within one minute. A render equal to the stored file writes nothing, and source read times show only the hour.
A lost or edited file is replaced by the next render. An owner's edit on a device stays as their own Drive version and changes no matter.
The Drive is the Workspace's shared folder. The notebook holds private source titles, so it is written only while the owner is the Workspace's only member. Otherwise the render withdraws the hosted version. A copy that an owner's device already synced stays that device's version until the owner deletes it.
`proactive.state` returns its `/drive` path when the Drive holds it, so the Router can point to it.
Implementation: [product controls](../../systems/apps/comma_web/lib/comma_web/proactive.ex),
[proactive notebook](../../systems/apps/comma_web/lib/comma_web/proactive_notebook.ex),
[proactive consumer](../../systems/apps/comma_web/lib/comma_web/proactive_check.ex),
[attention judgment](../../systems/apps/comma_web/lib/comma_web/recommendation_renderer.ex),
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
An item waits for consumers only while its source's latest successful collection returns it and no later attempt failed as a whole. Mail the member answered leaves the result and stops waiting.
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

Implementation: [LLMMetering](../../systems/apps/billing_core/lib/billing_core/metering/llm_metering.ex),
[Drive](../../systems/native/verified_kernel/runtime/VerifiedKernel/Session/Drive.lean),
[Cloudflare](../../systems/apps/salix_web/lib/salix_web/compute_providers/cloudflare.ex),
[VoiceMetering](../../systems/apps/billing_core/lib/billing_core/voice_metering.ex).

Refusing new external input preserves any existing native execution owner and evidence.
An idle Session projects the financial reason. The retained `ExternalRuntime` model
checks durable local refusal before exact-prefix removal and prevents refused-input dispatch.
