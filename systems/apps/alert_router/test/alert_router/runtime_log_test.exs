defmodule AlertRouter.RuntimeLogTestVerifier do
  def verify("test-storage-jwt", audience),
    do:
      {:ok,
       %{
         "aud" => audience,
         "email" => "storage-push@test.iam.gserviceaccount.com",
         "email_verified" => true
       }}

  def verify(_, _), do: {:error, :invalid_token}
end

defmodule AlertRouter.RuntimeLogTest do
  use AlertRouter.DataCase, async: false
  alias AlertRouter.{RuntimeLog, Repo}
  alias AlertRouter.Data.Incident
  alias SalixStore.S3
  import Plug.Test
  import Plug.Conn

  setup do
    if !Process.whereis(SalixStore.S3.Fake), do: start_supervised!(SalixStore.S3.Fake)
    SalixStore.S3.Fake.reset()
    old = Application.get_env(:salix_store, :s3_backend)
    old_config = Application.get_env(:alert_router, :runtime_log)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    Application.put_env(:alert_router, :runtime_log,
      enabled: true,
      bucket: SalixStore.Config.get().bucket,
      environment: "staging",
      cluster: "example-cluster",
      start_at: "2026-09-07T00:00:00Z"
    )

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, old)
      Application.put_env(:alert_router, :runtime_log, old_config)
    end)

    S3.put(
      "agents/agent/external_runtime/sessions/session.json",
      Jason.encode!(%{
        "agent_id" => "agent",
        "session_id" => "session",
        "tenant_id" => "tenant",
        "group_id" => "group"
      })
    )

    :ok
  end

  test "authenticated storage push persists a deduplicated job before ACK" do
    old = Application.get_env(:alert_router, :runtime_storage_push)

    Application.put_env(:alert_router, :runtime_storage_push,
      audience: "https://alerts.test/v1/events/runtime-storage",
      service_account_email: "storage-push@test.iam.gserviceaccount.com",
      token_verifier: AlertRouter.RuntimeLogTestVerifier
    )

    on_exit(fn -> Application.put_env(:alert_router, :runtime_storage_push, old) end)

    envelope = %{
      "message" => %{
        "messageId" => "storage-1",
        "attributes" => %{
          "bucketId" => SalixStore.Config.get().bucket,
          "eventType" => "OBJECT_FINALIZE",
          "objectId" => path(1)
        }
      }
    }

    push = fn token, body ->
      conn(:post, "/v1/events/runtime-storage", Jason.encode!(body))
      |> put_req_header("authorization", "Bearer " <> token)
      |> AlertRouter.Web.Router.call([])
    end

    assert push.("wrong", envelope).status == 401
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert push.("test-storage-jwt", envelope).status == 202
    assert push.("test-storage-jwt", envelope).status == 202
    assert [job] = Repo.all(Oban.Job)
    assert job.queue == "runtime_log"
    assert job.args["object"] == path(1)
    # New notifications must not disappear behind an in-flight older job.
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "executing"])
    newer = put_in(envelope, ["message", "messageId"], "storage-2")
    assert push.("test-storage-jwt", newer).status == 202
    assert Repo.aggregate(Oban.Job, :count) == 2
    wrong_bucket = put_in(envelope, ["message", "attributes", "bucketId"], "unapproved-bucket")
    assert push.("test-storage-jwt", wrong_bucket).status == 503
  end

  test "recovery delivered before a backfilled failure remains recovered with no duplicate card" do
    put_segment(1, [record(1, "runtime_failed")])
    put_segment(2, [record(2, "runtime_recovered")])
    assert {:ok, :done} = consume(2)
    assert [%{state: "resolved", recovery_status: "verified"} = incident] = Repo.all(Incident)
    assert incident.evidence_values["tenant"] == "tenant"
    assert incident.evidence_values["execution"] == "execution"
    assert {:ok, :done} = consume(1)
    assert Repo.aggregate(Incident, :count) == 1
    assert Repo.get!(Incident, incident.incident_key).desired_revision == 1
  end

  test "exhaustion escalates same incident, recovery closes it and later failure is separate" do
    put_segment(1, [
      record(1, "runtime_failed"),
      record(2, "recovery_exhausted"),
      record(3, "runtime_recovered"),
      record(4, "runtime_failed")
    ])

    assert {:ok, :done} = consume(1)
    incidents = Repo.all(from(i in Incident, order_by: i.started_at))
    assert [old, new] = incidents
    assert old.priority == "P0"
    assert old.state == "resolved"
    assert old.desired_revision == 3
    assert new.priority == "P1"
    assert new.state == "firing"
    assert old.incident_key != new.incident_key
  end

  test "existing incident rejects a delayed P1 downgrade and repeated recovery" do
    put_segment(2, [record(2, "recovery_exhausted")])
    assert {:ok, :done} = consume(2)
    [incident] = Repo.all(Incident)
    assert incident.priority == "P0"

    put_segment(1, [record(1, "runtime_failed")])
    assert {:ok, :done} = consume(1)
    assert Repo.get!(Incident, incident.incident_key).desired_revision == 1

    put_segment(3, [record(3, "runtime_recovered")])
    assert {:ok, :done} = consume(3)
    assert {:ok, :done} = consume(1)
    assert {:ok, :done} = consume(3)
    assert [%{priority: "P0", state: "resolved", desired_revision: 2}] = Repo.all(Incident)
  end

  test "failed card ingestion leaves no incident or delivery; retry replays from durable log" do
    put_segment(1, [record(1, "runtime_failed")])
    assert {:error, :router_disabled} = RuntimeLog.consume(path(1), route_mode: :disabled)

    assert Repo.aggregate(Oban.Job, :count) == 0

    assert Repo.aggregate(Incident, :count) == 0
    assert {:ok, :done} = consume(1)
    assert Repo.aggregate(Incident, :count) == 1
  end

  test "storage outage does not advance progress; storage writer remains independent" do
    put_segment(1, [record(1, "runtime_failed")])
    SalixStore.S3.Fake.set_fault({:fail, 503, :get, path(1)})
    assert {:error, _} = consume(1)
    assert Repo.aggregate(Incident, :count) == 0
    put_segment(1, [record(1, "runtime_failed"), record(2, "runtime_recovered")])
    assert {:ok, :done} = consume(1)
    assert [%{state: "resolved"}] = Repo.all(Incident)
  end

  test "unscoped legacy recovery cannot close a known execution" do
    recovery =
      update_in(
        record(2, "runtime_recovered"),
        ["data", "event"],
        &Map.delete(&1, "execution_id")
      )

    put_segment(1, [record(1, "runtime_failed"), recovery])
    assert {:ok, :done} = consume(1)
    assert [%{state: "firing"}] = Repo.all(Incident)
  end

  test "notified session and persisted record identity must agree" do
    invalid = Map.put(record(1, "runtime_failed"), "session_id", "other")
    put_segment(1, [invalid])
    assert {:error, :segment_identity_mismatch} = consume(1)
    assert Repo.aggregate(Incident, :count) == 0
  end

  test "old episode recovery delivered last cannot clear a newer failure" do
    put_segment(4, [record(4, "runtime_failed")])
    assert {:ok, :done} = consume(4)
    put_segment(1, [record(1, "runtime_failed"), record(3, "runtime_recovered")])
    assert {:ok, :done} = consume(1)
    incidents = Repo.all(from(i in Incident, order_by: i.started_at))
    assert [%{state: "resolved"}, %{state: "firing"}] = incidents
  end

  test "cutover skips old episodes and bounded reads reject oversized segments" do
    cfg = Application.fetch_env!(:alert_router, :runtime_log)

    Application.put_env(
      :alert_router,
      :runtime_log,
      Keyword.put(cfg, :start_at, "2026-09-07T00:00:02Z")
    )

    put_segment(1, [record(1, "runtime_failed"), record(3, "runtime_recovered")])
    assert {:ok, :done} = consume(1)
    assert Repo.aggregate(Incident, :count) == 0
    S3.put(path(2), String.duplicate("x", 1_048_577))
    assert {:error, :segment_byte_budget_exceeded} = consume(2)
    put_segment(2, List.duplicate(record(2, "runtime_failed"), 513))
    assert {:error, :segment_record_budget_exceeded} = consume(2)
  end

  test "consumer outcome reaches the shared metric shape without session labels" do
    reporter = AlertRouter.RuntimeLogTestReporter

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: reporter, metrics: AlertRouter.Telemetry.metrics(), start_async: false}
    )

    put_segment(1, [record(1, "runtime_failed")])
    assert {:ok, :done} = consume(1)
    scrape = TelemetryMetricsPrometheus.Core.scrape(reporter)

    assert scrape =~
             ~s(alert_router_operations_total{operation="runtime_log",outcome="ok",provider="salix_runtime"} 1)

    refute scrape =~ "tenant="
    refute scrape =~ "session="
  end

  test "durable failure to recovery updates the same Slack message over HTTP" do
    start_supervised!(AlertRouter.MockSlackAPI)

    bandit =
      start_supervised!(
        {Bandit, plug: AlertRouter.MockSlackAPI, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(bandit)
    old = Application.get_env(:alert_router, :slack)

    Application.put_env(
      :alert_router,
      :slack,
      old
      |> Keyword.put(:client, AlertRouter.Slack.ReqClient)
      |> Keyword.put(:base_url, "http://127.0.0.1:#{port}/api")
    )

    on_exit(fn -> Application.put_env(:alert_router, :slack, old) end)

    put_segment(1, [record(1, "runtime_failed")])
    assert {:ok, :done} = consume(1)
    assert %{failure: 0} = drain()
    [original] = Repo.all(Incident)
    assert is_binary(original.slack_root_ts)

    put_segment(1, [record(1, "runtime_failed"), record(2, "recovery_exhausted")])
    assert {:ok, :done} = consume(1)
    assert %{failure: 0} = drain()
    assert Repo.get!(Incident, original.incident_key).priority == "P0"

    put_segment(1, [
      record(1, "runtime_failed"),
      record(2, "recovery_exhausted"),
      record(3, "runtime_recovered")
    ])

    assert {:ok, :done} = consume(1)
    assert %{failure: 0} = drain()
    [final] = Repo.all(Incident)
    assert final.slack_root_ts == original.slack_root_ts
    assert final.recovery_status == "verified"
    requests = AlertRouter.MockSlackAPI.requests()

    root_posts =
      Enum.filter(
        requests,
        &(&1.path == "/api/chat.postMessage" and is_nil(&1.body["thread_ts"]))
      )

    updates = Enum.filter(requests, &(&1.path == "/api/chat.update"))
    assert length(root_posts) == 1
    assert length(updates) == 2
    assert Enum.all?(updates, &(&1.body["ts"] == original.slack_root_ts))
    assert Jason.encode!(List.last(updates).body) =~ "🟢 P0"
    assert {:ok, :done} = consume(1)
    assert %{success: 0, failure: 0} = drain()
  end

  defp drain,
    do:
      Oban.drain_queue(AlertRouter.Oban,
        queue: :alert_delivery,
        with_scheduled: true,
        with_recursion: true
      )

  defp consume(n), do: RuntimeLog.consume(path(n), route_mode: :shadow)
  defp id(n), do: "01ARZ3NDEKTSV4RRFFQ69G5F" <> String.pad_leading(Integer.to_string(n), 2, "0")
  defp path(n), do: "agents/agent/external_runtime/sessions/session/segments/#{id(n)}.jsonl"

  defp put_segment(n, records),
    do: S3.put(path(n), Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")

  defp record(n, kind) do
    {:ok, at, _} = DateTime.from_iso8601("2026-09-07T00:00:00Z")

    event = %{
      "dispatch_id" => "dispatch",
      "execution_id" => "execution",
      "fault_episode_id" => id(if(n >= 4, do: 4, else: 1)),
      "fault_started_at" => DateTime.to_unix(at) + if(n >= 4, do: 4, else: 1),
      "fault_priority" => if(n in [2, 3] and kind != "runtime_failed", do: "P0", else: "P1"),
      "created_at" => DateTime.to_unix(at) + n
    }

    event =
      if kind == "runtime_recovered",
        do: Map.merge(event, %{"name" => kind, "state" => "recovered"}),
        else: Map.merge(event, %{"work_state" => "failed", "issue" => kind})

    %{
      "id" => id(n),
      "agent_id" => "agent",
      "session_id" => "session",
      "type" => "runtime.event",
      "data" => %{"event" => event}
    }
  end
end
