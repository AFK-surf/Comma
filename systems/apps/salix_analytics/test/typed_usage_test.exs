defmodule SalixAnalytics.TypedUsageTest do
  use ExUnit.Case, async: false

  alias SalixAnalytics.{
    AgentRunEvent,
    BillingSourceEvent,
    BillingChargeEvent,
    FeeControlCheck,
    LLMCallEvent,
    StorageUsageEvent,
    ToolCallEvent,
    TypedSinkWorker,
    VMUsageEvent
  }

  alias SalixAnalytics.Sink.ClickHouseTyped

  setup do
    start_supervised!(SalixAnalytics.MockClickHouse)

    bandit =
      start_supervised!(
        {Bandit,
         plug: SalixAnalytics.MockClickHouse, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: {__MODULE__, :typed_bandit}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    prev_clickhouse = Application.get_env(:salix_analytics, :clickhouse)
    prev_sink = Application.get_env(:salix_analytics, :typed_sink)

    Application.put_env(:salix_analytics, :clickhouse,
      base_url: "http://127.0.0.1:#{port}/",
      table: "test.events",
      typed_database: "test"
    )

    Application.put_env(:salix_analytics, :typed_sink, ClickHouseTyped)

    on_exit(fn ->
      Application.put_env(:salix_analytics, :clickhouse, prev_clickhouse)
      Application.put_env(:salix_analytics, :typed_sink, prev_sink)
    end)

    :ok
  end

  test "typed rows preserve unknown, missing, and zero usage observations" do
    base = common("comma", "comma:usage:observation", "conversation_send", "user")
    unknown = LLMCallEvent.build(base)
    assert unknown["usage_reported"] == nil
    assert unknown["reasoning_tokens"] == nil
    missing = LLMCallEvent.build(Map.put(base, :usage, %{"usage_reported" => false}))
    assert missing["usage_reported"] == false

    reported =
      LLMCallEvent.build(
        Map.put(base, :usage, %{
          "usage_reported" => true,
          "cache_read_tokens_reported" => true,
          "cache_read_input_tokens" => 0,
          "reasoning_tokens" => 30
        })
      )

    assert reported["cache_read_tokens_reported"] == true
    assert reported["cache_read_input_tokens"] == 0
    assert reported["reasoning_tokens"] == 30
    assert {:ok, 1} = ClickHouseTyped.insert([reported])
  end

  test "builds typed rows for all billing ingress surfaces and resources" do
    rows = [
      LLMCallEvent.build(
        common("comma", "comma:llm:1", "conversation_send", "user")
        |> Map.merge(%{
          duration_ms: 1200,
          first_token_ms: 180,
          attempts: 2,
          response_kind: "final",
          error_type: "none",
          http_status: nil,
          app_revision: "2026.07.08"
        })
      ),
      LLMCallEvent.build(common("bridge", "bridge:llm:1", "direct_deliver", "external_user")),
      LLMCallEvent.build(common("bridge", "bridge:im:1", "im_router", "external_user")),
      LLMCallEvent.build(common("bridge", "meet:llm:1", "meeting_runtime", "service")),
      ToolCallEvent.build(
        tool_common("tool:1")
        |> Map.merge(%{
          tool_name: "browser.open",
          tool_source: "mcp",
          status: "guidance",
          duration_ms: 42,
          started_at: ~U[2026-07-08 00:00:00.123Z],
          args_fingerprint: "0123456789abcdef",
          result_fingerprint: "fedcba9876543210",
          call_index: 0,
          async: false,
          guidance_reason: "not_callable",
          app_revision: "2026.07.08",
          trace_id: "trace_1",
          request_id: "req_1",
          salix_agent_id: "agent_1",
          session_id: "session_1",
          round_id: "round_1"
        })
      ),
      AgentRunEvent.build(
        run_common("run:1")
        |> Map.merge(%{
          status: "completed",
          duration_ms: 3000,
          started_at: ~U[2026-07-08 00:00:00Z],
          trace_id: "trace_1",
          request_id: "req_1",
          salix_agent_id: "agent_1",
          session_id: "session_1",
          round_id: "round_1",
          app_revision: "2026.07.08",
          task_origin: %{"suite" => "trajectory", "case_id" => "case_1"},
          platform: "raft",
          source_schedule_id: "schedule_1"
        })
      ),
      VMUsageEvent.build(common("bridge", "vm:1", "cloud_vm_sweeper", "system")),
      StorageUsageEvent.build(common("comma", "storage:1", "storage_snapshot", "system")),
      BillingChargeEvent.build(
        common("comma", "charge:1", "ledger_projection", "system")
        |> Map.put(:entitlement_mode, "unlimited_metered")
      ),
      BillingSourceEvent.build(billing_source_common("manual_grant:1", "grant_issued")),
      FeeControlCheck.build(
        common("comma", "fee:1", "conversation_send", "user")
        |> Map.merge(%{
          cache_hit: false,
          query_performed: true,
          query_duration_ms: 3,
          result_source: "pg",
          entitlement_mode: "unlimited_metered"
        })
      )
    ]

    assert rows
           |> Enum.reject(&(&1["resource_kind"] in ["tool_call", "agent_run"]))
           |> Enum.all?(&(&1["billing_account_id"] == "ba_1"))

    assert rows
           |> Enum.map(& &1["entrypoint"])
           |> Enum.reject(&is_nil/1)
           |> Enum.uniq()
           |> Enum.sort() == [
             "agent_run",
             "cloud_vm_sweeper",
             "conversation_send",
             "direct_deliver",
             "im_router",
             "ledger_projection",
             "meeting_runtime",
             "storage_snapshot",
             "tool_call"
           ]

    assert Enum.find(rows, &(&1["resource_kind"] == "fee_control"))["query_performed"] == true

    assert Enum.find(rows, &(&1["resource_kind"] == "fee_control"))["entitlement_mode"] ==
             "unlimited_metered"

    assert Enum.find(rows, &(&1["resource_kind"] == "charge"))["entitlement_mode"] ==
             "unlimited_metered"

    assert Enum.find(rows, &(&1["resource_kind"] == "storage"))["byte_seconds"] == 0

    assert Enum.find(rows, &(&1["resource_kind"] == "billing_source"))["event_kind"] ==
             "grant_issued"

    llm = Enum.find(rows, &(&1["resource_kind"] == "llm"))
    assert llm["duration_ms"] == 1200
    assert llm["first_token_ms"] == 180
    assert llm["attempts"] == 2
    assert llm["response_kind"] == "final"
    assert llm["error_type"] == "none"
    assert llm["app_revision"] == "2026.07.08"
    assert Map.has_key?(llm, "http_status")

    tool = Enum.find(rows, &(&1["resource_kind"] == "tool_call"))
    assert tool["tool_name"] == "browser.open"
    assert tool["status"] == "guidance"
    assert tool["guidance_reason"] == "not_callable"
    assert tool["app_revision"] == "2026.07.08"
    assert tool["result_fingerprint"] == "fedcba9876543210"
    assert tool["charge_status"] == "unattributed"

    run = Enum.find(rows, &(&1["resource_kind"] == "agent_run"))
    assert run["status"] == "completed"
    assert run["duration_ms"] == 3000
    assert run["app_revision"] == "2026.07.08"
    assert Jason.decode!(run["task_origin"]) == %{"suite" => "trajectory", "case_id" => "case_1"}
    assert run["platform"] == "raft"
    assert run["source_schedule_id"] == "schedule_1"
    assert run["charge_status"] == "unattributed"
  end

  test "event_date is the UTC calendar date of the fact's instant" do
    base = %{
      source: "test",
      source_key: "llm:utc-date",
      entrypoint: "round",
      surface: "comma",
      billing_account_id: "ba",
      product_owner_type: "workspace",
      tenant_id: "t1",
      group_id: "g1",
      actor_type: "agent"
    }

    # An offset instant near midnight: 2026-07-09T17:30:00-07:00 IS
    # 2026-07-10T00:30:00Z. The v2 tables prune by event_date against UTC
    # windows, so the zone-local date (or the string's first ten characters)
    # would put the row in the wrong day.
    offset_string = LLMCallEvent.build(Map.put(base, :metered_at, "2026-07-09T17:30:00-07:00"))
    assert offset_string["event_date"] == "2026-07-10"

    {:ok, offset_dt, _} = DateTime.from_iso8601("2026-07-09T17:30:00-07:00")
    offset_datetime = LLMCallEvent.build(Map.put(base, :metered_at, offset_dt))
    assert offset_datetime["event_date"] == "2026-07-10"

    utc = LLMCallEvent.build(Map.put(base, :metered_at, ~U[2026-07-10 12:00:00Z]))
    assert utc["event_date"] == "2026-07-10"

    # Non-ISO strings keep the ten-character fallback.
    fallback = LLMCallEvent.build(Map.put(base, :metered_at, "2026-07-10 09:00:00"))
    assert fallback["event_date"] == "2026-07-10"
  end

  test "tool call rows keep call_index from string-keyed attrs" do
    row =
      ToolCallEvent.build(
        tool_common("tool:string-keys")
        |> Map.put(:call_index, 3)
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
      )

    assert row["call_index"] == 3
    assert row["tool_name"] == "shell.exec"
  end

  test "typed ClickHouse sink groups by table and dedups repeated source keys" do
    rows = [
      LLMCallEvent.build(common("comma", "comma:llm:1", "conversation_send", "user")),
      VMUsageEvent.build(common("comma", "vm:1", "cloud_vm_sweeper", "system")),
      ToolCallEvent.build(tool_common("tool:1")),
      AgentRunEvent.build(run_common("run:1")),
      BillingSourceEvent.build(billing_source_common("redeem:1", "redeem_applied"))
    ]

    start_supervised!({TypedSinkWorker, name: :typed_usage_test_worker, sink: ClickHouseTyped})

    assert {:ok, 5} = TypedSinkWorker.insert(rows, server: :typed_usage_test_worker)
    assert {:ok, 5} = TypedSinkWorker.insert(rows, server: :typed_usage_test_worker)
    assert SalixAnalytics.MockClickHouse.count() == 5

    queries = SalixAnalytics.MockClickHouse.queries()
    assert Enum.any?(queries, &String.contains?(&1, "test.llm_call_events"))
    assert Enum.any?(queries, &String.contains?(&1, "test.vm_usage_events"))
    assert Enum.any?(queries, &String.contains?(&1, "test.tool_call_events"))
    assert Enum.any?(queries, &String.contains?(&1, "test.agent_run_events"))
    assert Enum.any?(queries, &String.contains?(&1, "test.billing_source_events"))
  end

  test "typed worker supports async buffered enqueue for non-billable rows" do
    handler = attach_reporting_telemetry()
    row = LLMCallEvent.build(common("comma", "comma:llm:async", "conversation_send", "user"))

    start_supervised!(
      {TypedSinkWorker,
       name: :typed_usage_async_worker, sink: ClickHouseTyped, batch_size: 10, flush_ms: 10}
    )

    assert :ok = TypedSinkWorker.enqueue([row], server: :typed_usage_async_worker)
    assert_receive {:reporting, :queue, %{depth: 1}, %{sink: "reporting"}}
    assert_receive {:reporting, :flush, %{duration: duration}, %{outcome: "ok"}}, 5_000
    assert is_integer(duration) and duration >= 0
    assert_receive {:reporting, :queue, %{depth: 0}, %{sink: "reporting"}}

    assert eventually(fn ->
             SalixAnalytics.MockClickHouse.count() == 1
           end)

    :telemetry.detach(handler)
  end

  test "typed worker rejects async enqueue when the bounded buffer is full" do
    handler = attach_reporting_telemetry()
    row = LLMCallEvent.build(common("comma", "comma:llm:bounded", "conversation_send", "user"))

    start_supervised!(
      {TypedSinkWorker,
       name: :typed_usage_bounded_worker,
       sink: ClickHouseTyped,
       batch_size: 10,
       flush_ms: 10,
       max_buffer: 1}
    )

    assert :ok = TypedSinkWorker.enqueue([row], server: :typed_usage_bounded_worker)

    assert {:error, :queue_full} =
             TypedSinkWorker.enqueue([row], server: :typed_usage_bounded_worker)

    assert_receive {:reporting, :queue_full, %{value: 1}, %{sink: "reporting"}}
    :telemetry.detach(handler)
  end

  test "readiness checks typed tables without falling back to Postgres" do
    assert :ok = ClickHouseTyped.readiness()

    queries = SalixAnalytics.MockClickHouse.queries()

    # Both seam generations are probed: writes go to *_v2, but every seam read
    # still UNIONs frozen v1, so probing only the write target would report
    # ready on a node whose dashboard queries fail with UNKNOWN_TABLE.
    for table <- ~w(
          llm_call_events_v2 tool_call_events_v2 agent_run_events_v2
          llm_call_events tool_call_events agent_run_events
        ) do
      assert Enum.any?(queries, &String.contains?(&1, "SELECT 1 FROM test.#{table} LIMIT 0")),
             "readiness did not probe #{table}"
    end
  end

  defp common(surface, source_key, entrypoint, actor_type) do
    %{
      source: "test",
      source_key: source_key,
      entrypoint: entrypoint,
      surface: surface,
      billing_account_id: "ba_1",
      product_owner_type: surface,
      product_owner_id: "#{surface}_owner",
      tenant_id: "tenant_1",
      group_id: "group_1",
      actor_type: actor_type,
      provider: "openai",
      sku: "gpt-test",
      model: "gpt-test",
      usage: %{
        prompt_tokens: 10,
        completion_tokens: 5,
        total_tokens: 15,
        cache_read_input_tokens: 3,
        cache_write_input_tokens: 2
      }
    }
  end

  defp attach_reporting_telemetry do
    handler = "typed-reporting-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler,
        Enum.map([:queue, :queue_full, :flush, :drop], &[:salix, :reporting, &1]),
        fn [_salix, _reporting, event], measurements, metadata, _ ->
          send(parent, {:reporting, event, measurements, metadata})
        end,
        nil
      )

    handler
  end

  defp billing_source_common(source_key, event_kind) do
    %{
      source: "test",
      source_key: source_key,
      occurred_at: ~U[2026-06-23 00:00:00Z],
      created_at: ~U[2026-06-23 00:00:01Z],
      surface: "comma",
      billing_account_id: "ba_1",
      product_owner_type: "workspace",
      product_owner_id: "wsp_1",
      event_kind: event_kind,
      source_type: "manual_contract",
      source_id: "manual_1",
      source_event_id: "operator_1",
      idempotency_key: "manual:wsp_1:2026-06",
      package_code: "comma_support",
      package_version: "2026-06",
      credit_grant_id: "grant_1",
      status: "issued",
      metadata: %{"reason" => "test"}
    }
  end

  defp tool_common(source_key) do
    %{
      source: "test",
      source_key: source_key,
      entrypoint: "tool_call",
      surface: "comma",
      tenant_id: "tenant_1",
      group_id: "group_1",
      actor_type: "user",
      tool_name: "shell.exec",
      tool_source: "core",
      status: "completed",
      duration_ms: 10,
      started_at: ~U[2026-07-08 00:00:00Z],
      args_fingerprint: "aaaaaaaaaaaaaaaa",
      result_fingerprint: nil,
      call_index: 0,
      async: false
    }
  end

  defp run_common(source_key) do
    %{
      source: "test",
      source_key: source_key,
      entrypoint: "agent_run",
      surface: "comma",
      tenant_id: "tenant_1",
      group_id: "group_1",
      actor_type: "user",
      status: "completed",
      duration_ms: 10,
      started_at: ~U[2026-07-08 00:00:00Z]
    }
  end

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() ->
        true

      retries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, retries - 1)
    end
  end
end
