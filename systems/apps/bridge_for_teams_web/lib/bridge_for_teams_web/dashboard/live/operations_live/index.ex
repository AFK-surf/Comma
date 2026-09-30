defmodule BridgeForTeamsWeb.Dashboard.OperationsLive.Index do
  @moduledoc """
  Organization Operations page (`/orgs/:org/operations`).

  This is the BFT-wide observability entrypoint from the Operations RFC. The
  first implementation establishes the route, navigation, tab structure, and
  runner posture surface while reading the shared observability contract for
  persisted events, checks, runs, and audit data.
  """
  use BridgeForTeamsWeb.Dashboard, :live_view

  require Logger

  alias BridgeForTeams.{Agents, Environments, Memberships, Observability, Orgs, Projects}
  alias BridgeForTeams.RunChecks.GateContract
  alias BridgeForTeamsWeb.MacMiniRelease

  @tabs [:overview, :delivery, :integrations, :runners, :events, :checks, :audit]
  @filter_keys ~w(actor_user_id action audit_log_id check_family check_result_id correlation_id cursor domain event_type external_run_id gate_status project_id reason_class request_id resource_id resource_type result run_record_id run_type runner_cursor runner_id runner_type severity source status subject_id subject_type surface since)
  @runner_refresh_interval_ms 5_000
  @observability_limit 25
  @runner_fleet_page_limit 25
  @subsystem_fact_limit 200
  @redacted_display "[REDACTED]"
  @event_detail_shared_evidence_keys ~w(reason_detail request_id resource_id resource_label resource_type result status truncated)
  @event_detail_evidence_keys_by_domain %{
    "audit" =>
      ~w(action actor_type impersonated metadata_present redacted_diff_present request_id resource_id resource_label resource_type result),
    "check" =>
      ~w(check_family duration_ms exit_code gate_count next_action request_id status surface),
    "conversation" =>
      ~w(agent_id callback_mode challenge_mode channel_id connect_id conversation_id delivery_state list_limit message_id message_ts operation_api provider reply_message_id request_id salix_agent_id source_message_id surface thread_ts user_id workspace_id),
    "device" =>
      ~w(component component_version exit_code failure_code heartbeat_age_seconds provision_request_id connector_run_id status),
    "integration" =>
      ~w(callback_mode challenge_mode channel_id connect_id delivery_state http_status provider provider_event_id provider_event_type reason_class settings_path status status_code surface thread_ts user_id workspace_id),
    "org" => ~w(aggregate aggregate_id attempts op reason_class reconcile_outbox_id),
    "project" =>
      ~w(action aggregate aggregate_id attempts op reason_class reconcile_outbox_id request_id result salix_agent_count status surface),
    "agent" =>
      ~w(agent_id aggregate aggregate_id app_server_startable attempts auth_ready connector_id connector_run_id device_id device_runtime_id op previous_status readiness_checked_at ready reason_class reconcile_outbox_id runtime_id runtime_status salix_agent_id version version_detected),
    "runner" =>
      ~w(command_hash command_sha256 component component_version duration_ms evidence_path_label exit_code failure_code heartbeat_age_seconds install_code_id next_action provision_request_id reason_class release_id request_id run_id connector_run_id stderr_bytes stdout_bytes truncated),
    "schedule" =>
      ~w(bft_agent_id node reason_class salix_agent_count salix_agent_id schedule_id scheduled_for scheduled_for_ms session_id_configured stage surface),
    "sso" => ~w(provider reason_class request_id stage status_code)
  }
  @run_detail_evidence_keys ~w(command_hash command_sha256 component component_version duration_ms evidence_path_label exit_code failure_code next_action provision_request_id request_id run_id connector_run_id stderr_bytes stdout_bytes truncated)
  @check_detail_evidence_keys ~w(check_family connect_ref gate_count project_ref status surface)
  @audit_detail_evidence_keys ~w(metadata_present metadata_size_bytes redacted_diff_present request_id)
  @integration_groups [
    %{key: "feishu", label: "Feishu", default_surface: "bot", settings_anchor: "feishu"},
    %{
      key: "slack",
      label: "Slack",
      default_surface: "slack_calendar",
      settings_anchor: "slack"
    },
    %{key: "sso", label: "SSO", default_surface: "sso", settings_anchor: "sso"},
    %{key: "oauth", label: "OAuth", default_surface: "oauth", settings_anchor: "oauth"},
    %{
      key: "models",
      label: "Models",
      default_surface: "models",
      settings_anchor: "model-provider"
    }
  ]

  @impl true
  def mount(%{"org" => slug} = _params, _session, socket) do
    user = socket.assigns.current_user
    orgs = Orgs.list_orgs_for_user(user.id)

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, org_role} <- Memberships.org_role(org.id, user.id),
         true <- can_view_operations?(org_role) do
      projects = Projects.list_projects_for_user(org.id, user.id)
      runners = Environments.list_mac_mini_provisioners(org.id)

      {:ok,
       socket
       |> assign(:page_title, gettext("Operations"))
       |> assign(:active_nav, :operations)
       |> assign(:current_org, org)
       |> assign(:current_org_role, org_role)
       |> assign(:can_manage_operations, can_manage_operations?(org_role))
       |> assign(:can_view_audit, can_view_audit?(org_role))
       |> assign(:orgs, orgs)
       |> assign(:projects, projects)
       |> assign(:project_names, project_names(projects))
       |> assign(:runners, runners)
       |> assign(:tabs, visible_tabs(org_role))
       |> assign(:filters, %{})
       |> assign(:filter_summary, [])
       |> assign(:runner_refresh_ref, nil)
       |> assign(:operations_loading?, true)
       |> assign(:operations_error, nil)
       |> assign_observability()
       |> assign_current_tab(socket.assigns.live_action)
       |> assign_breadcrumbs()
       |> schedule_runner_refresh()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Organization not found."))
         |> redirect(to: ~p"/orgs")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign_filters(params)
     |> assign_observability()
     |> assign_current_tab(socket.assigns.live_action)
     |> assign_breadcrumbs()}
  end

  @impl true
  def handle_info(:refresh_operations_runners, socket) do
    {:noreply,
     socket
     |> assign(:runner_refresh_ref, nil)
     |> assign_runners()
     |> schedule_runner_refresh()}
  end

  @impl true
  def handle_event("filter-observability", %{"filters" => raw_filters}, socket) do
    filters = normalize_form_filters(raw_filters, filter_keys_for_tab(socket.assigns.current_tab))

    {:noreply,
     push_patch(socket,
       to: operations_tab_path(socket.assigns.current_org, socket.assigns.current_tab, filters)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h1 class="text-lg font-semibold tracking-tight">{gettext("Operations")}</h1>
          <p class="mt-1 max-w-3xl text-sm text-neutral-500">
            {gettext(
              "BFT-wide delivery status, events, checks, runners, and audit for %{name}.",
              name: @current_org.name
            )}
          </p>
        </div>
        <div class="flex flex-wrap items-center justify-end gap-2">
          <.badge color={health_badge_color(@summary.health)}>
            {String.replace(@summary.health, "_", " ")}
          </.badge>
          <.badge color={if @summary.runner_count == 0, do: "neutral", else: "green"}>
            {ngettext("%{count} runner", "%{count} runners", @summary.runner_count)}
          </.badge>
          <.badge color="neutral">
            {ngettext("%{count} Agent Swarm", "%{count} Agent Swarms", @summary.project_count)}
          </.badge>
        </div>
      </div>

      <.tabs>
        <:tab
          :for={tab <- @tabs}
          label={tab_label(tab)}
          patch={operations_tab_path(@current_org, tab, nav_filters(@filters))}
          active={@current_tab == tab}
        />
      </.tabs>

      <div
        :if={@filter_summary != []}
        id="operations-active-filters"
        class="flex flex-wrap items-center gap-2 rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2 text-xs text-neutral-600"
      >
        <span class="font-medium text-neutral-700">{gettext("Filters")}</span>
        <.badge :for={filter <- @filter_summary} color="neutral">{filter}</.badge>
      </div>

      <div
        id="operations-loading"
        class={[
          "hidden items-center gap-2 rounded-md border border-brand-200 bg-brand-50 px-3 py-2 text-xs text-brand-800 phx-change-loading:flex phx-click-loading:flex phx-submit-loading:flex",
          @operations_loading? && "flex"
        ]}
        role="status"
        aria-live="polite"
      >
        <.icon name="arrow-path" class="h-4 w-4" />
        <span>{gettext("Refreshing Operations data...")}</span>
      </div>

      <div
        :if={@operations_error}
        id="operations-load-error"
        class="rounded-md border border-red-200 bg-red-50 px-3 py-3 text-sm text-red-900"
      >
        <div class="font-medium">{gettext("Operations data could not be loaded")}</div>
        <p class="mt-1 text-xs text-red-800">
          {gettext("The console is showing the last safe snapshot or unknown state. Retry, or narrow the filters if the problem continues.")}
        </p>
        <.link
          patch={operations_tab_path(@current_org, @current_tab, @filters)}
          class="mt-2 inline-flex text-xs font-medium text-red-900 underline underline-offset-2"
        >
          {gettext("Retry loading Operations")}
        </.link>
      </div>

      <div :if={@current_tab == :overview} id="operations-overview" class="space-y-4">
        <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
          <.summary_card
            label={gettext("Delivery")}
            value={@summary.project_count}
            detail={gettext("Agent Swarms visible to this admin")}
            patch={operations_tab_path(@current_org, :delivery, %{})}
          />
          <.summary_card
            label={gettext("Runners")}
            value={@summary.runner_count}
            detail={gettext("Runner fleet")}
            patch={operations_tab_path(@current_org, :runners, %{})}
          />
          <.summary_card
            label={gettext("Events")}
            value={@summary.event_count}
            detail={gettext("Recent operational facts")}
            patch={operations_tab_path(@current_org, :events, %{})}
          />
          <.summary_card
            label={gettext("Runs")}
            value={@summary.run_count}
            detail={gettext("Recent bounded execution attempts")}
            patch={operations_tab_path(@current_org, :runners, %{})}
          />
          <.summary_card
            label={gettext("Checks")}
            value={@summary.check_count}
            detail={gettext("Recent persisted check snapshots")}
            patch={operations_tab_path(@current_org, :checks, %{})}
          />
          <.summary_card
            label={gettext("Audit")}
            value={@summary.audit_count}
            detail={gettext("Recent privileged action records")}
            patch={operations_tab_path(@current_org, :audit, %{})}
          />
        </div>

        <.card>
          <:title>{gettext("Why this status?")}</:title>
          <div class="space-y-3 text-sm text-neutral-600">
            <p>
              {gettext(
                "Operations summarizes the latest persisted BFT signals for this organization. Empty data remains unknown; failed checks or error events require attention."
              )}
            </p>
            <ul id="operations-health-reasons" class="list-disc space-y-1 pl-5">
              <li :for={reason <- @summary.health_reasons}>{reason}</li>
            </ul>
            <ul class="list-disc space-y-1 pl-5 text-xs text-neutral-500">
              <li>{gettext("Delivery currently comes from BFT project membership state.")}</li>
              <li>{gettext("Runner freshness currently comes from runner heartbeat state.")}</li>
              <li>{gettext("Events, Checks, and Audit come from the shared observability contract.")}</li>
            </ul>
          </div>
        </.card>

        <.card>
          <:title>{gettext("Signal freshness")}</:title>
          <div id="operations-freshness" class="grid grid-cols-1 gap-3 md:grid-cols-2">
            <.link
              :for={row <- @freshness_rows}
              patch={row.patch}
              class="rounded-md border border-neutral-200 px-3 py-3 hover:border-brand-300 hover:bg-brand-50/20"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <div class="font-medium text-neutral-900">{row.label}</div>
                  <div class="mt-1 text-sm text-neutral-600">{row.detail}</div>
                  <div class="mt-1 text-xs text-neutral-500">
                    {row.observed_label}
                  </div>
                </div>
                <.status_pill status={row.status} label={row.status_label} />
              </div>
            </.link>
          </div>
        </.card>

        <.card :if={@events != []}>
          <:title>{gettext("Recent events")}</:title>
          <.event_table
            id="operations-overview-events"
            events={Enum.take(@events, 5)}
            org={@current_org}
            can_view_audit={@can_view_audit}
          />
        </.card>

        <.card :if={@runs != []}>
          <:title>{gettext("Recent runs")}</:title>
          <.run_table
            id="operations-overview-runs"
            runs={Enum.take(@runs, 5)}
            project_names={@project_names}
          />
        </.card>

        <.card :if={@checks != []}>
          <:title>{gettext("Recent checks")}</:title>
          <div class="space-y-3">
            <.check_table
              id="operations-overview-checks"
              checks={Enum.take(@checks, 5)}
              project_names={@project_names}
            />
            <.link
              patch={operations_tab_path(@current_org, :checks, %{})}
              class="text-sm font-medium text-brand-700 hover:underline"
            >
              {gettext("View all checks")}
            </.link>
          </div>
        </.card>

        <.card :if={@can_view_audit and @audit_logs != []}>
          <:title>{gettext("Recent audit actions")}</:title>
          <div class="space-y-3">
            <.audit_table id="operations-overview-audit" audit_logs={Enum.take(@audit_logs, 5)} />
            <.link
              patch={operations_tab_path(@current_org, :audit, %{})}
              class="text-sm font-medium text-brand-700 hover:underline"
            >
              {gettext("View audit")}
            </.link>
          </div>
        </.card>
      </div>

      <div :if={@current_tab == :delivery} id="operations-delivery">
        <.card>
          <:title>{gettext("Delivery")}</:title>
          <div
            :if={@projects != [] and !@delivery_facts_observed?}
            id="operations-delivery-unknown"
            class="mb-4 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800"
          >
            {gettext("No delivery diagnostics have been observed yet; project delivery is unknown, not healthy.")}
          </div>
          <.empty_state
            :if={@delivery_postures == []}
            icon="folder"
            title={delivery_empty_title(@filters)}
            description={delivery_empty_description(@filters)}
          />
          <.table :if={@delivery_postures != []} id="operations-projects" rows={@delivery_postures}>
            <:col :let={posture} label={gettext("Agent Swarm")}>
              <.link
                navigate={~p"/orgs/#{@current_org.slug}/projects/#{posture.project.id}"}
                class="font-medium text-brand-700 hover:underline"
              >
                {posture.project.name}
              </.link>
              <div class="text-xs text-neutral-500">{safe_text(posture.project.slug)}</div>
            </:col>
            <:col :let={posture} label={gettext("Agents")}>
              <div :if={not is_nil(posture.agent_count)}>{ngettext("%{count} agent", "%{count} agents", posture.agent_count)}</div>
              <div class="text-xs text-neutral-500">{posture.agent_detail}</div>
            </:col>
            <:col :let={posture} label={gettext("Tasks")}>
              {delivery_count_label(posture.conversation_count)}
            </:col>
            <:col :let={posture} label={gettext("Integrations")}>
              <.status_pill status={posture.integration_status} label={status_label(posture.integration_status)} />
              <div :if={posture.integration_reason} class="mt-1 text-xs text-neutral-500">
                {humanize_reason(posture.integration_reason)}
              </div>
              <.fact_summary
                :if={posture.integration_summary}
                summary={posture.integration_summary}
                meta={[posture.integration_event_type]}
              />
            </:col>
            <:col :let={posture} label={gettext("Devices")}>
              {delivery_count_label(posture.environment_count)}
            </:col>
            <:col :let={posture} label={gettext("Latest event")}>
              <.fact_summary summary={posture.latest_event_summary} meta={[posture.latest_event_type]} />
            </:col>
            <:col :let={posture} label={gettext("Health")}>
              <.status_pill status={posture.health} label={status_label(posture.health)} />
              <div :if={posture.health_reason} class="mt-1 text-xs text-neutral-500">
                {posture.health_reason}
              </div>
            </:col>
            <:col :let={posture} label={gettext("Links")}>
               <div class="flex flex-col gap-1">
                 <.link
                   patch={operations_tab_path(@current_org, :events, %{project_id: posture.project.id})}
                   class="text-brand-700 hover:underline"
                 >
                   {gettext("View events")}
                 </.link>
                 <.link
                   patch={operations_tab_path(@current_org, :checks, %{project_id: posture.project.id})}
                   class="text-brand-700 hover:underline"
                 >
                   {gettext("View checks")}
                 </.link>
                 <details
                   id={"operations-delivery-detail-#{posture.project.id}"}
                   class="mt-1 rounded-md border border-neutral-200 bg-neutral-50 px-2 py-1"
                 >
                   <summary class="cursor-pointer text-xs font-medium text-neutral-700 hover:text-brand-700">
                     {gettext("Delivery detail")}
                   </summary>
                   <div class="mt-2 flex flex-col gap-1 text-xs">
                     <.link
                       navigate={~p"/orgs/#{@current_org.slug}/projects/#{posture.project.id}"}
                       class="text-brand-700 hover:underline"
                     >
                       {gettext("Open project")}
                     </.link>
                     <.link
                       patch={operations_tab_path(@current_org, :events, %{project_id: posture.project.id})}
                       class="text-brand-700 hover:underline"
                     >
                       {gettext("Filtered events")}
                     </.link>
                     <.link
                       patch={
                         operations_tab_path(@current_org, :events, %{
                           project_id: posture.project.id,
                           domain: "device"
                         })
                       }
                       class="text-brand-700 hover:underline"
                     >
                       {gettext("Device events")}
                     </.link>
                     <.link
                       patch={operations_tab_path(@current_org, :checks, %{project_id: posture.project.id})}
                       class="text-brand-700 hover:underline"
                     >
                       {gettext("Filtered checks")}
                     </.link>
                   </div>
                 </details>
               </div>
             </:col>
           </.table>
        </.card>
      </div>

      <div :if={@current_tab == :integrations} id="operations-integrations">
        <.card>
          <:title>{gettext("Integrations")}</:title>
          <div class="space-y-4">
            <p class="text-sm text-neutral-600">
              {gettext(
                "Feishu, Slack, SSO, OAuth, and model provider posture from shared check and event records. Setup pages continue to own write controls."
              )}
            </p>
            <.table
              id="operations-integrations-table"
              rows={@integration_postures}
              row_id={&"operations-integration-#{&1.key}"}
            >
              <:col :let={posture} label={gettext("Provider")}>
                <div>
                  <div class="font-medium text-neutral-900">{posture.label}</div>
                  <div class="text-xs text-neutral-500">{posture.surface_label}</div>
                </div>
              </:col>
              <:col :let={posture} label={gettext("Status")}>
                <.status_pill status={posture.status} label={status_label(posture.status)} />
                <div :if={posture.reason_class} class="mt-1 text-xs text-neutral-500">
                  {humanize_reason(posture.reason_class)}
                </div>
              </:col>
            <:col :let={posture} label={gettext("Latest check")}>
                <.fact_summary
                  summary={posture.check_summary}
                  meta={[
                    posture.check_ran_at && format_datetime(posture.check_ran_at),
                    posture.invocation_id
                  ]}
                />
              </:col>
              <:col :let={posture} label={gettext("Latest diagnostic")}>
                <.fact_summary summary={posture.event_summary} meta={[posture.event_type]} />
              </:col>
              <:col :let={posture} label={gettext("Links")}>
                <div class="flex flex-col gap-1">
                  <.link
                    patch={operations_tab_path(@current_org, :checks, posture.check_filters)}
                    class="text-brand-700 hover:underline"
                  >
                    {gettext("View checks")}
                  </.link>
                  <.link navigate={posture.owner_path} class="text-brand-700 hover:underline">
                    {gettext("Owner page")}
                  </.link>
                </div>
              </:col>
            </.table>
            <div
              :if={integrations_unknown?(@integration_postures)}
              id="operations-integrations-unknown"
              class="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800"
            >
              {gettext("No integration check or diagnostic records have been observed yet; this is unknown, not healthy.")}
            </div>
          </div>
        </.card>
      </div>

      <div :if={@current_tab == :runners} id="operations-runners" class="space-y-4">
        <.card>
          <:title>{gettext("Runners")}</:title>
          <:actions>
            <.button
              :if={@can_manage_operations}
              href={~p"/orgs/#{@current_org.slug}/fin"}
              variant="primary"
              size="sm"
            >
              {gettext("Manage in Fin")}
            </.button>
          </:actions>

          <p class="mb-4 text-sm text-neutral-500">
            {gettext("Runners associated with %{name}.", name: @current_org.name)}
          </p>

          <div :if={@runners == []} id="fin-mac-minis-empty">
            <.empty_state
              icon="bolt"
              title={gettext("No runners connected")}
              description={gettext("No runners have registered with this organization yet.")}
            >
              <:actions>
                <.button
                  :if={@can_manage_operations}
                  href={~p"/orgs/#{@current_org.slug}/fin"}
                  variant="primary"
                  size="sm"
                >
                  {gettext("Manage in Fin")}
                </.button>
              </:actions>
            </.empty_state>
          </div>

          <.empty_state
            :if={@runners != [] and @runner_postures == []}
            icon="bolt"
            title={gettext("No runners match these filters")}
            description={gettext("Clear the runner filters to see the full runner fleet.")}
          />

          <.table
            :if={@runner_postures != []}
            id="fin-mac-minis"
            rows={@runner_postures}
            class={observability_table_class(:runners)}
          >
            <:col :let={posture} label={gettext("Name")}>
              <div class="min-w-[14rem] max-w-[22rem]">
                <div class="truncate font-medium text-neutral-900" title={runner_name(posture.runner)}>
                  {runner_name(posture.runner)}
                </div>
                <div class="truncate font-mono text-xs text-neutral-500" title={safe_text(posture.runner.stable_id)}>
                  {safe_text(posture.runner.stable_id)}
                </div>
              </div>
            </:col>
            <:col :let={posture} label={gettext("Status")}>
              <.status_pill status={posture.status} />
              <div :if={posture.status_reason} class="mt-1 text-xs text-neutral-500">
                {posture.status_reason}
              </div>
              <div :if={posture.runner.status != posture.status} class="mt-1 text-xs text-neutral-500">
                {gettext("last reported")} {safe_text(posture.runner.status)}
              </div>
            </:col>
            <:col :let={posture} label={gettext("Components")}>
              <div class="space-y-1">
                <div :for={component <- posture.component_postures} class="flex items-center gap-2">
                  <span class="min-w-24 text-xs font-medium text-neutral-700">{component.label}</span>
                  <.status_pill status={component.status} label={status_label(component.status)} />
                  <span :if={component.detail} class="text-xs text-neutral-500" title={component.detail}>
                    {component.detail}
                  </span>
                </div>
              </div>
            </:col>
            <:col :let={posture} label={gettext("Host")}>
              <div class="max-w-[16rem]">
                <div class="truncate" title={blank_dash(posture.runner.host_identity)}>
                  {blank_dash(posture.runner.host_identity)}
                </div>
                <div class="truncate text-xs text-neutral-500" title={blank_dash(posture.runner.os_summary)}>
                  {blank_dash(posture.runner.os_summary)}
                </div>
              </div>
            </:col>
            <:col :let={posture} label={gettext("Capacity")}>{runner_capacity(posture.runner)}</:col>
            <:col :let={posture} label={gettext("Latest diagnostics")}>
              <.fact_summary
                summary={posture.latest_event_summary}
                meta={[posture.latest_event_type]}
                class="max-w-[22rem]"
              />
              <.fact_summary
                :if={posture.latest_run_summary}
                summary={posture.latest_run_summary}
                status={posture.latest_run_status}
                class="max-w-[22rem]"
              />
            </:col>
            <:col :let={posture} label={gettext("Last seen")}>
              <div>{format_datetime(posture.runner.last_seen_at)}</div>
              <div class="text-xs text-neutral-500">{last_seen_age(posture.runner)}</div>
            </:col>
            <:col :let={posture} label={gettext("Links")}>
              <div class="flex flex-col gap-1">
                <.link
                  patch={operations_tab_path(@current_org, :events, posture.event_filters)}
                  class="text-brand-700 hover:underline"
                >
                  {gettext("View events")}
                </.link>
                <.link
                  patch={operations_tab_path(@current_org, :runners, posture.run_filters)}
                  class="text-brand-700 hover:underline"
                >
                  {gettext("View runs")}
                </.link>
              </div>
            </:col>
          </.table>
          <.runner_fleet_pagination
            :if={@runner_postures != []}
            org={@current_org}
            filters={@filters}
            current_cursor={@runner_page_cursor}
            next_cursor={@runner_next_cursor}
            current_count={length(@runner_postures)}
            total_count={@runner_total_count}
          />
        </.card>

        <.card :if={@runs != []}>
          <:title>{gettext("Recent runs")}</:title>
          <.run_table id="operations-runs-table" runs={@runs} project_names={@project_names} />
          <.next_page_link
            :if={@run_cursor}
            patch={next_page_path(@current_org, @current_tab, @filters, @run_cursor)}
          />
        </.card>
      </div>

      <div :if={@current_tab == :events} id="operations-events">
        <.card>
          <:title>{gettext("Events")}</:title>
          <p class="mb-4 text-sm text-neutral-500">
            {gettext("Recent redacted operational events for %{name}.", name: @current_org.name)}
          </p>
          <.observability_filter_form
            id="operations-events-filters"
            org={@current_org}
            tab={:events}
            filters={@filters}
            fields={event_filter_fields(@projects, @can_view_audit)}
          />
          <.empty_state
            :if={@events == []}
            icon="bell"
            title={events_empty_title(@filters, @projects, @runners)}
            description={events_empty_description(@filters, @projects, @runners)}
          />
          <.event_table
            :if={@events != []}
            id="operations-events-table"
            events={@events}
            org={@current_org}
            can_view_audit={@can_view_audit}
          />
          <.next_page_link
            :if={@event_cursor}
            patch={next_page_path(@current_org, :events, @filters, @event_cursor)}
          />
        </.card>
      </div>

      <div :if={@current_tab == :checks} id="operations-checks">
        <.card>
          <:title>{gettext("Checks")}</:title>
          <p class="mb-4 text-sm text-neutral-500">
            {gettext("Persisted verification snapshots across SSO, bot, delivery, and runner surfaces.")}
          </p>
          <.observability_filter_form
            id="operations-checks-filters"
            org={@current_org}
            tab={:checks}
            filters={@filters}
            fields={check_filter_fields(@projects)}
          />
          <.empty_state
            :if={@checks == []}
            icon="check-circle"
            title={checks_empty_title(@filters, @projects)}
            description={checks_empty_description(@filters, @projects)}
          />
          <.check_table
            :if={@checks != []}
            id="operations-checks-table"
            checks={@checks}
            project_names={@project_names}
          />
          <.next_page_link
            :if={@check_cursor}
            patch={next_page_path(@current_org, :checks, @filters, @check_cursor)}
          />
        </.card>
      </div>

      <div :if={@current_tab == :audit and !@can_view_audit} id="operations-audit-denied">
        <.card>
          <:title>{gettext("Audit")}</:title>
          <.empty_state
            icon="lock-closed"
            title={gettext("Audit requires admin access")}
            description={gettext("Only organization owners and admins can view privileged action records.")}
          />
        </.card>
      </div>

      <div :if={@current_tab == :audit and @can_view_audit} id="operations-audit">
        <.card>
          <:title>{gettext("Audit")}</:title>
          <div class="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <p class="text-sm text-neutral-500">
              {gettext("Redacted administrative and system action records for %{name}.", name: @current_org.name)}
            </p>
            <.link
              href={audit_export_path(@current_org, @filters)}
              class="inline-flex h-9 items-center justify-center rounded-md border border-neutral-300 px-3 text-sm font-medium text-neutral-700 hover:border-neutral-400 hover:bg-neutral-50"
            >
              {gettext("Export CSV")}
            </.link>
          </div>
          <.observability_filter_form
            id="operations-audit-filters"
            org={@current_org}
            tab={:audit}
            filters={@filters}
            fields={audit_filter_fields()}
          />
          <.empty_state
            :if={@audit_logs == []}
            icon="clipboard-document-list"
            title={audit_empty_title(@filters)}
            description={audit_empty_description(@filters)}
          />
          <.audit_table :if={@audit_logs != []} id="operations-audit-table" audit_logs={@audit_logs} />
          <.next_page_link
            :if={@audit_cursor}
            patch={next_page_path(@current_org, :audit, @filters, @audit_cursor)}
          />
        </.card>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, required: true)
  attr(:patch, :string, default: nil)

  defp summary_card(assigns) do
    ~H"""
    <.link
      :if={@patch}
      patch={@patch}
      class="block h-full rounded-lg focus:outline-none focus:ring-2 focus:ring-brand-500 focus:ring-offset-2"
    >
      <.summary_card_content label={@label} value={@value} detail={@detail} linked={true} />
    </.link>
    <.summary_card_content
      :if={is_nil(@patch)}
      label={@label}
      value={@value}
      detail={@detail}
      linked={false}
    />
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, required: true)
  attr(:linked, :boolean, default: false)

  defp summary_card_content(assigns) do
    ~H"""
    <.card class={summary_card_class(@linked)}>
      <div class="space-y-1">
        <div class="text-xs font-medium text-neutral-500">{@label}</div>
        <div class="text-2xl font-semibold text-neutral-900">{@value}</div>
        <div class="text-xs text-neutral-500">{@detail}</div>
      </div>
    </.card>
    """
  end

  defp summary_card_class(true),
    do: "h-full transition hover:border-brand-300 hover:bg-brand-50/20"

  defp summary_card_class(_linked), do: "h-full"

  defp delivery_empty_title(filters) do
    if tab_filtered?(:delivery, filters) do
      gettext("No Agent Swarms match these filters")
    else
      gettext("No Agent Swarms yet")
    end
  end

  defp delivery_empty_description(filters) do
    if tab_filtered?(:delivery, filters) do
      gettext("Clear the delivery filters to see every Agent Swarm.")
    else
      gettext("Create an Agent Swarm before Operations can show delivery posture.")
    end
  end

  defp events_empty_title(filters, projects, runners) do
    cond do
      tab_filtered?(:events, filters) ->
        gettext("No events match these filters")

      not event_sources_installed?(projects, runners) ->
        gettext("No event producers connected yet")

      true ->
        gettext("No events observed yet")
    end
  end

  defp events_empty_description(filters, projects, runners) do
    cond do
      tab_filtered?(:events, filters) ->
        gettext("Clear the event filters to inspect all observed Operations events.")

      not event_sources_installed?(projects, runners) ->
        gettext(
          "Create an Agent Swarm or onboard a runner before runtime event ingestion can report activity."
        )

      true ->
        gettext("Event producers are available, but no matching activity has been recorded yet.")
    end
  end

  defp checks_empty_title(filters, projects) do
    cond do
      tab_filtered?(:checks, filters) ->
        gettext("No check results match these filters")

      projects == [] ->
        gettext("No check targets configured yet")

      true ->
        gettext("No check results persisted yet")
    end
  end

  defp checks_empty_description(filters, projects) do
    cond do
      tab_filtered?(:checks, filters) ->
        gettext("Clear the check filters to inspect all persisted verification snapshots.")

      projects == [] ->
        gettext(
          "Create an Agent Swarm or configure an integration before Run checks can persist results."
        )

      true ->
        gettext(
          "Run checks will appear here after an admin runs a setup or delivery verification."
        )
    end
  end

  defp audit_empty_title(filters) do
    if tab_filtered?(:audit, filters) do
      gettext("No audit actions match these filters")
    else
      gettext("No audit actions recorded yet")
    end
  end

  defp audit_empty_description(filters) do
    if tab_filtered?(:audit, filters) do
      gettext("Clear the audit filters to inspect all privileged action records.")
    else
      gettext("Audit is installed; privileged writes will appear here after activity occurs.")
    end
  end

  defp event_sources_installed?(projects, runners), do: projects != [] or runners != []

  defp tab_filtered?(tab, filters) do
    tab
    |> filter_keys_for_tab()
    |> Enum.reject(&(&1 in ["cursor", "runner_cursor"]))
    |> Enum.any?(fn key -> Map.get(filters, key) not in [nil, ""] end)
  end

  defp observability_table_class(:events),
    do: observability_table_class("[&_table]:min-w-[1180px]")

  defp observability_table_class(:runs),
    do: observability_table_class("[&_table]:min-w-[1120px]")

  defp observability_table_class(:checks),
    do: observability_table_class("[&_table]:min-w-[1080px]")

  defp observability_table_class(:audit),
    do: observability_table_class("[&_table]:min-w-[1040px]")

  defp observability_table_class(:runners),
    do: observability_table_class("[&_table]:min-w-[1240px]")

  defp observability_table_class(min_width_class) do
    (observability_table_base_class() ++ [min_width_class])
    |> Enum.join(" ")
  end

  defp observability_table_base_class do
    [
      "rounded-xl border-neutral-200 bg-white shadow-sm",
      "[&_thead_tr]:bg-neutral-50/80",
      "[&_th]:whitespace-nowrap [&_th]:px-4 [&_th]:py-2.5",
      "[&_td]:whitespace-nowrap [&_td]:px-4 [&_td]:py-3 [&_td]:align-top",
      "[&_tbody_tr]:transition-colors [&_tbody_tr:hover]:bg-brand-50/20"
    ]
  end

  attr(:id, :string, required: true)
  attr(:events, :list, required: true)
  attr(:org, :map, required: true)
  attr(:can_view_audit, :boolean, default: false)

  defp event_table(assigns) do
    ~H"""
    <.table id={@id} rows={@events} class={observability_table_class(:events)}>
      <:col :let={event} label={gettext("Time")}>
        <span class="font-mono text-xs text-neutral-500">{format_datetime(event.occurred_at)}</span>
      </:col>
      <:col :let={event} label={gettext("Severity")}>
        <.badge color={severity_color(event.severity)} class="uppercase tracking-wide">
          {event.severity}
        </.badge>
      </:col>
      <:col :let={event} label={gettext("Signal")}>
        <div class="min-w-[18rem] max-w-[24rem]">
          <div class="truncate font-medium text-neutral-900" title={safe_text(event.event_type)}>
            {safe_text(event.event_type)}
          </div>
          <div class="mt-1 flex items-center gap-1.5 overflow-hidden text-xs text-neutral-500">
            <span class="shrink-0 font-medium text-neutral-700">{safe_text(event.domain)}</span>
            <span class="shrink-0 text-neutral-300">/</span>
            <span class="truncate" title={safe_text(event.source)}>{safe_text(event.source)}</span>
            <span class="shrink-0 rounded bg-neutral-100 px-1.5 py-0.5">
              {safe_text(event.resource_type)}
            </span>
          </div>
        </div>
      </:col>
      <:col :let={event} label={gettext("Summary")}>
        <div class="max-w-[34rem]">
          <div
            class="truncate text-neutral-800"
            title={safe_text(event.summary, gettext("Diagnostic recorded"))}
          >
            {safe_text(event.summary, gettext("Diagnostic recorded"))}
          </div>
          <div :if={event.reason_class} class="mt-1 text-xs text-neutral-500">
            {humanize_reason(event.reason_class)}
          </div>
        </div>
      </:col>
      <:col :let={event} label={gettext("Details")}>
        <div class="flex max-w-[42rem] items-center gap-1.5 overflow-hidden text-xs text-neutral-500">
          <.detail_chip :if={event.status} label={gettext("Status")} value={status_label(event.status)} />
          <.detail_chip
            :if={event.correlation_id}
            label={gettext("Correlation")}
            value={safe_text(event.correlation_id)}
          />
          <.record_link_chip
            :if={event.run_record_id}
            patch={operations_tab_path(@org, :runners, %{run_record_id: event.run_record_id})}
            label={gettext("Run")}
          />
          <.record_link_chip
            :if={event.check_result_id}
            patch={operations_tab_path(@org, :checks, %{check_result_id: event.check_result_id})}
            label={gettext("Check")}
          />
          <.record_link_chip
            :if={@can_view_audit && event.audit_log_id}
            patch={operations_tab_path(@org, :audit, %{audit_log_id: event.audit_log_id})}
            label={gettext("Audit")}
          />
          <.event_evidence_preview event={event} />
        </div>
      </:col>
    </.table>
    """
  end

  attr(:patch, :string, required: true)
  attr(:label, :string, required: true)

  defp record_link_chip(assigns) do
    ~H"""
    <.link
      patch={@patch}
      class="inline-flex h-6 shrink-0 items-center rounded-md border border-brand-200 bg-brand-50 px-2 font-medium text-brand-700 hover:border-brand-300 hover:bg-brand-100"
    >
      {@label}
    </.link>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp detail_chip(assigns) do
    ~H"""
    <span class="inline-flex h-6 max-w-[18rem] shrink-0 items-center gap-1 overflow-hidden rounded-md bg-neutral-100 px-2 text-neutral-600">
      <span class="font-medium text-neutral-500">{@label}</span>
      <span class="truncate font-mono text-neutral-700" title={@value}>{@value}</span>
    </span>
    """
  end

  attr(:event, :map, required: true)

  defp event_evidence_preview(assigns) do
    assigns = assign(assigns, :pairs, event_evidence_pairs(assigns.event))

    ~H"""
    <.evidence_preview pairs={@pairs} label={gettext("Evidence")} />
    """
  end

  attr(:pairs, :list, required: true)
  attr(:label, :string, required: true)

  defp evidence_preview(assigns) do
    ~H"""
    <div :if={@pairs != []} class="inline-flex min-w-0 items-center gap-1.5">
      <span class="shrink-0 font-medium text-neutral-600">{@label}</span>
      <span
        :for={{key, value} <- @pairs}
        class="inline-flex h-6 max-w-[22rem] shrink-0 items-center overflow-hidden rounded-md bg-neutral-100 px-2 font-mono text-[11px] text-neutral-600"
        title={"#{key}=#{value}"}
      >
        <span class="truncate">{key}={value}</span>
      </span>
    </div>
    """
  end

  defp event_evidence_pairs(%{evidence: evidence} = event) when is_map(evidence) do
    allowed_keys = event_detail_evidence_keys(event)

    evidence
    |> Enum.flat_map(fn {key, value} ->
      key = to_string(key)

      with true <- MapSet.member?(allowed_keys, key),
           value when is_binary(value) <- event_evidence_value(value) do
        [{key, value}]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.take(8)
  end

  defp event_evidence_pairs(_event), do: []

  defp run_evidence_pairs(run) do
    run
    |> run_evidence_map()
    |> evidence_pairs(@run_detail_evidence_keys)
  end

  defp run_evidence_map(run) do
    evidence =
      case Map.get(run, :evidence) do
        %{} = evidence -> evidence
        _other -> %{}
      end

    evidence
    |> Map.merge(%{
      "duration_ms" => Map.get(run, :duration_ms),
      "exit_code" => Map.get(run, :exit_code),
      "request_id" => Map.get(run, :request_id)
    })
  end

  defp check_evidence_pairs(check) do
    check
    |> check_evidence_map()
    |> evidence_pairs(@check_detail_evidence_keys)
  end

  defp check_evidence_map(check) do
    result = Map.get(check, :result) || %{}

    %{
      "check_family" => Map.get(check, :check_family),
      "gate_count" => check_gate_count(result),
      "status" => Map.get(check, :status),
      "surface" => Map.get(check, :surface)
    }
    |> Map.merge(Map.take(result, @check_detail_evidence_keys))
  end

  defp audit_evidence_pairs(audit) do
    audit
    |> audit_evidence_map()
    |> evidence_pairs(@audit_detail_evidence_keys)
  end

  defp audit_evidence_map(audit) do
    metadata = Map.get(audit, :metadata) || %{}
    redacted_diff = Map.get(audit, :redacted_diff) || %{}

    %{
      "metadata_present" => map_size(metadata) > 0,
      "metadata_size_bytes" => Map.get(audit, :metadata_size_bytes),
      "redacted_diff_present" => map_size(redacted_diff) > 0,
      "request_id" => Map.get(audit, :request_id)
    }
  end

  defp evidence_pairs(evidence, allowed_keys) when is_map(evidence) do
    allowed_keys = MapSet.new(allowed_keys)

    evidence
    |> Enum.flat_map(fn {key, value} ->
      key = to_string(key)

      with true <- MapSet.member?(allowed_keys, key),
           value when is_binary(value) <- event_evidence_value(value) do
        [{key, value}]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.take(8)
  end

  defp evidence_pairs(_evidence, _allowed_keys), do: []

  defp event_detail_evidence_keys(event) do
    domain = event |> Map.get(:domain) |> to_string()
    domain_keys = Map.get(@event_detail_evidence_keys_by_domain, domain, [])

    MapSet.new(@event_detail_shared_evidence_keys ++ domain_keys)
  end

  defp event_evidence_value(value) when value in [nil, ""], do: nil
  defp event_evidence_value(value) when is_map(value) or is_list(value), do: nil
  defp event_evidence_value(value), do: safe_text(value, nil)

  attr(:id, :string, required: true)
  attr(:org, :map, required: true)
  attr(:tab, :atom, required: true)
  attr(:filters, :map, required: true)
  attr(:fields, :list, required: true)

  defp observability_filter_form(assigns) do
    ~H"""
    <form
      id={@id}
      phx-submit="filter-observability"
      class="mb-4 rounded-md border border-neutral-200 bg-neutral-50 px-3 py-3"
    >
      <div class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-4">
        <div :for={field <- @fields}>
          <.select
            :if={field.type == :select}
            id={"#{@id}-#{field.key}"}
            name={"filters[#{field.key}]"}
            label={field.label}
            prompt={field.prompt}
            value={Map.get(@filters, field.key)}
            options={field.options}
          />
          <.input
            :if={field.type == :text}
            id={"#{@id}-#{field.key}"}
            name={"filters[#{field.key}]"}
            label={field.label}
            value={Map.get(@filters, field.key)}
            placeholder={field.placeholder}
            autocomplete="off"
          />
        </div>
      </div>
      <div class="mt-3 flex items-center gap-2">
        <.button type="submit" size="sm" variant="primary">{gettext("Apply")}</.button>
        <.button patch={operations_tab_path(@org, @tab, %{})} size="sm" variant="ghost">
          {gettext("Clear")}
        </.button>
      </div>
    </form>
    """
  end

  attr(:id, :string, required: true)
  attr(:runs, :list, required: true)
  attr(:project_names, :map, required: true)

  defp run_table(assigns) do
    ~H"""
    <.table id={@id} rows={@runs} class={observability_table_class(:runs)}>
      <:col :let={run} label={gettext("Time")}>
        <span class="font-mono text-xs text-neutral-500">
          {format_datetime(run.started_at || run.created_at)}
        </span>
      </:col>
      <:col :let={run} label={gettext("Run")}>
        <div class="min-w-[15rem] max-w-[22rem]">
          <div class="truncate font-medium text-neutral-900" title={safe_text(run.run_type)}>
            {safe_text(run.run_type)}
          </div>
          <div :if={run.external_run_id} class="truncate font-mono text-xs text-neutral-500">
            {safe_text(run.external_run_id)}
          </div>
        </div>
      </:col>
      <:col :let={run} label={gettext("Project")}>
        <span class="font-medium text-neutral-800">{run_project_label(run, @project_names)}</span>
      </:col>
      <:col :let={run} label={gettext("Runner")}>
        <div class="max-w-[16rem]">
          <div class="truncate" title={blank_dash(run.runner_type)}>{blank_dash(run.runner_type)}</div>
          <div :if={run.runner_id} class="text-xs text-neutral-500">{short_id(run.runner_id)}</div>
        </div>
      </:col>
      <:col :let={run} label={gettext("Status")}>
        <.status_pill status={run.status} label={status_label(run.status)} />
        <div :if={run.reason_class} class="mt-1 text-xs text-neutral-500">
          {humanize_reason(run.reason_class)}
        </div>
      </:col>
      <:col :let={run} label={gettext("Duration")}>{run_duration(run)}</:col>
      <:col :let={run} label={gettext("Details")}>
        <div class="flex max-w-[42rem] items-center gap-1.5 overflow-hidden text-xs text-neutral-500">
          <.evidence_preview pairs={run_evidence_pairs(run)} label={gettext("Evidence")} />
          <.detail_chip
            :if={run.stderr_tail_redacted}
            label={gettext("Stderr")}
            value={safe_text(run.stderr_tail_redacted)}
          />
        </div>
      </:col>
    </.table>
    """
  end

  attr(:id, :string, required: true)
  attr(:checks, :list, required: true)
  attr(:project_names, :map, required: true)

  defp check_table(assigns) do
    ~H"""
    <.table id={@id} rows={@checks} class={observability_table_class(:checks)}>
      <:col :let={check} label={gettext("Ran at")}>
        <span class="font-mono text-xs text-neutral-500">{format_datetime(check.ran_at)}</span>
      </:col>
      <:col :let={check} label={gettext("Check")}>
        <div class="min-w-[14rem] max-w-[20rem]">
          <div class="truncate font-medium text-neutral-900" title={safe_text(check.surface)}>
            {safe_text(check.surface)}
          </div>
          <div class="truncate text-xs text-neutral-500" title={safe_text(check.check_family)}>
            {safe_text(check.check_family)}
          </div>
        </div>
      </:col>
      <:col :let={check} label={gettext("Subject")}>
        <div class="max-w-[18rem]">
          <div
            class="truncate font-medium text-neutral-800"
            title={check_subject_label(check, @project_names)}
          >
            {check_subject_label(check, @project_names)}
          </div>
          <div class="text-xs text-neutral-500">{safe_text(check.subject_type)}</div>
        </div>
      </:col>
      <:col :let={check} label={gettext("Status")}>
        <.status_pill status={check.status} label={status_label(check.status)} />
        <div :if={check.reason_class} class="mt-1 text-xs text-neutral-500">
          {humanize_reason(check.reason_class)}
        </div>
      </:col>
      <:col :let={check} label={gettext("Gates")}>
        <.fact_summary
          summary={check_gate_summary(check)}
          meta={[check.invocation_id]}
        />
      </:col>
      <:col :let={check} label={gettext("Details")}>
        <div class="flex max-w-[38rem] items-center gap-1.5 overflow-hidden text-xs text-neutral-500">
          <.evidence_preview pairs={check_evidence_pairs(check)} label={gettext("Evidence")} />
        </div>
      </:col>
    </.table>
    """
  end

  attr(:id, :string, required: true)
  attr(:audit_logs, :list, required: true)

  defp audit_table(assigns) do
    ~H"""
    <.table id={@id} rows={@audit_logs} class={observability_table_class(:audit)}>
      <:col :let={audit} label={gettext("Time")}>
        <span class="font-mono text-xs text-neutral-500">{format_datetime(audit.created_at)}</span>
      </:col>
      <:col :let={audit} label={gettext("Actor")}>
        <div class="min-w-[13rem] max-w-[20rem]">
          <div class="truncate font-medium text-neutral-900" title={audit_actor_label(audit)}>
            {audit_actor_label(audit)}
          </div>
          <div class="text-xs text-neutral-500">{safe_text(audit.actor_type)}</div>
        </div>
      </:col>
      <:col :let={audit} label={gettext("Action")}>
        <div class="min-w-[14rem] max-w-[22rem]">
          <div class="truncate font-medium text-neutral-900" title={safe_text(audit.action)}>
            {safe_text(audit.action)}
          </div>
          <div :if={audit.request_id} class="truncate font-mono text-xs text-neutral-500">
            {safe_text(audit.request_id)}
          </div>
        </div>
      </:col>
      <:col :let={audit} label={gettext("Resource")}>
        <div class="max-w-[18rem]">
          <div class="truncate font-medium text-neutral-800" title={audit_resource_label(audit)}>
            {audit_resource_label(audit)}
          </div>
          <div class="text-xs text-neutral-500">{safe_text(audit.resource_type)}</div>
        </div>
      </:col>
      <:col :let={audit} label={gettext("Result")}>
        <.status_pill status={audit.result} label={status_label(audit.result)} />
        <div :if={audit.reason_class} class="mt-1 text-xs text-neutral-500">
          {humanize_reason(audit.reason_class)}
        </div>
      </:col>
      <:col :let={audit} label={gettext("Details")}>
        <div class="flex max-w-[34rem] items-center gap-1.5 overflow-hidden text-xs text-neutral-500">
          <.evidence_preview pairs={audit_evidence_pairs(audit)} label={gettext("Details")} />
        </div>
      </:col>
    </.table>
    """
  end

  attr(:summary, :any, required: true)
  attr(:meta, :list, default: [])
  attr(:status, :any, default: nil)
  attr(:class, :string, default: nil)

  defp fact_summary(assigns) do
    assigns = assign(assigns, :meta_items, fact_meta_items(assigns.meta))

    ~H"""
    <div class={["max-w-md space-y-1", @class]}>
      <.status_pill :if={@status} status={@status} label={status_label(@status)} />
      <div
        class="truncate text-neutral-700"
        title={safe_text(@summary, gettext("No fact observed"))}
      >
        {safe_text(@summary, gettext("No fact observed"))}
      </div>
      <div :for={item <- @meta_items} class="truncate text-xs text-neutral-500" title={item}>
        {item}
      </div>
    </div>
    """
  end

  defp fact_meta_items(items) do
    items
    |> List.wrap()
    |> Enum.map(&safe_text(&1, nil))
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  attr(:patch, :string, required: true)
  attr(:label, :string, default: nil)

  defp next_page_link(assigns) do
    ~H"""
    <div class="mt-4 border-t border-neutral-100 pt-3">
      <.link patch={@patch} class="text-sm font-medium text-brand-700 hover:underline">
        {@label || gettext("Next page")}
      </.link>
    </div>
    """
  end

  attr(:org, :map, required: true)
  attr(:filters, :map, required: true)
  attr(:current_cursor, :string, default: nil)
  attr(:next_cursor, :string, default: nil)
  attr(:current_count, :integer, required: true)
  attr(:total_count, :integer, required: true)

  defp runner_fleet_pagination(assigns) do
    ~H"""
    <div class="mt-4 flex flex-col gap-2 border-t border-neutral-100 pt-3 sm:flex-row sm:items-center sm:justify-between">
      <p class="text-xs text-neutral-500">
        {gettext("Showing %{count} of %{total} runners",
          count: @current_count,
          total: @total_count
        )}
      </p>
      <div class="flex items-center gap-3">
        <.link
          :if={@current_cursor}
          patch={runner_fleet_first_page_path(@org, @filters)}
          class="text-sm font-medium text-neutral-600 hover:text-brand-700 hover:underline"
        >
          {gettext("First page")}
        </.link>
        <.link
          :if={@next_cursor}
          patch={runner_fleet_next_page_path(@org, @filters, @next_cursor)}
          class="text-sm font-medium text-brand-700 hover:underline"
        >
          {gettext("Next runners")}
        </.link>
      </div>
    </div>
    """
  end

  defp assign_current_tab(socket, tab)
       when tab in [:overview, :delivery, :integrations, :runners, :events, :checks, :audit],
       do: assign_tab(socket, tab)

  defp assign_current_tab(socket, _other), do: assign_tab(socket, :overview)

  defp assign_tab(socket, tab) do
    socket
    |> assign(:current_tab, tab)
    |> assign(
      :summary,
      summary(
        socket.assigns.projects,
        socket.assigns.runners,
        socket.assigns.events,
        socket.assigns.runs,
        socket.assigns.checks,
        socket.assigns.audit_logs,
        socket.assigns.health_summary
      )
    )
  end

  defp assign_breadcrumbs(socket) do
    org = socket.assigns.current_org

    breadcrumbs =
      case socket.assigns.current_tab do
        :overview ->
          [{org.name, ~p"/orgs/#{org.slug}"}, {gettext("Operations"), nil}]

        tab ->
          [
            {org.name, ~p"/orgs/#{org.slug}"},
            {gettext("Operations"), ~p"/orgs/#{org.slug}/operations"},
            {tab_label(tab), nil}
          ]
      end

    assign(socket, :breadcrumbs, breadcrumbs)
  end

  defp assign_observability(socket) do
    if Application.get_env(:bridge_for_teams_web, :operations_observability_load_failure, false) do
      assign_observability_error(socket, :forced_failure)
    else
      try do
        socket
        |> do_assign_observability()
        |> assign(:operations_loading?, false)
        |> assign(:operations_error, nil)
      rescue
        exception ->
          Logger.warning(
            "operations_observability_load_failed kind=error reason=#{inspect(exception.__struct__)}"
          )

          assign_observability_error(socket, exception)
      catch
        kind, reason ->
          Logger.warning(
            "operations_observability_load_failed kind=#{inspect(kind)} reason=#{inspect(error_reason_class(reason))}"
          )

          assign_observability_error(socket, reason)
      end
    end
  end

  defp do_assign_observability(socket) do
    org_id = socket.assigns.current_org.id
    filters = socket.assigns.filters
    event_page = Observability.page_events(org_id, event_opts(socket, filters))
    run_page = Observability.page_operation_runs(org_id, run_opts(filters))
    check_page = Observability.page_check_results(org_id, check_opts(filters))
    audit_page = audit_page(socket, org_id, filters)
    delivery_facts = subsystem_facts(socket, org_id, :delivery, filters)
    delivery_postures = delivery_postures(socket.assigns.projects, delivery_facts, filters)
    integration_facts = subsystem_facts(socket, org_id, :integrations, filters)
    runner_facts = subsystem_facts(socket, org_id, :runners, filters)
    runner_page = runner_fleet_page(socket, org_id, filters)

    runner_postures =
      runner_postures(
        runner_page.entries,
        runner_facts,
        filters
      )

    socket
    |> assign(:events, event_page.entries)
    |> assign(:event_cursor, event_page.next_cursor)
    |> assign(:runs, run_page.entries)
    |> assign(:run_cursor, run_page.next_cursor)
    |> assign(:checks, check_page.entries)
    |> assign(:check_cursor, check_page.next_cursor)
    |> assign(:audit_logs, audit_page.entries)
    |> assign(:audit_cursor, audit_page.next_cursor)
    |> assign(:delivery_postures, delivery_postures)
    |> assign(:delivery_facts_observed?, delivery_facts_observed?(delivery_facts))
    |> assign(:runner_postures, runner_postures)
    |> assign(:runner_page_cursor, runner_page.cursor)
    |> assign(:runner_next_cursor, runner_page.next_cursor)
    |> assign(:runner_total_count, runner_page.total_count)
    |> assign(:freshness_rows, overview_freshness(socket, delivery_facts, integration_facts))
    |> assign(
      :health_summary,
      Observability.org_health_summary_for_org(
        org_id,
        length(socket.assigns.projects),
        socket.assigns.runners
      )
    )
    |> assign(
      :integration_postures,
      integration_postures(socket, integration_facts.checks, integration_facts.events)
    )
  end

  defp assign_observability_error(socket, _reason) do
    socket
    |> assign(:events, Map.get(socket.assigns, :events, []))
    |> assign(:event_cursor, Map.get(socket.assigns, :event_cursor))
    |> assign(:runs, Map.get(socket.assigns, :runs, []))
    |> assign(:run_cursor, Map.get(socket.assigns, :run_cursor))
    |> assign(:checks, Map.get(socket.assigns, :checks, []))
    |> assign(:check_cursor, Map.get(socket.assigns, :check_cursor))
    |> assign(:audit_logs, Map.get(socket.assigns, :audit_logs, []))
    |> assign(:audit_cursor, Map.get(socket.assigns, :audit_cursor))
    |> assign(:delivery_postures, Map.get(socket.assigns, :delivery_postures, []))
    |> assign(
      :delivery_facts_observed?,
      Map.get(socket.assigns, :delivery_facts_observed?, false)
    )
    |> assign(:runner_postures, Map.get(socket.assigns, :runner_postures, []))
    |> assign(:runner_page_cursor, Map.get(socket.assigns, :runner_page_cursor))
    |> assign(:runner_next_cursor, Map.get(socket.assigns, :runner_next_cursor))
    |> assign(:runner_total_count, Map.get(socket.assigns, :runner_total_count, 0))
    |> assign(:freshness_rows, Map.get(socket.assigns, :freshness_rows, []))
    |> assign(
      :health_summary,
      Map.get(socket.assigns, :health_summary, unavailable_health_summary())
    )
    |> assign(:integration_postures, Map.get(socket.assigns, :integration_postures, []))
    |> assign(:operations_loading?, false)
    |> assign(:operations_error, :observability_unavailable)
  end

  defp unavailable_health_summary do
    %{health: "unknown", reason_codes: [:observability_unavailable]}
  end

  defp error_reason_class(%{__struct__: struct}), do: struct
  defp error_reason_class(reason), do: reason

  defp summary(projects, runners, events, runs, checks, audit_logs, health_summary) do
    runner_count = length(runners)
    project_count = length(projects)

    %{
      project_count: project_count,
      runner_count: runner_count,
      event_count: length(events),
      run_count: length(runs),
      check_count: length(checks),
      audit_count: length(audit_logs),
      health: health_summary.health,
      health_reasons: Enum.map(health_summary.reason_codes, &health_reason_text/1)
    }
  end

  defp overview_freshness(socket, delivery_facts, integration_facts) do
    org = socket.assigns.current_org
    now = DateTime.utc_now()
    policy = Observability.freshness_policy()

    [
      integration_freshness_row(org, integration_facts, now, policy),
      check_freshness_row(org, delivery_facts.checks, now, policy),
      runner_freshness_row(org, socket.assigns.runners, now, policy),
      environment_freshness_row(org, delivery_facts.events, now, policy)
    ]
  end

  defp integration_freshness_row(org, %{events: events, checks: checks}, now, policy) do
    latest_event =
      events
      |> Enum.filter(&(integration_key_for_event(&1) != nil))
      |> latest_by_datetime(& &1.occurred_at)

    latest_check =
      checks
      |> Enum.filter(&integration_check?/1)
      |> latest_by_datetime(& &1.ran_at)

    {observed_at, detail} =
      case latest_fact([{:event, latest_event}, {:check, latest_check}]) do
        {:event, event} ->
          {event.occurred_at,
           gettext("Latest diagnostic: %{summary}", summary: latest_event_summary(event))}

        {:check, check} ->
          {check.ran_at, gettext("Latest check: %{summary}", summary: check_gate_summary(check))}

        nil ->
          {nil, gettext("No integration check or diagnostic observed")}
      end

    freshness_row(
      gettext("Integrations"),
      detail,
      observed_at,
      policy[:integration_check_freshness_seconds],
      now,
      operations_tab_path(org, :integrations, %{})
    )
  end

  defp check_freshness_row(org, checks, now, policy) do
    latest_check = latest_by_datetime(checks, & &1.ran_at)

    {observed_at, detail} =
      case latest_check do
        nil ->
          {nil, gettext("No check result observed")}

        check ->
          {check.ran_at, gettext("Latest check: %{summary}", summary: check_gate_summary(check))}
      end

    freshness_row(
      gettext("Checks"),
      detail,
      observed_at,
      policy[:check_result_history_seconds],
      now,
      operations_tab_path(org, :checks, %{})
    )
  end

  defp runner_freshness_row(org, runners, now, policy) do
    latest_runner = latest_by_datetime(runners, & &1.last_seen_at)

    {observed_at, detail} =
      case latest_runner do
        nil ->
          {nil, gettext("No runner heartbeat observed")}

        runner ->
          {runner.last_seen_at,
           gettext("%{runner} heartbeat %{age}",
             runner: runner_name(runner),
             age: last_seen_age(runner)
           )}
      end

    freshness_row(
      gettext("Runners"),
      detail,
      observed_at,
      policy[:runner_heartbeat_stale_seconds],
      now,
      operations_tab_path(org, :runners, %{})
    )
  end

  defp environment_freshness_row(org, events, now, policy) do
    latest_event =
      events
      |> Enum.filter(&(&1.domain == "device"))
      |> latest_by_datetime(& &1.occurred_at)

    {observed_at, detail} =
      case latest_event do
        nil ->
          {nil, gettext("No device diagnostic observed")}

        event ->
          {event.occurred_at,
           gettext("Latest device event: %{summary}", summary: latest_event_summary(event))}
      end

    freshness_row(
      gettext("Devices"),
      detail,
      observed_at,
      policy[:event_history_seconds],
      now,
      operations_tab_path(org, :events, %{domain: "device"})
    )
  end

  defp freshness_row(label, detail, observed_at, max_age_seconds, now, patch) do
    {status, status_label} = freshness_status(observed_at, max_age_seconds, now)

    %{
      label: label,
      detail: detail,
      observed_at: observed_at,
      observed_label: observed_label(observed_at),
      status: status,
      status_label: status_label,
      patch: patch
    }
  end

  defp freshness_status(nil, _max_age_seconds, _now), do: {"unknown", gettext("unknown")}

  defp freshness_status(%DateTime{} = observed_at, max_age_seconds, %DateTime{} = now)
       when is_integer(max_age_seconds) and max_age_seconds > 0 do
    if DateTime.diff(now, observed_at, :second) > max_age_seconds do
      {"degraded", gettext("stale")}
    else
      {"ok", gettext("current")}
    end
  end

  defp freshness_status(%DateTime{}, _max_age_seconds, _now), do: {"ok", gettext("current")}

  defp observed_label(nil), do: gettext("Never observed")

  defp observed_label(%DateTime{} = observed_at),
    do: gettext("Last observed %{time}", time: format_datetime(observed_at))

  defp latest_fact(facts) do
    facts =
      Enum.reject(facts, fn {_kind, fact} -> is_nil(fact) end)

    case facts do
      [] ->
        nil

      facts ->
        Enum.max_by(
          facts,
          fn
            {:event, event} -> event.occurred_at
            {:check, check} -> check.ran_at
          end,
          &datetime_after_or_equal?/2
        )
    end
  end

  defp latest_by_datetime(records, datetime_fun) do
    records =
      Enum.reject(records, &(datetime_fun.(&1) == nil))

    case records do
      [] -> nil
      records -> Enum.max_by(records, datetime_fun, &datetime_after_or_equal?/2)
    end
  end

  defp datetime_after_or_equal?(left, right), do: DateTime.compare(left, right) != :lt

  defp subsystem_facts(socket, org_id, preset, filters) do
    preset = subsystem_fact_preset(preset, filters)

    %{
      events: list_subsystem_events(socket, org_id, preset.events),
      runs: list_subsystem_runs(org_id, preset.runs),
      checks: list_subsystem_checks(org_id, preset.checks)
    }
  end

  defp subsystem_fact_preset(:delivery, filters) do
    common_opts = subsystem_fact_opts(filters, ~w(project_id since))

    %{
      events: Keyword.merge(common_opts, limit: @subsystem_fact_limit, exclude_domain: "audit"),
      runs: Keyword.merge(common_opts, limit: @subsystem_fact_limit),
      checks: Keyword.merge(common_opts, limit: @subsystem_fact_limit)
    }
  end

  defp subsystem_fact_preset(:integrations, filters) do
    event_opts = subsystem_fact_opts(filters, ~w(project_id since))
    check_opts = subsystem_fact_opts(filters, ~w(project_id surface since))

    %{
      events: Keyword.merge(event_opts, domain: "integration", limit: @subsystem_fact_limit),
      runs: nil,
      checks: Keyword.merge(check_opts, limit: @subsystem_fact_limit)
    }
  end

  defp subsystem_fact_preset(:runners, filters) do
    common_opts =
      filters
      |> subsystem_fact_opts(~w(project_id runner_type runner_id since))
      |> put_default_runner_type()

    %{
      events: Keyword.merge(common_opts, limit: @subsystem_fact_limit, exclude_domain: "audit"),
      runs: Keyword.merge(common_opts, limit: @subsystem_fact_limit),
      checks: nil
    }
  end

  defp subsystem_fact_opts(filters, keys) do
    filters
    |> opts_for(keys -- ["since"])
    |> maybe_put_since(filters)
  end

  defp put_default_runner_type(opts) do
    Keyword.put_new(opts, :runner_type, "mac_mini_provisioner")
  end

  defp list_subsystem_events(socket, org_id, opts) do
    opts =
      opts
      |> maybe_exclude_audit_events(socket)

    Observability.list_events(org_id, opts)
  end

  defp list_subsystem_runs(_org_id, nil), do: []
  defp list_subsystem_runs(org_id, opts), do: Observability.list_operation_runs(org_id, opts)

  defp list_subsystem_checks(_org_id, nil), do: []
  defp list_subsystem_checks(org_id, opts), do: Observability.list_check_results(org_id, opts)

  defp delivery_facts_observed?(%{events: events, runs: runs, checks: checks}) do
    events != [] or runs != [] or checks != []
  end

  defp delivery_postures(projects, facts, filters) do
    projects = filter_delivery_projects(projects, filters)
    # An overview never fans out to every project's Agent owner. Opening one
    # project loads its bounded canonical page; diagnostics remain independently readable.
    agents =
      case projects do
        [project] ->
          case Agents.page_agents(project, limit: 500) do
            {:ok, %{items: items, next_cursor: nil}} -> items
            {:ok, _} -> :paged
            {:error, _} -> :unavailable
          end

        _ ->
          :not_loaded
      end

    Enum.map(projects, &delivery_posture(&1, facts, agents))
  end

  defp filter_delivery_projects(projects, %{"project_id" => project_id})
       when is_binary(project_id) and project_id != "" do
    Enum.filter(projects, &(&1.id == project_id))
  end

  defp filter_delivery_projects(projects, _filters), do: projects

  defp delivery_posture(project, %{events: events, runs: runs, checks: checks}, agents) do
    project_events = Enum.filter(events, &(&1.project_id == project.id))
    project_runs = Enum.filter(runs, &(&1.project_id == project.id))
    project_checks = Enum.filter(checks, &(&1.project_id == project.id))
    latest_event = List.first(project_events)
    latest_integration_check = Enum.find(project_checks, &integration_check?/1)
    latest_integration_event = Enum.find(project_events, &(&1.domain == "integration"))

    {health, health_reason} =
      delivery_health(agents, project_events, project_runs, project_checks)

    %{
      project: project,
      agent_count: if(is_list(agents), do: length(agents)),
      agent_detail: agent_detail(agents),
      conversation_count: delivery_observed_count(project_events, :conversation),
      environment_count: delivery_observed_count(project_events, :device),
      integration_status: integration_status(latest_integration_check, latest_integration_event),
      integration_reason: integration_reason(latest_integration_check, latest_integration_event),
      integration_summary:
        latest_integration_event && integration_event_summary(latest_integration_event),
      integration_event_type:
        latest_integration_event && safe_text(latest_integration_event.event_type, nil),
      latest_event_summary: latest_event_summary(latest_event),
      latest_event_type: latest_event && safe_text(latest_event.event_type, nil),
      health: health,
      health_reason: health_reason
    }
  end

  defp delivery_health(agents, events, runs, checks) do
    cond do
      Enum.any?(events, &(&1.severity == "critical")) ->
        {"critical", gettext("Recent critical delivery event")}

      Enum.any?(runs, &(&1.status == "critical")) ->
        {"critical", gettext("Recent critical delivery run")}

      Enum.any?(checks, &(&1.status == "critical")) ->
        {"critical", gettext("Recent critical delivery check")}

      Enum.any?(events, &(&1.severity == "error")) ->
        {"degraded", gettext("Recent delivery event has errors")}

      Enum.any?(runs, &(&1.status in ["failed", "canceled"])) ->
        {"degraded", gettext("Recent delivery run failed")}

      Enum.any?(checks, &(&1.status == "fail")) ->
        {"degraded", gettext("Recent delivery check failed")}

      Enum.any?(runs, &(&1.status in ["needs_manual", "skipped"])) or
          Enum.any?(checks, &(&1.status in ["needs_manual", "skipped"])) ->
        {"action_required", gettext("Recent delivery facts need manual follow-up")}

      agents == [] ->
        {"unknown", gettext("No active agents")}

      events == [] and runs == [] and checks == [] ->
        {"unknown", gettext("No delivery diagnostics observed")}

      Enum.any?(runs, &(&1.status == "ok")) or Enum.any?(checks, &(&1.status == "ok")) ->
        {"healthy", gettext("Recent delivery checks or runs are ok")}

      true ->
        {"unknown", gettext("No passing delivery check or run observed")}
    end
  end

  defp integration_check?(%{surface: surface}) do
    integration_key_for_surface(surface) in ["feishu", "slack", "sso", "oauth", "models"]
  end

  defp agent_detail(:not_loaded), do: gettext("Open the Agent Swarm to view its current agents")
  defp agent_detail(:unavailable), do: gettext("Agent list unavailable")
  defp agent_detail(:paged), do: gettext("Open the paginated agent list")
  defp agent_detail([]), do: gettext("No active agents")

  defp agent_detail(agents) do
    agents
    |> Enum.frequencies_by(&(&1.role || "unknown"))
    |> Enum.sort_by(fn {role, _count} -> role end)
    |> Enum.map(fn {role, count} -> "#{count} #{safe_text(role)}" end)
    |> Enum.join(", ")
  end

  defp delivery_observed_count(events, kind) do
    events
    |> Enum.flat_map(&delivery_observed_id(&1, kind))
    |> Enum.uniq()
    |> length()
  end

  defp delivery_observed_id(event, :conversation) do
    cond do
      event.conversation_id -> [event.conversation_id]
      event.domain == "conversation" and event.resource_id -> [event.resource_id]
      true -> []
    end
  end

  defp delivery_observed_id(event, :device) do
    cond do
      event.environment_id -> [event.environment_id]
      event.domain == "device" and event.resource_id -> [event.resource_id]
      true -> []
    end
  end

  defp latest_event_summary(nil), do: gettext("No event observed")

  defp latest_event_summary(%{summary: summary}) do
    safe_text(summary, gettext("Diagnostic recorded"))
  end

  defp delivery_count_label(0), do: gettext("none observed")
  defp delivery_count_label(count), do: to_string(count)

  defp runner_postures(runners, facts, filters) do
    runners
    |> filter_runner_posture_rows(filters)
    |> Enum.map(&runner_posture(&1, facts))
  end

  defp runner_fleet_page(socket, org_id, filters) do
    cond do
      filters["runner_type"] not in [nil, "", "mac_mini_provisioner"] ->
        %{entries: [], next_cursor: nil, total_count: 0, cursor: nil}

      is_binary(filters["runner_id"]) and filters["runner_id"] != "" ->
        entries = Enum.filter(socket.assigns.runners, &(&1.id == filters["runner_id"]))
        %{entries: entries, next_cursor: nil, total_count: length(entries), cursor: nil}

      true ->
        page_runner_fleet(org_id, filters["runner_cursor"], length(socket.assigns.runners))
    end
  end

  defp page_runner_fleet(org_id, cursor, total_count) do
    page =
      Environments.page_mac_mini_provisioners(org_id,
        limit: @runner_fleet_page_limit,
        after: cursor,
        total_count: total_count
      )

    if page.entries == [] and page.total_count > 0 and cursor not in [nil, ""] do
      org_id
      |> Environments.page_mac_mini_provisioners(
        limit: @runner_fleet_page_limit,
        total_count: total_count
      )
      |> Map.put(:cursor, nil)
    else
      Map.put(page, :cursor, cursor)
    end
  end

  defp filter_runner_posture_rows(_runners, %{"runner_type" => runner_type})
       when is_binary(runner_type) and runner_type not in ["", "mac_mini_provisioner"],
       do: []

  defp filter_runner_posture_rows(runners, %{"runner_id" => runner_id})
       when is_binary(runner_id) and runner_id != "" do
    Enum.filter(runners, &(&1.id == runner_id))
  end

  defp filter_runner_posture_rows(runners, _filters), do: runners

  defp runner_posture(runner, %{events: events, runs: runs}) do
    runner_events = Enum.filter(events, &runner_fact_for_runner?(&1, runner))
    runner_runs = Enum.filter(runs, &runner_fact_for_runner?(&1, runner))
    latest_event = List.first(runner_events)
    latest_run = List.first(runner_runs)
    runner_filters = %{runner_type: "mac_mini_provisioner", runner_id: runner.id}

    %{
      runner: runner,
      status: runner_status(runner),
      status_reason: runner_status_reason(runner),
      component_postures: runner_component_postures(runner),
      latest_event_summary: latest_event_summary(latest_event),
      latest_event_type: latest_event && safe_text(latest_event.event_type, nil),
      latest_run_status: latest_run && safe_text(latest_run.status, "unknown"),
      latest_run_summary: latest_run_summary(latest_run),
      event_filters: runner_filters,
      run_filters: runner_filters
    }
  end

  defp runner_fact_for_runner?(
         %{runner_type: "mac_mini_provisioner", runner_id: runner_id},
         runner
       ),
       do: runner_id == runner.id

  defp runner_fact_for_runner?(_fact, _runner), do: false

  defp runner_status_reason(runner) do
    status = runner_status(runner)
    age = last_seen_age(runner)

    cond do
      runner.last_seen_age_seconds in [nil, ""] ->
        gettext("No heartbeat observed")

      status == "online" ->
        gettext("Heartbeat %{age}", age: age)

      status in ["recently_lost", "stale", "unknown"] ->
        gettext("Heartbeat delayed: %{age}", age: age)

      status in ["offline", "failed", "error", "critical"] ->
        gettext("Runner reported %{status}; heartbeat %{age}",
          status: safe_text(runner.status, status),
          age: age
        )

      true ->
        gettext("Heartbeat %{age}", age: age)
    end
  end

  defp runner_component_postures(runner) do
    [
      %{
        label: gettext("Runner"),
        status: runner_status(runner),
        detail: runner_provisioner_detail(runner)
      },
      runner_component_posture(runner, "salix-connect"),
      runner_component_posture(runner, "agent-vmm-host")
    ]
  end

  defp runner_provisioner_detail(%{version: version}) do
    case safe_text(version, nil) do
      nil -> gettext("version not reported")
      version -> gettext("version %{version}", version: version)
    end
  end

  defp runner_component_posture(runner, "salix-connect" = component) do
    target = MacMiniRelease.updates(nil, runner)[component]

    if MacMiniRelease.component_update_available?(runner.capabilities, component, target) do
      %{
        label: component,
        status: "degraded",
        detail: gettext("Server-bound update available")
      }
    else
      runner_component_posture_default(runner, component)
    end
  end

  defp runner_component_posture(runner, "agent-vmm-host" = component) do
    target = MacMiniRelease.updates(nil, runner)["agent-vmm"]

    if MacMiniRelease.component_update_available?(runner.capabilities, component, target) do
      %{
        label: component,
        status: "degraded",
        detail: gettext("Administrator-selected update available")
      }
    else
      runner_component_posture_default(runner, component)
    end
  end

  defp runner_component_posture(runner, component) do
    runner_component_posture_default(runner, component)
  end

  defp runner_component_posture_default(runner, component) do
    version = runner_component_version(runner, component)
    capability = runner_component_capability(runner, component)

    status =
      cond do
        version -> "ready"
        capability -> "ready"
        true -> "unknown"
      end

    detail =
      cond do
        version ->
          "#{component}=#{version}"

        capability ->
          safe_text(capability, nil)

        true ->
          gettext("not observed")
      end

    %{label: component, status: status, detail: detail}
  end

  defp runner_component_version(%{capabilities: capabilities}, component)
       when is_map(capabilities) do
    MacMiniRelease.observed_component_version(capabilities, component)
  end

  defp runner_component_version(_runner, _component), do: nil

  defp runner_component_capability(%{capabilities: capabilities}, component)
       when is_map(capabilities) do
    underscored = String.replace(component, "-", "_")

    capabilities
    |> Map.get(component, Map.get(capabilities, underscored))
    |> safe_text(nil)
  end

  defp runner_component_capability(_runner, _component), do: nil

  defp latest_run_summary(nil), do: nil

  defp latest_run_summary(run) do
    [
      safe_text(run.run_type, gettext("Run")),
      safe_text(run.external_run_id, short_id(run.id)),
      run.environment_id && gettext("env %{id}", id: short_id(run.environment_id)),
      run.reason_class && humanize_reason(run.reason_class)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp assign_runners(socket) do
    runners = Environments.list_mac_mini_provisioners(socket.assigns.current_org.id)

    socket =
      socket
      |> assign(:runners, runners)
      |> assign_observability()

    assign(
      socket,
      :summary,
      summary(
        socket.assigns.projects,
        runners,
        socket.assigns.events,
        socket.assigns.runs,
        socket.assigns.checks,
        socket.assigns.audit_logs,
        socket.assigns.health_summary
      )
    )
  end

  defp schedule_runner_refresh(socket) do
    if connected?(socket) do
      case socket.assigns[:runner_refresh_ref] do
        nil ->
          assign(
            socket,
            :runner_refresh_ref,
            Process.send_after(self(), :refresh_operations_runners, @runner_refresh_interval_ms)
          )

        _ref ->
          socket
      end
    else
      socket
    end
  end

  defp health_reason_text(:no_operations_facts),
    do: gettext("No persisted Operations facts have been observed yet.")

  defp health_reason_text(:observability_unavailable),
    do: gettext("Operations data could not be loaded.")

  defp health_reason_text(:projects_without_runners),
    do: gettext("Agent Swarms exist, but no runner is connected.")

  defp health_reason_text(:critical_runner_status),
    do: gettext("At least one runner reports a critical status.")

  defp health_reason_text(:runner_offline_or_failed),
    do: gettext("At least one runner is offline or failed.")

  defp health_reason_text(:runner_stale_or_unknown),
    do: gettext("At least one runner heartbeat is stale or unknown.")

  defp health_reason_text(:critical_events),
    do: gettext("Recent operational events include critical alerts.")

  defp health_reason_text(:error_events),
    do: gettext("Recent operational events include errors.")

  defp health_reason_text(:critical_runs),
    do: gettext("Recent bounded execution runs include critical failures.")

  defp health_reason_text(:failed_or_canceled_runs),
    do: gettext("Recent bounded execution runs failed or were canceled.")

  defp health_reason_text(:critical_checks),
    do: gettext("Recent check snapshots include critical failures.")

  defp health_reason_text(:failed_checks),
    do: gettext("Recent check snapshots include failures.")

  defp health_reason_text(:manual_or_skipped_runs),
    do: gettext("Recent runs need manual follow-up or were skipped.")

  defp health_reason_text(:manual_or_skipped_checks),
    do: gettext("Recent checks need manual follow-up or were skipped.")

  defp health_reason_text(:checks_healthy),
    do: gettext("Latest check snapshots are healthy.")

  defp health_reason_text(:signals_partial),
    do:
      gettext(
        "Signals are partial; Operations keeps the status degraded until required facts arrive."
      )

  defp health_reason_text(_reason),
    do:
      gettext(
        "Signals are partial; Operations keeps the status degraded until required facts arrive."
      )

  defp health_badge_color("critical"), do: "red"
  defp health_badge_color("unknown"), do: "neutral"
  defp health_badge_color("action_required"), do: "amber"
  defp health_badge_color("degraded"), do: "amber"
  defp health_badge_color("healthy"), do: "green"
  defp health_badge_color(_), do: "neutral"

  defp severity_color("critical"), do: "red"
  defp severity_color("error"), do: "red"
  defp severity_color("warning"), do: "amber"
  defp severity_color(_), do: "neutral"

  defp safe_text(value, fallback \\ "—")

  defp safe_text(value, fallback) when value in [nil, ""], do: fallback

  defp safe_text(value, fallback) do
    case Observability.redact_payload(value) do
      value when value in [nil, ""] ->
        fallback

      value when is_binary(value) ->
        value

      value when is_integer(value) or is_float(value) or is_boolean(value) ->
        to_string(value)

      _other ->
        @redacted_display
    end
  end

  defp status_label(status) do
    status
    |> safe_text(gettext("unknown"))
    |> String.replace("_", " ")
    |> String.replace("-", " ")
  end

  defp check_subject_label(%{subject_type: "project", subject_id: subject_id}, project_names) do
    project_names
    |> Map.get(subject_id, subject_id || gettext("Project"))
    |> safe_text(gettext("Project"))
  end

  defp check_subject_label(%{subject_id: subject_id}, _project_names)
       when is_binary(subject_id) do
    safe_text(subject_id)
  end

  defp check_subject_label(_check, _project_names), do: gettext("Organization")

  defp run_project_label(%{project_id: project_id}, project_names)
       when is_binary(project_id) and project_id != "" do
    project_names
    |> Map.get(project_id, short_id(project_id))
    |> safe_text(short_id(project_id))
  end

  defp run_project_label(_run, _project_names), do: gettext("Organization")

  defp run_duration(%{duration_ms: duration_ms}) when is_integer(duration_ms),
    do: "#{duration_ms}ms"

  defp run_duration(_run), do: "—"

  defp check_gate_summary(%{result: %{"gates" => gates}}) when is_list(gates) do
    case gates do
      [] ->
        gettext("No gates recorded")

      gates ->
        gates = GateContract.normalize_gates(gates)
        required_gates = Enum.filter(gates, &GateContract.required?/1)

        failing_gate =
          Enum.find(required_gates, fn gate ->
            Map.get(gate, "status") in ["fail", "needs_manual", "skipped"]
          end)

        gate = failing_gate || List.first(required_gates) || hd(gates)

        label =
          gate
          |> Map.get("label", Map.get(gate, "gate_id"))
          |> safe_text(gettext("Gate"))

        status = Map.get(gate, "status") || "unknown"
        "#{label} - #{status_label(status)}"
    end
  end

  defp check_gate_summary(_check), do: gettext("No gates recorded")

  defp check_gate_count(%{"gates" => gates}) when is_list(gates), do: length(gates)
  defp check_gate_count(%{gates: gates}) when is_list(gates), do: length(gates)
  defp check_gate_count(_result), do: nil

  defp integration_postures(socket, checks, events) do
    Enum.map(@integration_groups, fn group ->
      group_checks =
        Enum.filter(checks, &(integration_key_for_surface(&1.surface) == group.key))

      group_events =
        Enum.filter(events, &(integration_key_for_event(&1) == group.key))

      latest_check = List.first(group_checks)
      latest_event = List.first(group_events)
      status = integration_status(latest_check, latest_event)

      %{
        key: group.key,
        label: group.label,
        status: status,
        reason_class: integration_reason(latest_check, latest_event),
        surface_label: integration_surface_label(latest_check, group),
        check_summary: integration_check_summary(latest_check),
        check_ran_at: latest_check && latest_check.ran_at,
        invocation_id: latest_check && safe_text(latest_check.invocation_id, nil),
        event_summary: integration_event_summary(latest_event),
        event_type: latest_event && safe_text(latest_event.event_type, nil),
        check_filters: integration_check_filters(latest_check, group),
        owner_path: integration_owner_path(socket.assigns.current_org, latest_check, group)
      }
    end)
  end

  defp integration_status(nil, nil), do: "unknown"

  defp integration_status(%{status: status}, _event)
       when status in ["fail", "needs_manual", "skipped"],
       do: status

  defp integration_status(_check, %{severity: severity}) when severity in ["error", "critical"],
    do: "fail"

  defp integration_status(_check, %{severity: "warning"}), do: "needs_manual"
  defp integration_status(%{status: status}, _event) when is_binary(status), do: status
  defp integration_status(_check, _event), do: "unknown"

  defp integration_reason(%{reason_class: reason}, _event)
       when is_binary(reason) and reason != "",
       do: reason

  defp integration_reason(_check, %{reason_class: reason})
       when is_binary(reason) and reason != "",
       do: reason

  defp integration_reason(_check, _event), do: nil

  defp integration_surface_label(%{surface: surface}, _group)
       when is_binary(surface) and surface != "",
       do: safe_text(surface)

  defp integration_surface_label(_check, group), do: group.default_surface

  defp integration_check_summary(nil), do: gettext("No check result recorded")
  defp integration_check_summary(check), do: check_gate_summary(check)

  defp integration_event_summary(nil), do: gettext("No runtime diagnostic recorded")

  defp integration_event_summary(%{summary: summary}) when is_binary(summary) and summary != "",
    do: safe_text(summary, gettext("Diagnostic recorded"))

  defp integration_event_summary(_event), do: gettext("Diagnostic recorded")

  defp integration_check_filters(%{surface: surface}, _group)
       when is_binary(surface) and surface != "",
       do: %{surface: surface}

  defp integration_check_filters(_check, group), do: %{surface: group.default_surface}

  defp integration_owner_path(org, %{project_id: project_id}, _group)
       when is_binary(project_id) and project_id != "" do
    ~p"/orgs/#{org.slug}/projects/#{project_id}"
  end

  defp integration_owner_path(org, _check, group) do
    ~p"/orgs/#{org.slug}/settings" <> "##{group.settings_anchor}"
  end

  defp integration_key_for_surface(surface) when is_binary(surface) do
    surface
    |> String.downcase()
    |> case do
      value when value in ["bot", "feishu", "feishu_bot", "feishu-connect"] -> "feishu"
      value when value in ["slack", "slack_calendar", "slack-calendar"] -> "slack"
      value when value in ["sso", "saml", "oidc"] -> "sso"
      value when value in ["oauth", "oauth_app", "oauth-provider"] -> "oauth"
      value when value in ["model", "models", "model_provider", "model-provider"] -> "models"
      value -> value
    end
  end

  defp integration_key_for_surface(_surface), do: nil

  defp integration_key_for_event(%{domain: domain} = event) do
    event_text =
      [
        domain,
        event.resource_type,
        event.source,
        event.event_type
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      domain != "integration" -> nil
      String.contains?(event_text, "feishu") or String.contains?(event_text, "bot") -> "feishu"
      String.contains?(event_text, "sso") -> "sso"
      String.contains?(event_text, "oauth") -> "oauth"
      String.contains?(event_text, "model") or String.contains?(event_text, "llm") -> "models"
      true -> nil
    end
  end

  defp integrations_unknown?(postures), do: Enum.all?(postures, &(&1.status == "unknown"))

  defp audit_actor_label(audit) do
    safe_text(Map.get(audit, :actor_label), nil) ||
      short_id(Map.get(audit, :actor_user_id)) ||
      safe_text(Map.get(audit, :actor_type), nil) ||
      gettext("system")
  end

  defp audit_resource_label(audit) do
    safe_text(Map.get(audit, :resource_label), nil) ||
      safe_text(Map.get(audit, :resource_id), nil) ||
      safe_text(Map.get(audit, :target), nil) ||
      gettext("Resource")
  end

  defp humanize_reason(reason) do
    reason
    |> safe_text(gettext("unknown"))
    |> String.replace("_", " ")
    |> String.replace("-", " ")
  end

  defp short_id(id) when id in [nil, ""], do: nil

  defp short_id(id) do
    id = safe_text(id, nil)

    cond do
      id in [nil, ""] -> nil
      id == @redacted_display -> id
      byte_size(id) > 12 -> String.slice(id, 0, 8) <> "..."
      true -> id
    end
  end

  defp project_names(projects) do
    Map.new(projects, fn project -> {project.id, project.name} end)
  end

  defp event_filter_fields(projects, can_view_audit?) do
    [
      select_field("domain", gettext("Domain"), domain_options(can_view_audit?)),
      select_field("severity", gettext("Severity"), severity_options()),
      text_field("source", gettext("Source"), "bft.dashboard"),
      text_field("event_type", gettext("Event type"), "run_checks.completed"),
      text_field("status", gettext("Status"), "failed"),
      text_field("reason_class", gettext("Reason"), "scope_batch_required"),
      select_field("project_id", gettext("Agent Swarm"), project_options(projects)),
      text_field("resource_type", gettext("Resource type"), "project"),
      text_field("resource_id", gettext("Resource id"), "resource-id"),
      text_field("correlation_id", gettext("Correlation"), "request-id"),
      text_field("since", gettext("Since"), "YYYY-MM-DDT00:00:00Z")
    ]
  end

  defp check_filter_fields(projects) do
    [
      text_field("check_family", gettext("Family"), "run_checks"),
      select_field("surface", gettext("Surface"), check_surface_options()),
      select_field("status", gettext("Status"), check_status_options()),
      select_field("gate_status", gettext("Gate status"), check_status_options()),
      select_field("project_id", gettext("Agent Swarm"), project_options(projects)),
      text_field("subject_type", gettext("Subject type"), "project"),
      text_field("subject_id", gettext("Subject id"), "subject-id"),
      text_field("since", gettext("Since"), "YYYY-MM-DDT00:00:00Z")
    ]
  end

  defp audit_filter_fields do
    [
      text_field("actor_user_id", gettext("Actor id"), "user-id"),
      text_field("action", gettext("Action"), "settings.sso.updated"),
      text_field("resource_type", gettext("Resource type"), "sso"),
      text_field("resource_id", gettext("Resource id"), "resource-id"),
      select_field("result", gettext("Result"), audit_result_options()),
      text_field("request_id", gettext("Request id"), "request-id"),
      text_field("since", gettext("Since"), "YYYY-MM-DDT00:00:00Z")
    ]
  end

  defp select_field(key, label, options) do
    %{type: :select, key: key, label: label, prompt: gettext("Any"), options: options}
  end

  defp text_field(key, label, placeholder) do
    %{type: :text, key: key, label: label, placeholder: placeholder}
  end

  defp domain_options(can_view_audit?) do
    [
      {"org", "org"},
      {"project", "project"},
      {"agent", "agent"},
      {"conversation", "conversation"},
      {"schedule", "schedule"},
      {"integration", "integration"},
      {"sso", "sso"},
      {"oauth", "oauth"},
      {"model", "model"},
      {"device", "device"},
      {"runner", "runner"},
      {"check", "check"}
    ]
    |> maybe_add_audit_domain(can_view_audit?)
  end

  defp maybe_add_audit_domain(options, true), do: options ++ [{"audit", "audit"}]
  defp maybe_add_audit_domain(options, _can_view_audit?), do: options

  defp severity_options do
    [{"info", "info"}, {"warning", "warning"}, {"error", "error"}, {"critical", "critical"}]
  end

  defp check_surface_options do
    [{"bot", "bot"}, {"sso", "sso"}, {"oauth", "oauth"}, {"models", "models"}]
  end

  defp check_status_options do
    [
      {"ok", "ok"},
      {"fail", "fail"},
      {"needs_manual", "needs_manual"},
      {"skipped", "skipped"}
    ]
  end

  defp audit_result_options do
    [{"ok", "ok"}, {"failed", "failed"}, {"denied", "denied"}, {"unknown", "unknown"}]
  end

  defp project_options(projects) do
    Enum.map(projects, fn project -> {safe_text(project.name), project.id} end)
  end

  defp assign_filters(socket, params) do
    filters =
      @filter_keys
      |> Enum.reduce(%{}, fn key, acc ->
        case normalize_filter(params[key]) do
          nil -> acc
          value -> Map.put(acc, key, value)
        end
      end)

    socket
    |> assign(:filters, filters)
    |> assign(:filter_summary, filter_summary(filters, socket.assigns.project_names))
  end

  defp normalize_filter(nil), do: nil
  defp normalize_filter(""), do: nil
  defp normalize_filter(value), do: value

  defp normalize_form_filters(raw_filters, allowed_keys) when is_map(raw_filters) do
    allowed_keys = MapSet.new(allowed_keys)

    raw_filters
    |> Enum.reduce(%{}, fn {key, value}, filters ->
      if MapSet.member?(allowed_keys, key) do
        case normalize_filter(value) do
          nil -> filters
          value -> Map.put(filters, key, value)
        end
      else
        filters
      end
    end)
  end

  defp normalize_form_filters(_raw_filters, _allowed_keys), do: %{}

  defp filter_keys_for_tab(:events) do
    ~w(domain severity source event_type status reason_class project_id resource_type resource_id correlation_id since run_record_id check_result_id audit_log_id)
  end

  defp filter_keys_for_tab(:checks) do
    ~w(check_result_id check_family surface status gate_status project_id subject_type subject_id since)
  end

  defp filter_keys_for_tab(:audit) do
    ~w(audit_log_id actor_user_id action resource_type resource_id result request_id since)
  end

  defp filter_keys_for_tab(:runners) do
    ~w(run_record_id run_type status project_id runner_type runner_id external_run_id request_id since)
  end

  defp filter_keys_for_tab(_tab), do: @filter_keys

  defp filter_summary(filters, project_names) do
    filters
    |> Map.delete("cursor")
    |> Map.delete("runner_cursor")
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> filter_label(key, value, project_names) end)
  end

  defp filter_label("project_id", value, project_names),
    do: "project=#{Map.get(project_names, value, short_id(value)) |> safe_text(short_id(value))}"

  defp filter_label(key, value, _project_names), do: "#{key}=#{safe_text(value)}"

  defp event_opts(socket, filters) do
    filters
    |> opts_for(
      ~w(domain severity source event_type status reason_class project_id resource_type resource_id run_record_id check_result_id audit_log_id correlation_id)
    )
    |> maybe_exclude_audit_events(socket)
    |> Keyword.put(:limit, @observability_limit)
    |> maybe_put_cursor(filters)
    |> maybe_put_since(filters)
  end

  defp maybe_exclude_audit_events(opts, %{assigns: %{can_view_audit: true}}), do: opts
  defp maybe_exclude_audit_events(opts, _socket), do: Keyword.put(opts, :exclude_domain, "audit")

  defp run_opts(filters) do
    filters
    |> opts_for(
      ~w(run_record_id run_type status project_id runner_type runner_id external_run_id request_id)
    )
    |> Keyword.put(:limit, @observability_limit)
    |> maybe_put_cursor(filters)
    |> maybe_put_since(filters)
  end

  defp check_opts(filters) do
    filters
    |> opts_for(
      ~w(check_result_id check_family surface status gate_status project_id subject_type subject_id)
    )
    |> Keyword.put(:limit, @observability_limit)
    |> maybe_put_cursor(filters)
    |> maybe_put_since(filters)
  end

  defp audit_opts(filters) do
    filters
    |> opts_for(~w(audit_log_id actor_user_id action resource_type resource_id result request_id))
    |> Keyword.put(:limit, @observability_limit)
    |> maybe_put_cursor(filters)
    |> maybe_put_since(filters)
  end

  defp opts_for(filters, keys) do
    Enum.reduce(keys, [], fn key, opts ->
      case Map.get(filters, key) do
        nil -> opts
        value -> Keyword.put(opts, String.to_existing_atom(key), value)
      end
    end)
  end

  defp maybe_put_since(opts, %{"since" => since}) do
    case DateTime.from_iso8601(since) do
      {:ok, datetime, _offset} -> Keyword.put(opts, :since, datetime)
      _ -> opts
    end
  end

  defp maybe_put_since(opts, _filters), do: opts

  defp maybe_put_cursor(opts, %{"cursor" => cursor}) when is_binary(cursor) and cursor != "",
    do: Keyword.put(opts, :after, cursor)

  defp maybe_put_cursor(opts, _filters), do: opts

  defp audit_page(%{assigns: %{can_view_audit: true}}, org_id, filters),
    do: Observability.page_audit_logs(org_id, audit_opts(filters))

  defp audit_page(_socket, _org_id, _filters), do: %{entries: [], next_cursor: nil}

  defp operations_tab_path(org, :overview, params),
    do: ~p"/orgs/#{org.slug}/operations?#{compact_query_params(params)}"

  defp operations_tab_path(org, :delivery, params),
    do: ~p"/orgs/#{org.slug}/operations/delivery?#{compact_query_params(params)}"

  defp operations_tab_path(org, :integrations, params),
    do: ~p"/orgs/#{org.slug}/operations/integrations?#{compact_query_params(params)}"

  defp operations_tab_path(org, :runners, params),
    do: ~p"/orgs/#{org.slug}/operations/runners?#{compact_query_params(params)}"

  defp operations_tab_path(org, :events, params),
    do: ~p"/orgs/#{org.slug}/operations/events?#{compact_query_params(params)}"

  defp operations_tab_path(org, :checks, params),
    do: ~p"/orgs/#{org.slug}/operations/checks?#{compact_query_params(params)}"

  defp operations_tab_path(org, :audit, params),
    do: ~p"/orgs/#{org.slug}/operations/audit?#{compact_query_params(params)}"

  defp audit_export_path(org, filters) do
    ~p"/orgs/#{org.slug}/operations/audit.csv?#{compact_query_params(nav_filters(filters))}"
  end

  defp compact_query_params(params) when is_map(params) do
    Map.reject(params, fn {_key, value} -> value in [nil, ""] end)
  end

  defp nav_filters(filters), do: Map.drop(filters, ["cursor", "runner_cursor"])

  defp next_page_path(org, tab, filters, cursor) do
    operations_tab_path(org, tab, Map.put(filters, "cursor", cursor))
  end

  defp runner_fleet_next_page_path(org, filters, cursor) do
    filters =
      filters
      |> Map.delete("cursor")
      |> Map.put("runner_cursor", cursor)

    operations_tab_path(org, :runners, filters)
  end

  defp runner_fleet_first_page_path(org, filters) do
    operations_tab_path(org, :runners, Map.drop(filters, ["cursor", "runner_cursor"]))
  end

  defp tab_label(:delivery), do: gettext("Delivery")
  defp tab_label(:integrations), do: gettext("Integrations")
  defp tab_label(:runners), do: gettext("Runners")
  defp tab_label(:events), do: gettext("Events")
  defp tab_label(:checks), do: gettext("Checks")
  defp tab_label(:audit), do: gettext("Audit")
  defp tab_label(_), do: gettext("Overview")

  defp can_manage_operations?(role), do: role in ["owner", "admin"]
  defp can_view_operations?(role), do: role in ["owner", "admin"]
  defp can_view_audit?(role), do: role in ["owner", "admin"]

  defp visible_tabs(role) when role in ["owner", "admin"], do: @tabs
  defp visible_tabs(_role), do: Enum.reject(@tabs, &(&1 == :audit))

  defp runner_name(%{name: name, stable_id: stable_id}) do
    cond do
      safe_text(name, nil) -> safe_text(name, nil)
      safe_text(stable_id, nil) -> safe_text(stable_id, nil)
      true -> "Runner"
    end
  end

  defp runner_capacity(%{capacity: capacity, current_connector_count: current}) do
    "#{current || 0} / #{capacity || 0}"
  end

  defp runner_status(%{effective_status: status}) when is_binary(status) and status != "",
    do: status

  defp runner_status(%{status: status}) when is_binary(status) and status != "", do: status
  defp runner_status(_), do: "unknown"

  defp blank_dash(value), do: safe_text(value)

  defp format_datetime(nil), do: "—"

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  defp last_seen_age(%{last_seen_age_seconds: nil}), do: gettext("never seen")
  defp last_seen_age(%{last_seen_age_seconds: seconds}), do: last_seen_age(seconds)

  defp last_seen_age(seconds) when is_integer(seconds) and seconds < 60 do
    ngettext("%{count}s ago", "%{count}s ago", seconds)
  end

  defp last_seen_age(seconds) when is_integer(seconds) and seconds < 3600 do
    minutes = div(seconds, 60)
    ngettext("%{count}m ago", "%{count}m ago", minutes)
  end

  defp last_seen_age(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    ngettext("%{count}h ago", "%{count}h ago", hours)
  end

  defp last_seen_age(_), do: gettext("never seen")
end
