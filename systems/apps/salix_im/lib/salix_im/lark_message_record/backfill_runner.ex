defmodule SalixIM.LarkMessageRecord.BackfillRunner do
  @moduledoc """
  Schedules history backfill passes of the Lark message record.

  This process holds no correctness: which installation is being walked, when
  it is next due, and how far each container got are rows in
  `SalixStore.LarkMirrorBackfillLedger`. Killing it, or running it on every
  Pod, changes throughput and nothing else.

    * **Discovery** pages every connected Lark connect and records it as an
      installation to walk.
    * **Work** leases the installation that has been due the longest and runs
      one `Backfill` pass. `:more` makes it due again at once, `:idle` defers it
      by `pass_interval_ms`, a failure by a fixed backoff.

  Bound per Pod: one discovery Task and at most `max_concurrent_passes` pass
  Tasks, each making one Lark request per `pace_ms` on its own app.
  """

  use SystemsRuntime.Server

  require Logger

  alias SalixIM.{LarkMessageRecord, ProviderConnects}
  alias SalixIM.LarkMessageRecord.Backfill
  alias SalixStore.LarkMirrorBackfillLedger

  @default_pace_ms 500
  @default_lease_ttl_ms 120_000
  @default_work_idle_ms 30_000
  @default_pass_interval_ms 3_600_000
  @default_discover_interval_ms 3_600_000
  @default_max_concurrent_passes 2
  @default_connect_page 100
  @failure_backoff_ms 60_000

  @task_supervisor __MODULE__.Tasks

  def child_spec(opts) do
    %{id: opts[:name] || __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> SystemsRuntime.Server.start_link(__MODULE__, opts)
      name -> SystemsRuntime.Server.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Name of the supervisor that owns the discovery and pass tasks."
  @spec task_supervisor_name() :: atom()
  def task_supervisor_name, do: @task_supervisor

  @impl true
  def init(opts) do
    delay = setting(opts, :start_delay_ms, 0)
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :discover_tick, delay)
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :work_tick, delay)
    {:ok, %{opts: opts, passes: %{}, discover_task: nil, discover_cursor: nil}}
  end

  # `async_nolink`: a crashed pass must reschedule, not take the scheduler with
  # it. The lease a crashed pass held expires on its own.
  @impl true
  def handle_info(:work_tick, state) do
    slots = setting(state.opts, :max_concurrent_passes, @default_max_concurrent_passes)

    if map_size(state.passes) < slots do
      opts = state.opts

      task =
        SystemsRuntime.TaskSupervisor.async_nolink(task_supervisor(state), fn ->
          run_once(opts)
        end)

      passes = Map.put(state.passes, task.ref, task)

      if map_size(passes) < slots,
        do: SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), :work_tick)

      {:noreply, %{state | passes: passes}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:discover_tick, %{discover_task: nil} = state) do
    cursor = state.discover_cursor
    opts = state.opts

    task =
      SystemsRuntime.TaskSupervisor.async_nolink(task_supervisor(state), fn ->
        discover_once(cursor, opts)
      end)

    {:noreply, %{state | discover_task: task}}
  end

  def handle_info(:discover_tick, state), do: {:noreply, state}

  def handle_info({ref, result}, %{discover_task: %Task{ref: ref}} = state) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])
    {cursor, delay} = discover_next(state, result)
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :discover_tick, delay)
    SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), :work_tick)
    {:noreply, %{state | discover_task: nil, discover_cursor: cursor}}
  end

  def handle_info({ref, result}, state) when is_map_key(state.passes, ref) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :work_tick, work_delay(state, result))
    {:noreply, %{state | passes: Map.delete(state.passes, ref)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{discover_task: %Task{ref: ref}} = state) do
    Logger.warning("lark record backfill discovery crashed: #{inspect(reason)}")
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :discover_tick, @failure_backoff_ms)
    {:noreply, %{state | discover_task: nil, discover_cursor: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.passes, ref) do
    Logger.warning("lark record backfill pass crashed: #{inspect(reason)}")
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :work_tick, @failure_backoff_ms)
    {:noreply, %{state | passes: Map.delete(state.passes, ref)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc "Leases one due installation and runs one pass over it."
  @spec run_once(keyword()) :: :empty | {:ok, Backfill.outcome()} | {:error, term()}
  def run_once(opts \\ []) do
    if not LarkMessageRecord.enabled?() do
      :empty
    else
      ledger = ledger(opts)

      case ledger.claim_due_connect(setting(opts, :lease_ttl_ms, @default_lease_ttl_ms)) do
        {:ok, claimed} -> run_claimed(claimed, opts)
        :empty -> :empty
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp run_claimed(claimed, opts) do
    ledger = ledger(opts)
    connect_id = claimed["connect_id"]

    case connect_for(claimed, opts) do
      {:ok, connect} ->
        connect |> pass(opts) |> settle(ledger, connect_id, opts)

      {:error, :unreachable} ->
        # Deleted, disabled, or no longer a connected Lark app. Discovery
        # puts it back if it returns; its watermarks are untouched.
        _ = ledger.delete_connect(connect_id)
        {:ok, :idle}

      {:error, reason} ->
        _ = ledger.finish_connect(connect_id, @failure_backoff_ms, reason)
        emit(:error)
        {:error, reason}
    end
  end

  defp pass(connect, opts) do
    Backfill.run_pass(connect,
      pace_ms: setting(opts, :pace_ms, @default_pace_ms),
      page_budget: setting(opts, :page_budget, nil),
      ledger: ledger(opts),
      reader: opts[:reader],
      writer: opts[:writer],
      sleep: opts[:sleep]
    )
  end

  defp settle(result, ledger, connect_id, opts) do
    {outcome, delay, error} =
      case result do
        {:ok, :more} -> {:more, 0, nil}
        {:ok, :idle} -> {:idle, setting(opts, :pass_interval_ms, @default_pass_interval_ms), nil}
        {:ok, :retry} -> {:retry, @failure_backoff_ms, nil}
        {:error, reason} -> {:error, @failure_backoff_ms, reason}
      end

    emit(outcome)
    _ = ledger.finish_connect(connect_id, delay, error)
    result
  end

  defp connect_for(claimed, opts) do
    connects = opts[:connects] || ProviderConnects

    case connects.get_active_connect_by_id(claimed["group_id"], claimed["connect_id"], "lark") do
      {:ok, connect} ->
        # The walk calls Lark as the app, with the credentials the connect holds.
        if connect["tenant_id"] == claimed["tenant_id"] and connect["status"] == "connected" and
             Enum.all?(~w(app_id app_secret), &(is_binary(connect[&1]) and connect[&1] != "")),
           do: {:ok, connect},
           else: {:error, :unreachable}

      {:error, :not_found} ->
        {:error, :unreachable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Records one page of connected Lark connects as installations to walk and
  returns the cursor for the next page.
  """
  @spec discover_once(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def discover_once(cursor, opts \\ []) do
    if not LarkMessageRecord.enabled?() do
      {:ok, %{next_cursor: cursor, scan_complete: true}}
    else
      connects = opts[:connects] || ProviderConnects

      with {:ok, page} <-
             connects.list_lark_message_record_backfill_connects(
               setting(opts, :connect_page, @default_connect_page),
               cursor
             ),
           :ok <-
             ledger(opts).upsert_connects(
               Enum.map(page.candidates, &Map.take(&1, ~w(connect_id tenant_id group_id)))
             ) do
        {:ok, %{next_cursor: page.next_cursor, scan_complete: page.scan_complete}}
      end
    end
  end

  defp work_delay(state, :empty), do: setting(state.opts, :work_idle_ms, @default_work_idle_ms)
  defp work_delay(_state, {:ok, _outcome}), do: 0
  defp work_delay(_state, _error), do: @failure_backoff_ms

  defp discover_next(state, {:ok, %{scan_complete: true}}),
    do: {nil, setting(state.opts, :discover_interval_ms, @default_discover_interval_ms)}

  defp discover_next(_state, {:ok, %{next_cursor: cursor}}), do: {cursor, 0}
  defp discover_next(_state, _error), do: {nil, @failure_backoff_ms}

  defp ledger(opts), do: opts[:ledger] || LarkMirrorBackfillLedger

  defp task_supervisor(state), do: state.opts[:task_supervisor] || @task_supervisor

  # Labels stay finite and carry no tenant, app, chat or content.
  defp emit(outcome) do
    SystemsRuntime.Telemetry.execute([:salix, :lark_mirror, :backfill, :pass], %{count: 1}, %{
      outcome: outcome
    })

    :ok
  rescue
    _exception -> :ok
  end

  defp setting(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> config(key, default)
    end
  end

  defp config(key, default) do
    :salix_im
    |> SystemsRuntime.get_env(:lark_message_record_backfill, [])
    |> Keyword.get(key, default)
  end
end
