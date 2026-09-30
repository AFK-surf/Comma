defmodule BridgeForTeamsWeb.Dashboard.HomeLive do
  @moduledoc """
  The authenticated workspace overview (`/orgs/:org`), with `/` as the landing
  alias for the user's first organization. It reads the user's orgs and loads
  analytics for the selected organization through the `BridgeForTeams.*`
  contexts in-process.

  Owned by slice "orgs-shell".
  """
  use BridgeForTeamsWeb.Dashboard, :live_view

  require Logger

  alias BridgeForTeams.{Analytics, DashboardProjection, Memberships, Orgs, Projects}

  @summary_async :home_summary

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user
    orgs = Orgs.list_orgs_for_user(user.id)
    requested_slug = params["org"]
    current_org = resolve_current_org(requested_slug, orgs)

    if requested_slug && is_nil(current_org) do
      {:ok,
       socket
       |> assign(:orgs, orgs)
       |> put_flash(:error, gettext("Organization not found."))
       |> push_navigate(to: ~p"/orgs")}
    else
      mount_overview(socket, user, orgs, current_org)
    end
  end

  defp mount_overview(socket, user, orgs, current_org) do
    current_org_role = current_org_role(current_org, user.id)

    socket =
      socket
      |> assign(:page_title, gettext("Home"))
      |> assign(:active_nav, :overview)
      |> assign(:breadcrumbs, [{gettext("Home"), nil}])
      |> assign(:current_org, current_org)
      |> assign(:current_org_role, current_org_role)
      |> assign(:orgs, orgs)
      |> assign(:org_count, length(orgs))
      |> assign(:summary, empty_summary())
      |> assign(:summary_status, summary_status(current_org))
      |> maybe_load_summary(current_org, user)

    if connected?(socket) do
      subscribe_and_enqueue_projection_refreshes(current_org, user)
    end

    {:ok, socket}
  end

  defp resolve_current_org(nil, orgs), do: List.first(orgs)
  defp resolve_current_org(slug, orgs), do: Enum.find(orgs, &(&1.slug == slug))

  @impl true
  def handle_async(@summary_async, {:ok, summary}, socket) do
    {:noreply, assign(socket, summary: summary, summary_status: summary_status_from(summary))}
  end

  def handle_async(@summary_async, {:exit, reason}, socket) do
    Logger.warning("home summary analytics failed: #{inspect(reason)}")

    {:noreply, assign(socket, summary: empty_summary(), summary_status: :failed)}
  end

  @impl true
  def handle_info({:dashboard_projection_refreshed, _project_id}, socket) do
    {:noreply, reload_summary(socket)}
  end

  defp summary_status(nil), do: :ready
  defp summary_status(_org), do: :loading

  defp maybe_load_summary(socket, nil, _user), do: socket

  defp maybe_load_summary(socket, org, user) do
    if connected?(socket) do
      start_async(socket, @summary_async, fn -> Analytics.org_home_summary(org.id, user.id) end)
    else
      socket
    end
  end

  defp reload_summary(%{assigns: %{current_org: nil}} = socket), do: socket

  defp reload_summary(socket) do
    summary =
      Analytics.org_home_summary(socket.assigns.current_org.id, socket.assigns.current_user.id)

    assign(socket, summary: summary, summary_status: summary_status_from(summary))
  end

  defp subscribe_and_enqueue_projection_refreshes(nil, _user), do: :ok

  defp subscribe_and_enqueue_projection_refreshes(org, user) do
    org.id
    |> Projects.list_projects_for_user(user.id)
    |> Enum.each(fn project ->
      DashboardProjection.subscribe(project.id)

      if DashboardProjection.stale_or_missing?(project) do
        DashboardProjection.enqueue_refresh(project)
      end
    end)
  end

  defp summary_status_from(%{project_usage_rows: rows}) when is_list(rows) do
    if Enum.any?(rows, &(&1.snapshot_status == :error)), do: :failed, else: :ready
  end

  defp summary_status_from(_summary), do: :ready

  defp current_org_role(nil, _user_id), do: nil

  defp current_org_role(org, user_id) do
    case Memberships.org_role(org.id, user_id) do
      {:ok, role} -> role
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-lg font-semibold">{gettext("Welcome back")}{user_suffix(@current_user)}</h1>
        <p class="text-sm text-neutral-500">{gettext("Here's an overview of your workspace.")}</p>
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <.card>
          <:title>{gettext("Organizations")}</:title>
          <div class="flex items-baseline gap-2">
            <span class="text-2xl font-semibold">{@org_count}</span>
            <.link navigate={~p"/orgs"} class="text-xs text-brand-600 hover:underline">{gettext("View all")}</.link>
          </div>
        </.card>

        <.card>
          <:title>{gettext("Agent Swarms")}{org_scope(@current_org)}</:title>
          <div class="flex items-baseline gap-2">
            <span class="text-2xl font-semibold">{summary_value(@summary.project_count, @summary_status)}</span>
            <.link :if={@current_org} navigate={~p"/orgs/#{@current_org.slug}/projects"} class="text-xs text-brand-600 hover:underline">
              {gettext("View agent swarms")}
            </.link>
          </div>
        </.card>
      </div>

      <div :if={@current_org} id="home-statistics" class="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <.card class="overflow-hidden">
          <:title>{gettext("Agent Swarm activity")}</:title>
          <:actions>
            <span class="text-xs text-neutral-500">{summary_label(@summary_status, gettext("Created vs used"))}</span>
          </:actions>
          <div class="space-y-4">
            <div class="grid grid-cols-2 gap-3">
              <.stat_tile label={gettext("Created")} value={summary_value(@summary.project_count, @summary_status)} />
              <.stat_tile label={gettext("Used")} value={summary_value(@summary.used_project_count, @summary_status)} />
            </div>

            <div class="space-y-3" aria-label="Agent Swarm activity chart">
              <.bar_row
                label={gettext("Created")}
                value={summary_value(@summary.project_count, @summary_status)}
                percent={bar_percent(@summary.project_count, @summary.project_count)}
                tone="brand"
              />
              <.bar_row
                label={gettext("Used")}
                value={summary_value(@summary.used_project_count, @summary_status)}
                percent={bar_percent(@summary.used_project_count, @summary.project_count)}
                tone="green"
              />
              <.bar_row
                label={gettext("Unused")}
                value={summary_value(@summary.unused_project_count, @summary_status)}
                percent={bar_percent(@summary.unused_project_count, @summary.project_count)}
                tone="neutral"
              />
            </div>
          </div>
        </.card>

        <.card class="overflow-hidden">
          <:title>{gettext("Token usage")}</:title>
          <:actions>
            <span class="text-xs text-neutral-500">{summary_label(@summary_status, gettext("Recorded tasks"))}</span>
          </:actions>
          <div class="space-y-4">
            <div class="grid grid-cols-2 gap-3">
              <.stat_tile label={gettext("Total tokens")} value={summary_value(format_number(@summary.token_totals.total), @summary_status)} />
              <.stat_tile label={gettext("Tasks")} value={summary_value(@summary.conversation_count, @summary_status)} />
            </div>

            <div class="space-y-3" aria-label="Token usage chart">
              <.bar_row
                label={gettext("Input")}
                value={summary_value(format_number(@summary.token_totals.input), @summary_status)}
                percent={bar_percent(@summary.token_totals.input, visible_token_total(@summary))}
                tone="brand"
              />
              <.bar_row
                label={gettext("Output")}
                value={summary_value(format_number(@summary.token_totals.output), @summary_status)}
                percent={bar_percent(@summary.token_totals.output, visible_token_total(@summary))}
                tone="amber"
              />
              <.bar_row
                label={gettext("Cache")}
                value={
                  summary_value(
                    format_number(@summary.token_totals.cache_read + @summary.token_totals.cache_write),
                    @summary_status
                  )
                }
                percent={
                  bar_percent(
                    @summary.token_totals.cache_read + @summary.token_totals.cache_write,
                    visible_token_total(@summary)
                  )
                }
                tone="neutral"
              />
            </div>
          </div>
        </.card>
      </div>

      <div :if={@current_org && @summary.project_usage_rows != []} id="project-usage-breakdown">
        <.card>
          <:title>{gettext("Top Agent Swarm usage")}</:title>
          <div class="space-y-3">
            <div :for={row <- @summary.project_usage_rows} class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3 rounded-md border border-neutral-200 px-3 py-2">
              <div class="min-w-0">
                <div class="truncate text-sm font-medium text-neutral-800">{row.name}</div>
                <div class="text-xs text-neutral-500">{ngettext("%{count} task", "%{count} tasks", row.conversation_count)}</div>
              </div>
              <div class="text-right">
                <div class="text-sm font-semibold text-neutral-900">{format_number(row.token_usage.total)}</div>
                <div class="text-xs text-neutral-500">{gettext("tokens")}</div>
              </div>
            </div>
          </div>
        </.card>
      </div>

      <.empty_state
        :if={@org_count == 0}
        icon="building-office"
        title={gettext("No organizations yet")}
        description={gettext("Use an invite code to create a new organization, or ask an administrator to add you to an existing one.")}
      >
        <:actions>
          <.button variant="primary" navigate={~p"/orgs"}>{gettext("Browse organizations")}</.button>
        </:actions>
      </.empty_state>
    </div>
    """
  end

  defp user_suffix(%{name: name}) when is_binary(name) and name != "", do: ", #{name}"
  defp user_suffix(_), do: ""

  defp org_scope(nil), do: ""
  defp org_scope(%{name: name}), do: " · #{name}"

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  defp stat_tile(assigns) do
    ~H"""
    <div class="rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2">
      <div class="text-xs font-medium text-neutral-500">{@label}</div>
      <div class="mt-1 text-xl font-semibold text-neutral-900">{@value}</div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:percent, :integer, required: true)
  attr(:tone, :string, required: true)

  defp bar_row(assigns) do
    ~H"""
    <div>
      <div class="mb-1 flex items-center justify-between gap-3 text-xs">
        <span class="font-medium text-neutral-600">{@label}</span>
        <span class="tabular-nums text-neutral-500">{@value}</span>
      </div>
      <div class="h-2 rounded-full bg-neutral-100">
        <div class={["h-2 rounded-full", bar_tone(@tone)]} style={"width: #{@percent}%"}></div>
      </div>
    </div>
    """
  end

  defp empty_summary do
    %{
      project_count: 0,
      used_project_count: 0,
      unused_project_count: 0,
      conversation_count: 0,
      token_totals: %{input: 0, output: 0, cache_read: 0, cache_write: 0, total: 0},
      project_usage_rows: []
    }
  end

  defp visible_token_total(%{token_totals: totals}),
    do: totals.input + totals.output + totals.cache_read + totals.cache_write

  defp bar_percent(_value, total) when total in [nil, 0], do: 0
  defp bar_percent(value, total), do: round(value / total * 100)

  defp bar_tone("brand"), do: "bg-brand-500"
  defp bar_tone("green"), do: "bg-green-500"
  defp bar_tone("amber"), do: "bg-amber-500"
  defp bar_tone(_), do: "bg-neutral-300"

  defp summary_label(:loading, _label), do: gettext("Loading")
  defp summary_label(:failed, _label), do: gettext("Unavailable")
  defp summary_label(_status, label), do: label

  defp summary_value(_value, :loading), do: "..."
  defp summary_value(_value, :failed), do: "—"
  defp summary_value(value, _status), do: value

  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(value), do: to_string(value)
end
