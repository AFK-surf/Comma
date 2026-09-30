defmodule SalixWeb.Dashboard.AgentLive.Show do
  @moduledoc "Agent detail: edit config, lifecycle actions and sites."
  use SalixWeb.Dashboard, :live_view

  alias SalixAgent.{Control, Templates}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # Archived agents stay reachable read-only so their history (sessions,
    # evals, telemetry drill-downs) keeps working after a soft delete.
    case Control.get_including_archived(id, socket.assigns.current_tenant) do
      {:ok, agent} ->
        {:ok,
         socket
         |> assign(
           active_nav: :agents,
           agent_id: id,
           agent: agent,
           archived?: Control.archived?(agent),
           page_title: agent["name"],
           breadcrumbs: [{"Agents", "/dash/agents"}, {agent["name"], nil}],
           templates: available_templates(socket.assigns.current_tenant)
         )
         |> then(&assign(&1, catalog_available?: &1.assigns.templates != nil))
         |> load_side()}

      {:error, _} ->
        {:ok,
         socket |> put_flash(:error, "Agent not found.") |> push_navigate(to: "/dash/agents")}
    end
  end

  defp load_side(socket) do
    sites =
      case SalixAgent.Workspace.list_sites(socket.assigns.agent) do
        {:ok, s} -> s
        s when is_list(s) -> s
        _ -> []
      end

    assign(socket, sites: sites)
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{archived?: true}} = socket)
      when event in ["save", "cancel-agent", "wake-agent", "delete-agent"] do
    {:noreply, put_flash(socket, :error, "Agent is archived and read-only.")}
  end

  def handle_event("save", params, socket) do
    # Partial patch (willow semantics): only send fields with a value. The
    # runtime rejects clearing system_prompt to empty. An empty template pins
    # nothing: the Agent follows its role default. Without a loaded catalog
    # the page shows no template choice and leaves the current pin alone.
    attrs =
      %{
        "tool_router_enabled" => params["tool_router_enabled"] == "true",
        "vm" => %{
          "enabled" => params["vm_enabled"] == "true",
          "provider" =>
            params["vm_provider"] || get_in(socket.assigns.agent, ["vm", "provider"]) ||
              "cloudflare"
        }
      }
      |> put_if_present("name", params["name"])
      |> put_if_present("system_prompt", params["system_prompt"])
      |> then(fn attrs ->
        if socket.assigns.catalog_available?,
          do: Map.put(attrs, "template_id", params["template_id"] || ""),
          else: attrs
      end)

    case Control.configure(socket.assigns.agent_id, attrs, socket.assigns.current_tenant) do
      {:ok, agent} ->
        {:noreply, socket |> put_flash(:info, "Agent saved.") |> assign(agent: agent)}

      {:error, {:bad_request, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("cancel-agent", _p, socket) do
    case Control.cancel(socket.assigns.agent_id, socket.assigns.current_tenant) do
      {:ok, agent} ->
        {:noreply, socket |> put_flash(:info, "Agent cancelled.") |> assign(agent: agent)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  def handle_event("wake-agent", _p, socket) do
    case Control.wake(socket.assigns.agent_id, %{}, socket.assigns.current_tenant) do
      {:ok, agent} ->
        {:noreply, socket |> put_flash(:info, "Agent woken.") |> assign(agent: agent)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete-agent", _p, socket) do
    case Control.delete(socket.assigns.agent_id, socket.assigns.current_tenant) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Agent deleted.") |> push_navigate(to: "/dash/agents")}

      :ok ->
        {:noreply, push_navigate(socket, to: "/dash/agents")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  defp put_if_present(attrs, key, val) when is_binary(val) and val != "",
    do: Map.put(attrs, key, val)

  defp put_if_present(attrs, _key, _val), do: attrs

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div id="agent-detail-header" class="flex flex-wrap items-start justify-between gap-4">
        <div class="min-w-0 flex-1 basis-72">
          <div class="flex flex-wrap items-center gap-2">
            <h1 class="min-w-0 break-all text-xl font-semibold">{@agent["name"]}</h1>
            <.status_pill status={@agent["status"]} />
            <.badge :if={@archived?} color="amber">archived</.badge>
          </div>
          <p class="mt-1 break-all font-mono text-xs text-neutral-500">{@agent["agent_id"]}</p>
          <p :if={@archived?} class="mt-1 text-xs text-neutral-500">
            This agent was deleted. Its history stays readable until cleanup; actions are disabled.
          </p>
        </div>
        <div id="agent-detail-actions" class="flex max-w-full flex-wrap items-center gap-2 [&>*]:h-auto [&>*]:min-h-7 [&>*]:py-1 [&>*]:max-w-full [&>*]:shrink-0 [&>*]:whitespace-normal [&>*]:[overflow-wrap:anywhere]">
          <.button size="sm" navigate={"/dash/agents/#{@agent_id}/sessions"}>Sessions</.button>
          <.button :if={@agent["group_id"]} size="sm" navigate={"/dash/groups/#{@agent["group_id"]}?tab=conversations"}>
            Group conversations
          </.button>
          <.button size="sm" navigate={"/dash/agents/#{@agent_id}/files"}>Files</.button>
          <.button :if={!@archived?} size="sm" phx-click="wake-agent">Wake</.button>
          <.button :if={!@archived?} size="sm" phx-click="cancel-agent">Cancel</.button>
          <.button
            :if={!@archived?}
            size="sm"
            variant="danger"
            phx-click="delete-agent"
            data-confirm="Delete this agent?"
          >
            Delete
          </.button>
        </div>
      </div>

      <.card>
        <:title>Configuration</:title>
        <form phx-submit="save" class="space-y-3">
          <.input name="name" label="Name" value={@agent["name"]} disabled={@archived?} />
          <.select
            :if={@catalog_available?}
            name="template_id"
            label="Template"
            value={@agent["template_id"] || ""}
            prompt={follow_default_prompt(@agent)}
            options={template_options(@templates, @agent["template_id"])}
            model_catalog={@templates}
            model_default_icon={SalixAgent.AgentDefaults.default_icon(@agent["role"])}
            disabled={@archived?}
          />
          <p :if={!@catalog_available?} class="text-sm text-neutral-500">
            Template catalog unavailable. The current template stays unchanged.
          </p>
          <.textarea
            name="system_prompt"
            label="System prompt"
            rows="6"
            value={@agent["system_prompt"]}
            disabled={@archived?}
          />
          <div class="flex items-center gap-6">
            <.toggle
              name="tool_router_enabled"
              label="Tool router"
              checked={@agent["tool_router_enabled"]}
              value="true"
              disabled={@archived?}
            />
            <.toggle
              name="vm_enabled"
              label="VM"
              checked={get_in(@agent, ["vm", "enabled"]) == true}
              value="true"
              disabled={@archived?}
            />
            <.select
              name="vm_provider"
              label="VM provider"
              value={get_in(@agent, ["vm", "provider"]) || "cloudflare"}
              options={[{"Cloudflare", "cloudflare"}]}
              disabled={@archived?}
            />
          </div>
          <div :if={!@archived?} class="flex justify-end">
            <.button type="submit" variant="primary">Save</.button>
          </div>
        </form>
      </.card>

      <.card>
        <:title>Sites</:title>
        <.table :if={@sites != []} id="sites" rows={@sites}>
          <:col :let={s} label="Name">{s["name"] || s["site"]}</:col>
          <:col :let={s} label="URL">
            <a href={s["url"]} target="_blank" class="text-brand-600 underline">{s["url"]}</a>
          </:col>
        </.table>
        <p :if={@sites == []} class="text-sm text-neutral-500">No published sites.</p>
      </.card>
    </div>
    """
  end

  # `nil` marks an unavailable catalog, distinct from an empty one.
  defp available_templates(tenant_id) do
    case Templates.list_private(tenant_id) do
      {:ok, private} -> Templates.list_admin() ++ private
      {:error, _} -> nil
    end
  end

  defp template_options(templates, current) do
    Enum.flat_map(templates, fn template ->
      cond do
        template["template_id"] != "default" ->
          [{SalixAgent.ModelPresentation.name(template), template["template_id"]}]

        current == "default" ->
          [[key: "#{template["model"]} (current choice)", value: current]]

        true ->
          []
      end
    end)
  end

  defp follow_default_prompt(agent), do: SalixAgent.AgentDefaults.default_label(agent["role"])
end
