defmodule SalixStore.InflightTest do
  @moduledoc """
  The stall-visibility contract: an operation still WAITING on the backend is
  visible in the in-flight table for exactly as long as it runs, the poller
  publishes zero-filled per-operation gauges from a scan (never from events —
  during a stall there are none), and rows from dead processes cannot pin the
  gauges high.
  """
  use SystemsClock.Case, async: false

  use SystemsClock.Test, scope: ["Elixir.SalixStore"]
  alias SalixStore.Inflight
  alias SalixStore.S3.Fake

  setup do
    Fake.reset()
    :ok
  end

  test "a slow backend call is visible in-flight for its full duration, then gone" do
    Fake.set_fault({:delay, 300, :get, :any})

    task = SystemsRuntime.Task.async(fn -> SalixStore.S3.get("inflight/slow", []) end)
    SystemsClock.sleep(80)

    # The table is the node's: the application's own workers queue behind the
    # delayed fake too, so the call under test is read by its process.
    assert %{"store_get" => {1, oldest_ms}} = Inflight.snapshot_for(task.pid)
    assert oldest_ms > 0

    {:ok, _} = settle_until(fn -> SystemsRuntime.Task.yield(task, 0) end)

    assert %{"store_get" => {0, 0}} = Inflight.snapshot_for(task.pid)
  end
end
