defmodule SalixAgent.RouterRequestMonitor do
  @moduledoc """
  Best-effort node-local observation of admitted Router requests, outside the
  Router mailbox. Identities are private cache keys, never telemetry labels.
  This is not a delivery ledger: node/observer restarts lose observations.
  No business protocol or recovery transition depends on this cache.
  """
  use GenServer

  @max_routers 1024
  @max_requests 1000
  @threshold_ms 300_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def register(agent_id, owner), do: emit({:register, agent_id, owner})
  def clear_session(agent_id, session_id), do: emit({:clear, {agent_id, session_id}})

  def started(agent_id, session_id, source_ids),
    do: emit({:started, {agent_id, session_id}, source_ids})

  def enqueued(agent_id, session_id, events) do
    # Strip all content before crossing the observational process boundary.
    ids =
      for %{
            "type" => "queue_append",
            "kind" => "user_message",
            "payload" => %{"role" => "user", "source_message_id" => id}
          } = event <- events,
          event["wake"] != false,
          is_binary(id) and id != "",
          do: id

    if ids != [], do: emit({:enqueued, {agent_id, session_id}, ids})
    :ok
  rescue
    _ -> :ok
  end

  @doc false
  def sample, do: GenServer.call(__MODULE__, :sample)

  defp emit(message) do
    GenServer.cast(__MODULE__, message)
    :ok
  catch
    _, _ -> :ok
  end

  @impl true
  def init(opts) do
    state = %{
      owners: %{},
      queues: %{},
      dropped: 0,
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      interval: Keyword.get(opts, :interval, 15_000)
    }

    Process.send_after(self(), :sample, state.interval)
    {:ok, state}
  end

  @impl true
  def handle_cast({:register, id, pid}, state) when is_pid(pid) do
    case state.owners[id] do
      {^pid, _ref} ->
        {:noreply, state}

      previous when previous != nil or map_size(state.owners) < @max_routers ->
        if previous, do: Process.demonitor(elem(previous, 1), [:flush])
        state = remove_agent(state, id)
        {:noreply, %{state | owners: Map.put(state.owners, id, {pid, Process.monitor(pid)})}}

      _ ->
        {:noreply, %{state | dropped: state.dropped + 1}}
    end
  end

  def handle_cast({:enqueued, {agent, _session} = key, ids}, state) do
    if Map.has_key?(state.owners, agent) and
         (Map.has_key?(state.queues, key) or map_size(state.queues) < @max_routers) do
      now = state.clock.()
      queue = Map.get(state.queues, key, %{pending: %{}, last_start: now})

      {pending, dropped} =
        Enum.reduce(ids, {queue.pending, 0}, fn id, {pending, dropped} ->
          cond do
            Map.has_key?(pending, id) -> {pending, dropped}
            map_size(pending) < @max_requests -> {Map.put(pending, id, now), dropped}
            true -> {pending, dropped + 1}
          end
        end)

      {:noreply,
       %{
         state
         | queues: Map.put(state.queues, key, %{queue | pending: pending}),
           dropped: state.dropped + dropped
       }}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:started, key, ids}, state) do
    case state.queues[key] do
      nil ->
        {:noreply, state}

      queue ->
        pending = Map.drop(queue.pending, ids)

        cond do
          map_size(pending) == 0 ->
            {:noreply, %{state | queues: Map.delete(state.queues, key)}}

          map_size(pending) < map_size(queue.pending) ->
            {:noreply,
             %{
               state
               | queues:
                   Map.put(state.queues, key, %{
                     queue
                     | pending: pending,
                       last_start: state.clock.()
                   })
             }}

          true ->
            {:noreply, state}
        end
    end
  end

  def handle_cast({:clear, key}, state),
    do: {:noreply, %{state | queues: Map.delete(state.queues, key)}}

  @impl true
  def handle_call(:sample, _from, state), do: {:reply, publish(state), state}

  @impl true
  def handle_info(:sample, state) do
    publish(state)
    Process.send_after(self(), :sample, state.interval)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    owners = Enum.filter(state.owners, fn {_id, {_pid, owner_ref}} -> owner_ref == ref end)
    {:noreply, Enum.reduce(owners, state, fn {id, _}, acc -> remove_agent(acc, id) end)}
  end

  defp remove_agent(state, id) do
    %{
      state
      | owners: Map.delete(state.owners, id),
        queues: Map.reject(state.queues, fn {{agent, _}, _} -> agent == id end)
    }
  end

  defp publish(state) do
    now = state.clock.()

    stalled =
      Enum.count(state.queues, fn {_key, queue} ->
        oldest = queue.pending |> Map.values() |> Enum.min(fn -> now end)

        map_size(queue.pending) > 0 and now - oldest > @threshold_ms and
          now - queue.last_start >= @threshold_ms
      end)

    sample = %{
      stalled: stalled,
      pending: map_size(state.queues),
      dropped: state.dropped,
      observed_at: System.system_time(:second)
    }

    try do
      :telemetry.execute([:salix, :router_requests, :sample], sample, %{})
    catch
      _, _ -> :ok
    end

    sample
  end
end
