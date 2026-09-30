defmodule SalixWeb.Dashboard.AgentDefaultsLive do
  @moduledoc """
  Edit the layered Router/Worker default templates.

  The platform section is global: it names global templates and applies to
  every tenant that leaves a role default empty. The tenant section edits the
  `agent_defaults` config of the selected tenant; an empty value defers to the
  platform default. Tenant choices are copied only when Agents are created.
  """
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.Tenants
  alias SalixAgent.{AgentDefaults, Templates}

  @roles [{"router", "Router"}, {"worker", "Worker"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       active_nav: :config,
       page_title: "Agent defaults",
       breadcrumbs: [{"Config", nil}, {"Agent defaults", nil}],
       roles: @roles
     )
     |> load()}
  end

  defp load(socket) do
    tenant_id = socket.assigns.current_tenant

    {platform, platform_error} =
      case AgentDefaults.platform() do
        {:ok, config} -> {config, nil}
        {:error, reason} -> {%{}, inspect(reason)}
      end

    tenant =
      case Tenants.get_config(tenant_id, "agent_defaults", %{}) do
        {:ok, config} when is_map(config) -> config
        _ -> %{}
      end

    tenant_templates =
      case Templates.list_private(tenant_id) do
        {:ok, private} -> Templates.list_admin() ++ private
        {:error, _} -> Templates.list_admin()
      end

    assign(socket,
      platform: platform,
      platform_error: platform_error,
      platform_names: AgentDefaults.effective_role_defaults(nil),
      tenant: tenant,
      effective: AgentDefaults.effective_role_defaults(tenant_id),
      global_templates: Templates.list_admin(),
      tenant_templates: tenant_templates
    )
  end

  @impl true
  def handle_event("save-platform", params, socket) do
    case AgentDefaults.update_platform(pointer_attrs(params)) do
      {:ok, _config} ->
        {:noreply, socket |> put_flash(:info, "Platform defaults saved.") |> load()}

      {:error, {:bad_request, message}} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("save-tenant", params, socket) do
    case Tenants.update_config(
           socket.assigns.current_tenant,
           "agent_defaults",
           pointer_attrs(params)
         ) do
      {:ok, _config} ->
        {:noreply, socket |> put_flash(:info, "Tenant defaults saved.") |> load()}

      {:error, {:bad_request, message}} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  # Only the two pointer fields are editable here; a blank select clears one.
  defp pointer_attrs(params) do
    Map.new(AgentDefaults.fields(), fn field -> {field, params[field] || ""} end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-xl font-semibold">Agent defaults</h1>
      <p class="text-sm text-neutral-600">
        Existing Agents follow the platform default or use their own template.
        Tenant defaults only set the initial choice for new Agents.
      </p>

      <.card>
        <:title>Platform defaults</:title>
        <p :if={@platform_error} class="text-sm text-red-600">
          Platform defaults are unavailable: {@platform_error}
        </p>
        <form phx-submit="save-platform" class="space-y-3">
          <.select
            :for={{role, label} <- @roles}
            name={AgentDefaults.field(role)}
            label={label <> " default template"}
            value={if @platform[AgentDefaults.field(role)] == "default", do: "", else: @platform[AgentDefaults.field(role)] || ""}
            prompt="Default (gpt-test)"
            options={template_options(@global_templates, nil)}
            model_catalog={Enum.map(@global_templates, &Map.merge(&1, SalixAgent.ModelPresentation.public(&1)))}
          />
          <div class="flex justify-end">
            <.button type="submit" variant="primary">Save platform defaults</.button>
          </div>
        </form>
      </.card>

      <.card>
        <:title>New Agent defaults for this tenant</:title>
        <form phx-submit="save-tenant" class="space-y-3">
          <.select
            :for={{role, label} <- @roles}
            name={AgentDefaults.field(role)}
            label={label <> " default template"}
            value={@tenant[AgentDefaults.field(role)] || ""}
            prompt={follow_platform_prompt(@platform_names[role])}
            options={template_options(@tenant_templates, @tenant[AgentDefaults.field(role)])}
            model_catalog={Enum.map(@tenant_templates, &Map.merge(&1, SalixAgent.ModelPresentation.public(&1)))}
            model_default_icon={@platform_names[role]["model_icon"]}
          />
          <div class="flex justify-end">
            <.button type="submit" variant="primary">Save tenant defaults</.button>
          </div>
        </form>
        <dl class="mt-4 grid grid-cols-2 gap-2 text-sm">
          <%= for {role, label} <- @roles do %>
            <dt class="text-neutral-500">Effective {label} default</dt>
            <dd>{effective_label(@effective[role])}</dd>
          <% end %>
        </dl>
      </.card>
    </div>
    """
  end

  defp follow_platform_prompt(nil), do: "Default (unavailable)"

  defp follow_platform_prompt(template),
    do: "Default (#{SalixAgent.ModelPresentation.name(template)})"

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

  defp effective_label(nil), do: "Not configured"

  defp effective_label(template) do
    name = SalixAgent.ModelPresentation.name(template) || template["template_id"]
    source = template["source"] |> to_string() |> String.replace("_", " ")
    "#{name} (#{source})"
  end
end
