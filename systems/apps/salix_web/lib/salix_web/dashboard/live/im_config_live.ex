defmodule SalixWeb.Dashboard.IMConfigLive do
  @moduledoc """
  Configure the tenant IM integrations (slack, telegram, discord, imessage,
  meetings). The config is a single JSON document (`im_integrations`); each
  top-level key is a platform/section, edited here as JSON and patched via the
  tenant config API.
  """
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.Tenants
  alias SalixWeb.Dashboard.Format

  @sections ~w(slack telegram discord imessage meetings)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       active_nav: :im,
       page_title: "IM configuration",
       breadcrumbs: [{"IM", "/dash/im"}, {"Configuration", nil}],
       sections: @sections
     )
     |> load()}
  end

  defp load(socket) do
    {:ok, config} =
      Tenants.get_config(socket.assigns.current_tenant, "im_integrations", %{})

    assign(socket, config: config, text: Format.pretty_json(config))
  end

  @impl true
  def handle_event("save", %{"config" => text}, socket) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) ->
        case Tenants.update_config(
               socket.assigns.current_tenant,
               "im_integrations",
               map
             ) do
          {:ok, config} ->
            {:noreply,
             socket
             |> put_flash(:info, "IM config saved.")
             |> assign(config: config, text: Format.pretty_json(config))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Config must be a valid JSON object.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-xl font-semibold">IM configuration</h1>
        <p class="mt-1 text-sm text-neutral-500">
          Sections: {Enum.join(@sections, ", ")}. Edit the JSON document and save.
        </p>
      </div>

      <form id="im-config-form" phx-submit="save" class="space-y-3">
        <.textarea name="config" rows="22" value={@text} />
        <div class="flex justify-end">
          <.button type="submit" variant="primary">Save IM config</.button>
        </div>
      </form>

      <.card>
        <:title>Configured sections</:title>
        <div class="flex flex-wrap gap-2">
          <.badge :for={s <- @sections} color={if Map.has_key?(@config, s), do: "green", else: "neutral"}>
            {s} {if Map.has_key?(@config, s), do: "✓", else: "—"}
          </.badge>
        </div>
      </.card>
    </div>
    """
  end
end
