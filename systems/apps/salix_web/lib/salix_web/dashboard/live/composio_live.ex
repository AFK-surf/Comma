defmodule SalixWeb.Dashboard.ComposioLive do
  @moduledoc """
  Configure the Composio integrations path — the current tenant's Composio
  project API key (write-only, like OAuth client secrets), plus the
  deployment-wide platform default that tenants without their own key fall
  back to. Groups of an opted-in tenant get the `composio.*` agent tools;
  their connected accounts are managed on the group page's Composio tab.
  """
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.ComposioSettings

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(active_nav: :composio, page_title: "Composio", breadcrumbs: [{"Composio", nil}])
     |> load()}
  end

  defp load(socket) do
    assign(socket,
      settings: ComposioSettings.view(socket.assigns.current_tenant),
      default_settings: ComposioSettings.view_default()
    )
  end

  @impl true
  def handle_event("save", params, socket) do
    case ComposioSettings.put(socket.assigns.current_tenant, save_attrs(params)) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Composio settings saved.") |> load()}
      {:error, {:bad_request, msg}} -> {:noreply, put_flash(socket, :error, msg)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete", _params, socket) do
    case ComposioSettings.delete(socket.assigns.current_tenant) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Composio settings removed.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("save-default", params, socket) do
    case ComposioSettings.put_default(save_attrs(params)) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Platform default saved.") |> load()}

      {:error, {:bad_request, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete-default", _params, socket) do
    case ComposioSettings.delete_default() do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Platform default removed.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  # A blank api_key is dropped so the write keeps the stored secret
  # ("leave blank to keep"); checkbox absence means disabled.
  defp save_attrs(params) do
    attrs = %{
      "base_url" => params["base_url"] || "",
      "enabled" => params["enabled"] == "true"
    }

    case String.trim(to_string(params["api_key"] || "")) do
      "" -> attrs
      api_key -> Map.put(attrs, "api_key", api_key)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl space-y-6">
      <h1 class="text-xl font-semibold">Composio</h1>
      <p class="text-sm text-neutral-500">
        Composio lets agent groups connect third-party toolkits (Gmail, Google Calendar,
        Notion, Linear, …) through Composio-hosted auth and call them directly — no
        per-provider OAuth app setup. The API key is write-only and never shown back.
      </p>

      <.card>
        <:title>Tenant settings</:title>
        <:actions>
          <.badge :if={@settings["source"] == "default"} color="brand">platform default</.badge>
          <.badge color={if @settings["enabled"], do: "green", else: "neutral"}>
            {if @settings["enabled"], do: "enabled", else: "not configured"}
          </.badge>
        </:actions>
        <form id="composio-form" phx-submit="save" class="space-y-3">
          <.input
            type="password"
            name="api_key"
            label="Composio API key"
            placeholder={if @settings["api_key_configured"], do: "•••••• (leave blank to keep)", else: ""}
          />
          <.input
            name="base_url"
            label="Base URL (optional)"
            value={@settings["base_url"]}
            placeholder="https://backend.composio.dev"
          />
          <label class="flex items-center gap-2 text-sm">
            <input type="hidden" name="enabled" value="false" />
            <input type="checkbox" name="enabled" value="true" checked={@settings["enabled"] or not @settings["api_key_configured"]} />
            Enabled
          </label>
          <p :if={@settings["source"] == "default"} class="text-xs text-neutral-500">
            Falling back to the platform default. Save a tenant API key here to override it.
          </p>
          <div class="flex justify-between">
            <.button
              type="button"
              variant="danger"
              size="sm"
              phx-click="delete"
              data-confirm="Remove this tenant's Composio settings?"
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
          Deployment-wide fallback. A tenant without its own enabled API key automatically
          uses this one; tenant settings always win when present.
        </p>
      </div>

      <.card>
        <:title>Default settings</:title>
        <:actions>
          <.badge color={if @default_settings["enabled"], do: "green", else: "neutral"}>
            {if @default_settings["enabled"], do: "enabled", else: "not configured"}
          </.badge>
        </:actions>
        <form id="composio-default-form" phx-submit="save-default" class="space-y-3">
          <.input
            type="password"
            name="api_key"
            label="Composio API key"
            placeholder={if @default_settings["api_key_configured"], do: "•••••• (leave blank to keep)", else: ""}
          />
          <.input
            name="base_url"
            label="Base URL (optional)"
            value={@default_settings["base_url"]}
            placeholder="https://backend.composio.dev"
          />
          <label class="flex items-center gap-2 text-sm">
            <input type="hidden" name="enabled" value="false" />
            <input type="checkbox" name="enabled" value="true" checked={@default_settings["enabled"] or not @default_settings["api_key_configured"]} />
            Enabled
          </label>
          <div class="flex justify-between">
            <.button
              type="button"
              variant="danger"
              size="sm"
              phx-click="delete-default"
              data-confirm="Remove the platform default Composio settings?"
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
