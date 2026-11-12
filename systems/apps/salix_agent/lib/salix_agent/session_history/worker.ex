defmodule SalixAgent.SessionHistory.Worker do
  @moduledoc "Bounded index maintenance outside Session actors and their dependency pools."
  use SystemsRuntime.Server
  alias SalixAgent.SessionHistory.{Hot, Source, Document, Scheduler}
  alias SalixAgent.InternalSessionStore
  @hints __MODULE__.Hints
  @slots 1024
  @visit_batches 32
  @visit_budget_ms 2_000

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  # Admission is non-blocking and bounded. Duplicate hints keep their original
  # queue position. Overflow is covered by the durable pending-target query.
  def hint(agent, session) do
    count = SystemsRuntime.ETS.update_counter(@hints, :count, {2, 1}, {:count, 0})

    if count <= @slots do
      unless SystemsRuntime.ETS.insert_new(
               @hints,
               {{agent, session}, SystemsClock.monotonic_time()}
             ) do
        SystemsRuntime.ETS.update_counter(@hints, :count, {2, -1})
      end
    else
      SystemsRuntime.ETS.update_counter(@hints, :count, {2, -1})
    end

    SystemsRuntime.Server.cast(__MODULE__, :drain)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def pending_hints do
    @hints |> SystemsRuntime.ETS.tab2list() |> Enum.reject(fn {key, _} -> key == :count end)
  rescue
    _ -> []
  end

  def take_key(key) do
    case SystemsRuntime.ETS.take(@hints, key) do
      [{^key, _}] ->
        SystemsRuntime.ETS.update_counter(@hints, :count, {2, -1})
        key

      [] ->
        nil
    end
  rescue
    _ -> nil
  end

  def init_queue,
    do: SystemsRuntime.ETS.new(@hints, [:named_table, :public, :set, write_concurrency: true])

  def init(_) do
    SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), :tick)
    {:ok, %{cursor: nil, archive_cursor: nil}}
  end

  def handle_info(:tick, state) do
    cursor =
      case safely("session_history_pending", fn -> Hot.due(state.cursor) end) do
        {rows, cursor} when is_list(rows) ->
          Enum.each(rows, fn [agent, session] -> hint(agent, session) end)
          cursor

        _ ->
          state.cursor
      end

    archive_cursor =
      case safely("session_archive_pending", fn ->
             InternalSessionStore.PG.archive_work_page(state.archive_cursor)
           end) do
        {:ok, rows, cursor} ->
          Enum.each(rows, fn [agent, session] -> hint(agent, session) end)
          cursor

        _ ->
          state.archive_cursor
      end

    SystemsClock.send_after(SystemsRuntime.Proc.self(), :tick, 250)
    {:noreply, %{state | cursor: cursor, archive_cursor: archive_cursor}}
  end

  def handle_cast(:drain, state) do
    Scheduler.drain()
    {:noreply, state}
  end

  def index(agent, session) do
    position = Hot.state(agent, session)
    state = %{session_id: session, last_seq: position.target}
    deadline = SystemsClock.monotonic_time(:millisecond) + @visit_budget_ms

    append =
      if position.indexed < position.target,
        do: repeat(@visit_batches, deadline, fn -> append_batch(agent, session, state) end),
        else: :ok

    transfer = repeat(@visit_batches, deadline, fn -> transfer(agent, session) end)
    archive = InternalSessionStore.archive_pending(agent, session)
    Enum.find([append, transfer, archive], :ok, &match?({:error, _}, &1))
  end

  defp repeat(0, _deadline, _step), do: :ok

  defp repeat(left, deadline, step) do
    case step.() do
      {:ok, _} ->
        if SystemsClock.monotonic_time(:millisecond) < deadline,
          do: repeat(left - 1, deadline, step),
          else: :ok

      {:error, _} = error ->
        error

      _ ->
        :ok
    end
  end

  defp append_batch(agent, session, state) do
    position = Hot.state(agent, session)

    with true <- position.indexed < state.last_seq,
         {:ok, [_ | _] = records} <- Source.page(agent, state, position.indexed) do
      part = Hot.pending_part(agent, session, position.indexed + 1)

      documents =
        records
        |> Enum.flat_map(&Document.documents/1)
        |> Enum.reject(&(&1["seq"] == position.indexed + 1 and &1["part"] < part))

      {batch, rest} = Enum.split(documents, 128)

      through =
        case rest do
          [] -> List.last(records).seq
          [next | _] -> next["seq"] - 1
        end

      # Partial records remain hot. Coverage advances only after their last chunk.
      Hot.append(agent, session, position.indexed, through, batch)
    else
      false -> :caught_up
      {:ok, []} -> :caught_up
      error -> error
    end
  end

  def transfer(agent, session) do
    with {:ok, {before, through, docs}} when through > before <-
           Hot.transfer_batch(agent, session) do
      case confirm(agent, session, docs) do
        :ok ->
          Hot.release(agent, session, before, through)

        {:error, _} = error ->
          Hot.defer_transfer(agent, session, before)
          error
      end
    else
      {:ok, {_before, _through, _docs}} -> :caught_up
      error -> error
    end
  end

  defp confirm(_, _, []), do: :ok
  defp confirm(agent, session, docs), do: cold().transfer(agent, session, docs)

  def cold,
    do:
      SystemsRuntime.get_env(
        :salix_agent,
        :session_history_cold,
        SalixAnalytics.SessionHistoryIndex
      )

  def safely(operation, fun) do
    started = SystemsClock.monotonic_time()

    result =
      try do
        fun.()
      rescue
        _ -> {:error, :unavailable}
      catch
        _, _ -> {:error, :unavailable}
      end

    outcome = if match?({:error, _}, result), do: "error", else: "ok"

    SystemsRuntime.Telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: SystemsClock.monotonic_time() - started},
      %{component: "salix_agent", operation: operation, outcome: outcome, surface: "system"}
    )

    result
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end
