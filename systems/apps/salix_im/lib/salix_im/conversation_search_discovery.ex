defmodule SalixIM.ConversationSearchDiscovery do
  @moduledoc """
  Permanent bounded discovery for the Task-search projection.

  One fleet-wide leased cursor visits one Group inventory key or at most 100
  canonical Conversation common prefixes per turn. Lexicographic `start_after`
  cursors are durable in PostgreSQL and move beyond the full key range of each
  processed common prefix. Each prefix is followed by one exact metadata read;
  Message/Participant child objects are never enumerated.

  Discovery starts only after the matching writer-fleet barrier. Missing
  metadata is never deletion authority. Invalid inventory/meta stops cursor
  advancement and emits an actionable diagnostic instead of silently skipping
  canonical data. The scanner/lease/barrier protocol maps to
  `tla/salix/ConversationTaskSearchDiscovery.tla`.
  """

  use GenServer

  require Logger

  alias SalixIM.ConversationSearchSource
  alias SalixStore.{ConversationSearch, Keys}

  @interval_ms 250
  @lease_ms 30_000
  @page_size 100
  @read_concurrency 8
  @read_timeout_ms 10_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  def drain_once(server \\ __MODULE__), do: GenServer.call(server, :drain_once, 60_000)

  @doc false
  def with_heartbeat_for_test(claim, lease_ms, fun) when is_function(fun, 1),
    do: with_heartbeat(claim, lease_ms, fun)

  @doc false
  def discover_claim_for_test(claim, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, @page_size)
    discover_claim(claim, page_size)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: positive(opts[:interval_ms], @interval_ms),
      lease_ms: positive(opts[:lease_ms], @lease_ms),
      holder: Atom.to_string(node()) <> ":" <> inspect(self())
    }

    schedule(0)
    {:ok, state}
  end

  @impl true
  def handle_call(:drain_once, _from, state), do: {:reply, discover_once(state), state}

  @impl true
  def handle_info(:tick, state) do
    _ = discover_once(state)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  defp discover_once(state) do
    case ConversationSearch.claim_discovery_cursor(state.holder, state.lease_ms) do
      {:ok, nil} -> :idle
      {:ok, claim} -> with_heartbeat(claim, state.lease_ms, &discover_claim(&1, @page_size))
      {:error, _reason} = error -> error
    end
  end

  defp discover_claim(%{current_group_id: nil} = claim, _page_size), do: discover_group(claim)
  defp discover_claim(claim, page_size), do: discover_conversation_page(claim, page_size)

  defp discover_group(claim) do
    case ConversationSearchSource.next_group(claim.group_start_after) do
      {:ok, nil} ->
        ConversationSearch.complete_discovery_cycle(claim)

      {:ok, %{group_id: group_id}} ->
        ConversationSearch.select_discovery_group(claim, group_id)

      {:error, reason} ->
        fail_page(claim, :group_inventory, reason)
    end
  end

  defp discover_conversation_page(claim, page_size) do
    case ConversationSearchSource.conversation_page(
           claim.current_group_id,
           claim.conversation_start_after,
           page_size
         ) do
      {:ok, %{sources: [], next_start_after: nil}} ->
        ConversationSearch.complete_discovery_group(
          claim,
          Keys.ctl_group(claim.current_group_id)
        )

      {:ok, %{sources: sources, next_start_after: next_start_after}} ->
        with {:ok, classified} <- classify_sources(sources),
             {:ok, operations} <- ConversationSearch.required_operations(classified),
             :ok <- enqueue_operations(operations) do
          ConversationSearch.advance_discovery_conversations(claim, next_start_after)
        else
          {:error, reason} -> fail_page(claim, :conversation_page, reason)
        end

      {:error, reason} ->
        fail_page(claim, :conversation_inventory, reason)
    end
  end

  defp classify_sources(sources) do
    sources
    |> Task.async_stream(
      &classify_source/1,
      ordered: true,
      max_concurrency: @read_concurrency,
      timeout: @read_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, classified}}, {:ok, acc} -> {:cont, {:ok, [classified | acc]}}
      {:ok, :missing}, {:ok, acc} -> {:cont, {:ok, acc}}
      {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
      {:exit, reason}, _acc -> {:halt, {:error, {:canonical_read_failed, reason}}}
    end)
    |> case do
      {:ok, classified} -> {:ok, Enum.reverse(classified)}
      {:error, _reason} = error -> error
    end
  end

  defp classify_source(source) do
    case ConversationSearchSource.classify_conversation(source) do
      {:ok, {:task, current}} ->
        {:ok, Map.put(current, :desired_task, true)}

      {:ok, {state, current}} when state in [:not_task, :deleted] ->
        {:ok, Map.put(current, :desired_task, false)}

      {:ok, :missing} ->
        Logger.warning("Conversation search discovery found a missing canonical metadata object",
          identity: inspect(source, limit: 20)
        )

        :missing

      {:error, reason} ->
        {:error, {:canonical_conversation_invalid, source.key, reason}}
    end
  end

  defp enqueue_operations(operations) do
    Enum.reduce_while(operations, :ok, fn operation, :ok ->
      result =
        case operation.operation do
          :rebuild ->
            ConversationSearch.enqueue_rebuild(operation.group_id, operation.conversation_id)

          :delete ->
            ConversationSearch.enqueue_delete(operation.group_id, operation.conversation_id)
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fail_page(claim, stage, reason) do
    emit_diagnostic(stage, claim, reason)
    _ = ConversationSearch.release_discovery_cursor(claim)
    {:error, reason}
  end

  defp emit_diagnostic(stage, identity, reason) do
    Logger.error("Conversation search discovery failed",
      stage: stage,
      identity: inspect(identity, limit: 20),
      reason: inspect(reason, limit: 20)
    )
  end

  defp with_heartbeat(claim, lease_ms, fun) do
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
        result = fun.(claim)
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
    case ConversationSearch.renew_discovery_claim(claim, lease_ms) do
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

  defp schedule(delay), do: Process.send_after(self(), :tick, delay)
  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
