defmodule SalixAgent.RouterRequestMonitorTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  alias SalixAgent.RouterRequestMonitor, as: Monitor

  setup do
    if SystemsRuntime.Proc.whereis(SalixAgent.Supervisor) do
      Supervisor.terminate_child(SalixAgent.Supervisor, Monitor)
      on_exit(fn -> Supervisor.restart_child(SalixAgent.Supervisor, Monitor) end)
    else
      if pid = SystemsRuntime.Proc.whereis(Monitor), do: GenServer.stop(pid)
    end

    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 1_000_000)
    start_supervised!({Monitor, clock: fn -> :atomics.get(clock, 1) end, interval: 60_000})
    Monitor.register("router", SystemsRuntime.Proc.self())
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
end
