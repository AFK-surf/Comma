defmodule SalixAgent.SessionWorkRecoveryTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  import ExUnit.CaptureLog

  alias SalixAgent.SessionWorkRecovery

  setup do
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    :ok
  end

  test "coalesces concurrent requests and rotates after the last attempted lane" do
    owner = SystemsRuntime.Proc.self()

    sweep_fn = fn opts ->
      SystemsRuntime.Proc.send(owner, {:session_work_sweep, SystemsRuntime.Proc.self(), opts})

      SystemsRuntime.Proc.receive do
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
    settle_receive({:session_work_sweep, first_task, first_opts})
    assert first_opts[:session_work_max_keys] == 7
    assert first_opts[:session_work_cursor] == nil
    assert first_opts[:deferred_session_work_cursor] == nil
    assert first_opts[:session_work_start_lane] == :eager

    assert :ok = SessionWorkRecovery.request_sweep(worker)
    assert :ok = SessionWorkRecovery.request_sweep(worker)

    SystemsRuntime.Proc.send(
      first_task,
      {:finish_session_work_sweep,
       summary(
         next: "eager-cursor",
         deferred_next: "deferred-cursor",
         last_attempted_lane: :eager
       )}
    )

    settle_receive({:session_work_sweep, second_task, second_opts})
    assert second_opts[:session_work_cursor] == "eager-cursor"
    assert second_opts[:deferred_session_work_cursor] == "deferred-cursor"
    assert second_opts[:session_work_start_lane] == :deferred

    SystemsRuntime.Proc.send(second_task, {:finish_session_work_sweep, summary()})
    assert eventually(fn -> :sys.get_state(worker, :infinity).task == nil end)
    settle_refute_receive({:session_work_sweep, _third_task, _third_opts}, 50)
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

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)
end
