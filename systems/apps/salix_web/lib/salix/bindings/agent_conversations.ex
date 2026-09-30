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
        {:ok, agent} = SalixAgent.Control.get_record(agent_id)

        %{
          agent_id: agent_id,
          session_id: session_id,
          participant_id: participant["participant_id"],
          worker_role: participant["role_label"] || "worker",
          runtime_kind: SalixAgent.Control.runtime_kind(agent),
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
