defmodule SalixIM.RouterWaitProbe do
  @moduledoc """
  `SalixAgent.WaitExtension` probe: is a Worker on one of this agent's active
  Tasks still working?

  Reads the group's Task conversations created by the agent whose `status` is
  `active`, then the Worker participant's session activity. Any read failure
  answers `false`, so the wait times out exactly as it would without the probe.
  """

  @behaviour SalixAgent.WaitExtension

  alias SalixIM.{ConversationParticipantActivity, Conversations}

  @list_limit 50
  @max_tasks_checked 10

  @impl true
  def delegates_busy?(agent_id, _session_id, _wait) when is_binary(agent_id) do
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)

    with {:ok, %{"data" => records}} <-
           Conversations.list_group_conversations(group_id,
             kind: "agent_task",
             limit: @list_limit
           ) do
      records
      |> Enum.filter(&own_active_task?(&1, agent_id))
      |> recent_first()
      |> Enum.take(@max_tasks_checked)
      |> Enum.any?(&worker_busy?(group_id, &1))
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def delegates_busy?(_agent_id, _session_id, _wait), do: false

  # The Task a Router is waiting on is the one that moved last. The listing
  # comes back oldest first, and a Router keeps old scheduled Tasks `active`
  # for weeks, so without this the newest Tasks fall outside the checked
  # window and the probe never sees a working Worker (staging 2026-09-15:
  # 16 active Tasks, the awaited one 15th).
  @doc false
  def recent_first(records) when is_list(records),
    do: Enum.sort_by(records, &updated_at/1, :desc)

  defp updated_at(record) do
    case record["updated_at"] do
      ms when is_integer(ms) -> ms
      _ -> 0
    end
  end

  @doc false
  def own_active_task?(record, agent_id) when is_map(record) do
    record["status"] == "active" and record["created_by_agent_id"] == agent_id and
      is_binary(record["task_worker_agent_id"]) and record["task_worker_agent_id"] != ""
  end

  def own_active_task?(_record, _agent_id), do: false

  defp worker_busy?(group_id, %{"conversation_id" => conversation_id} = record) do
    worker_agent_id = record["task_worker_agent_id"]

    with {:ok, %{"participants" => participants}} <-
           Conversations.list_group_conversation_participants(group_id, conversation_id),
         %{} = participant <- Enum.find(participants, &(&1["agent_id"] == worker_agent_id)),
         {:ok, status} <-
           ConversationParticipantActivity.read(
             group_id,
             conversation_id,
             participant["participant_id"],
             participant
           ) do
      busy_activity?(status["activity"])
    else
      _ -> false
    end
  end

  defp worker_busy?(_group_id, _record), do: false

  @doc false
  def busy_activity?(%{"state" => "active"}), do: true
  def busy_activity?(_activity), do: false
end
