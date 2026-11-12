defmodule SalixAgent.SessionWorkRecovery do
  @moduledoc """
  Bounded dispatch of committed Session work and capability deadlines.

  The existing supervised worker coalesces wakes and periodic sweep requests.
  Session reservations only suppress duplicate hints. Placement and the Session
  owner retain execution authority. Capability settlement uses its existing owner.
  """

  use SystemsRuntime.Server
  require Logger

  alias SalixAgent.CapabilityRequests
  alias SalixStore.Repo

  # These are the existing Session scheduling rules, independent of storage.
  @deferred_or_external_reasons ~w(external_callback_tool_call capability_deadline wait_deadline llm_retry provider_cutover_parked)

  def immediate_recovery_reasons?(reasons) when is_list(reasons),
    do: Enum.any?(reasons, &(to_string(&1) not in @deferred_or_external_reasons))

  def immediate_recovery_reasons?(_reasons), do: false

  def recover_after_ms(reasons, wait) when is_list(reasons) do
    reasons = Enum.map(reasons, &to_string/1)
    eager = reasons -- @deferred_or_external_reasons
    deadline = if is_map(wait), do: wait["deadline_ms"] || wait[:deadline_ms]
    deferred? = Enum.any?(~w(wait_deadline llm_retry capability_deadline), &(&1 in reasons))

    case {eager, deferred?, deadline} do
      {[], true, deadline} when is_integer(deadline) -> deadline
      {[_ | _], true, _} -> if "capability_deadline" in reasons, do: 0
      _ -> nil
    end
  end

  def recover_after_ms(_reasons, _wait), do: nil

  @doc "Read one page of an Agent's committed Session work on owner startup."
  def local_work_page(agent_id, cursor, limit) do
    with {:ok, %{rows: rows}} <-
           SalixStore.Repo.query(
             """
             SELECT s.session_id, s.work_reasons, a.role, a.router_session_id
             FROM salix_sessions s JOIN salix_agents a USING (agent_id)
             WHERE s.agent_id = $1 AND s.birth_kind = 'internal'
               AND s.deleted_at IS NULL AND s.control_payload IS NOT NULL
               AND cardinality(s.work_reasons) > 0 AND a.config_revision > 0
               AND ($2::text IS NULL OR s.session_id > $2)
             ORDER BY s.session_id LIMIT $3
             """,
             [agent_id, cursor, limit]
           ) do
      targets =
        for [session_id, reasons, role, canonical] <- rows,
            not (role == "router" and SalixStore.Ids.valid_session_id?(canonical) and
                   canonical != session_id),
            immediate_recovery_reasons?(reasons),
            do: %{runtime: :internal, session_id: session_id}

      next = if length(rows) == limit, do: rows |> List.last() |> hd()
      {:ok, targets, next}
    end
  end

  @default_page_size 100
  @default_wake_timeout_ms 500
  @default_page_wake_budget_ms 2_000

  @lanes [:sessions, :capability_expiry, :capability_delivery]
  @type summary :: map()

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> SystemsRuntime.Server.start_link(__MODULE__, opts)
      name -> SystemsRuntime.Server.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Request one bounded sweep without blocking the caller."
  @spec request_sweep(GenServer.server()) :: :ok | {:error, :not_running}
  def request_sweep(server \\ __MODULE__) do
    case SystemsRuntime.Server.whereis(server) do
      nil ->
        Logger.warning("session-work recovery worker is not running")
        {:error, :not_running}

      _pid ->
        SystemsRuntime.Server.cast(server, :sweep)
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
             runtime == :internal and
             is_binary(session_id) and session_id != "" and byte_size(session_id) <= 256 do
    server = Keyword.get(opts, :server, __MODULE__)
    revision = Keyword.get(opts, :revision)

    if valid_revision?(revision) do
      key = {agent_id, runtime, session_id}
      target = %{runtime: runtime, session_id: session_id}

      case SystemsRuntime.Server.whereis(server) do
        nil ->
          Logger.warning("session-work recovery worker is not running")
          {:error, :not_running}

        _pid ->
          SystemsRuntime.Server.cast(server, {:wake, key, agent_id, target})
          :ok
      end
    else
      {:error, :invalid_target}
    end
  end

  def request_wake(_agent_id, _target, _opts), do: {:error, :invalid_target}

  @doc "Run one bounded pass over committed due work."
  def sweep(opts \\ []) do
    started_at = SystemsClock.monotonic_time()
    limit = min(positive_integer_option(opts[:session_work_max_keys], @default_page_size), 128)
    timeout = positive_integer_option(opts[:session_work_wake_timeout], @default_wake_timeout_ms)

    budget =
      positive_integer_option(opts[:session_work_page_wake_budget], @default_page_wake_budget_ms)

    deadline = SystemsClock.monotonic_time(:millisecond) + budget
    cursors = Keyword.get(opts, :cursors, %{})
    start_lane = Keyword.get(opts, :start_lane, :sessions)
    index = Enum.find_index(@lanes, &(&1 == start_lane)) || 0
    lanes = Enum.drop(@lanes, index) ++ Enum.take(@lanes, index)

    result =
      Enum.reduce_while(lanes, %{empty_summary() | cursors: cursors}, fn lane, acc ->
        if SystemsClock.monotonic_time(:millisecond) >= deadline do
          {:halt, acc}
        else
          acc = %{acc | last_attempted_lane: lane}

          case due_page(lane, Map.get(acc.cursors, lane), limit) do
            {:ok, records, eof?} ->
              {acc, cursor, stopped?} =
                process_page(records, lane, acc, Map.get(acc.cursors, lane), deadline, timeout)

              cursor = if eof? and not stopped?, do: nil, else: cursor
              {:cont, %{acc | cursors: Map.put(acc.cursors, lane, cursor)}}

            {:error, reason} ->
              Logger.warning("due work scan failed: #{inspect({lane, reason})}")
              {:cont, %{acc | failed: acc.failed + 1}}
          end
        end
      end)

    result = %{result | rewoken: Enum.uniq(Enum.reverse(result.rewoken))}

    Salix.Telemetry.emit_operation(
      "salix_cluster",
      "session_work_recovery",
      "system",
      if(result.failed > 0, do: "error", else: "ok"),
      SystemsClock.monotonic_time() - started_at
    )

    result
  end

  def empty_summary do
    %{rewoken: [], scanned: 0, failed: 0, cursors: %{}, last_attempted_lane: nil}
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       cursors: %{},
       start_lane: :sessions,
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
        # The committed Session due row already exists. Drop only this lossy hint;
        # periodic lease-driven recovery keeps notification pressure from
        # becoming either an unbounded queue or an unbounded sweep loop.
        emit_notification_admission("over_budget")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {ref, %{cursors: cursors, last_attempted_lane: lane} = result},
        %{task: %Task{ref: ref}, task_kind: :sweep} = state
      ) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])
    if result.failed > 0, do: Logger.warning("due work recovery: #{result.failed} failures")
    next = Enum.at(@lanes, rem((Enum.find_index(@lanes, &(&1 == lane)) || 0) + 1, length(@lanes)))
    state = %{state | cursors: cursors, start_lane: next, task: nil, task_kind: nil}
    {:noreply, maybe_start_next(state)}
  end

  def handle_info(
        {ref, result},
        %{task: %Task{ref: ref}, task_kind: {:notification_wake, key, started_at}} = state
      ) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])

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
    SystemsRuntime.Proc.demonitor(ref, [:flush])
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
      cursors: state.cursors,
      start_lane: state.start_lane
    ]

    task =
      SystemsRuntime.TaskSupervisor.async_nolink(state.task_supervisor, fn ->
        state.sweep_fn.(opts)
      end)

    %{state | task: task, task_kind: :sweep, pending: false}
  end

  defp start_notification_wake(state) do
    {{:value, {key, agent_id, target}}, queue} = :queue.out(state.notification_queue)
    started_at = SystemsClock.monotonic_time()

    task =
      SystemsRuntime.TaskSupervisor.async_nolink(state.task_supervisor, fn ->
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
    %{state | task: nil, task_kind: nil}
  end

  defp due_page(:sessions, cursor, limit) do
    {at, agent, session} = cursor || {nil, "", ""}

    case Repo.query(
           """
           WITH pending AS (
             SELECT s.agent_id, s.session_id
             FROM salix_sessions s JOIN salix_agents a USING (agent_id)
             WHERE s.next_run_at <= clock_timestamp() AND s.deleted_at IS NULL
               AND a.config_revision > 0 AND a.archived_at IS NULL
               AND (s.dispatch_after IS NULL OR s.dispatch_after <= clock_timestamp())
               AND ($1::timestamptz IS NULL OR (s.next_run_at,s.agent_id,s.session_id) > ($1,$2,$3))
             ORDER BY s.next_run_at,s.agent_id,s.session_id
             LIMIT $4 FOR UPDATE OF s SKIP LOCKED
           ), claimed AS (
             UPDATE salix_sessions s SET dispatch_after = clock_timestamp() + interval '10 seconds'
             FROM pending p WHERE s.agent_id=p.agent_id AND s.session_id=p.session_id
             RETURNING s.agent_id,s.session_id,s.next_run_at
           )
           SELECT c.agent_id,c.session_id,c.next_run_at,a.role,a.router_session_id
           FROM claimed c JOIN salix_agents a USING (agent_id)
           ORDER BY c.next_run_at,c.agent_id,c.session_id
           """,
           [at, agent, session, limit]
         ) do
      {:ok, %{rows: rows}} ->
        records =
          Enum.map(rows, fn [agent, session, at, role, canonical] ->
            %{
              agent_id: agent,
              session_id: session,
              cursor: {at, agent, session},
              retired:
                role == "router" and SalixStore.Ids.valid_session_id?(canonical) and
                  canonical != session
            }
          end)

        {:ok, records, length(rows) < limit}

      error ->
        error
    end
  end

  defp due_page(lane, cursor, limit) do
    result =
      case lane do
        :capability_expiry ->
          CapabilityRequests.due_location_requests(cursor: cursor, limit: limit)

        :capability_delivery ->
          CapabilityRequests.due_result_deliveries(cursor: cursor, limit: limit)
      end

    case result do
      {:ok, %{items: items, next: next}} ->
        records =
          Enum.map(items, fn item ->
            request = item.record

            at =
              if lane == :capability_expiry,
                do: DateTime.from_unix!(request["expires_at"], :second),
                else: item.due_at

            %{request: request, cursor: {at, request["group_id"], request["request_id"]}}
          end)

        {:ok, records, is_nil(next)}

      error ->
        error
    end
  end

  defp process_page([], _lane, stats, cursor, _deadline, _timeout), do: {stats, cursor, false}

  defp process_page([record | rest], lane, stats, cursor, deadline, timeout) do
    remaining = deadline - SystemsClock.monotonic_time(:millisecond)

    if remaining <= 0 do
      {stats, cursor, true}
    else
      result = dispatch(lane, record, min(timeout, remaining))
      stats = %{stats | scanned: stats.scanned + 1}

      stats =
        case {lane, result} do
          {:sessions, :ok} -> %{stats | rewoken: [record.agent_id | stats.rewoken]}
          {_, :ok} -> stats
          {_, :retired} -> stats
          _ -> %{stats | failed: stats.failed + 1}
        end

      process_page(rest, lane, stats, record.cursor, deadline, timeout)
    end
  end

  defp dispatch(:sessions, %{retired: true}, _timeout), do: :retired

  defp dispatch(:sessions, record, timeout),
    do:
      wake_exact_target(
        record.agent_id,
        %{runtime: :internal, session_id: record.session_id},
        timeout
      )

  defp dispatch(lane, %{request: request}, timeout) do
    args = [request["group_id"], request["request_id"], request["tenant_id"], [timeout: timeout]]

    case lane do
      :capability_expiry -> apply(CapabilityRequests, :expire_location, args)
      :capability_delivery -> apply(CapabilityRequests, :retry_result_delivery, args)
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :error, {:erpc, :timeout} -> {:error, :timeout}
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
      SystemsClock.monotonic_time() - started_at
    )
  end

  defp positive_integer_option(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer_option(_value, default), do: default

  defp valid_revision?(nil), do: true

  defp valid_revision?(revision),
    do: is_integer(revision) and revision >= 0
end
