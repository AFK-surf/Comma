defmodule CommaWeb.SalixClient do
  @moduledoc false

  @behaviour Comma.Salix.Client

  alias SalixAgent.Templates

  @max_workspace_file_read_bytes 10_000_001
  @max_workspace_model_templates 100
  # Attachment downloads are saved to disk rather than rendered inline, so they
  # carry the client's own download bound rather than the inline-image one.

  @impl true
  def provision_workspace_scope(workspace) when is_map(workspace) do
    tenant_id = workspace["salix_tenant_id"]
    group_id = workspace["default_group_id"]
    router_agent_id = workspace["router_agent_id"]
    worker_agent_id = workspace["default_worker_agent_id"]

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

    with {:ok, template_id} <- ensure_default_agent_template(),
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
         :ok <-
           ensure_salix_agent(
             router_agent_id,
             tenant_id,
             %{
               "agent_id" => router_agent_id,
               "group_id" => group_id,
               "name" => workspace["name"] <> " Router",
               "role" => "router",
               "purpose" => "comma_workspace_router"
             }
             |> maybe_put_template_id(template_id)
             |> maybe_put("vm", workspace["vm"])
           ),
         :ok <- ensure_salix_group_router_if_absent(group_id, tenant_id, router_agent_id),
         :ok <-
           ensure_salix_agent(
             worker_agent_id,
             tenant_id,
             %{
               "agent_id" => worker_agent_id,
               "group_id" => group_id,
               "name" => workspace["name"] <> " Worker",
               "role" => "worker",
               "purpose" => "comma_workspace_default_worker"
             }
             |> maybe_put_template_id(template_id)
             |> maybe_put("vm", workspace["vm"])
           ) do
      :ok
    end
  end

  @impl true
  def verify_workspace_scope(workspace) when is_map(workspace) do
    tenant_id = workspace["salix_tenant_id"]
    group_id = workspace["default_group_id"]
    router_agent_id = workspace["router_agent_id"]
    worker_agent_id = workspace["default_worker_agent_id"]

    with {:ok, %{"tenant_id" => ^tenant_id}} <- Salix.Control.Tenants.get(tenant_id),
         {:ok, group} <- Salix.Control.Groups.get(group_id, tenant_id),
         :ok <- verify_workspace_group(group, workspace),
         {:ok, router} <- SalixAgent.Control.get(router_agent_id, tenant_id),
         :ok <- verify_workspace_agent(router, router_agent_id, tenant_id, group_id, "router"),
         {:ok, worker} <- SalixAgent.Control.get(worker_agent_id, tenant_id),
         :ok <- verify_workspace_agent(worker, worker_agent_id, tenant_id, group_id, "worker") do
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

  @impl true
  def conversation_uses_private_model?(workspace, binding) do
    agent_result =
      case binding["kind"] do
        "user_chat" ->
          {:ok, workspace["router_agent_id"]}

        "agent_task" ->
          with {:ok, conversation} <-
                 get_group_conversation(
                   workspace,
                   get_in(binding, ["internal", "salix_conversation_id"])
                 ) do
            {:ok, conversation["task_worker_agent_id"]}
          end

        _ ->
          {:error, :not_found}
      end

    with {:ok, id} when is_binary(id) <- agent_result,
         {:ok, agent} <- SalixAgent.Control.get(id, workspace["salix_tenant_id"]),
         true <- agent["group_id"] == workspace["default_group_id"],
         {:ok, llm} when is_map(llm) <- Templates.resolve_llm_for_record(agent) do
      llm["credential_scope"] == "tenant"
    else
      _ -> false
    end
  end

  @impl true
  def get_workspace_agent_models(workspace) when is_map(workspace) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, resolved_workspace} <- resolve_workspace_scope(workspace),
           {:ok, router} <- workspace_agent_model(resolved_workspace, "router"),
           {:ok, worker} <- workspace_agent_model(resolved_workspace, "worker"),
           {:ok, workers} <- workspace_worker_models(resolved_workspace),
           {:ok, defaults} <-
             SalixAgent.AgentDefaults.tenant(resolved_workspace["salix_tenant_id"]),
           {:ok, available_models} <-
             Templates.list_available(
               resolved_workspace["salix_tenant_id"],
               @max_workspace_model_templates
             ) do
        tenant_id = resolved_workspace["salix_tenant_id"]

        {:ok,
         %{
           "workspace_id" => resolved_workspace["id"],
           "agents" => %{"router" => router, "worker" => worker},
           "workers" => workers,
           "worker_default_template_id" => defaults["worker_template_id"],
           # What each role uses when nothing is chosen for it in this
           # workspace: the platform default, described so the UI can name it.
           "platform_defaults" => %{
             "router" => platform_default_model("router", tenant_id),
             "worker" => platform_default_model("worker", tenant_id)
           },
           "available_models" =>
             Enum.map(
               SalixAgent.AgentDefaults.selectable(available_models),
               &public_model_template/1
             )
         }}
      end
    end)
  end

  def get_user_workspace_agent_models(workspace) do
    with {:ok, policy} <- Comma.ModelSelectionPolicy.get(),
         {:ok, models} <- Comma.Salix.Client.get_workspace_agent_models(workspace) do
      available =
        Enum.filter(models["available_models"], fn template ->
          template["scope"] == "tenant" or
            Comma.ModelSelectionPolicy.allowed?(policy, template["template_id"])
        end)

      {:ok, Map.put(models, "available_models", available)}
    end
  end

  def update_user_workspace_agent_model(workspace, target, template_id) do
    with :ok <- user_model_choice_allowed(workspace, template_id) do
      Comma.Salix.Client.update_workspace_agent_model(workspace, target, template_id)
    end
  end

  def update_user_workspace_worker_default(workspace, template_id) do
    with :ok <- user_model_choice_allowed(workspace, template_id) do
      update_workspace_worker_default(workspace, template_id)
    end
  end

  defp user_model_choice_allowed(_workspace, nil), do: :ok

  defp user_model_choice_allowed(workspace, id) when is_binary(id) do
    with {:ok, policy} <- Comma.ModelSelectionPolicy.get(),
         {:ok, template} <- Templates.get(id, workspace["salix_tenant_id"]) do
      cond do
        template["hidden"] == true -> {:error, :invalid_model_template}
        template["tenant_id"] != nil -> :ok
        Comma.ModelSelectionPolicy.allowed?(policy, id) -> :ok
        true -> {:error, :model_not_user_selectable}
      end
    else
      {:error, :not_found} -> {:error, :invalid_model_template}
      error -> error
    end
  end

  defp user_model_choice_allowed(_workspace, _id), do: {:error, :invalid_model_template}

  @doc "Update one existing Agent. Role aliases address the workspace's initial Agents."
  @impl true
  def update_workspace_agent_model(workspace, target, template_id)
      when is_map(workspace) and is_binary(target) and
             (is_binary(template_id) or is_nil(template_id)) do
    observe_salix(:salix_boundary, fn ->
      with {:ok, scope} <- resolve_workspace_scope(workspace),
           tenant_id = scope["salix_tenant_id"],
           {:ok, template_id} <- validate_model_choice(template_id, tenant_id),
           {:ok, agent} <- model_target(scope, target),
           :ok <- template_model_writable(agent),
           {:ok, updated} <- assign_agent_template(agent, template_id, tenant_id),
           {:ok, template, source} <- Templates.resolve_public_template_for_record(updated) do
        {:ok, public_workspace_agent_model(updated, template, source)}
      end
    end)
  end

  def update_workspace_agent_model(_, _, _), do: {:error, :invalid_workspace_agent_model}

  def update_workspace_worker_default(workspace, template_id) do
    with {:ok, scope} <- resolve_workspace_scope(workspace),
         {:ok, id} <- validate_model_choice(template_id, scope["salix_tenant_id"]),
         :ok <- write_worker_default(scope["salix_tenant_id"], id) do
      {:ok, %{"template_id" => id}}
    end
  end

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

  # One native page, at most 50 candidate records and no scan-ahead or polling.
  def workspace_worker_models(workspace, cursor \\ nil) do
    with {:ok, scope} <- resolve_workspace_scope(workspace),
         {:ok, page} <-
           SalixAgent.Control.page_agents(scope["salix_tenant_id"], scope["default_group_id"],
             role: "worker",
             limit: 50,
             cursor: cursor
           ) do
      Enum.reduce_while(page.items, {:ok, []}, fn agent, {:ok, acc} ->
        case workspace_worker_model(agent) do
          {:ok, model} ->
            {:cont, {:ok, [model | acc]}}

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, items} ->
          {:ok, %{"items" => Enum.reverse(items), "next_cursor" => page.next_cursor}}

        error ->
          error
      end
    end
  end

  defp workspace_worker_model(agent) do
    case runtime_model_settings(agent) do
      nil ->
        with {:ok, template, source} <- Templates.resolve_public_template_for_record(agent) do
          {:ok, public_workspace_agent_model(agent, template, source)}
        end

      settings ->
        runtime = SalixAgent.AgentManagement.Projection.runtime(agent["runtime_config"])

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
  end

  # Compute inherits the Agent template only when its runtime model is absent.
  # Mapping: ExternalSessionStore.resolve_compute_runtime_model/2.
  defp runtime_model_settings(%{"runtime_config" => %{"kind" => kind} = runtime})
       when kind in ~w(external connected_runtime),
       do: runtime

  defp runtime_model_settings(%{
         "runtime_config" => %{"kind" => "compute_workload", "runtime_spec" => settings}
       })
       when is_map(settings) do
    if present_model?(settings["model"]), do: settings
  end

  defp runtime_model_settings(_), do: nil

  defp present_model?(model), do: is_binary(model) and String.trim(model) != ""

  defp template_model_writable(agent) do
    if is_nil(runtime_model_settings(agent)),
      do: :ok,
      else:
        {:error,
         {:bad_request, "This Worker's model is controlled by its runtime configuration."}}
  end

  defp validate_model_choice(nil, _tenant_id), do: {:ok, nil}

  defp validate_model_choice(template_id, tenant_id) when is_binary(template_id) do
    with {:ok, template} <- visible_model_template(template_id, tenant_id) do
      {:ok, template["template_id"]}
    end
  end

  defp validate_model_choice(_, _), do: {:error, :invalid_model_template}

  defp write_worker_default(tenant_id, template_id) do
    case Salix.Control.Tenants.update_config(tenant_id, "agent_defaults", %{
           "worker_template_id" => template_id
         }) do
      {:ok, _config} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp platform_default_model(role, tenant_id) do
    with {:ok, id, _} <- SalixAgent.AgentDefaults.resolve_platform_default(role),
         {:ok, template} <- Templates.get_public(id, tenant_id) do
      public_model_template(template)
    else
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

  defp workspace_agent_model(workspace, role) do
    with {:ok, agent} <- workspace_agent(workspace, role),
         {:ok, template, source} <- Templates.resolve_public_template_for_record(agent),
         true <- valid_public_model_template?(template) do
      {:ok, public_workspace_agent_model(agent, template, source)}
    else
      false -> {:error, :workspace_agent_model_unavailable}
      {:error, :not_found} -> {:error, :workspace_agent_model_unavailable}
      {:error, :agent_template_unresolved} -> {:error, :workspace_agent_model_unavailable}
      {:error, _reason} = error -> error
      _invalid -> {:error, :workspace_agent_model_unavailable}
    end
  end

  defp workspace_agent(workspace, role) when role in ["router", "worker"] do
    agent_id =
      case role do
        "router" -> workspace["router_agent_id"]
        "worker" -> workspace["default_worker_agent_id"]
      end

    tenant_id = workspace["salix_tenant_id"]
    group_id = workspace["default_group_id"]

    with true <- is_binary(agent_id) and agent_id != "",
         {:ok, agent} <- SalixAgent.Control.get(agent_id, tenant_id),
         :ok <- verify_workspace_agent(agent, agent_id, tenant_id, group_id, role) do
      {:ok, agent}
    else
      false -> {:error, :workspace_agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp visible_model_template(template_id, tenant_id) do
    template_id = String.trim(template_id)

    if template_id == "" do
      {:error, :invalid_model_template}
    else
      case Templates.get(template_id, tenant_id) do
        {:ok, %{"hidden" => true}} ->
          {:error, :invalid_model_template}

        {:ok, template} ->
          public = public_model_template(Templates.public_json(template))

          if public["template_id"] == template_id and valid_public_model_template?(public),
            do: {:ok, public},
            else: {:error, :invalid_model_template}

        {:error, :not_found} ->
          {:error, :invalid_model_template}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp assign_agent_template(agent, template_id, tenant_id) do
    if agent["template_id"] == template_id,
      do: {:ok, agent},
      else:
        SalixAgent.Control.configure(
          agent["agent_id"],
          %{"template_id" => template_id},
          tenant_id
        )
  end

  defp public_source(:platform_default), do: "platform_default"
  defp public_source(_chosen), do: "pinned"

  defp public_workspace_agent_model(agent, template, source) do
    %{
      "agent_id" => agent["agent_id"],
      "name" => agent["name"] || agent["agent_id"],
      "role" => agent["role"],
      "source" => public_source(source),
      "template_id" => template["template_id"],
      "template_name" => template["name"],
      "model" => template["model"],
      "provider" => template["provider"]
    }
    |> Map.merge(
      Map.take(
        template,
        ~w(model_display_name model_vendor model_icon account_pool scope reasoning_effort)
      )
    )
  end

  defp public_model_template(template) do
    Map.take(
      template,
      ~w(template_id name model provider scope model_display_name model_vendor model_icon account_pool reasoning_effort)
    )
  end

  defp valid_public_model_template?(%{
         "template_id" => template_id,
         "name" => name,
         "model" => model,
         "provider" => provider
       }) do
    Enum.all?([template_id, name, model, provider], &is_binary/1) and
      template_id != "" and name != "" and model != ""
  end

  defp valid_public_model_template?(_template), do: false

  @impl true
  def update_workspace_vm(workspace, vm) when is_map(workspace) and is_map(vm) do
    workspace = Map.put(workspace, "vm", strip_vm_command_flags(vm))

    with {:ok, workspace} <- resolve_workspace_scope(workspace),
         {:ok, tenant_config} <- workspace_tenant_config(workspace),
         :ok <- ensure_salix_tenant_config(workspace["salix_tenant_id"], tenant_config),
         :ok <- update_workspace_agent_vms(workspace, vm) do
      :ok
    end
  end

  @doc false
  def ensure_default_agent_template do
    case Application.get_env(:comma_core, :default_agent_template) do
      template when is_map(template) ->
        template = stringify_keys(template)
        id = template["template_id"] || "comma-e2e-default"

        attrs =
          template
          |> Map.put("template_id", id)
          |> Map.put_new("name", "Comma E2E Default")

        case Templates.get(id) do
          {:ok, _existing} ->
            case Templates.update(id, attrs) do
              {:ok, _template} -> {:ok, id}
              {:error, reason} -> {:error, reason}
            end

          {:error, :not_found} ->
            case Templates.create(attrs) do
              {:ok, _template} -> {:ok, id}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp maybe_put_template_id(attrs, nil), do: attrs
  defp maybe_put_template_id(attrs, template_id), do: Map.put(attrs, "template_id", template_id)
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
  def subscribe_group_conversation_list(workspace, kind, subscriber)
      when is_map(workspace) and kind in ["agent_task", "user_chat"] and is_pid(subscriber) do
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
      when is_map(workspace) and is_pid(subscriber) do
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
      when is_map(workspace) and is_pid(subscriber) do
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
    started = System.monotonic_time()

    try do
      result = fun.()
      outcome = if match?({:error, _}, result), do: "error", else: "ok"
      CommaProduct.Telemetry.emit_operation(operation, outcome, System.monotonic_time() - started)
      result
    rescue
      exception ->
        CommaProduct.Telemetry.emit_operation(
          operation,
          "error",
          System.monotonic_time() - started
        )

        reraise exception, __STACKTRACE__
    end
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
  def read_agent_blob(workspace, agent_id, ref, max_bytes)
      when is_map(workspace) and is_binary(agent_id) and is_map(ref) and
             is_integer(max_bytes) and max_bytes > 0 do
    max_bytes = min(max_bytes, @max_workspace_file_read_bytes)

    with {:ok, workspace} <- resolve_workspace_scope(workspace),
         group_id = workspace["default_group_id"],
         true <- SalixStore.Ids.valid_agent_id_for_group?(agent_id, group_id),
         {:ok, agent} <- SalixAgent.Control.get(agent_id, workspace["salix_tenant_id"]),
         true <- agent["group_id"] == group_id,
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
        with :ok <- validate_agent_identity(agent, attrs) do
          maybe_update_agent(id, tenant_id, agent, attrs)
        end

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

  defp update_workspace_agent_vms(workspace, vm) do
    [workspace["router_agent_id"], workspace["default_worker_agent_id"]]
    |> Enum.reduce_while(:ok, fn agent_id, :ok ->
      case SalixAgent.Control.configure(agent_id, %{"vm" => vm}, workspace["salix_tenant_id"]) do
        {:ok, _agent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_update_agent(id, tenant_id, agent, attrs) do
    updates =
      %{}
      |> maybe_update_vm(agent, attrs)

    if updates == %{} do
      :ok
    else
      normalize_created(SalixAgent.Control.configure(id, updates, tenant_id))
    end
  end

  defp maybe_update_vm(updates, agent, %{"vm" => vm}) when is_map(vm) do
    if strip_vm_command_flags(agent["vm"] || %{}) == strip_vm_command_flags(vm) do
      updates
    else
      Map.put(updates, "vm", vm)
    end
  end

  defp maybe_update_vm(updates, _agent, _attrs), do: updates

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
      |> Application.get_env(:cloudflare_vm_gateway, %{})
      |> normalize_map()

    base_url = cfg["base_url"]
    secret = cfg["secret"]

    if is_binary(base_url) and base_url != "" and is_binary(secret) and secret != "" do
      %{"enabled" => true, "gateway_base_url" => base_url, "gateway_secret" => secret}
    end
  end

  defp comma_vm_config do
    case Application.get_env(:comma_core, :salix_vm, %{}) do
      cfg when is_map(cfg) -> cfg
      cfg when is_list(cfg) -> Map.new(cfg)
      _ -> %{}
    end
  end

  defp strip_vm_command_flags(vm) when is_map(vm), do: Map.delete(normalize_map(vm), "recreate")
  defp strip_vm_command_flags(_vm), do: %{}

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
