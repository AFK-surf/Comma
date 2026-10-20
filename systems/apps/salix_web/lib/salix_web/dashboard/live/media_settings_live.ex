defmodule SalixWeb.Dashboard.MediaSettingsLive do
  @moduledoc """
  The operator page for the platform's media settings
  (`SalixAgent.MediaSettings`): the image, video, vision describer and
  analyzer configurations of Agents that hold a model choice instead of a
  template. Each is the JSON a template's media field takes.
  """
  use SalixWeb.Dashboard, :live_view

  alias SalixAgent.MediaSettings

  @labels %{
    "image_config" => "Image generation",
    "video_config" => "Video",
    "vision_describer_config" => "Vision describer",
    "analyze_config" => "Analysis"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       active_nav: :media_settings,
       page_title: "Media settings",
       breadcrumbs: [{"Media settings", nil}],
       form: %{},
       errors: %{},
       page_error: nil
     )
     |> load()}
  end

  defp load(socket) do
    case MediaSettings.get() do
      {:ok, settings} ->
        form = Map.new(MediaSettings.purposes(), &{&1, json_text(settings[&1])})
        assign(socket, form: form, errors: %{}, page_error: nil)

      {:error, _} ->
        assign(socket,
          page_error: "Media settings are unavailable. Check storage access, then retry."
        )
    end
  end

  defp json_text(nil), do: ""
  defp json_text(config) when config == %{}, do: ""
  defp json_text(config), do: Jason.encode!(config, pretty: true)

  @impl true
  def handle_event("save", params, socket) do
    form = Map.take(params, MediaSettings.purposes())

    decoded =
      Map.new(form, fn {purpose, text} ->
        case String.trim(text || "") do
          "" -> {purpose, {:ok, nil}}
          json -> {purpose, decode(json)}
        end
      end)

    errors =
      for {purpose, {:error, message}} <- decoded, into: %{}, do: {purpose, message}

    if errors == %{} do
      case MediaSettings.put(
             Map.new(decoded, fn {purpose, {:ok, config}} -> {purpose, config} end)
           ) do
        {:ok, _} ->
          {:noreply, socket |> put_flash(:info, "Media settings saved.") |> load()}

        {:error, :conflict} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             "Someone else saved first. Review the current settings, then retry."
           )
           |> load()}

        {:error, _} ->
          {:noreply, assign(socket, form: form, page_error: "Could not save media settings.")}
      end
    else
      {:noreply, assign(socket, form: form, errors: errors)}
    end
  end

  def handle_event("retry", _, socket), do: {:noreply, load(socket)}

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, config} when is_map(config) -> {:ok, config}
      _ -> {:error, "Enter a JSON object, or leave it empty."}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, purposes: MediaSettings.purposes(), labels: @labels)

    ~H"""
    <div class="mx-auto max-w-4xl space-y-6">
      <div>
        <h1 class="text-2xl font-semibold tracking-tight">Media settings</h1>
        <p class="mt-2 text-sm text-neutral-500">Image, video, vision and analysis models for Agents that choose a model instead of a template. The platform pays for them.</p>
      </div>
      <div :if={@page_error} role="alert" class="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm"><p>{@page_error}</p><.button type="button" phx-click="retry">Retry</.button></div>
      <form id="media-settings-form" phx-submit="save" class="space-y-4">
        <.textarea :for={purpose <- @purposes} id={"media-" <> purpose} name={purpose} label={@labels[purpose]} value={@form[purpose]} rows="6" errors={List.wrap(@errors[purpose])} hint="The same JSON as a template's media field. Empty turns it off." />
        <.button type="submit" variant="primary">Save</.button>
      </form>
    </div>
    """
  end
end
