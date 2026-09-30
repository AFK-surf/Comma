defmodule SalixAnalytics.TypedSinkWorkerTest do
  use ExUnit.Case, async: false
  alias SalixAnalytics.TypedSinkWorker

  defmodule BlockedSink do
    def insert(rows) do
      send(Process.whereis(:typed_sink_test_owner), {:writing, self(), rows})

      receive do
        :release -> {:ok, length(rows)}
        :fail -> {:error, :offline}
      end
    end
  end

  setup context do
    Process.register(self(), :typed_sink_test_owner)

    worker =
      start_supervised!(
        Supervisor.child_spec(
          {TypedSinkWorker,
           name: :bounded_sink_test, sink: BlockedSink, max_buffer: 3, batch_size: 2, flush_ms: 5},
          shutdown: if(context[:short_shutdown], do: 50, else: 500)
        )
      )

    on_exit(fn ->
      if pid = Process.whereis(:bounded_sink_test), do: Process.exit(pid, :kill)
    end)

    %{worker: worker}
  end

  test "slow ClickHouse does not block admission, and concurrent producers stay bounded", %{
    worker: worker
  } do
    assert :ok = TypedSinkWorker.enqueue([%{id: 0}], server: :bounded_sink_test)
    assert_receive {:writing, ^worker, [%{id: 0}]}

    tasks =
      for id <- 1..40 do
        Task.async(fn -> TypedSinkWorker.enqueue([%{id: id}], server: :bounded_sink_test) end)
      end

    results = Enum.map(tasks, &Task.await(&1, 1_000))
    assert Enum.count(results, &(&1 == :ok)) == 2
    assert Enum.count(results, &(&1 == {:error, :queue_full})) == 38
    assert :ets.info(:bounded_sink_test, :size) == 7
    assert {:message_queue_len, 0} = Process.info(worker, :message_queue_len)

    send(worker, :release)
    assert_receive {:writing, ^worker, rows}
    assert length(rows) == 2
    send(worker, :release)
  end

  test "worker failure loses only the disposable buffer and replacement accepts rows", %{
    worker: worker
  } do
    assert :ok = TypedSinkWorker.enqueue([%{id: 1}], server: :bounded_sink_test)
    assert_receive {:writing, ^worker, _}
    ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    stop_supervised!(:bounded_sink_test)

    assert {:error, :unavailable} =
             TypedSinkWorker.enqueue([%{id: 2}], server: :bounded_sink_test)

    replacement =
      start_supervised!(
        {TypedSinkWorker, name: :bounded_sink_test, sink: BlockedSink, flush_ms: 5}
      )

    assert :ok = TypedSinkWorker.enqueue([%{id: 3}], server: :bounded_sink_test)
    assert_receive {:writing, ^replacement, [%{id: 3}]}
    send(replacement, :release)
  end

  test "graceful shutdown drains all batches and rejects new rows", %{worker: worker} do
    assert :ok = TypedSinkWorker.enqueue([%{id: 1}], server: :bounded_sink_test)
    assert_receive {:writing, ^worker, [%{id: 1}]}
    assert :ok = TypedSinkWorker.enqueue([%{id: 2}, %{id: 3}], server: :bounded_sink_test)
    stopper = Task.async(fn -> GenServer.stop(worker, :normal, 2_000) end)
    send(worker, :release)
    assert_receive {:writing, ^worker, rows}
    assert Enum.map(rows, & &1.id) == [2, 3]

    assert {:error, :unavailable} =
             TypedSinkWorker.enqueue([%{id: 4}], server: :bounded_sink_test)

    send(worker, :release)
    assert Task.await(stopper) == :ok
  end

  @tag :short_shutdown
  test "a blocked dependency cannot exceed the supervisor shutdown budget", %{worker: worker} do
    assert :ok = TypedSinkWorker.enqueue([%{id: 1}], server: :bounded_sink_test)
    assert_receive {:writing, ^worker, _}
    ref = Process.monitor(worker)
    stop_supervised!(:bounded_sink_test)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}

    assert {:error, :unavailable} =
             TypedSinkWorker.enqueue([%{id: 2}], server: :bounded_sink_test)
  end

  test "slow telemetry handlers stay off the admission path", %{worker: worker} do
    owner = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:salix, :reporting, :queue],
      fn _, _, _, _ ->
        send(owner, {:handler, self()})
        receive do: (:continue -> :ok)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert_receive {:handler, ^worker}
    task = Task.async(fn -> TypedSinkWorker.enqueue([%{id: 1}], server: :bounded_sink_test) end)
    assert Task.await(task, 1_000) == :ok
    :telemetry.detach(handler)
    send(worker, :continue)
    assert_receive {:writing, ^worker, _}
    send(worker, :release)
  end
end
