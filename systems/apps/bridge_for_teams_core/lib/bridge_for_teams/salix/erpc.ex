defmodule BridgeForTeams.Salix.Erpc do
  @moduledoc """
  Real `:erpc` implementation of `BridgeForTeams.Salix.Client` (design §4.2).

  Targets salix modules **by name at runtime** (no compile-time dep): control
  plane on `Salix.Control.*`, IM connects through `SalixIM.ProviderConnects`, agents on
  `SalixAgent.Control` / `SalixAgent.Runtime`, and public devices on
  `SalixEnv.Control`. A live salix node is picked via
  `BridgeForTeams.Salix.Nodes.pick/1`.

  Error taxonomy (mirrors `SalixEnv.Connector.Live` / `SalixCluster.Placement`):

      catch :error, {:erpc, :noconnection} -> {:error, :unavailable}
            :error, {:erpc, :timeout}      -> {:error, :timeout}
            kind, reason                   -> {:error, {kind, reason}}

  Timeout budget = call_timeout + 5_000.
  """
  @behaviour BridgeForTeams.Salix.Client

  alias BridgeForTeams.Salix.Nodes

  @default_timeout 15_000
  # SalixEnv owns a 30-second Connector request budget for runtime-auth RPCs.
  # Keep the BFT caller outside that deadline so a valid inner response cannot
  # be cancelled by the generic 15-second dashboard timeout.
  @runtime_auth_timeout 35_000
  # Workspace reads sit on dashboard render paths (sites/files/file content):
  # fail fast so a slow Salix degrades the UI instead of hanging it.
  @workspace_read_timeout 3_000
  # Conversation delivery/participant status reads back the conversation detail
  # page: fail fast so a sick agent runtime degrades the status panels instead
  # of hanging the read.
  @conversation_status_read_timeout 3_000
  # Triage Workbench reads are scan-shaped but sit on a dashboard render path:
  # the same fail-fast budget, so a slow Salix degrades one card instead of
  # hanging the page.
  @triage_read_timeout 3_000
  # Readiness is deployment-wide, but a dashboard read must never create an
  # unbounded per-Pod fan-out. Above this ceiling we return `:unknown` without
  # sampling: a partial sample cannot prove readiness.
  @triage_status_max_nodes 16
  # Candidate capability probes run concurrently only after the cardinality
  # ceiling is known to hold. The task deadline sits just outside the erpc
  # deadline so all 16 probes still share one bounded wall-clock window.
  @triage_status_capability_probe_timeout 1_000
  @triage_status_probe_task_timeout 1_100
  @triage_status_directory_timeout 1_000
  @kubernetes_dns_strategy :"Elixir.Cluster.Strategy.Kubernetes.DNS"
  @slack_history_read_timeout 30_000

  @tenants Salix.Control.Tenants
  @groups Salix.Control.Groups
  @oauth_apps Salix.Control.OAuthApps
  @composio_settings Salix.Control.ComposioSettings
  @signal Salix.Control.Signal
  @composio Salix.Composio
  @plugins Salix.Control.Plugins
  @remote_mcp_oauth Salix.Control.RemoteMCPOAuth
  @oauth_bindings Salix.Control.OAuthBindings
  @oauth_flow SalixWeb.OAuthFlow
  @conversations SalixIM.Conversations
  @conversation_attachments SalixIM.ConversationAttachments
  @conversation_input SalixIM.ConversationInput
  @conversation_server SalixIM.ConversationServer
  @internal_provider SalixIM.Provider.Internal
  @provider_connects SalixIM.ProviderConnects
  @slack_history_reader SalixIM.SlackHistoryReader
  @triage_read_model SalixIM.Triage.ReadModel
  @ifc_admin SalixIM.IFC.Admin
  @meet SalixMeet
  @provider_http SalixIM.ProviderHTTP
  @capability_requests SalixAgent.CapabilityRequests
  @feishu_checks SalixIM.FeishuChecks
  @meeting_calendar_policy Salix.Bindings.MeetingCalendarPolicy
  @meeting_calendar_status Salix.Bindings.MeetingCalendarStatus
  @meeting_summary_replay Salix.Bindings.MeetingSummaryReplay
  @first_message_timeout_ms 25_000
  @agent SalixAgent
  @agent_actor SalixAgent.AgentActor
  @agent_billing SalixAgent.Billing
  @agent_control SalixAgent.Control
  @agent_runtime SalixAgent.Runtime
  @activity_surface SalixAgent.ActivitySurface
  @agent_workspace SalixAgent.Workspace
  @agent_templates SalixAgent.Templates
  @agent_defaults SalixAgent.AgentDefaults
  @external_worker_targets SalixStore.ExternalWorkerTargets
  @skill_catalog SalixAgent.SkillCatalog
  @env_control SalixEnv.Control
  @connector_tokens SalixEnv.ConnectorTokens
  @schedules SalixCluster.Schedules
  @task_schedules SalixCluster.TaskSchedules

  # ---- Control plane ----
  @impl true
  def create_tenant(attrs) do
    {tenant_id, attrs} = Map.pop(attrs, "tenant_id")
    call(@tenants, :create_preallocated, [attrs, tenant_id], hint: tenant_id)
  end

  @impl true
  def update_tenant(id, attrs), do: call(@tenants, :update, [id, attrs], hint: id)

  @impl true
  def get_tenant(id), do: call(@tenants, :get, [id], hint: id)

  @impl true
  def get_tenant_config(tenant_id, name, default),
    do: call(@tenants, :get_config, [tenant_id, name, default], hint: tenant_id)

  @impl true
  def update_tenant_config(tenant_id, name, value),
    do: call(@tenants, :update_config, [tenant_id, name, value], hint: tenant_id)

  @impl true
  def create_group_connector_token(group_id, tenant_id, attrs),
    do:
      call(@connector_tokens, :create_group_connector_token, [group_id, tenant_id, attrs],
        hint: tenant_id
      )

  @impl true
  def create_group(attrs) do
    {tenant, attrs} = pop_tenant(attrs)
    {group_id, attrs} = Map.pop(attrs, "group_id")
    call(@groups, :create_preallocated, [attrs, tenant, group_id], hint: tenant)
  end

  @impl true
  def update_group(group_id, tenant_id, attrs),
    do: call(@groups, :update, [group_id, attrs, tenant_id], hint: group_id)

  @impl true
  def get_group(group_id), do: call(@groups, :get, [group_id], hint: group_id)

  @impl true
  def create_group_conversation(group_id, attrs),
    do: call(@conversation_input, :create_group_conversation, [group_id, attrs], hint: group_id)

  @impl true
  def create_task_conversation(group_id, delegator_agent_id, worker_agent_id, attrs),
    do:
      call(
        @task_schedules,
        :create_task_conversation,
        [group_id, delegator_agent_id, worker_agent_id, attrs],
        hint: group_id
      )

  @impl true
  def get_group_conversation(group_id, conversation_id),
    do: call(@conversations, :get_group_conversation, [group_id, conversation_id], hint: group_id)

  @impl true
  def subscribe_group_conversation(group_id, conversation_id, subscriber),
    do:
      call(
        @conversation_server,
        :subscribe_group_conversation,
        [group_id, conversation_id, subscriber],
        hint: group_id
      )

  @impl true
  def get_group_conversation_with_messages(group_id, conversation_id, opts),
    do:
      call(
        @conversations,
        :get_group_conversation_with_messages,
        [group_id, conversation_id, opts],
        hint: group_id
      )

  @impl true
  def list_group_conversation_participants(group_id, conversation_id, opts),
    do:
      call(
        @conversations,
        :list_group_conversation_participants,
        [group_id, conversation_id, opts],
        hint: group_id
      )

  @impl true
  def update_group_conversation(group_id, conversation_id, attrs),
    do:
      call(@conversation_server, :update_group_conversation, [group_id, conversation_id, attrs],
        hint: group_id
      )

  @impl true
  def set_task_archived(group_id, conversation_id, action, version),
    do:
      call(@conversation_server, :set_task_archived, [group_id, conversation_id, action, version],
        hint: group_id
      )

  @impl true
  def accept_task_review(group_id, conversation_id, review_version),
    do:
      call(
        @conversation_server,
        :accept_task_review,
        [group_id, conversation_id, review_version],
        hint: group_id
      )

  @impl true
  def update_task_schedule(group_id, conversation_id, schedule),
    do:
      call(@task_schedules, :update_task_schedule, [group_id, conversation_id, schedule],
        hint: group_id
      )

  @impl true
  def list_group_conversations(group_id, opts),
    do: call(@conversations, :list_group_conversations, [group_id, opts], hint: group_id)

  @impl true
  def list_group_conversation_messages(group_id, conversation_id, opts),
    do:
      call(@conversations, :list_group_conversation_messages, [group_id, conversation_id, opts],
        hint: group_id
      )

  @impl true
  def get_group_conversation_attachment(group_id, conversation_id, message_id, index),
    do:
      call(@conversation_attachments, :fetch, [group_id, conversation_id, message_id, index],
        hint: group_id,
        timeout: @workspace_read_timeout
      )

  @impl true
  def group_conversation_delivery_status(group_id, conversation_id, opts),
    do:
      call(@conversations, :group_conversation_delivery_status, [group_id, conversation_id, opts],
        hint: group_id,
        timeout: @conversation_status_read_timeout
      )

  @impl true
  def get_conversation_participant_status(group_id, conversation_id, participant_id) do
    call(
      @internal_provider,
      :call,
      [
        %{group_id: group_id, agent_id: ""},
        "internal.get_conversation_participant_status",
        %{"conversation_id" => conversation_id, "participant_id" => participant_id}
      ],
      hint: group_id,
      timeout: @conversation_status_read_timeout
    )
  end

  @impl true
  def group_conversation_participant_statuses(group_id, conversation_id, participants),
    do:
      call(
        @conversations,
        :group_conversation_participant_statuses,
        [group_id, conversation_id, participants],
        hint: group_id,
        timeout: @conversation_status_read_timeout
      )

  @impl true
  def append_group_conversation_message(group_id, conversation_id, attrs),
    do:
      call(
        @conversation_server,
        :append_group_conversation_message,
        [
          group_id,
          conversation_id,
          attrs
        ],
        hint: group_id
      )

  @impl true
  def redeliver_group_conversation_agent_message(group_id, conversation_id, attrs),
    do:
      call(
        @conversation_server,
        :redeliver_group_conversation_agent_message,
        [group_id, conversation_id, attrs],
        hint: group_id
      )

  @impl true
  def ensure_group_conversation_provider_participant(group_id, conversation_id, attrs),
    do:
      call(
        @conversation_server,
        :ensure_group_conversation_provider_participant,
        [group_id, conversation_id, attrs],
        hint: group_id
      )

  @impl true
  def seed_group_conversation_transcript(group_id, conversation_id, attrs),
    do:
      call(
        @conversation_server,
        :seed_group_conversation_transcript,
        [
          group_id,
          conversation_id,
          attrs
        ],
        hint: group_id
      )

  @impl true
  def send_provider_participant_message(group_id, conversation_id, participant_id, attrs),
    do:
      call(
        @conversation_server,
        :send_provider_participant_message,
        [
          group_id,
          conversation_id,
          participant_id,
          attrs
        ],
        hint: group_id
      )

  @impl true
  def list_group_meetings(group_id),
    do: call(@meet, :list_group_meetings, [group_id], hint: group_id)

  # The remote read owns its own deadline and answers with a typed refusal when
  # it expires. This call must therefore outlive it, or the transport would turn
  # every slow-but-answered read into a generic `:timeout` and throw away the
  # diagnosis the freeze needs. See the deadline budget in
  # `BridgeForTeams.Meetings`.
  @meeting_source_erpc_headroom_ms 500

  @impl true
  def list_group_meetings_bounded(group_id, opts) do
    deadline_ms = Keyword.get(opts, :deadline_ms, 500)

    call(@meet, :list_group_meetings_bounded, [group_id, opts],
      hint: group_id,
      timeout: deadline_ms + @meeting_source_erpc_headroom_ms
    )
  end

  @impl true
  def replay_meeting_summary(group_id, meeting_id, opts) do
    call(@meeting_summary_replay, :run_existing, [group_id, meeting_id, opts],
      hint: group_id,
      timeout: 300_000
    )
  end

  @impl true
  def list_group_im_connects(group_id, provider \\ nil),
    do: call(@provider_connects, :list_group_im_connects, [group_id, provider], hint: group_id)

  @impl true
  def slack_manifest(app_name),
    do: call(@provider_http, :slack_manifest, [app_name])

  @impl true
  def create_slack_im_connect(tenant_id, group_id, attrs),
    do:
      call(@provider_connects, :create_slack_im_connect, [tenant_id, group_id, attrs],
        hint: group_id
      )

  @impl true
  def update_slack_im_connect(tenant_id, group_id, connect_id, attrs),
    do:
      call(@provider_connects, :update_slack_im_connect, [tenant_id, group_id, connect_id, attrs],
        hint: group_id
      )

  @impl true
  def create_feishu_im_connect(tenant_id, group_id, attrs),
    do:
      call(@provider_connects, :create_feishu_im_connect, [tenant_id, group_id, attrs],
        hint: group_id
      )

  @impl true
  def update_feishu_im_connect(tenant_id, group_id, connect_id, attrs),
    do:
      call(
        @provider_connects,
        :update_feishu_im_connect,
        [tenant_id, group_id, connect_id, attrs],
        hint: group_id
      )

  @impl true
  def feishu_callback_preflight(params),
    do: call(@feishu_checks, :callback_preflight, [params])

  @impl true
  def feishu_callback_preflight_for_connect(params),
    do:
      call(@feishu_checks, :callback_preflight_for_connect, [params],
        hint: params["connect_id"] || params[:connect_id]
      )

  @impl true
  def feishu_bot_identity(params),
    do:
      call(@feishu_checks, :bot_identity, [params],
        hint: params["connect_id"] || params[:connect_id]
      )

  @impl true
  def meeting_calendar_policy(params),
    do:
      call(
        @meeting_calendar_policy,
        :get,
        [params["agent_id"] || params[:agent_id], params["connect_id"] || params[:connect_id]],
        hint: params["agent_id"] || params[:agent_id]
      )

  @impl true
  def meeting_preparation(params) do
    timeout =
      case params["action"] do
        "overview" -> 5_000
        "history" -> 15_000
        _ -> 60_000
      end

    call(
      Salix.Bindings.MeetingPreparationDashboard,
      :run,
      [params["tenant_id"], params["group_id"], params["action"], params["attrs"] || %{}],
      timeout: timeout,
      hint: params["group_id"]
    )
  end

  @impl true
  def meeting_calendar_policy_status(params),
    do:
      call(
        @meeting_calendar_policy,
        :status,
        [params["agent_id"] || params[:agent_id], params["connect_id"] || params[:connect_id]],
        hint: params["agent_id"] || params[:agent_id]
      )

  @impl true
  def meeting_calendar_status(params),
    do:
      call(
        @meeting_calendar_status,
        :get,
        [
          params["agent_id"] || params[:agent_id],
          params["connect_id"] || params[:connect_id],
          params["limit"] || params[:limit] || 20
        ],
        hint: params["agent_id"] || params[:agent_id]
      )

  @impl true
  def feishu_first_message(params),
    do:
      call(@feishu_checks, :first_message, [params],
        hint: params["connect_id"] || params[:connect_id],
        timeout: @first_message_timeout_ms
      )

  @impl true
  def disable_im_connect(tenant_id, group_id, connect_id),
    do:
      call(@provider_connects, :disable_im_connect, [tenant_id, group_id, connect_id],
        hint: group_id
      )

  @impl true
  def enable_im_connect(tenant_id, group_id, connect_id),
    do:
      call(@provider_connects, :enable_im_connect, [tenant_id, group_id, connect_id],
        hint: group_id
      )

  @impl true
  def delete_group_im_connects(tenant_id, group_id),
    do: call(@provider_connects, :delete_group_im_connects, [tenant_id, group_id], hint: group_id)

  @impl true
  def delete_im_connect(tenant_id, group_id, connect_id),
    do:
      call(@provider_connects, :delete_im_connect, [tenant_id, group_id, connect_id],
        hint: group_id
      )

  # ---- Slack Triage Workbench ----
  @impl true
  def triage_list_buckets(namespace, cursor, limit),
    do:
      call(@triage_read_model, :list_buckets, [namespace, cursor, limit],
        hint: namespace,
        timeout: @triage_read_timeout
      )

  @impl true
  def triage_get_bucket(namespace, bucket_key),
    do:
      call(@triage_read_model, :get_bucket, [namespace, bucket_key],
        hint: namespace,
        timeout: @triage_read_timeout
      )

  # The receipt prefix is global (no receipt carries a namespace), so this scan
  # takes no placement hint.
  @impl true
  def triage_list_receipts(cursor),
    do: call(@triage_read_model, :list_receipts_page, [cursor], timeout: @triage_read_timeout)

  @impl true
  def triage_recent_window(namespace, since_ms, opts),
    do:
      call(@triage_read_model, :recent_window, [namespace, since_ms, opts],
        hint: namespace,
        timeout: @triage_read_timeout
      )

  @impl true
  def triage_recent_processing(namespace, since_ms, opts),
    do:
      call(@triage_read_model, :recent_processing, [namespace, since_ms, opts],
        hint: namespace,
        timeout: @triage_read_timeout
      )

  @impl true
  def triage_product_activity(project_id, group_id, agent_id, opts),
    do:
      call(
        @triage_read_model,
        :product_activity,
        [project_id, group_id, agent_id, opts],
        hint: group_id,
        timeout: @triage_read_timeout
      )

  @impl true
  def triage_product_heatmap(project_id, group_id, agent_id),
    do:
      call(@triage_read_model, :product_heatmap, [project_id, group_id, agent_id],
        hint: group_id,
        timeout: @triage_read_timeout
      )

  @impl true
  def triage_processing_detail(group_id, receipt_ref),
    do:
      call(@triage_read_model, :processing_detail, [group_id, receipt_ref],
        hint: group_id,
        timeout: @triage_read_timeout
      )

  @impl true
  def triage_source_presentation(group_id, receipt_refs),
    do:
      call(SalixIM.Triage.SourcePresentation, :read, [group_id, receipt_refs],
        hint: group_id,
        timeout: 8_000
      )

  @impl true
  def triage_model_debug(project, group, agent, kind, id),
    do:
      call(
        @triage_read_model,
        :model_debug,
        [SalixStore.TriageKeys.default_namespace(), project, group, agent, kind, id],
        hint: group,
        timeout: @triage_read_timeout
      )

  @impl true
  def triage_delegation_task(project_id, group_id, agent_id, obligation_id, index),
    do:
      call(
        @triage_read_model,
        :delegation_task,
        [
          SalixStore.TriageKeys.default_namespace(),
          project_id,
          group_id,
          agent_id,
          obligation_id,
          index
        ],
        hint: group_id,
        timeout: @triage_read_timeout
      )

  @impl true
  def triage_knowledge_context(project_id, group_id, agent_id, opts),
    do:
      call(
        @triage_read_model,
        :knowledge_context,
        [project_id, group_id, agent_id, opts],
        hint: group_id,
        timeout: @triage_read_timeout
      )

  # Ring status is a hard-bounded deployment-wide aggregation. A visible-node
  # list is not, by itself, proof that discovery is complete. Kubernetes DNS is
  # the existing release-owned live-member directory; explicit test/embedded
  # directories and a non-distributed standalone node are the other complete
  # cases. Missing/failed/old-shape nodes therefore produce `:unknown`, never a
  # sampled `:ready` claim. The read model's own 1000ms GenServer.call budget
  # sits well inside this dashboard deadline.
  @impl true
  def triage_ring_status(refs) do
    {nodes, discovery_complete?, membership_fence} = triage_status_nodes()

    observed_call(fn ->
      results =
        if length(nodes) <= @triage_status_max_nodes do
          nodes
          |> Task.async_stream(
            &triage_ring_status_on_node(&1, refs),
            ordered: false,
            max_concurrency: @triage_status_max_nodes,
            timeout: @triage_read_timeout + 5_000,
            on_timeout: :kill_task
          )
          |> Enum.map(fn
            {:ok, result} -> result
            {:exit, _reason} -> {:error, :unavailable}
          end)
        else
          []
        end

      membership_stable? =
        discovery_complete? and triage_status_membership_stable?(membership_fence)

      aggregate_triage_ring_status(length(nodes), results,
        discovery_complete: discovery_complete? and membership_stable?
      )
    end)
  end

  @doc false
  def aggregate_triage_ring_status(expected_node_count, results, opts \\ [])

  def aggregate_triage_ring_status(expected_node_count, results, opts)
      when is_integer(expected_node_count) and expected_node_count >= 0 and is_list(results) and
             is_list(opts) do
    discovery_complete? = Keyword.get(opts, :discovery_complete, false) == true
    classified = Enum.map(results, &classify_triage_ring_status/1)
    current = for {:current, ready?, ring} <- classified, do: {ready?, ring}
    explicit_not_ready? = Enum.any?(current, fn {ready?, _ring} -> not ready? end)

    observation_complete? =
      expected_node_count in 1..@triage_status_max_nodes and
        length(results) == expected_node_count and length(current) == expected_node_count

    evaluation_readiness =
      cond do
        explicit_not_ready? -> :unavailable
        discovery_complete? and observation_complete? -> :ready
        true -> :unknown
      end

    {:ok,
     build_triage_ring_aggregate(
       current,
       evaluation_readiness,
       %{
         discovery_complete: discovery_complete?,
         visible_node_count: expected_node_count,
         observed_node_count: length(results),
         current_node_count: length(current),
         unavailable_node_count: Enum.count(classified, &match?({:unavailable, _reason}, &1)),
         old_shape_node_count: Enum.count(classified, &(&1 == :old_shape)),
         node_limit: @triage_status_max_nodes,
         candidate_limit_exceeded: expected_node_count > @triage_status_max_nodes,
         observation_complete: observation_complete?
       }
     )}
  end

  def aggregate_triage_ring_status(_expected_node_count, _results, _opts),
    do: {:error, :invalid_triage_ring_status}

  @impl true
  def triage_connect_posture(tenant_id, group_id),
    do:
      call(@triage_read_model, :connect_posture, [tenant_id, group_id],
        hint: group_id,
        timeout: @triage_read_timeout
      )

  @impl true
  def triage_list_slack_channels(tenant_id, group_id, connect_id, cursor, limit),
    do:
      call(
        @provider_connects,
        :list_slack_triage_channels,
        [tenant_id, group_id, connect_id, cursor, limit],
        hint: group_id,
        timeout: @triage_read_timeout
      )

  @impl true
  def ifc_overview(tenant_id, group_id),
    do:
      call(@ifc_admin, :overview, [tenant_id, group_id],
        hint: group_id,
        timeout: @triage_read_timeout
      )

  @impl true
  def ifc_put_scope_label(tenant_id, group_id, connect_id, scope_id, attrs),
    do:
      call(@ifc_admin, :put_scope_label, [tenant_id, group_id, connect_id, scope_id, attrs],
        hint: group_id
      )

  @impl true
  def ifc_delete_scope_label(tenant_id, group_id, connect_id, scope_id),
    do:
      call(@ifc_admin, :delete_scope_label, [tenant_id, group_id, connect_id, scope_id],
        hint: group_id
      )

  @impl true
  def ifc_put_tag_clearance(tenant_id, group_id, connect_id, tag, user_id),
    do:
      call(@ifc_admin, :put_tag_clearance, [tenant_id, group_id, connect_id, tag, user_id],
        hint: group_id
      )

  @impl true
  def ifc_delete_tag_clearance(tenant_id, group_id, connect_id, tag, principal_key),
    do:
      call(
        @ifc_admin,
        :delete_tag_clearance,
        [tenant_id, group_id, connect_id, tag, principal_key],
        hint: group_id
      )

  @impl true
  def ifc_put_placement_override(tenant_id, group_id, connect_id, user_id, placement),
    do:
      call(
        @ifc_admin,
        :put_placement_override,
        [tenant_id, group_id, connect_id, user_id, placement],
        hint: group_id
      )

  @impl true
  def slack_history_source_authority(request),
    do:
      call(@slack_history_reader, :source_authority, [request],
        hint: request[:group_id] || request["group_id"],
        timeout: @slack_history_read_timeout
      )

  @impl true
  def slack_history_read_page(request),
    do:
      call(@slack_history_reader, :read_page, [request],
        hint: request[:group_id] || request["group_id"],
        timeout: @slack_history_read_timeout
      )

  @impl true
  def ensure_triage_worker(group_id, router_id),
    do: call(Salix.Bindings.TriageWorker, :ensure, [group_id, router_id], hint: group_id)

  @impl true
  def triage_worker_binding(group_id),
    do:
      call(Salix.Bindings.TriageWorker, :get, [group_id],
        hint: group_id,
        timeout: @triage_read_timeout
      )

  @impl true
  def triage_worker_configuration(group_id, opts),
    do:
      call(Salix.Bindings.TriageWorker, :view, [group_id, opts],
        hint: group_id,
        timeout: @triage_read_timeout
      )

  @impl true
  def configure_triage_worker(group_id, router_id, worker_id, revision, audit),
    do:
      call(
        Salix.Bindings.TriageWorker,
        :configure,
        [group_id, router_id, worker_id, revision, audit],
        hint: group_id
      )

  @impl true
  def triage_provision(tenant_id, group_id, connect_id, approved_channel_id),
    do:
      call(
        @provider_connects,
        :provision_slack_triage_authority,
        [tenant_id, group_id, connect_id, approved_channel_id],
        hint: group_id
      )

  @impl true
  def triage_set_enabled(tenant_id, group_id, connect_id, enabled?),
    do:
      call(
        @provider_connects,
        :set_slack_triage_enabled,
        [tenant_id, group_id, connect_id, enabled?],
        hint: group_id
      )

  @impl true
  def triage_set_channel_enabled(tenant_id, group_id, connect_id, channel_id, enabled?),
    do:
      call(
        @provider_connects,
        :set_slack_triage_channel_enabled,
        [tenant_id, group_id, connect_id, channel_id, enabled?],
        hint: group_id
      )

  @impl true
  def list_oauth_provider_apps(tenant_id),
    do: call(@oauth_apps, :list, [tenant_id], hint: tenant_id)

  @impl true
  def put_oauth_provider_app(tenant_id, provider, attrs),
    do: call(@oauth_apps, :put, [tenant_id, provider, attrs], hint: tenant_id)

  @impl true
  def delete_oauth_provider_app(tenant_id, provider),
    do: call(@oauth_apps, :delete, [tenant_id, provider], hint: tenant_id)

  @impl true
  def get_signal_number(tenant_id),
    do: call(@signal, :tenant_number, [tenant_id], hint: tenant_id)

  @impl true
  def put_signal_number(tenant_id, number),
    do: call(@signal, :put_tenant_number, [tenant_id, %{"number" => number}], hint: tenant_id)

  @impl true
  def get_group_signal(group_id, tenant_id),
    do: call(@signal, :status, [group_id, tenant_id], hint: group_id)

  @impl true
  def start_group_signal_claim(group_id, tenant_id, created_by),
    do: call(@signal, :start_claim, [group_id, tenant_id, created_by], hint: group_id)

  @impl true
  def remove_group_signal_binding(group_id, tenant_id, binding_id),
    do: call(@signal, :remove_binding, [group_id, tenant_id, binding_id], hint: group_id)

  @impl true
  def get_composio_settings(tenant_id),
    do: call(@composio_settings, :view, [tenant_id], hint: tenant_id)

  @impl true
  def put_composio_settings(tenant_id, attrs),
    do: call(@composio_settings, :put, [tenant_id, attrs], hint: tenant_id)

  @impl true
  def delete_composio_settings(tenant_id),
    do: call(@composio_settings, :delete, [tenant_id], hint: tenant_id)

  @impl true
  def list_composio_connected_accounts(tenant_id, group_id),
    do: call(@composio, :list_group_connected_accounts, [tenant_id, group_id], hint: group_id)

  @impl true
  def create_composio_connect_link(tenant_id, group_id, toolkit, attrs),
    do:
      call(@composio, :create_group_connect_link, [tenant_id, group_id, toolkit, attrs],
        hint: group_id
      )

  @impl true
  def delete_composio_connected_account(tenant_id, group_id, connected_account_id),
    do:
      call(
        @composio,
        :delete_group_connected_account,
        [tenant_id, group_id, connected_account_id],
        hint: group_id
      )

  @impl true
  def list_tenant_plugin_definitions(tenant_id),
    do: call(@plugins, :list_tenant_definitions, [tenant_id], hint: tenant_id)

  @impl true
  def create_tenant_plugin_definition(tenant_id, attrs),
    do: call(@plugins, :create_tenant_definition, [tenant_id, attrs], hint: tenant_id)

  @impl true
  def update_tenant_plugin_definition(tenant_id, plugin_id, attrs),
    do: call(@plugins, :update_tenant_definition, [tenant_id, plugin_id, attrs], hint: tenant_id)

  @impl true
  def list_group_plugin_definitions(tenant_id, group_id),
    do: call(@plugins, :list_definitions, [tenant_id, group_id], hint: group_id)

  @impl true
  def list_group_plugin_enablements(tenant_id, group_id),
    do: call(@plugins, :list_group_enablements, [tenant_id, group_id], hint: group_id)

  @impl true
  def group_plugin_runtime_projection(tenant_id, group_id),
    do:
      call(@plugins, :runtime_projection, [%{"tenant_id" => tenant_id, "group_id" => group_id}],
        hint: group_id
      )

  @impl true
  def create_group_plugin_definition(tenant_id, group_id, attrs),
    do: call(@plugins, :create_definition, [tenant_id, group_id, attrs], hint: group_id)

  @impl true
  def update_group_plugin_definition(tenant_id, group_id, plugin_id, attrs),
    do:
      call(@plugins, :update_group_definition, [tenant_id, group_id, plugin_id, attrs],
        hint: group_id
      )

  @impl true
  def enable_group_plugin(tenant_id, group_id, plugin_id),
    do: call(@plugins, :enable_group, [tenant_id, group_id, plugin_id], hint: group_id)

  @impl true
  def disable_group_plugin(tenant_id, group_id, plugin_id),
    do: call(@plugins, :disable_group, [tenant_id, group_id, plugin_id], hint: group_id)

  @impl true
  def prepare_group_plugin_setup(tenant_id, group_id, plugin_id, connection_id),
    do:
      call(@plugins, :prepare_group_setup, [tenant_id, group_id, plugin_id, connection_id],
        hint: group_id
      )

  @impl true
  def start_remote_mcp_authorization(tenant_id, group_id, binding_id, params),
    do:
      call(@remote_mcp_oauth, :start_authorization, [tenant_id, group_id, binding_id, params],
        hint: group_id
      )

  @impl true
  def disconnect_remote_mcp_authorization(tenant_id, group_id, binding_id),
    do: call(@remote_mcp_oauth, :disconnect, [tenant_id, group_id, binding_id], hint: group_id)

  @impl true
  def list_group_oauth_bindings(group_id),
    do: call(@oauth_bindings, :list, [group_id], hint: group_id)

  @impl true
  def update_group_oauth_binding(group_id, binding_id, attrs),
    do: call(@oauth_bindings, :update, [group_id, binding_id, attrs], hint: group_id)

  @impl true
  def start_oauth_authorization(tenant_id, group_id, provider, params),
    do:
      call(@oauth_flow, :start_authorization, [tenant_id, group_id, provider, params],
        hint: group_id
      )

  @impl true
  def delete_group_oauth_binding(tenant_id, group_id, binding_id),
    do: call(@oauth_flow, :delete_binding, [tenant_id, group_id, binding_id], hint: group_id)

  @impl true
  def put_feishu_tenant_app(tenant_id, attrs),
    do: call(@tenants, :put_feishu_tenant_app, [tenant_id, attrs], hint: tenant_id)

  @impl true
  def delete_feishu_tenant_app(tenant_id),
    do: call(@tenants, :delete_feishu_tenant_app, [tenant_id], hint: tenant_id)

  @impl true
  def get_feishu_tenant_app(tenant_id),
    do: call(@tenants, :get_feishu_tenant_app, [tenant_id], hint: tenant_id)

  @impl true
  def subscription_operation(tenant, action, args)
      when action in [
             :list,
             :list_bindings,
             :create,
             :update,
             :delete,
             :quota,
             :reset_quota,
             :begin_oauth,
             :complete_oauth
           ] do
    call(SalixAgent.AccountPool, action, [tenant | args], hint: tenant, timeout: 125_000)
  end

  @impl true
  def device_managed_auth_operation(tenant, group, device, runtime, action, attrs)
      when action in [:read, :bind, :unbind] and is_map(attrs) do
    call(
      SalixWeb.SubscriptionRuntimeAuth,
      :managed,
      [tenant, group, device, runtime, action, attrs],
      hint: tenant,
      timeout: 65_000
    )
  end

  @impl true
  def compute_managed_auth_operation(tenant, project, workload, action, attrs)
      when action in [:read, :bind, :unbind] and is_map(attrs) do
    call(
      SalixWeb.ComputeSubscriptionAuth,
      :managed,
      [tenant, project, workload, action, attrs],
      hint: tenant,
      timeout: 65_000
    )
  end

  @impl true
  def private_template_operation(tenant, action, args)
      when action in [:list, :save, :delete, :discover] do
    call(SalixAgent.SubscriptionTemplates, action, [tenant | args], hint: tenant, timeout: 20_000)
  end

  @impl true
  def list_templates(tenant_id) do
    case call(@agent_templates, :list_available, [tenant_id], hint: tenant_id) do
      {:ok, templates} -> templates
      error -> error
    end
  end

  @impl true
  def get_template(template_id, tenant_id),
    do: call(@agent_templates, :get_public, [template_id, tenant_id], hint: tenant_id)

  @impl true
  def effective_agent_defaults(tenant_id) do
    case call(@agent_defaults, :effective_role_defaults, [tenant_id], hint: tenant_id) do
      {:error, _} = error -> error
      defaults when is_map(defaults) -> {:ok, defaults}
    end
  end

  @impl true
  def create_owned_agent(attrs) do
    {tenant, attrs} = pop_tenant(attrs)
    {agent_id, attrs} = Map.pop(attrs, "agent_id")

    attrs =
      attrs |> Map.put("management_purpose", attrs["purpose"] || "") |> Map.delete("purpose")

    call(@agent_control, :create_owned_preallocated, [attrs, tenant, agent_id], hint: tenant)
  end

  @impl true
  def create_agent(attrs) do
    {tenant, attrs} = pop_tenant(attrs)
    {agent_id, attrs} = Map.pop(attrs, "agent_id")
    call(@agent_control, :create_preallocated, [attrs, tenant, agent_id], hint: tenant)
  end

  @impl true
  def page_group_agents(tenant_id, group_id, opts),
    do:
      call(@agent_control, :page_agents, [tenant_id, group_id, opts],
        hint: tenant_id,
        timeout: 3_000
      )

  @impl true
  def archive_agent_configuration(agent_id, tenant_id),
    do: call(@agent_control, :delete, [agent_id, tenant_id], hint: tenant_id)

  @impl true
  def rebind_agent_configuration(agent_id, tenant_id, target, expected, invocation),
    do:
      call(
        @agent_control,
        :rebind_external_worker,
        [agent_id, tenant_id, target, expected, invocation],
        hint: tenant_id
      )

  @impl true
  def claim_agent_configuration(agent_id, tenant_id, archived_at),
    do:
      call(@agent_control, :claim_configuration, [agent_id, tenant_id, archived_at],
        hint: tenant_id
      )

  @impl true
  def configure_agent(agent_id, tenant_id, attrs),
    do: call(@agent_control, :configure, [agent_id, attrs, tenant_id], hint: tenant_id)

  @impl true
  def update_agent(agent_id, tenant_id, attrs),
    do: call(@agent_control, :update, [agent_id, attrs, tenant_id], hint: tenant_id)

  @impl true
  def get_agent(agent_id, tenant_id),
    do: call(@agent_control, :get_including_archived, [agent_id, tenant_id], hint: tenant_id)

  @impl true
  def get_agent_projection(agent_id, tenant_id),
    do: call(@agent_control, :get, [agent_id, tenant_id], hint: tenant_id)

  @impl true
  def page_external_worker_targets(
        tenant_id,
        owner_type,
        owner_id,
        group_id,
        provider,
        opts
      ) do
    scope = %{
      tenant_id: tenant_id,
      owner_type: owner_type,
      owner_id: owner_id,
      group_id: group_id,
      provider: provider
    }

    call(@external_worker_targets, :page, [scope, opts], hint: tenant_id)
  end

  @impl true
  def validate_external_worker_target(
        tenant_id,
        owner_type,
        owner_id,
        group_id,
        provider,
        workload_id,
        selection_fence
      ) do
    scope = %{
      tenant_id: tenant_id,
      owner_type: owner_type,
      owner_id: owner_id,
      group_id: group_id,
      provider: provider
    }

    call(
      @external_worker_targets,
      :validate,
      [scope, workload_id, selection_fence],
      hint: tenant_id
    )
  end

  @impl true
  def apply_external_worker_binding(agent_id, tenant_id, runtime_config),
    do:
      call(
        @agent_control,
        :apply_external_worker_binding,
        [agent_id, tenant_id, runtime_config],
        hint: tenant_id
      )

  defp pop_tenant(attrs) do
    {Map.get(attrs, "tenant_id"), Map.delete(attrs, "tenant_id")}
  end

  # ---- Agent runtime ----
  @impl true
  def deliver(agent_id, payload, opts),
    do: call(@agent, :deliver, [agent_id, payload, opts], hint: agent_id)

  @impl true
  def switch_router_session(agent_id, tenant_id, expected_session_id),
    do:
      call(
        @agent_actor,
        :switch_router_session,
        [agent_id, tenant_id, expected_session_id, []],
        hint: agent_id
      )

  @impl true
  def list_sessions(agent_id, opts),
    do: call(@agent_runtime, :list_sessions, [agent_id, opts], hint: agent_id)

  @impl true
  def get_session(agent_id, session_id, opts),
    do: call(@agent_runtime, :get_session, [agent_id, session_id, opts], hint: agent_id)

  @impl true
  def get_session_messages(agent_id, session_id),
    do: call(@agent_runtime, :get_session_messages, [agent_id, session_id], hint: agent_id)

  @impl true
  def list_project_knowledge_uses(agent_id, opts),
    do:
      call(@agent_runtime, :list_project_knowledge_uses, [agent_id, opts],
        hint: agent_id,
        timeout: @triage_read_timeout
      )

  @impl true
  def session_records(agent_id, session_id, opts),
    do: call(@agent_runtime, :session_records, [agent_id, session_id, opts], hint: agent_id)

  @impl true
  def session_trace(agent_id, session_id, opts),
    do: call(@agent_runtime, :session_trace, [agent_id, session_id, opts], hint: agent_id)

  @impl true
  def list_agent_activities(agent_id) do
    case call(@activity_surface, :list_agent, [agent_id], hint: agent_id) do
      activities when is_list(activities) -> {:ok, activities}
      {:error, _reason} = err -> err
      _other -> {:ok, []}
    end
  end

  @impl true
  def billing_history(agent_id, tenant_id, opts),
    do: call(@agent_billing, :list_history, [agent_id, opts, tenant_id], hint: agent_id)

  @impl true
  def list_agent_sites(agent_id),
    do:
      call(@agent_workspace, :list_sites, [agent_id],
        hint: agent_id,
        timeout: @workspace_read_timeout
      )

  @impl true
  def write_agent_file(agent_id, path, body),
    do: call(@agent_workspace, :write, [agent_id, path, body], hint: agent_id)

  @impl true
  def delete_agent_path(agent_id, path),
    do: call(@agent_workspace, :delete, [agent_id, path, [recursive: true]], hint: agent_id)

  @impl true
  def list_agent_skills(agent_id, tenant_id),
    do: call(@skill_catalog, :list, [agent_id, tenant_id], hint: agent_id)

  @impl true
  def create_agent_skill(agent_id, tenant_id, attrs),
    do: call(@skill_catalog, :create, [agent_id, tenant_id, attrs], hint: agent_id)

  @impl true
  def delete_agent_skill(agent_id, tenant_id, skill_id, actor),
    do: call(@skill_catalog, :delete, [agent_id, tenant_id, skill_id, actor], hint: agent_id)

  @impl true
  def read_agent_file(agent_id, path),
    do:
      call(@agent_workspace, :read, [agent_id, path],
        hint: agent_id,
        timeout: @workspace_read_timeout
      )

  @impl true
  def list_agent_files(agent_id, path),
    do:
      call(@agent_workspace, :list, [agent_id, path],
        hint: agent_id,
        timeout: @workspace_read_timeout
      )

  # ---- Schedules ----
  @impl true
  def get_schedule(schedule_id), do: call(@schedules, :get, [schedule_id], hint: schedule_id)

  @impl true
  def list_schedules_for_owners(agent_ids, group_id) when is_list(agent_ids),
    do: call(@schedules, :list_for_owners, [agent_ids, group_id])

  @impl true
  def delete_schedule(schedule_id),
    do: call(@schedules, :delete, [schedule_id], hint: schedule_id)

  @impl true
  def create_schedule(attrs) do
    with {:ok, id, attrs} <- pop_schedule_id(attrs) do
      call(@schedules, :create, [id, attrs], hint: id)
    end
  end

  @impl true
  def update_schedule(schedule_id, attrs),
    do: call(@schedules, :update, [schedule_id, attrs], hint: schedule_id)

  defp pop_schedule_id(attrs) do
    case Map.pop(attrs, "id") do
      {id, rest} when is_binary(id) and id != "" ->
        if SalixStore.Ids.valid_schedule_id?(id) do
          {:ok, id, rest}
        else
          {:error, :invalid_schedule}
        end

      {_blank, rest} ->
        {:ok, SalixStore.Ids.new_schedule_id(), rest}
    end
  end

  # ---- Env ----
  @impl true
  def get_env(device_id, group_id, tenant_id),
    do: call(@env_control, :get_environment, [device_id, group_id, tenant_id], hint: device_id)

  @impl true
  def list_group_envs(group_id, tenant_id),
    do: call(@env_control, :list_group_environments, [group_id, tenant_id], hint: group_id)

  @impl true
  def page_group_envs(group_id, tenant_id, opts),
    do:
      call(
        @env_control,
        :page_group_environments,
        [group_id, tenant_id, opts],
        hint: group_id
      )

  @impl true
  def disconnect_env(device_id, group_id, tenant_id),
    do: call(@env_control, :delete_environment, [device_id, group_id, tenant_id], hint: device_id)

  @impl true
  def delete_env(device_id, group_id, tenant_id, connector_token_hash),
    do:
      call(
        @env_control,
        :remove_environment,
        [device_id, group_id, tenant_id, connector_token_hash],
        hint: device_id
      )

  @impl true
  def runtime_auth(operation, attrs),
    do:
      call(@env_control, :runtime_auth, [operation, attrs],
        hint: attrs.device_id,
        timeout: @runtime_auth_timeout
      )

  @impl true
  def runtime_auth_read(device_id, device_runtime_id, group_id, tenant_id),
    do:
      call(
        @env_control,
        :runtime_auth_read,
        [device_id, device_runtime_id, group_id, tenant_id],
        hint: device_id,
        timeout: @runtime_auth_timeout
      )

  @impl true
  def runtime_auth_login_start(device_id, device_runtime_id, flow, group_id, tenant_id),
    do:
      call(
        @env_control,
        :runtime_auth_login_start,
        [device_id, device_runtime_id, flow, group_id, tenant_id],
        hint: device_id,
        timeout: @runtime_auth_timeout
      )

  @impl true
  def runtime_auth_login_cancel(
        device_id,
        device_runtime_id,
        attempt_id,
        group_id,
        tenant_id
      ),
      do:
        call(
          @env_control,
          :runtime_auth_login_cancel,
          [device_id, device_runtime_id, attempt_id, group_id, tenant_id],
          hint: device_id,
          timeout: @runtime_auth_timeout
        )

  @impl true
  def list_runtime_auth_requests(group_id, tenant_id, opts),
    do:
      call(
        @capability_requests,
        :list_runtime_auth_page,
        [group_id, tenant_id, opts],
        hint: group_id
      )

  @impl true
  def get_runtime_auth_request(group_id, request_id, tenant_id),
    do:
      call(
        @capability_requests,
        :get_runtime_auth,
        [group_id, request_id, tenant_id],
        hint: group_id
      )

  @impl true
  def complete_runtime_auth_request(group_id, request_id, attrs, tenant_id),
    do:
      call(
        @capability_requests,
        :complete_runtime_auth,
        [group_id, request_id, attrs, tenant_id],
        hint: group_id,
        timeout: @runtime_auth_timeout
      )

  @doc false
  def runtime_auth_timeout, do: @runtime_auth_timeout

  defp triage_status_nodes do
    case Application.get_env(:bridge_for_teams_core, :salix_nodes_override) do
      nodes when is_list(nodes) ->
        # An explicit directory names expected members, including members that
        # may currently be down. Omissions therefore stay observable.
        {nodes, complete?} = bounded_triage_status_nodes(nodes, true, fn _node -> :salix end)
        {nodes, complete?, :static_directory}

      _unset ->
        topologies = Application.get_env(:salix_cluster, :topologies, [])
        observed = triage_status_candidates()

        {candidates, directory_complete?} =
          kubernetes_dns_triage_status_directory(
            topologies,
            observed,
            &:inet_res.getbyname(&1, :a)
          )

        {nodes, probes_complete?} =
          bounded_triage_status_nodes(
            candidates,
            directory_complete?,
            &triage_salix_capability/1
          )

        standalone_complete? = not Node.alive?() and nodes == [Node.self()]

        membership_fence =
          if directory_complete?,
            do: {:kubernetes_dns, topologies, observed, candidates},
            else: :incomplete_directory

        {nodes, probes_complete? and (directory_complete? or standalone_complete?),
         if(standalone_complete?, do: :static_directory, else: membership_fence)}
    end
  end

  defp triage_status_membership_stable?(
         {:kubernetes_dns, topologies, initial_observed, initial_candidates}
       ) do
    kubernetes_dns_triage_status_stable?(
      topologies,
      initial_observed,
      initial_candidates,
      &triage_status_candidates/0,
      &:inet_res.getbyname(&1, :a)
    )
  end

  defp triage_status_membership_stable?(:static_directory), do: true
  defp triage_status_membership_stable?(:incomplete_directory), do: false

  @doc false
  def kubernetes_dns_triage_status_directory(topologies, observed_nodes, resolver)
      when is_list(topologies) and is_list(observed_nodes) and is_function(resolver, 1) do
    observed_nodes = observed_nodes |> Enum.filter(&is_atom/1) |> Enum.uniq() |> Enum.sort()

    with {:ok, service, application_name} <- kubernetes_dns_directory_config(topologies),
         {:ok, {:hostent, _fqdn, _aliases, :inet, _address_bytes, addresses}}
         when is_list(addresses) <- bounded_triage_directory_lookup(resolver, service),
         true <-
           addresses != [] and
             length(Enum.take(addresses, @triage_status_max_nodes + 1)) <=
               @triage_status_max_nodes,
         {:ok, directory_nodes} <- kubernetes_dns_nodes(addresses, application_name) do
      nodes = Enum.sort(Enum.uniq(directory_nodes ++ observed_nodes))
      {nodes, Enum.all?(observed_nodes, &(&1 in directory_nodes))}
    else
      _lookup_missing_invalid_or_over_limit -> {observed_nodes, false}
    end
  catch
    _kind, _reason -> {observed_nodes, false}
  end

  def kubernetes_dns_triage_status_directory(_topologies, observed_nodes, _resolver)
      when is_list(observed_nodes),
      do: {observed_nodes |> Enum.filter(&is_atom/1) |> Enum.uniq() |> Enum.sort(), false}

  def kubernetes_dns_triage_status_directory(_topologies, _observed_nodes, _resolver),
    do: {[], false}

  @doc false
  # modeled: TriageEvaluatorReadiness.tla membershipStable / DriftMembership
  def kubernetes_dns_triage_status_stable?(
        topologies,
        initial_observed,
        initial_candidates,
        observed_provider,
        resolver
      )
      when is_list(topologies) and is_list(initial_observed) and
             is_list(initial_candidates) and is_function(observed_provider, 0) and
             is_function(resolver, 1) do
    initial_observed = normalize_triage_status_nodes(initial_observed)
    initial_candidates = normalize_triage_status_nodes(initial_candidates)
    final_observed_before = normalize_triage_status_nodes(observed_provider.())

    {final_candidates, final_complete?} =
      kubernetes_dns_triage_status_directory(
        topologies,
        final_observed_before,
        resolver
      )

    final_observed_after = normalize_triage_status_nodes(observed_provider.())

    final_complete? and initial_observed == final_observed_before and
      final_observed_before == final_observed_after and
      initial_candidates == normalize_triage_status_nodes(final_candidates)
  catch
    _kind, _reason -> false
  end

  def kubernetes_dns_triage_status_stable?(
        _topologies,
        _initial_observed,
        _initial_candidates,
        _observed_provider,
        _resolver
      ),
      do: false

  defp normalize_triage_status_nodes(nodes) when is_list(nodes),
    do: nodes |> Enum.filter(&is_atom/1) |> Enum.uniq() |> Enum.sort()

  defp normalize_triage_status_nodes(_nodes), do: []

  defp kubernetes_dns_directory_config(topologies) do
    Enum.find_value(topologies, {:error, :kubernetes_dns_directory_unavailable}, fn
      {_name, topology} when is_list(topology) ->
        config = Keyword.get(topology, :config, [])

        if Keyword.get(topology, :strategy) == @kubernetes_dns_strategy and is_list(config) do
          service = Keyword.get(config, :service)
          application_name = Keyword.get(config, :application_name)

          if is_binary(service) and service != "" and is_binary(application_name) and
               application_name != "",
             do: {:ok, service, application_name},
             else: false
        else
          false
        end

      _invalid ->
        false
    end)
  end

  defp bounded_triage_directory_lookup(resolver, service) do
    [service]
    |> Task.async_stream(
      fn service -> resolver.(to_charlist(service)) end,
      ordered: true,
      max_concurrency: 1,
      timeout: @triage_status_directory_timeout,
      on_timeout: :kill_task
    )
    |> Enum.at(0)
    |> case do
      {:ok, result} -> result
      _failed_or_timed_out -> {:error, :directory_unavailable}
    end
  end

  defp kubernetes_dns_nodes(addresses, application_name) do
    nodes =
      Enum.map(addresses, fn address ->
        with address when is_list(address) <- :inet_parse.ntoa(address) do
          # libcluster's Kubernetes DNS strategy has already materialized node
          # names while connecting the same bounded directory. Readiness must
          # not create a second, cumulatively unbounded source of atoms as Pod
          # IPs churn; an as-yet unknown name simply keeps readiness unknown.
          String.to_existing_atom("#{application_name}@#{address}")
        end
      end)

    if Enum.all?(nodes, &is_atom/1), do: {:ok, nodes}, else: {:error, :invalid_dns_address}
  rescue
    _invalid_address -> {:error, :invalid_dns_address}
  end

  @doc false
  def bounded_triage_status_nodes(candidates, discovery_complete?, probe)
      when is_list(candidates) and is_boolean(discovery_complete?) and is_function(probe, 1) do
    # Take one sentinel beyond the ceiling before sorting, de-duplicating, or
    # invoking a capability probe. Even an unexpectedly huge configured list
    # therefore causes at most 17 candidate reads and zero network calls.
    bounded_candidates = Enum.take(candidates, @triage_status_max_nodes + 1)

    cond do
      length(bounded_candidates) > @triage_status_max_nodes ->
        # modeled: TriageEvaluatorReadiness.tla DiscoverIncomplete
        {bounded_candidates, false}

      not Enum.all?(bounded_candidates, &is_atom/1) ->
        {[], false}

      true ->
        {salix_nodes, probes_complete?} =
          bounded_candidates
          |> Enum.uniq()
          |> Enum.sort()
          |> Task.async_stream(
            fn candidate -> {candidate, probe.(candidate)} end,
            ordered: false,
            max_concurrency: @triage_status_max_nodes,
            timeout: @triage_status_probe_task_timeout,
            on_timeout: :kill_task
          )
          |> Enum.reduce({[], true}, fn
            {:ok, {candidate, :salix}}, {nodes, complete?} ->
              {[candidate | nodes], complete?}

            {:ok, {_candidate, :not_salix}}, {nodes, _complete?} ->
              {nodes, false}

            _unavailable_timeout_or_invalid_probe, {nodes, _complete?} ->
              {nodes, false}
          end)

        {Enum.sort(salix_nodes), discovery_complete? and probes_complete?}
    end
  end

  def bounded_triage_status_nodes(_candidates, _discovery_complete?, _probe), do: {[], false}

  defp triage_status_candidates do
    local =
      if Enum.any?(Application.started_applications(), fn {app, _description, _version} ->
           app == :salix_web
         end),
         do: [Node.self()],
         else: []

    local ++ Node.list(:visible)
  end

  defp triage_salix_capability(candidate) do
    case :erpc.call(
           candidate,
           :application,
           :get_application,
           [Salix.Control],
           @triage_status_capability_probe_timeout
         ) do
      {:ok, :salix_web} -> :salix
      {:ok, _other_app} -> :not_salix
      :undefined -> :not_salix
      _unavailable_or_invalid -> :unavailable
    end
  catch
    _kind, _reason -> :unavailable
  end

  defp triage_ring_status_on_node(target_node, refs) do
    context = SystemsObservability.Context.inject()
    remote_args = [context, @triage_read_model, :ring_status, [refs]]

    if target_node == node() do
      local_call(__MODULE__, :receive_call, remote_args, @triage_read_timeout)
    else
      remote_call(
        target_node,
        @triage_read_model,
        :ring_status,
        [refs],
        remote_args,
        @triage_read_timeout
      )
    end
  catch
    :error, {:erpc, :noconnection} -> {:error, :unavailable}
    :error, {:erpc, :timeout} -> {:error, :timeout}
    kind, reason -> {:error, {kind, reason}}
  end

  defp classify_triage_ring_status(
         {:ok,
          %{
            running: running,
            runtime: %{
              running: runtime_running,
              evaluation_ready: evaluation_ready,
              active_evaluations: active_evaluations,
              open_buckets: open_buckets,
              scheduled_buckets: scheduled_buckets,
              observed_at_ms: observed_at_ms
            },
            recovery: %{
              running: recovery_running,
              pending_receipts: pending_receipts
            }
          } = ring}
       )
       when is_boolean(running) and is_boolean(runtime_running) and
              is_boolean(evaluation_ready) and is_boolean(recovery_running) and
              is_integer(active_evaluations) and active_evaluations >= 0 and
              is_integer(open_buckets) and open_buckets >= 0 and
              is_integer(scheduled_buckets) and scheduled_buckets >= 0 and
              is_integer(observed_at_ms) and observed_at_ms >= 0 and
              is_integer(pending_receipts) and pending_receipts >= 0,
       do: {:current, evaluation_ready, ring}

  defp classify_triage_ring_status({:ok, _old_or_invalid_shape}), do: :old_shape
  defp classify_triage_ring_status({:error, reason}), do: {:unavailable, reason}
  defp classify_triage_ring_status(_unexpected), do: :old_shape

  defp build_triage_ring_aggregate(current, readiness, diagnostics) do
    complete? = diagnostics.observation_complete
    rings = Enum.map(current, &elem(&1, 1))

    %{
      running: complete_value(complete?, Enum.map(rings, & &1.running), &Enum.all?/1),
      evaluation_readiness: readiness,
      diagnostics: diagnostics,
      runtime: %{
        running: complete_value(complete?, Enum.map(rings, & &1.runtime.running), &Enum.all?/1),
        mode: common_current_value(rings, &Map.get(&1.runtime, :mode)),
        namespace: common_current_value(rings, &Map.get(&1.runtime, :namespace)),
        evaluation_ready: readiness_boolean(readiness),
        evaluation_readiness: readiness,
        active_evaluations:
          complete_value(
            complete?,
            Enum.map(rings, & &1.runtime.active_evaluations),
            &Enum.sum/1
          ),
        open_buckets:
          complete_value(complete?, Enum.map(rings, & &1.runtime.open_buckets), &Enum.sum/1),
        scheduled_buckets:
          complete_value(
            complete?,
            Enum.map(rings, & &1.runtime.scheduled_buckets),
            &Enum.sum/1
          ),
        observed_at_ms: max_current_value(rings, & &1.runtime.observed_at_ms)
      },
      recovery: %{
        running: complete_value(complete?, Enum.map(rings, & &1.recovery.running), &Enum.all?/1),
        phase: common_current_value(rings, &Map.get(&1.recovery, :phase)),
        cursor: nil,
        holder: nil,
        lease_held:
          complete_value(
            complete?,
            Enum.map(rings, &Map.get(&1.recovery, :lease_held, false)),
            &Enum.any?/1
          ),
        page_limit: common_current_value(rings, &Map.get(&1.recovery, :page_limit)),
        batch_limit: common_current_value(rings, &Map.get(&1.recovery, :batch_limit)),
        backoff_ms: common_current_value(rings, &Map.get(&1.recovery, :backoff_ms)),
        pending_receipts:
          complete_value(
            complete?,
            Enum.map(rings, & &1.recovery.pending_receipts),
            &Enum.sum/1
          )
      }
    }
  end

  defp complete_value(true, [_first | _rest] = values, aggregate), do: aggregate.(values)
  defp complete_value(_complete?, _values, _aggregate), do: nil

  defp common_current_value([], _getter), do: nil

  defp common_current_value(rings, getter) do
    case rings |> Enum.map(getter) |> Enum.uniq() do
      [value] -> value
      _different -> :mixed
    end
  end

  defp max_current_value([], _getter), do: nil
  defp max_current_value(rings, getter), do: rings |> Enum.map(getter) |> Enum.max()

  defp readiness_boolean(:ready), do: true
  defp readiness_boolean(:unavailable), do: false
  defp readiness_boolean(:unknown), do: nil

  @doc """
  Run an `:erpc.call` to a live salix node with the salix error taxonomy and the
  `timeout + 5_000` budget.

  Picks a node via `BridgeForTeams.Salix.Nodes.pick/1`; an optional `:hint` in
  `opts` makes the placement sticky (cache locality). When no salix node is
  reachable, returns `{:error, :unavailable}` without attempting the call.
  """
  @spec call(module(), atom(), [term()], timeout() | keyword()) ::
          {:ok, term()} | {:error, term()}
  def call(mod, fun, args, timeout_or_opts \\ @default_timeout)

  def call(mod, fun, args, opts) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    hint = Keyword.get(opts, :hint)
    observed_call(fn -> do_call(mod, fun, args, timeout, hint) end)
  end

  def call(mod, fun, args, timeout) do
    observed_call(fn -> do_call(mod, fun, args, timeout, nil) end)
  end

  @doc false
  def receive_call(serialized_context, module, function, arguments)
      when is_atom(module) and is_atom(function) and is_list(arguments) do
    context = SystemsObservability.Context.extract(serialized_context)

    SystemsObservability.Context.run(context, fn ->
      SystemsObservability.Trace.with_span(
        :bft_salix,
        %{component: "salix_agent", surface: context.surface, operation: "erpc.receive"},
        fn -> apply(module, function, arguments) end,
        kind: :server
      )
    end)
  end

  defp observed_call(fun) do
    SystemsObservability.Context.with_surface("bft", fn ->
      SystemsObservability.Trace.with_span(
        :bft_salix,
        %{component: "bridge_for_teams", surface: "bft", operation: "erpc.call"},
        fn -> observe_result(fun) end,
        kind: :client
      )
    end)
  end

  defp observe_result(fun) do
    started = System.monotonic_time()
    result = fun.()

    BridgeForTeams.Telemetry.emit_operation(
      :salix_erpc,
      outcome(result),
      System.monotonic_time() - started
    )

    result
  end

  defp outcome({:error, :timeout}), do: :timeout
  defp outcome({:error, :unavailable}), do: :unavailable
  defp outcome({:error, _reason}), do: :error
  defp outcome(_result), do: :ok

  defp do_call(mod, fun, args, timeout, hint) do
    remote_args = [SystemsObservability.Context.inject(), mod, fun, args]

    case Nodes.pick(hint) do
      {:ok, node} when node == node() ->
        local_call(__MODULE__, :receive_call, remote_args, timeout)

      {:ok, node} ->
        remote_call(node, mod, fun, args, remote_args, timeout)

      {:error, :unavailable} = err ->
        err
    end
  catch
    :error, {:erpc, :noconnection} -> {:error, :unavailable}
    :error, {:erpc, :timeout} -> {:error, :timeout}
    kind, reason -> {:error, {kind, reason}}
  end

  defp remote_call(node, mod, fun, args, remote_args, timeout) do
    :erpc.call(node, __MODULE__, :receive_call, remote_args, timeout + 5_000)
  catch
    :error,
    {:exception, :undef, [{__MODULE__, :receive_call, ^remote_args, _location} | _stack]} ->
      :erpc.call(node, mod, fun, args, timeout + 5_000)
  end

  defp local_call(mod, fun, args, timeout) do
    caller = self()
    ref = make_ref()
    callers = [caller | List.wrap(Process.get(:"$callers"))] |> Enum.uniq()

    coordinator =
      spawn(fn ->
        local_call_coordinator(caller, ref, mod, fun, args, callers)
      end)

    monitor_ref = Process.monitor(coordinator)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^coordinator, reason} ->
        {:error, {:exit, reason}}
    after
      timeout ->
        cancel_local_call(coordinator, monitor_ref, ref)
        flush_local_result(ref)
        {:error, :timeout}
    end
  end

  # The coordinator is isolated from the caller but monitors it, while the
  # target is linked to the trapping coordinator. This preserves erpc's caller
  # lifetime cancellation without letting an untrappable target exit (for
  # example, :kill) take down a Phoenix/LiveView caller.
  defp local_call_coordinator(caller, ref, mod, fun, args, callers) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)
    coordinator = self()

    {target, target_monitor} =
      :erlang.spawn_opt(
        fn ->
          Process.put(:"$callers", callers)

          result =
            try do
              apply(mod, fun, args)
            catch
              kind, reason -> {:error, {kind, reason}}
            end

          send(coordinator, {ref, result})
        end,
        [:link, :monitor]
      )

    receive do
      {^ref, result} ->
        send(caller, {ref, result})

      {:DOWN, ^target_monitor, :process, ^target, reason} ->
        send(caller, {ref, {:error, {:exit, reason}}})

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        stop_local_target(target, target_monitor)

      {:cancel, ^ref} ->
        stop_local_target(target, target_monitor)
    end
  end

  defp cancel_local_call(coordinator, monitor_ref, ref) do
    send(coordinator, {:cancel, ref})

    receive do
      {:DOWN, ^monitor_ref, :process, ^coordinator, _reason} ->
        :ok
    after
      1_000 ->
        Process.exit(coordinator, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^coordinator, _reason} -> :ok
        end
    end
  end

  defp stop_local_target(target, target_monitor) do
    Process.exit(target, :kill)

    receive do
      {:DOWN, ^target_monitor, :process, ^target, _reason} -> :ok
    end
  end

  defp flush_local_result(ref) do
    receive do
      {^ref, _result} -> :ok
    after
      0 -> :ok
    end
  end
end
