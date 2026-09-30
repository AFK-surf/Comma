defmodule BridgeForTeamsWeb.Dashboard.PrivateTemplatesLive do
  use BridgeForTeamsWeb.Dashboard, :live_view
  alias BridgeForTeams.{Orgs, Subscriptions}

  @impl true
  def mount(%{"org" => slug}, _session, socket) do
    user = socket.assigns.current_user

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, _} <- Subscriptions.authorize({org.id, user.id}) do
      socket =
        assign(socket,
          current_org: org,
          orgs: Orgs.list_orgs_for_user(user.id),
          scope: {org.id, user.id},
          active_nav: :settings,
          page_title: "Private templates",
          breadcrumbs: [
            {org.name, ~p"/orgs/#{org.slug}"},
            {"Models", ~p"/orgs/#{org.slug}/settings/models"},
            {"Private templates", nil}
          ],
          templates: [],
          discovered_models: [],
          model_search: "",
          discovery_truncated: false,
          busy: false,
          loaded: false,
          error: nil,
          dialog: nil,
          selected: nil,
          form: defaults()
        )

      {:ok, if(connected?(socket), do: load(socket), else: socket)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Organization administrator access is required.")
         |> redirect(to: ~p"/orgs")}
    end
  end

  defp defaults,
    do: %{
      "name" => "",
      "subscription_provider" => "codex",
      "model" => "gpt-5.6-sol",
      "max_tokens" => "65536"
    }

  defp load(socket) do
    scope = socket.assigns.scope

    socket
    |> assign(busy: true, error: nil)
    |> start_async(:list, fn -> Subscriptions.templates(scope) end)
  end

  @impl true
  def handle_event(_, _, %{assigns: %{busy: true}} = socket), do: {:noreply, socket}
  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  def handle_event("new", _, socket),
    do:
      {:noreply,
       assign(socket,
         dialog: :edit,
         selected: nil,
         form: defaults(),
         error: nil,
         discovered_models: [],
         model_search: ""
       )}

  def handle_event("close", _, socket),
    do: {:noreply, assign(socket, dialog: nil, selected: nil, error: nil)}

  def handle_event("change", %{"template" => params}, socket) do
    params =
      if params["subscription_provider"] != socket.assigns.form["subscription_provider"],
        do:
          Map.put(
            params,
            "model",
            if(params["subscription_provider"] == "claude",
              do: "claude-sonnet-4-6",
              else: "gpt-5.6-sol"
            )
          ),
        else: params

    changed = params["subscription_provider"] != socket.assigns.form["subscription_provider"]
    models = if changed, do: [], else: socket.assigns.discovered_models
    params = display_values(params, socket.assigns.form, models, changed)
    {:noreply, assign(socket, form: params, discovered_models: models)}
  end

  def handle_event(event, %{"id" => id}, socket) when event in ["edit", "delete"] do
    case Enum.find(
           socket.assigns.templates,
           &(&1["template_id"] == id and &1["subscription_provider"] in ["codex", "claude"])
         ) do
      nil ->
        {:noreply, assign(socket, error: "Refresh the list before changing this template.")}

      template ->
        {:noreply,
         assign(socket,
           selected: template,
           discovered_models: [],
           model_search: "",
           form: template,
           error: nil,
           dialog: if(event == "edit", do: :edit, else: :delete)
         )}
    end
  end

  def handle_event("discover", _, socket) do
    scope = socket.assigns.scope
    pool = socket.assigns.form["subscription_provider"]

    {:noreply,
     socket
     |> assign(busy: true, error: nil)
     |> start_async(:discover, fn -> Subscriptions.discover_models(scope, pool) end)}
  end

  def handle_event("search-models", %{"value" => query}, socket),
    do: {:noreply, assign(socket, model_search: query)}

  def handle_event("choose-model", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.discovered_models, &(&1["id"] == id)) do
      nil ->
        {:noreply, socket}

      model ->
        {:noreply,
         assign(socket,
           form:
             Map.merge(socket.assigns.form, %{
               "model" => id,
               "model_display_name" => model["name"],
               "model_vendor" => model["vendor"]
             })
         )}
    end
  end

  def handle_event("save", %{"template" => params}, socket) do
    params = display_values(params, socket.assigns.form, socket.assigns.discovered_models, false)
    scope = socket.assigns.scope
    id = socket.assigns.selected && socket.assigns.selected["template_id"]

    {:noreply,
     socket
     |> assign(busy: true, error: nil, form: params)
     |> start_async(:save, fn -> Subscriptions.save_template(scope, id, params) end)}
  end

  def handle_event(
        "confirm-delete",
        _,
        %{assigns: %{selected: %{"template_id" => id}, dialog: :delete}} = socket
      ) do
    scope = socket.assigns.scope

    {:noreply,
     socket
     |> assign(busy: true, error: nil)
     |> start_async(:delete, fn -> Subscriptions.delete_template(scope, id) end)}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:discover, {:ok, {:ok, result}}, socket),
    do:
      {:noreply,
       assign(socket,
         busy: false,
         discovered_models: result["data"],
         discovery_truncated: result["truncated"] == true
       )}

  def handle_async(:list, {:ok, {:ok, templates}}, socket),
    do: {:noreply, assign(socket, templates: templates, loaded: true, busy: false)}

  def handle_async(:save, {:ok, {:ok, _}}, socket) do
    {:noreply,
     socket
     |> assign(dialog: nil)
     |> put_flash(
       :info,
       "Template saved. Review allowed models and the organization default in Models."
     )
     |> load()}
  end

  def handle_async(:delete, {:ok, :ok}, socket),
    do: {:noreply, socket |> assign(dialog: nil) |> load()}

  def handle_async(_, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, busy: false, error: operation_error(reason))}

  def handle_async(_, {:exit, _}, socket),
    do: {:noreply, assign(socket, busy: false, error: "The runtime is unavailable. Try again.")}

  defp display_values(form, previous, models, changed) do
    model = unless changed, do: Enum.find(models, &(&1["id"] == form["model"]))

    cond do
      model ->
        Map.merge(form, %{
          "model_display_name" => model["name"],
          "model_vendor" => model["vendor"]
        })

      not changed and form["model"] == previous["model"] ->
        Map.merge(form, Map.take(previous, ~w(model_display_name model_vendor)))

      true ->
        Map.merge(form, %{"model_display_name" => nil, "model_vendor" => nil})
    end
  end

  defp operation_error({kind, message})
       when kind in [:conflict, :bad_request] and is_binary(message), do: message

  defp operation_error(:model_catalog_too_large),
    do:
      "The model catalog exceeds the 100-template interactive limit. Contact a platform administrator."

  defp operation_error(:forbidden), do: "Organization administrator access is required."

  defp operation_error(_),
    do: "Could not complete this operation. Refresh the page and try again."

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-center justify-between gap-3 text-sm">
        <.link navigate={~p"/orgs/#{@current_org.slug}/settings/models"} class="text-brand-600 hover:underline">← Models and access</.link>
        <.link navigate={~p"/orgs/#{@current_org.slug}/settings/subscriptions"} class="text-brand-600 hover:underline">Manage subscriptions →</.link>
      </div>
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div><h1 class="text-xl font-semibold">Private templates</h1><p class="mt-1 text-sm text-neutral-500">Reusable subscription models for {@current_org.name}. Visible only within this organization.</p></div>
        <.button variant="primary" phx-click="new" disabled={@busy}>Create private template</.button>
      </div>
      <div :if={@error && !@dialog} role="alert" class="rounded-md bg-red-50 p-3 text-sm text-red-700">{@error}</div>
      <div class="rounded-lg border border-neutral-200">
        <div class="flex items-center justify-between border-b border-neutral-200 px-4 py-3"><h2 class="text-sm font-medium">Organization templates</h2><.button phx-click="refresh" disabled={@busy} size="sm">Refresh</.button></div>
        <p :if={!@loaded} role="status" class="p-6 text-sm text-neutral-500">Loading templates…</p>
        <div :if={@loaded && @templates == []} class="p-10 text-center"><h2 class="font-medium">Connect once. Reuse across Agents.</h2><p class="mt-2 text-sm text-neutral-500">Connect a Codex or Claude subscription, then create a private template for its model.</p></div>
        <table :if={@templates != []} class="w-full text-left text-sm" aria-label="Private templates">
          <thead class="bg-neutral-50 text-xs text-neutral-500"><tr><th class="px-4 py-3">Template</th><th class="px-4 py-3">Model</th><th class="px-4 py-3">Source</th><th class="px-4 py-3 text-right">Actions</th></tr></thead>
          <tbody class="divide-y divide-neutral-100"><tr :for={template <- @templates} id={"template-" <> template["template_id"]}>
            <td class="px-4 py-4 font-medium">{template["name"]}<span :if={template["template_id"] in [@current_org.default_template_id, @current_org.default_router_template_id]} class="ml-2 text-xs text-brand-600">Default</span><span class="ml-2 text-xs font-normal text-neutral-400">Private</span></td>
            <td class="break-all px-4 py-4">{template["model"]}</td>
            <td class="px-4 py-4 text-neutral-500">{if template["subscription_provider"], do: String.capitalize(template["subscription_provider"]) <> " subscription", else: "Managed in Salix"}</td>
            <td class="px-4 py-4 text-right"><div :if={template["subscription_provider"] in ["codex", "claude"]} class="flex justify-end gap-2">
              <button type="button" phx-click="edit" phx-value-id={template["template_id"]} aria-label={"Edit " <> template["name"]} title="Edit template" disabled={@busy} class="rounded p-2 text-neutral-500 hover:bg-neutral-100"><.icon name="pencil" /></button>
              <button type="button" phx-click="delete" phx-value-id={template["template_id"]} aria-label={"Delete " <> template["name"]} title="Delete template" disabled={@busy} class="rounded p-2 text-neutral-500 hover:bg-red-50 hover:text-red-600"><.icon name="trash" /></button>
            </div></td>
          </tr></tbody>
        </table>
      </div>
      <p class="text-xs text-neutral-500">Global templates remain read-only in Models. Private templates cannot become global. Subscription model usage does not spend platform credits.</p>
      <.modal :if={@dialog} id="template-dialog" show on_cancel={JS.push("close")}>
        <:title>{if @dialog == :delete, do: "Delete private template", else: if(@selected, do: "Edit private template", else: "Create private template")}</:title>
        <div :if={@error} role="alert" class="mb-4 rounded bg-red-50 p-3 text-sm text-red-700">{@error}</div>
        <form :if={@dialog == :edit} id="private-template-form" phx-change="change" phx-submit="save" class="space-y-4">
          <.input id="private-template-name" name="template[name]" label="Template name" value={@form["name"]} required maxlength="120" disabled={@busy} />
          <.select id="private-template-subscription_provider" name="template[subscription_provider]" label="Subscription provider" value={@form["subscription_provider"]} options={[{"Codex", "codex"}, {"Claude", "claude"}]} disabled={@busy} />
          <.button type="button" phx-click="discover" disabled={@busy}>Fetch models</.button>
          <p :if={@discovery_truncated} class="text-xs text-neutral-500">The result is limited to 1,000 models. You can also enter a model ID.</p>
          <div :if={@discovered_models != []} class="space-y-2">
            <.input id="private-model-search" name="model_search" label="Search models" value={@model_search} phx-keyup="search-models" phx-debounce="200" disabled={@busy} />
            <div class="rounded border border-neutral-200" aria-label="Available models">
                <p class="px-3 py-2 text-xs text-neutral-500">Up to 50 matches. Search to narrow the list.</p>
              <button :for={model <- Enum.filter(@discovered_models, &String.contains?(String.downcase(&1["name"] <> " " <> &1["id"]), String.downcase(@model_search))) |> Enum.take(50)} type="button" phx-click="choose-model" phx-value-id={model["id"]} aria-pressed={@form["model"] == model["id"]} disabled={@busy} class="block w-full px-3 py-2 text-left text-sm hover:bg-neutral-100"><span class="block font-medium">{model["name"]}</span><span class="text-xs text-neutral-500">{model["id"]}</span></button>
            </div>
          </div>
          <p :if={@form["model_display_name"]} class="text-xs text-neutral-500">Display name: {@form["model_display_name"]}</p>
          <.input id="private-template-model" name="template[model]" label="Model ID" value={@form["model"]} required maxlength="160" disabled={@busy} />
          <.input id="private-template-max_tokens" name="template[max_tokens]" type="number" label="Maximum output tokens" value={@form["max_tokens"]} min="1" max="1000000" required disabled={@busy} />
          <p class="text-xs text-neutral-500">Uses this organization's connected subscriptions. The model must be available to your provider account. Changes apply when an Agent next activates.</p>
          <div class="flex justify-end gap-2"><.button phx-click="close" disabled={@busy}>Cancel</.button><.button type="submit" variant="primary" disabled={@busy}>Save template</.button></div>
        </form>
        <div :if={@dialog == :delete} class="space-y-4"><p class="text-sm">Delete {@selected["name"]}? First remove it from organization model settings and any Agents that use it.</p><div class="flex justify-end gap-2"><.button phx-click="close" disabled={@busy}>Cancel</.button><.button variant="danger" phx-click="confirm-delete" disabled={@busy}>Delete template</.button></div></div>
      </.modal>
    </div>
    """
  end
end
