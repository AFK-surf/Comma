defmodule Salix.Bindings.AgentConversations do
  @moduledoc false

  @behaviour SalixIM.Ports.TaskCreate
  @behaviour SalixIM.Ports.TaskSchedule
  @behaviour SalixAgent.MemoryConsultationSource

  @conversation_search_limit 100

  @impl SalixAgent.MemoryConsultationSource
  def search_worker_sessions(group_id, keywords, [], limit) do
    with {:ok, hits} <-
           SalixIM.Conversations.search_group_conversations_by_keywords(
             group_id,
             keywords,
             limit: @conversation_search_limit
           ) do
      targets =
        hits
        |> Enum.filter(&(&1["conversation_kind"] == "agent_task"))
        |> Enum.sort_by(&(&1["created_at"] || 0), :desc)
        |> Enum.flat_map(&worker_targets_for_hit(group_id, &1))

      {:ok, target_page(targets, length(hits) >= @conversation_search_limit, limit)}
    end
  end

  def search_worker_sessions(group_id, _keywords, conversation_refs, limit) do
    targets =
      conversation_refs
      |> Enum.take(limit)
      |> Enum.flat_map(&worker_targets_for_ref(group_id, &1))

    {:ok, target_page(targets, length(conversation_refs) > limit, limit)}
  end

  @impl SalixAgent.MemoryConsultationSource
  def consult_worker_session(group_id, target, question, request_id, opts) do
    conversation_id = get_in(target, [:conversation_ref, "conversation_id"])
    participant_id = target[:participant_id]

    with {:ok, resolved} <-
           SalixIM.ConversationServer.resolve_worker_memory_target(
             group_id,
             conversation_id,
             participant_id
           ),
         :ok <- same_target(resolved, target),
         {:ok, agent} <- SalixAgent.Control.get_record(resolved["agent_id"]),
         :ok <- eligible_worker(agent, group_id),
         {:ok, result} <-
           SalixIM.Ports.AgentDelivery.consult_memory(
             resolved["agent_id"],
             resolved["session_id"],
             question,
             request_id,
             opts
           ),
         {:ok, current} <-
           SalixIM.ConversationServer.resolve_worker_memory_target(
             group_id,
             conversation_id,
             participant_id
           ),
         :ok <- same_target(current, target),
         {:ok, current_agent} <- SalixAgent.Control.get_record(current["agent_id"]),
         :ok <- eligible_worker(current_agent, group_id) do
      {:ok, result}
    end
  end

  @impl SalixIM.Ports.TaskCreate
  def create_task_conversation(
        group_id,
        delegator_agent_id,
        target_agent_id,
        attrs
      ) do
    SalixCluster.TaskSchedules.create_task_conversation(
      group_id,
      delegator_agent_id,
      target_agent_id,
      attrs
    )
  end

  @impl SalixIM.Ports.TaskCreate
  def task_worker(scope),
    do:
      SalixAgent.AgentManagement.Ports.task_worker(%{
        tenant_id: scope.tenant_id,
        group_id: scope.group_id
      })

  @impl SalixIM.Ports.TaskCreate
  def default_task_model(scope),
    do:
      SalixAgent.AgentManagement.Ports.default_task_model(%{
        tenant_id: scope.tenant_id,
        group_id: scope.group_id
      })

  @impl SalixIM.Ports.TaskCreate
  def session_model(scope, choice) do
    with :ok <- station_runs(scope, choice) do
      SalixAgent.AgentManagement.Ports.session_model(
        %{
          tenant_id: scope.tenant_id,
          group_id: scope.group_id,
          runs_on: scope[:runs_on]
        },
        choice
      )
    end
  end

  # A Task that runs on a station takes a model the station's profiles have
  # enabled, as the station last said (`task_models`). One that has said
  # nothing runs no model a Task can name.
  defp station_runs(%{runs_on: %{"device_id" => device_id}} = scope, %{
         "kind" => "runtime",
         "provider" => provider,
         "model" => model
       }) do
    models =
      case SalixEnv.Registry.get_device(scope.tenant_id, scope.group_id, device_id) do
        {:ok, device} -> get_in(device, ["meta", "capabilities", "task_models"])
        _ -> nil
      end

    cond do
      not is_map(models) -> {:error, {:not_on_station, %{}}}
      model in List.wrap(models[provider]) -> :ok
      true -> {:error, {:not_on_station, Map.take(models, ~w(claude codex))}}
    end
  end

  defp station_runs(_scope, _choice), do: :ok

  # The station must be connected now, and a desktop station take Tasks as
  # stations ask each other (`tasks` 2, systems/station/docs/tasks.md):
  # nothing is woken on the way. An agent starts the Group's Cloud VM itself (`cloud_vm.start`); a
  # Task runs there when the Group's Cloud VM switch is on. Giving a station the Task is the
  # `station.session` egress; with no transcript to label, a Group in IFC
  # enforce mode refuses it.
  #
  # A Loop Task (`loop`) runs its Loop while every app is closed. A person's
  # own computer, a station minted for its owner (`meta.owner_user_id`, the
  # Comma desktop station), stops taking Tasks when the app quits and is never
  # woken, so it is refused for one, connected or not. Stations Salix or a
  # provisioner runs, and the Cloud VM, stay allowed.
  @impl SalixIM.Ports.TaskCreate
  def runs_on(scope, request) do
    ctx = %{tenant_id: scope.tenant_id, group_id: scope.group_id, agent_id: scope[:agent_id]}

    {class, _descriptor} =
      SalixAgent.IFC.Destination.describe("station.session", %{"action" => "start"}, ctx)

    if class == :egress and SalixAgent.IFC.mode_for(ctx.tenant_id, ctx.group_id) == :enforce,
      do: {:error, :ifc_enforced},
      else: resolve_runs_on(scope, request)
  end

  defp resolve_runs_on(scope, %{"kind" => "cloud_vm"} = request) when map_size(request) == 1 do
    # The Group's Cloud VM switch decides; a binding only makes the Cloud VM
    # the Worker's default Task location.
    case SalixAgent.Control.get_record(scope.agent_id) do
      {:ok, %{"tenant_id" => tenant, "group_id" => group} = agent}
      when tenant == scope.tenant_id and group == scope.group_id ->
        if SalixAgent.CloudVM.allowed?(agent),
          do: cloud_vm_running(scope),
          else: {:error, :cloud_vm_disabled}

      {:ok, _other_group} ->
        {:error, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve_runs_on(scope, %{"kind" => "station", "device_id" => device_id} = request)
       when map_size(request) == 2 and is_binary(device_id) and device_id != "" do
    if device_id == SalixStore.RuntimeIds.cloud_vm_device_id(scope.group_id) do
      {:error, :use_cloud_vm_kind}
    else
      with {:ok, device} <- device(scope, device_id),
           :ok <- unattended(scope, device),
           {:ok, _device} <- connected_station(device),
           do: {:ok, %{"kind" => "station", "device_id" => device_id}}
    end
  end

  defp resolve_runs_on(_scope, _request), do: {:error, :invalid_runs_on}

  defp cloud_vm_running(scope) do
    device_id = SalixStore.RuntimeIds.cloud_vm_device_id(scope.group_id)

    # Its station is Salix's own image's: it takes Tasks as Salix asks. It
    # is running once the VM is ready: a station that connected while its
    # archive is still to be restored takes no work (a used station cannot
    # take its archive back).
    with {:ok, %{"status" => "ready"}} <-
           SalixWeb.ComputeProviders.Cloudflare.get_record(scope.group_id),
         {:ok, _device} <- connected(scope, device_id) do
      {:ok, %{"kind" => "cloud_vm", "device_id" => device_id}}
    else
      _not_running -> {:error, :cloud_vm_not_running}
    end
  end

  # A device that reports no `tasks` capability runs the old connector
  # (`salix-connect`), which runs no Task: its user installs the Comma station
  # (`device_needs_station`); an older `tasks` is a station to update
  # (`station_outdated`). See `SalixStore.StationReadiness`.
  #
  # The capabilities are those of the device's last connection, which its
  # record keeps while it is offline. A device that cannot take Tasks is
  # refused with how to upgrade it whether it is connected or not: coming
  # back online would not let it take the Task. A record that never
  # connected holds no capabilities: that device is only known to be offline.
  defp connected_station(device) do
    capabilities = get_in(device, ["meta", "capabilities"])

    case {SalixStore.StationReadiness.check(capabilities), online(device)} do
      {:ready, online} -> online
      {_unknown, {:error, _} = offline} when not is_map(capabilities) -> offline
      {refusal, _online} -> {:error, refusal}
    end
  end

  defp unattended(%{loop: true}, %{"meta" => %{"owner_user_id" => owner}})
       when is_binary(owner) and owner != "",
       do: {:error, :personal_station_for_loop}

  defp unattended(_scope, _device), do: :ok

  defp connected(scope, device_id) do
    with {:ok, device} <- device(scope, device_id), do: online(device)
  end

  defp device(scope, device_id) do
    case SalixEnv.Registry.get_device(scope.tenant_id, scope.group_id, device_id) do
      {:ok, device} -> {:ok, device}
      {:error, _reason} -> {:error, :device_not_found}
    end
  end

  defp online(%{"status" => "connected", "connector_run_id" => run_id} = device)
       when is_binary(run_id) and run_id != "",
       do: {:ok, device}

  defp online(_device), do: {:error, :device_offline}

  @impl SalixIM.Ports.TaskSchedule
  def update_task_schedule(group_id, conversation_id, schedule) do
    SalixCluster.TaskSchedules.update_task_schedule(group_id, conversation_id, schedule)
  end

  defp worker_targets_for_ref(group_id, ref) when is_map(ref) do
    conversation_id = ref["conversation_id"] || ref[:conversation_id]
    message_id = ref["message_id"] || ref[:message_id]

    with true <- is_binary(conversation_id),
         {:ok, conversation} <-
           SalixIM.Conversations.get_group_conversation(group_id, conversation_id),
         true <- conversation["kind"] == "agent_task",
         {:ok, hit} <- referenced_hit(group_id, conversation, message_id) do
      worker_targets_for_hit(group_id, hit)
    else
      _ -> []
    end
  end

  defp worker_targets_for_ref(_group_id, _ref), do: []

  defp referenced_hit(_group_id, conversation, message_id) when message_id in [nil, ""] do
    {:ok,
     %{
       "conversation_id" => conversation["conversation_id"],
       "conversation_kind" => conversation["kind"],
       "title" => conversation["title"] || "",
       "created_at" => conversation["updated_at"] || conversation["created_at"] || 0,
       "snippet" => ""
     }}
  end

  defp referenced_hit(group_id, conversation, message_id) when is_binary(message_id) do
    case SalixIM.Conversations.get_group_conversation_message(
           group_id,
           conversation["conversation_id"],
           message_id
         ) do
      {:ok, message} ->
        {:ok,
         %{
           "conversation_id" => conversation["conversation_id"],
           "conversation_kind" => conversation["kind"],
           "title" => conversation["title"] || "",
           "message_id" => message_id,
           "created_at" =>
             message["created_at"] || conversation["updated_at"] ||
               conversation["created_at"] || 0,
           "snippet" => message |> Map.get("content") |> content_text() |> String.slice(0, 160)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp referenced_hit(_group_id, _conversation, _message_id), do: {:error, :invalid_message_id}

  defp worker_targets_for_hit(group_id, hit) do
    conversation_id = hit["conversation_id"]

    with {:ok, conversation} <-
           SalixIM.Conversations.get_group_conversation(group_id, conversation_id),
         true <- conversation["kind"] == "agent_task",
         {:ok, %{"participants" => participants}} <-
           SalixIM.Conversations.list_group_conversation_participants(
             group_id,
             conversation_id
           ) do
      workers = Enum.filter(participants, &worker_participant?(group_id, &1))
      relevant = relevant_workers(group_id, conversation_id, hit, workers)

      Enum.map(relevant, fn participant ->
        agent_id = participant["agent_id"]
        session_id = get_in(participant, ["payload", "session_id"])

        %{
          agent_id: agent_id,
          session_id: session_id,
          participant_id: participant["participant_id"],
          worker_role: participant["role_label"] || "worker",
          runtime_kind: "internal",
          rank_at: hit["created_at"] || 0,
          conversation_ref:
            %{
              "conversation_id" => conversation_id,
              "title" => hit["title"] || conversation["title"] || "",
              "snippet" => hit["snippet"] || ""
            }
            |> maybe_put("message_id", hit["message_id"])
        }
      end)
    else
      _ -> []
    end
  end

  defp worker_participant?(group_id, participant) do
    agent_id = participant["agent_id"]
    session_id = get_in(participant, ["payload", "session_id"])

    participant["actor_type"] == "agent" and participant["state"] != "inactive" and
      is_binary(agent_id) and is_binary(session_id) and
      case SalixAgent.Control.get_record(agent_id) do
        {:ok, agent} ->
          agent["group_id"] == group_id and agent["role"] == "worker" and
            SalixAgent.Control.visible?(agent)

        _ ->
          false
      end
  end

  defp relevant_workers(_group_id, _conversation_id, %{"message_id" => nil}, workers),
    do: workers

  defp relevant_workers(group_id, conversation_id, %{"message_id" => message_id}, workers)
       when is_binary(message_id) do
    case SalixIM.Conversations.get_group_conversation_message(
           group_id,
           conversation_id,
           message_id
         ) do
      {:ok, message} ->
        mentioned_ids = get_in(message, ["mentions", "participant_ids"]) || []
        sender_id = message["participant_id"]
        sender_agent_id = message["agent_id"]

        selected =
          Enum.filter(workers, fn participant ->
            participant["participant_id"] == sender_id or
              participant["agent_id"] == sender_agent_id or
              participant["participant_id"] in mentioned_ids
          end)

        if selected == [], do: workers, else: selected

      _ ->
        workers
    end
  end

  defp relevant_workers(_group_id, _conversation_id, _hit, workers), do: workers

  defp content_text(content) when is_binary(content), do: content
  defp content_text(%{"text" => text}) when is_binary(text), do: text

  defp content_text(content) when is_list(content) do
    content
    |> Enum.map(&content_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp content_text(_content), do: ""

  defp same_target(resolved, target) do
    if resolved["participant_id"] == target[:participant_id] and
         resolved["agent_id"] == target[:agent_id] and
         resolved["session_id"] == target[:session_id] do
      :ok
    else
      {:error, :participant_binding_changed}
    end
  end

  defp eligible_worker(agent, group_id) do
    if agent["group_id"] == group_id and agent["role"] == "worker" and
         SalixAgent.Control.visible?(agent) do
      :ok
    else
      {:error, :target_unavailable}
    end
  end

  defp target_page(targets, truncated, limit) do
    unique =
      targets
      |> Enum.sort_by(&Map.get(&1, :rank_at, 0), :desc)
      |> Enum.uniq_by(&{&1.agent_id, &1.session_id})

    %{
      targets: Enum.take(unique, limit),
      truncated: truncated or length(unique) > limit
    }
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
