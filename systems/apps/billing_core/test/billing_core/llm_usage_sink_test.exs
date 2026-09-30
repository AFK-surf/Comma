defmodule BillingCore.Metering.LLMUsageSinkTest do
  use ExUnit.Case, async: false
  alias BillingCore.LLMMetering
  alias SalixAnalytics.TypedSinkWorker
  @worker BillingCore.Metering.LLMUsageWorker

  defmodule ControlledSink do
    def insert(rows) do
      send(Process.whereis(:llm_usage_test_owner), {:raw_write, self(), rows})

      receive do
        :accept -> {:ok, length(rows)}
        :reject -> {:error, :clickhouse_down}
      end
    end
  end

  setup do
    Process.register(self(), :llm_usage_test_owner)
    previous = Application.get_env(:billing_core, :llm_typed_sink)
    Application.put_env(:billing_core, :llm_typed_sink, ControlledSink)

    worker =
      start_supervised!(
        {TypedSinkWorker,
         name: @worker,
         sink: BillingCore.Metering.LLMUsageSink,
         sink_name: "llm_usage",
         retry_on_error: true,
         max_buffer: 2,
         flush_ms: 10}
      )

    on_exit(fn ->
      if pid = Process.whereis(@worker), do: Process.exit(pid, :kill)

      if previous,
        do: Application.put_env(:billing_core, :llm_typed_sink, previous),
        else: Application.delete_env(:billing_core, :llm_typed_sink)
    end)

    %{worker: worker}
  end

  test "session hook returns while ClickHouse is blocked and retains the same row on retry", %{
    worker: worker
  } do
    assert :ok = LLMMetering.after_llm_call(fact("first"))
    assert_receive {:raw_write, ^worker, [first]}
    task = Task.async(fn -> LLMMetering.after_llm_call(fact("second")) end)
    assert Task.await(task, 1_000) == :ok
    assert {:error, :queue_full} = LLMMetering.after_llm_call(fact("overflow"))
    send(worker, :reject)
    assert_receive {:raw_write, ^worker, [retry]}, 2_000
    assert retry == first
    send(worker, :accept)
    assert_receive {:raw_write, ^worker, [%{"source_key" => "second"}]}
    send(worker, :accept)
    :sys.get_state(worker)
  end

  test "graceful shutdown drains accepted LLM usage and stores no credentials", %{worker: worker} do
    assert :ok =
             LLMMetering.after_llm_call(
               Map.merge(fact("shutdown"), %{api_key: "private-key", prompt: "private-prompt"})
             )

    assert_receive {:raw_write, ^worker, [_]}
    entries = :ets.tab2list(@worker) |> Enum.filter(&(tuple_size(&1) == 3))
    refute inspect(entries) =~ "private-key"
    refute inspect(entries) =~ "private-prompt"
    stopper = Task.async(fn -> GenServer.stop(worker, :normal, 2_000) end)
    send(worker, :accept)
    assert :ok = Task.await(stopper)
  end

  defp fact(key) do
    %{
      source_key: key,
      provider: "openai",
      model: "gpt-x",
      tenant_account_pool: true,
      billing_account_id: "tenant-account",
      usage: %{prompt_tokens: 10},
      metered_at: ~U[2026-09-14 06:00:00Z]
    }
  end
end
