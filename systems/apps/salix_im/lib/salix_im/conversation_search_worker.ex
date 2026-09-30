defmodule SalixIM.ConversationSearchWorker do
  @moduledoc """
  Single bounded search-projection worker per SalixIM application instance.

  Concurrent Pods partition work through `FOR UPDATE SKIP LOCKED`. Each tick
  claims at most one Conversation job. A rebuild reads at most 64 one-MiB
  source segments, retains about three MiB of projected working state, and
  atomically writes at most 256 KiB of Message text plus a 16-KiB title.

  A fenced heartbeat renews the durable claim during slow S3 reads. Final
  projection writes also verify the same unexpired token, so a stale claimant
  cannot apply or settle after another worker takes the lease. The worker
  claim/renew/apply/settle lifecycle maps to
  `tla/salix/ConversationTaskSearchQueue.tla`.
  """

  use GenServer

  alias SalixIM.ConversationSearchProjection
  alias SalixStore.ConversationSearch

  @default_interval_ms 250
  @default_lease_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  def drain_once(server \\ __MODULE__), do: GenServer.call(server, :drain_once, 60_000)

  @doc false
  def with_heartbeat_for_test(claim, lease_ms, fun) when is_function(fun, 0),
    do: with_heartbeat(claim, lease_ms, fun)

  @impl true
  def init(opts) do
    state = %{
      interval_ms: positive(opts[:interval_ms], @default_interval_ms),
      lease_ms: positive(opts[:lease_ms], @default_lease_ms),
      holder: Atom.to_string(node()) <> ":" <> inspect(self())
    }

    schedule_tick(0)
    {:ok, state}
  end

  @impl true
  def handle_call(:drain_once, _from, state), do: {:reply, drain(state), state}

  @impl true
  def handle_info(:tick, state) do
    result = drain(state)
    schedule_tick(if(match?({:processed, 1}, result), do: 0, else: state.interval_ms))
    {:noreply, state}
  end

  defp drain(state) do
    case ConversationSearch.claim_one(state.holder, state.lease_ms) do
      {:ok, nil} ->
        :idle

      {:ok, claim} ->
        result = with_heartbeat(claim, state.lease_ms)
        _ = settle(claim, result)
        {:processed, 1}

      {:error, _reason} = error ->
        error
    end
  end

  defp settle(claim, :ok), do: ConversationSearch.complete(claim)

  defp settle(claim, {:error, reason}), do: ConversationSearch.retry(claim, reason)
  defp settle(claim, other), do: ConversationSearch.retry(claim, {:unexpected_result, other})

  defp schedule_tick(delay), do: Process.send_after(self(), :tick, delay)

  defp with_heartbeat(claim, lease_ms, fun \\ nil) do
    parent = self()
    reference = make_ref()

    {:ok, heartbeat} =
      Task.start(fn ->
        owner_ref = Process.monitor(parent)

        heartbeat(
          parent,
          owner_ref,
          reference,
          claim,
          lease_ms,
          max(div(lease_ms, 3), 10),
          :initial
        )
      end)

    receive do
      {^reference, :renewed} ->
        result = run_claim(fun, claim)
        send(heartbeat, {reference, :stop})

        receive do
          {^reference, :stopped} -> result
          {^reference, {:lost, reason}} -> {:error, {:claim_heartbeat_lost, reason}}
        after
          lease_ms -> {:error, :claim_heartbeat_stop_timeout}
        end

      {^reference, {:lost, reason}} ->
        {:error, {:claim_heartbeat_lost, reason}}
    after
      lease_ms -> {:error, :claim_heartbeat_start_timeout}
    end
  end

  defp heartbeat(parent, owner_ref, reference, claim, lease_ms, interval_ms, phase) do
    case ConversationSearch.renew_job_claim(claim, lease_ms) do
      :ok ->
        if phase == :initial, do: send(parent, {reference, :renewed})

        receive do
          {^reference, :stop} -> send(parent, {reference, :stopped})
          {:DOWN, ^owner_ref, :process, ^parent, _reason} -> :ok
        after
          interval_ms ->
            heartbeat(parent, owner_ref, reference, claim, lease_ms, interval_ms, :running)
        end

      {:error, reason} ->
        send(parent, {reference, {:lost, reason}})
    end
  end

  defp run_claim(nil, claim), do: ConversationSearchProjection.process_claim(claim)
  defp run_claim(fun, _claim) when is_function(fun, 0), do: fun.()

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
