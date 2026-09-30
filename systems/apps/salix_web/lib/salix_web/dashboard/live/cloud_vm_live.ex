defmodule SalixWeb.Dashboard.CloudVMLive do
  @moduledoc """
  Operator page for the deployment-wide platform cloud-VM configuration
  (`SalixWeb.CloudVM.default_vm_config/0`): provider credentials used by
  tenants that explicitly follow platform VM config. Secrets follow the
  write-only convention — the page shows configured-flags and blank secret
  fields keep the stored value.
  """
  use SalixWeb.Dashboard, :live_view

  alias SalixWeb.CloudVM

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       active_nav: :cloud_vm,
       page_title: "Cloud VM",
       breadcrumbs: [{"Cloud VM", nil}]
     )
     |> load()}
  end

  defp load(socket) do
    config = CloudVM.redacted_default_vm_config()
    providers = config["providers"] || %{}

    assign(socket,
      default_provider: config["default_provider"] || "cloudflare",
      cloudflare: providers["cloudflare"] || %{},
      configured?: config != %{}
    )
  end

  @impl true
  def handle_event("save", params, socket) do
    attrs = %{
      "default_provider" => params["default_provider"],
      "providers" => %{
        "cloudflare" =>
          drop_blank(%{
            "enabled" => params["cloudflare_enabled"] == "true",
            "gateway_base_url" => params["cloudflare_gateway_base_url"],
            "gateway_secret" => params["cloudflare_gateway_secret"]
          })
      }
    }

    case CloudVM.put_default_vm_config(attrs) do
      {:ok, _redacted} ->
        {:noreply, socket |> put_flash(:info, "Platform VM defaults saved.") |> load()}

      {:error, {:bad_request, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete", _params, socket) do
    case CloudVM.delete_default_vm_config() do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Platform VM defaults removed.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  # false stays (an explicit cloudflare disable is meaningful); blank strings go.
  defp drop_blank(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_binary(v) and String.trim(v) == "" end)
    |> Map.new()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl space-y-6">
      <div>
        <h1 class="text-xl font-semibold">Cloud VM platform defaults</h1>
        <p class="mt-1 text-sm text-neutral-500">
          Deployment-wide provider credentials for tenants that explicitly follow platform
          <code>vm</code>
          configuration. Organization-owned tenant config stays independent; agents with
          <code>vm.enabled</code>
          use Cloudflare for cloud compute.
          Secrets are write-only and never shown back.
        </p>
      </div>

      <form id="cloud-vm-defaults" phx-submit="save" class="space-y-6">
        <.card>
          <:title>Provider selection</:title>
          <.select
            name="default_provider"
            label="Default provider"
            value={@default_provider}
            options={[{"Cloudflare", "cloudflare"}]}
          />
        </.card>

        <.card>
          <:title>Cloudflare</:title>
          <:actions>
            <.badge color={if @cloudflare["gateway_secret_configured"], do: "green", else: "neutral"}>
              {if @cloudflare["gateway_secret_configured"], do: "secret configured", else: "no secret"}
            </.badge>
          </:actions>
          <div class="space-y-3">
            <label class="flex items-center gap-2 text-sm">
              <input type="hidden" name="cloudflare_enabled" value="false" />
              <input
                type="checkbox"
                name="cloudflare_enabled"
                value="true"
                checked={@cloudflare["enabled"] == true}
                class="h-4 w-4 rounded border-neutral-300"
              /> Enabled
            </label>
            <.input
              name="cloudflare_gateway_base_url"
              label="Gateway base URL"
              value={@cloudflare["gateway_base_url"]}
            />
            <.input
              type="password"
              name="cloudflare_gateway_secret"
              label="Gateway secret"
              placeholder={
                if @cloudflare["gateway_secret_configured"],
                  do: "•••••• (leave blank to keep)",
                  else: ""
              }
            />
          </div>
        </.card>

        <div class="flex justify-between">
          <.button
            :if={@configured?}
            type="button"
            variant="danger"
            size="sm"
            phx-click="delete"
            data-confirm="Remove the platform VM defaults? Tenants following platform vm config lose cloud-VM provisioning."
          >
            Remove defaults
          </.button>
          <.button type="submit" variant="primary" size="sm">Save</.button>
        </div>
      </form>
    </div>
    """
  end
end
