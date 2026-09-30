defmodule SalixWeb.Dashboard.OAuthLive do
  @moduledoc """
  Configure OAuth provider-app credentials (client id/secret) per provider —
  the current tenant's apps, plus the deployment-wide platform defaults that
  tenants without their own credentials fall back to.
  """
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.OAuthApps

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(active_nav: :oauth, page_title: "OAuth Apps", breadcrumbs: [{"OAuth Apps", nil}])
     |> load()}
  end

  # OAuth list calls return a plain list, or `{:error, :unavailable}` when the
  # control store is down. Fall back to an error state with empty lists so the
  # template never iterates a non-list (which would crash the LiveView).
  defp load(socket) do
    with apps when is_list(apps) <- OAuthApps.list(socket.assigns.current_tenant),
         defaults when is_list(defaults) <- OAuthApps.list_defaults(),
         remote when is_list(remote) <- OAuthApps.list_remote_mcp(socket.assigns.current_tenant) do
      assign(socket, apps: apps, default_apps: defaults, remote_mcp_apps: remote, load_error: nil)
    else
      _ ->
        assign(socket,
          apps: [],
          default_apps: [],
          remote_mcp_apps: [],
          load_error:
            "OAuth apps are temporarily unavailable — the control store could not be reached."
        )
    end
  end

  @impl true
  def handle_event("save", %{"provider" => provider} = params, socket) do
    attrs = %{"client_id" => params["client_id"], "client_secret" => params["client_secret"]}

    case OAuthApps.put(socket.assigns.current_tenant, provider, attrs) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "#{provider} saved.") |> load()}
      {:error, {:bad_request, msg}} -> {:noreply, put_flash(socket, :error, msg)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete", %{"provider" => provider}, socket) do
    case OAuthApps.delete(socket.assigns.current_tenant, provider) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "#{provider} removed.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("save-default", %{"provider" => provider} = params, socket) do
    attrs = %{"client_id" => params["client_id"], "client_secret" => params["client_secret"]}

    case OAuthApps.put_default(provider, attrs) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "#{provider} platform default saved.") |> load()}

      {:error, {:bad_request, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete-default", %{"provider" => provider}, socket) do
    case OAuthApps.delete_default(provider) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "#{provider} platform default removed.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("save-remote-mcp", params, socket) do
    provider_key = params["provider_key"] || params["provider"]

    attrs = %{
      "client_id" => params["client_id"],
      "client_secret" => params["client_secret"],
      "token_endpoint_auth_method" => params["token_endpoint_auth_method"]
    }

    case OAuthApps.put_remote_mcp(socket.assigns.current_tenant, provider_key, attrs) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Remote MCP client saved.") |> load()}

      {:error, {:bad_request, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete-remote-mcp", %{"provider-key" => provider_key}, socket) do
    case OAuthApps.delete_remote_mcp(socket.assigns.current_tenant, provider_key) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Remote MCP client removed.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-xl font-semibold">OAuth provider apps</h1>
      <p class="text-sm text-neutral-500">
        Client credentials used for group OAuth bindings. Secrets are write-only and never shown back.
      </p>

      <div :if={@load_error} class="rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-700">
        {@load_error}
      </div>

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <.card :for={app <- @apps}>
          <:title>{app["provider"]}</:title>
          <:actions>
            <.badge :if={app["source"] == "default"} color="brand">platform default</.badge>
            <.badge color={if app["client_secret_configured"], do: "green", else: "neutral"}>
              {if app["client_secret_configured"], do: "configured", else: "not set"}
            </.badge>
          </:actions>
          <form id={"oauth-form-#{app["provider"]}"} phx-submit="save" class="space-y-3">
            <input type="hidden" name="provider" value={app["provider"]} />
            <.input name="client_id" label="Client ID" value={app["client_id"]} />
            <.input
              type="password"
              name="client_secret"
              label="Client secret"
              placeholder={if app["client_secret_configured"], do: "•••••• (leave blank to keep)", else: ""}
            />
            <p :if={app["source"] == "default"} class="text-xs text-neutral-500">
              Falling back to the platform default ({app["default_client_id"]}). Save tenant
              credentials here to override it.
            </p>
            <div class="flex justify-between">
              <.button
                type="button"
                variant="danger"
                size="sm"
                phx-click="delete"
                phx-value-provider={app["provider"]}
                data-confirm={"Remove #{app["provider"]} credentials?"}
              >
                Remove
              </.button>
              <.button type="submit" variant="primary" size="sm">Save</.button>
            </div>
          </form>
        </.card>
      </div>

      <div class="space-y-2 pt-4">
        <h2 class="text-lg font-semibold">Platform defaults</h2>
        <p class="text-sm text-neutral-500">
          Deployment-wide fallback credentials. A tenant without its own complete client
          id/secret pair for a provider automatically uses these; tenant credentials always
          win when present. Defaults apply to every tenant of this deployment.
        </p>
      </div>

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <.card :for={app <- @default_apps}>
          <:title>{app["provider"]}</:title>
          <:actions>
            <.badge color={if app["client_secret_configured"], do: "green", else: "neutral"}>
              {if app["client_secret_configured"], do: "configured", else: "not set"}
            </.badge>
          </:actions>
          <form
            id={"oauth-default-form-#{app["provider"]}"}
            phx-submit="save-default"
            class="space-y-3"
          >
            <input type="hidden" name="provider" value={app["provider"]} />
            <.input name="client_id" label="Client ID" value={app["client_id"]} />
            <.input
              type="password"
              name="client_secret"
              label="Client secret"
              placeholder={if app["client_secret_configured"], do: "•••••• (leave blank to keep)", else: ""}
            />
            <div class="flex justify-between">
              <.button
                type="button"
                variant="danger"
                size="sm"
                phx-click="delete-default"
                phx-value-provider={app["provider"]}
                data-confirm={"Remove the #{app["provider"]} platform default?"}
              >
                Remove
              </.button>
              <.button type="submit" variant="primary" size="sm">Save</.button>
            </div>
          </form>
        </.card>
      </div>

      <div class="space-y-2 pt-4">
        <h2 class="text-lg font-semibold">Remote MCP static clients</h2>
        <p class="text-sm text-neutral-500">
          Client credentials for remote MCP providers that do not support dynamic client registration.
          Use the provider key shown on the MCP binding status when authorization reports missing client config.
        </p>
      </div>

      <.card>
        <:title>Add remote MCP client</:title>
        <form id="oauth-remote-mcp-new" phx-submit="save-remote-mcp" class="space-y-3">
          <.input name="provider_key" label="Provider key" placeholder="mcp_..." />
          <.input name="client_id" label="Client ID" />
          <.input type="password" name="client_secret" label="Client secret" />
          <.select
            name="token_endpoint_auth_method"
            label="Token endpoint auth"
            value="client_secret_post"
            options={[
              {"client_secret_post", "client_secret_post"},
              {"client_secret_basic", "client_secret_basic"}
            ]}
          />
          <div class="flex justify-end">
            <.button type="submit" variant="primary" size="sm">Save</.button>
          </div>
        </form>
      </.card>

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <.card :for={app <- @remote_mcp_apps}>
          <:title>{app["provider_key"]}</:title>
          <:actions>
            <.badge color={if app["client_secret_configured"], do: "green", else: "neutral"}>
              {if app["client_secret_configured"], do: "configured", else: "not set"}
            </.badge>
          </:actions>
          <form id={"oauth-remote-mcp-form-#{app["provider_key"]}"} phx-submit="save-remote-mcp" class="space-y-3">
            <input type="hidden" name="provider_key" value={app["provider_key"]} />
            <.input name="client_id" label="Client ID" value={app["client_id"]} />
            <.input
              type="password"
              name="client_secret"
              label="Client secret"
              placeholder={if app["client_secret_configured"], do: "•••••• (leave blank to keep)", else: ""}
            />
            <.select
              name="token_endpoint_auth_method"
              label="Token endpoint auth"
              value={app["token_endpoint_auth_method"] || "client_secret_post"}
              options={[
                {"client_secret_post", "client_secret_post"},
                {"client_secret_basic", "client_secret_basic"}
              ]}
            />
            <div class="flex justify-between">
              <.button
                type="button"
                variant="danger"
                size="sm"
                phx-click="delete-remote-mcp"
                phx-value-provider-key={app["provider_key"]}
                data-confirm={"Remove remote MCP client #{app["provider_key"]}?"}
              >
                Remove
              </.button>
              <.button type="submit" variant="primary" size="sm">Save</.button>
            </div>
          </form>
        </.card>
      </div>
    </div>
    """
  end
end
