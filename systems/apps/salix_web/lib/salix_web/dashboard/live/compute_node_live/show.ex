defmodule SalixWeb.Dashboard.ComputeNodeLive.Show do
  @moduledoc "Tenant-scoped Agent VMM node detail."
  use SalixWeb.Dashboard, :live_view

  alias SalixStore.AgentVMMAdminProjection
  alias SalixWeb.AgentVMMAdminCursor
  alias SalixWeb.Dashboard.Format

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     assign(socket,
       active_nav: :compute_nodes,
       page_title: "Compute Node",
       breadcrumbs: [{"Compute Nodes", "/dash/compute-nodes"}, {Format.short_id(id), nil}],
       registration_id: id,
       tab: "overview",
       cursor: nil,
       next_cursor: nil,
       node: nil,
       workloads: [],
       workload_command_id: Ecto.UUID.generate(),
       operations: [],
       activity: [],
       comma_admin_url: nil,
       read_at: nil,
       read_error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = tab(params["tab"])

    with {:ok, cursor} <- decode_cursor(params["cursor"], socket, tab) do
      {:noreply, socket |> assign(tab: tab, cursor: cursor) |> load()}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid page cursor.")
         |> push_patch(to: detail_path(socket.assigns.registration_id, tab))}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("create_shell_workload", %{"id" => environment_id}, socket) do
    tenant_id = socket.assigns.current_tenant

    result =
      with {:ok, node} <-
             AgentVMMAdminProjection.get_node(tenant_id, socket.assigns.registration_id),
           environment when is_map(environment) <-
             Enum.find(node["environments"], &(&1["id"] == environment_id)) do
        SalixStore.AgentVMMAdminCommands.execute(socket.assigns.workload_command_id, %{
          action: "create_shell_workload",
          tenant_id: tenant_id,
          target_id: environment_id,
          expected_revision: environment["revision"]
        })
      else
        _ -> {:error, :not_found}
      end

    case result do
      {status, _} when status in [:ok, :already_applied] ->
        {:noreply,
         socket
         |> assign(workload_command_id: Ecto.UUID.generate())
         |> load()
         |> put_flash(:info, "Shell workload accepted. Refresh to check its runtime status.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Workload creation failed: #{inspect(reason)}")}
    end
  end

  defp load(socket) do
    tenant_id = socket.assigns.current_tenant
    id = socket.assigns.registration_id

    with {:ok, node} <- AgentVMMAdminProjection.get_node(tenant_id, id),
         {:ok, socket} <- load_tab(socket, tenant_id, id) do
      assign(socket,
        node: node,
        comma_admin_url: comma_admin_url(tenant_id, id),
        page_title: node["device_id"],
        read_at: DateTime.utc_now(),
        read_error: nil
      )
    else
      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Compute node not found.")
        |> push_navigate(to: "/dash/compute-nodes")

      {:error, reason} ->
        assign(socket, read_error: reason)
    end
  end

  defp load_tab(socket, _tenant_id, _id) when socket.assigns.tab == "overview",
    do: {:ok, assign(socket, next_cursor: nil)}

  defp load_tab(socket, tenant_id, id) when socket.assigns.tab == "workloads" do
    with {:ok, page} <-
           AgentVMMAdminProjection.page_workloads(tenant_id, id, socket.assigns.cursor, 50),
         {:ok, next_cursor} <- encode_cursor(page.next_cursor, socket, "workloads") do
      {:ok, assign(socket, workloads: page.workloads, next_cursor: next_cursor)}
    end
  end

  defp load_tab(socket, tenant_id, id) when socket.assigns.tab == "operations" do
    with {:ok, page} <-
           AgentVMMAdminProjection.page_operations(tenant_id, id, socket.assigns.cursor, 50),
         {:ok, next_cursor} <- encode_cursor(page.next_cursor, socket, "operations") do
      {:ok, assign(socket, operations: page.operations, next_cursor: next_cursor)}
    end
  end

  defp load_tab(socket, tenant_id, id) when socket.assigns.tab == "activity" do
    with {:ok, page} <-
           AgentVMMAdminProjection.page_activity(tenant_id, id, socket.assigns.cursor, 50),
         {:ok, next_cursor} <- encode_cursor(page.next_cursor, socket, "activity") do
      {:ok, assign(socket, activity: page.activity, next_cursor: next_cursor)}
    end
  end

  defp encode_cursor(nil, _socket, _tab), do: {:ok, nil}

  defp encode_cursor(cursor, socket, tab) do
    AgentVMMAdminCursor.encode(
      socket.assigns.current_tenant,
      cursor,
      cursor_scope(socket.assigns.registration_id, tab)
    )
  end

  defp decode_cursor(value, _socket, _tab) when value in [nil, ""], do: {:ok, nil}

  defp decode_cursor(value, socket, tab) do
    AgentVMMAdminCursor.decode(
      value,
      socket.assigns.current_tenant,
      cursor_scope(socket.assigns.registration_id, tab)
    )
  end

  defp cursor_scope(id, tab), do: %{"registration_id" => id, "tab" => tab}

  defp detail_path(id, tab, cursor \\ nil) do
    params = %{"tab" => tab} |> maybe_put_cursor(cursor)
    "/dash/compute-nodes/#{id}?" <> URI.encode_query(params)
  end

  defp maybe_put_cursor(params, nil), do: params
  defp maybe_put_cursor(params, cursor), do: Map.put(params, "cursor", cursor)

  defp comma_admin_url(tenant_id, registration_id) do
    origin = Application.get_env(:comma_web, :admin_cookie_origin, "http://127.0.0.1:4175")

    origin <>
      "/?" <>
      URI.encode_query(%{
        "section" => "compute",
        "tenant" => tenant_id,
        "registration" => registration_id
      })
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div :if={@node} class="flex items-start justify-between gap-4">
        <div>
          <div class="flex items-center gap-2">
            <h1 class="text-xl font-semibold">{@node["device_id"]}</h1>
            <.status_pill status={@node["status"]} />
          </div>
          <p class="mt-1 font-mono text-xs text-neutral-500">{@node["id"]}</p>
        </div>
        <div class="flex gap-2">
          <a class="rounded-md border border-neutral-300 px-3 py-1.5 text-sm font-medium hover:bg-neutral-50" href={@comma_admin_url} rel="noreferrer" target="_blank">Open in Comma Admin</a>
          <.button size="sm" phx-click="refresh">Refresh</.button>
        </div>
      </div>

      <div :if={@read_error} class="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-800">
        Refresh failed; showing data read at {Format.datetime(@read_at)}.
      </div>

      <div :if={@node} class="space-y-6">
        <div class="flex gap-1 border-b border-neutral-200">
          <.tab_link :for={{label, value} <- [{"Overview", "overview"}, {"Workloads", "workloads"}, {"Operations", "operations"}, {"Activity", "activity"}]} label={label} value={value} current={@tab} id={@node["id"]} />
        </div>

        <.card :if={@tab == "overview"}>
          <:title>Overview</:title>
          <div class="grid gap-3 md:grid-cols-3">
            <.kv label="Product authorization">{installation(@node)}</.kv>
            <.kv label="Registration">{@node["registration"]["status"]}</.kv>
            <.kv label="Admission">{enabled(@node)}</.kv>
            <.kv label="Gateway observation">{@node["connection"]["status"]}</.kv>
            <.kv label="Bindings">{@node["connection"]["available_bindings"]} / {@node["connection"]["binding_count"]} available</.kv>
            <.kv label="Inventory watermark">{@node["connection"]["inventory_watermark"] || "Not reported"}</.kv>
            <.kv label="Allocations">{@node["work"]["allocations"]}</.kv>
            <.kv label="Workloads">{@node["work"]["ready_workloads"]} / {@node["work"]["workloads"]} ready</.kv>
            <.kv label="Runtime">{@node["work"]["ready_runtimes"]} / {@node["work"]["runtimes"]} ready</.kv>
            <.kv label="Active commands">{@node["operations"]["active"]}</.kv>
            <.kv label="Unknown outcomes">{@node["operations"]["unknown_outcome"]}</.kv>
            <.kv label="Issue">{@node["issue"] || "None"}</.kv>
          </div>
        </.card>

        <.card :if={@tab == "overview"}>
          <:title>Host observation</:title>
          <div class="grid gap-3 md:grid-cols-3">
            <.kv label="Host health">{observation_value(@node, ["health", "status"])}</.kv>
            <.kv label="Health issue">{observation_value(@node, ["health", "issue"])}</.kv>
            <.kv label="Observed / received">{Format.datetime(@node["connection"]["last_observed_at"])} / {Format.datetime(@node["connection"]["received_at"])}</.kv>
            <.kv label="Protocol / Host API">{observation_value(@node, ["protocol_version"])} / {observation_value(@node, ["host_api_version"])}</.kv>
            <.kv label="Connector release">{observation_value(@node, ["connector_release"])}</.kv>
            <.kv label="Features">{feature_list(@node)}</.kv>
            <.kv label="Capacity">{observation_map(@node, "capacity")}</.kv>
            <.kv label="Active workload usage">{observation_map(@node, "usage")}</.kv>
          </div>
          <div :if={health_components(@node) != []} class="mt-4">
            <div class="mb-2 text-xs text-neutral-500">Components</div>
            <div class="grid gap-2 md:grid-cols-2">
              <div :for={component <- health_components(@node)} class="flex items-center justify-between rounded border border-neutral-200 px-3 py-2 text-sm">
                <span>{component["component"]}</span>
                <.status_pill status={component["status"]} />
              </div>
            </div>
          </div>
          <p :if={@node["connection"]["health"] == nil} class="mt-3 text-sm text-neutral-500">
            This Host has not reported typed health, capacity, or usage data.
          </p>
        </.card>

        <.card :if={@tab == "workloads"}>
          <:title>Workloads</:title>
          <p class="mb-3 text-sm text-neutral-500">Create a managed Shell workload: 512 PID limit, 2 GiB writable disk limit, no network access.</p>
          <div :for={environment <- @node["environments"]} class="mb-3 flex flex-wrap items-center justify-between gap-2">
            <span class="font-mono text-xs">{environment["id"]}</span>
            <.button size="sm" phx-click="create_shell_workload" phx-value-id={environment["id"]}
              disabled={environment["desired_state"] != "ready" || environment["binding_status"] != "available"}
              phx-disable-with="Creating…" data-confirm="Create a Shell workload in this environment?">
              Create Shell workload
            </.button>
          </div>
          <.table :if={@workloads != []} id="compute-node-workloads" rows={@workloads}>
            <:col :let={row} label="Workload"><span class="font-mono text-xs">{Format.short_id(row["id"])}</span></:col>
            <:col :let={row} label="Kind">{row["kind"]}</:col>
            <:col :let={row} label="Desired / observed">{row["desired_state"]} / {row["observed_state"]}</:col>
            <:col :let={row} label="Allocation">{row["allocation_status"]}</:col>
            <:col :let={row} label="Runtime">{row["runtime_status"] || "not reported"} / {row["runtime_readiness"] || "not reported"}</:col>
            <:col :let={row} label="Last reconcile error">{reconcile_error(row)}</:col>
          </.table>
          <p :if={@workloads == []} class="text-sm text-neutral-500">No workloads.</p>
        </.card>

        <.card :if={@tab == "operations"}>
          <:title>Operations</:title>
          <.table :if={@operations != []} id="compute-node-operations" rows={@operations}>
            <:col :let={row} label="Kind">{row["kind"]}</:col>
            <:col :let={row} label="Classification">{row["classification"]}</:col>
            <:col :let={row} label="Status"><.status_pill status={row["status"]} /></:col>
            <:col :let={row} label="Outcome">{row["outcome"]}</:col>
            <:col :let={row} label="Updated">{Format.datetime(row["updated_at"])}</:col>
          </.table>
          <p :if={@operations == []} class="text-sm text-neutral-500">No operations.</p>
        </.card>

        <.card :if={@tab == "activity"}>
          <:title>Activity</:title>
          <div :for={row <- @activity} class="flex items-center justify-between border-b border-neutral-100 py-2 text-sm">
            <span>{row["action"]} · {row["outcome"]}</span>
            <span class="text-neutral-500">{Format.datetime(row["created_at"])}</span>
          </div>
          <p :if={@activity == []} class="text-sm text-neutral-500">No activity.</p>
        </.card>

        <div :if={@tab != "overview" && @next_cursor} class="flex justify-end">
          <.button size="sm" navigate={detail_path(@node["id"], @tab, @next_cursor)}>Next page</.button>
        </div>

        <details :if={@tab == "overview"} class="rounded-lg border border-neutral-200 p-3 text-sm">
          <summary class="cursor-pointer font-medium">Diagnostics</summary>
          <div class="mt-3 grid gap-2 md:grid-cols-2">
            <.kv label="Registration revision">{@node["registration"]["revision"]}</.kv>
            <.kv label="Policy revision">{@node["registration"]["policy_revision"]}</.kv>
            <.kv label="Last observed">{Format.datetime(@node["connection"]["last_observed_at"])}</.kv>
            <.kv label="Oldest active command">{Format.datetime(@node["operations"]["oldest_active_at"])}</.kv>
          </div>
        </details>
      </div>
    </div>
    """
  end

  defp installation(%{"installation" => nil}), do: "Not requested"
  defp installation(node), do: node["installation"]["status"]

  defp enabled(node),
    do: if(node["registration"]["desired_enabled"], do: "enabled", else: "disabled")

  defp observation_value(node, path) do
    case get_in(node["connection"], path) do
      nil -> "Not reported"
      value -> to_string(value)
    end
  end

  defp feature_list(node) do
    case node["connection"]["supported_features"] do
      [] -> "Not reported"
      features -> Enum.join(features, ", ")
    end
  end

  defp observation_map(node, key) do
    value = node["connection"][key]

    case value do
      value when value == %{} ->
        "Not reported"

      nil ->
        "Not reported"

      value ->
        value
        |> Enum.sort()
        |> Enum.map_join(", ", fn {key, field} ->
          "#{key}: #{observation_field(field)}"
        end)
    end
  end

  defp observation_field(%{} = value) do
    value
    |> Enum.sort()
    |> Enum.map_join(" ", fn {key, field} -> "#{key}=#{observation_field(field)}" end)
  end

  defp observation_field(value) when is_list(value),
    do: Enum.map_join(value, " ", &observation_field/1)

  defp observation_field(value), do: to_string(value)

  defp health_components(node),
    do: get_in(node, ["connection", "health", "components"]) || []

  defp reconcile_error(%{"reconcile_error" => %{} = error}) do
    ["code", "stage", "resource", "message", "available_bytes", "required_bytes"]
    |> Enum.flat_map(fn key ->
      case Map.fetch(error, key) do
        {:ok, value} -> ["#{key}=#{value}"]
        :error -> []
      end
    end)
    |> Enum.join(" / ")
  end

  defp reconcile_error(_), do: "None"

  defp tab(value) when value in ~w(overview workloads operations activity), do: value
  defp tab(_), do: "overview"

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:current, :string, required: true)
  attr(:id, :string, required: true)

  defp tab_link(assigns) do
    ~H"""
    <.link
      patch={detail_path(@id, @value)}
      class={[
        "border-b-2 px-3 py-2 text-sm",
        @current == @value && "border-neutral-900 font-medium text-neutral-900",
        @current != @value && "border-transparent text-neutral-500 hover:text-neutral-900"
      ]}
    >
      {@label}
    </.link>
    """
  end

  attr(:label, :string, required: true)
  slot(:inner_block, required: true)

  defp kv(assigns) do
    ~H"""
    <div>
      <div class="text-xs text-neutral-500">{@label}</div>
      <div class="mt-0.5 text-sm"><%= render_slot(@inner_block) %></div>
    </div>
    """
  end
end
