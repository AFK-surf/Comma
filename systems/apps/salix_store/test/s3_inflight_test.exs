defmodule SalixStore.InflightTest do
  @moduledoc """
  The stall-visibility contract: an operation still WAITING on the backend is
  visible in the in-flight table for exactly as long as it runs, the poller
  publishes zero-filled per-operation gauges from a scan (never from events —
  during a stall there are none), and rows from dead processes cannot pin the
  gauges high.
  """
  use ExUnit.Case, async: false

  alias SalixStore.Inflight
  alias SalixStore.S3.Fake

  setup do
    Fake.reset()
    :ok
  end

  test "a slow backend call is visible in-flight for its full duration, then gone" do
    Fake.set_fault({:delay, 300, :get, :any})

    task = Task.async(fn -> SalixStore.S3.get("inflight/slow", []) end)
    Process.sleep(80)

    assert %{"store_get" => {1, oldest_ms}} = Inflight.snapshot()
    assert oldest_ms > 0

    _ = Task.await(task, 5_000)

    assert %{"store_get" => {0, 0}} = Inflight.snapshot()
  end

  test "a raising operation still clears its row" do
    assert_raise RuntimeError, fn ->
      Inflight.track("store_put", fn -> raise "boom" end)
    end

    assert %{"store_put" => {0, 0}} = Inflight.snapshot()
  end

  test "an ArgumentError raised BY the operation propagates and runs it exactly once" do
    # The tracking guards degrade a MISSING TABLE to an untracked run; they
    # must never catch the operation's own ArgumentError and re-run it — for
    # a store write that would be a double-execution.
    counter = :counters.new(1, [])

    assert_raise ArgumentError, fn ->
      Inflight.track("store_put", fn ->
        :counters.add(counter, 1, 1)
        raise ArgumentError, "from the operation"
      end)
    end

    assert :counters.get(counter, 1) == 1
    assert %{"store_put" => {0, 0}} = Inflight.snapshot()
  end

  test "rows from dead processes are dropped at scan time" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}

    :ets.insert(
      Inflight.table(),
      {make_ref(), "store_get", dead, System.monotonic_time(:millisecond) - 5_000}
    )

    assert %{"store_get" => {0, 0}} = Inflight.snapshot()
    assert :ets.info(Inflight.table(), :size) == 0
  end

  test "the poller publishes zero-filled gauges for every known operation" do
    handler_id = "inflight-test-#{inspect(self())}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:salix, :store, :inflight],
        fn _event, measurements, metadata, _config ->
          send(parent, {:inflight_event, metadata.operation, measurements})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Inflight.Poller.publish()

    for operation <- Inflight.operations() do
      assert_receive {:inflight_event, ^operation, %{count: 0, oldest_age_seconds: 0.0}}
    end
  end

  test "the poller reports a positive oldest age for a stalled operation" do
    handler_id = "inflight-age-test-#{inspect(self())}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:salix, :store, :inflight],
        fn _event, measurements, metadata, _config ->
          send(parent, {:inflight_event, metadata.operation, measurements})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Fake.set_fault({:delay, 400, :put, :any})
    task = Task.async(fn -> SalixStore.S3.put("inflight/stalled", "body", []) end)
    Process.sleep(100)

    Inflight.Poller.publish()

    assert_receive {:inflight_event, "store_put", %{count: 1, oldest_age_seconds: age}}
    assert age > 0

    _ = Task.await(task, 5_000)
  end
end
