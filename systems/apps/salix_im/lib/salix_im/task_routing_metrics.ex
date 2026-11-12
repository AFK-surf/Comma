defmodule SalixIM.TaskRoutingMetrics do
  @moduledoc "Bounded read projection of committed Task routing decisions."
  alias SalixIM.Conversations
  alias SalixStore.Repo

  # One indexed Task page and one batch participant read. No Actor or Session reads.
  @limit 1_000
  @participant_limit 2_000
  def tasks(group_id, since_ms) do
    with {:ok, page} <-
           Conversations.list_group_conversations(group_id,
             kind: "agent_task",
             limit: @limit,
             # Created in the period implies active since then, so more pages
             # mean Tasks of the period may have been cut off.
             active_since: since_ms
           ) do
      tasks =
        Enum.filter(page["data"], fn task ->
          (task["created_at"] || 0) >= since_ms and
            is_map(get_in(task, ["metadata", "task_model_selection"]))
        end)

      legacy = Enum.filter(tasks, &is_nil(evidence(&1)["session_id"]))

      with {:ok, workers, workers_truncated} <- legacy_workers(group_id, legacy) do
        {:ok,
         %{
           tasks: Enum.map(tasks, &project(&1, workers)),
           truncated: page["has_more"],
           workers_truncated: workers_truncated,
           limit: @limit
         }}
      end
    end
  end

  defp legacy_workers(_group, []), do: {:ok, %{}, false}

  defp legacy_workers(group, tasks) do
    # Historical decisions did not retain their initial Session. Only unchanged
    # Worker participants can establish that link. A replacement stays unknown.
    # The role lives only in the payload, so every agent participant takes a row.
    case Repo.query(
           """
           SELECT conversation_id, payload FROM salix_conversation_participants
           WHERE group_id=$1 AND conversation_id=ANY($2::text[])
             AND actor_type='agent' AND session_id IS NOT NULL AND deleted_at IS NULL
           ORDER BY conversation_id, participant_id LIMIT #{@participant_limit + 1}
           """,
           [group, Enum.map(tasks, & &1["conversation_id"])]
         ) do
      {:ok, %{rows: rows}} ->
        truncated = length(rows) > @participant_limit
        # The last Task of a cut read may be missing participants, so it stays unknown.
        rows = if truncated, do: drop_last_conversation(rows), else: rows

        workers =
          rows
          |> Enum.map(fn [cid, body] -> {cid, :erlang.binary_to_term(body, [:safe])} end)
          |> Enum.filter(fn {_cid, p} -> p["role_label"] == "worker" end)
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

        {:ok, workers, truncated}

      _ ->
        {:error, :unavailable}
    end
  end

  defp drop_last_conversation(rows) do
    [last, _body] = List.last(rows)
    Enum.reject(rows, fn [cid, _body] -> cid == last end)
  end

  defp project(task, workers) do
    selection = evidence(task)
    session = selection["session_id"] || selection["learning_session_id"]

    session =
      session ||
        case workers[task["conversation_id"]] do
          [worker] ->
            if worker["created_at"] == worker["updated_at"] and
                 get_in(worker, ["payload", "session_model"]) == selection["selected_model"],
               do: get_in(worker, ["payload", "session_id"])

          _ ->
            nil
        end

    %{
      id: task["conversation_id"],
      created_at: task["created_at"],
      # Archiving is housekeeping: a Task keeps the outcome it was archived with.
      status:
        if(task["status"] == "archived", do: task["archived_from_status"], else: task["status"]),
      session_id: session,
      selection: selection
    }
  end

  defp evidence(task), do: get_in(task, ["metadata", "task_model_selection"])
end
