defmodule SalixAgent.SubscriptionWorkerBudgetTest do
  use ExUnit.Case, async: false
  alias SalixAgent.SubscriptionWorker

  setup_all do
    source = Path.expand("../../../account-proxy", __DIR__)
    dir = Path.join(System.tmp_dir!(), "worker-budget-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    binary = Path.join(dir, "worker-test")

    {output, status} =
      System.cmd("go", ["test", "-c", "-o", binary], cd: source, stderr_to_stdout: true)

    assert status == 0, output
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, binary: binary}
  end

  setup %{binary: binary} do
    keys = [
      :llm_stream_first_event_timeout_ms,
      :llm_stream_idle_timeout_ms,
      :llm_request_timeout_ms
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:salix_agent, &1)})
    Application.put_env(:salix_agent, :llm_stream_first_event_timeout_ms, 1_000)
    Application.put_env(:salix_agent, :llm_stream_idle_timeout_ms, 100)
    Application.put_env(:salix_agent, :llm_request_timeout_ms, 10_000)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, old} -> Application.put_env(:salix_agent, key, old)
          :error -> Application.delete_env(:salix_agent, key)
        end
      end
    end)

    worker =
      start_supervised!(
        {SubscriptionWorker,
         name: nil,
         command:
           {"/usr/bin/env",
            ["SALIX_WORKER_BUDGET_TEST=1", binary, "-test.run=TestWorkerBudgetProcess"]}}
      )

    assert {:ok, "firstlast"} = SubscriptionWorker.request("/normalize", %{}, %{}, server: worker)
    {:ok, worker: worker}
  end

  test "a large request crosses both protocol endpoints and the next call still works", %{
    worker: worker
  } do
    # The complete frame includes the JSON envelope and credential, not only body.
    body = %{"padding" => String.duplicate("x", 16 * 1024 * 1024 - 1024)}

    assert {:ok, "firstlast"} =
             SubscriptionWorker.request("/v1/responses", body, %{}, server: worker)

    assert {:error, 413, "request_too_large", ""} =
             SubscriptionWorker.request(
               "/v1/responses",
               Map.put(body, "padding", String.duplicate("x", 16 * 1024 * 1024)),
               %{},
               server: worker
             )

    assert {:ok, "firstlast"} = SubscriptionWorker.request("/normalize", %{}, %{}, server: worker)
  end

  test "the first event can take longer than the streaming idle budget", %{worker: worker} do
    assert {:ok, "firstlast"} =
             SubscriptionWorker.request("/v1/responses", %{"stream" => true, "delay" => 250}, %{},
               server: worker
             )
  end

  @tag timeout: 45_000
  test "a first event after the former thirty-second deadline completes", %{worker: worker} do
    Application.put_env(:salix_agent, :llm_stream_first_event_timeout_ms, 120_000)
    Application.put_env(:salix_agent, :llm_stream_idle_timeout_ms, 30_000)
    Application.put_env(:salix_agent, :llm_request_timeout_ms, 40_000)

    assert {:ok, "firstlast"} =
             SubscriptionWorker.request(
               "/v1/responses",
               %{"stream" => true, "delay" => 31_000},
               %{},
               server: worker
             )
  end

  @tag timeout: 45_000
  test "a control response after the former thirty-second deadline completes", %{worker: worker} do
    Application.put_env(:salix_agent, :llm_request_timeout_ms, 40_000)

    assert {:ok, "firstlast"} =
             SubscriptionWorker.request("/quota", %{"delay" => 31_000}, %{}, server: worker)
  end

  test "the configured first-event budget cancels a silent request", %{worker: worker} do
    Application.put_env(:salix_agent, :llm_stream_first_event_timeout_ms, 100)

    assert {:error, 504, "worker_first_event_timeout", ""} =
             SubscriptionWorker.request("/v1/messages", %{"stream" => true, "delay" => 500}, %{},
               server: worker
             )

    assert {:ok, "firstlast"} = SubscriptionWorker.request("/normalize", %{}, %{}, server: worker)
  end

  test "after the first event the configured idle budget preserves partial output", %{
    worker: worker
  } do
    assert {:error, 504, "worker_idle_timeout", "first"} =
             SubscriptionWorker.request("/v1/responses", %{"stream" => true, "gap" => 500}, %{},
               server: worker
             )

    assert {:ok, "firstlast"} = SubscriptionWorker.request("/normalize", %{}, %{}, server: worker)
  end

  test "blocking and control calls use the total budget rather than streaming idle", %{
    worker: worker
  } do
    for op <- ["/v1/responses", "/v1/responses/compact", "/quota"] do
      assert {:ok, "firstlast"} =
               SubscriptionWorker.request(op, %{"delay" => 250, "gap" => 250}, %{},
                 server: worker
               )
    end
  end

  test "disabling stream timers retains the owner total deadline", %{worker: worker} do
    Application.put_env(:salix_agent, :llm_stream_first_event_timeout_ms, :infinity)
    Application.put_env(:salix_agent, :llm_stream_idle_timeout_ms, :infinity)
    Application.put_env(:salix_agent, :llm_request_timeout_ms, 200)

    assert {:error, 504, "worker_timeout", "first"} =
             SubscriptionWorker.request("/v1/responses", %{"stream" => true, "gap" => 500}, %{},
               server: worker
             )
  end
end
