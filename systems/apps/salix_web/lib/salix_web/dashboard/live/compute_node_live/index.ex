defmodule SalixWeb.Dashboard.ComputeNodeLive.Index do
  @moduledoc "Tenant-scoped Agent VMM fleet status."
  use SalixWeb.Dashboard, :live_view

  alias SalixStore.AgentVMMAdminProjection
  alias SalixWeb.AgentVMMAdminCursor
  alias SalixWeb.Dashboard.Format

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       active_nav: :compute_nodes,
       page_title: "Compute Nodes",
       breadcrumbs: [{"Compute Nodes", nil}],
       filters: %{},
       cursor: nil,
       nodes: [],
       summary: empty_summary(),
       next_cursor: nil,
       read_at: nil,
       read_error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = filters(params)

    with {:ok, cursor} <- decode_cursor(params["cursor"], socket.assigns.current_tenant, filters) do
      {:noreply, socket |> assign(filters: filters, cursor: cursor) |> load()}
    else
      _ ->
        {:noreply,
         socket |> put_flash(:error, "Invalid page cursor.") |> push_patch(to: path(filters))}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: path(filters(params)))}
  end

  defp load(socket) do
    tenant_id = socket.assigns.current_tenant
    filters = socket.assigns.filters

    with {:ok, summary} <- AgentVMMAdminProjection.overview(tenant_id, filters),
         {:ok, page} <-
           AgentVMMAdminProjection.page_nodes(tenant_id, filters, socket.assigns.cursor, 50),
         {:ok, next_cursor} <- encode_cursor(page.next_cursor, tenant_id, filters) do
      assign(socket,
        summary: summary,
        nodes: page.nodes,
        next_cursor: next_cursor,
        read_at: DateTime.utc_now(),
        read_error: nil
      )
    else
      {:error, reason} -> assign(socket, read_error: reason)
    end
  end

  defp encode_cursor(nil, _tenant_id, _filters), do: {:ok, nil}

  defp encode_cursor(cursor, tenant_id, filters),
    do: AgentVMMAdminCursor.encode(tenant_id, cursor, filters)

  defp decode_cursor(nil, _tenant_id, _filters), do: {:ok, nil}
  defp decode_cursor("", _tenant_id, _filters), do: {:ok, nil}

  defp decode_cursor(token, tenant_id, filters),
    do: AgentVMMAdminCursor.decode(token, tenant_id, filters)

  defp filters(params) do
    %{}
    |> put_filter("q", params["q"])
    |> put_filter("group_id", params["group_id"])
    |> put_filter("status", params["status"])
    |> put_filter("desired_enabled", params["desired_enabled"])
    |> put_filter("connection", params["connection"])
    |> put_filter("work", params["work"])
    |> put_filter("issue", params["issue"])
    |> put_filter("updated_from", params["updated_from"])
    |> put_filter("updated_to", params["updated_to"])
  end

  defp put_filter(filters, _key, value) when value in [nil, ""], do: filters
  defp put_filter(filters, key, value), do: Map.put(filters, key, value)

  defp path(filters) do
    query = URI.encode_query(filters)
    if query == "", do: "/dash/compute-nodes", else: "/dash/compute-nodes?" <> query
  end

  defp next_path(filters, cursor) do
    path(Map.put(filters, "cursor", cursor))
  end

  defp empty_summary do
    %{
      "total" => 0,
      "ready" => 0,
      "needs_attention" => 0,
      "disconnected_or_stale" => 0,
      "draining" => 0,
      "unknown_outcome" => 0
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h1 class="text-xl font-semibold">Compute Nodes</h1>
          <p class="mt-1 text-sm text-neutral-500">Agent VMM registration, allocation, workload, and runtime state.</p>
        </div>
        <.button size="sm" phx-click="refresh">Refresh</.button>
      </div>

      <div :if={@read_error} class="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-800">
        Refresh failed; showing the last successful page from {Format.datetime(@read_at)}.
      </div>

      <div class="grid grid-cols-2 gap-3 md:grid-cols-6">
        <.summary label="Needs attention" value={@summary["needs_attention"]} />
        <.summary label="Disconnected / stale" value={@summary["disconnected_or_stale"]} />
        <.summary label="Draining" value={@summary["draining"]} />
        <.summary label="Unknown outcome" value={@summary["unknown_outcome"]} />
        <.summary label="Ready" value={@summary["ready"]} />
        <.summary label="Total" value={@summary["total"]} />
      </div>

      <form id="compute-node-filters" phx-submit="filter" class="grid gap-3 rounded-lg border border-neutral-200 p-3 md:grid-cols-4">
        <.input name="q" value={@filters["q"]} label="Node or registration" />
        <.input name="group_id" value={@filters["group_id"]} label="Group ID" />
        <.select name="status" value={@filters["status"]} label="Registration" options={[{"All", ""}, {"Ready", "ready"}, {"Enrolling", "enrolling"}, {"Disabled", "disabled"}, {"Revoked", "revoked"}]} />
        <.select name="desired_enabled" value={@filters["desired_enabled"]} label="Desired admission" options={[{"All", ""}, {"Enabled", "true"}, {"Disabled", "false"}]} />
        <.select name="connection" value={@filters["connection"]} label="Connection" options={[{"All", ""}, {"Not reported", "not_reported"}, {"Disconnected", "disconnected"}, {"Stale", "stale"}, {"Connected", "connected"}]} />
        <.select name="work" value={@filters["work"]} label="Work activity" options={[{"All", ""}, {"Idle", "idle"}, {"Active", "active"}, {"Draining", "draining"}]} />
        <.select name="issue" value={@filters["issue"]} label="Issue" options={issue_options()} />
        <.input name="updated_from" value={@filters["updated_from"]} label="Updated from (ISO 8601)" />
        <.input name="updated_to" value={@filters["updated_to"]} label="Updated to (ISO 8601)" />
        <div class="flex items-end"><.button type="submit" size="sm">Apply</.button></div>
      </form>

      <.table :if={@nodes != []} id="compute-nodes" rows={@nodes} row_click={fn node -> JS.navigate("/dash/compute-nodes/#{node["id"]}") end}>
        <:col :let={node} label="Node">
          <div class="font-medium">{node["device_id"]}</div>
          <div class="font-mono text-xs text-neutral-500">{Format.short_id(node["id"])}</div>
        </:col>
        <:col :let={node} label="Scope">{node["group_id"]}</:col>
        <:col :let={node} label="Registration"><.status_pill status={node["registration"]["status"]} /></:col>
        <:col :let={node} label="Connection"><.status_pill status={node["connection"]["status"]} /></:col>
        <:col :let={node} label="Work">{node["work"]["ready_workloads"]} / {node["work"]["workloads"]} ready</:col>
        <:col :let={node} label="Runtime">{node["work"]["ready_runtimes"]} / {node["work"]["runtimes"]} ready</:col>
        <:col :let={node} label="Issue">{node["issue"] || "—"}</:col>
        <:col :let={node} label="Updated">{Format.time_ago(node["updated_at"])}</:col>
        <:action :let={node}><.button size="sm" navigate={"/dash/compute-nodes/#{node["id"]}"}>Open</.button></:action>
      </.table>

      <.empty_state :if={@nodes == [] && !@read_error} icon="server" title="No compute nodes" />

      <div :if={@next_cursor} class="flex justify-end">
        <.button size="sm" navigate={next_path(@filters, @next_cursor)}>Next page</.button>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :integer, required: true)

  defp summary(assigns) do
    ~H"""
    <div class="rounded-lg border border-neutral-200 p-3">
      <div class="text-xs text-neutral-500">{@label}</div>
      <div class="mt-1 text-xl font-semibold">{@value}</div>
    </div>
    """
  end

  defp issue_options do
    [
      {"All", ""},
      {"Install action required", "install_action_required"},
      {"Registration enrolling", "registration_enrolling"},
      {"Registration disabled", "registration_disabled"},
      {"Registration revoked", "registration_revoked"},
      {"Observation missing", "observation_missing"},
      {"Observation stale", "observation_stale"},
      {"Binding unavailable", "binding_unavailable"},
      {"Workload not converged", "workload_not_converged"},
      {"Runtime not ready", "runtime_not_ready"},
      {"Command failed", "command_failed"},
      {"Command outcome unknown", "command_unknown_outcome"}
    ]
  end
end
