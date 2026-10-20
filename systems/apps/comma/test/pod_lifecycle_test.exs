defmodule Comma.PodLifecycleTest do
  use SystemsClock.Case, async: false

  use SystemsClock.Test, scope: ["Elixir.SalixStore", "Elixir.Comma"]
  alias Comma.PodLifecycle

  setup do
    PodLifecycle.reset_for_test()

    on_exit(fn ->
      PodLifecycle.reset_for_test()

      if SystemsRuntime.Proc.whereis(Comma.Oban) do
        for queue <- [:comma_external, :comma_discovery] do
          Oban.resume_queue(Comma.Oban, queue: queue, local_only: true)
        end
      end
    end)

    :ok
  end

  test "begin_drain is local, immediate, and does not affect liveness" do
    assert PodLifecycle.live() == :ok
    assert PodLifecycle.accepting_requests?()

    assert :ok = PodLifecycle.begin_drain()

    assert PodLifecycle.live() == :ok
    refute PodLifecycle.accepting_requests?()
    assert {:error, :draining} = PodLifecycle.ready(:salix)
    assert {:error, :draining} = PodLifecycle.ready(:bridge_for_teams)
    assert {:error, :draining} = PodLifecycle.ready(:comma_product)
  end

  test "unknown and disabled surfaces fail closed" do
    PodLifecycle.boot([:salix])

    assert {:error, :unknown_surface} = PodLifecycle.ready(:unknown)
    assert {:error, :subsystem_disabled} = PodLifecycle.ready(:comma_product)
  end

  test "an unsealed meeting projection does not block the projection-first fleet rollout" do
    assert_eventually(fn -> PodLifecycle.ready(:salix) == :ok end)

    SalixStore.Repo.query!(
      "DELETE FROM salix_cutover_markers WHERE name = 'meeting_group_projection_v1'"
    )

    :ok = SalixStore.MeetingGroupProjectionReadiness.refresh()

    on_exit(fn ->
      :ok = SalixStore.MeetingGroupProjections.mark_ready(%{"mode" => "test-restore"})
      :ok = SalixStore.MeetingGroupProjectionReadiness.refresh()
    end)

    refute SalixStore.MeetingGroupProjectionReadiness.ready?()
    assert :ok = PodLifecycle.ready(:salix)
  end

  test "preStop rejects requests and quiets local jobs before propagation and Salix drain" do
    handler = "pod-lifecycle-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    parent = SystemsRuntime.Proc.self()

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:comma, :pod_lifecycle, :pre_stop],
        fn _event, _measurements, metadata, _config ->
          SystemsRuntime.Proc.send(parent, {:pre_stop_stage, metadata.stage})
        end,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)

    task =
      SystemsRuntime.Task.async(fn ->
        PodLifecycle.pre_stop(propagation_ms: 100, job_grace_ms: 0)
      end)

    settle_receive({:pre_stop_stage, :readiness_withdrawn})
    settle_receive({:pre_stop_stage, :jobs_quiet})
    refute PodLifecycle.accepting_requests?()

    if SystemsRuntime.Proc.whereis(Comma.Oban) do
      assert %{paused: true} = Oban.check_queue(Comma.Oban, queue: :comma_external)
      assert %{paused: true} = Oban.check_queue(Comma.Oban, queue: :comma_discovery)
    end

    assert SystemsClock.yield(task, 20) == nil
    settle_receive({:pre_stop_stage, :job_grace_complete})
    settle_receive({:pre_stop_stage, :salix_drain_complete})
    settle_receive({:pre_stop_stage, :connector_drain_complete})
    assert {:ok, _result} = SystemsClock.yield(task, 5_000)
  end

  test "product-only preStop treats the disabled Salix drain as a bounded no-op" do
    PodLifecycle.boot([:comma_product])

    assert {:ok, %{drained: [], handed_off: 0, failed: []}} =
             PodLifecycle.pre_stop(propagation_ms: 0, job_grace_ms: 0)

    refute PodLifecycle.accepting_requests?()
    assert {:error, :draining} = PodLifecycle.ready(:salix)
  end

  defp assert_eventually(fun, attempts \\ 1500)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      SystemsClock.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())
end
