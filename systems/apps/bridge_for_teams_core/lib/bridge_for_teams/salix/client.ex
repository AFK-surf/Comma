defmodule BridgeForTeams.Salix.Client do
  @moduledoc """
  The Salix anti-corruption layer behaviour (design §4). The single seam through
  which BridgeForTeams drives the Salix runtime.

  `BridgeForTeams.Salix.Erpc` reaches Salix by node selection. In same-BEAM
  tests/dev runs, `BridgeForTeams.Salix.Nodes` can pick `Node.self()` once
  `:salix_web` is started, so this still exercises the real Salix modules while
  Salix's own dependencies remain mockable.

  All callbacks return `{:ok, term}` or a tagged error following the salix erpc
  taxonomy: `{:error, :unavailable}` (`{:erpc, :noconnection}`),
  `{:error, :timeout}` (`{:erpc, :timeout}`), or `{:error, {kind, reason}}`.
  Timeout budget = call_timeout + 5_000.
  """

  @type result :: {:ok, term()} | {:error, term()}
  @type attrs :: map()

  # ---- Control plane (Salix.Control, app :salix_web) ----
  @callback create_tenant(attrs()) :: result()
  @callback update_tenant(id :: String.t(), attrs()) :: result()
  @callback get_tenant(id :: String.t()) :: result()
  @callback get_tenant_config(tenant_id :: String.t(), name :: String.t(), default :: map()) ::
              result()
  @callback update_tenant_config(tenant_id :: String.t(), name :: String.t(), value :: map()) ::
              result()
  @callback create_group_connector_token(
              group_id :: String.t(),
              tenant_id :: String.t(),
              attrs()
            ) ::
              {:ok, %{required(String.t()) => term()}} | {:error, term()}
  @callback create_group(attrs()) :: result()
  @callback update_group(group_id :: String.t(), tenant_id :: String.t(), attrs()) :: result()
  @callback get_group(group_id :: String.t()) :: result()
  @callback create_group_conversation(group_id :: String.t(), attrs()) :: result()
  @callback create_task_conversation(
              group_id :: String.t(),
              delegator_agent_id :: String.t(),
              worker_agent_id :: String.t(),
              attrs()
            ) :: result()
  @optional_callbacks create_task_conversation: 4
  @callback get_group_conversation(group_id :: String.t(), conversation_id :: String.t()) ::
              result()
  @callback subscribe_group_conversation(
              group_id :: String.t(),
              conversation_id :: String.t(),
              subscriber :: pid()
            ) :: result()
  @callback get_group_conversation_with_messages(
              group_id :: String.t(),
              conversation_id :: String.t(),
              opts :: keyword()
            ) :: result()
  @callback list_group_conversation_participants(
              group_id :: String.t(),
              conversation_id :: String.t(),
              opts :: keyword()
            ) :: result()
  @callback update_group_conversation(
              group_id :: String.t(),
              conversation_id :: String.t(),
              attrs()
            ) :: result()
  @callback set_task_archived(
              group_id :: String.t(),
              conversation_id :: String.t(),
              action :: :archive | :unarchive,
              expected_updated_at :: pos_integer()
            ) :: result()
  @callback accept_task_review(
              group_id :: String.t(),
              conversation_id :: String.t(),
              review_version :: pos_integer()
            ) :: result()
  @callback update_task_schedule(
              group_id :: String.t(),
              conversation_id :: String.t(),
              schedule :: map() | nil
            ) :: result()
  @callback list_group_conversations(group_id :: String.t(), opts :: keyword()) :: result()
  @callback list_group_conversation_messages(
              group_id :: String.t(),
              conversation_id :: String.t(),
              opts :: keyword()
            ) :: result()
  @callback get_group_conversation_attachment(
              group_id :: String.t(),
              conversation_id :: String.t(),
              message_id :: String.t(),
              index :: non_neg_integer()
            ) :: {:ok, %{filename: String.t(), body: binary()}} | {:error, term()}
  @callback group_conversation_delivery_status(
              group_id :: String.t(),
              conversation_id :: String.t(),
              opts :: keyword()
            ) :: result()
  @callback get_conversation_participant_status(
              group_id :: String.t(),
              conversation_id :: String.t(),
              participant_id :: String.t()
            ) :: result()
  @callback group_conversation_participant_statuses(
              group_id :: String.t(),
              conversation_id :: String.t(),
              participants :: [map()]
            ) :: result()
  @callback append_group_conversation_message(
              group_id :: String.t(),
              conversation_id :: String.t(),
              attrs()
            ) :: result()
  @callback redeliver_group_conversation_agent_message(
              group_id :: String.t(),
              conversation_id :: String.t(),
              attrs()
            ) :: result()
  @callback ensure_group_conversation_provider_participant(
              group_id :: String.t(),
              conversation_id :: String.t(),
              attrs()
            ) :: result()
  # Seed a conversation transcript WITHOUT waking agents
  # (`SalixIM.ConversationServer.seed_group_conversation_transcript/3`):
  # appends `attrs["messages"]` (each requires a
  # stable request identity; agent messages require a real group-member
  # `agent_id`) and,
  # with `attrs["mark_participants_delivered"]`, advances the delivery cursors
  # of `attrs["conversation"]["participants"]` past the seeded tail so delivery
  # recovery never replays them into an agent. Used for mock/demo transcripts.
  @callback seed_group_conversation_transcript(
              group_id :: String.t(),
              conversation_id :: String.t(),
              attrs()
            ) :: result()
  @callback send_provider_participant_message(
              group_id :: String.t(),
              conversation_id :: String.t(),
              participant_id :: String.t(),
              attrs()
            ) :: result()
  # Compact meeting records (bot-attended Google Meet sessions triggered from
  # IM providers) for the group, newest first — see `SalixMeet.list_group_meetings/1`.
  @callback list_group_meetings(group_id :: String.t()) :: result()
  # Bounded, typed-failure group source for one Triage evaluation — see
  # `SalixMeet.list_group_meetings_bounded/2`. Optional so an older Salix that
  # does not export it leaves `Meetings.list_triage_meetings/2` failing closed
  # rather than degrading to the unbounded dashboard scan.
  @callback list_group_meetings_bounded(group_id :: String.t(), opts :: keyword()) :: result()
  @callback replay_meeting_summary(
              group_id :: String.t(),
              meeting_id :: String.t(),
              opts :: keyword()
            ) :: result()
  @optional_callbacks list_group_meetings_bounded: 2, replay_meeting_summary: 3
  @callback list_group_im_connects(group_id :: String.t(), provider :: String.t() | nil) ::
              result()
  # The same read with `opts`: `:timeout` (ms) lets a page that reads many
  # groups fail fast. Optional: a client without it gets the 2-arity call.
  @callback list_group_im_connects(
              group_id :: String.t(),
              provider :: String.t() | nil,
              opts :: keyword()
            ) :: result()
  @optional_callbacks list_group_im_connects: 3
  # Returns a Slack App Manifest map
  # (`%{redirect_url, events_url, interactions_url, manifest}`)
  # built from the deployment's public base URL; not wrapped in an `:ok` tuple.
  @callback slack_manifest(app_name :: String.t()) :: map() | {:error, term()}
  @callback create_slack_im_connect(
              tenant_id :: String.t(),
              group_id :: String.t(),
              attrs()
            ) :: result()
  @callback update_slack_im_connect(
              tenant_id :: String.t(),
              group_id :: String.t(),
              connect_id :: String.t(),
              attrs()
            ) :: result()
  @callback create_feishu_im_connect(
              tenant_id :: String.t(),
              group_id :: String.t(),
              attrs()
            ) :: result()
  @callback update_feishu_im_connect(
              tenant_id :: String.t(),
              group_id :: String.t(),
              connect_id :: String.t(),
              attrs()
            ) :: result()
  # On-demand Feishu callback preflight. POSTs a synthetic official Feishu
  # callback envelope to the connect's webhook URL and asserts that the
  # URL-verification challenge round-trips. When the
  # binding carries an `encrypt_key`, the envelope is AES-encrypted with a random
  # 16-byte IV (official wire format) so an encrypted callback that the runtime
  # cannot decrypt fails honestly instead of false-greening. Returns
  # `{:ok, redacted_evidence}` or `{:error, reason_class}` where reason_class is
  # `:token_mismatch | :decrypt_signature | :callback_unreachable |
  # :encrypted_unsupported`.
  @callback feishu_callback_preflight(params :: attrs()) :: result()
  # Connect-aware callback preflight.
  # Identity-only: `params` carries a `"connect_id"`; the connect's bot secrets are
  # resolved INSIDE Salix from the tenant Feishu app store, never passed from
  # BridgeForTeams. Same evidence/reason taxonomy as
  # `feishu_callback_preflight/1` plus the fail-closed resolution classes
  # `:connect_not_found | :connect_inactive | :secrets_not_configured`.
  @callback feishu_callback_preflight_for_connect(params :: attrs()) :: result()
  # Connect-aware Feishu bot identity check. Verifies that the runtime connect
  # has resolved the Feishu bot's own `open_id`, which group-message routing
  # needs for exact @-mention matching. Returns `{:ok, redacted_evidence}` or
  # `{:error, :bot_identity_missing | :connect_not_found | :connect_inactive}`.
  @callback feishu_bot_identity(params :: attrs()) :: result()
  # Read-only Google Calendar meeting policy for one Feishu or Slack connect.
  # The Salix runtime resolves notification/auto-join policy against the current
  # Router's agent group and returns only explicitly configured shared
  # calendars; it never falls back to a private `primary` calendar.
  @callback meeting_calendar_policy(params :: attrs()) :: result()
  # Read-only variant for public diagnostics. It consumes only the configured
  # entry, active connect identity, and the durable enrollment proof; it never
  # resolves provider catalogs or creates/refreshes Calendar sources/watches.
  @callback meeting_calendar_policy_status(params :: attrs()) :: result()
  # Bounded, read-only status of the durable 24-hour calendar meeting
  # projection. This does not contact Google or create MeetingPlans.
  @callback meeting_calendar_status(params :: attrs()) :: result()
  @callback meeting_preparation(params :: attrs()) :: result()
  @optional_callbacks meeting_preparation: 1
  @callback disable_im_connect(
              tenant_id :: String.t(),
              group_id :: String.t(),
              connect_id :: String.t()
            ) :: result()
  @callback enable_im_connect(
              tenant_id :: String.t(),
              group_id :: String.t(),
              connect_id :: String.t()
            ) :: result()
  @callback delete_im_connect(
              tenant_id :: String.t(),
              group_id :: String.t(),
              connect_id :: String.t()
            ) :: result()

  @callback delete_group_im_connects(String.t(), String.t()) :: result()

  # ---- Tenant OAuth provider apps (Salix.Control.OAuthApps, app :salix_web) ----
  # Org-scoped (tenant-scoped) OAuth client credentials for providers such as
  # Notion/Linear. List returns one public-safe view per supported provider
  # (`%{"provider", "client_id", "client_secret_configured"}`) as a bare list;
  # `put`/`delete` mutate a single provider. Secrets are write-only and never
  # served back.
  @callback list_oauth_provider_apps(tenant_id :: String.t()) ::
              [map()] | {:error, term()}
  @callback put_oauth_provider_app(
              tenant_id :: String.t(),
              provider :: String.t(),
              attrs()
            ) :: result()
  @callback delete_oauth_provider_app(
              tenant_id :: String.t(),
              provider :: String.t()
            ) :: :ok | result()

  # ---- Tenant Signal number (Salix.Control.Signal, app :salix_web) ----
  # The tenant's own Signal number overrides the platform number for new
  # Signal connections (docs/messaging-voice.md). Views carry `override`,
  # `platform` and `effective` account views (`e164`, `state`, `scope`).
  @callback get_signal_number(tenant_id :: String.t()) :: result()
  @callback put_signal_number(tenant_id :: String.t(), number :: String.t()) :: result()
  # A project's Signal chats: status, one-time claim codes and bindings of
  # the project's Salix group (Salix.Control.Signal).
  @callback get_group_signal(group_id :: String.t(), tenant_id :: String.t()) :: result()
  @callback start_group_signal_claim(
              group_id :: String.t(),
              tenant_id :: String.t(),
              created_by :: String.t()
            ) :: result()
  @callback remove_group_signal_binding(
              group_id :: String.t(),
              tenant_id :: String.t(),
              binding_id :: String.t()
            ) :: result()

  # ---- Tenant Composio settings (Salix.Control.ComposioSettings, app :salix_web) ----
  # Org-scoped (tenant-scoped) Composio opt-in: the org's Composio project API
  # key + enabled flag, powering the composio.* agent tools as a direct
  # integrations path alongside OAuth provider apps. `get` returns the
  # redacted view (`%{"enabled", "api_key_configured", "base_url", "source"}`)
  # as a bare map; the API key is write-only and never served back.
  @callback get_composio_settings(tenant_id :: String.t()) :: map() | {:error, term()}
  @callback put_composio_settings(tenant_id :: String.t(), attrs()) :: result()
  @callback delete_composio_settings(tenant_id :: String.t()) :: :ok | result()

  # ---- Group Composio connections (Salix.Composio, app :salix_web) ----
  # Project-scoped (group-scoped) Composio connected accounts — the direct
  # integrations path. Composio's user id IS the Salix group id, so accounts
  # share the OAuth-binding tenancy boundary. `list` returns token-free account
  # maps (`%{"id", "toolkit" => %{"slug"}, "status"}`); `create_..._link`
  # resolves (or creates) the toolkit's auth config and returns a hosted
  # Connect Link (`%{"redirect_url", "connected_account_id"}`) the browser is
  # sent to; Composio returns it to the attrs `"callback_url"` afterwards.
  # `{:error, :not_configured}` when the tenant has no Composio settings.
  @callback list_composio_connected_accounts(
              tenant_id :: String.t(),
              group_id :: String.t()
            ) :: {:ok, [map()]} | {:error, term()}
  @callback create_composio_connect_link(
              tenant_id :: String.t(),
              group_id :: String.t(),
              toolkit :: String.t(),
              attrs()
            ) :: result()
  @callback delete_composio_connected_account(
              tenant_id :: String.t(),
              group_id :: String.t(),
              connected_account_id :: String.t()
            ) :: :ok | result()

  # ---- Plugins (Salix.Control.Plugins, app :salix_web) ----
  # Tenant definitions are org-owned plugin packages visible to every group in
  # the tenant. Group definitions are project-owned packages visible only to one
  # Agent Swarm. Enablement always lives on the group and only changes runtime
  # projection; child domains such as Skill/OAuth/IM/MCP/env keep their own
  # lifecycle state.
  @callback list_tenant_plugin_definitions(tenant_id :: String.t()) :: result()
  @callback create_tenant_plugin_definition(tenant_id :: String.t(), attrs()) :: result()
  @callback update_tenant_plugin_definition(
              tenant_id :: String.t(),
              plugin_id :: String.t(),
              attrs()
            ) :: result()
  @callback list_group_plugin_definitions(tenant_id :: String.t(), group_id :: String.t()) ::
              result()
  @callback list_group_plugin_enablements(tenant_id :: String.t(), group_id :: String.t()) ::
              result()
  @callback group_plugin_runtime_projection(tenant_id :: String.t(), group_id :: String.t()) ::
              result()
  @callback create_group_plugin_definition(
              tenant_id :: String.t(),
              group_id :: String.t(),
              attrs()
            ) :: result()
  @callback update_group_plugin_definition(
              tenant_id :: String.t(),
              group_id :: String.t(),
              plugin_id :: String.t(),
              attrs()
            ) :: result()
  @callback enable_group_plugin(
              tenant_id :: String.t(),
              group_id :: String.t(),
              plugin_id :: String.t()
            ) :: result()
  @callback disable_group_plugin(
              tenant_id :: String.t(),
              group_id :: String.t(),
              plugin_id :: String.t()
            ) :: result()
  @callback prepare_group_plugin_setup(
              tenant_id :: String.t(),
              group_id :: String.t(),
              plugin_id :: String.t(),
              connection_id :: String.t() | nil
            ) :: result()
  @callback start_remote_mcp_authorization(
              tenant_id :: String.t(),
              group_id :: String.t(),
              binding_id :: String.t(),
              params :: attrs()
            ) :: result()
  @callback disconnect_remote_mcp_authorization(
              tenant_id :: String.t(),
              group_id :: String.t(),
              binding_id :: String.t()
            ) :: :ok | result()

  # ---- Group OAuth account bindings (Salix.Control.OAuthBindings / SalixWeb.OAuthFlow) ----
  # Project-scoped (group-scoped) connected third-party accounts produced by
  # running a tenant provider app's OAuth authorization flow. `list` returns the
  # public-safe binding views (no tokens) as a bare list; `start_authorization`
  # builds the provider consent URL and
  # persists pending state (`{:ok, %{"authorization_url", "state"}}`); `delete`
  # removes a binding (and revokes/cleans up its connection when it was the last
  # reference).
  @callback list_group_oauth_bindings(group_id :: String.t()) ::
              [map()] | {:error, term()}
  @callback update_group_oauth_binding(
              group_id :: String.t(),
              binding_id :: String.t(),
              attrs :: attrs()
            ) :: result()
  @callback start_oauth_authorization(
              tenant_id :: String.t(),
              group_id :: String.t(),
              provider :: String.t(),
              params :: attrs()
            ) :: result()
  @callback delete_group_oauth_binding(
              tenant_id :: String.t(),
              group_id :: String.t(),
              binding_id :: String.t()
            ) :: :ok | result()

  # ---- Tenant Feishu app (bot secrets) (Salix.Control.Tenants, app :salix_web) ----
  # The org's Feishu custom app, keyed per tenant, holding the bot-side secrets
  # (`app_secret`, `verification_token`, `encrypt_key`). Bot secrets live in
  # Salix; BFT keeps only the non-secret posture. `put`
  # mirrors `put_oauth_provider_app`'s arg shape (tenant id + write-only attrs
  # map, pointer-merge semantics) and returns the public view
  # (`%{"app_id", "app_secret_configured", ...}`); secret values are write-only
  # and never served back.
  @callback put_feishu_tenant_app(
              tenant_id :: String.t(),
              attrs()
            ) :: result()
  @callback delete_feishu_tenant_app(tenant_id :: String.t()) :: :ok | result()
  @callback get_feishu_tenant_app(tenant_id :: String.t()) :: result()

  # List the tenant-visible LLM template catalog (`SalixAgent.Templates.list_available/1`).
  # Each entry is a public view — `%{"template_id", "name", "model", "provider",
  # "provider_type", "max_tokens"}` — with no credentials. Returns a bare list
  # (Salix template API convention). Drives BridgeForTeams's model-selection dropdown and
  # per-org allowlist editor.
  @callback subscription_operation(String.t(), atom(), list()) :: result()
  @callback device_managed_auth_operation(
              String.t(),
              String.t(),
              String.t(),
              String.t(),
              atom(),
              map()
            ) ::
              {:ok, map()} | {:error, term()}

  @callback compute_managed_auth_operation(String.t(), String.t(), String.t(), atom(), map()) ::
              result()
  @callback private_template_operation(String.t(), atom(), list()) :: result()

  @callback list_templates(tenant_id :: String.t()) :: [map()] | {:error, term()}
  # Read one visible template without exposing provider credentials.
  @callback get_template(template_id :: String.t(), tenant_id :: String.t()) :: result()
  # The effective Router/Worker default template per role for a tenant after
  # layering tenant and platform defaults (`SalixAgent.AgentDefaults`).
  @callback effective_agent_defaults(tenant_id :: String.t()) :: result()

  # Provision a Salix control-plane agent record (under attrs.tenant_id + group).
  @callback create_agent(attrs()) :: result()

  # Update an already-provisioned agent's control-plane record (e.g. its
  # `template_id`/model, name, system prompt) — `SalixAgent.Control.update`.
  # The control record is create-once, so post-provision changes route here.
  @callback update_agent(agent_id :: String.t(), tenant_id :: String.t(), attrs()) :: result()
  # Read an already-provisioned Salix agent control record under a tenant.
  @callback get_agent(agent_id :: String.t(), tenant_id :: String.t()) :: result()
  # Read a visible control record without session-derived runtime decoration.
  @callback get_agent_projection(agent_id :: String.t(), tenant_id :: String.t()) :: result()
  @callback create_owned_agent(map()) :: result()
  @optional_callbacks create_owned_agent: 1

  @callback page_group_agents(String.t(), String.t(), keyword()) :: result()
  @optional_callbacks page_group_agents: 3

  @callback archive_agent_configuration(String.t(), String.t()) :: result()
  @callback rebind_agent_configuration(
              String.t(),
              String.t(),
              map(),
              non_neg_integer(),
              String.t()
            ) :: result()
  @optional_callbacks archive_agent_configuration: 2, rebind_agent_configuration: 5

  @callback claim_agent_configuration(String.t(), String.t(), integer() | nil) :: result()
  @callback configure_agent(String.t(), String.t(), map()) :: result()
  @optional_callbacks claim_agent_configuration: 3, configure_agent: 3
  # Expand-only seam for RFC25. BFT supplies the already-authorized Project
  # tenant/group/owner facts; Salix owns target interpretation and fencing.
  @callback page_external_worker_targets(
              tenant_id :: String.t(),
              owner_type :: String.t(),
              owner_id :: String.t(),
              group_id :: String.t(),
              provider :: String.t(),
              opts :: keyword()
            ) :: result()
  @callback validate_external_worker_target(
              tenant_id :: String.t(),
              owner_type :: String.t(),
              owner_id :: String.t(),
              group_id :: String.t(),
              provider :: String.t(),
              workload_id :: String.t(),
              selection_fence :: map()
            ) :: result()
  @callback apply_external_worker_binding(
              agent_id :: String.t(),
              tenant_id :: String.t(),
              runtime_config :: map()
            ) :: result()
  @optional_callbacks page_external_worker_targets: 6,
                      validate_external_worker_target: 7,
                      apply_external_worker_binding: 3

  # ---- Agent runtime (SalixAgent, app :salix_agent) ----
  @callback deliver(agent_id :: String.t(), payload :: map(), opts :: keyword()) :: result()
  @callback switch_router_session(
              agent_id :: String.t(),
              tenant_id :: String.t(),
              expected_session_id :: String.t()
            ) :: result()
  @callback list_sessions(agent_id :: String.t(), opts :: keyword()) :: result()
  @callback get_session(agent_id :: String.t(), session_id :: String.t(), opts :: keyword()) ::
              result()
  @callback get_session_messages(agent_id :: String.t(), session_id :: String.t()) :: result()
  @callback list_project_knowledge_uses(agent_id :: String.t(), opts :: keyword()) :: result()
  @callback session_records(
              agent_id :: String.t(),
              session_id :: String.t(),
              opts :: keyword()
            ) :: result()
  @callback session_trace(agent_id :: String.t(), session_id :: String.t(), opts :: keyword()) ::
              result()
  # The agent's current in-memory activity surface (`SalixAgent.ActivitySurface`
  # — the last live thinking/typing/execution signal per running session), for
  # seeding a status display on connect. `{:ok, [activity_map]}`.
  @callback list_agent_activities(agent_id :: String.t()) :: result()
  @callback billing_history(agent_id :: String.t(), tenant_id :: String.t(), opts :: keyword()) ::
              result()
  # Deployed agent-hosted websites (VFS sites under the agent state); each entry
  # is `%{"name" => .., "url" => ..}`.
  @callback list_agent_sites(agent_id :: String.t()) :: {:ok, [map()]} | {:error, term()}
  # Write one file into an agent's VFS (`SalixAgent.Workspace.write/3`). Writing
  # `/.salix/websites/<name>/index.html` publishes/updates a hosted site.
  @callback write_agent_file(agent_id :: String.t(), path :: String.t(), body :: binary()) ::
              result()
  # Recursively delete a path from an agent's VFS
  # (`SalixAgent.Workspace.delete/3` with `recursive: true` — a billing-gated
  # storage delete). Returns `{:ok, %{"path" => .., "deleted" => n}}`.
  @callback delete_agent_path(agent_id :: String.t(), path :: String.t()) :: result()

  # The skills an agent's sessions see (`SalixAgent.SkillCatalog.list/2` over
  # the SkillStore projection): `{:ok, %{"skills" => [..], "revision" => ..}}`,
  # each `%{"skill_id", "name", "description", "location", "source" =>
  # "system" | "custom" | "imported", "layer", "editable", "deletable",
  # "delete_reason", "content"}`. `"location"` is the session runtime path
  # (`/.runtime/skills/<skill_id>/SKILL.md`) — the same one the agent's
  # prompt lists.
  @callback list_agent_skills(agent_id :: String.t(), tenant_id :: String.t()) :: result()
  # Create a group-level editable skill owned by the agent
  # (`SalixAgent.SkillCatalog.create/3`). `attrs` carries `"skill_id"`,
  # `"name"`, and optional `"description"`/`"content"` (a full SKILL.md body).
  # `{:error, :duplicate}` when the id or name is already projected.
  @callback create_agent_skill(agent_id :: String.t(), tenant_id :: String.t(), attrs()) ::
              result()
  # Delete an editable group-level skill as an authenticated human control-plane
  # actor (`SalixAgent.SkillCatalog.delete/4`). BFT authorizes the actor first;
  # Salix enforces the group/editable boundary store-side.
  @callback delete_agent_skill(
              agent_id :: String.t(),
              tenant_id :: String.t(),
              skill_id :: String.t(),
              actor :: map()
            ) :: result()

  # Read one file body from an agent's VFS (`SalixAgent.Workspace.read/2`).
  # `{:error, :not_found}` for a missing path.
  @callback read_agent_file(agent_id :: String.t(), path :: String.t()) ::
              {:ok, binary()} | {:error, term()}
  # List an agent's VFS entries under `path` (`SalixAgent.Workspace.list/2`).
  # Directories yield `{:ok, [entry]}`; when `path` names a file the runtime
  # answers `{:file, entry}` instead. Each entry is
  # `%{"path", "kind" ("file"|"dir"), "size", "modified_at"}`.
  @callback list_agent_files(agent_id :: String.t(), path :: String.t()) ::
              {:ok, [map()]} | {:file, map()} | {:error, term()}
  # ---- Schedules (SalixCluster.Schedules, app :salix_cluster) ----
  # Recurring schedule definitions are rows in the salix control Postgres
  # (docs/storage-search.md); each definition's receiver
  # identifies its target. Listing is owner-filtered at the store — callers
  # pass the bounded agent-id set they own and unrelated definitions are
  # neither queried nor transferred. `delete` removes one definition and is
  # idempotent.
  @callback get_schedule(schedule_id :: String.t()) :: result()
  @callback list_schedules_for_owners(agent_ids :: [String.t()], group_id :: String.t() | nil) ::
              {:ok, [map()]} | {:error, term()}
  @callback delete_schedule(schedule_id :: String.t()) :: :ok | {:error, term()}
  # Create one definition, create-once (`SalixCluster.Schedules.create/3`).
  # `attrs` carries the definition fields — `agent_id`, `prompt`, exactly one
  # of a positive `interval_minutes` | parseable `cron` (optional IANA
  # `timezone`), optional `session_id` — plus an `"id"`; the live impl
  # generates one when omitted. Returns the stored string-keyed definition,
  # `{:error, :already_exists}` on an id collision, or
  # `{:error, :invalid_schedule}` when validation fails.
  @callback create_schedule(attrs()) :: result()
  # CAS-merge `attrs` into an existing definition
  # (`SalixCluster.Schedules.update/2`); `"id"` cannot be changed. Returns the
  # merged definition, `{:error, :not_found}` for an unknown id, or
  # `{:error, :conflict}` when the CAS retry budget is exhausted.
  @callback update_schedule(schedule_id :: String.t(), attrs()) :: result()

  # ---- Public devices (SalixEnv.Control, app :salix_env) ----
  # Salix is the source of truth for project devices and their current
  # connector runs. Point reads and mutations use Control's typed public
  # projection. Bounded GET/list surfaces read the rebuildable BFT PostgreSQL
  # projection refreshed through `page_group_envs/3`; they never read raw
  # Registry records or reconcile on the request path.
  @callback get_env(device_id :: String.t(), group_id :: String.t(), tenant_id :: String.t()) ::
              result()
  @callback list_group_envs(group_id :: String.t(), tenant_id :: String.t()) ::
              {:ok, [map()]} | {:error, term()}
  @callback page_group_envs(
              group_id :: String.t(),
              tenant_id :: String.t(),
              opts :: keyword()
            ) ::
              {:ok, %{records: [map()], next_cursor: String.t() | nil}} | {:error, term()}
  @callback disconnect_env(
              device_id :: String.t(),
              group_id :: String.t(),
              tenant_id :: String.t()
            ) :: result()
  @callback delete_env(
              device_id :: String.t(),
              group_id :: String.t(),
              tenant_id :: String.t(),
              connector_token_hash :: String.t() | nil
            ) :: result()
  @callback runtime_auth(operation :: atom(), attrs :: map()) :: result()
  @callback runtime_auth_read(
              device_id :: String.t(),
              device_runtime_id :: String.t(),
              group_id :: String.t(),
              tenant_id :: String.t()
            ) :: result()
  @callback runtime_auth_login_start(
              device_id :: String.t(),
              device_runtime_id :: String.t(),
              flow :: String.t(),
              group_id :: String.t(),
              tenant_id :: String.t()
            ) :: result()
  @callback runtime_auth_login_cancel(
              device_id :: String.t(),
              device_runtime_id :: String.t(),
              attempt_id :: String.t(),
              group_id :: String.t(),
              tenant_id :: String.t()
            ) :: result()
  @callback list_runtime_auth_requests(
              group_id :: String.t(),
              tenant_id :: String.t(),
              opts :: keyword()
            ) :: result()
  @callback get_runtime_auth_request(
              group_id :: String.t(),
              request_id :: String.t(),
              tenant_id :: String.t()
            ) :: result()
  @callback complete_runtime_auth_request(
              group_id :: String.t(),
              request_id :: String.t(),
              attrs :: map(),
              tenant_id :: String.t()
            ) :: result()

  # ---- Slack Triage Workbench (SalixIM.Triage.ReadModel, app :salix_im) ----
  # Read-only windows over native Slack Triage durable state, backing the BFT
  # Triage Workbench (docs/bridge-for-teams/design.mda).
  # The Salix runtime namespace is always explicit: the read model reads no
  # configuration of its own, so BFT resolves it and passes it in.
  #
  # These sit on dashboard render paths and use the 3s read timeout, like the
  # workspace and conversation-status reads: a slow Salix must degrade a card,
  # never hang the page. `{:error, :unavailable}` stays distinct from an empty
  # page all the way to the UI.

  # A bounded scan for receipts created at or after `since_ms`, newest first.
  # The receipt keyspace is key-ordered, not time-ordered, so `truncated: true`
  # means the page budget ran out and the window may be missing rows — the UI
  # renders that, never an unqualified "N events". Options: `:page_budget`.
  @callback triage_recent_window(
              namespace :: String.t(),
              since_ms :: non_neg_integer(),
              opts :: keyword()
            ) :: result()
  # Bounded product-facing Triage lifecycle for one exact project/Agent:
  # reply or silence, context effects, and delegations.
  # Raw provider/runtime evidence never crosses this callback.
  @callback triage_product_activity(
              project_id :: String.t(),
              group_id :: String.t(),
              agent_id :: String.t(),
              opts :: keyword()
            ) :: result()
  # Agent-wide hourly outcome counts per Slack channel for the last 7 days.
  @callback triage_product_heatmap(
              project_id :: String.t(),
              group_id :: String.t(),
              agent_id :: String.t()
            ) :: result()
  @callback ensure_triage_worker(String.t(), String.t()) :: result()
  @callback triage_worker_binding(String.t()) :: result()
  @callback triage_worker_configuration(String.t(), keyword()) :: result()
  @callback configure_triage_worker(
              String.t(),
              String.t(),
              String.t() | nil,
              non_neg_integer(),
              map()
            ) :: result()

  @callback triage_processing_detail(group_id :: String.t(), receipt_ref :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback triage_source_presentation(group_id :: String.t(), receipt_refs :: [String.t()]) ::
              result()
  # User-requested exact lookup of one delegation's canonical Task. This does
  # not create a Task or change the Triage obligation's stored disposition.
  @callback triage_delegation_task(
              project_id :: String.t(),
              group_id :: String.t(),
              agent_id :: String.t(),
              obligation_id :: String.t(),
              index :: 0 | 1
            ) :: result()
  # Project-scoped active Triage context for the canonical Knowledge read
  # interface. The Agent id proves the selected active product identity but
  # does not filter rows by their producing Agent.
  @callback triage_knowledge_context(
              project_id :: String.t(),
              group_id :: String.t(),
              agent_id :: String.t(),
              opts :: keyword()
            ) :: result()
  # A hard-bounded deployment-wide Triage review-ring aggregation. The result
  # carries top-level `evaluation_readiness: :ready | :unavailable | :unknown`;
  # missing/failed/old-shape members and incomplete discovery are `:unknown`,
  # never a sampled readiness claim.
  # `salix_im` owns neither process name, so the caller supplies
  # `%{runtime: server_ref | nil, recovery: server_ref | nil,
  # evaluation_agent_id: String.t() | nil}`. The Agent id selects the live
  # identity-bound provider template checked on every observed Salix node.
  # Under
  # `salix_web` those are the registered names
  # `Salix.Bindings.TriageReviewRuntime` and
  # `Salix.Bindings.TriageReceiptRecovery` — resolved on the far side at
  # runtime, so naming them here creates no compile dependency. A missing
  # process reports `running: false` (the runtime being off is a fact, not a
  # fault); a present-but-silent one is `{:error, :unavailable}`.
  @callback triage_ring_status(
              refs :: %{
                optional(atom()) => atom() | pid() | String.t() | nil
              }
            ) :: result()
  # Per-connect Slack Triage posture for one group, display fields only — never
  # a bot token, signing secret, or client secret.
  @callback triage_connect_posture(tenant_id :: String.t(), group_id :: String.t()) :: result()

  # One bounded, credential-free page of Slack channels visible to an exact
  # connect. Used by the product channel picker; `cursor` is Slack's opaque
  # continuation token and `limit` is capped by Salix.
  @callback triage_list_slack_channels(
              tenant_id :: String.t(),
              group_id :: String.t(),
              connect_id :: String.t(),
              cursor :: String.t() | nil,
              limit :: pos_integer()
            ) :: result()

  # Every information-flow setting in one group, by connect: the group's mode,
  # each conversation's observed facts merged with its operator classification,
  # the tag clearances, and the principals' placements. Credential-free — no
  # message content and no tokens, only who may read what.
  @callback ifc_overview(tenant_id :: String.t(), group_id :: String.t()) :: result()

  # Classifies one conversation (tags, audience mode, sealed). Salix validates;
  # an unknown audience mode or a tag carrying the codec's separator is
  # rejected there rather than written and misread later.
  @callback ifc_put_scope_label(
              tenant_id :: String.t(),
              group_id :: String.t(),
              connect_id :: String.t(),
              scope_id :: String.t(),
              attrs :: map()
            ) :: result()

  # Returns one conversation to its defaults.
  @callback ifc_delete_scope_label(
              tenant_id :: String.t(),
              group_id :: String.t(),
              connect_id :: String.t(),
              scope_id :: String.t()
            ) :: result()

  # Clears one provider user for one tag. A clearance only ever widens what
  # someone may read; it never changes what they may write.
  @callback ifc_put_tag_clearance(
              tenant_id :: String.t(),
              group_id :: String.t(),
              connect_id :: String.t(),
              tag :: String.t(),
              user_id :: String.t()
            ) :: result()

  # Withdraws one clearance, by the principal key the overview returned.
  @callback ifc_delete_tag_clearance(
              tenant_id :: String.t(),
              group_id :: String.t(),
              connect_id :: String.t(),
              tag :: String.t(),
              principal_key :: String.t()
            ) :: result()

  # Overrides the provider's internal/external answer for one principal; a nil
  # placement drops the override and restores the provider's own answer.
  @callback ifc_put_placement_override(
              tenant_id :: String.t(),
              group_id :: String.t(),
              connect_id :: String.t(),
              user_id :: String.t(),
              placement :: String.t() | nil
            ) :: result()

  # Credential-free authority snapshot for one explicitly selected public
  # channel. Slack credentials remain inside Salix.
  @callback slack_history_source_authority(request :: map()) :: result()

  # One generation- and channel-fenced normalized history/replies page.
  @callback slack_history_read_page(request :: map()) :: result()

  # ---- Slack Triage authority writes (SalixIM.ProviderConnects) ----
  # The one-way provisioning door: stamps the approved channel, the router
  # agent, a fresh connect generation, and the permanent
  # `triage_provisioned_at` marker, leaving the connect provisioned but
  # disabled. `{:error, :slack_triage_authority_ineligible}` when the connect
  # or group cannot carry the authority.
  @callback triage_provision(
              tenant_id :: String.t(),
              group_id :: String.t(),
              connect_id :: String.t(),
              approved_channel_id :: String.t()
            ) :: result()
  # Flip one provisioned connect's review-only enablement. Disabling rotates
  # the connect generation, fencing in-flight admissions. Returns `:ok` (not an
  # `{:ok, _}` tuple) on success — the Salix API answers with a bare `:ok`.
  @callback triage_set_enabled(
              tenant_id :: String.t(),
              group_id :: String.t(),
              connect_id :: String.t(),
              enabled? :: boolean()
            ) :: :ok | {:error, term()}
  # Pause or resume one configured channel without changing its siblings or
  # the connect-wide Triage switch.
  @callback triage_set_channel_enabled(
              tenant_id :: String.t(),
              group_id :: String.t(),
              connect_id :: String.t(),
              channel_id :: String.t(),
              enabled? :: boolean()
            ) :: :ok | {:error, term()}

  @doc "The configured Salix client implementation (`{:bridge_for_teams_core, :salix_client}`)."
  @spec impl() :: module()
  def impl,
    do: Application.get_env(:bridge_for_teams_core, :salix_client, BridgeForTeams.Salix.Erpc)

  @doc """
  Calls an optional callback on the configured client, or returns
  `{:error, :unsupported}` when that client does not implement it.
  """
  @spec call_optional(atom(), [term()]) :: term()
  def call_optional(fun, args) when is_atom(fun) and is_list(args) do
    client = impl()

    if Code.ensure_loaded?(client) and function_exported?(client, fun, length(args)),
      do: apply(client, fun, args),
      else: {:error, :unsupported}
  end

  @optional_callbacks get_signal_number: 1,
                      put_signal_number: 2,
                      get_group_signal: 2,
                      start_group_signal_claim: 3,
                      remove_group_signal_binding: 3,
                      page_group_envs: 3,
                      slack_history_source_authority: 1,
                      slack_history_read_page: 1
end
