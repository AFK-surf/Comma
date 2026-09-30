defmodule SalixAgent.SessionWorkRecovery do
  @moduledoc """
  Bounded, single-flight recovery for durable non-stable session work.

  The supervised worker owns the two Postgres eager/deferred cursors and moves
  the deterministic `sweep/1` operation off the shared cluster Recovery tick.
  It has no timer or lease of its own: the lease holder requests work, repeated
  requests coalesce, and at most one sweep runs on a node at a time.

  Each pass starts at the successor of the last lane it actually attempted.
  A wake budget exhausted inside one lane therefore cannot starve the other
  lane forever. Within a lane the cursor advances only through the contiguous
  prefix whose records were actually attempted; a query error or a budget
  exhausted before the next record leaves that cursor unchanged.

  Candidate rows are derived hints. Recovery rereads the authoritative Session
  and token/revision fences every exact cleanup or wake. Wakes are idempotent
  hints; every SessionActor rereads durable state before running.

  Retirement, lane fairness, and notification catch-up are implementation-test
  contracts. Their feature-level TLA+ models are retired; the retained system
  models do not prove this recovery loop's progress.
  """

  use GenServer
  require Logger

  alias SalixAgent.{
    ExternalSessionStore,
    InternalSession,
    InternalSessionStore,
    SessionWorkIndex
  }

  @default_page_size 100
  @default_wake_timeout_ms 500
  @default_page_wake_budget_ms 2_000
  # Reconnect catch-up is a bounded latency optimization, not the completeness
  # owner. Scan at most 6,400 candidates; the lease-driven singleton recovery
  # worker retains every unfinished candidate and continues after this cap.
  @max_catchup_pages 64

  @type lane :: :eager | :deferred
  @type summary :: %{
          rewoken: [String.t()],
          scanned: non_neg_integer(),
          cleaned: non_neg_integer(),
          failed: non_neg_integer(),
          unproven_retained: non_neg_integer(),
          next: String.t() | nil,
          deferred_next: String.t() | nil,
          last_attempted_lane: lane() | nil
        }

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Request one lease-authorized sweep without blocking the caller."
  @spec request_sweep(GenServer.server()) :: :ok | {:error, :not_running}
  def request_sweep(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil ->
        Logger.warning("session-work recovery worker is not running")
        {:error, :not_running}

      _pid ->
        GenServer.cast(server, :sweep)
        :ok
    end
  end

  @doc "Request one bounded, deduplicated exact wake without blocking the caller."
  @spec request_wake(String.t(), map(), keyword()) ::
          :ok | {:error, :invalid_target | :not_running}
  def request_wake(agent_id, target, opts \\ [])

  def request_wake(
        agent_id,
        %{runtime: runtime, session_id: session_id},
        opts
      )
      when is_binary(agent_id) and agent_id != "" and
             byte_size(agent_id) <= 256 and
             runtime in [:internal, :external] and
             is_binary(session_id) and session_id != "" and byte_size(session_id) <= 256 do
    server = Keyword.get(opts, :server, __MODULE__)
    candidate_token = Keyword.get(opts, :candidate_token)

    if valid_candidate_token?(candidate_token) do
      key = {candidate_token || "", agent_id, runtime, session_id}
      target = %{runtime: runtime, session_id: session_id}

      case GenServer.whereis(server) do
        nil ->
          Logger.warning("session-work recovery worker is not running")
          {:error, :not_running}

        _pid ->
          GenServer.cast(server, {:wake, key, agent_id, target})
          :ok
      end
    else
      {:error, :invalid_target}
    end
  end

  def request_wake(_agent_id, _target, _opts), do: {:error, :invalid_target}

  @doc "Run one bounded session-work recovery pass synchronously."
  @spec sweep(keyword()) :: summary()
  def sweep(opts \\ []) do
    started_at = System.monotonic_time()
    now_ms = opts[:now] || System.system_time(:millisecond)
    max_keys = Keyword.get(opts, :session_work_max_keys, @default_page_size)
    start_lane = normalize_lane(opts[:session_work_start_lane])
    group_id = opts[:session_work_group_id]
    device_id = opts[:session_work_device_id]

    wake_timeout_ms =
      positive_integer_option(opts[:session_work_wake_timeout], @default_wake_timeout_ms)

    page_wake_budget_ms =
      positive_integer_option(
        opts[:session_work_page_wake_budget],
        @default_page_wake_budget_ms
      )

    state = %{
      stats: %{rewoken: [], cleaned: 0, failed: 0, unproven_retained: 0},
      scanned: 0,
      next: opts[:session_work_cursor],
      deferred_next: opts[:deferred_session_work_cursor],
      last_attempted_lane: nil,
      group_id: group_id,
      device_id: device_id
    }

    deadline_ms = System.monotonic_time(:millisecond) + page_wake_budget_ms

    result =
      if(is_nil(group_id), do: lane_order(start_lane), else: [:eager])
      |> Enum.reduce_while(state, fn lane, acc ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          {:halt, acc}
        else
          attempt_lane(
            lane,
            acc,
            max_keys,
            now_ms,
            deadline_ms,
            wake_timeout_ms
          )
        end
      end)

    summary = %{
      rewoken: result.stats.rewoken |> Enum.reverse() |> Enum.uniq(),
      scanned: result.scanned,
      cleaned: result.stats.cleaned,
      failed: result.stats.failed,
      unproven_retained: result.stats.unproven_retained,
      next: result.next,
      deferred_next: result.deferred_next,
      last_attempted_lane: result.last_attempted_lane
    }

    Salix.Telemetry.emit_operation(
      "salix_cluster",
      "session_work_recovery",
      "system",
      telemetry_outcome(summary),
      System.monotonic_time() - started_at
    )

    summary
  end

  @doc """
  Start one bounded device-scoped catch-up pass after Connector reconnect.
  Candidate rows are only addresses; the existing recovery path rereads and
  token-fences every authoritative Session before waking its normal owner.
  """
  @spec catch_up_external_inputs(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def catch_up_external_inputs(group_id, device_id)
      when is_binary(group_id) and group_id != "" and is_binary(device_id) and device_id != "" do
    case Task.Supervisor.start_child(SalixAgent.TaskSup, fn ->
           run_external_input_catchup(group_id, device_id)
         end) do
      {:ok, _pid} -> {:ok, %{"accepted" => true}}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  def catch_up_external_inputs(_group_id, _device_id), do: {:error, :invalid_scope}

  @doc false
  @spec empty_summary() :: summary()
  def empty_summary do
    %{
      rewoken: [],
      scanned: 0,
      cleaned: 0,
      failed: 0,
      unproven_retained: 0,
      next: nil,
      deferred_next: nil,
      last_attempted_lane: nil
    }
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       cursor: nil,
       deferred_cursor: nil,
       start_lane: :eager,
       task: nil,
       task_kind: nil,
       pending: false,
       notification_queue: :queue.new(),
       notification_keys: MapSet.new(),
       notification_queue_limit: positive_integer_option(opts[:notification_queue_limit], 1_024),
       notification_wake_timeout:
         positive_integer_option(
           opts[:notification_wake_timeout],
           @default_wake_timeout_ms
         ),
       max_keys: Keyword.get(opts, :session_work_max_keys, @default_page_size),
       task_supervisor: Keyword.get(opts, :task_supervisor, SalixAgent.TaskSup),
       sweep_fn: Keyword.get(opts, :sweep_fn, &__MODULE__.sweep/1),
       wake_fn: Keyword.get(opts, :wake_fn, &wake_exact_target/3)
     }}
  end

  @impl true
  def handle_cast(:sweep, %{task: %Task{}} = state), do: {:noreply, %{state | pending: true}}
  def handle_cast(:sweep, state), do: {:noreply, start_sweep(state)}

  def handle_cast({:wake, key, agent_id, target}, state) do
    cond do
      MapSet.member?(state.notification_keys, key) ->
        emit_notification_admission("ignored")
        {:noreply, state}

      :queue.len(state.notification_queue) < state.notification_queue_limit ->
        state = %{
          state
          | notification_queue: :queue.in({key, agent_id, target}, state.notification_queue),
            notification_keys: MapSet.put(state.notification_keys, key)
        }

        emit_notification_admission("ok")
        {:noreply, maybe_start_next(state)}

      true ->
        # The durable candidate already exists. Drop only this lossy hint;
        # periodic lease-driven recovery keeps notification pressure from
        # becoming either an unbounded queue or an unbounded sweep loop.
        emit_notification_admission("over_budget")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {ref,
         %{
           rewoken: _rewoken,
           scanned: _scanned,
           cleaned: _cleaned,
           failed: _failed,
           next: next,
           deferred_next: deferred_next,
           last_attempted_lane: last_attempted_lane
         } = result},
        %{task: %Task{ref: ref}, task_kind: :sweep} = state
      ) do
    Process.demonitor(ref, [:flush])
    log_summary(result)

    state = %{
      state
      | cursor: next,
        deferred_cursor: deferred_next,
        start_lane: successor_lane(last_attempted_lane, state.start_lane),
        task: nil,
        task_kind: nil
    }

    {:noreply, maybe_start_next(state)}
  end

  def handle_info(
        {ref, result},
        %{task: %Task{ref: ref}, task_kind: {:notification_wake, key, started_at}} = state
      ) do
    Process.demonitor(ref, [:flush])

    outcome =
      case result do
        :ok ->
          "ok"

        {:error, reason} ->
          Logger.warning("session-work notification wake failed: #{inspect(reason)}")
          "error"

        other ->
          Logger.warning(
            "session-work notification wake returned an invalid result: #{inspect(other)}"
          )

          "error"
      end

    emit_notification_wake(outcome, started_at)

    state = %{
      state
      | task: nil,
        task_kind: nil,
        notification_keys: MapSet.delete(state.notification_keys, key)
    }

    {:noreply, maybe_start_next(state)}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}, task_kind: :sweep} = state) do
    Process.demonitor(ref, [:flush])
    Logger.warning("session-work recovery returned an invalid result: #{inspect(result)}")
    {:noreply, state |> reset_after_failure() |> maybe_start_next()}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{task: %Task{ref: ref}, task_kind: {:notification_wake, key, started_at}} = state
      ) do
    Logger.warning("session-work notification wake task exited: #{inspect(reason)}")
    emit_notification_wake("error", started_at)

    state = %{
      state
      | task: nil,
        task_kind: nil,
        notification_keys: MapSet.delete(state.notification_keys, key)
    }

    {:noreply, maybe_start_next(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{task: %Task{ref: ref}, task_kind: :sweep} = state
      ) do
    Logger.warning("session-work recovery task exited: #{inspect(reason)}")
    {:noreply, state |> reset_after_failure() |> maybe_start_next()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_sweep(state) do
    opts = [
      session_work_max_keys: state.max_keys,
      session_work_cursor: state.cursor,
      deferred_session_work_cursor: state.deferred_cursor,
      session_work_start_lane: state.start_lane
    ]

    task = Task.Supervisor.async_nolink(state.task_supervisor, fn -> state.sweep_fn.(opts) end)
    %{state | task: task, task_kind: :sweep, pending: false}
  end

  defp start_notification_wake(state) do
    {{:value, {key, agent_id, target}}, queue} = :queue.out(state.notification_queue)
    started_at = System.monotonic_time()

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        state.wake_fn.(agent_id, target, state.notification_wake_timeout)
      end)

    %{
      state
      | task: task,
        task_kind: {:notification_wake, key, started_at},
        notification_queue: queue
    }
  end

  defp maybe_start_next(%{task: %Task{}} = state), do: state
  defp maybe_start_next(%{pending: true} = state), do: start_sweep(state)

  defp maybe_start_next(state) do
    if :queue.is_empty(state.notification_queue), do: state, else: start_notification_wake(state)
  end

  defp reset_after_failure(state) do
    %{state | cursor: nil, deferred_cursor: nil, start_lane: :eager, task: nil, task_kind: nil}
  end

  defp attempt_lane(lane, state, max_keys, now_ms, deadline_ms, wake_timeout_ms) do
    cursor = lane_cursor(state, lane)
    state = %{state | last_attempted_lane: lane}

    case list_lane(lane, cursor, max_keys, now_ms, state.group_id, state.device_id) do
      {:ok, records, eof?} ->
        {stats, next, stopped?} =
          process_lane(
            records,
            lane,
            cursor,
            eof?,
            now_ms,
            deadline_ms,
            wake_timeout_ms,
            state.stats
          )

        state =
          state
          |> Map.put(:stats, stats)
          |> Map.update!(:scanned, &(&1 + length(records)))
          |> put_lane_cursor(lane, next)

        if stopped?, do: {:halt, state}, else: {:cont, state}

      {:error, reason} ->
        Logger.warning("#{lane} session-work recovery scan failed: #{inspect(reason)}")
        {:cont, put_in(state, [:stats, :failed], state.stats.failed + 1)}
    end
  end

  defp list_lane(:eager, cursor, max_keys, _now_ms, group_id, device_id) do
    [max_keys: max_keys, group_id: group_id]
    |> maybe_put_cursor(cursor)
    |> SessionWorkIndex.list_discovery()
    |> normalize_page()
    |> scope_page(device_id)
    |> mark_readiness_notifications()
  end

  defp list_lane(:deferred, cursor, max_keys, now_ms, _group_id, _device_id) do
    opts = [max_keys: max_keys] |> maybe_put_cursor(cursor)

    now_ms
    |> SessionWorkIndex.list_due_discovery(opts)
    |> normalize_page()
  end

  defp normalize_page({:ok, %{records: records, eof: eof?}}), do: {:ok, records, eof?}
  defp normalize_page({:error, _} = error), do: error

  defp mark_readiness_notifications({:ok, records, eof?}),
    do: {:ok, Enum.map(records, &Map.put(&1, "_runtime_ready_notification", true)), eof?}

  defp mark_readiness_notifications(error), do: error

  defp scope_page({:ok, records, eof?}, device_id) when is_binary(device_id),
    do: {:ok, Enum.map(records, &Map.put(&1, "_catchup_device_id", device_id)), eof?}

  defp scope_page(page, _device_id), do: page

  defp log_summary(%{
         rewoken: rewoken,
         scanned: scanned,
         cleaned: cleaned,
         failed: failed,
         unproven_retained: unproven_retained
       }) do
    if rewoken != [] or cleaned > 0 or failed > 0 or unproven_retained > 0 do
      Logger.info(
        "session-work recovery: rewoke=#{inspect(rewoken)} scanned=#{scanned} " <>
          "cleaned=#{cleaned} failed=#{failed} unproven_retained=#{unproven_retained}"
      )
    end
  end

  defp process_lane(
         records,
         lane,
         input_cursor,
         eof?,
         now_ms,
         deadline_ms,
         wake_timeout_ms,
         stats
       ) do
    do_process_lane(
      records,
      lane,
      input_cursor,
      eof?,
      now_ms,
      deadline_ms,
      wake_timeout_ms,
      stats
    )
  end

  defp do_process_lane([], _lane, cursor, eof?, _now_ms, _deadline_ms, _wake_timeout_ms, stats),
    do: {stats, if(eof?, do: nil, else: cursor), false}

  defp do_process_lane(
         [record | rest],
         lane,
         cursor,
         eof?,
         now_ms,
         deadline_ms,
         wake_timeout_ms,
         stats
       ) do
    process_resolved_record(
      resolve_record(record, now_ms),
      cursor,
      rest,
      record,
      lane,
      eof?,
      now_ms,
      deadline_ms,
      wake_timeout_ms,
      stats
    )
  end

  defp process_resolved_record(
         resolution,
         cursor,
         rest,
         record,
         lane,
         eof?,
         now_ms,
         deadline_ms,
         wake_timeout_ms,
         stats
       ) do
    case resolution do
      {:wake, agent_id, target} ->
        remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

        if remaining_ms <= 0 do
          {stats, cursor, true}
        else
          timeout_ms = min(wake_timeout_ms, remaining_ms)

          stats =
            case wake_exact_target(agent_id, target, timeout_ms) do
              :ok -> %{stats | rewoken: [agent_id | stats.rewoken]}
              {:error, _reason} -> %{stats | failed: stats.failed + 1}
            end

          advance_lane(
            rest,
            record,
            lane,
            eof?,
            now_ms,
            deadline_ms,
            wake_timeout_ms,
            stats
          )
        end

      :keep ->
        advance_lane(
          rest,
          record,
          lane,
          eof?,
          now_ms,
          deadline_ms,
          wake_timeout_ms,
          stats
        )

      :unproven ->
        advance_lane(
          rest,
          record,
          lane,
          eof?,
          now_ms,
          deadline_ms,
          wake_timeout_ms,
          %{stats | unproven_retained: stats.unproven_retained + 1}
        )

      :stale ->
        stats =
          case SessionWorkIndex.delete_stale_record(record) do
            {:ok, _status} -> %{stats | cleaned: stats.cleaned + 1}
            {:error, _reason} -> %{stats | failed: stats.failed + 1}
          end

        advance_lane(
          rest,
          record,
          lane,
          eof?,
          now_ms,
          deadline_ms,
          wake_timeout_ms,
          stats
        )

      {:error, _reason} ->
        advance_lane(
          rest,
          record,
          lane,
          eof?,
          now_ms,
          deadline_ms,
          wake_timeout_ms,
          %{stats | failed: stats.failed + 1}
        )
    end
  end

  defp advance_lane(rest, record, lane, eof?, now_ms, deadline_ms, wake_timeout_ms, stats) do
    do_process_lane(
      rest,
      lane,
      SessionWorkIndex.cursor(record, lane),
      eof?,
      now_ms,
      deadline_ms,
      wake_timeout_ms,
      stats
    )
  end

  defp wake_exact_target(agent_id, target, timeout_ms) do
    with {:ok, pid} <- SalixAgent.Placement.ensure_started(agent_id, create: false),
         :ok <- SalixAgent.Server.recover_session_work(pid, [target], timeout_ms) do
      :ok
    else
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  defp run_external_input_catchup(group_id, device_id) do
    case do_external_input_catchup(group_id, device_id, nil, 0, 0) do
      :ok ->
        :ok

      {:error, reason, failed} ->
        Logger.warning(
          "external-input reconnect catch-up incomplete: " <>
            "device_id=#{device_id} failed=#{failed} reason=#{inspect(reason)}"
        )
    end
  end

  defp do_external_input_catchup(
         _group_id,
         _device_id,
         _cursor,
         @max_catchup_pages,
         failed
       ),
       do: {:error, :page_limit, failed}

  defp do_external_input_catchup(group_id, device_id, cursor, pages, failed) do
    summary =
      sweep(
        session_work_group_id: group_id,
        session_work_device_id: device_id,
        session_work_cursor: cursor,
        session_work_start_lane: :eager
      )

    failed = failed + summary.failed

    cond do
      is_nil(summary.next) and failed == 0 ->
        :ok

      is_nil(summary.next) ->
        {:error, :candidate_failure, failed}

      summary.next == cursor ->
        {:error, :no_progress, failed}

      true ->
        do_external_input_catchup(group_id, device_id, summary.next, pages + 1, failed)
    end
  end

  defp resolve_record(
         %{
           "agent_id" => _agent_id,
           "runtime_kind" => "internal",
           "session_id" => _session_id,
           "token" => _token
         } = record,
         now_ms
       ) do
    if SessionWorkIndex.retired_router_session?(record) do
      :stale
    else
      resolve_internal_record(record, now_ms)
    end
  end

  defp resolve_record(
         %{
           "agent_id" => agent_id,
           "runtime_kind" => "external",
           "session_id" => session_id,
           "token" => token
         } = record,
         now_ms
       ) do
    case ExternalSessionStore.get_session_record_with_etag(agent_id, session_id) do
      {:ok, session, _current_etag} ->
        current_reasons = ExternalSessionStore.work_reasons(session)

        cond do
          different_external_device?(session, record["_catchup_device_id"]) ->
            :keep

          session["work_index_token"] == token and
            "runtime_wait" in current_reasons and record["_runtime_ready_notification"] == true ->
            {:wake, agent_id, %{runtime: :external, session_id: session_id}}

          session["work_index_token"] == token ->
            classify_current_work(
              current_reasons,
              ExternalSessionStore.recovery_wait(session),
              now_ms,
              agent_id,
              %{runtime: :external, session_id: session_id}
            )

          true ->
            classify_mismatched_generation(record, session["storage_revision"])
        end

      {:error, :not_found} ->
        :unproven

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_record(_record, _now_ms), do: :unproven

  defp resolve_internal_record(
         %{"agent_id" => agent_id, "session_id" => session_id, "token" => token} = record,
         now_ms
       ) do
    case InternalSessionStore.read_with_etag(agent_id, session_id) do
      {:ok, session, _current_etag} ->
        current_reasons = InternalSession.work_reasons(session)

        if InternalSession.work_index_token(session) == token do
          classify_current_work(
            current_reasons,
            InternalSession.recovery_wait(session),
            now_ms,
            agent_id,
            %{runtime: :internal, session_id: session_id}
          )
        else
          classify_mismatched_generation(record, InternalSession.storage_revision(session))
        end

      {:error, :not_found} ->
        :unproven

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp different_external_device?(_session, nil), do: false

  defp different_external_device?(session, device_id),
    do: get_in(session, ["runtime", "binding", "device_id"]) != device_id

  defp classify_mismatched_generation(%{"base_revision" => nil}, _current_revision),
    do: :unproven

  defp classify_mismatched_generation(%{"base_revision" => base_revision}, current_revision)
       when is_binary(base_revision) and is_binary(current_revision) do
    if base_revision == current_revision, do: :unproven, else: :stale
  end

  defp classify_mismatched_generation(_record, _current_revision), do: :unproven

  defp classify_current_work(reasons, wait, now_ms, agent_id, target) do
    cond do
      SessionWorkIndex.immediate_recovery_reasons?(reasons) ->
        {:wake, agent_id, target}

      Enum.any?(~w(wait_deadline llm_retry capability_deadline runtime_wait), &(&1 in reasons)) and
          wait_due?(wait, now_ms) ->
        {:wake, agent_id, target}

      Enum.any?(~w(wait_deadline llm_retry capability_deadline runtime_wait), &(&1 in reasons)) ->
        :keep

      true ->
        :stale
    end
  end

  defp wait_due?(wait, now_ms) when is_map(wait) do
    case wait["deadline_ms"] || wait[:deadline_ms] do
      deadline_ms when is_integer(deadline_ms) -> deadline_ms <= now_ms
      _ -> false
    end
  end

  defp wait_due?(_wait, _now_ms), do: false

  defp lane_order(:eager), do: [:eager, :deferred]
  defp lane_order(:deferred), do: [:deferred, :eager]
  defp normalize_lane(:deferred), do: :deferred
  defp normalize_lane(_lane), do: :eager
  defp successor_lane(:eager, _fallback), do: :deferred
  defp successor_lane(:deferred, _fallback), do: :eager
  defp successor_lane(nil, fallback), do: fallback

  defp telemetry_outcome(%{failed: failed}) when failed > 0, do: "error"

  defp telemetry_outcome(%{unproven_retained: retained}) when retained > 0,
    do: "retained"

  defp telemetry_outcome(_summary), do: "ok"

  defp emit_notification_admission(outcome) do
    Salix.Telemetry.emit_operation(
      "salix_agent",
      "session_work_notification_admission",
      "system",
      outcome,
      0
    )
  end

  defp emit_notification_wake(outcome, started_at) do
    Salix.Telemetry.emit_operation(
      "salix_agent",
      "session_work_notification_wake",
      "system",
      outcome,
      System.monotonic_time() - started_at
    )
  end

  defp lane_cursor(state, :eager), do: state.next
  defp lane_cursor(state, :deferred), do: state.deferred_next
  defp put_lane_cursor(state, :eager, cursor), do: %{state | next: cursor}
  defp put_lane_cursor(state, :deferred, cursor), do: %{state | deferred_next: cursor}

  defp positive_integer_option(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer_option(_value, default), do: default

  defp valid_candidate_token?(nil), do: true

  defp valid_candidate_token?(token),
    do: is_binary(token) and token != "" and byte_size(token) <= 512

  defp maybe_put_cursor(opts, token) when is_binary(token) and token != "",
    do: Keyword.put(opts, :continuation_token, token)

  defp maybe_put_cursor(opts, _token), do: opts
end
