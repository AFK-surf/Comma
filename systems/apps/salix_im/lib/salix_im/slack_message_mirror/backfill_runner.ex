defmodule SalixIM.SlackMessageMirror.BackfillRunner do
  @moduledoc """
  Schedules Slack mirror backfill passes.

  This process holds no correctness. PostgreSQL does: which installation is
  being walked, until when, when it is next due, and how far each channel got
  are all rows in `SalixStore.SlackMirrorBackfillLedger`. Killing this process,
  or running it on every Pod at once, changes throughput and nothing else.

  Two concerns run on separate cadences and both run in Tasks, never inline:

    * **Discovery** pages every active Slack connect and records it as an
      installation to walk. Slow, because installations change slowly.

    * **Work** claims the installation that has been due the longest and runs
      one pass over it. Up to `max_concurrent_passes` run at once on a Pod,
      each on a different installation and so on a different Slack budget.

  A pass that reports history left makes its installation due again at once;
  one that reports nothing left defers it by `pass_interval_ms`. Joining a
  channel, and going live, kick `kick_generation` and due now. A finish
  defers only if it claimed at that generation. Because the claim takes the
  installation due the longest, a Pod with one free slot alternates between
  installations rather than pinning to the deepest one.

  ## What bounds this

  Per Pod: one discovery Task and at most `max_concurrent_passes` pass Tasks,
  each doing one Slack request per `pace_ms` on its own installation. Per
  discovery tick: one page of connects. A Pod's Slack request rate is bounded
  by pacing and concurrency alone regardless of how many connects, channels or
  messages exist, and adding Pods adds claimants for DISTINCT installations
  rather than duplicate work on the same one.
  """

  use GenServer

  require Logger

  alias SalixIM.ProviderConnects
  alias SalixIM.SlackMessageMirror
  alias SalixIM.SlackMessageMirror.Backfill
  alias SalixStore.SlackMirrorBackfillLedger

  @default_pace_ms 1_500
  @default_lease_ttl_ms 120_000
  @default_work_idle_ms 30_000
  @default_pass_interval_ms 3_600_000
  @default_discover_interval_ms 3_600_000
  @default_max_concurrent_passes 4
  @default_connect_page 100
  @failure_backoff_ms 60_000

  @task_supervisor __MODULE__.Tasks

  def child_spec(opts) do
    %{id: opts[:name] || __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Name of the supervisor that owns the discovery and pass tasks."
  @spec task_supervisor_name() :: atom()
  def task_supervisor_name, do: @task_supervisor

  @impl true
  def init(opts) do
    state = %{opts: opts, passes: %{}, discover_task: nil, discover_cursor: nil}

    delay = setting(opts, :start_delay_ms, 0)
    Process.send_after(self(), :discover_tick, delay)
    Process.send_after(self(), :work_tick, delay)

    {:ok, state}
  end

  # `async_nolink`, not `async`. A linked task's abnormal exit is delivered to
  # this process as an exit signal, and since it does not trap exits the
  # scheduler would die with the pass rather than reschedule it. The claim a
  # crashed pass held expires on its own.
  #
  # One pass Task per tick. A tick that leaves a slot free schedules the next
  # one at once, so the slots fill; every finished pass schedules exactly one
  # tick, so the number of pending ticks and running passes together never
  # exceeds the slots. An empty queue costs one claim per slot per
  # `work_idle_ms`.
  @impl true
  def handle_info(:work_tick, state) do
    slots = setting(state.opts, :max_concurrent_passes, @default_max_concurrent_passes)

    if map_size(state.passes) < slots do
      opts = state.opts
      task = Task.Supervisor.async_nolink(task_supervisor(state), fn -> run_once(opts) end)
      passes = Map.put(state.passes, task.ref, task)
      if map_size(passes) < slots, do: send(self(), :work_tick)
      {:noreply, %{state | passes: passes}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:discover_tick, %{discover_task: nil} = state) do
    cursor = state.discover_cursor
    opts = state.opts

    task =
      Task.Supervisor.async_nolink(task_supervisor(state), fn -> discover_once(cursor, opts) end)

    {:noreply, %{state | discover_task: task}}
  end

  def handle_info(:discover_tick, state), do: {:noreply, state}

  def handle_info({ref, result}, %{discover_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {cursor, delay} = discover_next(state, result)
    Process.send_after(self(), :discover_tick, delay)
    send(self(), :work_tick)
    {:noreply, %{state | discover_task: nil, discover_cursor: cursor}}
  end

  def handle_info({ref, result}, state) when is_map_key(state.passes, ref) do
    Process.demonitor(ref, [:flush])
    Process.send_after(self(), :work_tick, work_delay(state, result))
    {:noreply, %{state | passes: Map.delete(state.passes, ref)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{discover_task: %Task{ref: ref}} = state) do
    Logger.warning("slack mirror backfill discovery crashed: #{inspect(reason)}")
    Process.send_after(self(), :discover_tick, @failure_backoff_ms)
    {:noreply, %{state | discover_task: nil, discover_cursor: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.passes, ref) do
    Logger.warning("slack mirror backfill pass crashed: #{inspect(reason)}")
    Process.send_after(self(), :work_tick, @failure_backoff_ms)
    {:noreply, %{state | passes: Map.delete(state.passes, ref)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Makes one installation due now and wakes the scheduler.

  Used when the bot joins a channel and when going live. Safe to call from
  the webhook path: a missed kick still lands on the next work tick.
  """
  @spec kick(map()) :: :ok
  def kick(connect) when is_map(connect) do
    if SlackMessageMirror.enabled?() do
      _ = ledger([]).kick_connect(connect)

      case Process.whereis(__MODULE__) do
        pid when is_pid(pid) -> send(pid, :work_tick)
        nil -> :ok
      end
    end

    :ok
  end

  def kick(_connect), do: :ok

  @doc """
  Claims one due installation and runs one pass over it.

  `:empty` means nothing is due, which is the steady state once every channel
  is walked and is not an error.
  """
  @spec run_once(keyword()) :: :empty | {:ok, Backfill.outcome()} | {:error, term()}
  def run_once(opts \\ []) do
    if not SlackMessageMirror.enabled?() do
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

    claimed_kick_gen = claimed_kick_gen(claimed)

    case connect_for(claimed, opts) do
      {:ok, connect} ->
        settle(ledger, connect_id, pass(connect, opts), opts, claimed_kick_gen)

      {:error, :unreachable} ->
        # Deleted, disabled, or no longer a Slack installation with a token.
        # Discovery puts it back if it returns; its watermarks are untouched.
        _ = ledger.delete_connect(connect_id)
        {:ok, :idle}

      {:error, reason} ->
        _ = ledger.finish_connect(connect_id, @failure_backoff_ms, reason, claimed_kick_gen)
        emit(:error)
        {:error, reason}
    end
  end

  defp pass(connect, opts) do
    Backfill.run_pass(connect,
      pace_ms: setting(opts, :pace_ms, @default_pace_ms),
      lease_ttl_ms: setting(opts, :lease_ttl_ms, @default_lease_ttl_ms),
      floor_ts_us: setting(opts, :floor_ts_us, 0),
      page_budget: setting(opts, :page_budget, nil),
      ledger: ledger(opts),
      writer: opts[:writer] || SlackMessageMirror,
      reader: opts[:reader] || Backfill.SlackReader,
      sleep: opts[:sleep] || (&Process.sleep/1)
    )
  end

  defp settle(ledger, connect_id, result, opts, claimed_kick_gen) do
    case result do
      {:ok, :more} ->
        emit(:more)
        _ = ledger.finish_connect(connect_id, 0, nil, claimed_kick_gen)
        {:ok, :more}

      {:ok, :idle} ->
        emit(:idle)

        _ =
          ledger.finish_connect(
            connect_id,
            setting(opts, :pass_interval_ms, @default_pass_interval_ms),
            nil,
            claimed_kick_gen
          )

        {:ok, :idle}

      {:ok, :retry} ->
        emit(:retry)
        _ = ledger.finish_connect(connect_id, @failure_backoff_ms, nil, claimed_kick_gen)
        {:ok, :retry}

      # Another Pod holds this installation now; its row already says so, and
      # writing a schedule over it would be this Pod's last act of authority
      # over work it no longer has.
      {:error, :claim_lost} ->
        emit(:error)
        {:error, :claim_lost}

      {:error, reason} ->
        emit(:error)
        _ = ledger.finish_connect(connect_id, @failure_backoff_ms, reason, claimed_kick_gen)
        {:error, reason}
    end
  end

  defp claimed_kick_gen(%{"kick_generation" => n}) when is_integer(n) and n >= 0, do: n
  defp claimed_kick_gen(_claimed), do: 0

  defp connect_for(claimed, opts) do
    connects = opts[:connects] || ProviderConnects

    case connects.get_active_connect_by_id(claimed["group_id"], claimed["connect_id"], "slack") do
      {:ok, connect} ->
        if connect["tenant_id"] == claimed["tenant_id"] and
             is_binary(connect["workspace_id"]) and connect["workspace_id"] != "" and
             is_binary(connect["bot_token"]) and connect["bot_token"] != "" do
          {:ok, connect}
        else
          {:error, :unreachable}
        end

      {:error, :not_found} ->
        {:error, :unreachable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Records one page of Slack connects as installations to walk.

  Returns the cursor for the next page. `scan_complete` means the whole
  connect corpus was covered and the next tick starts over.
  """
  @spec discover_once(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def discover_once(cursor, opts \\ []) do
    if not SlackMessageMirror.enabled?() do
      {:ok, %{next_cursor: cursor, scan_complete: true}}
    else
      connects = opts[:connects] || ProviderConnects

      with {:ok, page} <-
             connects.list_slack_mirror_backfill_connects(
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

  # A pass that did work is followed immediately by the next claim; an empty
  # queue is not polled tightly.
  defp work_delay(state, :empty), do: setting(state.opts, :work_idle_ms, @default_work_idle_ms)
  defp work_delay(_state, {:ok, _outcome}), do: 0
  defp work_delay(_state, _error), do: @failure_backoff_ms

  defp discover_next(state, {:ok, %{scan_complete: true}}),
    do: {nil, setting(state.opts, :discover_interval_ms, @default_discover_interval_ms)}

  defp discover_next(_state, {:ok, %{next_cursor: cursor}}), do: {cursor, 0}
  defp discover_next(_state, _error), do: {nil, @failure_backoff_ms}

  defp ledger(opts), do: opts[:ledger] || SlackMirrorBackfillLedger

  defp task_supervisor(state), do: state.opts[:task_supervisor] || @task_supervisor

  # Labels stay finite and carry no tenant, workspace, channel or content.
  defp emit(outcome) do
    :telemetry.execute([:salix, :slack_mirror, :backfill, :pass], %{count: 1}, %{outcome: outcome})

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
    |> Application.get_env(:slack_message_mirror_backfill, [])
    |> Keyword.get(key, default)
  end
end
