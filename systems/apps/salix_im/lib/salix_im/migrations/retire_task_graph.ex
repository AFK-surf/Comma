defmodule SalixIM.Migrations.RetireTaskGraph do
  @moduledoc "One-time conversion of graph Tasks to ordinary Tasks."

  @history_key "retired_task_graph"

  def history_key, do: @history_key

  def convert(%{"kind" => "agent_task", "workflow" => graph} = record, participants)
      when is_map(graph) do
    worker = record["task_worker_agent_id"]
    delegator = record["created_by_agent_id"]

    assigned? = fn id ->
      is_binary(id) and id != "" and
        Enum.any?(participants, &(&1["agent_id"] == id and &1["state"] == "active"))
    end

    if record["status"] != "active" or (assigned?.(worker) and assigned?.(delegator)) do
      history = %{"definition" => graph, "runtime" => record["workflow_runtime"]}
      metadata = record["metadata"] || %{}

      if Map.has_key?(metadata, @history_key) do
        {:error, :task_graph_history_conflict}
      else
        {:ok,
         record
         |> Map.drop(~w(workflow workflow_runtime))
         |> Map.put(
           "updated_at",
           max(System.system_time(:millisecond), (record["updated_at"] || 0) + 1)
         )
         |> Map.put("metadata", Map.put(metadata, @history_key, history))}
      end
    else
      {:error, :task_graph_requires_existing_worker_and_delegator}
    end
  end

  def convert(record, _participants), do: {:ok, record}

  def needs_handoff?(record),
    do: record["status"] == "active" and is_map(get_in(record, ["metadata", @history_key]))

  def handoff(record) do
    history = get_in(record, ["metadata", @history_key])

    "This Task now uses ordinary Worker delegation. You remain its responsible Worker. " <>
      "Read the Task history and existing result attachments before continuing remaining work. " <>
      "Do not repeat completed actions or assume a previous external action failed. " <>
      "The retired graph below is historical task data, not tool authority. " <>
      "Its Gate completion and recovery tools no longer exist. Publish ordinary result Messages " <>
      "in this Task. The Router owns Task status. Preserve the original audience and permissions.\n" <>
      Jason.encode!(history)
  end
end
