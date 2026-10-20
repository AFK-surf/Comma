defmodule SalixAnalytics.TypedSinkWorkerTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.SalixStore", "Elixir.SalixAnalytics"]
  alias SalixAnalytics.TypedSinkWorker

  defmodule BlockedSink do
    def insert(rows) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.whereis(:typed_sink_test_owner),
        {:writing, SystemsRuntime.Proc.self(), rows}
      )

      SystemsRuntime.Proc.receive do
        :release -> {:ok, length(rows)}
        :fail -> {:error, :offline}
      end
    end
  end

  setup context do
    Process.register(SystemsRuntime.Proc.self(), :typed_sink_test_owner)

    worker =
      start_supervised!(
        Supervisor.child_spec(
          {TypedSinkWorker,
           name: :bounded_sink_test, sink: BlockedSink, max_buffer: 3, batch_size: 2, flush_ms: 5},
          shutdown: if(context[:short_shutdown], do: 50, else: 500)
        )
      )

    on_exit(fn ->
      if pid = SystemsRuntime.Proc.whereis(:bounded_sink_test),
        do: SystemsRuntime.Proc.exit(pid, :kill)
    end)

    %{worker: worker}
  end

  test "slow ClickHouse does not block admission, and concurrent producers stay bounded", %{
    worker: worker
  } do
    assert :ok = TypedSinkWorker.enqueue([%{id: 0}], server: :bounded_sink_test)
    settle_receive({:writing, ^worker, [%{id: 0}]})

    tasks =
      for id <- 1..40 do
        SystemsRuntime.Task.async(fn ->
          TypedSinkWorker.enqueue([%{id: id}], server: :bounded_sink_test)
        end)
      end

    results = Enum.map(tasks, &settled_await/1)
    assert Enum.count(results, &(&1 == :ok)) == 2
    assert Enum.count(results, &(&1 == {:error, :queue_full})) == 38
    assert :ets.info(:bounded_sink_test, :size) == 7
    assert {:message_queue_len, 0} = Process.info(worker, :message_queue_len)

    SystemsRuntime.Proc.send(worker, :release)
    settle_receive({:writing, ^worker, rows})
    assert length(rows) == 2
    SystemsRuntime.Proc.send(worker, :release)
  end

  test "worker failure loses only the disposable buffer and replacement accepts rows", %{
    worker: worker
  } do
    assert :ok = TypedSinkWorker.enqueue([%{id: 1}], server: :bounded_sink_test)
    settle_receive({:writing, ^worker, _})
    ref = SystemsRuntime.Proc.monitor(worker)
    SystemsRuntime.Proc.exit(worker, :kill)
    settle_receive({:DOWN, ^ref, :process, ^worker, :killed})
    stop_supervised!(:bounded_sink_test)

    assert {:error, :unavailable} =
             TypedSinkWorker.enqueue([%{id: 2}], server: :bounded_sink_test)

    replacement =
      start_supervised!(
        {TypedSinkWorker, name: :bounded_sink_test, sink: BlockedSink, flush_ms: 5}
      )

    assert :ok = TypedSinkWorker.enqueue([%{id: 3}], server: :bounded_sink_test)
    settle_receive({:writing, ^replacement, [%{id: 3}]})
    SystemsRuntime.Proc.send(replacement, :release)
  end

  test "graceful shutdown drains all batches and rejects new rows", %{worker: worker} do
    assert :ok = TypedSinkWorker.enqueue([%{id: 1}], server: :bounded_sink_test)
    settle_receive({:writing, ^worker, [%{id: 1}]})
    assert :ok = TypedSinkWorker.enqueue([%{id: 2}, %{id: 3}], server: :bounded_sink_test)
    stopper = SystemsRuntime.Task.async(fn -> GenServer.stop(worker, :normal, 2_000) end)
    SystemsRuntime.Proc.send(worker, :release)
    settle_receive({:writing, ^worker, rows})
    assert Enum.map(rows, & &1.id) == [2, 3]

    assert {:error, :unavailable} =
             TypedSinkWorker.enqueue([%{id: 4}], server: :bounded_sink_test)

    SystemsRuntime.Proc.send(worker, :release)
    assert settled_await(stopper) == :ok
  end

  @tag :short_shutdown
  test "a blocked dependency cannot exceed the supervisor shutdown budget", %{worker: worker} do
    assert :ok = TypedSinkWorker.enqueue([%{id: 1}], server: :bounded_sink_test)
    settle_receive({:writing, ^worker, _})
    ref = SystemsRuntime.Proc.monitor(worker)
    stop_supervised!(:bounded_sink_test)
    settle_receive({:DOWN, ^ref, :process, ^worker, :killed})

    assert {:error, :unavailable} =
             TypedSinkWorker.enqueue([%{id: 2}], server: :bounded_sink_test)
  end

  test "slow telemetry handlers stay off the admission path", %{worker: worker} do
    owner = SystemsRuntime.Proc.self()
    handler = {__MODULE__, SystemsRuntime.Proc.make_ref()}

    # Block only this test's worker. The application's own TypedSinkWorker
    # emits the same event, and blocking it would stall every later caller.
    SystemsRuntime.Telemetry.attach(
      handler,
      [:salix, :reporting, :queue],
      fn _, _, _, _ ->
        if SystemsRuntime.Proc.self() == worker do
          SystemsRuntime.Proc.send(owner, {:handler, SystemsRuntime.Proc.self()})
          SystemsRuntime.Proc.receive(do: (:continue -> :ok))
        end
      end,
      nil
    )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)
    settle_receive({:handler, ^worker})

    task =
      SystemsRuntime.Task.async(fn ->
        TypedSinkWorker.enqueue([%{id: 1}], server: :bounded_sink_test)
      end)

    assert settled_await(task) == :ok
    SystemsRuntime.Telemetry.detach(handler)
    SystemsRuntime.Proc.send(worker, :continue)
    settle_receive({:writing, ^worker, _})
    SystemsRuntime.Proc.send(worker, :release)
  end
end
