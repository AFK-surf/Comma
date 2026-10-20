defmodule SalixWeb.Dashboard.InitialAgentLive.Form do
  @moduledoc """
  Create (`:new`) and edit (`:edit`) a tenant initial-agent slot. Both actions
  use the initial-agent seed control API; on `:edit` the slot key is fixed
  (taken from the URL), on `:new` the operator chooses it.
  """
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.InitialAgentSeeds
  alias SalixWeb.Dashboard.ModelField

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, active_nav: :initial_agents, model: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, init(socket, params)}

  defp init(socket, %{"slot" => slot}) do
    case InitialAgentSeeds.get(slot, socket.assigns.current_tenant) do
      {:ok, agent} ->
        assign(socket,
          action: :edit,
          slot: slot,
          page_title: "Initial agent: #{slot}",
          breadcrumbs: [{"Initial agents", "/dash/initial-agents"}, {slot, nil}],
          model: agent["model"],
          form: form_from(agent)
        )

      {:error, _} ->
        socket
        |> put_flash(:error, "Initial agent slot not found.")
        |> push_navigate(to: "/dash/initial-agents")
    end
  end

  defp init(socket, _params) do
    assign(socket,
      action: :new,
      slot: nil,
      page_title: "New initial agent",
      breadcrumbs: [{"Initial agents", "/dash/initial-agents"}, {"New", nil}],
      form: form_from(%{})
    )
  end

  # Build the form map from an initial-agent record (or a blank map for :new).
  defp form_from(a) do
    %{
      "slot" => a["slot"] || "",
      "display_name" => a["display_name"] || "",
      "description" => a["description"] || "",
      "model" => ModelField.value(a["model"]),
      "avatar_url" => a["avatar_url"] || "",
      "is_router" => !!a["is_router"],
      "is_default" => !!a["is_default"],
      "enabled" => Map.get(a, "enabled", true) != false,
      "sort_order" => to_string(a["sort_order"] || 0)
    }
  end

  @impl true
  def handle_event("save", params, socket) do
    slot = socket.assigns.slot || params["slot"]
    attrs = build_attrs(params, socket.assigns.model)

    case InitialAgentSeeds.put(slot, attrs, socket.assigns.current_tenant) do
      {:ok, agent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Initial agent saved.")
         |> push_navigate(to: "/dash/initial-agents/#{agent["slot"]}")}

      {:error, {:bad_request, msg}} ->
        {:noreply, socket |> put_flash(:error, msg) |> assign(form: merge_form(params))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Save failed: #{inspect(reason)}")
         |> assign(form: merge_form(params))}
    end
  end

  # Parse form params into upsert attrs. The seed API derives `role` from
  # `is_router` and enforces the default/router constraints, so we send the
  # toggles rather than a role and surface any rejection as a flash.
  defp build_attrs(params, current_model) do
    model =
      case ModelField.change(params["model"], current_model) do
        :keep -> current_model
        model -> model
      end

    %{
      "model" => model,
      "display_name" => params["display_name"],
      "description" => params["description"],
      "avatar_url" => params["avatar_url"],
      "is_router" => params["is_router"] == "true",
      "is_default" => params["is_default"] == "true",
      "enabled" => params["enabled"] == "true",
      "sort_order" => to_int(params["sort_order"], 0)
    }
  end

  # Re-render the submitted values on error (booleans come back as the
  # "true"/absent checkbox encoding).
  defp merge_form(params) do
    %{
      "slot" => params["slot"] || "",
      "display_name" => params["display_name"] || "",
      "description" => params["description"] || "",
      "model" => params["model"] || "",
      "avatar_url" => params["avatar_url"] || "",
      "is_router" => params["is_router"] == "true",
      "is_default" => params["is_default"] == "true",
      "enabled" => params["enabled"] == "true",
      "sort_order" => params["sort_order"] || "0"
    }
  end

  defp to_int(v, default) do
    case Integer.parse(to_string(v || "")) do
      {n, _} -> n
      :error -> default
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-xl font-semibold">{@page_title}</h1>

      <form phx-submit="save" class="space-y-5">
        <.card>
          <:title>Slot</:title>
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <.input
              :if={@action == :new}
              name="slot"
              label="Slot key"
              value={@form["slot"]}
              required
              placeholder="main"
              hint="Letters, digits, dot, dash, underscore"
            />
            <div :if={@action == :edit}>
              <p class="block text-xs font-medium text-neutral-600 mb-1">Slot key</p>
              <p class="font-mono text-sm text-neutral-800">{@slot}</p>
            </div>
            <.input name="display_name" label="Display name (optional)" value={@form["display_name"]}
              hint="Defaults to the slot key when blank" />
            <.input name="description" label="Description (optional)" value={@form["description"]} />
            <.input name="avatar_url" label="Avatar URL (optional)" value={@form["avatar_url"]} />
          </div>
        </.card>

        <.card>
          <:title>Model</:title>
          <.select
            name="model"
            label="Model"
            options={ModelField.options(@model)}
            value={@form["model"]}
            prompt="Platform model of the role"
          />
        </.card>

        <.card>
          <:title>Behavior</:title>
          <div class="flex flex-col gap-3">
            <.toggle name="is_default" label="Default slot (must be a worker)" checked={@form["is_default"]} value="true" />
            <.toggle name="is_router" label="Router seed" checked={@form["is_router"]} value="true" />
            <.toggle name="enabled" label="Enabled" checked={@form["enabled"]} value="true" />
          </div>
          <div class="mt-3 max-w-xs">
            <.input type="number" name="sort_order" label="Sort order" value={@form["sort_order"]} />
          </div>
        </.card>

        <div class="flex justify-end gap-2">
          <.button navigate="/dash/initial-agents">Cancel</.button>
          <.button type="submit" variant="primary">Save slot</.button>
        </div>
      </form>
    </div>
    """
  end
end
