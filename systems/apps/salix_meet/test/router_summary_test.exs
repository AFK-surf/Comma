defmodule SalixMeet.RouterSummaryTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixMeet"]
  alias SalixMeet.{Delivery, RouterSummary, Store}

  defmodule Handoff do
    def request(state, request) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_meet, :summary_test_pid),
        {:request, state, request}
      )

      :ok
    end
  end

  defmodule Materials do
    def prepare_context(_state) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_meet, :summary_test_pid),
        :prepared
      )

      {:ok,
       %{
         "version" => 2,
         "transcript" => String.duplicate("会", 16_010),
         "captions_transcript" => "Comma planning",
         "asr_transcript" => "Q planning",
         "duration_seconds" => 660
       }}
    end

    def summarize(_), do: raise("legacy summary must not run")
    def summarize(_, _), do: raise("legacy summary must not run")
  end

  setup do
    configs = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_meet, :router_summary_mod, Handoff},
      {:salix_meet, :summary_mod, Materials},
      {:salix_meet, :owner_attribution_mod, SalixMeet.Ports.OwnerAttribution.None},
      {:salix_meet, :summary_test_pid, SystemsRuntime.Proc.self()}
    ]

    old =
      Enum.map(configs, fn {app, key, value} ->
        previous = SystemsRuntime.fetch_env(app, key)
        SystemsRuntime.put_env(app, key, value)
        {app, key, previous}
      end)

    start_supervised!(SalixStore.S3.Fake)
    SalixStore.S3.Fake.reset()

    on_exit(fn ->
      Enum.each(old, fn
        {app, key, {:ok, value}} -> SystemsRuntime.put_env(app, key, value)
        {app, key, :error} -> SystemsRuntime.delete_env(app, key)
      end)
    end)

    id = "router-summary-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    state = %{
      "status" => "done",
      "provider" => "slack",
      "group_id" => "summary-group",
      "meeting_agent_id" => "meeting-agent",
      "title" => "Standup",
      "captions" => [%{"text" => "Comma planning"}],
      "artifacts" => %{},
      "delivery" => %{}
    }

    {:ok, _, _} = Store.create_once(id, state: state)
    {:ok, %{"state" => claimed}, _, claim} = Store.claim_delivery(id, "test")
    %{id: id, state: Map.put(claimed, "meeting_id", id), claim: claim}
  end

  test "durable request precedes enqueue; Router submission feeds the existing attribution/publish gate",
       c do
    assert {:error, :router_summary_pending} =
             Delivery.prepare_summary_for_delivery(c.id, c.state, c.claim)

    settle_receive(:prepared)
    settle_receive({:request, _, request})
    {:ok, %{"state" => state}, _} = Store.get(c.id)
    assert get_in(state, ["delivery", "router_summary", "request_id"]) == request["request_id"]
    refute Map.has_key?(state, "summary")

    assert {:error, :router_summary_pending} =
             Delivery.prepare_summary_for_delivery(c.id, state, c.claim)

    settle_refute_receive(:prepared)
    settle_receive({:request, _, ^request})
    params = params(c.id, request)
    assert {:ok, first, _} = RouterSummary.read("summary-group", params)
    assert String.length(first["text"]) == 16_000
    assert first["next_offset"] == 16_000
    assert {:ok, last, _} = RouterSummary.read("summary-group", Map.put(params, "offset", 16_000))
    assert last["text"] == String.duplicate("会", 10)
    assert last["next_offset"] == nil
    assert {:ok, %{"status" => "accepted"}} = RouterSummary.submit("summary-group", params)
    assert {:ok, _} = RouterSummary.submit("summary-group", params)
    {:ok, %{"state" => state}, _} = Store.get(c.id)
    assert {:ok, summary} = Delivery.prepare_summary_for_delivery(c.id, state, c.claim)
    assert summary["title"] == "Comma standup"
    assert summary["duration_minutes"] == 11
    {:ok, %{"state" => saved}, _} = Store.get(c.id)
    assert saved["summary"] == summary

    assert SalixMeet.OwnerAttributionSnapshot.complete?(
             SalixMeet.OwnerAttributionSnapshot.current(saved)
           )

    settle_refute_receive(:prepared)
  end

  test "cross-group, stale, malformed and replacement submissions cannot write", c do
    {:error, :router_summary_pending} =
      Delivery.prepare_summary_for_delivery(c.id, c.state, c.claim)

    settle_receive({:request, _, request})
    params = params(c.id, request)
    assert {:error, :not_found} = RouterSummary.submit("other-group", params)

    assert {:error, :stale_summary_request} =
             RouterSummary.submit("summary-group", %{params | "request_id" => "fake"})

    assert {:error, :invalid_summary_schema} =
             RouterSummary.submit("summary-group", %{params | "summary" => %{}})

    assert {:ok, _} = RouterSummary.submit("summary-group", params)
    changed = put_in(params, ["summary", "title"], "replacement")
    assert {:error, :summary_already_submitted} = RouterSummary.submit("summary-group", changed)
  end

  test "stale delivery claim cannot enqueue a request", c do
    assert {:error, :fenced} =
             Delivery.prepare_summary_for_delivery(
               c.id,
               c.state,
               Map.put(c.claim, "attempt_count", -1)
             )

    settle_refute_receive({:request, _, _})
  end

  defp params(id, request) do
    %{
      "meeting_id" => id,
      "request_id" => request["request_id"],
      "summary" => %{
        "title" => "Comma standup",
        "attendees" => [],
        "timeline" => [],
        "key_points" => ["Plan"],
        "action_items" => [],
        "decisions" => [],
        "open_questions" => [],
        "blockers" => []
      }
    }
  end
end
