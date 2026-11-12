defmodule SalixWeb.Dashboard.PlatformModelsLive do
  @moduledoc """
  The operator page for the platform model (`SalixAgent.PlatformModels`): its
  name, per tier the internal model that serves it, and the platform route
  table with its learning, which chooses the Worker tier's model per Task.
  Members see only the name.
  """
  use SalixWeb.Dashboard, :live_view

  alias SalixAgent.{AccountPool, PlatformModels}
  alias SalixWeb.Dashboard.{RoutingForm, RoutingModels}

  @routing_events ~w(change-routing add-routing remove-routing reset-routing save-routing refresh-routing-models import-routing export-routing routing-file-error)

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
       form_error: nil,
       routing_saving: false
     )
     |> load()}
  end

  defp load(socket) do
    with {:ok, settings} <- PlatformModels.get(),
         {:ok, %{"accounts" => accounts}} <- AccountPool.list(AccountPool.platform_tenant()) do
      socket
      |> assign(
        form: settings_form(settings),
        profiles:
          for(
            %{"credential_kind" => "provider_api_key"} = p <- accounts,
            do: {p["name"], p["id"]}
          ),
        page_error: nil,
        form_error: nil
      )
      |> load_routing(settings["routing"])
    else
      _ -> assign(socket, page_error: "Platform model settings are unavailable. Retry.")
    end
  end

  defp load_routing(socket, policy) do
    assign(socket,
      routing_policy: policy,
      routing_rows: RoutingForm.rows(policy),
      routing_enabled: policy != nil and policy["enabled"] != false,
      routing_learning: RoutingForm.learning?(policy),
      routing_learned: routing_learned(policy),
      routing_models: routing_models(),
      routing_saving: false,
      routing_error: nil,
      routing_dirty: false
    )
  end

  # The models the platform's API keys serve: the platform table routes to these.
  defp routing_models do
    case RoutingModels.platform_models() do
      {:ok, models} -> models
      {:error, _} -> []
    end
  end

  # What each route has learned, by key: its best model so far and its samples.
  defp routing_learned(policy) do
    with true <- RoutingForm.learning?(policy),
         {:ok, %{"routes" => routes}} <- Salix.TaskRoutingLearning.platform_summary(policy) do
      for route <- routes, best = List.first(route["arms"]), into: %{} do
        {route["key"],
         %{"label" => RoutingForm.arm_label(best["choice"]), "tasks" => route["revision"]}}
      end
    else
      _ -> %{}
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
           "images" => entry["images"] == true,
           "fallback_model" => entry["fallback_model"] || ""
         }}
      end)

    %{"name" => settings["name"] || PlatformModels.name(), "tiers" => tiers}
  end

  @impl true
  def handle_event(event, _, %{assigns: %{routing_saving: true}} = socket)
      when event in @routing_events,
      do: {:noreply, socket}

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

  def handle_event("import-routing", %{"json" => json}, socket) do
    case RoutingForm.import_table(json) do
      {:ok, rows} ->
        {:noreply, assign(socket, routing_rows: rows, routing_dirty: true, routing_error: nil)}

      {:error, message} ->
        {:noreply, assign(socket, routing_error: message)}
    end
  end

  def handle_event("export-routing", _, socket) do
    case RoutingForm.export_table(socket.assigns.routing_rows) do
      {:ok, json} ->
        {:noreply,
         push_event(socket, "download-routing", %{
           filename: "platform-model-routing.json",
           json: json
         })}

      {:error, message} ->
        {:noreply, assign(socket, routing_error: message)}
    end
  end

  def handle_event("routing-file-error", %{"reason" => reason}, socket) do
    message =
      if reason == "too_large",
        do: "Choose a JSON file no larger than 64 KiB.",
        else: "Could not read this file. Choose the JSON file again."

    {:noreply, assign(socket, routing_error: message)}
  end

  def handle_event("change-routing", %{"routing" => params}, socket) do
    rows =
      RoutingForm.change(
        socket.assigns.routing_rows,
        params["rows"] || %{},
        socket.assigns.routing_models
      )

    enabled = params["enabled"] == "true"
    learning = params["learning"] == "true"

    dirty =
      socket.assigns.routing_dirty or rows != socket.assigns.routing_rows or
        enabled != socket.assigns.routing_enabled or
        learning != socket.assigns.routing_learning

    {:noreply,
     assign(socket,
       routing_rows: rows,
       routing_enabled: enabled,
       routing_learning: learning,
       routing_dirty: dirty,
       routing_error: nil
     )}
  end

  def handle_event("add-routing", _, socket) do
    rows = RoutingForm.add(socket.assigns.routing_rows)
    {:noreply, assign(socket, routing_rows: rows, routing_dirty: true, routing_error: nil)}
  end

  def handle_event("remove-routing", %{"id" => id}, socket) do
    rows = Map.delete(socket.assigns.routing_rows, id)
    {:noreply, assign(socket, routing_rows: rows, routing_dirty: true, routing_error: nil)}
  end

  def handle_event("refresh-routing-models", _, socket),
    do: {:noreply, assign(socket, routing_models: routing_models())}

  def handle_event("reset-routing", _, socket), do: {:noreply, load(socket)}

  def handle_event("save-routing", %{"routing" => params}, socket) do
    models = routing_models()
    rows = RoutingForm.change(socket.assigns.routing_rows, params["rows"] || %{}, models)
    enabled = params["enabled"] == "true"
    learning = params["learning"] == "true"
    original = socket.assigns.routing_policy

    result =
      with {:ok, policy} <- RoutingForm.policy(original, rows, enabled, models, learning) do
        PlatformModels.put_routing(original, policy)
      end

    case result do
      {:ok, _policy} ->
        {:noreply,
         socket
         |> put_flash(:info, "Platform routing saved. New tasks use this configuration.")
         |> load()}

      {:error, :conflict} ->
        {:noreply,
         socket |> put_flash(:error, "Someone else saved first. Review, then retry.") |> load()}

      {:error, message} when is_binary(message) ->
        {:noreply,
         assign(socket,
           routing_rows: rows,
           routing_enabled: enabled,
           routing_learning: learning,
           routing_error: message,
           routing_dirty: true
         )}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           routing_rows: rows,
           routing_enabled: enabled,
           routing_learning: learning,
           routing_error:
             "Could not save. Each entry must use a model a platform API key serves.",
           routing_dirty: true
         )}
    end
  end

  # An empty Profile clears the tier.
  defp entry(%{"profile_id" => profile_id} = fields) when profile_id not in [nil, ""] do
    %{
      "profile_id" => profile_id,
      "model" => String.trim(fields["model"] || ""),
      "protocol" => blank(fields["protocol"]),
      "reasoning_effort" => blank(fields["reasoning_effort"]),
      "context_tokens" => integer(fields["context_tokens"]),
      "max_tokens" => integer(fields["max_tokens"]),
      "images" => fields["images"] == "true",
      "fallback_model" => blank(fields["fallback_model"])
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
          <p :if={tier == "worker"} class="text-sm text-neutral-500">While platform model routing below is on, a Task runs the model its route returns instead.</p>
          <div class="grid gap-3 sm:grid-cols-2">
            <.select id={"tier-#{tier}-profile"} name={"tiers[#{tier}][profile_id]"} label="Platform Profile" options={@profiles} prompt="Not configured" value={@form["tiers"][tier]["profile_id"]} />
            <.input id={"tier-#{tier}-model"} name={"tiers[#{tier}][model]"} label="Model id at that Profile" value={@form["tiers"][tier]["model"]} />
            <.select id={"tier-#{tier}-protocol"} name={"tiers[#{tier}][protocol]"} label="Protocol" options={@protocols} value={@form["tiers"][tier]["protocol"]} />
            <.input id={"tier-#{tier}-effort"} name={"tiers[#{tier}][reasoning_effort]"} label="Reasoning effort" value={@form["tiers"][tier]["reasoning_effort"]} placeholder="Model default" />
            <.input id={"tier-#{tier}-context"} name={"tiers[#{tier}][context_tokens]"} label="Context tokens" value={@form["tiers"][tier]["context_tokens"]} />
            <.input id={"tier-#{tier}-max"} name={"tiers[#{tier}][max_tokens]"} label="Max output tokens" value={@form["tiers"][tier]["max_tokens"]} />
            <.input :if={tier == "transcription"} id={"tier-#{tier}-fallback"} name={"tiers[#{tier}][fallback_model]"} label="Model for declined audio, at the same Profile" value={@form["tiers"][tier]["fallback_model"]} placeholder="None" />
          </div>
          <label class="inline-flex items-center gap-2 text-sm"><input type="hidden" name={"tiers[#{tier}][images]"} value="false" /><input type="checkbox" id={"tier-#{tier}-images"} name={"tiers[#{tier}][images]"} value="true" checked={@form["tiers"][tier]["images"]} /> Accepts images</label>
        </section>
        <p :if={@form_error} role="alert" class="text-sm text-red-700">{@form_error}</p>
        <.button type="submit" variant="primary">Save</.button>
      </form>
      <div :if={@form != %{}} class="space-y-2">
        <h2 class="text-lg font-semibold">Platform model routing</h2>
        <p class="text-sm text-neutral-500">Chooses the Worker tier's model for each new Task that runs the platform model, in a group without a route table of its own. Each entry names a model a platform API key serves. Its learning is the platform's own: group route tables never read or write it.</p>
        <SalixWeb.Dashboard.RoutingPanel.panel
          scope="platform"
          enabled={@routing_enabled} learning={@routing_learning} learned={@routing_learned}
          rows={@routing_rows} policy={@routing_policy}
          error={@routing_error} dirty={@routing_dirty} models={@routing_models}
          saving={@routing_saving} />
      </div>
    </div>
    """
  end
end
