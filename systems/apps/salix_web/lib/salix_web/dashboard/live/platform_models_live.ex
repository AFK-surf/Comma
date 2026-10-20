defmodule SalixWeb.Dashboard.PlatformModelsLive do
  @moduledoc """
  The operator page for the platform model (`SalixAgent.PlatformModels`): its
  name, and per tier the internal model that serves it. Members see only the
  name.
  """
  use SalixWeb.Dashboard, :live_view

  alias SalixAgent.{AccountPool, PlatformModels}

  @protocols [
    {"Profile default", ""},
    {"OpenAI Responses", "responses"},
    {"OpenAI Chat Completions", "chat_completions"},
    {"Anthropic Messages", "anthropic"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       active_nav: :platform_models,
       page_title: "Platform model",
       breadcrumbs: [{"Platform model", nil}],
       form: %{},
       profiles: [],
       page_error: nil,
       form_error: nil
     )
     |> load()}
  end

  defp load(socket) do
    with {:ok, settings} <- PlatformModels.get(),
         {:ok, %{"accounts" => accounts}} <- AccountPool.list(AccountPool.platform_tenant()) do
      assign(socket,
        form: settings_form(settings),
        profiles:
          for(
            %{"credential_kind" => "provider_api_key"} = p <- accounts,
            do: {p["name"], p["id"]}
          ),
        page_error: nil,
        form_error: nil
      )
    else
      _ -> assign(socket, page_error: "Platform model settings are unavailable. Retry.")
    end
  end

  defp settings_form(settings) do
    tiers =
      Map.new(PlatformModels.tiers(), fn tier ->
        entry = get_in(settings, ["tiers", tier]) || %{}

        {tier,
         %{
           "profile_id" => entry["profile_id"] || "",
           "model" => entry["model"] || "",
           "protocol" => entry["protocol"] || "",
           "reasoning_effort" => entry["reasoning_effort"] || "",
           "context_tokens" => to_string(entry["context_tokens"] || ""),
           "max_tokens" => to_string(entry["max_tokens"] || ""),
           "images" => entry["images"] == true
         }}
      end)

    %{"name" => settings["name"] || PlatformModels.name(), "tiers" => tiers}
  end

  @impl true
  def handle_event("save", params, socket) do
    tiers =
      Map.new(PlatformModels.tiers(), fn tier ->
        fields = get_in(params, ["tiers", tier]) || %{}
        {tier, entry(fields)}
      end)

    case PlatformModels.put(%{"name" => String.trim(params["name"] || ""), "tiers" => tiers}) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Platform model saved.") |> load()}

      {:error, :conflict} ->
        {:noreply,
         socket |> put_flash(:error, "Someone else saved first. Review, then retry.") |> load()}

      {:error, _} ->
        {:noreply,
         assign(socket,
           form_error:
             "Could not save. A tier needs a platform Profile and a model id; numbers must be positive."
         )}
    end
  end

  def handle_event("retry", _, socket), do: {:noreply, load(socket)}

  # An empty Profile clears the tier.
  defp entry(%{"profile_id" => profile_id} = fields) when profile_id not in [nil, ""] do
    %{
      "profile_id" => profile_id,
      "model" => String.trim(fields["model"] || ""),
      "protocol" => blank(fields["protocol"]),
      "reasoning_effort" => blank(fields["reasoning_effort"]),
      "context_tokens" => integer(fields["context_tokens"]),
      "max_tokens" => integer(fields["max_tokens"]),
      "images" => fields["images"] == "true"
    }
  end

  defp entry(_fields), do: nil

  defp blank(value) do
    case String.trim(value || "") do
      "" -> nil
      text -> text
    end
  end

  defp integer(value) do
    case Integer.parse(String.trim(value || "")) do
      {number, ""} -> number
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, tiers: PlatformModels.tiers(), protocols: @protocols)

    ~H"""
    <div class="mx-auto max-w-4xl space-y-6">
      <div>
        <h1 class="text-2xl font-semibold tracking-tight">Platform model</h1>
        <p class="mt-2 text-sm text-neutral-500">The one model members can choose besides their own Profiles. Members see only its name; the platform pays for it and meters it against their credits. An Agent that follows the default uses its role's tier. Summary writes meeting notes (else the meeting agent's model does); Transcription transcribes meeting audio.</p>
      </div>
      <div :if={@page_error} role="alert" class="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm"><p>{@page_error}</p><.button type="button" phx-click="retry">Retry</.button></div>
      <form :if={@form != %{}} id="platform-models-form" phx-submit="save" class="space-y-6">
        <.input id="platform-model-name" name="name" label="Name members see" value={@form["name"]} />
        <section :for={tier <- @tiers} class="space-y-3 rounded-lg border border-neutral-200 p-4">
          <h2 class="text-lg font-semibold">{String.capitalize(tier)}</h2>
          <div class="grid gap-3 sm:grid-cols-2">
            <.select id={"tier-#{tier}-profile"} name={"tiers[#{tier}][profile_id]"} label="Platform Profile" options={@profiles} prompt="Not configured" value={@form["tiers"][tier]["profile_id"]} />
            <.input id={"tier-#{tier}-model"} name={"tiers[#{tier}][model]"} label="Model id at that Profile" value={@form["tiers"][tier]["model"]} />
            <.select id={"tier-#{tier}-protocol"} name={"tiers[#{tier}][protocol]"} label="Protocol" options={@protocols} value={@form["tiers"][tier]["protocol"]} />
            <.input id={"tier-#{tier}-effort"} name={"tiers[#{tier}][reasoning_effort]"} label="Reasoning effort" value={@form["tiers"][tier]["reasoning_effort"]} placeholder="Model default" />
            <.input id={"tier-#{tier}-context"} name={"tiers[#{tier}][context_tokens]"} label="Context tokens" value={@form["tiers"][tier]["context_tokens"]} />
            <.input id={"tier-#{tier}-max"} name={"tiers[#{tier}][max_tokens]"} label="Max output tokens" value={@form["tiers"][tier]["max_tokens"]} />
          </div>
          <label class="inline-flex items-center gap-2 text-sm"><input type="hidden" name={"tiers[#{tier}][images]"} value="false" /><input type="checkbox" id={"tier-#{tier}-images"} name={"tiers[#{tier}][images]"} value="true" checked={@form["tiers"][tier]["images"]} /> Accepts images</label>
        </section>
        <p :if={@form_error} role="alert" class="text-sm text-red-700">{@form_error}</p>
        <.button type="submit" variant="primary">Save</.button>
      </form>
    </div>
    """
  end
end
