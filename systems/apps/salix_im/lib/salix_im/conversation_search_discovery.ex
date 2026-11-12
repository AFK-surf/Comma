defmodule SalixIM.ConversationSearchDiscovery do
  @moduledoc "Run the existing release backfill over bounded canonical PostgreSQL pages."
  use SystemsRuntime.Server
  alias SalixStore.ConversationSearch
  @interval_ms 250

  def start_link(opts \\ []),
    do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  def drain_once(server \\ __MODULE__),
    do: SystemsRuntime.Server.call(server, :drain_once, 60_000)

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      done?: false,
      timer: nil
    }

    {:ok, schedule(state, 0)}
  end

  @impl true
  def handle_call(:drain_once, _from, state) do
    {result, state} = drain(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_result, state} = drain(%{state | timer: nil})
    {:noreply, if(state.done?, do: state, else: schedule(state, state.interval_ms))}
  end

  defp drain(%{done?: true} = state), do: {:idle, state}

  defp drain(state) do
    with {:ok, generation} <- ConversationSearch.writer_generation(),
         {:ok, run} <- ConversationSearch.backfill_state(generation) do
      cond do
        not is_nil(run.sealed_at) or not is_nil(run.retired_at) ->
          {:idle, done(state)}

        is_nil(run.writer_barrier_at) ->
          {:idle, state}

        is_nil(run.scan_completed_at) ->
          case ConversationSearch.scan_page(generation) do
            {:ok, %{complete: true} = result} -> seal(generation, result, state)
            result -> {result, state}
          end

        true ->
          seal(generation, :draining, state)
      end
    else
      error -> {error, state}
    end
  end

  defp seal(generation, result, state) do
    case ConversationSearch.seal_backfill(generation) do
      :ok -> {result, done(state)}
      {:error, :not_ready} -> {result, state}
      error -> {error, state}
    end
  end

  defp done(%{timer: nil} = state), do: %{state | done?: true}

  defp done(state) do
    SystemsClock.cancel_timer(state.timer)
    %{state | done?: true, timer: nil}
  end

  defp schedule(state, delay) do
    %{state | timer: SystemsClock.send_after(SystemsRuntime.Proc.self(), :tick, delay)}
  end
end
