defmodule SalixWeb.Dashboard.EnvironmentLive.Show do
  @moduledoc "Stable device detail."
  use SalixWeb.Dashboard, :live_view

  alias SalixWeb.Dashboard.Format
  alias SalixWeb.SubscriptionRuntimeAuth

  @impl true
  def mount(%{"group_id" => group_id, "id" => id}, _session, socket) do
    case SalixEnv.Control.get_environment(id, group_id, socket.assigns.current_tenant) do
      {:ok, env} ->
        runtime_id = first_external_runtime_id(env)

        {:ok,
         assign(socket,
           active_nav: :environments,
           env: env,
           page_title: env["name"],
           breadcrumbs: [{"Devices", "/dash/environments"}, {env["name"], nil}],
           managed_runtime_id: nil,
           managed_auth: nil,
           managed_accounts: [],
           managed_accounts_next: nil,
           selected_runtime_id: runtime_id,
           runtime_sessions: runtime_sessions(env, runtime_id, socket.assigns.current_tenant)
         )}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Device not found.")
         |> push_navigate(to: "/dash/environments")}
    end
  end

  @impl true
  def handle_event("select-runtime", %{"device_runtime_id" => runtime_id}, socket) do
    if Enum.any?(external_runtimes(socket.assigns.env), &(&1["device_runtime_id"] == runtime_id)) do
      {:noreply,
       assign(socket,
         selected_runtime_id: runtime_id,
         runtime_sessions:
           runtime_sessions(socket.assigns.env, runtime_id, socket.assigns.current_tenant)
       )}
    else
      {:noreply, put_flash(socket, :error, "Runtime not found.")}
    end
  end

  def handle_event("probe-runtime", %{"id" => runtime_id}, socket) do
    env = socket.assigns.env

    case SalixEnv.Control.probe_runtime(
           env["device_id"],
           runtime_id,
           env["group_id"],
           socket.assigns.current_tenant
         ) do
      {:ok, _summary} ->
        {:ok, refreshed} =
          SalixEnv.Control.get_environment(
            env["device_id"],
            env["group_id"],
            socket.assigns.current_tenant
          )

        {:noreply,
         socket
         |> assign(
           env: refreshed,
           runtime_sessions:
             runtime_sessions(
               refreshed,
               socket.assigns.selected_runtime_id,
               socket.assigns.current_tenant
             )
         )
         |> put_flash(:info, "Runtime probe completed.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Runtime probe failed: #{format_reason(reason)}")}
    end
  end

  def handle_event("manage-account", %{"id" => runtime}, socket) do
    {:noreply, load_managed_auth(assign(socket, managed_runtime_id: runtime), "")}
  end

  def handle_event("refresh-account", _, socket), do: {:noreply, load_managed_auth(socket, "")}

  def handle_event("more-accounts", _, socket),
    do: {:noreply, load_managed_auth(socket, socket.assigns.managed_accounts_next || "")}

  def handle_event("bind-account", %{"account_id" => id}, socket) do
    case Enum.find(socket.assigns.managed_accounts, &(&1["id"] == id)) do
      nil -> {:noreply, put_flash(socket, :error, "Select an available account.")}
      account -> {:noreply, configure_account(socket, :bind, account)}
    end
  end

  def handle_event("retry-account", _, socket) do
    {:noreply, configure_account(socket, :bind, socket.assigns.managed_auth["account"])}
  end

  def handle_event("unbind-account", _, socket),
    do: {:noreply, configure_account(socket, :unbind, nil)}

  defp configure_account(socket, operation, account) do
    env = socket.assigns.env
    attrs = %{"expected_binding" => socket.assigns.managed_auth["binding"]}

    attrs =
      if operation == :bind and is_map(account),
        do:
          Map.merge(attrs, %{
            "account_id" => account["id"],
            "expected_account_version" => account["version"]
          }),
        else: attrs

    case SubscriptionRuntimeAuth.managed(
           socket.assigns.current_tenant,
           env["group_id"],
           env["device_id"],
           socket.assigns.managed_runtime_id,
           operation,
           attrs
         ) do
      {:ok, _} ->
        load_managed_auth(socket, "")

      {:error, _} ->
        socket
        |> load_managed_auth("")
        |> put_flash(
          :error,
          "Account configuration failed or changed. Review the current state before retrying."
        )
    end
  end

  # Only the selected runtime reads one account page. Refresh is operator-driven.
  defp load_managed_auth(socket, cursor) do
    env = socket.assigns.env
    tenant = socket.assigns.current_tenant

    with {:ok, auth} <-
           SubscriptionRuntimeAuth.managed(
             tenant,
             env["group_id"],
             env["device_id"],
             socket.assigns.managed_runtime_id,
             :read
           ),
         {:ok, page} <- SubscriptionRuntimeAuth.accounts(tenant, auth["provider"], cursor),
         {:ok, refreshed} <-
           SalixEnv.Control.get_environment(env["device_id"], env["group_id"], tenant) do
      assign(socket,
        managed_auth: auth,
        managed_accounts: page["accounts"],
        managed_accounts_next: page["accounts_next"],
        env: refreshed
      )
    else
      _ ->
        socket
        |> assign(managed_auth: nil, managed_accounts: [], managed_accounts_next: nil)
        |> put_flash(:error, "Runtime account configuration is unavailable.")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center gap-2">
        <h1 class="text-xl font-semibold">{@env["name"]}</h1>
        <.status_pill status={@env["status"]} />
      </div>

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <.kv label="Device ID">{@env["device_id"]}</.kv>
        <.kv label="Connector run ID">{@env["connector_run_id"]}</.kv>
        <.kv label="OS / Arch">{@env["os"]} {@env["arch"]}</.kv>
        <.kv label="Node">{@env["node_id"]}</.kv>
        <.kv label="Connected">{Format.datetime(iso(@env["connected_at"]))}</.kv>
        <.kv label="Description">{@env["description"]}</.kv>
        <.kv label="Skills">{Enum.join(@env["skills"] || [], ", ")}</.kv>
      </div>

      <.card :if={system_info?(@env)}>
        <:title>System info</:title>
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <.kv label="Hostname">{si(@env, "hostname")}</.kv>
          <.kv label="OS">{os_label(@env["system_info"])}</.kv>
          <.kv label="OS version">{si(@env, "os_version")}</.kv>
          <.kv label="Architecture">{si(@env, "arch")}</.kv>
          <.kv label="CPU">{si(@env, "cpu_model")}</.kv>
          <.kv label="CPU cores">{si(@env, "cpu_count")}</.kv>
          <.kv label="Memory">{format_bytes(@env["system_info"]["memory_total"])}</.kv>
          <.kv label="Updated">{Format.datetime(iso_ms(@env["system_info_updated_at"]))}</.kv>
        </div>
        <pre class="mt-3 overflow-auto rounded-md bg-neutral-50 p-3 text-xs">{Format.pretty_json(@env["system_info"])}</pre>
      </.card>

    <.card>
    <:title>Connector health</:title>
    <div :if={is_map(@env["connector_health"])} class="grid grid-cols-1 gap-3 sm:grid-cols-3">
    <.kv label="Last observed">{Format.datetime(iso_ms(@env["connector_health_updated_at"]))}</.kv>
    <.kv label="Release">{connector_release(@env)}</.kv>
    <.kv label="Requests">{health(@env, "request_inflight")} / {health(@env, "request_capacity")}</.kv>
    <.kv label="Runtime proxy">{health(@env, "runtime_proxy_inflight")} / {health(@env, "runtime_proxy_capacity")}</.kv>
    <.kv label="Managed processes">{health(@env, "managed_processes")}</.kv>
    <.kv label="Resumable sessions">{optional_health(@env, "resumable_runtime_sessions")}</.kv>
    <.kv label="Recoverable executions">{health(@env, "recoverable_runtime_sessions")}</.kv>
    <.kv label="Pending input batches">{health(@env, "pending_input_batches")}</.kv>
    <.kv label="Pending runtime events">{health(@env, "pending_runtime_events")}</.kv>
    </div>
    <p :if={!is_map(@env["connector_health"])} class="text-sm text-neutral-500">Not reported by this Connector.</p>
    </.card>

    <.card>
    <:title>External runtimes</:title>
    <div class="overflow-x-auto">
    <table class="w-full text-left text-sm">
    <thead><tr class="border-b border-neutral-200 text-xs uppercase text-neutral-500"><th class="py-2">Provider</th><th>Version</th><th>Availability</th><th>Issue</th><th>Checked</th><th>Valid until</th><th></th></tr></thead>
    <tbody>
     <tr :for={runtime <- external_runtimes(@env)} class="border-b border-neutral-100">
    <td class="py-2 font-medium">{runtime["provider"]}</td>
    <td>{runtime["version"] || "—"}</td>
    <td><.status_pill status={runtime["status"]} /></td>
    <td>{runtime["issue"] || "—"}</td>
    <td>{Format.datetime(iso(runtime["readiness_checked_at"]))}</td>
    <td>{Format.datetime(iso(runtime["readiness_valid_until"]))}</td>
    <td class="space-x-2 text-right">
      <.button :if={runtime["provider"] in ~w(codex claude)} size="sm" phx-click="manage-account" phx-value-id={runtime["device_runtime_id"]}>Account</.button>
      <.button size="sm" phx-click="select-runtime" phx-value-device_runtime_id={runtime["device_runtime_id"]}>Sessions</.button>
      <.button size="sm" phx-click="probe-runtime" phx-value-id={runtime["device_runtime_id"]} disabled={@env["status"] != "connected"}>Re-probe</.button>
    </td>
     </tr>
    </tbody>
    </table>
    </div>
    <div :if={@selected_runtime_id} class="mt-4 space-y-2">
    <h3 class="text-sm font-medium">Connector-held sessions</h3>
    <p :if={@runtime_sessions["observation_status"] == "not_reported"} class="text-sm text-neutral-500">Not reported by this Connector.</p>
    <p :if={@runtime_sessions["observation_status"] == "last_observed"} class="text-sm text-amber-700">Connector disconnected; showing the last observed snapshot.</p>
    <p :if={is_integer(@runtime_sessions["observed_at"])} class="text-xs text-neutral-500">Observed {Format.datetime(iso_ms(@runtime_sessions["observed_at"]))}</p>
    <p :if={@runtime_sessions["session_ids"] == [] && @runtime_sessions["observation_status"] != "not_reported"} class="text-sm text-neutral-500">No Connector-held sessions.</p>
    <p :if={@runtime_sessions["truncated"] == true} class="text-xs text-neutral-500">Showing {length(@runtime_sessions["session_ids"])} of {@runtime_sessions["session_count"]} sessions.</p>
    <div :for={session_id <- @runtime_sessions["session_ids"]} class="rounded-lg border border-neutral-200 px-3 py-2 font-mono text-xs">
    {session_id}
    </div>
    </div>
    </.card>

      <.card :if={@managed_auth}>
        <:title>Runtime account</:title>
        <p class="text-xs font-mono break-all">{@managed_runtime_id}</p>
        <p class="mt-2 text-sm">All Agents using this runtime share its account.</p>
        <p class="mt-2 text-sm">Status: {@managed_auth["state"]}</p>
        <p :if={@managed_auth["issue"]} role="status" class="text-sm text-amber-700">{@managed_auth["issue"]}</p>
        <div :if={"bind" in @managed_auth["actions"]}>
          <p :if={@managed_auth["source"] == "self_configured"} class="mt-2 text-sm">Uses credentials configured on the device. Bind an organization account to manage authentication here.</p>
          <form phx-submit="bind-account" class="mt-3 flex flex-wrap items-end gap-2">
            <label class="text-sm">Organization account
              <select name="account_id" aria-label="Organization account" required class="block rounded-md border border-neutral-300 p-2">
                <option value="">Select account</option>
                <option :for={account <- @managed_accounts} value={account["id"]}>{account["name"] || account["email"] || account["id"]}</option>
              </select>
            </label>
            <.button type="submit" variant="primary" disabled={@env["status"] != "connected"}>{if @managed_auth["binding"], do: "Change account", else: "Bind account"}</.button>
          </form>
          <.button :if={@managed_accounts_next not in [nil, ""]} size="sm" phx-click="more-accounts">More accounts</.button>
        </div>
        <div :if={@managed_auth["source"] == "organization"} class="mt-3 space-y-2">
          <p class="text-sm">Account: {get_in(@managed_auth, ["account", "name"]) || get_in(@managed_auth, ["account", "email"]) || get_in(@managed_auth, ["binding", "account_id"])}</p>
          <.button :if={"retry" in @managed_auth["actions"]} phx-click="retry-account">Retry same account</.button>
          <.button :if={"unbind" in @managed_auth["actions"]} phx-click="unbind-account" data-confirm="Unbinding may interrupt tasks using this runtime. Session data is retained.">Unbind account</.button>
        </div>
        <.button size="sm" phx-click="refresh-account" class="mt-3">Refresh status</.button>
        <p class="mt-2 text-xs text-neutral-500">Configured credentials do not prove a successful model request. Re-probe the runtime to check readiness.</p>
      </.card>

      <.card>
        <:title>Capabilities</:title>
        <pre class="overflow-auto rounded-md bg-neutral-50 p-3 text-xs">{Format.pretty_json(@env["capabilities"])}</pre>
      </.card>
    </div>
    """
  end

  defp system_info?(env), do: is_map(env["system_info"]) and env["system_info"] != %{}

  defp external_runtimes(env),
    do:
      Enum.filter(
        env["device_runtimes"] || [],
        &(&1["provider"] in ["codex", "pi", "kimi", "claude"])
      )

  defp first_external_runtime_id(env) do
    case external_runtimes(env) do
      [runtime | _] -> runtime["device_runtime_id"]
      [] -> nil
    end
  end

  defp runtime_sessions(_env, nil, _tenant_id),
    do: %{"observation_status" => "not_reported", "session_ids" => []}

  defp runtime_sessions(env, runtime_id, tenant_id) do
    case SalixEnv.Control.runtime_sessions(
           env["device_id"],
           runtime_id,
           env["group_id"],
           tenant_id
         ) do
      {:ok, snapshot} -> snapshot
      {:error, _} -> %{"observation_status" => "not_reported", "session_ids" => []}
    end
  end

  defp health(env, key), do: get_in(env, ["connector_health", key]) || 0
  defp optional_health(env, key), do: get_in(env, ["connector_health", key]) || "Not reported"

  defp connector_release(env) do
    get_in(env, ["capabilities", "component_releases", "salix-connect", "release_id"]) ||
      get_in(env, ["capabilities", "component_versions", "salix-connect"]) || "—"
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp si(env, key) do
    case env["system_info"] do
      %{} = info -> to_string(info[key] || "")
      _ -> ""
    end
  end

  # "Linux 6.8.0-generic" / "Darwin 23.5.0" from os_type + os_release (falling
  # back to os_version, which the Go connector reports instead of os_release).
  defp os_label(%{} = info) do
    [info["os_type"], info["os_release"] || info["os_version"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp os_label(_), do: ""

  defp format_bytes(n) when is_integer(n) and n > 0 do
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    exp = min(trunc(:math.log(n) / :math.log(1024)), length(units) - 1)
    value = n / :math.pow(1024, exp)
    :erlang.float_to_binary(value, decimals: 1) <> " " <> Enum.at(units, exp)
  end

  defp format_bytes(_), do: "—"

  defp iso_ms(ms) when is_integer(ms),
    do: DateTime.from_unix!(ms, :millisecond) |> DateTime.to_iso8601()

  defp iso_ms(_), do: nil

  attr(:label, :string, required: true)
  slot(:inner_block, required: true)

  defp kv(assigns) do
    ~H"""
    <div class="rounded-lg border border-neutral-200 bg-white px-4 py-3">
      <dt class="text-xs font-medium uppercase tracking-wide text-neutral-500">{@label}</dt>
      <dd class="mt-1 text-sm text-neutral-800">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  defp iso(s) when is_integer(s), do: DateTime.from_unix!(s) |> DateTime.to_iso8601()
  defp iso(v), do: v
end
