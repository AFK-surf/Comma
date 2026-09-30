defmodule SalixMeet.RouterSummaryTest do
  use ExUnit.Case, async: false
  alias SalixMeet.{Delivery, RouterSummary, Store}

  defmodule Handoff do
    def request(state, request) do
      send(Application.fetch_env!(:salix_meet, :summary_test_pid), {:request, state, request})
      :ok
    end
  end

  defmodule Materials do
    def prepare_context(_state) do
      send(Application.fetch_env!(:salix_meet, :summary_test_pid), :prepared)

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
      {:salix_meet, :summary_test_pid, self()}
    ]

    old =
      Enum.map(configs, fn {app, key, value} ->
        previous = Application.fetch_env(app, key)
        Application.put_env(app, key, value)
        {app, key, previous}
      end)

    start_supervised!(SalixStore.S3.Fake)
    SalixStore.S3.Fake.reset()

    on_exit(fn ->
      Enum.each(old, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)
    end)

    id = "router-summary-#{System.unique_integer([:positive])}"

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

    assert_receive :prepared
    assert_receive {:request, _, request}
    {:ok, %{"state" => state}, _} = Store.get(c.id)
    assert get_in(state, ["delivery", "router_summary", "request_id"]) == request["request_id"]
    refute Map.has_key?(state, "summary")

    assert {:error, :router_summary_pending} =
             Delivery.prepare_summary_for_delivery(c.id, state, c.claim)

    refute_receive :prepared
    assert_receive {:request, _, ^request}

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

    refute_receive :prepared
  end

  test "cross-group, stale, malformed and replacement submissions cannot write", c do
    {:error, :router_summary_pending} =
      Delivery.prepare_summary_for_delivery(c.id, c.state, c.claim)

    assert_receive {:request, _, request}
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

  test "changed materials invalidate submission and create a new request", c do
    {:error, :router_summary_pending} =
      Delivery.prepare_summary_for_delivery(c.id, c.state, c.claim)

    assert_receive {:request, _, old}

    {:ok, %{"state" => state}, _} =
      Store.update_state_retrying(c.id, &Map.put(&1, "captions", [%{"text" => "Changed"}]))

    assert {:error, :summary_source_changed} =
             RouterSummary.submit("summary-group", params(c.id, old))

    assert {:error, :router_summary_pending} =
             Delivery.prepare_summary_for_delivery(c.id, state, c.claim)

    assert_receive {:request, _, new}
    refute old["request_id"] == new["request_id"]
    assert new["attempt"] == 1
  end

  test "expired request is fenced, retried with new identity, then bounded", c do
    {:error, :router_summary_pending} =
      Delivery.prepare_summary_for_delivery(c.id, c.state, c.claim)

    assert_receive {:request, _, old}

    {:ok, %{"state" => state}, _} =
      Store.update_state_retrying(
        c.id,
        &put_in(&1, ["delivery", "router_summary", "expires_at"], 1)
      )

    assert {:error, :summary_request_expired} =
             RouterSummary.submit("summary-group", params(c.id, old))

    assert {:error, :router_summary_pending} =
             Delivery.prepare_summary_for_delivery(c.id, state, c.claim)

    assert_receive {:request, _, new}
    assert new["attempt"] == 2
    refute new["request_id"] == old["request_id"]

    assert {:error, :stale_summary_request} =
             RouterSummary.submit("summary-group", params(c.id, old))

    {:ok, %{"state" => state}, _} =
      Store.update_state_retrying(c.id, fn live ->
        live
        |> put_in(["delivery", "router_summary", "expires_at"], 1)
        |> put_in(["delivery", "router_summary", "attempt"], 3)
      end)

    assert {:error, :router_summary_timeout} =
             Delivery.prepare_summary_for_delivery(c.id, state, c.claim)

    refute_receive {:request, _, _}
  end

  test "stale delivery claim cannot enqueue a request", c do
    assert {:error, :fenced} =
             Delivery.prepare_summary_for_delivery(
               c.id,
               c.state,
               Map.put(c.claim, "attempt_count", -1)
             )

    refute_receive {:request, _, _}
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
