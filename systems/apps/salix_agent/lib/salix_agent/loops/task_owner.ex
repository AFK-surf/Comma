defmodule SalixAgent.Loops.TaskOwner do
  @moduledoc """
  A Task Loop's port to its Task's Conversation owner.

  Wakes enter the Task's existing internal Message log, so ordinary
  Conversation delivery takes them to the same Worker Session. The Loop row
  holds every fact of the Loop; the Task only shows it.

  A Loop that ends keeps `task_settle_pending` on its row until the Task
  owner has taken the end (`loop_ended/2`): the Task gets the status that
  the end implies, at most once. The Reconciler retries a bounded page of
  them each sweep.

  No caller holds a Loop row lock while it calls this port.
  """
  require Logger
  alias SalixStore.Loops, as: Store

  @type loop :: %{required(String.t()) => term()}
  @callback loop_wake(loop(), map(), String.t()) ::
              {:ok, :created | :duplicate} | {:error, term()}
  @callback loop_ended(loop(), map()) :: :ok | {:error, term()}

  @doc "Deliver a wake of a Task Loop into its Task, or `:default` for any other Loop."
  def wake(record, payload, source_id) do
    if task_loop(record),
      do: invoke(record, :loop_wake, [payload, source_id]),
      else: :default
  end

  @doc "Tell the Task of an ended Loop now; the Reconciler retries a failure."
  def settle_soon(%{"task_settle_pending" => true} = record) do
    {:ok, _pid} = SystemsRuntime.Task.start(fn -> settle(record) end)
    :ok
  end

  def settle_soon(_record), do: :ok

  @doc "Hand the end of the Loop to its Task, then clear the pending flag."
  def settle(%{"task_settle_pending" => true} = record) do
    fact = Map.take(record, ["ended_reason", "ended_at", "run_count", "max_runs", "ends_at"])

    with :ok <- invoke(record, :loop_ended, [fact]) do
      case Store.update(record["id"], fn current ->
             if current["task_settle_pending"] == true and current["status"] == "ended",
               do: {:ok, Map.put(current, "task_settle_pending", false)},
               else: {:unchanged, current}
           end) do
        {:ok, _current} -> :ok
        {:error, :not_found} -> :ok
        error -> error
      end
    end
  end

  def settle(_record), do: :ok

  @doc "One recovery page per sweep; a failed row cannot starve later rows."
  def reconcile_settles(cursor) do
    case Store.unsettled_task_ends(cursor, 20) do
      {:ok, []} ->
        nil

      {:ok, rows} ->
        Enum.each(rows, &settle/1)
        List.last(rows)["id"]

      {:error, _} ->
        cursor
    end
  end

  defp invoke(record, callback, args) do
    with %{} = loop <- task_loop(record),
         module when not is_nil(module) <-
           SystemsRuntime.get_env(:salix_agent, :loop_task_owner_mod) do
      apply(module, callback, [loop | args])
    else
      nil -> if(task_loop(record), do: {:error, :task_owner_unavailable}, else: :ok)
    end
  rescue
    error ->
      Logger.warning("Task Loop owner call failed: #{inspect(error.__struct__)}")
      {:error, :task_owner_unavailable}
  catch
    _, _ -> {:error, :task_owner_unavailable}
  end

  defp task_loop(record) do
    case field(record, "task_conversation_id") do
      task when is_binary(task) ->
        %{
          "group_id" => field(record, "group_id"),
          "conversation_id" => task,
          "loop_id" => field(record, "id") || field(record, "loop_id"),
          "agent_id" => field(record, "agent_id"),
          "session_id" => field(record, "session_id")
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      _ ->
        nil
    end
  end

  defp field(record, key),
    do: Map.get(record, key) || Map.get(record, String.to_existing_atom(key))
end
