defmodule SalixIM.FeishuMessageMirror.BackfillRunner do
  @moduledoc """
  Schedules Feishu mirror backfill passes.

  The same shape as `SalixIM.SlackMessageMirror.BackfillRunner`, and like it
  this process holds no correctness: which installation is being walked, when
  it is next due, and how far each container got are rows in
  `SalixStore.FeishuMirrorBackfillLedger`. Killing it, or running it on every
  Pod, changes throughput and nothing else.

    * **Discovery** pages every active Feishu connect and records it as an
      installation to walk.
    * **Work** leases the installation that has been due the longest and runs
      one `Backfill` pass. `:more` makes it due again at once, `:idle` defers it
      by `pass_interval_ms`, a failure by a fixed backoff.

  Bound per Pod: one discovery Task, one claim Task, and at most
  `max_concurrent_passes` pass Tasks. Empty claims arm one work timer for
  `work_idle_ms`. Discovery and pass completion share that timer. Stale timer
  deliveries cannot start claims. Work that wakes while a claim runs makes
  one more claim if that one comes back empty. Discovery keeps its separate page cadence.

  Each pass makes one Feishu request per `pace_ms` on its own app.
  """

  use SystemsRuntime.Server

  require Logger

  alias SalixIM.{FeishuMessageMirror, ProviderConnects}
  alias SalixIM.FeishuMessageMirror.Backfill
  alias SalixStore.FeishuMirrorBackfillLedger

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
    state = %{
      opts: opts,
      passes: %{},
      claim_task: nil,
      claim_again: false,
      work_timer: nil,
      discover_task: nil,
      discover_cursor: nil
    }

    delay = setting(opts, :start_delay_ms, 0)
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :discover_tick, delay)
    {:ok, schedule_work(state, delay)}
  end

  # One pump owns claims and wakeups. Empty claims never start pass tasks.
  @impl true
  def handle_info({:timeout, ref, :work_tick}, %{work_timer: {ref, _}} = state) do
    {:noreply, pump(%{state | work_timer: nil})}
  end

  def handle_info(:work_tick, state) do
    {:noreply, state |> cancel_work() |> pump()}
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
    {:noreply, schedule_work(%{state | discover_task: nil, discover_cursor: cursor}, 0)}
  end

  def handle_info({ref, result}, %{claim_task: %Task{ref: ref}} = state) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])
    state = %{state | claim_task: nil}

    case result do
      {:ok, claimed} ->
        task =
          SystemsRuntime.TaskSupervisor.async_nolink(task_supervisor(state), fn ->
            run_claimed(claimed, state.opts)
          end)

        state = %{state | passes: Map.put(state.passes, task.ref, task)}
        {:noreply, pump(state)}

      # Work woke while this claim ran (a discovery that recorded new
      # installations, a pass that finished): the claim may have read the
      # ledger before that, so claim once more.
      :empty when state.claim_again ->
        {:noreply, pump(state)}

      :empty ->
        {:noreply,
         schedule_work(state, setting(state.opts, :work_idle_ms, @default_work_idle_ms))}

      {:error, _reason} ->
        {:noreply, schedule_work(state, @failure_backoff_ms)}
    end
  end

  def handle_info({ref, _result}, state) when is_map_key(state.passes, ref) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])
    # Each installation's durable due time includes its error backoff.
    {:noreply, schedule_work(%{state | passes: Map.delete(state.passes, ref)}, 0)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{discover_task: %Task{ref: ref}} = state) do
    Logger.warning("feishu mirror backfill discovery crashed: #{inspect(reason)}")
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :discover_tick, @failure_backoff_ms)
    {:noreply, %{state | discover_task: nil, discover_cursor: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{claim_task: %Task{ref: ref}} = state) do
    Logger.warning("feishu mirror backfill claim crashed: #{inspect(reason)}")
    {:noreply, schedule_work(%{state | claim_task: nil}, @failure_backoff_ms)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.passes, ref) do
    Logger.warning("feishu mirror backfill pass crashed: #{inspect(reason)}")
    {:noreply, schedule_work(%{state | passes: Map.delete(state.passes, ref)}, 0)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc "Leases one due installation and runs one pass over it."
  @spec run_once(keyword()) :: :empty | {:ok, Backfill.outcome()} | {:error, term()}
  def run_once(opts \\ []) do
    case claim_once(opts) do
      {:ok, claimed} -> run_claimed(claimed, opts)
      result -> result
    end
  end

  defp claim_once(opts) do
    if FeishuMessageMirror.enabled?(),
      do: ledger(opts).claim_due_connect(setting(opts, :lease_ttl_ms, @default_lease_ttl_ms)),
      else: :empty
  end

  defp pump(state) do
    slots = setting(state.opts, :max_concurrent_passes, @default_max_concurrent_passes)

    cond do
      state.claim_task != nil ->
        %{state | claim_again: true}

      map_size(state.passes) < slots ->
        task =
          SystemsRuntime.TaskSupervisor.async_nolink(task_supervisor(state), fn ->
            claim_once(state.opts)
          end)

        %{state | claim_task: task, claim_again: false}

      true ->
        state
    end
  end

  defp schedule_work(state, delay) do
    due = SystemsClock.monotonic_time(:millisecond) + delay

    case state.work_timer do
      {_ref, earlier} when earlier <= due ->
        state

      _ ->
        state = cancel_work(state)
        ref = SystemsClock.start_timer(delay, SystemsRuntime.Proc.self(), :work_tick)
        %{state | work_timer: {ref, due}}
    end
  end

  defp cancel_work(%{work_timer: nil} = state), do: state

  defp cancel_work(%{work_timer: {ref, _}} = state) do
    SystemsClock.cancel_timer(ref)
    %{state | work_timer: nil}
  end

  defp run_claimed(claimed, opts) do
    ledger = ledger(opts)
    connect_id = claimed["connect_id"]

    case connect_for(claimed, opts) do
      {:ok, connect} ->
        connect |> pass(opts) |> settle(ledger, connect_id, opts)

      {:error, :unreachable} ->
        # Deleted, disabled, or no longer a connected Feishu app. Discovery
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

    case connects.get_active_connect_by_id(claimed["group_id"], claimed["connect_id"], "feishu") do
      {:ok, connect} ->
        if connect["tenant_id"] == claimed["tenant_id"] and connect["status"] == "connected" and
             is_binary(connect["app_id"]) and connect["app_id"] != "",
           do: {:ok, connect},
           else: {:error, :unreachable}

      {:error, :not_found} ->
        {:error, :unreachable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Records one page of connected Feishu connects as installations to walk and
  returns the cursor for the next page.
  """
  @spec discover_once(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def discover_once(cursor, opts \\ []) do
    if not FeishuMessageMirror.enabled?() do
      {:ok, %{next_cursor: cursor, scan_complete: true}}
    else
      connects = opts[:connects] || ProviderConnects

      with {:ok, page} <-
             connects.list_feishu_mirror_backfill_connects(
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

  defp discover_next(state, {:ok, %{scan_complete: true}}),
    do: {nil, setting(state.opts, :discover_interval_ms, @default_discover_interval_ms)}

  defp discover_next(_state, {:ok, %{next_cursor: cursor}}), do: {cursor, 0}
  defp discover_next(_state, _error), do: {nil, @failure_backoff_ms}

  defp ledger(opts), do: opts[:ledger] || FeishuMirrorBackfillLedger

  defp task_supervisor(state), do: state.opts[:task_supervisor] || @task_supervisor

  # Labels stay finite and carry no tenant, app, chat or content.
  defp emit(outcome) do
    SystemsRuntime.Telemetry.execute([:salix, :feishu_mirror, :backfill, :pass], %{count: 1}, %{
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
    |> SystemsRuntime.get_env(:feishu_message_mirror_backfill, [])
    |> Keyword.get(key, default)
  end
end
