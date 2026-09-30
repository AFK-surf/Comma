defmodule SalixAgent.RouterRequestMonitorTest do
  use ExUnit.Case, async: false
  alias SalixAgent.RouterRequestMonitor, as: Monitor

  setup do
    if Process.whereis(SalixAgent.Supervisor) do
      Supervisor.terminate_child(SalixAgent.Supervisor, Monitor)
      on_exit(fn -> Supervisor.restart_child(SalixAgent.Supervisor, Monitor) end)
    else
      if pid = Process.whereis(Monitor), do: GenServer.stop(pid)
    end

    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 1_000_000)
    start_supervised!({Monitor, clock: fn -> :atomics.get(clock, 1) end, interval: 60_000})
    Monitor.register("router", self())
    %{clock: clock}
  end

  defp enqueue(id, router \\ "router", role \\ "user", wake \\ true) do
    Monitor.enqueued(router, "session", [
      %{
        "type" => "queue_append",
        "kind" => "user_message",
        "wake" => wake,
        "payload" => %{"source_message_id" => id, "role" => role}
      }
    ])
  end

  test "independent observation reaches the shared scrape without private labels", %{clock: clock} do
    reporter = Module.concat(__MODULE__, Reporter)

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: reporter, metrics: Salix.Telemetry.metrics(), start_async: false}
    )

    enqueue("private-request")
    Monitor.sample()
    :atomics.put(clock, 1, 1_300_001)
    Monitor.sample()
    scrape = TelemetryMetricsPrometheus.Core.scrape(reporter)
    assert scrape =~ "salix_router_requests_stalled 1"
    refute scrape =~ "private-request"
    refute scrape =~ "agent_id"
    Monitor.started("router", "session", ["private-request"])
    Monitor.sample()
    assert TelemetryMetricsPrometheus.Core.scrape(reporter) =~ "salix_router_requests_stalled 0"
  end

  test "pending user input crosses the strict oldest boundary without another hold", %{
    clock: clock
  } do
    enqueue("one")
    assert Monitor.sample().stalled == 0
    Monitor.sample()
    :atomics.put(clock, 1, 1_300_000)
    assert Monitor.sample().stalled == 0
    Monitor.sample()
    :atomics.put(clock, 1, 1_300_001)
    assert Monitor.sample().stalled == 1
    Monitor.started("router", "session", ["one"])
    assert Monitor.sample().stalled == 0
  end

  test "new starts reset silence, continuations and unrelated Routers do not", %{clock: clock} do
    enqueue("old")
    enqueue("new")
    Monitor.register("healthy", self())
    enqueue("healthy-input", "healthy")
    Monitor.sample()
    :atomics.put(clock, 1, 1_299_999)
    Monitor.started("router", "session", ["new"])
    Monitor.started("healthy", "session", ["healthy-input"])
    Monitor.sample()
    :atomics.put(clock, 1, 1_300_001)
    assert Monitor.sample().stalled == 0
    Monitor.started("healthy", "session", ["healthy-input"])
    Monitor.started("router", "session", ["new"])
    Monitor.sample()
    :atomics.put(clock, 1, 1_599_999)
    assert Monitor.sample().stalled == 1
    Monitor.clear_session("router", "session")
    assert Monitor.sample().stalled == 0
  end

  test "non-user, no-wake context, and non-Router input do not page", %{clock: clock} do
    enqueue("assistant", "router", "assistant")
    enqueue("history", "router", "user", false)
    enqueue("worker-input", "worker")
    Monitor.sample()
    :atomics.put(clock, 1, 2_000_000)
    assert Monitor.sample().stalled == 0
  end

  test "blocked Router cannot block observation", %{clock: clock} do
    router =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(router, :kill) end)
    Monitor.register("blocked", router)
    enqueue("waiting", "blocked")
    Monitor.sample()
    :atomics.put(clock, 1, 1_300_001)
    assert Monitor.sample().stalled == 1
  end

  test "new traffic can restore owner registration after an observer restart", %{clock: clock} do
    enqueue("lost-before-restart")
    Monitor.sample()
    GenServer.stop(Monitor)
    # The supervised observer restarts; the role-owned delivery seam registers again.
    Process.sleep(10)
    Monitor.register("router", self())
    enqueue("new-after-restart")
    Monitor.sample()
    :atomics.put(clock, 1, 1_300_001)
    assert Monitor.sample().stalled == 1
  end

  test "duplicates preserve enqueue time and missing observer does not raise", %{clock: clock} do
    enqueue("same")
    Monitor.sample()
    :atomics.put(clock, 1, 1_200_000)
    enqueue("same")
    Monitor.sample()
    :atomics.put(clock, 1, 1_300_001)
    assert Monitor.sample().stalled == 1
    GenServer.stop(Monitor)
    assert enqueue("unobserved") == :ok
    assert Monitor.started("router", "session", ["unobserved"]) == :ok
    assert Monitor.register("other", self()) == :ok
  end
end
