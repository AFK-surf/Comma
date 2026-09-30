defmodule SalixWeb.Dashboard.DriveLive do
  @moduledoc """
  Configure the Drive integration: the Synchronicity control plane the
  agents' `/drive` mount reaches, for the current tenant and as the
  deployment-wide platform default. A group's own binding (org, network,
  space and API key) is managed on the group page's Drive tab; a binding
  Comma's Workspace convergence minted appears there too, marked `comma`.
  """
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.DriveSettings

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(active_nav: :drive, page_title: "Drive", breadcrumbs: [{"Drive", nil}])
     |> load()}
  end

  defp load(socket) do
    assign(socket,
      settings: DriveSettings.view(socket.assigns.current_tenant),
      default_settings: DriveSettings.view_default()
    )
  end

  @impl true
  def handle_event("save", params, socket) do
    case DriveSettings.put(socket.assigns.current_tenant, save_attrs(params)) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Drive settings saved.") |> load()}
      {:error, {:bad_request, msg}} -> {:noreply, put_flash(socket, :error, msg)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete", _params, socket) do
    case DriveSettings.delete(socket.assigns.current_tenant) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Drive settings removed.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("save-default", params, socket) do
    case DriveSettings.put_default(save_attrs(params)) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Platform default saved.") |> load()}
      {:error, {:bad_request, msg}} -> {:noreply, put_flash(socket, :error, msg)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete-default", _params, socket) do
    case DriveSettings.delete_default() do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Platform default removed.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  defp save_attrs(params) do
    %{"base_url" => params["base_url"] || "", "enabled" => params["enabled"] == "true"}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl space-y-6">
      <h1 class="text-xl font-semibold">Drive</h1>
      <p class="text-sm text-neutral-500">
        Agents read and write a group's Drive at <code>/drive/...</code> through the
        Synchronicity control plane named here. Each group also needs a Drive binding
        (its org, network, space and API key) on its group page; Comma creates those for its
        Workspaces, an operator enters them for anything else.
      </p>

      <.card>
        <:title>Tenant settings</:title>
        <:actions>
          <.badge :if={@settings["source"] == "default"} color="brand">platform default</.badge>
          <.badge color={if @settings["enabled"], do: "green", else: "neutral"}>
            {if @settings["enabled"], do: "enabled", else: "not configured"}
          </.badge>
        </:actions>
        <form id="drive-form" phx-submit="save" class="space-y-3">
          <.input
            name="base_url"
            label="Control plane origin"
            value={@settings["base_url"]}
            placeholder="https://sync.example.com"
          />
          <label class="flex items-center gap-2 text-sm">
            <input type="hidden" name="enabled" value="false" />
            <input type="checkbox" name="enabled" value="true" checked={@settings["enabled"] or @settings["base_url"] == ""} />
            Enabled
          </label>
          <p :if={@settings["source"] == "default"} class="text-xs text-neutral-500">
            Falling back to the platform default. Save an origin here to override it.
          </p>
          <div class="flex justify-between">
            <.button
              type="button"
              variant="danger"
              size="sm"
              phx-click="delete"
              data-confirm="Remove this tenant's Drive settings?"
            >
              Remove
            </.button>
            <.button type="submit" variant="primary" size="sm">Save</.button>
          </div>
        </form>
      </.card>

      <div class="space-y-2 pt-4">
        <h2 class="text-lg font-semibold">Platform default</h2>
        <p class="text-sm text-neutral-500">
          Deployment-wide fallback. A tenant without its own origin uses this one; a group
          binding that names its own origin uses neither.
        </p>
      </div>

      <.card>
        <:title>Default settings</:title>
        <:actions>
          <.badge color={if @default_settings["enabled"], do: "green", else: "neutral"}>
            {if @default_settings["enabled"], do: "enabled", else: "not configured"}
          </.badge>
        </:actions>
        <form id="drive-default-form" phx-submit="save-default" class="space-y-3">
          <.input
            name="base_url"
            label="Control plane origin"
            value={@default_settings["base_url"]}
            placeholder="https://sync.example.com"
          />
          <label class="flex items-center gap-2 text-sm">
            <input type="hidden" name="enabled" value="false" />
            <input type="checkbox" name="enabled" value="true" checked={@default_settings["enabled"] or @default_settings["base_url"] == ""} />
            Enabled
          </label>
          <div class="flex justify-between">
            <.button
              type="button"
              variant="danger"
              size="sm"
              phx-click="delete-default"
              data-confirm="Remove the deployment-wide Drive settings?"
            >
              Remove
            </.button>
            <.button type="submit" variant="primary" size="sm">Save</.button>
          </div>
        </form>
      </.card>
    </div>
    """
  end
end
