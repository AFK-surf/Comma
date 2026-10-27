defmodule SalixAgent.SessionHistory.Worker do
  @moduledoc "Bounded index maintenance outside Session actors and their dependency pools."
  use SystemsRuntime.Server
  alias SalixAgent.InternalSession
  alias SalixAgent.SessionHistory.{Hot, Source, Document}
  alias SalixStore.{S3, Codec, Keys}
  @hints __MODULE__.Hints
  @slots 1024
  @visit_batches 32
  @visit_budget_ms 2_000

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  # Admission is non-blocking and bounded. Duplicate hints keep their original
  # queue position. Overflow is repaired by durable discovery, not chat retries.
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

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def take_hint do
    # This scan is bounded to 1,024 identities and runs only off the chat path.
    case Enum.min_by(pending_hints(), fn {_, queued_at} -> queued_at end, fn -> nil end) do
      {key, _} -> take_key(key)
      nil -> nil
    end
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
    {:ok, 0}
  end

  def handle_info(:tick, n) do
    safely("session_history_index", fn ->
      Enum.each(Hot.due(), fn [agent, session] ->
        if SalixAgent.SessionHistory.Scheduler.maintenance({agent, session}) == :ok do
          try do
            index(agent, session)
          after
            SalixAgent.SessionHistory.Scheduler.complete()
          end
        end
      end)
    end)

    if rem(n, 10) == 0, do: safely("session_history_discovery", &discover/0)
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :tick, 250)
    {:noreply, n + 1}
  end

  def index(agent, session) do
    with {:ok, state} <- Source.read(agent, session) do
      Hot.track(agent, session)
      recent_state(agent, session, state)

      # A session far behind catches up over several batches per visit, bounded
      # by count and time so other sessions still get their turn.
      deadline = SystemsClock.monotonic_time(:millisecond) + @visit_budget_ms
      repeat(@visit_batches, deadline, fn -> append_batch(agent, session, state) end)
      repeat(@visit_batches, deadline, fn -> transfer(agent, session) end)
    end
  end

  defp repeat(0, _deadline, _step), do: :ok

  defp repeat(left, deadline, step) do
    if match?({:ok, _}, step.()) and SystemsClock.monotonic_time(:millisecond) < deadline,
      do: repeat(left - 1, deadline, step),
      else: :ok
  end

  defp append_batch(agent, session, state) do
    position = Hot.state(agent, session)

    with {:ok, [_ | _] = records} <- Source.page(agent, state, position.indexed) do
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
      {:ok, []} -> :caught_up
      error -> error
    end
  end

  def recent(agent, session) do
    with {:ok, state} <- Source.read(agent, session) do
      Hot.track(agent, session)
      recent_state(agent, session, state)
    end
  end

  defp recent_state(agent, session, state) do
    with {:ok, tail} <-
           Source.page(
             agent,
             state,
             max(
               InternalSession.archived_through(state),
               InternalSession.get(state, :last_seq) - 32
             )
           ) do
      docs = tail |> Enum.reverse() |> Enum.flat_map(&Document.documents/1) |> Enum.take(128)
      Hot.recent(agent, session, docs)
    end
  end

  def transfer(agent, session) do
    with {:ok, {before, through, docs}} when through > before <-
           Hot.transfer_batch(agent, session),
         :ok <- confirm(agent, session, docs) do
      Hot.release(agent, session, before, through)
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

  def discover do
    cursor = Hot.discovery_cursor()
    opts = [max_keys: 50] ++ if(cursor, do: [start_after: cursor], else: [])

    with {:ok, %{objects: objects, next: next}} <- S3.list("agents/", opts) do
      Enum.each(objects, fn %{key: key} ->
        case Regex.run(
               ~r{\Aagents/([^/]+)/internal_runtime/sessions/[^/]+/state\.etf\.zst\z},
               key
             ) do
          [_, agent] ->
            with {:ok, %{body: body}} <- S3.get(key),
                 {:ok, state} <- InternalSession.load(Codec.snapshot_etf(body)),
                 session_id = InternalSession.session_id(state),
                 true <-
                   InternalSession.agent_id(state) == agent and
                     key == Keys.agent_internal_runtime_session(agent, session_id) do
              Hot.track(agent, session_id)
            else
              error -> throw({:discovery_failed, error})
            end

          _ ->
            :ok
        end
      end)

      Hot.advance_discovery(cursor, if(is_nil(next), do: nil, else: List.last(objects).key))
    end
  end

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
