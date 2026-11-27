defmodule SalixAgent.SessionHistorySupervisorTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixAgent.SessionHistory.Supervisor, as: HistorySupervisor

  # Only the Agent's ring node indexes its Sessions, so history work on a node
  # must come back after its supervisor fails.
  test "the history supervisor restarts after it fails" do
    # The test configuration turns history work off; this test starts it.
    old = SystemsRuntime.get_env(:salix_agent, :session_history_enabled)
    SystemsRuntime.put_env(:salix_agent, :session_history_enabled, true)
    on_exit(fn -> SystemsRuntime.put_env(:salix_agent, :session_history_enabled, old) end)
    [spec] = HistorySupervisor.children()
    start_supervised!(spec)
    first = Process.whereis(HistorySupervisor)
    assert is_pid(first)

    # A supervisor fails by stopping its children and then exiting, as it
    # does when a child exceeds its restart intensity.
    :ok = SystemsRuntime.Supervisor.stop(first, :crashed)

    settle_until(fn ->
      case Process.whereis(HistorySupervisor) do
        pid when is_pid(pid) and pid != first -> true
        _ -> false
      end
    end)

    second = Process.whereis(HistorySupervisor)
    assert is_pid(second) and second != first
    assert is_pid(Process.whereis(SalixAgent.SessionHistory.Worker))
  end
end
