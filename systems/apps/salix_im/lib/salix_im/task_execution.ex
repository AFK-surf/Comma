defmodule SalixIM.TaskExecution do
  @moduledoc """
  Owner-authorized IM operations for one ordinary Task command.

  The model proposes operations and fixed parameters. Canonical human source,
  Workspace ownership, Task participant and Session identity are server facts.
  Payload fields come from the operation owner; all other parameters, including
  absent optional targets, remain fixed. Existing provider checks still apply.
  """

  alias SalixIM.{
    ConversationParticipantActivity,
    ConversationSourceIdentity,
    Conversations,
    GroupDirectory,
    ProviderConnects
  }

  alias SalixIM.Provider.Manuals

  @key "task_execution"
  @limit 20

  def protected_source_ref_keys, do: [@key]

  def prepare(_scope, _ctx, %{"execution_requests" => requests}, _worker)
      when requests in [nil, []], do: {:ok, %{}}

  def prepare(scope, ctx, params, worker) do
    case params["execution_requests"] do
      nil ->
        {:ok, %{}}

      requests when is_list(requests) and length(requests) in 1..@limit ->
        origin = value(ctx, :trusted_origin) || %{}

        with "router" <- scope.agent["role"],
             {:ok, group} <- GroupDirectory.get_group(scope.group_id),
             true <- group["router_agent_id"] == scope.agent_id,
             nil <- params["schedule"],
             "internal" <- origin["provider"],
             "user_chat" <- origin["conversation_kind"],
             true <- origin["agent_group_id"] == scope.group_id,
             {:ok, %{"role" => "worker"} = target} <- GroupDirectory.get_agent(worker),
             true <- target["group_id"] == scope.group_id,
             nil <- target["inspector_policy"],
             true <- value(ctx, :source_message_id) in List.wrap(value(ctx, :source_message_ids)),
             {:ok, identity} <-
               ConversationSourceIdentity.decode(
                 value(ctx, :source_message_id),
                 origin["conversation_id"]
               ),
             true <-
               identity.message_id == origin["message_id"] and
                 identity.participant_id == origin["participant_id"],
             :ok <- participant_session(scope, origin, value(ctx, :session_id)),
             {:ok, requester} <-
               requester(scope.group_id, origin["conversation_id"], origin["message_id"]),
             :ok <- authorize_owner(scope.group_id, requester),
             {:ok, requests} <- prepare_requests(scope.group_id, requests) do
          {:ok,
           %{
             "ifc_members" => ["comma_user|" <> requester],
             @key => %{
               "requester_id" => requester,
               "worker_agent_id" => worker,
               "parent_conversation_id" => origin["conversation_id"],
               "parent_message_id" => origin["message_id"],
               "requests" => requests
             }
           }}
        else
          _ ->
            {:error,
             "task_execution_not_authorized: execution requests require a current personal Comma owner request and an ordinary one-shot Task"}
        end

      _ ->
        {:error,
         "task_execution_invalid: execution_requests must contain 1 to #{@limit} operations"}
    end
  end

  # IFC uses this only for the exact effect being checked. The transcript's
  # Task command stays agent-authored data; it cannot authorize other tools.
  def ifc_request("im_api." <> api, args, ctx) do
    with {:ok, scope} <- GroupDirectory.scope_for_agent(value(ctx, :agent_id)),
         {:ok, grant} <- resolve(scope, ctx),
         :ok <- permitted_effect(scope, ctx, api, args),
         {:ok, principal} <- SalixIFC.Codec.encode_principal({:comma_user, grant["requester_id"]}) do
      origin = value(ctx, :trusted_origin)
      {:ok, origin["source_message_id"], principal}
    else
      _ -> report_request(api, args, ctx)
    end
  end

  def ifc_request(_name, _args, _ctx), do: :none

  # An ordinary Task assigns work even when it grants no external IM effects.
  # Admit only a report to that Task, as the assigned agent, not as a human.
  # The canonical assignment and consumed delegator message are the authority.
  # Source labels still pass through the same IFC kernel and provider checks.
  defp report_request("internal.send_message", args, ctx) do
    origin = value(ctx, :trusted_origin) || %{}
    source_id = value(ctx, :source_message_id)

    with {:ok, scope} <- GroupDirectory.scope_for_agent(value(ctx, :agent_id)),
         "worker" <- scope.agent["role"],
         "internal" <- origin["provider"],
         "agent_task" <- origin["conversation_kind"],
         true <- origin["agent_group_id"] == scope.group_id,
         :ok <- permitted_effect(scope, ctx, "internal.send_message", args),
         true <- source_id in List.wrap(value(ctx, :source_message_ids)),
         {:ok, identity} <-
           ConversationSourceIdentity.decode(source_id, origin["conversation_id"]),
         true <-
           identity.message_id == origin["message_id"] and
             identity.participant_id == origin["participant_id"],
         {:ok, task} <-
           Conversations.get_group_conversation_record(scope.group_id, origin["conversation_id"]),
         "agent_task" <- task["kind"],
         "active" <- task["status"],
         true <- ordinary_schedule?(task["schedule"]),
         true <- task["task_worker_agent_id"] == scope.agent_id,
         :ok <- participant_session(scope, origin, value(ctx, :session_id)),
         {:ok, participant} <-
           Conversations.get_group_conversation_participant(
             scope.group_id,
             origin["conversation_id"],
             origin["participant_id"]
           ),
         "active" <- participant["state"],
         {:ok, command} <-
           Conversations.get_group_conversation_message(
             scope.group_id,
             origin["conversation_id"],
             origin["message_id"]
           ),
         "agent" <- command["actor_type"],
         delegator when is_binary(delegator) and delegator != "" <- task["created_by_agent_id"],
         true <- command["agent_id"] == delegator,
         {:ok, principal} <- SalixIFC.Codec.encode_principal({:agent, scope.agent_id}) do
      {:ok, source_id, principal}
    else
      _ -> :none
    end
  end

  defp report_request(_api, _args, _ctx), do: :none

  defp permitted_effect(_scope, ctx, "internal.send_message", args) do
    if args["connect_id"] == "internal" and
         args["conversation_id"] == value(ctx, :trusted_origin)["conversation_id"],
       do: :ok,
       else: {:error, :task_execution_effect_denied}
  end

  defp permitted_effect(scope, ctx, api, args) do
    [provider | _] = String.split(api, ".", parts: 2)

    case authorize(scope, ctx, provider, api, args["connect_id"], Map.delete(args, "connect_id")) do
      {:ok, _connect} -> :ok
      _ -> {:error, :task_execution_effect_denied}
    end
  end

  def requests(scope, ctx) do
    case resolve(scope, ctx) do
      {:ok, grant} -> Enum.filter(grant["requests"], &current_installation?(scope.group_id, &1))
      _ -> []
    end
  end

  def active?(scope, ctx), do: match?({:ok, _}, resolve(scope, ctx))

  defp current_installation?(group_id, request) do
    with {:ok, connect} <-
           ProviderConnects.get_delegatable_connect_by_id(
             group_id,
             request["connect_id"],
             request["provider"]
           ),
         {:ok, current} <- installation(connect) do
      current == request["installation"]
    else
      _ -> false
    end
  end

  def authorize(scope, ctx, provider, api, connect_id, params) do
    with {:ok, grant} <- resolve(scope, ctx),
         {:ok, payload_keys, _definition} <- operation(provider, api),
         request when is_map(request) <-
           Enum.find(grant["requests"], fn request ->
             request["provider"] == provider and request["api"] == api and
               request["connect_id"] == connect_id and
               Map.drop(params, payload_keys) == request["params"]
           end),
         {:ok, connect} <-
           ProviderConnects.get_delegatable_connect_by_id(scope.group_id, connect_id, provider),
         {:ok, installation} <- installation(connect),
         true <- installation == request["installation"] do
      {:ok, connect}
    else
      _ ->
        {:error,
         "task_execution_not_authorized: this Task command does not permit that operation, connection, or target"}
    end
  end

  defp resolve(scope, ctx) do
    origin = value(ctx, :trusted_origin) || %{}
    group_id = scope.group_id

    with "worker" <- scope.agent["role"],
         "internal" <- origin["provider"],
         "agent_task" <- origin["conversation_kind"],
         true <- origin["agent_group_id"] == group_id,
         true <- value(ctx, :source_message_id) in List.wrap(value(ctx, :source_message_ids)),
         {:ok, identity} <-
           ConversationSourceIdentity.decode(
             value(ctx, :source_message_id),
             origin["conversation_id"]
           ),
         true <-
           identity.message_id == origin["message_id"] and
             identity.participant_id == origin["participant_id"],
         {:ok, task} <-
           Conversations.get_group_conversation_record(group_id, origin["conversation_id"]),
         "agent_task" <- task["kind"],
         "active" <- task["status"],
         true <- ordinary_schedule?(task["schedule"]),
         grant when is_map(grant) <- get_in(task, ["source_refs", @key]),
         true <- grant["worker_agent_id"] == scope.agent_id,
         :ok <- participant_session(scope, origin, value(ctx, :session_id)),
         {:ok, command} <-
           Conversations.get_group_conversation_message(
             group_id,
             origin["conversation_id"],
             origin["message_id"]
           ),
         1 <- command["seq"],
         true <- get_in(command, ["metadata", "task_command"]) == true,
         {:ok, requester} <-
           requester(group_id, grant["parent_conversation_id"], grant["parent_message_id"]),
         true <- requester == grant["requester_id"],
         :ok <- authorize_owner(group_id, requester),
         requests when is_list(requests) and length(requests) in 1..@limit <- grant["requests"] do
      {:ok, Map.put(grant, "requests", Enum.map(requests, &current_request/1))}
    else
      _ -> {:error, :task_execution_not_authorized}
    end
  end

  # Read-time compatibility for already authorized, immutable pre-split grants.
  # Only the operation spelling changes; the installation and exact destination
  # stay pinned. New create commands must use the current operation catalog.
  defp current_request(
         %{"provider" => "slack", "api" => "slack.post_message", "params" => params} = request
       )
       when is_map(params) do
    case params["thread_ts"] do
      empty when empty in [nil, ""] ->
        request
        |> Map.put("api", "slack.post_channel_message")
        |> Map.put("params", Map.delete(params, "thread_ts"))

      thread when is_binary(thread) and thread != "" ->
        Map.put(request, "api", "slack.reply_message")

      _ ->
        request
    end
  end

  defp current_request(request), do: request

  defp ordinary_schedule?(nil), do: true

  defp ordinary_schedule?(%{"schedule_id" => nil, "command" => command} = schedule),
    do: is_binary(command) and map_size(schedule) == 2

  defp ordinary_schedule?(_), do: false

  defp participant_session(scope, origin, session_id) do
    with true <- is_binary(session_id) and session_id != "",
         {:ok, participant} <-
           Conversations.get_group_conversation_participant(
             scope.group_id,
             origin["conversation_id"],
             origin["participant_id"]
           ),
         {agent_id, ^session_id} <- ConversationParticipantActivity.session_ref(participant),
         true <- agent_id == scope.agent_id do
      :ok
    else
      _ -> {:error, :task_execution_participant_invalid}
    end
  end

  defp requester(group_id, conversation_id, message_id) do
    with {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, ^conversation_id} <- SalixIM.ConversationIds.group_router(group),
         {:ok, %{"kind" => "user_chat"}} <-
           Conversations.get_group_conversation_record(group_id, conversation_id),
         {:ok, %{"actor_type" => "user", "user_id" => user_id} = message} <-
           Conversations.get_group_conversation_message(group_id, conversation_id, message_id),
         true <- is_binary(user_id) and user_id not in ["", "current"],
         {:ok, participant} <-
           Conversations.get_group_conversation_participant(
             group_id,
             conversation_id,
             message["participant_id"]
           ),
         "active" <- participant["state"],
         true <- participant["actor_type"] == "user" and participant["user_id"] == "current" do
      {:ok, user_id}
    else
      _ -> {:error, :task_execution_source_invalid}
    end
  end

  defp authorize_owner(group_id, user_id) do
    case Application.get_env(:salix_im, :task_execution_owner_mod) do
      nil -> {:error, :task_execution_owner_unavailable}
      mod -> mod.authorize_owner(group_id, user_id)
    end
  end

  defp prepare_requests(group_id, requests) do
    Enum.reduce_while(requests, {:ok, []}, fn request, {:ok, acc} ->
      with %{"api" => api, "connect_id" => connect_id, "params" => params} <- request,
           true <- Enum.sort(Map.keys(request)) == ~w(api connect_id params),
           true <- is_binary(api) and is_binary(connect_id),
           [provider, _operation] <- String.split(api, ".", parts: 2),
           {:ok, payload_keys, definition} <- operation(provider, api),
           true <- is_map(params) and Enum.all?(Map.keys(params), &is_binary/1),
           true <-
             Enum.all?(
               definition["required_params"] -- payload_keys,
               &(params[&1] not in [nil, ""])
             ),
           true <- Enum.all?(Map.keys(params), &Map.has_key?(definition["parameters"], &1)),
           {:ok, connect} <-
             ProviderConnects.get_delegatable_connect_by_id(group_id, connect_id, provider),
           {:ok, installation} <- installation(connect),
           true <-
             connect["managed_by"] != "comma_product" or
               params["chat_id"] == connect["managed_peer_id"] do
        normalized = %{
          "provider" => provider,
          "api" => api,
          "connect_id" => connect_id,
          "installation" => installation,
          "params" => Map.drop(params, payload_keys)
        }

        {:cont, {:ok, acc ++ [normalized]}}
      else
        _ -> {:halt, {:error, :task_execution_operation_invalid}}
      end
    end)
  end

  # Bind an existing installation, not a reusable record locator. These are
  # provider-owned account facts, never token material or model assertions.
  defp installation(connect) do
    required =
      case connect["provider"] do
        "slack" -> ~w(connect_generation workspace_id)
        "telegram" -> ~w(bot_user_id)
        "feishu" -> ~w(app_id tenant_key)
        _ -> []
      end

    if required != [] and Enum.all?(required, &(connect[&1] not in [nil, ""])),
      do:
        {:ok, Map.take(connect, required ++ ~w(provider connect_id managed_by managed_peer_id))},
      else: {:error, :task_execution_installation_unknown}
  end

  defp operation(provider, api) do
    with {:ok, manual} <- Manuals.manual(provider),
         definition when is_map(definition) <- Enum.find(manual["apis"], &(&1["name"] == api)),
         payload when is_list(payload) <- definition["task_payload_params"] do
      {:ok, payload, definition}
    else
      _ -> {:error, :task_execution_operation_unsupported}
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
