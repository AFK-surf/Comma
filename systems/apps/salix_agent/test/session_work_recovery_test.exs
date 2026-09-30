defmodule SalixAgent.SessionWorkRecoveryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SalixAgent.SessionWorkRecovery

  setup do
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    :ok
  end

  test "reports a missing worker instead of silently dropping the request" do
    assert {:error, :not_running} =
             SessionWorkRecovery.request_sweep(:missing_session_work_recovery_test)
  end

  test "coalesces concurrent requests and rotates after the last attempted lane" do
    owner = self()

    sweep_fn = fn opts ->
      send(owner, {:session_work_sweep, self(), opts})

      receive do
        {:finish_session_work_sweep, result} -> result
      end
    end

    worker =
      start_supervised!(
        {SessionWorkRecovery,
         name: nil,
         task_supervisor: SalixAgent.TaskSup,
         sweep_fn: sweep_fn,
         session_work_max_keys: 7}
      )

    assert :ok = SessionWorkRecovery.request_sweep(worker)
    assert_receive {:session_work_sweep, first_task, first_opts}
    assert first_opts[:session_work_max_keys] == 7
    assert first_opts[:session_work_cursor] == nil
    assert first_opts[:deferred_session_work_cursor] == nil
    assert first_opts[:session_work_start_lane] == :eager

    assert :ok = SessionWorkRecovery.request_sweep(worker)
    assert :ok = SessionWorkRecovery.request_sweep(worker)

    send(
      first_task,
      {:finish_session_work_sweep,
       summary(
         next: "eager-cursor",
         deferred_next: "deferred-cursor",
         last_attempted_lane: :eager
       )}
    )

    assert_receive {:session_work_sweep, second_task, second_opts}
    assert second_opts[:session_work_cursor] == "eager-cursor"
    assert second_opts[:deferred_session_work_cursor] == "deferred-cursor"
    assert second_opts[:session_work_start_lane] == :deferred

    send(second_task, {:finish_session_work_sweep, summary()})
    assert eventually(fn -> :sys.get_state(worker).task == nil end)
    refute_receive {:session_work_sweep, _third_task, _third_opts}, 50
  end

  test "a crashed sweep resets cursors before the next request" do
    owner = self()

    sweep_fn = fn opts ->
      send(owner, {:session_work_sweep, self(), opts})

      receive do
        {:finish_session_work_sweep, result} -> result
      end
    end

    worker =
      start_supervised!(
        {SessionWorkRecovery, name: nil, task_supervisor: SalixAgent.TaskSup, sweep_fn: sweep_fn}
      )

    assert :ok = SessionWorkRecovery.request_sweep(worker)
    assert_receive {:session_work_sweep, first_task, _first_opts}

    send(
      first_task,
      {:finish_session_work_sweep, summary(next: "old-eager", last_attempted_lane: :eager)}
    )

    assert eventually(fn -> :sys.get_state(worker).cursor == "old-eager" end)

    assert :ok = SessionWorkRecovery.request_sweep(worker)
    assert_receive {:session_work_sweep, crashing_task, second_opts}
    assert second_opts[:session_work_cursor] == "old-eager"
    assert second_opts[:session_work_start_lane] == :deferred
    Process.exit(crashing_task, :kill)

    assert eventually(fn ->
             state = :sys.get_state(worker)

             state.task == nil and state.cursor == nil and state.deferred_cursor == nil and
               state.start_lane == :eager
           end)

    assert :ok = SessionWorkRecovery.request_sweep(worker)
    assert_receive {:session_work_sweep, final_task, final_opts}
    assert final_opts[:session_work_cursor] == nil
    assert final_opts[:deferred_session_work_cursor] == nil
    assert final_opts[:session_work_start_lane] == :eager
    send(final_task, {:finish_session_work_sweep, summary()})
  end

  test "notification wakes are bounded and a pending durable sweep cannot starve" do
    owner = self()

    wake_fn = fn agent_id, target, timeout ->
      send(owner, {:notification_wake, self(), agent_id, target, timeout})

      receive do
        :finish_notification_wake -> :ok
      end
    end

    sweep_fn = fn opts ->
      send(owner, {:session_work_sweep, self(), opts})

      receive do
        {:finish_session_work_sweep, result} -> result
      end
    end

    worker =
      start_supervised!(
        {SessionWorkRecovery,
         name: nil,
         task_supervisor: SalixAgent.TaskSup,
         sweep_fn: sweep_fn,
         wake_fn: wake_fn,
         notification_queue_limit: 1,
         notification_wake_timeout: 321}
      )

    first = %{runtime: :internal, session_id: "ses1_0000000000000001911"}
    second = %{runtime: :external, session_id: "ses1_0000000000000001912"}
    overflow = %{runtime: :internal, session_id: "ses1_0000000000000001913"}

    assert :ok =
             SessionWorkRecovery.request_wake("agent-one", first,
               server: worker,
               candidate_token: "token-one"
             )

    assert_receive {:notification_wake, first_task, "agent-one", ^first, 321}

    # The in-flight key is deduplicated. One different key is queued; the next
    # different key exceeds the explicit bound and safely falls back to the
    # durable candidate sweep.
    assert :ok =
             SessionWorkRecovery.request_wake("agent-one", first,
               server: worker,
               candidate_token: "token-one"
             )

    assert :ok =
             SessionWorkRecovery.request_wake("agent-two", second,
               server: worker,
               candidate_token: "token-two"
             )

    assert :ok =
             SessionWorkRecovery.request_wake("agent-three", overflow,
               server: worker,
               candidate_token: "token-three"
             )

    assert eventually(fn ->
             state = :sys.get_state(worker)

             :queue.len(state.notification_queue) == 1 and
               MapSet.size(state.notification_keys) == 2
           end)

    assert :ok = SessionWorkRecovery.request_sweep(worker)
    send(first_task, :finish_notification_wake)

    # The completeness owner runs before another lossy fast hint.
    assert_receive {:session_work_sweep, sweep_task, _opts}
    refute_receive {:notification_wake, _task, "agent-two", ^second, 321}, 50
    send(sweep_task, {:finish_session_work_sweep, summary()})

    assert_receive {:notification_wake, second_task, "agent-two", ^second, 321}
    send(second_task, :finish_notification_wake)

    assert eventually(fn ->
             state = :sys.get_state(worker)

             state.task == nil and :queue.is_empty(state.notification_queue) and
               MapSet.size(state.notification_keys) == 0
           end)

    refute_receive {:notification_wake, _task, "agent-three", ^overflow, 321}, 50
  end

  test "emits bounded recovery telemetry without coupling sweep correctness to handlers" do
    owner = self()
    handler_id = "session-work-recovery-failure-isolation-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:salix, :operation, :stop],
        fn event, measurements, metadata, receiver ->
          if metadata.operation == "session_work_recovery" do
            send(receiver, {:session_work_recovery_telemetry, event, measurements, metadata})
            raise "observer failure must not fail recovery"
          end
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    summary =
      capture_log(fn ->
        send(owner, {:sweep_result, SessionWorkRecovery.sweep(session_work_max_keys: 1)})
      end)

    assert is_binary(summary)
    assert_receive {:sweep_result, %{failed: 0, unproven_retained: 0}}

    assert_receive {:session_work_recovery_telemetry, [:salix, :operation, :stop],
                    %{duration: duration},
                    %{
                      component: "salix_cluster",
                      operation: "session_work_recovery",
                      surface: "system",
                      outcome: "ok"
                    }}

    assert is_integer(duration) and duration >= 0
  end

  defp summary(overrides \\ []) do
    Map.merge(
      %{
        rewoken: [],
        scanned: 0,
        cleaned: 0,
        failed: 0,
        unproven_retained: 0,
        next: nil,
        deferred_next: nil,
        last_attempted_lane: nil
      },
      Map.new(overrides)
    )
  end

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end
end
