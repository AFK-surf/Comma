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

  # A desktop station must be connected now, and take Tasks as stations ask
  # each other (`tasks` 2, systems/station/docs/tasks.md): nothing wakes a
  # person's computer. The Group's Cloud VM need not be running: a Task runs
  # there when the Group's Cloud VM switch is on, and one made while the VM
  # sleeps, wakes, or was never made is kept for it and given to it once
  # Salix has it up (`SalixWeb.StationTasks`). Giving a station the Task is
  # the `station.session` egress; with no transcript to label, a Group in IFC
  # enforce mode refuses it. A Loop Task never asks: it runs inside Salix
  # (`SalixIM.TaskPlacement`).
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
          do: {:ok, %{"kind" => "cloud_vm", "device_id" => cloud_vm_device_id(scope)}},
          else: {:error, :cloud_vm_disabled}

      {:ok, _other_group} ->
        {:error, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve_runs_on(scope, %{"kind" => "automatic", "model" => model}),
    do: SalixWeb.TaskStations.resolve(scope, model)

  defp resolve_runs_on(scope, %{"kind" => "station", "device_id" => device_id} = request)
       when map_size(request) == 2 and is_binary(device_id) and device_id != "" do
    if device_id == SalixStore.RuntimeIds.cloud_vm_device_id(scope.group_id) do
      {:error, :use_cloud_vm_kind}
    else
      with :ok <-
             SalixStore.ComputeStation.admit_device(
               scope.tenant_id,
               scope.group_id,
               device_id
             ),
           {:ok, device} <- device(scope, device_id),
           {:ok, _device} <- connected_station(device),
           {:ok, _owner} <-
             SalixEnv.StationConnection.authorize(
               SalixStore.ComputeStation.connection(scope.tenant_id, scope.group_id, device)
             ),
           do: {:ok, %{"kind" => "station", "device_id" => device_id}}
    end
  end

  # A coding Task: a new sandbox of its own (`SalixWeb.CodingSandboxes`) with
  # GitHub repository `repo` checked out. The repository must be one the
  # Group's connected GitHub account reads, and the Group under its limit of
  # sandboxes. Answers the repository with its base ref.
  #
  # A Task that continues pull request `repo.pull_request` works on that pull
  # request's head branch, into its base: the sandbox's grant pushes to the
  # Task branch, so the Worker's pushes update the pull request itself.
  defp resolve_runs_on(scope, %{"kind" => "sandbox", "repo" => repo} = request)
       when map_size(request) == 2 do
    with true <- SalixWeb.L4ES.enabled?() || {:error, :sandbox_unavailable},
         {:ok, repo} <- repo(repo),
         :ok <- sandbox_room(scope),
         {:ok, %{token: token}} <-
           SalixWeb.CodingSandboxes.github().token(scope.tenant_id, scope.group_id),
         {:ok, found} <- github_repo(token, repo),
         {:ok, repo} <- carried_pull_request(token, repo) do
      {:ok,
       %{
         "kind" => "sandbox",
         "repo" => Map.put_new(repo, "base_ref", found.default_branch)
       }}
    end
  end

  defp resolve_runs_on(_scope, _request), do: {:error, :invalid_runs_on}

  @github_name ~r/^[A-Za-z0-9_.-]{1,100}$/
  @git_ref ~r/^(?!\/)(?!.*\.\.)(?!.*\/\/)[A-Za-z0-9._\/-]{1,255}(?<!\/)(?<!\.lock)$/

  # A pull request names the Task's branches itself: it comes without them.
  defp repo(%{"pull_request" => number} = repo)
       when is_integer(number) and number > 0 do
    with false <- Map.has_key?(repo, "base_ref") or Map.has_key?(repo, "branch"),
         {:ok, rest} <- repo(Map.delete(repo, "pull_request")) do
      {:ok, Map.put(rest, "pull_request", number)}
    else
      true -> {:error, :invalid_repo}
      error -> error
    end
  end

  defp repo(%{"owner" => owner, "name" => name} = repo)
       when is_binary(owner) and is_binary(name) do
    refs = Map.take(repo, ["base_ref", "branch"])

    if Regex.match?(@github_name, owner) and Regex.match?(@github_name, name) and
         map_size(Map.drop(repo, ["owner", "name", "base_ref", "branch"])) == 0 and
         Enum.all?(refs, fn {_k, v} -> is_binary(v) and Regex.match?(@git_ref, v) end),
       do: {:ok, Map.merge(%{"owner" => owner, "name" => name}, refs)},
       else: {:error, :invalid_repo}
  end

  defp repo(_repo), do: {:error, :invalid_repo}

  # An open pull request of the repository, its head branch in the repository
  # itself: the sandbox's grant covers that repository only.
  defp carried_pull_request(
         token,
         %{"owner" => owner, "name" => name, "pull_request" => number} = repo
       ) do
    case SalixWeb.CodingSandboxes.github().pull_request_refs(token, owner, name, number) do
      {:ok, %{state: state}} when state not in ["open", "draft"] ->
        {:error, {:pull_request_not_open, number, state}}

      {:ok, %{head_ref: head, head_repo: head_repo, base_ref: base}} ->
        cond do
          not is_binary(head_repo) or not Regex.match?(@git_ref, head) or
              not Regex.match?(@git_ref, base) ->
            {:error, {:pull_request_branch_unusable, number}}

          String.downcase(head_repo) != String.downcase("#{owner}/#{name}") ->
            {:error, {:pull_request_from_fork, number}}

          true ->
            {:ok, Map.merge(repo, %{"base_ref" => base, "branch" => head})}
        end

      {:error, :github_reauthorization_required} = error ->
        error

      {:error, :not_found} ->
        {:error, {:pull_request_not_found, "#{owner}/#{name}##{number}"}}

      {:error, _} ->
        {:error, {:pull_request_unreadable, "#{owner}/#{name}##{number}"}}
    end
  end

  defp carried_pull_request(_token, repo), do: {:ok, repo}

  defp sandbox_room(scope) do
    max = SalixWeb.L4ES.max_sandboxes(scope.tenant_id)

    if SalixStore.CodingSandboxes.live_count(scope.tenant_id, scope.group_id) < max,
      do: :ok,
      else: {:error, {:sandbox_limit, max}}
  end

  defp github_repo(token, %{"owner" => owner, "name" => name}) do
    case SalixWeb.CodingSandboxes.github().repo(token, owner, name) do
      {:ok, found} -> {:ok, found}
      {:error, :github_reauthorization_required} = error -> error
      {:error, _} -> {:error, {:repo_not_found, "#{owner}/#{name}"}}
    end
  end

  # Its station is Salix's own image's: it takes Tasks as Salix asks, once
  # the VM is ready and it has connected (`SalixWeb.StationTasks.invite/1`).
  defp cloud_vm_device_id(scope), do: SalixStore.RuntimeIds.cloud_vm_device_id(scope.group_id)

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
