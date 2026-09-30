defmodule SalixWeb.Dashboard.AgentLive.New do
  @moduledoc "Create an agent (group + template, optional fork, VM)."
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.Groups
  alias SalixAgent.{Control, Templates}
  alias SalixStore.RuntimeIds

  @impl true
  def mount(_params, _session, socket) do
    environments = SalixEnv.Control.list_environments(socket.assigns.current_tenant)

    {:ok,
     assign(socket,
       active_nav: :agents,
       page_title: "New agent",
       breadcrumbs: [{"Agents", "/dash/agents"}, {"New", nil}],
       groups: Groups.list(socket.assigns.current_tenant),
       templates: available_templates(socket.assigns.current_tenant),
       agents: Control.list(socket.assigns.current_tenant, []),
       environments: environments,
       agent_type: "internal",
       selected_group_id: "",
       selected_device_id: "",
       selected_runtime_id: ""
     )}
  end

  @impl true
  def handle_event("form_change", params, socket) do
    agent_type = params["agent_type"] || "internal"
    selected_group_id = params["group_id"] || ""

    selected_device_id =
      if agent_type == "external" do
        normalize_selected_env(
          socket.assigns.environments,
          selected_group_id,
          params["device_id"] || ""
        )
      else
        ""
      end

    runtime_id = if agent_type == "external", do: params["device_runtime_id"] || "", else: ""

    runtime_id =
      normalize_selected_runtime(
        socket.assigns.environments,
        selected_group_id,
        selected_device_id,
        runtime_id
      )

    {:noreply,
     assign(socket,
       agent_type: agent_type,
       selected_group_id: selected_group_id,
       selected_device_id: selected_device_id,
       selected_runtime_id: runtime_id
     )}
  end

  @impl true
  def handle_event("create", params, socket) do
    case build_agent_attrs(params, socket.assigns.environments) do
      {:ok, attrs} ->
        create_agent(socket, attrs)

      {:error, msg} ->
        {:noreply,
         socket
         |> assign(
           agent_type: params["agent_type"] || socket.assigns.agent_type,
           selected_group_id: params["group_id"] || socket.assigns.selected_group_id,
           selected_device_id:
             normalize_selected_env(
               socket.assigns.environments,
               params["group_id"] || socket.assigns.selected_group_id,
               params["device_id"] || socket.assigns.selected_device_id
             ),
           selected_runtime_id: params["device_runtime_id"] || socket.assigns.selected_runtime_id
         )
         |> put_flash(:error, msg)}
    end
  end

  defp create_agent(socket, attrs) do
    case Control.create(attrs, socket.assigns.current_tenant) do
      {:ok, agent} ->
        {:noreply, push_navigate(socket, to: "/dash/agents/#{agent["agent_id"]}")}

      {:error, {:bad_request, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  defp build_agent_attrs(%{"agent_type" => "external"} = params, environments) do
    with {:ok, env} <- selected_environment(environments, params["group_id"], params["device_id"]),
         {:ok, runtime} <- selected_runtime(env, params["device_runtime_id"]) do
      attrs =
        base_attrs(params)
        |> Map.put("role", "worker")
        |> Map.put("vm", %{"enabled" => false})
        |> Map.put("runtime_config", external_runtime_config(env, runtime))

      {:ok, attrs}
    else
      {:error, :device_required} ->
        {:error, "Select a device."}

      {:error, :runtime_required} ->
        {:error, "Select a runtime."}

      {:error, :runtime_unavailable} ->
        {:error, "Selected device does not have an external runtime."}
    end
  end

  defp build_agent_attrs(params, _environments) do
    attrs =
      base_attrs(params)
      |> Map.put("vm", %{
        "enabled" => params["vm_enabled"] == "true",
        "provider" => params["vm_provider"] || "cloudflare"
      })
      |> put_if(params, "role")

    {:ok, attrs}
  end

  defp base_attrs(params) do
    %{
      "group_id" => params["group_id"],
      "template_id" => params["template_id"]
    }
    |> put_if(params, "name")
    |> put_if(params, "fork_from")
  end

  defp selected_environment(_environments, nil, _device_id), do: {:error, :device_required}
  defp selected_environment(_environments, "", _device_id), do: {:error, :device_required}
  defp selected_environment(_environments, _group_id, nil), do: {:error, :device_required}
  defp selected_environment(_environments, _group_id, ""), do: {:error, :device_required}

  defp selected_environment(environments, group_id, device_id) do
    case Enum.find(connected_devices(environments, group_id), &(&1["device_id"] == device_id)) do
      nil -> {:error, :device_required}
      env -> {:ok, env}
    end
  end

  defp selected_runtime(_env, nil), do: {:error, :runtime_required}
  defp selected_runtime(_env, ""), do: {:error, :runtime_required}

  defp selected_runtime(env, runtime_id) do
    case Enum.find(external_runtimes(env), &(device_runtime_id(&1) == runtime_id)) do
      nil -> {:error, :runtime_unavailable}
      runtime -> {:ok, runtime}
    end
  end

  defp external_runtime_config(env, runtime) do
    %{
      "kind" => "external",
      "provider" => runtime["provider"],
      "device_id" => env["device_id"],
      "runtime_id" => runtime["runtime_id"],
      "device_runtime_id" => device_runtime_id(runtime)
    }
    |> put_optional_nonblank("model", runtime["model"])
    |> put_optional_nonblank("model_provider", runtime["model_provider"])
    |> put_optional_nonblank("reasoning_effort", runtime["reasoning_effort"])
  end

  defp put_optional_nonblank(map, _key, value) when value in [nil, ""], do: map
  defp put_optional_nonblank(map, key, value), do: Map.put(map, key, value)

  defp put_if(attrs, params, key) do
    case params[key] do
      v when is_binary(v) and v != "" -> Map.put(attrs, key, v)
      _ -> attrs
    end
  end

  defp connected_devices(_environments, group_id) when group_id in [nil, ""], do: []

  defp connected_devices(environments, group_id) do
    Enum.filter(environments, &(&1["status"] == "connected"))
    |> Enum.filter(&(&1["group_id"] == group_id))
    |> latest_connected_devices()
  end

  defp latest_connected_devices(environments) do
    environments
    |> Enum.filter(&present?(&1["device_id"]))
    |> Enum.group_by(& &1["device_id"])
    |> Enum.map(fn {_device_id, records} ->
      Enum.max_by(records, &environment_updated_at/1, fn -> nil end)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp environment_updated_at(env) do
    case env["updated_at"] || env["connected_at"] do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, _} -> int
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp external_runtimes(env) do
    env
    |> Map.get("device_runtimes", [])
    |> Enum.filter(fn runtime ->
      RuntimeIds.external_runtime_provider?(runtime["provider"]) and
        device_runtime_id(runtime) != ""
    end)
  end

  defp device_runtime_id(runtime), do: runtime["device_runtime_id"] || ""

  defp normalize_selected_env(_environments, _group_id, device_id) when device_id in [nil, ""],
    do: ""

  defp normalize_selected_env(environments, group_id, device_id) do
    if Enum.any?(connected_devices(environments, group_id), &(&1["device_id"] == device_id)) do
      device_id
    else
      ""
    end
  end

  defp normalize_selected_runtime(environments, group_id, device_id, runtime_id) do
    with {:ok, env} <- selected_environment(environments, group_id, device_id),
         runtimes = [_ | _] <- external_runtimes(env) do
      if Enum.any?(runtimes, &(device_runtime_id(&1) == runtime_id)) do
        runtime_id
      else
        runtimes |> hd() |> device_runtime_id()
      end
    else
      _ -> ""
    end
  end

  defp selected_device(environments, group_id, device_id) do
    Enum.find(connected_devices(environments, group_id), &(&1["device_id"] == device_id))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp runtime_options(nil), do: []

  defp runtime_options(env) do
    env
    |> external_runtimes()
    |> Enum.map(fn runtime ->
      label =
        [runtime["provider"] || "codex", device_runtime_id(runtime), runtime["version"]]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" / ")

      {label, device_runtime_id(runtime)}
    end)
  end

  defp device_options(environments, group_id) do
    environments
    |> connected_devices(group_id)
    |> Enum.map(fn env ->
      name = env["name"] || env["device_id"]
      label = if name == env["device_id"], do: name, else: "#{name} / #{env["device_id"]}"
      {label, env["device_id"]}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-xl font-semibold">New agent</h1>

      <form id="new-agent-form" phx-change="form_change" phx-submit="create" class="max-w-xl space-y-4">
        <.card>
          <div class="space-y-3">
            <.input name="name" label="Name (optional)" />
            <.select
              name="group_id"
              label="Agent group"
              prompt="Select a group"
              value={@selected_group_id}
              options={Enum.map(@groups, &{&1["name"], &1["group_id"]})}
              required
            />
            <.select
              name="template_id"
              label="Template"
              prompt="Use tenant creation setting"
              options={Enum.map(SalixAgent.AgentDefaults.selectable(@templates), &{SalixAgent.ModelPresentation.name(&1), &1["template_id"]})}
              model_catalog={@templates}
            />
            <.select
              name="agent_type"
              label="Agent type"
              value={@agent_type}
              options={[{"Internal", "internal"}, {"External", "external"}]}
            />
            <.select
              :if={@agent_type == "internal"}
              name="role"
              label="Role"
              value="worker"
              options={[{"worker", "worker"}, {"router", "router"}]}
            />
            <.select
               :if={@agent_type == "external"}
               name="device_id"
               label="Device"
               prompt="Select a device"
               value={@selected_device_id}
               options={device_options(@environments, @selected_group_id)}
               required
            />
            <.select
               :if={@agent_type == "external"}
               name="device_runtime_id"
               label="Runtime"
               prompt="Select a runtime"
               value={@selected_runtime_id}
               options={
                 runtime_options(selected_device(@environments, @selected_group_id, @selected_device_id))
               }
              required
            />
            <.select
              name="fork_from"
              label="Fork from (optional)"
              prompt="None"
              options={Enum.map(@agents, &{&1["name"], &1["agent_id"]})}
            />
            <.toggle
              :if={@agent_type == "internal"}
              name="vm_enabled"
              label="Enable VM"
              value="true"
            />
            <.select
              :if={@agent_type == "internal"}
              name="vm_provider"
              label="VM provider"
              value="cloudflare"
              options={[{"Cloudflare", "cloudflare"}]}
            />
          </div>
        </.card>
        <div class="flex justify-end gap-2">
          <.button navigate="/dash/agents">Cancel</.button>
          <.button type="submit" variant="primary">Create agent</.button>
        </div>
      </form>
    </div>
    """
  end

  defp available_templates(tenant_id) do
    case Templates.list_private(tenant_id) do
      {:ok, private} -> Templates.list_admin() ++ private
      {:error, _} -> []
    end
  end
end
