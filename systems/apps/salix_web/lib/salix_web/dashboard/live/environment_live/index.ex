defmodule SalixWeb.Dashboard.EnvironmentLive.Index do
  @moduledoc "List stable devices and their current connection state."
  use SalixWeb.Dashboard, :live_view

  alias SalixWeb.Dashboard.Format

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    {:ok,
     socket
     |> assign(
       active_nav: :environments,
       page_title: "Devices",
       breadcrumbs: [{"Devices", nil}]
     )
     |> load()}
  end

  defp load(socket),
    do:
      assign(socket,
        environments: SalixEnv.Control.list_environments(socket.assigns.current_tenant)
      )

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("delete", %{"id" => id, "group-id" => group_id}, socket) do
    case SalixEnv.Control.delete_environment(id, group_id, socket.assigns.current_tenant) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Connector disconnected.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-xl font-semibold">Devices</h1>

      <.table :if={@environments != []} id="envs" rows={@environments} row_click={
        fn e -> JS.navigate("/dash/environments/#{e["group_id"]}/#{e["device_id"]}") end
      }>
        <:col :let={e} label="Name">{e["name"]}</:col>
        <:col :let={e} label="Host">{host_label(e)}</:col>
        <:col :let={e} label="OS / Arch">{os_arch(e)}</:col>
        <:col :let={e} label="Status"><.status_pill status={e["status"]} /></:col>
        <:col :let={e} label="Node"><span class="font-mono text-xs">{Format.short_id(e["node_id"])}</span></:col>
        <:col :let={e} label="Connected">{Format.time_ago(iso(e["connected_at"]))}</:col>
        <:action :let={e}>
          <.button size="sm" navigate={"/dash/environments/#{e["group_id"]}/#{e["device_id"]}"}>Open</.button>
          <.button :if={e["status"] == "connected"} size="sm" variant="danger" phx-click="delete" phx-value-id={e["device_id"]} phx-value-group-id={e["group_id"]}
            data-confirm="Disconnect this device's current connector?">Disconnect</.button>
        </:action>
      </.table>
      <.empty_state :if={@environments == []} icon="bolt" title="No devices" />
    </div>
    """
  end

  defp iso(s) when is_integer(s), do: DateTime.from_unix!(s) |> DateTime.to_iso8601()
  defp iso(v), do: v

  # Prefer the connector's reported hostname; fall back to "—".
  defp host_label(%{"system_info" => %{"hostname" => host}}) when is_binary(host) and host != "",
    do: host

  defp host_label(_), do: "—"

  # OS string prefers the richer system-info OS type over the registration os.
  defp os_arch(e) do
    info = e["system_info"] || %{}
    os = first_present([info["os_type"], e["os"]])
    arch = first_present([info["arch"], e["arch"]])

    [os, arch] |> Enum.reject(&(&1 == "")) |> Enum.join(" / ")
  end

  defp first_present(values) do
    Enum.find(values, "", &(is_binary(&1) and &1 != ""))
  end
end
