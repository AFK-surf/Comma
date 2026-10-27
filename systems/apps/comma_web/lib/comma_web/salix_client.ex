defmodule CommaWeb.SalixClient do
  require SystemsRuntime.Proc

  @moduledoc false

  @behaviour Comma.Salix.Client

  alias SalixAgent.{AgentModel, ModelChoice, TaskModel, TaskPlace}

  # Whole reads held in memory: workspace files and Agent resources. A message
  # attachment is streamed instead (`stream_agent_blob/4`) and has no such bound.
  @max_workspace_file_read_bytes 10_000_001

  @impl true
  def provision_workspace_scope(workspace) when is_map(workspace) do
    tenant_id = workspace["salix_tenant_id"]
    group_id = workspace["default_group_id"]
    router_agent_id = workspace["router_agent_id"]

    billing_owner = %{
      "surface" => "comma",
      "vm_profile_key" => "cf-standard-1",
      "product_owner_type" => "workspace",
      "product_owner_id" => workspace["id"],
      "billing_account_id" => workspace["billing_account_id"],
      "salix_tenant_id" => tenant_id,
      "salix_group_id" => group_id,
      "router_agent_id" => router_agent_id,
      "charge_policy" => "platform_paid"
    }

    with :ok <- ensure_default_platform_models(),
         {:ok, tenant_config} <- workspace_tenant_config(workspace),
         :ok <-
           ensure_salix_tenant(
             tenant_id,
             %{
               "tenant_id" => tenant_id,
               "name" => workspace["name"]
             }
             |> maybe_put("config", tenant_config)
           ),
         :ok <-
           ensure_salix_group(group_id, tenant_id, %{
             "group_id" => group_id,
             "name" => workspace["name"],
             "billing_owner" => billing_owner
           }),
         :ok <- set_group_cloud_vm(group_id, tenant_id, workspace["vm"]),
         :ok <-
           ensure_salix_agent(
             router_agent_id,
             tenant_id,
             %{
               "agent_id" => router_agent_id,
               "group_id" => group_id,
               "name" => workspace["name"] <> " Router",
               "role" => "router",
               "purpose" => router_purpose(workspace)
             }
           ),
         :ok <- ensure_salix_group_router_if_absent(group_id, tenant_id, router_agent_id) do
      :ok
    end
  end

  # A Workspace gets only its Router agent here. Its Tasks run on its Group's
  # Task agent (`SalixAgent.TaskAgent`), which Salix makes when the first Task
  # needs it; a stored default Worker id is no longer provisioned or checked.

  defp router_purpose(%{"kind" => "guest"}), do: SalixStore.TenantProfiles.guest_router_purpose()
  defp router_purpose(_workspace), do: SalixAgent.ToolPolicy.comma_router_purpose()

  @impl true
  def ensure_guest_tenant(tenant_id, dependency_max_children)
      when is_binary(tenant_id) and is_integer(dependency_max_children) do
    # The profile must exist before any guest Router is created in the Tenant.
    with :ok <-
           ensure_salix_tenant(tenant_id, %{"tenant_id" => tenant_id, "name" => "Comma guests"}),
         {:ok, _profile} <-
           SalixStore.TenantProfiles.put_router_only(tenant_id, dependency_max_children) do
      :ok
    end
  end

  @impl true
  def verify_workspace_scope(workspace) when is_map(workspace) do
    tenant_id = workspace["salix_tenant_id"]
    group_id = workspace["default_group_id"]
    router_agent_id = workspace["router_agent_id"]

    with {:ok, %{"tenant_id" => ^tenant_id}} <- Salix.Control.Tenants.get(tenant_id),
         {:ok, group} <- Salix.Control.Groups.get(group_id, tenant_id),
         :ok <- verify_workspace_group(group, workspace),
         {:ok, router} <- SalixAgent.Control.get(router_agent_id, tenant_id),
         :ok <- verify_workspace_agent(router, router_agent_id, tenant_id, group_id, "router") do
      :ok
    else
      {:ok, _mismatched_record} -> {:error, :workspace_scope_conflict}
      {:error, _reason} = error -> error
      _mismatch -> {:error, :workspace_scope_conflict}
    end
  end

  @impl true
  def resolve_workspace_scope(workspace) when is_map(workspace) do
    tenant_id = workspace["salix_tenant_id"]
    group_id = workspace["default_group_id"]

    with {:ok, group} <- Salix.Control.Groups.get(group_id, tenant_id),
         {:ok, router_conversation_id} <- SalixIM.ConversationIds.group_router(group),
         router_agent_id when is_binary(router_agent_id) and router_agent_id != "" <-
           group["router_agent_id"],
         true <- SalixStore.Ids.valid_agent_id_for_group?(router_agent_id, group_id),
         {:ok, router} <- get_visible_group_router(router_agent_id, tenant_id),
         true <- router["group_id"] == group_id and router["role"] == "router" do
      {:ok,
       workspace
       |> Map.put("router_agent_id", router_agent_id)
       |> Map.put("router_conversation_id", router_conversation_id)}
    else
      nil -> {:error, :router_not_configured}
      "" -> {:error, :router_not_configured}
      false -> {:error, :invalid_group_router}
      {:error, _} = error -> error
      _invalid -> {:error, :invalid_group_router}
    end
  end

  # A chat runs its Router's model. A Task runs its Session's own model
  # choice when it has one (the Router's, or the Workspace's default Task
  # model), else its Agent's.
  @impl true
  def conversation_uses_private_model?(workspace, binding) do
    tenant_id = workspace["salix_tenant_id"]

    choice =
      case binding["kind"] do
        "user_chat" ->
          agent_model_choice(workspace, workspace["router_agent_id"])

        "agent_task" ->
          with {:ok, conversation} <-
                 get_group_conversation(
                   workspace,
                   get_in(binding, ["internal", "salix_conversation_id"])
                 ) do
            task_model_choice(workspace, conversation)
          end

        _ ->
          {:error, :not_found}
      end

    with {:ok, choice} <- choice,
         {:ok, llm} when is_map(llm) <- ModelChoice.resolve_llm(choice, tenant_id) do
      llm["credential_scope"] == "tenant"
    else
      _ -> false
    end
  end

  defp task_model_choice(workspace, conversation) do
    case SalixIM.TaskCardProjection.task_session_model(conversation) do
      %{} = choice -> {:ok, choice}
      nil -> agent_model_choice(workspace, conversation["task_worker_agent_id"])
    end
  end

  defp agent_model_choice(workspace, agent_id) when is_binary(agent_id) do
    with {:ok, agent} <- SalixAgent.Control.get(agent_id, workspace["salix_tenant_id"]),
         true <- agent["group_id"] == workspace["default_group_id"],
         {:ok, choice, _source} <- AgentModel.choice(agent) do
      {:ok, choice}
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp agent_model_choice(_workspace, _agent_id), do: {:error, :not_found}

  @impl true
  def get_workspace_agent_models(workspace) when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, resolved_workspace} <- resolve_workspace_scope(workspace),
           {:ok, router} <- workspace_agent_model(resolved_workspace, "router"),
           {:ok, worker} <- task_agent_model(resolved_workspace),
           {:ok, task_model} <- TaskModel.get(resolved_workspace["default_group_id"]),
           {:ok, task_place} <- TaskPlace.get(resolved_workspace["default_group_id"]) do
        {:ok,
         %{
           "workspace_id" => resolved_workspace["id"],
           "agents" => %{"router" => router, "worker" => worker},
           # The model a Task runs when it names none (`SalixAgent.TaskModel`).
           "task_model" => %{"selection" => task_selection(task_model)},
           # Where a Task runs when it names no place (`SalixAgent.TaskPlace`):
           # inside Salix unless a member chose the Cloud VM or a station.
           "task_place" => %{"place" => task_place || TaskPlace.salix()},
           # Kept only for old clients: desktop apps already shipped require
           # this page and no longer get any Worker in it.
           "workers" => empty_worker_page(),
           # What each role uses when nothing is chosen for it: the platform
           # model, described so the UI can name it.
           "platform_defaults" => %{
             "router" => platform_default_model("router"),
             "worker" => platform_default_model("worker")
           }
         }}
      end
    end)
  end

  @doc "Choose Comma's built-in model or a catalog model."
  def update_user_workspace_agent_selection(workspace, target, %{"kind" => "builtin"} = selection)
      when map_size(selection) == 1 do
    Comma.Salix.Client.update_workspace_agent_model(workspace, target, nil)
  end

  # The Agent stores the catalog choice itself (`SalixAgent.ModelChoice`).
  def update_user_workspace_agent_selection(
        workspace,
        target,
        %{"kind" => "catalog", "allow_paid" => allow_paid} = selection
      )
      when is_boolean(allow_paid) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, scope} <- resolve_workspace_scope(workspace),
           tenant_id = scope["salix_tenant_id"],
           {:ok, agent} <- model_target(scope, target),
           :ok <- agent_model_writable(agent),
           {:ok, choice} <- ModelChoice.choose(selection, tenant_id),
           {:ok, updated} <- assign_agent_choice(agent, choice, tenant_id) do
        workspace_worker_model(updated)
      end
    end)
  end

  def update_user_workspace_agent_selection(_workspace, _target, _selection),
    do: {:error, :invalid_model_configuration}

  @doc """
  Set the Workspace's default Task model (`SalixAgent.TaskModel`): Comma's
  built-in model or a catalog model. Answers the stored selection.
  """
  def update_workspace_task_model(workspace, %{"kind" => "builtin"} = selection)
      when map_size(selection) == 1,
      do: put_task_model(workspace, TaskModel.platform())

  def update_workspace_task_model(
        workspace,
        %{"kind" => "catalog", "allow_paid" => allow_paid} = selection
      )
      when is_boolean(allow_paid) do
    choice =
      selection
      |> Map.take(~w(kind model reasoning_effort allow_paid profile_id))
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    put_task_model(workspace, choice)
  end

  def update_workspace_task_model(_workspace, _selection),
    do: {:error, :invalid_model_configuration}

  defp put_task_model(workspace, choice) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, scope} <- resolve_workspace_scope(workspace),
           {:ok, stored} <-
             TaskModel.put(scope["salix_tenant_id"], scope["default_group_id"], choice),
           do: {:ok, %{"selection" => task_selection(stored)}}
    end)
  end

  @doc """
  Set the Workspace's default place to run Tasks (`SalixAgent.TaskPlace`):
  inside Salix (`{kind: salix}`), its Cloud VM while the Workspace's Cloud VM
  is on, or a station of the Workspace (`{kind: station, device_id}`, which
  the caller checks). Answers the stored place.
  """
  def update_workspace_task_place(workspace, place) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, scope} <- resolve_workspace_scope(workspace),
           {:ok, stored} <-
             TaskPlace.put(scope["salix_tenant_id"], scope["default_group_id"], place || %{}),
           do: {:ok, %{"place" => stored || TaskPlace.salix()}}
    end)
  end

  @doc """
  Set how the Workspace's Router writes to people (`reply_style`): `default`
  or `concise`. Answers the stored style.
  """
  def update_workspace_reply_style(workspace, style) when style in ["default", "concise"] do
    observe_salix(:salix_boundary, fn ->
      with {:ok, scope} <- resolve_workspace_scope(workspace),
           {:ok, router} <- workspace_agent(scope, "router"),
           {:ok, updated} <-
             SalixAgent.Control.configure(
               router["agent_id"],
               %{"reply_style" => style},
               scope["salix_tenant_id"]
             ),
           do: {:ok, %{"reply_style" => reply_style(updated)}}
    end)
  end

  def update_workspace_reply_style(_workspace, _style), do: {:error, :invalid_reply_style}

  defp reply_style(agent), do: agent["reply_style"] || "default"

  @doc """
  The Worker list old clients read (`GET …/agent-models/workers`): always an
  empty page. Kept only for old clients, which require it; a Task's model is
  the Workspace's default Task model now.
  """
  def empty_worker_page, do: %{"items" => [], "next_cursor" => nil}

  # Comma's built-in model is the platform model, whether set or never chosen.
  defp task_selection(%{"kind" => "catalog"} = choice),
    do: %{
      "kind" => "catalog",
      "model" => choice["model"],
      "reasoning_effort" => choice["reasoning_effort"],
      "allow_paid" => choice["allow_paid"] == true,
      "profile_id" => choice["profile_id"]
    }

  defp task_selection(_platform_or_none), do: %{"kind" => "builtin"}

  defp assign_agent_choice(agent, choice, tenant_id) do
    if agent["model"] == choice,
      do: {:ok, agent},
      else: SalixAgent.Control.configure(agent["agent_id"], %{"model" => choice}, tenant_id)
  end

  @doc "Rename the workspace's Router or one of its Workers."
  def rename_workspace_agent(workspace, target, name) when is_binary(name) do
    name = String.trim(name)

    with true <- name != "" and String.length(name) <= 80,
         {:ok, scope} <- resolve_workspace_scope(workspace),
         {:ok, agent} <- model_target(scope, target),
         {:ok, updated} <-
           SalixAgent.Control.configure(
             agent["agent_id"],
             %{"name" => name},
             scope["salix_tenant_id"]
           ) do
      {:ok, %{"agent_id" => updated["agent_id"], "name" => updated["name"]}}
    else
      false -> {:error, :invalid_agent_name}
      error -> error
    end
  end

  def rename_workspace_agent(_, _, _), do: {:error, :invalid_agent_name}

  @doc """
  Set the model of one existing Agent: a model choice (`SalixAgent.ModelChoice`),
  or nil to follow the platform model of its role. Role aliases address the
  workspace's initial Agents.
  """
  @impl true
  def update_workspace_agent_model(workspace, target, model)
      when is_map(workspace) and is_binary(target) and (is_map(model) or is_nil(model)) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, scope} <- resolve_workspace_scope(workspace),
           tenant_id = scope["salix_tenant_id"],
           {:ok, agent} <- model_target(scope, target),
           :ok <- agent_model_writable(agent),
           {:ok, model} <- checked_choice(model, tenant_id),
           {:ok, updated} <- assign_agent_choice(agent, model, tenant_id) do
        workspace_worker_model(updated)
      end
    end)
  end

  def update_workspace_agent_model(_, _, _), do: {:error, :invalid_workspace_agent_model}

  defp checked_choice(nil, _tenant_id), do: {:ok, nil}
  defp checked_choice(model, tenant_id), do: ModelChoice.choose(model, tenant_id)

  defp model_target(workspace, role) when role in ["router", "worker"],
    do: workspace_agent(workspace, role)

  defp model_target(workspace, id) do
    with {:ok, agent} <- SalixAgent.Control.get(id, workspace["salix_tenant_id"]),
         true <- agent["group_id"] == workspace["default_group_id"],
         true <- agent["role"] == "worker" or id == workspace["router_agent_id"] do
      {:ok, agent}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  defp workspace_worker_model(agent) do
    settings = runtime_model_settings(agent)

    if settings,
      do: runtime_settings_model(agent, settings),
      else: chosen_worker_model(agent)
  end

  defp chosen_worker_model(agent) do
    with {:ok, model, source} <- AgentModel.resolve_public(agent),
         do: {:ok, public_workspace_agent_model(agent, model, source)}
  end

  defp runtime_settings_model(agent, settings) do
    runtime = SalixAgent.AgentManagement.Projection.worker_runtime(agent)

    {:ok,
     %{
       "agent_id" => agent["agent_id"],
       "name" => agent["name"] || agent["agent_id"],
       "role" => agent["role"],
       "source" =>
         if(present_model?(settings["model"]), do: "agent_config", else: "runtime_default"),
       "model" => settings["model"],
       "provider" => settings["model_provider"],
       "reasoning_effort" => settings["reasoning_effort"],
       "runtime" => Map.take(runtime, ~w(kind provider))
     }}
  end

  # A Worker bound to a station runs the runtime model of its binding
  # (`SalixAgent.StationBinding`); rebinding changes it.
  defp runtime_model_settings(%{"station_binding" => %{"runs_on" => %{}, "model" => model}})
       when is_map(model),
       do: %{"model" => model["model"], "reasoning_effort" => model["reasoning_effort"]}

  defp runtime_model_settings(_), do: nil

  defp present_model?(model), do: is_binary(model) and String.trim(model) != ""

  defp agent_model_writable(agent) do
    if is_nil(runtime_model_settings(agent)),
      do: :ok,
      else: {:error, {:bad_request, "This Worker's model is set by its station binding."}}
  end

  defp platform_default_model(role) do
    case AgentModel.platform_public(role) do
      {:ok, model} -> public_model(model)
      _ -> nil
    end
  end

  defp get_visible_group_router(router_agent_id, tenant_id) do
    case SalixAgent.Control.get(router_agent_id, tenant_id) do
      {:ok, router} -> {:ok, router}
      {:error, :not_found} -> {:error, :invalid_group_router}
      {:error, _reason} = error -> error
    end
  end

  # The Group's Task agent, which shipped apps show as the "worker"; nil
  # before the Group has one.
  defp task_agent_model(workspace) do
    case workspace_agent_model(workspace, "worker") do
      {:error, :workspace_agent_model_unavailable} -> {:ok, nil}
      result -> result
    end
  end

  defp workspace_agent_model(workspace, role) do
    with {:ok, agent} <- workspace_agent(workspace, role),
         {:ok, model, source} <- AgentModel.resolve_public(agent),
         true <- valid_public_model?(model) do
      {:ok, public_workspace_agent_model(agent, model, source)}
    else
      false -> {:error, :workspace_agent_model_unavailable}
      {:error, :not_found} -> {:error, :workspace_agent_model_unavailable}
      {:error, :agent_model_unresolved} -> {:error, :workspace_agent_model_unavailable}
      {:error, :platform_model_unconfigured} -> {:error, :workspace_agent_model_unavailable}
      {:error, _reason} = error -> error
      _invalid -> {:error, :workspace_agent_model_unavailable}
    end
  end

  defp workspace_agent(workspace, role) when role in ["router", "worker"] do
    tenant_id = workspace["salix_tenant_id"]
    group_id = workspace["default_group_id"]

    with {:ok, agent_id} <- workspace_agent_id(workspace, role),
         true <- is_binary(agent_id) and agent_id != "",
         {:ok, agent} <- SalixAgent.Control.get(agent_id, tenant_id),
         :ok <- verify_workspace_agent(agent, agent_id, tenant_id, group_id, role) do
      {:ok, agent}
    else
      # The "worker" alias names the Group's Task agent, which a Group gets
      # with its first Task.
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp workspace_agent_id(workspace, "router"), do: {:ok, workspace["router_agent_id"]}

  defp workspace_agent_id(workspace, "worker"),
    do: SalixAgent.TaskAgent.get(workspace["default_group_id"])

  defp public_source(:platform_default), do: "platform_default"
  defp public_source(_chosen), do: "pinned"

  defp public_workspace_agent_model(agent, model, source) do
    %{
      "agent_id" => agent["agent_id"],
      "name" => agent["name"] || agent["agent_id"],
      "role" => agent["role"],
      "source" => public_source(source),
      "model" => model["model"],
      "provider" => model["provider"]
    }
    |> Map.merge(
      Map.take(
        model,
        ~w(model_display_name model_vendor model_icon account_pool scope reasoning_effort)
      )
    )
    |> Map.put("selection", selection(model, source))
    |> put_reply_style(agent)
  end

  defp put_reply_style(public, %{"role" => "router"} = agent),
    do: Map.put(public, "reply_style", reply_style(agent))

  defp put_reply_style(public, _agent), do: public

  # What the Agent chose: Comma's built-in model, or a catalog model, effort and
  # whether pay-per-use Profiles may serve it, or a compute runtime's model.
  defp selection(_model, :platform_default), do: %{"kind" => "builtin"}
  # The platform model is Comma's built-in model, whether followed or chosen.
  defp selection(%{"platform_tier" => _}, _source), do: %{"kind" => "builtin"}

  defp selection(%{"runtime_model" => model} = public, _source),
    do: %{
      "kind" => "runtime",
      "model" => model,
      "reasoning_effort" => public["reasoning_effort"]
    }

  defp selection(%{"catalog_model" => model} = public, _source),
    do: %{
      "kind" => "catalog",
      "model" => model,
      "reasoning_effort" => public["reasoning_effort"],
      "allow_paid" => public["allow_paid"] == true,
      "profile_id" => public["profile_id"]
    }

  defp public_model(model) do
    Map.take(
      model,
      ~w(name model provider scope model_display_name model_vendor model_icon account_pool reasoning_effort)
    )
  end

  # A Custom endpoint's model id may name no known provider (a relay's
  # `relay-ai/model`): its provider is then empty, and the model still shows.
  defp valid_public_model?(%{"name" => name, "model" => model}),
    do: Enum.all?([name, model], &(is_binary(&1) and &1 != ""))

  defp valid_public_model?(_model), do: false

  @impl true
  def update_workspace_vm(workspace, vm) when is_map(workspace) and is_map(vm) do
    workspace = Map.put(workspace, "vm", strip_vm_command_flags(vm))

    with {:ok, workspace} <- resolve_workspace_scope(workspace),
         {:ok, tenant_config} <- workspace_tenant_config(workspace),
         :ok <- ensure_salix_tenant_config(workspace["salix_tenant_id"], tenant_config) do
      set_group_cloud_vm(workspace["default_group_id"], workspace["salix_tenant_id"], vm)
    end
  end

  # The Workspace's `vm.enabled` is its Group's Cloud VM switch, which decides
  # for every Agent of the Group (`SalixAgent.CloudVM.allowed?/1`).
  defp set_group_cloud_vm(group_id, tenant_id, vm) when is_map(vm) do
    normalize_created(
      Salix.Control.Groups.update(
        group_id,
        %{"cloud_vm_enabled" => vm["enabled"] == true},
        tenant_id
      )
    )
  end

  defp set_group_cloud_vm(_group_id, _tenant_id, _vm), do: :ok

  # A deployment that names its one model (`llm.default_template`: a local or
  # self-hosted installation) runs it as the platform model of every role not
  # configured yet. Its Routers and Workers follow that platform model.
  defp ensure_default_platform_models do
    case SystemsRuntime.get_env(:comma_core, :default_agent_template) do
      template when is_map(template) ->
        case SalixAgent.Migrations.PlatformModels.seed(stringify_keys(template)) do
          {:ok, _tiers} -> :ok
          {:error, _reason} = error -> error
        end

      _ ->
        :ok
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} ->
      value =
        if is_map(value) do
          stringify_keys(value)
        else
          value
        end

      {to_string(key), value}
    end)
  end

  @impl true
  def create_group_conversation(workspace, attrs) when is_map(workspace) and is_map(attrs) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, workspace} <- resolve_workspace_scope(workspace) do
        attrs =
          attrs
          |> Map.put("kind", "user_chat")
          |> Map.put("participants", [
            %{
              "actor_type" => "user",
              "user_id" => attrs["user_id"],
              "state" => "active",
              "notification_filter" => %{"messages" => "all", "statuses" => "none"}
            },
            %{
              "actor_type" => "agent",
              "agent_id" => workspace["router_agent_id"],
              "role_label" => "agent",
              "state" => "active",
              "notification_filter" => %{"messages" => "all", "statuses" => "none"}
            }
          ])

        SalixIM.ConversationInput.create_group_conversation(
          workspace["default_group_id"],
          attrs
        )
      end
    end)
  end

  @impl true
  def enter_meeting_task(workspace, user_id, attrs),
    do: CommaWeb.MeetingTaskInput.enter(workspace, user_id, attrs)

  @impl true
  def update_meeting_task(workspace, user_id, occurrence_id, attrs),
    do: CommaWeb.MeetingTaskInput.update(workspace, user_id, occurrence_id, attrs)

  @impl true
  def ensure_group_router_conversation(workspace) when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, workspace} <- resolve_workspace_scope(workspace),
           {:ok, conversation} <-
             SalixIM.RouterConversationInput.ensure(workspace["default_group_id"]),
           true <- conversation["conversation_id"] == workspace["router_conversation_id"] do
        {:ok, conversation}
      else
        false -> {:error, :invalid_group_router_conversation}
        {:error, _reason} = error -> error
      end
    end)
  end

  @impl true
  def ensure_group_router_conversation(workspace, opts)
      when is_map(workspace) and is_list(opts) do
    with {:ok, conversation} <- ensure_group_router_conversation(workspace),
         limit = opts |> Keyword.get(:message_limit, 1_000) |> max(1) |> min(1_000),
         {:ok, %{"conversation" => current, "messages" => messages}} <-
           get_group_conversation_with_messages(workspace, conversation["conversation_id"],
             tail: limit
           ) do
      {:ok, conversation |> Map.merge(current) |> Map.put("messages", messages)}
    end
  end

  @impl true
  def subscribe_group_conversation_list(workspace, kind, subscriber)
      when is_map(workspace) and kind in ["agent_task", "user_chat"] and
             SystemsRuntime.Proc.is_process(subscriber) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, workspace} <- resolve_workspace_scope(workspace) do
        SalixIM.ConversationServer.subscribe_group_conversation_list(
          workspace["default_group_id"],
          kind,
          subscriber
        )
      end
    end)
  end

  @impl true
  def list_station_tasks(workspace) when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, workspace} <- resolve_workspace_scope(workspace) do
        {:ok, SalixWeb.StationTaskIndex.list(workspace["default_group_id"])}
      end
    end)
  end

  @impl true
  def read_station_task(workspace, station_id, thread, opts)
      when is_map(workspace) and is_binary(station_id) and is_binary(thread) and is_map(opts) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, workspace} <- resolve_workspace_scope(workspace) do
        SalixIM.Ports.StationHostedTasks.read(
          %{tenant_id: workspace["salix_tenant_id"], group_id: workspace["default_group_id"]},
          station_id,
          thread,
          opts
        )
      end
    end)
  end

  @impl true
  def subscribe_station_tasks(workspace, subscriber)
      when is_map(workspace) and SystemsRuntime.Proc.is_process(subscriber) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, workspace} <- resolve_workspace_scope(workspace) do
        SalixWeb.StationTaskIndex.subscribe(workspace["default_group_id"], subscriber)
      end
    end)
  end

  @impl true
  def subscribe_group_conversation_mutations(workspace, subscriber)
      when is_map(workspace) and SystemsRuntime.Proc.is_process(subscriber) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, workspace} <- resolve_workspace_scope(workspace) do
        SalixIM.ConversationServer.subscribe_group_conversation_mutations(
          workspace["default_group_id"],
          subscriber
        )
      end
    end)
  end

  @impl true
  def append_group_router_conversation_message(workspace, attrs)
      when is_map(workspace) and is_map(attrs) do
    observe_salix(:deliver, fn ->
      with {:ok, workspace} <- resolve_workspace_scope(workspace) do
        SalixIM.RouterConversationInput.append_user_message(
          workspace["default_group_id"],
          attrs
        )
      end
    end)
  end

  @impl true
  def list_group_conversations(workspace, opts) when is_map(workspace) and is_list(opts) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.Conversations.list_group_conversations(workspace["default_group_id"], opts)
    end)
  end

  @impl true
  def list_group_activity_tasks(workspace) when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.ConversationServer.list_group_activity_tasks(workspace["default_group_id"])
    end)
  end

  @impl true
  def search_group_tasks(workspace, query, opts)
      when is_map(workspace) and is_binary(query) and is_list(opts) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.Conversations.search_group_tasks(
        workspace["default_group_id"],
        query,
        opts
      )
    end)
  end

  @impl true
  def get_group_conversation(workspace, conversation_id) when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.Conversations.get_group_conversation(
        workspace["default_group_id"],
        conversation_id
      )
    end)
  end

  @impl true
  def list_group_conversation_pins(workspace) when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.Conversations.list_conversation_pins(
        workspace["default_group_id"],
        workspace["salix_tenant_id"]
      )
    end)
  end

  @impl true
  def pin_group_conversation(workspace, conversation_id) when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.ConversationServer.pin_conversation(
        workspace["default_group_id"],
        conversation_id,
        workspace["salix_tenant_id"]
      )
    end)
  end

  @impl true
  def get_group_task_order(workspace) when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.Conversations.get_task_order(
        workspace["default_group_id"],
        workspace["salix_tenant_id"]
      )
    end)
  end

  @impl true
  def put_group_task_order(workspace, bucket, conversation_ids) when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.ConversationServer.put_task_order(
        workspace["default_group_id"],
        bucket,
        conversation_ids,
        workspace["salix_tenant_id"]
      )
    end)
  end

  @impl true
  def get_group_condensed_workspace(workspace) when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, group} <-
             Salix.Control.Groups.get(workspace["default_group_id"], workspace["salix_tenant_id"]),
           {:ok, condensed} <- SalixStore.CondensedWorkspaces.get(group["group_id"]) do
        {:ok, condensed_workspace_view(group, condensed)}
      end
    end)
  end

  @impl true
  def set_group_condensed_workspace_enabled(workspace, enabled)
      when is_map(workspace) and is_boolean(enabled) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, _group} <-
             Salix.Control.Groups.update(
               workspace["default_group_id"],
               %{"condensed_workspace_enabled" => enabled},
               workspace["salix_tenant_id"]
             ) do
        get_group_condensed_workspace(workspace)
      end
    end)
  end

  # People edit without the Agent suitability check: they are the authority
  # on what the Group's Agents should know.
  @impl true
  def update_group_condensed_workspace(workspace, operations, user_id)
      when is_map(workspace) and is_binary(user_id) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, group} <-
             Salix.Control.Groups.get(workspace["default_group_id"], workspace["salix_tenant_id"]) do
        case SalixStore.CondensedWorkspaces.apply_operations(
               group["group_id"],
               operations,
               %{"kind" => "user", "user_id" => user_id}
             ) do
          {:ok, condensed, removed} ->
            {:ok,
             group
             |> condensed_workspace_view(condensed)
             |> Map.put("removed_ids", removed)}

          {:error, {:conflict, missing, condensed}} ->
            {:error,
             {:conflict,
              %{
                "message" => "No statement has id #{Enum.join(missing, ", ")}. Nothing changed.",
                "condensed_workspace" => condensed_workspace_view(group, condensed)
              }}}

          {:error, {:invalid, message}} ->
            {:error, {:bad_request, message}}

          {:error, _reason} ->
            {:error, {:unavailable, :condensed_workspace}}
        end
      end
    end)
  end

  defp condensed_workspace_view(group, condensed) do
    %{
      "enabled" => group["condensed_workspace_enabled"] == true,
      "revision" => condensed.revision,
      "statements" => condensed.statements,
      "bytes" => SalixStore.CondensedWorkspaces.rendered_bytes(condensed.statements),
      "recommended_max_bytes" => SalixStore.CondensedWorkspaces.recommended_bytes(),
      "max_bytes" => SalixStore.CondensedWorkspaces.hard_limit_bytes(),
      "updated_by_kind" => condensed.updated_by["kind"],
      "updated_at" => condensed.updated_at && DateTime.to_unix(condensed.updated_at)
    }
  end

  @impl true
  def list_group_task_labels(workspace) when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.TaskLabels.list(workspace["default_group_id"], workspace["salix_tenant_id"])
    end)
  end

  @impl true
  def update_group_task_label_policy(workspace, policy) when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.TaskLabels.update_policy(
        workspace["default_group_id"],
        policy,
        workspace["salix_tenant_id"]
      )
    end)
  end

  @impl true
  def create_group_task_label(workspace, attrs) when is_map(workspace) and is_map(attrs) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.TaskLabels.create(
        workspace["default_group_id"],
        attrs,
        workspace["salix_tenant_id"]
      )
    end)
  end

  @impl true
  def update_group_task_label(workspace, label_id, attrs)
      when is_map(workspace) and is_map(attrs) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.TaskLabels.update(
        workspace["default_group_id"],
        label_id,
        attrs,
        workspace["salix_tenant_id"]
      )
    end)
  end

  @impl true
  def delete_group_task_label(workspace, label_id) when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.TaskLabels.delete(
        workspace["default_group_id"],
        label_id,
        workspace["salix_tenant_id"]
      )
    end)
  end

  @impl true
  def resolve_group_task_label_proposal(workspace, proposal_id, decision)
      when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.TaskLabels.resolve_proposal(
        workspace["default_group_id"],
        proposal_id,
        decision,
        workspace["salix_tenant_id"]
      )
    end)
  end

  @impl true
  def unpin_group_conversation(workspace, conversation_id) when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.ConversationServer.unpin_conversation(
        workspace["default_group_id"],
        conversation_id,
        workspace["salix_tenant_id"]
      )
    end)
  end

  @impl true
  def update_group_conversation(workspace, conversation_id, attrs)
      when is_map(workspace) and is_map(attrs) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.ConversationServer.update_group_conversation(
        workspace["default_group_id"],
        conversation_id,
        attrs
      )
    end)
  end

  @impl true
  def get_group_conversation_with_messages(workspace, conversation_id, opts)
      when is_map(workspace) and is_list(opts) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.Conversations.get_group_conversation_with_messages(
        workspace["default_group_id"],
        conversation_id,
        opts
      )
    end)
  end

  @impl true
  def list_group_conversation_message_page(workspace, conversation_id, opts)
      when is_map(workspace) and is_list(opts) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.Conversations.list_group_conversation_message_page(
        workspace["default_group_id"],
        conversation_id,
        opts
      )
    end)
  end

  @impl true
  def subscribe_group_conversation(workspace, conversation_id, subscriber)
      when is_map(workspace) and SystemsRuntime.Proc.is_process(subscriber) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.ConversationServer.subscribe_group_conversation(
        workspace["default_group_id"],
        conversation_id,
        subscriber
      )
    end)
  end

  @impl true
  def subscribe_group_conversation_participant(
        workspace,
        conversation_id,
        participant_id,
        subscriber
      )
      when is_map(workspace) and SystemsRuntime.Proc.is_process(subscriber) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.ConversationServer.subscribe_group_conversation_participant(
        workspace["default_group_id"],
        conversation_id,
        participant_id,
        subscriber
      )
    end)
  end

  @impl true
  def get_group_conversation_participant_status(workspace, conversation_id, participant_id)
      when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.ConversationServer.get_group_conversation_participant_status(
        workspace["default_group_id"],
        conversation_id,
        participant_id
      )
    end)
  end

  @impl true
  def get_group_conversation_participant_history(workspace, conversation_id, participant_id, opts) do
    observe_salix(:salix_boundary, fn ->
      CommaWeb.ParticipantHistory.read(workspace, conversation_id, participant_id, opts)
    end)
  end

  @impl true
  def ensure_group_conversation_user_participant(workspace, conversation_id, user_id)
      when is_map(workspace) and is_binary(user_id) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.ConversationServer.ensure_group_conversation_user_participant(
        workspace["default_group_id"],
        conversation_id,
        %{
          "user_id" => user_id,
          "state" => "active",
          "notification_filter" => %{"messages" => "none", "statuses" => "none"}
        }
      )
    end)
  end

  @impl true
  def reconcile_group_conversation_router_participant(workspace, conversation_id)
      when is_map(workspace) and is_binary(conversation_id) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.ConversationInput.reconcile_group_conversation_router_participant(
        workspace["default_group_id"],
        conversation_id
      )
    end)
  end

  @impl true
  def list_group_conversation_participants(workspace, conversation_id, opts)
      when is_map(workspace) and is_list(opts) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.Conversations.list_group_conversation_participants(
        workspace["default_group_id"],
        conversation_id,
        opts
      )
    end)
  end

  @impl true
  def get_group_conversation_messages(workspace, conversation_id) when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.Conversations.list_group_conversation_messages(
        workspace["default_group_id"],
        conversation_id,
        tail: 1000
      )
    end)
  end

  @impl true
  def get_group_conversation_message(workspace, conversation_id, message_id)
      when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.Conversations.get_group_conversation_message(
        workspace["default_group_id"],
        conversation_id,
        message_id
      )
    end)
  end

  @impl true
  def append_group_conversation_message(workspace, conversation_id, attrs)
      when is_map(workspace) and is_map(attrs) do
    observe_salix(:deliver, fn ->
      SalixIM.ConversationServer.append_group_conversation_message(
        workspace["default_group_id"],
        conversation_id,
        attrs
      )
    end)
  end

  @impl true
  def set_task_archived(workspace, conversation_id, action, version) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.ConversationServer.set_task_archived(
        workspace["default_group_id"],
        conversation_id,
        action,
        version
      )
    end)
  end

  @impl true
  def set_task_status(workspace, conversation_id, status, version, user_id) do
    observe_salix(:salix_boundary, fn ->
      SalixIM.ConversationServer.set_task_status(
        workspace["default_group_id"],
        conversation_id,
        status,
        version,
        user_id
      )
    end)
  end

  @impl true
  def switch_task_run(workspace, conversation_id, run, user_id) do
    observe_salix(:salix_boundary, fn ->
      case SalixIM.TaskRun.switch(workspace["default_group_id"], conversation_id, run, user_id) do
        {:ok, record} ->
          {:ok, record}

        {:error, {:placement, refusal}} ->
          refused(refusal, SalixIM.TaskPlacement.message(refusal))

        {:error, {:station, reason}} ->
          refused(reason, station_refusal(reason))

        {:error, {:bad_request, message}} ->
          refused(:invalid, message)

        {:error, _reason} = error ->
          error
      end
    end)
  end

  # Why a Task did not move, with a reason clients word in their language
  # when they know it, and the text they show when they do not.
  defp refused(reason, message),
    do: {:error, {:task_run_refused, refusal_reason(reason), message}}

  defp refusal_reason({:runs_on, {reason, _info}, _source}) when is_atom(reason), do: reason
  defp refusal_reason({:runs_on, reason, _source}) when is_atom(reason), do: reason
  defp refusal_reason({:model, {reason, _models}}) when is_atom(reason), do: reason
  defp refusal_reason({:model, reason}) when is_atom(reason), do: reason
  defp refusal_reason({:station_refused, _why}), do: :station_refused
  defp refusal_reason(reason) when is_atom(reason), do: reason
  defp refusal_reason(_reason), do: :refused

  defp station_refusal(:station_outdated),
    do: SalixStore.StationReadiness.instructions(:station_outdated)

  defp station_refusal(:device_offline), do: "that station is not connected now"

  defp station_refusal(:task_running),
    do: "the Task's model is in the middle of a turn; switch once it ends"

  defp station_refusal({:station_refused, why}) when is_binary(why), do: why
  defp station_refusal(reason), do: "the station did not take the Task: #{inspect(reason)}"

  @impl true
  def accept_task_review(workspace, conversation_id, review_version)
      when is_map(workspace) and is_integer(review_version) and review_version > 0 do
    observe_salix(:salix_boundary, fn ->
      SalixIM.ConversationServer.accept_task_review(
        workspace["default_group_id"],
        conversation_id,
        review_version
      )
    end)
  end

  @impl true
  def reserve_group_conversation_message(workspace, conversation_id, attrs)
      when is_map(workspace) and is_map(attrs) do
    observe_salix(:deliver, fn ->
      SalixIM.ConversationServer.reserve_group_conversation_message(
        workspace["default_group_id"],
        conversation_id,
        attrs
      )
    end)
  end

  defp observe_salix(operation, fun) do
    SystemsObservability.Context.with_surface("comma", fn ->
      SystemsObservability.Trace.with_span(
        :comma_salix,
        %{component: "comma_product", surface: "comma", operation: operation},
        fn -> observe_salix_result(operation, fun) end,
        kind: :client
      )
    end)
  end

  defp observe_salix_result(operation, fun) do
    started = SystemsClock.monotonic_time()

    try do
      result = fun.()
      outcome = if match?({:error, _}, result), do: "error", else: "ok"

      CommaProduct.Telemetry.emit_operation(
        operation,
        outcome,
        SystemsClock.monotonic_time() - started
      )

      result
    rescue
      exception ->
        CommaProduct.Telemetry.emit_operation(
          operation,
          "error",
          SystemsClock.monotonic_time() - started
        )

        reraise exception, __STACKTRACE__
    end
  end

  # The Loop runtime owns the Loop rows; one indexed read for the Tasks.
  @impl true
  def task_loops(workspace, conversation_ids)
      when is_map(workspace) and is_list(conversation_ids) do
    observe_salix(:salix_boundary, fn ->
      SalixAgent.Loops.task_loops(workspace["default_group_id"], conversation_ids)
    end)
  end

  # A coding Task keeps its branch's pull request on its Workload each time a turn ended or its panel read it
  # (`SalixWeb.CodingSandboxes.remember/4`): the card shows what GitHub said then, in one indexed read for the Tasks.
  @impl true
  def task_pull_requests(workspace, conversation_ids)
      when is_map(workspace) and is_list(conversation_ids) do
    observe_salix(:salix_boundary, fn ->
      found =
        for {id, workload} <-
              SalixStore.CodingSandboxes.get_by_conversations(
                workspace["salix_tenant_id"],
                conversation_ids
              ),
            %{"number" => number, "state" => state, "url" => url} <-
              [get_in(workload.spec, ["facts", "pull_request", "value"])],
            is_integer(number) and is_binary(state) and is_binary(url),
            into: %{},
            do: {id, %{"number" => number, "state" => state, "url" => url}}

      {:ok, found}
    end)
  end

  @impl true
  def task_activity_participants(workspace, conversation_id) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, %{"kind" => "agent_task"} = conversation} <-
             SalixIM.Conversations.get_group_conversation(
               workspace["default_group_id"],
               conversation_id
             ) do
        # Exactly two product-owned roles, resolved through the owner's existing
        # membership index. Never page participants or inspect private Sessions.
        participants =
          [conversation["created_by_agent_id"], conversation["task_worker_agent_id"]]
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> Enum.uniq()
          |> Enum.flat_map(fn agent_id ->
            case SalixIM.ConversationServer.get_group_conversation_agent_participant_identity(
                   workspace["default_group_id"],
                   conversation_id,
                   agent_id
                 ) do
              {:ok, participant} ->
                [
                  participant
                  |> Map.take(["participant_id", "name"])
                  |> Map.put("agent_id", agent_id)
                ]

              {:error, _reason} ->
                []
            end
          end)

        {:ok, participants}
      else
        {:error, _} = error -> error
        _ -> {:error, :not_found}
      end
    end)
  end

  @doc """
  Where a Task runs and the model it runs, which Task panels show instead of
  its Agent. `place` is `{kind: salix}`, `{kind: cloud_vm}` or
  `{kind: station, device_id, name}`. `model` is `{kind: platform}`,
  `{kind: catalog, name, vendor}`, `{kind: runtime, provider, name, vendor}`
  (`name` nil when the station runs its runtime's default), or nil when it is
  not known. `vendor` is the model's maker (`anthropic`, `openai`, …), whose
  mark clients show for the Task's Worker; nil when it is not known.

  A coding Task's run has `place` `{kind: sandbox, repo, state, reason?}`
  and `facts`: what its sandbox and GitHub answered last
  (`SalixWeb.CodingSandboxes.remember/4`), each part only once read:
  `usage` (the token use, nil when none), `changes` (`{files, additions,
  deletions}`) and `pull_request` (the branch's, nil when it has none).
  """
  @impl true
  def task_run(workspace, conversation_id) do
    group_id = workspace["default_group_id"]

    observe_salix(:salix_boundary, fn ->
      with {:ok, %{"kind" => "agent_task"} = conversation} <-
             SalixIM.Conversations.get_group_conversation(group_id, conversation_id),
           {:ok, stations} <- SalixStore.StationTaskSessions.of_task(group_id, conversation_id) do
        case {conversation, stations} do
          {%{"runs_on" => %{"kind" => "sandbox"}}, _stations} ->
            {:ok, coding_task_run(workspace, conversation)}

          {_conversation, []} ->
            {:ok,
             %{"place" => TaskPlace.salix(), "model" => salix_task_model(workspace, conversation)}}

          {_conversation, [station | _]} ->
            {:ok, station_task_run(workspace, station)}
        end
      else
        {:ok, _not_a_task} -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp salix_task_model(workspace, conversation) do
    case task_model_choice(workspace, conversation) do
      {:ok, choice} -> public_task_model(choice, workspace["salix_tenant_id"])
      {:error, _reason} -> nil
    end
  end

  defp public_task_model(%{"kind" => "platform"}, _tenant_id), do: %{"kind" => "platform"}

  defp public_task_model(%{"kind" => kind} = choice, tenant_id)
       when kind in ["catalog", "runtime"] do
    public =
      case ModelChoice.public(choice, tenant_id) do
        {:ok, public} -> public
        {:error, _reason} -> %{}
      end

    name =
      case public["model_display_name"] do
        name when is_binary(name) and name != "" -> name
        _unknown -> choice["model"]
      end

    if kind == "runtime",
      do: %{
        "kind" => "runtime",
        "provider" => choice["provider"],
        "name" => name,
        "vendor" => public["model_vendor"] || runtime_vendor(choice["provider"])
      },
      else: %{"kind" => "catalog", "name" => name, "vendor" => public["model_vendor"]}
  end

  defp public_task_model(_choice, _tenant_id), do: nil

  # A station's Session runs what it was invited with (`start`). Group-owned
  # Stations run the platform model with Codex when the Task names no model
  # (`SalixWeb.StationTasks`); other Stations use their runtime's default.
  defp station_task_run(workspace, %{device_id: device_id} = station) do
    group_id = workspace["default_group_id"]
    tenant_id = workspace["salix_tenant_id"]
    start = if is_map(station.start), do: station.start, else: %{}
    cloud_vm? = device_id == SalixStore.RuntimeIds.cloud_vm_device_id(group_id)

    group_station? =
      case SalixStore.ComputeStation.device_owner(tenant_id, group_id, device_id) do
        {_kind, %{"owner" => owner}} when owner in ["group_default", "group_station"] -> true
        :unmanaged -> cloud_vm?
        _ -> false
      end

    runtime = start["runtime"]

    place =
      if cloud_vm?,
        do: TaskPlace.cloud_vm(),
        else: %{
          "kind" => "station",
          "device_id" => device_id,
          "name" => station_name(workspace, device_id)
        }

    model =
      cond do
        is_binary(start["model"]) and start["model"] != "" ->
          public_task_model(
            %{"kind" => "runtime", "provider" => runtime, "model" => start["model"]},
            tenant_id
          )

        group_station? and runtime in [nil, "", "codex"] ->
          %{"kind" => "platform"}

        is_binary(runtime) and runtime != "" ->
          %{
            "kind" => "runtime",
            "provider" => runtime,
            "name" => nil,
            "vendor" => runtime_vendor(runtime)
          }

        true ->
          nil
      end

    %{"place" => place, "model" => model}
  end

  # A coding Task runs on its own sandbox (`SalixStore.CodingSandboxes`): the
  # place carries its repository, session branch and the sandbox's state.
  defp coding_task_run(workspace, conversation) do
    tenant_id = workspace["salix_tenant_id"]

    sandbox =
      case SalixStore.CodingSandboxes.get_by_conversation(
             tenant_id,
             conversation["conversation_id"]
           ) do
        {:ok, workload} -> workload.spec
        {:error, _} -> %{}
      end

    start = if is_map(sandbox["start"]), do: sandbox["start"], else: %{}
    repo = conversation["repo"] || sandbox["repo"] || %{}

    model =
      cond do
        is_binary(start["model"]) and start["model"] != "" ->
          public_task_model(
            %{"kind" => "runtime", "provider" => start["runtime"], "model" => start["model"]},
            tenant_id
          )

        start["runtime"] == "claude" ->
          %{"kind" => "runtime", "provider" => "claude", "name" => nil, "vendor" => "anthropic"}

        true ->
          %{"kind" => "runtime", "provider" => "codex", "name" => nil, "vendor" => "openai"}
      end

    %{
      "place" =>
        %{
          "kind" => "sandbox",
          "repo" => Map.take(repo, ~w(owner name base_ref branch)),
          "state" => sandbox["state"] || "starting"
        }
        |> then(fn place ->
          if is_binary(sandbox["reason"]),
            do: Map.put(place, "reason", sandbox["reason"]),
            else: place
        end),
      "model" => model,
      "facts" => coding_facts(sandbox["facts"])
    }
  end

  # What a coding Task's sandbox and GitHub answered last: each part's value, once read.
  defp coding_facts(%{} = facts) do
    for {part, %{"value" => value}} <- facts,
        part in ~w(usage changes pull_request),
        into: %{},
        do: {part, value}
  end

  defp coding_facts(_facts), do: %{}

  # The maker of the models a runtime runs by default.
  defp runtime_vendor("claude"), do: "anthropic"
  defp runtime_vendor("codex"), do: "openai"
  defp runtime_vendor(_runtime), do: nil

  defp station_name(workspace, device_id) do
    case SalixEnv.Control.get_environment(
           device_id,
           workspace["default_group_id"],
           workspace["salix_tenant_id"]
         ) do
      {:ok, device} -> Comma.Devices.display_name(device)
      {:error, _reason} -> nil
    end
  end

  @impl true
  def conversation_activity_context(workspace, conversation_id) when is_map(workspace) do
    with {:ok, workspace} <- resolve_workspace_scope(workspace),
         true <- conversation_id == workspace["router_conversation_id"],
         {:ok,
          %{
            "conversation_id" => ^conversation_id,
            "router_participant_id" => participant_id
          }} <- ensure_group_router_conversation(workspace),
         true <- SalixStore.Ids.valid_participant_id?(participant_id) do
      {:ok,
       %{
         participant_id: participant_id,
         conversation_id: conversation_id
       }}
    else
      false -> {:error, :invalid_group_router_conversation}
      {:error, _} = error -> error
      _ -> {:error, :conversation_agent_participant_not_found}
    end
  end

  @impl true
  def list_agent_skills(workspace) when is_map(workspace) do
    with {:ok, workspace} <- resolve_workspace_scope(workspace) do
      SalixAgent.SkillCatalog.list(workspace["router_agent_id"], workspace["salix_tenant_id"])
    end
  end

  @impl true
  def read_agent_skill_file(workspace, skill_id, path, max_bytes)
      when is_map(workspace) and is_binary(skill_id) and is_binary(path) and
             is_integer(max_bytes) and max_bytes > 0 do
    with {:ok, workspace} <- resolve_workspace_scope(workspace) do
      SalixAgent.SkillCatalog.read_file(
        workspace["router_agent_id"],
        workspace["salix_tenant_id"],
        skill_id,
        path,
        max_bytes
      )
    end
  end

  @impl true
  def write_agent_file(workspace, path, body)
      when is_map(workspace) and is_binary(path) and is_binary(body) do
    with {:ok, workspace} <- resolve_workspace_scope(workspace) do
      SalixAgent.Workspace.write(workspace["router_agent_id"], path, body)
    end
  end

  @impl true
  def write_agent_file_stream(workspace, path, stream)
      when is_map(workspace) and is_binary(path) do
    with {:ok, workspace} <- resolve_workspace_scope(workspace) do
      SalixAgent.Workspace.write_stream(workspace["router_agent_id"], path, stream)
    end
  end

  @impl true
  def read_agent_file(workspace, path, max_bytes)
      when is_map(workspace) and is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    max_bytes = min(max_bytes, @max_workspace_file_read_bytes)

    with {:ok, workspace} <- resolve_workspace_scope(workspace) do
      case SalixAgent.Workspace.stream(workspace["router_agent_id"], path) do
        {:ok, _stream, size} when is_integer(size) and size > max_bytes ->
          {:error, :too_large}

        {:ok, stream, size} when is_integer(size) and size >= 0 ->
          read_bounded_stream(stream, max_bytes)

        {:ok, _stream, _invalid_size} ->
          {:error, :workspace_file_unavailable}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @impl true
  def list_agent_files(workspace, dir, opts) when is_map(workspace) and is_binary(dir) do
    with {:ok, scope} <- resolve_workspace_scope(workspace),
         do: CommaWeb.AgentFiles.list(scope, dir, opts)
  end

  @impl true
  def read_agent_file_as(workspace, path, max_bytes, reader)
      when is_map(workspace) and is_binary(path) and is_integer(max_bytes) and max_bytes > 0 and
             is_binary(reader) do
    max_bytes = min(max_bytes, @max_workspace_file_read_bytes)

    with {:ok, scope} <- resolve_workspace_scope(workspace),
         do: CommaWeb.AgentFiles.read(scope, path, max_bytes, reader)
  end

  @impl true
  def write_agent_file_as(workspace, path, body, opts)
      when is_map(workspace) and is_binary(path) and is_binary(body) and is_list(opts) do
    with {:ok, scope} <- resolve_workspace_scope(workspace),
         do: CommaWeb.AgentFiles.write(scope, path, body, opts)
  end

  @impl true
  def delete_agent_file(workspace, path, opts)
      when is_map(workspace) and is_binary(path) and is_list(opts) do
    with {:ok, scope} <- resolve_workspace_scope(workspace),
         do: CommaWeb.AgentFiles.delete(scope, path, opts)
  end

  @impl true
  def get_router_instructions(workspace) when is_map(workspace) do
    with {:ok, scope} <- resolve_workspace_scope(workspace),
         {:ok, router} <- workspace_agent(scope, "router") do
      {:ok, SalixAgent.ToolPolicy.system_prompt("router", router) || ""}
    end
  end

  @impl true
  def set_router_instructions(workspace, content, opts)
      when is_map(workspace) and is_binary(content) and is_list(opts) do
    expected = Keyword.get(opts, :expected_hash)

    # Checked on the record each write attempt replaces, so a change saved
    # meanwhile (Drive, Settings, the Router's own import) is never overwritten.
    precondition = fn router ->
      with :ok <- instructions_unchanged(router, expected),
           do: instructions_clearable(content, router)
    end

    with {:ok, scope} <- resolve_workspace_scope(workspace),
         {:ok, router} <- workspace_agent(scope, "router"),
         {:ok, updated} <-
           SalixAgent.Control.configure_if(
             router["agent_id"],
             %{"router_system_prompt" => content},
             scope["salix_tenant_id"],
             precondition
           ) do
      {:ok, SalixAgent.ToolPolicy.system_prompt("router", updated) || ""}
    end
  end

  defp instructions_unchanged(_router, nil), do: :ok

  defp instructions_unchanged(router, expected) do
    current = SalixAgent.ToolPolicy.system_prompt("router", router) || ""

    if SalixStore.Crypto.hex(current) == expected,
      do: :ok,
      else: {:error, {:conflict, "the instructions changed"}}
  end

  # Without its own instructions the Router runs with the shared
  # `system_prompt`, which this does not change: clearing would only bring that
  # one back.
  defp instructions_clearable(content, router) do
    if String.trim(content) == "" and router["system_prompt"] not in [nil, ""],
      do: {:error, {:bad_request, "the instructions cannot be cleared"}},
      else: :ok
  end

  @impl true
  def read_agent_blob(workspace, agent_id, ref, max_bytes)
      when is_map(workspace) and is_binary(agent_id) and is_map(ref) and
             is_integer(max_bytes) and max_bytes > 0 do
    max_bytes = min(max_bytes, @max_workspace_file_read_bytes)

    with :ok <- authorize_agent_blob(workspace, agent_id),
         {:ok, stream, size, _filename} <-
           SalixIM.Ports.AgentWorkspace.read_ref_stream(agent_id, ref, "resource"),
         true <- is_integer(size) and size >= 0 and size <= max_bytes do
      read_bounded_stream(stream, max_bytes)
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
      _invalid -> {:error, :workspace_file_unavailable}
    end
  end

  def read_agent_blob(_workspace, _agent_id, _blob_ref, _max_bytes), do: {:error, :not_found}

  @impl true
  def stream_agent_blob(workspace, agent_id, ref, range)
      when is_map(workspace) and is_binary(agent_id) and is_map(ref) do
    with :ok <- authorize_agent_blob(workspace, agent_id),
         {:ok, stream, size, _filename} <- read_ref_stream(agent_id, ref, range),
         true <- is_integer(size) and size >= 0 do
      {:ok, stream, size}
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
      _invalid -> {:error, :workspace_file_unavailable}
    end
  end

  def stream_agent_blob(_workspace, _agent_id, _blob_ref, _range), do: {:error, :not_found}

  @impl true
  def presign_agent_blob(workspace, agent_id, ref, opts)
      when is_map(workspace) and is_binary(agent_id) and is_map(ref) and is_list(opts) do
    with :ok <- authorize_agent_blob(workspace, agent_id) do
      SalixStore.Blob.presign(agent_id, ref, opts)
    end
  end

  def presign_agent_blob(_workspace, _agent_id, _blob_ref, _opts), do: {:error, :not_found}

  @impl true
  def link_agent_blob(workspace, agent_id, ref, path)
      when is_map(workspace) and is_binary(agent_id) and is_map(ref) and is_binary(path) do
    with :ok <- authorize_agent_blob(workspace, agent_id),
         {:ok, workspace} <- resolve_workspace_scope(workspace) do
      SalixAgent.Workspace.put_ref(workspace["router_agent_id"], path, ref)
    end
  end

  def link_agent_blob(_workspace, _agent_id, _ref, _path), do: {:error, :not_found}

  defp read_ref_stream(agent_id, ref, nil),
    do: SalixIM.Ports.AgentWorkspace.read_ref_stream(agent_id, ref, "resource")

  defp read_ref_stream(agent_id, ref, range),
    do: SalixIM.Ports.AgentWorkspace.read_ref_stream(agent_id, ref, "resource", range)

  # Blob storage uses global UUID keys: the sender Agent must belong to the
  # caller's Group for its blob to be read.
  defp authorize_agent_blob(workspace, agent_id) do
    with {:ok, workspace} <- resolve_workspace_scope(workspace),
         group_id = workspace["default_group_id"],
         true <- SalixStore.Ids.valid_agent_id_for_group?(agent_id, group_id),
         {:ok, agent} <- SalixAgent.Control.get(agent_id, workspace["salix_tenant_id"]),
         true <- agent["group_id"] == group_id do
      :ok
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
      _invalid -> {:error, :workspace_file_unavailable}
    end
  end

  defp read_bounded_stream(stream, max_bytes) do
    result =
      try do
        Enum.reduce_while(stream, {[], 0}, fn
          chunk, {chunks, total_bytes} when is_binary(chunk) ->
            next_bytes = total_bytes + byte_size(chunk)

            if next_bytes > max_bytes do
              {:halt, {:error, :too_large}}
            else
              {:cont, {[chunk | chunks], next_bytes}}
            end

          _invalid_chunk, _state ->
            {:halt, {:error, :workspace_file_unavailable}}
        end)
      rescue
        _error -> {:error, :workspace_file_unavailable}
      catch
        _kind, _reason -> {:error, :workspace_file_unavailable}
      end

    case result do
      {:error, _reason} = error -> error
      {chunks, _total_bytes} -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp ensure_salix_tenant(id, attrs) do
    case Salix.Control.Tenants.get(id) do
      {:ok, tenant} ->
        ensure_salix_tenant_config(id, attrs["config"], tenant)

      {:error, :not_found} ->
        attrs = attrs |> encode_config() |> Map.delete("tenant_id")
        normalize_created(Salix.Control.Tenants.create_preallocated(attrs, id))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_workspace_group(group, workspace) do
    expected_owner = %{
      "surface" => "comma",
      "vm_profile_key" => "cf-standard-1",
      "product_owner_type" => "workspace",
      "product_owner_id" => workspace["id"],
      "billing_account_id" => workspace["billing_account_id"],
      "salix_tenant_id" => workspace["salix_tenant_id"],
      "salix_group_id" => workspace["default_group_id"],
      "router_agent_id" => workspace["router_agent_id"],
      "charge_policy" => "platform_paid"
    }

    actual_owner = Map.take(group["billing_owner"] || %{}, Map.keys(expected_owner))

    expected_owner =
      if is_nil(actual_owner["vm_profile_key"]),
        do: Map.delete(expected_owner, "vm_profile_key"),
        else: expected_owner

    if group["group_id"] == workspace["default_group_id"] and
         group["tenant_id"] == workspace["salix_tenant_id"] and
         group["router_agent_id"] == workspace["router_agent_id"] and
         actual_owner == expected_owner do
      :ok
    else
      {:error, :workspace_scope_conflict}
    end
  end

  defp verify_workspace_agent(agent, agent_id, tenant_id, group_id, role) do
    if agent["agent_id"] == agent_id and agent["tenant_id"] == tenant_id and
         agent["group_id"] == group_id and agent["role"] == role do
      :ok
    else
      {:error, :workspace_scope_conflict}
    end
  end

  defp encode_config(%{"config" => config} = attrs) when is_map(config),
    do: Map.put(attrs, "config", Jason.encode!(config))

  defp encode_config(attrs), do: attrs

  defp ensure_salix_tenant_config(_id, nil), do: :ok

  defp ensure_salix_tenant_config(id, config) do
    case Salix.Control.Tenants.get(id) do
      {:ok, tenant} -> ensure_salix_tenant_config(id, config, tenant)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_salix_tenant_config(_id, nil, _tenant), do: :ok

  defp ensure_salix_tenant_config(id, config, tenant) when is_map(config) do
    current = decode_config(tenant["config"])
    merged = deep_merge(current, config)

    if merged == current do
      :ok
    else
      normalize_created(Salix.Control.Tenants.update(id, %{"config" => Jason.encode!(merged)}))
    end
  end

  defp ensure_salix_group(id, tenant_id, attrs) do
    case Salix.Control.Groups.get(id, tenant_id) do
      {:ok, _group} ->
        :ok

      {:error, :not_found} ->
        attrs = Map.delete(attrs, "group_id")
        normalize_created(Salix.Control.Groups.create_preallocated(attrs, tenant_id, id))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_salix_group_router_if_absent(group_id, tenant_id, router_agent_id) do
    with {:ok, group} <- Salix.Control.Groups.get(group_id, tenant_id) do
      case group["router_agent_id"] do
        current when is_binary(current) and current != "" ->
          :ok

        _absent ->
          normalize_created(
            Salix.Control.Groups.update(
              group_id,
              %{"router_agent_id" => router_agent_id},
              tenant_id
            )
          )
      end
    end
  end

  defp ensure_salix_agent(id, tenant_id, attrs) do
    case SalixAgent.Control.get(id, tenant_id) do
      {:ok, agent} ->
        validate_agent_identity(agent, attrs)

      {:error, :not_found} ->
        attrs = Map.delete(attrs, "agent_id")
        normalize_created(SalixAgent.Control.create_preallocated(attrs, tenant_id, id))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_agent_identity(agent, attrs) do
    if agent["group_id"] == attrs["group_id"] and agent["role"] == attrs["role"] do
      :ok
    else
      {:error, :workspace_scope_conflict}
    end
  end

  defp workspace_tenant_config(%{"vm" => %{"enabled" => true, "provider" => provider}}) do
    with {:ok, providers} <- configured_vm_providers(provider) do
      {:ok,
       %{
         "vm" => %{
           "default_provider" => provider,
           "providers" => providers
         }
       }}
    end
  end

  defp workspace_tenant_config(_workspace), do: {:ok, nil}

  defp configured_vm_providers(provider) do
    configured = comma_vm_config()
    providers = normalize_map(configured["providers"] || configured[:providers] || %{})

    provider_section =
      providers[provider] ||
        case provider do
          "cloudflare" -> default_cloudflare_provider()
          _ -> nil
        end

    if is_map(provider_section) do
      {:ok, Map.put(providers, provider, normalize_map(provider_section))}
    else
      {:error, {:bad_request, "vm provider #{provider} is not configured"}}
    end
  end

  defp default_cloudflare_provider do
    cfg =
      :salix_env
      |> SystemsRuntime.get_env(:cloudflare_vm_gateway, %{})
      |> normalize_map()

    base_url = cfg["base_url"]
    secret = cfg["secret"]

    if is_binary(base_url) and base_url != "" and is_binary(secret) and secret != "" do
      %{"enabled" => true, "gateway_base_url" => base_url, "gateway_secret" => secret}
    end
  end

  defp comma_vm_config do
    case SystemsRuntime.get_env(:comma_core, :salix_vm, %{}) do
      cfg when is_map(cfg) -> cfg
      cfg when is_list(cfg) -> Map.new(cfg)
      _ -> %{}
    end
  end

  defp strip_vm_command_flags(vm) when is_map(vm), do: Map.delete(normalize_map(vm), "recreate")

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      value =
        if is_map(value) do
          normalize_map(value)
        else
          value
        end

      {to_string(key), value}
    end)
  end

  defp normalize_map(_), do: %{}

  defp decode_config(nil), do: %{}
  defp decode_config(""), do: %{}
  defp decode_config(config) when is_map(config), do: config

  defp decode_config(config) when is_binary(config) do
    case Jason.decode(config) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, l, r -> deep_merge(l, r) end)
  end

  defp deep_merge(_left, right), do: right

  defp normalize_created({:ok, _}), do: :ok
  defp normalize_created({:error, :exists}), do: :ok
  defp normalize_created({:error, reason}), do: {:error, reason}

  # ---- Drive binding (the agents' /drive mount) ----

  # The row as stored, disabled or not: Comma decides whether to write from
  # what exists, not from what the agent mount may use right now.
  @impl true
  def drive_binding(workspace) when is_map(workspace) do
    with {:ok, group_id} <- default_group_id(workspace) do
      Salix.Control.DriveBindings.stored(group_id)
    end
  end

  @impl true
  def put_drive_binding(workspace, attrs) when is_map(workspace) and is_map(attrs) do
    with {:ok, group_id} <- default_group_id(workspace) do
      Salix.Control.DriveBindings.put(group_id, attrs)
    end
  end

  defp default_group_id(workspace) do
    case workspace["default_group_id"] do
      group_id when is_binary(group_id) and group_id != "" -> {:ok, group_id}
      _ -> {:error, :workspace_group_missing}
    end
  end
end
