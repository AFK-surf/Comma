defmodule SalixIM.Triage.ReceiptRecovery do
  @moduledoc """
  Bounded global recovery ring for durable typed Slack Triage receipts.

  The typed provider receipt remains the inbox truth. This process only
  discovers bounded pages and feeds current, credential-free authority plus
  each exact receipt through `SalixIM.Triage.Runtime.accept_current/3`.

  Modeled in `tla/salix/TriageReceiptRecovery.tla`.
  """

  use GenServer

  alias SalixIM.Triage.Runtime
  alias SalixIM.{ProviderConnects, ProviderReceipts}
  alias SalixStore.{Lease, ULID}

  @page_limit 25
  @batch_limit 5
  @catch_up_ms 100
  @full_ring_idle_ms 5_000
  @held_poll_ms 5_000
  @failure_backoff_ms 250
  @max_backoff_ms 30_000

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    allowed = [
      :batch_limit,
      :failure_backoff_ms,
      :full_ring_idle_ms,
      :held_poll_ms,
      :id,
      :interval_ms,
      :lease_key,
      :lease_ttl_ms,
      :max_backoff_ms,
      :name,
      :page_limit,
      :runtime
    ]

    state = %{
      runtime: Keyword.get(opts, :runtime),
      lease_key: Keyword.get(opts, :lease_key),
      lease_ttl_ms: Keyword.get(opts, :lease_ttl_ms, 30_000),
      holder: "#{node()}:#{ULID.generate()}",
      lease: nil,
      phase: :list,
      cursor: nil,
      page: nil,
      resolution: nil,
      authorities: %{},
      interval_ms: Keyword.get(opts, :interval_ms, @catch_up_ms),
      page_limit: Keyword.get(opts, :page_limit, @page_limit),
      batch_limit: Keyword.get(opts, :batch_limit, @batch_limit),
      full_ring_idle_ms: Keyword.get(opts, :full_ring_idle_ms, @full_ring_idle_ms),
      held_poll_ms: Keyword.get(opts, :held_poll_ms, @held_poll_ms),
      failure_backoff_ms: Keyword.get(opts, :failure_backoff_ms, @failure_backoff_ms),
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, @max_backoff_ms),
      current_backoff_ms: Keyword.get(opts, :failure_backoff_ms, @failure_backoff_ms)
    }

    if Enum.any?(Keyword.keys(opts), &(&1 not in allowed)) or not valid_state?(state) do
      {:stop, :invalid_triage_receipt_recovery_options}
    else
      send(self(), :tick)
      {:ok, state}
    end
  end

  # Read-only introspection for the Triage Workbench read model. It projects
  # current in-memory ring position only: it holds no timer, takes no lease
  # decision, and never mutates state, so a workbench read can never perturb
  # the ring.
  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       phase: state.phase,
       cursor: state.cursor,
       holder: state.holder,
       lease_held: not is_nil(state.lease),
       page_limit: state.page_limit,
       batch_limit: state.batch_limit,
       backoff_ms: state.current_backoff_ms,
       pending_receipts: pending_receipts(state.page)
     }, state}
  end

  @impl true
  def handle_info(:tick, state) do
    case renew_or_acquire(state) do
      {:ok, state} -> {:noreply, run_phase(state)}
      {:held, state} -> {:noreply, schedule(state, state.held_poll_ms)}
      {:error, state} -> {:noreply, schedule_failure(state)}
    end
  end

  defp pending_receipts(%{receipts: receipts}) when is_list(receipts), do: length(receipts)
  defp pending_receipts(_page), do: 0

  defp run_phase(%{phase: :list} = state) do
    case ProviderReceipts.list_slack_triage_page(:all, state.cursor, state.page_limit) do
      {:ok, page} ->
        state
        |> Map.put(:page, page)
        |> Map.put(:phase, :resolve)
        |> reset_backoff()
        |> schedule(state.interval_ms)

      {:error, _reason} ->
        schedule_failure(state)
    end
  end

  defp run_phase(%{phase: :resolve, page: page} = state) do
    resolution = state.resolution || empty_resolution()

    case ProviderConnects.resolve_slack_triage_recovery_authority_refs(
           page.authority_refs,
           resolution.cursor
         ) do
      {:ok, authority_page} ->
        resolution = merge_resolution(resolution, authority_page)

        if authority_page.scan_complete do
          state
          |> Map.put(:authorities, resolution.authorities)
          |> Map.put(:resolution, nil)
          |> Map.put(:phase, :admit)
          |> reset_backoff()
          |> schedule(state.interval_ms)
        else
          state
          |> Map.put(:resolution, %{resolution | cursor: authority_page.next_cursor})
          |> reset_backoff()
          |> schedule(state.interval_ms)
        end

      {:error, _reason} ->
        schedule_failure(state)
    end
  end

  defp run_phase(%{phase: :admit, page: page} = state) do
    {batch, remaining} = Enum.split(page.receipts, state.batch_limit)

    Enum.each(batch, fn receipt ->
      authority_ref =
        {receipt["connect_id"], get_in(receipt, ["triage_event", "bucket", "channel_id"])}

      case Map.get(state.authorities, authority_ref) do
        authority when is_map(authority) -> accept_current(state.runtime, authority, receipt)
        _inactive_or_unavailable -> :ok
      end
    end)

    if remaining == [] do
      delay = if page.scan_complete, do: state.full_ring_idle_ms, else: state.interval_ms

      state
      |> Map.put(:cursor, page.next_cursor)
      |> Map.put(:page, nil)
      |> Map.put(:resolution, nil)
      |> Map.put(:authorities, %{})
      |> Map.put(:phase, :list)
      |> reset_backoff()
      |> schedule(delay)
    else
      state
      |> put_in([:page, :receipts], remaining)
      |> reset_backoff()
      |> schedule(state.interval_ms)
    end
  end

  defp accept_current(runtime, authority, receipt) do
    ProviderReceipts.observe_slack_triage_receipt(authority, receipt)

    case Runtime.accept_current(runtime, authority, receipt) do
      {:ok, status} when status in [:accepted, :duplicate] -> :ok
      _closed_failure -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp renew_or_acquire(%{lease: nil} = state) do
    case Lease.acquire(state.lease_key, state.holder, ttl_ms: state.lease_ttl_ms) do
      {:ok, lease} -> {:ok, %{state | lease: lease}}
      {:error, {:held_by, _holder, _until}} -> {:held, state}
      {:error, _reason} -> {:error, state}
    end
  end

  defp renew_or_acquire(%{lease: lease} = state) do
    case Lease.renew(lease, ttl_ms: state.lease_ttl_ms) do
      {:ok, renewed} -> {:ok, %{state | lease: renewed}}
      {:error, :lost} -> {:held, %{state | lease: nil}}
      {:error, _reason} -> {:error, %{state | lease: nil}}
    end
  end

  defp schedule_failure(state) do
    delay = state.current_backoff_ms
    next = min(delay * 2, state.max_backoff_ms)
    state |> Map.put(:current_backoff_ms, next) |> schedule(delay)
  end

  defp reset_backoff(state), do: %{state | current_backoff_ms: state.failure_backoff_ms}

  defp empty_resolution do
    %{
      cursor: nil,
      authorities: %{},
      seen_connect_ids: MapSet.new(),
      unavailable_connect_ids: MapSet.new()
    }
  end

  defp merge_resolution(current, page) do
    page_seen = MapSet.new(page.seen_connect_ids)
    duplicates = MapSet.intersection(current.seen_connect_ids, page_seen)

    unavailable =
      current.unavailable_connect_ids
      |> MapSet.union(MapSet.new(page.unavailable_connect_ids))
      |> MapSet.union(duplicates)

    authorities =
      current.authorities
      |> Map.merge(page.authorities)
      |> Map.reject(fn {{connect_id, _channel_id}, _authority} ->
        MapSet.member?(unavailable, connect_id)
      end)

    %{
      current
      | authorities: authorities,
        seen_connect_ids: MapSet.union(current.seen_connect_ids, page_seen),
        unavailable_connect_ids: unavailable
    }
  end

  defp schedule(state, delay) do
    Process.send_after(self(), :tick, delay)
    state
  end

  defp valid_state?(state) do
    (is_pid(state.runtime) or is_atom(state.runtime)) and is_binary(state.lease_key) and
      state.lease_key != "" and
      Enum.all?(
        [
          state.lease_ttl_ms,
          state.interval_ms,
          state.full_ring_idle_ms,
          state.held_poll_ms,
          state.failure_backoff_ms,
          state.max_backoff_ms
        ],
        &(is_integer(&1) and &1 > 0)
      ) and state.page_limit in 1..@page_limit and state.batch_limit in 1..@batch_limit and
      state.failure_backoff_ms <= state.max_backoff_ms
  end
end
