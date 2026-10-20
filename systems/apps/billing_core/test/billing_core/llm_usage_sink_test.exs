defmodule BillingCore.Metering.LLMUsageSinkTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BillingCore", "Elixir.SalixAnalytics.TypedSinkWorker"]

  alias BillingCore.LLMMetering
  alias SalixAnalytics.TypedSinkWorker
  @worker BillingCore.Metering.LLMUsageWorker

  defmodule ControlledSink do
    def insert(rows) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.whereis(:llm_usage_test_owner),
        {:raw_write, SystemsRuntime.Proc.self(), rows}
      )

      SystemsRuntime.Proc.receive do
        :accept -> {:ok, length(rows)}
        :reject -> {:error, :clickhouse_down}
      end
    end
  end

  setup do
    Process.register(SystemsRuntime.Proc.self(), :llm_usage_test_owner)
    previous = SystemsRuntime.get_env(:billing_core, :llm_typed_sink)
    SystemsRuntime.put_env(:billing_core, :llm_typed_sink, ControlledSink)

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
      if pid = SystemsRuntime.Proc.whereis(@worker), do: SystemsRuntime.Proc.exit(pid, :kill)

      if previous,
        do: SystemsRuntime.put_env(:billing_core, :llm_typed_sink, previous),
        else: SystemsRuntime.delete_env(:billing_core, :llm_typed_sink)
    end)

    %{worker: worker}
  end

  test "session hook returns while ClickHouse is blocked and retains the same row on retry", %{
    worker: worker
  } do
    assert :ok = LLMMetering.after_llm_call(fact("first"))
    settle_receive({:raw_write, ^worker, [first]})
    task = SystemsRuntime.Task.async(fn -> LLMMetering.after_llm_call(fact("second")) end)
    assert settled_await(task) == :ok
    assert {:error, :queue_full} = LLMMetering.after_llm_call(fact("overflow"))
    SystemsRuntime.Proc.send(worker, :reject)
    settle_receive({:raw_write, ^worker, [retry]})
    assert retry == first
    SystemsRuntime.Proc.send(worker, :accept)
    settle_receive({:raw_write, ^worker, [%{"source_key" => "second"}]})
    SystemsRuntime.Proc.send(worker, :accept)
    :sys.get_state(worker, :infinity)
  end

  test "graceful shutdown drains accepted LLM usage and stores no credentials", %{worker: worker} do
    assert :ok =
             LLMMetering.after_llm_call(
               Map.merge(fact("shutdown"), %{api_key: "private-key", prompt: "private-prompt"})
             )

    settle_receive({:raw_write, ^worker, [_]})
    entries = :ets.tab2list(@worker) |> Enum.filter(&(tuple_size(&1) == 3))
    refute inspect(entries) =~ "private-key"
    refute inspect(entries) =~ "private-prompt"
    stopper = SystemsRuntime.Task.async(fn -> GenServer.stop(worker, :normal, 2_000) end)
    SystemsRuntime.Proc.send(worker, :accept)
    assert :ok = settled_await(stopper)
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
