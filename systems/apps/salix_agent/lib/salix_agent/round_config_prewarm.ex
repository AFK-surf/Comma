defmodule SalixAgent.RoundConfigPrewarm do
  @moduledoc """
  Round configuration built ahead of the session actor that will need it.

  A delivery into a cold agent knows the agent as soon as the facade has
  classified it, about a hundred milliseconds before the session actor exists
  and can start its own build. The facade starts the build here; the actor's
  prewarm then adopts the result (or waits for the build in flight) instead of
  reading the catalog, skills, plugins and templates a second time.

  One build per agent is in flight at a time. A result is taken once and is
  only adopted while fresh; a committed skill or configuration event discards
  it, the same way it invalidates the actor's own cache.
  """

  use GenServer

  @table __MODULE__
  @fresh_ms 5_000
  @poll_ms 5

  # The table needs an owner that outlives the delivery tasks that fill it.
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    _ = table()
    {:ok, %{}}
  end

  @doc "Starts a build for the agent unless one is in flight or fresh."
  @spec start(String.t()) :: :ok
  def start(agent_id) when is_binary(agent_id) do
    now = now_ms()

    case lookup(agent_id) do
      {:building, _ref, started} when now - started < @fresh_ms -> :ok
      {:ready, _result, at} when now - at < @fresh_ms -> :ok
      _ -> spawn_build(agent_id, now)
    end
  end

  @doc """
  Adopts a fresh build for the agent, waits for one in flight, or runs
  `build` itself. The result is taken once.
  """
  @spec take(String.t(), (-> result), non_neg_integer()) :: result when result: term()
  def take(agent_id, build, timeout_ms \\ 10_000) when is_function(build, 0) do
    deadline = now_ms() + timeout_ms
    await(agent_id, build, deadline)
  end

  @doc "Forgets any build for the agent (a configuration write landed)."
  @spec discard(String.t()) :: :ok
  def discard(agent_id) when is_binary(agent_id) do
    :ets.delete(table(), agent_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp await(agent_id, build, deadline) do
    now = now_ms()

    case lookup(agent_id) do
      {:ready, result, at} when now - at < @fresh_ms ->
        :ets.delete(table(), agent_id)
        result

      {:building, _ref, started} when now - started < @fresh_ms and now < deadline ->
        Process.sleep(@poll_ms)
        await(agent_id, build, deadline)

      _stale_absent_or_late ->
        build.()
    end
  end

  defp spawn_build(agent_id, now) do
    ref = make_ref()

    if :ets.insert_new(table(), {agent_id, {:building, ref, now}}) do
      read_scope = SalixStore.ReadScope.capture() || %{}
      context = SystemsObservability.Context.capture()

      case Task.Supervisor.start_child(SalixAgent.TaskSup, fn ->
             SystemsObservability.Context.run(context, fn ->
               result =
                 SalixStore.ReadScope.run(read_scope, fn ->
                   case SalixAgent.RoundConfig.build_round_snapshot(agent_id, %{}) do
                     {:ok, snapshot} when is_map(snapshot) ->
                       # What the build read, for the actor that adopts it.
                       {:ok,
                        snapshot
                        |> Map.put(:read_scope, SalixStore.ReadScope.capture())
                        |> Map.put(:built_at_ms, now_ms())}

                     other ->
                       other
                   end
                 end)

               # Only the build that claimed the slot publishes; a slot the
               # actor already took or discarded stays empty.
               case lookup(agent_id) do
                 {:building, ^ref, _} ->
                   :ets.insert(table(), {agent_id, {:ready, result, now_ms()}})

                 _ ->
                   :ok
               end
             end)
           end) do
        {:ok, _pid} -> :ok
        {:error, _reason} -> discard(agent_id)
      end
    else
      # Another caller claimed the slot at the same instant.
      :ok
    end

    :ok
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end

  defp lookup(agent_id) do
    case :ets.lookup(table(), agent_id) do
      [{^agent_id, entry}] -> entry
      [] -> :absent
    end
  rescue
    ArgumentError -> :absent
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      _ ->
        @table
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
