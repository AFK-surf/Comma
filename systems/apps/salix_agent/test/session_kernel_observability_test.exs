defmodule SalixAgent.SessionKernelObservabilityTest do
  use ExUnit.Case, async: false
  alias SalixAgent.InternalSession.State
  alias SalixAgent.TestSupport.SessionData
  @reporter Module.concat(__MODULE__, Reporter)

  test "real kernel results reach the shared scrape without payload labels" do
    {:ok, _} = Application.ensure_all_started(:telemetry)

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: @reporter, metrics: Salix.Telemetry.metrics(), start_async: false}
    )

    state = %State{agent_id: "private-agent", status: :active, activity_status: :thinking}

    assert %{name: "private-content"} =
             SessionData.apply_event(
               state,
               %{"type" => "session_update", "name" => "private-content"}
             )

    assert_raise ArgumentError, fn ->
      SessionData.apply_event(state, %{"unknown" => %URI{}})
    end

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~
             ~s(component="salix_agent",operation="session_kernel",outcome="ok",surface="system")

    assert scrape =~
             ~s(component="salix_agent",operation="session_kernel",outcome="error",surface="system")

    assert scrape =~ "salix_operations_duration_seconds_bucket"
    refute scrape =~ "private-agent"
    refute scrape =~ "private-content"

    stop_supervised!(@reporter)
    assert SessionData.apply_event(state, %{}) == state

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:salix, :operation, :stop],
        fn _, _, _, _ -> raise "failed telemetry handler" end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert SessionData.apply_event(state, %{}) == state
  end
end
