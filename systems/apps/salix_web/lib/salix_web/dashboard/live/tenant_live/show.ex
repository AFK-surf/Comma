defmodule SalixWeb.Dashboard.TenantLive.Show do
  @moduledoc """
  Tenant detail: config editing, API key management and the tenant's own
  Signal number (`Salix.Control.Signal`, docs/messaging-voice.md).
  """
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.Tenants
  alias SalixWeb.Dashboard.Format

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Tenants.get(id) do
      {:ok, tenant} ->
        {:ok,
         socket
         |> assign(
           active_nav: :tenants,
           tenant_id: id,
           tenant: tenant,
           page_title: tenant["name"],
           breadcrumbs: [{"Tenants", "/dash/tenants"}, {tenant["name"], nil}],
           config_text: Format.pretty_json(tenant["config"] || "{}"),
           new_key: nil
         )
         |> load_keys()
         |> load_signal()}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Tenant not found.")
         |> push_navigate(to: "/dash/tenants")}
    end
  end

  defp load_keys(socket) do
    case Tenants.list_api_keys(socket.assigns.tenant_id) do
      {:error, :unavailable} ->
        socket
        |> assign(api_keys: [])
        |> put_flash(:error, "API keys are temporarily unavailable.")

      keys when is_list(keys) ->
        assign(socket, api_keys: keys)
    end
  end

  defp load_signal(socket) do
    case Salix.Control.Signal.tenant_number(socket.assigns.tenant_id) do
      {:ok, view} -> assign(socket, signal: view, signal_error: nil)
      {:error, reason} -> assign(socket, signal: nil, signal_error: inspect(reason))
    end
  end

  @impl true
  def handle_event("save-signal", %{"number" => number}, socket) do
    case Salix.Control.Signal.put_tenant_number(socket.assigns.tenant_id, %{"number" => number}) do
      {:ok, view} ->
        {:noreply, socket |> put_flash(:info, "Signal number saved.") |> assign(signal: view)}

      {:error, reason} ->
        {_status, error} = Salix.Control.Signal.http_error(reason)
        {:noreply, put_flash(socket, :error, "Signal number not saved: #{error}")}
    end
  end

  def handle_event("save-config", %{"config" => config}, socket) do
    case Jason.decode(config) do
      {:ok, _} ->
        case Tenants.update(socket.assigns.tenant_id, %{"config" => config}) do
          {:ok, tenant} ->
            {:noreply,
             socket
             |> put_flash(:info, "Config saved.")
             |> assign(tenant: tenant, config_text: Format.pretty_json(config))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Config must be valid JSON.")}
    end
  end

  def handle_event("create-key", %{"name" => name}, socket) do
    case Tenants.create_api_key(socket.assigns.tenant_id, %{"name" => name}) do
      {:ok, rec} ->
        {:noreply,
         socket
         |> put_flash(:info, "API key created — copy it now, it won't be shown again.")
         |> assign(new_key: rec["key"])
         |> load_keys()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete-key", %{"hash" => hash}, socket) do
    case Tenants.delete_api_key(socket.assigns.tenant_id, hash) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "API key deleted.") |> load_keys()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("dismiss-key", _params, socket), do: {:noreply, assign(socket, new_key: nil)}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-xl font-semibold">{@tenant["name"]}</h1>
        <p class="mt-1 font-mono text-xs text-neutral-500">{@tenant["tenant_id"]}</p>
      </div>

      <.card>
        <:title>Configuration (JSON)</:title>
        <form phx-submit="save-config" class="space-y-3">
          <.textarea name="config" rows="12" value={@config_text} />
          <div class="flex justify-end">
            <.button type="submit" variant="primary">Save config</.button>
          </div>
        </form>
      </.card>

      <.card>
        <:title>Signal number</:title>
        <p :if={@signal_error} class="text-xs text-red-700">Unavailable: {@signal_error}</p>
        <div :if={@signal} class="space-y-3">
          <p class="text-sm text-neutral-600">
            New Signal connections of this tenant use
            <span id="signal-effective-number" class="font-mono">
              {(@signal["effective"] || %{})["e164"] || "no number"}
            </span>.
            The platform number is {(@signal["platform"] || %{})["e164"] || "not set"}.
            A tenant number overrides it; existing connections keep their number.
          </p>
          <form id="tenant-signal-number" phx-submit="save-signal" class="flex items-end gap-2">
            <.input
              name="number"
              label="Tenant Signal number (E.164, blank for the platform number)"
              value={(@signal["override"] || %{})["e164"]}
              class="w-64"
            />
            <.button type="submit" variant="primary">Save</.button>
          </form>
        </div>
      </.card>

      <.card>
        <:title>API keys</:title>
        <:actions>
          <form phx-submit="create-key" class="flex items-end gap-2">
            <.input name="name" placeholder="Key name" class="w-44" />
            <.button type="submit" variant="primary">Create</.button>
          </form>
        </:actions>

        <div
          :if={@new_key}
          class="mb-3 flex items-center justify-between gap-2 rounded-md border border-amber-200 bg-amber-50 px-3 py-2"
        >
          <div class="min-w-0">
            <p class="text-xs font-medium text-amber-800">New key (copy now)</p>
            <p class="truncate font-mono text-xs text-amber-900">{@new_key}</p>
          </div>
          <.button size="sm" phx-click="dismiss-key">Dismiss</.button>
        </div>

        <.table :if={@api_keys != []} id="api-keys" rows={@api_keys}>
          <:col :let={k} label="Name">{k["name"]}</:col>
          <:col :let={k} label="Hash"><span class="font-mono text-xs">{Format.short_id(k["key_hash"])}</span></:col>
          <:col :let={k} label="Created">{Format.time_ago(k["created_at"])}</:col>
          <:action :let={k}>
            <.button
              size="sm"
              variant="danger"
              phx-click="delete-key"
              phx-value-hash={k["key_hash"]}
              data-confirm="Delete this API key?"
            >
              Delete
            </.button>
          </:action>
        </.table>
        <.empty_state :if={@api_keys == []} icon="key" title="No API keys" />
      </.card>
    </div>
    """
  end
end
