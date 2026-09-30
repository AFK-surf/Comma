defmodule AlertRouter.LifecycleDeliveryTest do
  use AlertRouter.DataCase, async: false

  import AlertRouter.TestFixtures

  alias AlertRouter.Adapters.GCPMonitoring
  alias AlertRouter.Data.{EventRecord, Incident}
  alias AlertRouter.Repo

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  setup do
    start_supervised!(AlertRouter.MockSlackAPI)

    bandit =
      start_supervised!(
        {Bandit, plug: AlertRouter.MockSlackAPI, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: {__MODULE__, :mock_slack}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    previous_slack = Application.get_env(:alert_router, :slack)
    previous_gcp = Application.get_env(:alert_router, :gcp_push)

    previous_lifecycle_event_reader =
      Application.get_env(
        :alert_router,
        :lifecycle_event_reader,
        AlertRouter.LifecycleEventReader.Repo
      )

    Application.put_env(
      :alert_router,
      :slack,
      previous_slack
      |> Keyword.put(:client, AlertRouter.Slack.ReqClient)
      |> Keyword.put(:base_url, "http://127.0.0.1:#{port}/api")
    )

    Application.put_env(
      :alert_router,
      :gcp_push,
      Keyword.put(previous_gcp, :auth_module, AlertRouter.TestGCPPushAuth)
    )

    on_exit(fn ->
      Application.put_env(:alert_router, :slack, previous_slack)
      Application.put_env(:alert_router, :gcp_push, previous_gcp)

      Application.put_env(
        :alert_router,
        :lifecycle_event_reader,
        previous_lifecycle_event_reader
      )
    end)

    :ok
  end

  test "live P1 reaches the channel and thread progress refreshes the same card" do
    event = %{gcp_event("open", project: "example-staging-project") | priority: "P1"}
    assert {:ok, %{incident: incident}} = AlertRouter.ingest(event, route_mode: :live)
    assert %{success: 2, failure: 0} = drain_delivery()
    [root, _] = AlertRouter.MockSlackAPI.requests()
    assert root.body["text"] =~ "<!channel> P1"
    incident = Repo.get!(Incident, incident.incident_key)

    report = %{
      "type" => "message",
      "channel" => incident.channel_id,
      "thread_ts" => incident.slack_root_ts,
      "ts" => "#{System.system_time(:second) + 10}.000001",
      "user" => "UINVESTIGATOR",
      "text" => "告警进展\n已确认：一个会话再次中断\n影响：已定位一个会话，整体范围未知\n下一步：核对第二次执行结果"
    }

    assert push_progress(report).status == 200
    assert %{success: 2, failure: 0} = drain_delivery()
    latest = last_root_update()
    assert latest.path == "/api/chat.update"
    assert latest.body["ts"] == incident.slack_root_ts
    assert Jason.encode!(latest.body) =~ "一个会话再次中断"
    assert Jason.encode!(latest.body) =~ "核对第二次执行结果"
    refute Jason.encode!(latest.body) =~ "<!channel>"
    assert push_progress(report).status == 200
    assert %{success: 0, failure: 0} = drain_delivery()

    assert push_progress(%{
             report
             | "ts" => "#{System.system_time(:second) + 9}.000001",
               "text" => "告警进展\n旧结论"
           }).status == 200

    assert %{success: 0, failure: 0} = drain_delivery()

    assert {:ok, _} =
             AlertRouter.ingest(gcp_event("closed", project: "example-staging-project"),
               route_mode: :live
             )

    assert %{success: 2, failure: 0} = drain_delivery()

    card =
      Enum.find(
        Enum.reverse(AlertRouter.MockSlackAPI.requests()),
        &(&1.path == "/api/chat.update")
      )

    assert Jason.encode!(card.body) =~ "一个会话再次中断"
    assert Repo.get!(Incident, incident.incident_key).recovery_status == "unknown"
  end

  test "progress rejects forged and replayed callbacks and ignores unrelated discussion" do
    event = gcp_event()
    assert {:ok, _} = AlertRouter.ingest(event, route_mode: :shadow)
    assert %{success: 2, failure: 0} = drain_delivery()
    incident = Repo.get!(Incident, event.incident_key)

    report = %{
      "type" => "message",
      "channel" => incident.channel_id,
      "thread_ts" => incident.slack_root_ts,
      "ts" => "#{System.system_time(:second) + 10}.000001",
      "user" => "UREPORTER",
      "text" => "告警进展\n已恢复 <!channel>"
    }

    assert push_progress(report, secret: "forged").status == 401
    assert push_progress(report, age: -301).status == 401
    assert push_progress(report, team: "TOTHER").status == 403

    for changed <- [
          Map.put(report, "channel", "COTHER"),
          Map.delete(report, "thread_ts"),
          Map.put(report, "text", "我猜已经好了"),
          Map.put(report, "text", "告警进展\n" <> String.duplicate("a", 1801)),
          Map.put(report, "subtype", "message_changed")
        ] do
      assert push_progress(changed).status == 200
    end

    assert Repo.get!(Incident, incident.incident_key).progress == %{}
    assert %{success: 0, failure: 0} = drain_delivery()
    assert push_progress(report).status == 200
    assert %{success: 2, failure: 0} = drain_delivery()
    card = last_root_update().body

    progress =
      hd(card["blocks"])["child_blocks"]
      |> Enum.find(&String.ends_with?(&1["block_id"], "-progress"))

    assert progress["text"]["type"] == "plain_text"
    assert progress["text"]["text"] =~ "已恢复 <!channel>"
    refute card["text"] =~ "<!channel>"
    assert Repo.get!(Incident, incident.incident_key).state == "firing"
    assert Repo.get!(Incident, incident.incident_key).recovery_status == "not_applicable"
  end

  test "an ambiguous escalation is reconciled in the channel without a second mention" do
    first = %{gcp_event("open", project: "example-staging-project") | priority: "P1"}
    assert {:ok, _} = AlertRouter.ingest(first, route_mode: :live)
    assert %{success: 2, failure: 0} = drain_delivery()

    escalation = %{
      first
      | event_id: first.event_id <> "-escalation",
        priority: "P0",
        source_state: "recovery_exhausted"
    }

    assert {:ok, _} = AlertRouter.ingest(escalation, route_mode: :live)

    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.postMessage",
      {:commit, 500, %{"ok" => false, "error" => "internal_error"}}
    )

    assert %{success: 2, failure: 0} = drain_delivery()
    assert Repo.get!(EventRecord, escalation.event_id).timeline_state == "ambiguous"

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban, queue: :alert_reconciliation)

    assert Repo.get!(EventRecord, escalation.event_id).timeline_state == "posted"
    requests = AlertRouter.MockSlackAPI.requests()

    notifications =
      Enum.filter(
        requests,
        &(&1.path == "/api/chat.postMessage" and is_nil(&1.body["thread_ts"]))
      )

    assert length(notifications) == 2
    assert List.last(notifications).body["text"] =~ "<!channel> P0"
    assert Jason.encode!(List.last(notifications).body) =~ "https://comma-test.slack.com/archives/"
    assert List.last(requests).path == "/api/conversations.history"
    assert {:ok, %{disposition: :duplicate}} = AlertRouter.ingest(escalation, route_mode: :live)
    assert %{success: 0, failure: 0} = drain_delivery()
  end

  test "an escalation coalesced into the first root does not send a second channel mention" do
    first = %{gcp_event("open", project: "example-staging-project") | priority: "P1"}
    assert {:ok, _} = AlertRouter.ingest(first, route_mode: :live)

    escalation = %{
      first
      | event_id: first.event_id <> "-escalation",
        priority: "P0",
        source_state: "recovery_exhausted"
    }

    assert {:ok, _} = AlertRouter.ingest(escalation, route_mode: :live)
    assert %{failure: 0} = drain_delivery()

    posts =
      Enum.filter(
        AlertRouter.MockSlackAPI.requests(),
        &(&1.path == "/api/chat.postMessage" and is_nil(&1.body["thread_ts"]))
      )

    assert [root] = posts
    assert root.body["text"] =~ "<!channel> P0"
    assert Repo.get!(Incident, first.incident_key).slack_root_revision == 2
  end

  test "an escalation while the first root is in flight still notifies the channel" do
    first = %{gcp_event("open", project: "example-staging-project") | priority: "P1"}
    assert {:ok, %{incident: incident}} = AlertRouter.ingest(first, route_mode: :live)
    ref = make_ref()

    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.getPermalink",
      {:respond, 429, %{"ok" => false, "error" => "ratelimited"}}
    )

    AlertRouter.MockSlackAPI.script_next("/api/chat.postMessage", {:gate_commit, self(), ref})

    job = %Oban.Job{
      args: %{
        "incident_key" => incident.incident_key,
        "render_revision" => 1,
        "route_revision" => 1
      }
    }

    sender = Task.async(fn -> AlertRouter.Workers.DeliverIncident.perform(job) end)
    assert_receive {:mock_slack_gate, ^ref, gate_pid}, 1_000

    escalation = %{
      first
      | event_id: first.event_id <> "-escalation",
        priority: "P0",
        source_state: "recovery_exhausted"
    }

    assert {:ok, _} = AlertRouter.ingest(escalation, route_mode: :live)
    send(gate_pid, {:release_mock_slack_gate, ref})
    assert :ok = Task.await(sender)
    assert %{failure: 0} = drain_delivery()

    posts =
      Enum.filter(
        AlertRouter.MockSlackAPI.requests(),
        &(&1.path == "/api/chat.postMessage" and is_nil(&1.body["thread_ts"]))
      )

    assert [root, notice] = posts
    assert root.body["text"] =~ "<!channel> P1"
    assert notice.body["text"] =~ "<!channel> P0"
    assert Repo.get!(Incident, first.incident_key).slack_root_revision == 1
  end

  test "signed card actions claim once and only the owner can transfer" do
    assert {:ok, %{incident: original}} = AlertRouter.ingest(gcp_event(), route_mode: :shadow)
    assert %{failure: 0} = drain_delivery()
    incident = Repo.get!(Incident, original.incident_key)
    claim = %{"action_id" => "alert_claim"}
    assert push_action(incident, "UALICE", claim, secret: "forged").status == 401
    assert push_action(incident, "UALICE", claim, team: "TOTHER").status == 403

    assert push_action(%{incident | slack_root_ts: "1000000000.000001"}, "UALICE", claim).status ==
             200

    assert Repo.get!(Incident, incident.incident_key).owner == nil
    assert push_action(incident, "UALICE", claim).status == 200
    assert %{success: 2, failure: 0} = drain_delivery()
    card = last_root_update().body
    assert card["ts"] == incident.slack_root_ts
    assert Jason.encode!(card) =~ "UALICE"
    assert push_action(incident, "UBOB", claim).status == 409
    assert push_action(incident, "UALICE", claim).status == 200
    transfer = %{"action_id" => "alert_transfer", "selected_user" => "UCAROL"}
    assert push_action(incident, "UBOB", transfer).status == 409
    assert Repo.get!(Incident, incident.incident_key).owner == "UALICE"
    assert %{success: 0, failure: 0} = drain_delivery()
    assert push_action(incident, "UALICE", transfer).status == 200
    assert Repo.get!(Incident, incident.incident_key).owner == "UCAROL"
    assert %{success: 2, failure: 0} = drain_delivery()
    assert push_action(incident, "UALICE", %{transfer | "selected_user" => "UBOB"}).status == 409
    assert Repo.get!(Incident, incident.incident_key).owner == "UCAROL"
    old_block = "ar-#{AlertRouter.Slack.Renderer.incident_id(incident.incident_key)}-r1-ownership"
    assert push_action(incident, "UCAROL", Map.put(transfer, "block_id", old_block)).status == 409
    assert Repo.get!(Incident, incident.incident_key).owner == "UCAROL"
    before_feedback = Repo.get!(Incident, incident.incident_key)

    feedback = %{
      "action_id" => "alert_feedback",
      "selected_option" => %{"value" => "false_positive"}
    }

    assert push_action(incident, "UCAROL", feedback).status == 200
    assert %{success: 2, failure: 0} = drain_delivery()
    assert Jason.encode!(last_root_update().body) =~ "误报"
    classified = Repo.get!(Incident, incident.incident_key)
    assert classified.feedback["outcome"] == "false_positive"
    assert classified.feedback["author"] == "UCAROL"
    assert classified.handling_revision == before_feedback.handling_revision
    assert classified.state == "firing"
    assert classified.recovery_status == "not_applicable"
    assert push_action(incident, "UCAROL", feedback).status == 200
    assert %{success: 0, failure: 0} = drain_delivery()
    assert {:ok, _} = AlertRouter.ingest(gcp_event("closed"), route_mode: :shadow)
    assert %{failure: 0} = drain_delivery()
    assert Repo.get!(Incident, incident.incident_key).owner == "UCAROL"
    assert Repo.get!(Incident, incident.incident_key).recovery_status == "unknown"
    assert Repo.get!(Incident, incident.incident_key).feedback == classified.feedback
  end

  test "only the configured external investigator can update progress without a prefix" do
    assert {:ok, %{incident: original}} = AlertRouter.ingest(gcp_event(), route_mode: :shadow)
    assert %{failure: 0} = drain_delivery()
    incident = Repo.get!(Incident, original.incident_key)

    report = %{
      "type" => "message",
      "subtype" => "bot_message",
      "channel" => incident.channel_id,
      "thread_ts" => incident.slack_root_ts,
      "ts" => "#{System.system_time(:second) + 10}.000001",
      "bot_id" => "BINVESTIGATOR",
      "app_id" => "AINVESTIGATOR",
      "text" => "调查受阻：无法读取原始日志，实际用户影响仍未知。"
    }

    assert push_progress(report).status == 200
    assert push_progress(report, investigator_bot_id: "BOTHER").status == 200

    assert push_progress(%{report | "app_id" => "ATEST"}, investigator_bot_id: "BINVESTIGATOR").status ==
             200

    assert Repo.get!(Incident, incident.incident_key).progress == %{}
    assert push_progress(report, investigator_bot_id: "BINVESTIGATOR").status == 200
    assert %{success: 1, failure: 0} = drain_delivery()
    updated = Repo.get!(Incident, incident.incident_key)
    assert updated.progress["source"] == "investigator"
    assert updated.progress["text"] == report["text"]
    assert updated.recovery_status == "not_applicable"
    assert updated.owner == nil
    assert updated.handling_revision == 0

    incident
    |> Ecto.Changeset.change(owner: "UALICE")
    |> Repo.update!()

    duplicate_ts = "#{System.system_time(:second) + 12}.000001"

    assert push_progress(%{report | "ts" => duplicate_ts},
             investigator_bot_id: "BINVESTIGATOR"
           ).status == 200

    assert %{success: 0, failure: 0} = drain_delivery()

    assert push_progress(
             %{report | "text" => "旧调查结果", "ts" => "#{System.system_time(:second) + 11}.000001"},
             investigator_bot_id: "BINVESTIGATOR"
           ).status == 200

    latest = Repo.get!(Incident, incident.incident_key)
    assert latest.progress["text"] == report["text"]
    assert latest.progress["ts"] == duplicate_ts
    assert latest.handling_revision == updated.handling_revision
    assert latest.desired_revision == updated.desired_revision
    assert %{success: 0, failure: 0} = drain_delivery()
    card = last_root_update().body
    assert Jason.encode!(card) =~ "调查机器人回报"
    assert Jason.encode!(card) =~ "实际用户影响仍未知"

    long = %{
      report
      | "text" => String.duplicate("已确认", 1200),
        "ts" => "#{System.system_time(:second) + 13}.000001"
    }

    assert push_progress(long, investigator_bot_id: "BINVESTIGATOR").status == 200
    text = Repo.get!(Incident, incident.incident_key).progress["text"]
    assert String.valid?(text)
    assert byte_size(text) <= 4000
    assert String.ends_with?(text, "完整回报见原线程）")
  end

  test "overdue notices are bounded, target the channel or owner, and stop after new progress" do
    previous = Application.get_env(:alert_router, :slack_progress)

    Application.put_env(:alert_router, :slack_progress,
      signing_secret: "progress-test-secret",
      team_id: "TTEST",
      app_id: "ATEST"
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:alert_router, :slack_progress, previous),
        else: Application.delete_env(:alert_router, :slack_progress)
    end)

    event = %{gcp_event("open", project: "example-staging-project") | priority: "P1"}
    assert {:ok, %{incident: original}} = AlertRouter.ingest(event, route_mode: :live)
    assert %{success: 2, failure: 0} = drain_now()
    incident = Repo.get!(Incident, original.incident_key)
    [scheduled] = Repo.all(from(j in Oban.Job, where: j.worker == "AlertRouter.Workers.Remind"))
    assert DateTime.diff(scheduled.scheduled_at, scheduled.inserted_at) in 899..901
    assert :ok = AlertRouter.Workers.Remind.perform(scheduled)

    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.postMessage",
      {:commit, 500, %{"ok" => false, "error" => "internal_error"}}
    )

    assert %{success: 1, failure: 0} = drain_now()

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban, queue: :alert_reconciliation)

    notice =
      AlertRouter.MockSlackAPI.requests()
      |> Enum.reverse()
      |> Enum.find(&(&1.path == "/api/chat.postMessage"))

    assert notice.path == "/api/chat.postMessage"
    refute Map.has_key?(notice.body, "thread_ts")
    assert notice.body["text"] =~ "<!channel>"
    assert notice.body["text"] =~ "仍无人接手"
    assert :ok = AlertRouter.Workers.Remind.perform(scheduled)
    assert %{success: 0, failure: 0} = drain_now()

    assert push_action(incident, "UALICE", %{"action_id" => "alert_claim"}).status == 200
    assert %{success: 2, failure: 0} = drain_now()
    claim_notice = List.last(AlertRouter.MockSlackAPI.requests())
    refute Map.has_key?(claim_notice.body, "thread_ts")
    refute claim_notice.body["text"] =~ "<!channel>"
    assert claim_notice.body["text"] =~ "UALICE"
    assert :ok = AlertRouter.Workers.Remind.perform(scheduled)
    assert %{success: 0, failure: 0} = drain_now()

    [_, owner_due] =
      Repo.all(
        from(j in Oban.Job, where: j.worker == "AlertRouter.Workers.Remind", order_by: j.id)
      )

    assert DateTime.diff(owner_due.scheduled_at, owner_due.inserted_at) in 1799..1801
    assert :ok = AlertRouter.Workers.Remind.perform(owner_due)
    assert %{success: 1, failure: 0} = drain_now()
    assert List.last(AlertRouter.MockSlackAPI.requests()).body["text"] =~ "<@UALICE>"
    refute List.last(AlertRouter.MockSlackAPI.requests()).body["text"] =~ "<!channel>"

    report = %{
      "type" => "message",
      "channel" => incident.channel_id,
      "thread_ts" => incident.slack_root_ts,
      "ts" => "#{System.system_time(:second) + 10}.000001",
      "user" => "UALICE",
      "text" => "告警进展\n正在验证用户路径"
    }

    assert push_progress(report).status == 200
    assert %{success: 2, failure: 0} = drain_now()

    jobs =
      Repo.all(
        from(j in Oban.Job, where: j.worker == "AlertRouter.Workers.Remind", order_by: j.id)
      )

    assert length(jobs) == 3
    latest = List.last(jobs)
    assert :ok = AlertRouter.Workers.Remind.perform(latest)

    assert {:ok, _} =
             AlertRouter.ingest(gcp_event("closed", project: "example-staging-project"),
               route_mode: :live
             )

    count = length(AlertRouter.MockSlackAPI.requests())
    assert %{failure: 0} = drain_now()

    refute AlertRouter.MockSlackAPI.requests()
           |> Enum.drop(count)
           |> Enum.any?(fn r ->
             r.body["text"] && String.contains?(r.body["text"], "超过 30 分钟")
           end)

    assert :ok = AlertRouter.Workers.Remind.perform(latest)
    assert %{success: 0, failure: 0} = drain_now()
  end

  defp drain_now do
    Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery, with_recursion: true)
  end

  defp last_root_update do
    AlertRouter.MockSlackAPI.requests()
    |> Enum.reverse()
    |> Enum.find(&(&1.path == "/api/chat.update"))
  end

  defp push_action(incident, user, action, opts \\ []) do
    previous = Application.get_env(:alert_router, :slack_progress)

    Application.put_env(:alert_router, :slack_progress,
      signing_secret: "progress-test-secret",
      team_id: "TTEST",
      app_id: "ATEST"
    )

    try do
      latest = Repo.get!(Incident, incident.incident_key)

      block_id =
        "ar-#{AlertRouter.Slack.Renderer.incident_id(incident.incident_key)}-r#{latest.desired_revision}-ownership"

      action = Map.put_new(action, "block_id", block_id)

      payload = %{
        "type" => "block_actions",
        "team" => %{"id" => Keyword.get(opts, :team, "TTEST")},
        "api_app_id" => "ATEST",
        "user" => %{"id" => user},
        "container" => %{
          "channel_id" => incident.channel_id,
          "message_ts" => incident.slack_root_ts
        },
        "actions" => [action]
      }

      body = URI.encode_query(%{"payload" => Jason.encode!(payload)})
      timestamp = Integer.to_string(System.system_time(:second))

      signature =
        :crypto.mac(
          :hmac,
          :sha256,
          Keyword.get(opts, :secret, "progress-test-secret"),
          "v0:" <> timestamp <> ":" <> body
        )
        |> Base.encode16(case: :lower)

      conn(:post, "/v1/interactions/slack", body)
      |> put_req_header("x-slack-request-timestamp", timestamp)
      |> put_req_header("x-slack-signature", "v0=" <> signature)
      |> AlertRouter.Web.Router.call([])
    after
      if previous,
        do: Application.put_env(:alert_router, :slack_progress, previous),
        else: Application.delete_env(:alert_router, :slack_progress)
    end
  end

  defp push_progress(event, opts \\ []) do
    previous = Application.get_env(:alert_router, :slack_progress)

    Application.put_env(:alert_router, :slack_progress,
      signing_secret: "progress-test-secret",
      team_id: "TTEST",
      app_id: "ATEST",
      investigator_bot_id: Keyword.get(opts, :investigator_bot_id)
    )

    try do
      body =
        Jason.encode!(%{
          "type" => "event_callback",
          "team_id" => Keyword.get(opts, :team, "TTEST"),
          "api_app_id" => "ATEST",
          "event" => event
        })

      timestamp = Integer.to_string(System.system_time(:second) + Keyword.get(opts, :age, 0))

      signature =
        :crypto.mac(
          :hmac,
          :sha256,
          Keyword.get(opts, :secret, "progress-test-secret"),
          "v0:" <> timestamp <> ":" <> body
        )
        |> Base.encode16(case: :lower)

      conn(:post, "/v1/events/slack", body)
      |> put_req_header("x-slack-request-timestamp", timestamp)
      |> put_req_header("x-slack-signature", "v0=" <> signature)
      |> AlertRouter.Web.Router.call([])
    after
      if previous,
        do: Application.put_env(:alert_router, :slack_progress, previous),
        else: Application.delete_env(:alert_router, :slack_progress)
    end
  end

  test "live route posts the canonical root to the reviewed public alert channel" do
    assert {:ok, %{disposition: :accepted}} =
             AlertRouter.ingest(
               gcp_event("open", project: "example-staging-project"),
               route_mode: :live
             )

    assert %{success: 2, failure: 0} = drain_delivery()

    assert [post_root, firing_thread] = AlertRouter.MockSlackAPI.requests()
    assert post_root.path == "/api/chat.postMessage"
    assert post_root.body["channel"] == "C0BJ1699HSN"
    assert firing_thread.body["channel"] == "C0BJ1699HSN"
    assert is_binary(firing_thread.body["thread_ts"])
  end

  test "GKE OOM push reaches the alert channel once without claiming recovery or Comma attribution" do
    previous_mode = Application.fetch_env!(:alert_router, :mode)
    Application.put_env(:alert_router, :mode, :live)
    on_exit(fn -> Application.put_env(:alert_router, :mode, previous_mode) end)

    labels = %{
      "comma_policy_id" => "gke_oom_kill",
      "comma_priority" => "p2",
      "comma_domain" => "capacity",
      "managed_by" => "comma_alerting",
      "policy_version" => "v1",
      "environment" => "staging",
      "service" => "gke"
    }

    payload =
      gcp_payload("open", project: "example-staging-project")
      |> put_in(["incident", "policy_user_labels"], labels)

    assert %Plug.Conn{status: 202} = push_gcp(payload, "oom-open", "2026-04-24T03:13:20Z")
    assert %{success: 2, failure: 0} = drain_delivery()
    assert %Plug.Conn{status: 202} = push_gcp(payload, "oom-redelivery", "2026-04-24T03:13:20Z")
    assert %{success: 0, failure: 0} = drain_delivery()

    assert [root, thread] = AlertRouter.MockSlackAPI.requests()
    assert root.body["channel"] == "C0BJ1699HSN"
    assert thread.body["channel"] == "C0BJ1699HSN"
    text = Jason.encode!(root.body)
    assert text =~ "GKE 集群发生 OOM kill"
    assert text =~ "工作负载仍需定位"
    refute text =~ "<!channel>"
    refute text =~ "已恢复"

    production = gcp_payload("open") |> put_in(["incident", "policy_user_labels"], labels)
    assert {:error, _} = GCPMonitoring.normalize(production)
  end

  test "live P0 mentions the channel once on the firing root" do
    firing = p0_event("open")
    resolved = p0_event("closed")

    assert {:ok, %{disposition: :accepted}} =
             AlertRouter.ingest(firing, route_mode: :live)

    assert %{success: 2, failure: 0} = drain_delivery()

    assert {:ok, %{disposition: :accepted}} =
             AlertRouter.ingest(resolved, route_mode: :live)

    assert %{success: 2, failure: 0} = drain_delivery()

    assert [post_root, firing_thread, update_root, resolved_thread] =
             AlertRouter.MockSlackAPI.requests()

    assert post_root.path == "/api/chat.postMessage"
    assert post_root.body["text"] =~ "<!channel> P0"
    assert Jason.encode!(post_root.body["blocks"]) =~ "<!channel>"

    for request <- [firing_thread, update_root, resolved_thread] do
      refute Jason.encode!(request.body) =~ "<!channel>"
    end
  end

  test "authenticated GCP push persists and posts once; resolved updates the same root and appends Block Kit timeline" do
    firing = gcp_event()

    assert %Plug.Conn{status: 202, resp_body: firing_response} =
             push_gcp(gcp_payload(), "gcp-message-firing", "2026-04-24T03:13:20Z")

    assert Jason.decode!(firing_response) == %{"disposition" => "accepted"}
    assert %{success: 2, failure: 0} = drain_delivery()

    assert %Plug.Conn{status: 202, resp_body: duplicate_response} =
             push_gcp(gcp_payload(), "gcp-message-firing", "2026-04-24T03:13:20Z")

    assert Jason.decode!(duplicate_response) == %{"disposition" => "duplicate"}
    assert %{success: 0, failure: 0} = drain_delivery()

    assert %Plug.Conn{status: 202, resp_body: resolved_response} =
             push_gcp(gcp_payload("closed"), "gcp-message-resolved", "2026-04-24T03:21:40Z")

    assert Jason.decode!(resolved_response) == %{"disposition" => "accepted"}
    assert %{success: 2, failure: 0} = drain_delivery()

    incident = Repo.get!(Incident, firing.incident_key)
    assert incident.state == "resolved"
    assert incident.recovery_status == "unknown"
    assert incident.delivered_revision == 2

    assert Repo.aggregate(
             from(event in EventRecord,
               where:
                 event.incident_key == ^firing.incident_key and event.timeline_state == "posted"
             ),
             :count
           ) == 2

    assert [post_root, firing_thread, update_root, resolved_thread] =
             AlertRouter.MockSlackAPI.requests()

    assert post_root.path == "/api/chat.postMessage"
    assert post_root.authorization == ["Bearer xoxb-alert-router-test"]
    assert post_root.body["channel"] == "C0ALMF2AD70"
    refute Map.has_key?(post_root.body, "thread_ts")

    assert firing_thread.path == "/api/chat.postMessage"
    root_ts = firing_thread.body["thread_ts"]
    assert is_binary(root_ts)
    assert incident.slack_root_ts == root_ts

    assert update_root.path == "/api/chat.update"
    assert update_root.body["ts"] == root_ts

    assert resolved_thread.path == "/api/chat.postMessage"
    assert resolved_thread.body["thread_ts"] == root_ts

    firing_root = post_root.body
    firing_reply = firing_thread.body
    resolved_root = update_root.body
    resolved_reply = resolved_thread.body

    assert Enum.map(firing_root["blocks"], & &1["type"]) == ["container", "plan"]
    assert Enum.map(resolved_root["blocks"], & &1["type"]) == ["container", "plan"]

    assert get_in(resolved_root, ["blocks", Access.at(0), "title", "text"]) =~
             "来源已结束告警"

    refute get_in(resolved_root, ["blocks", Access.at(0), "title", "text"]) =~ "已恢复"

    firing_plan = get_in(firing_root, ["blocks", Access.at(1)])
    resolved_plan = get_in(resolved_root, ["blocks", Access.at(1)])

    assert firing_plan["title"] == "告警生命周期"

    assert Enum.map(firing_plan["tasks"], & &1["status"]) == [
             "pending"
           ]

    assert Enum.map(resolved_plan["tasks"], & &1["status"]) == [
             "complete",
             "pending"
           ]

    assert Enum.map(firing_plan["tasks"], & &1["title"]) == [
             "告警中 · open · 2026-04-24 03:06 UTC"
           ]

    assert Enum.map(resolved_plan["tasks"], & &1["title"]) == [
             "告警中 · open · 2026-04-24 03:06 UTC",
             "来源已结束告警 · closed · 2026-04-24 03:21 UTC · 服务恢复待确认"
           ]

    assert Enum.map(firing_plan["tasks"], & &1["task_id"]) ==
             Enum.take(Enum.map(resolved_plan["tasks"], & &1["task_id"]), 1)

    assert [%{"type" => "container"}] = firing_reply["blocks"]
    assert [%{"type" => "container"}] = resolved_reply["blocks"]

    assert get_in(resolved_reply, ["blocks", Access.at(0), "title", "text"]) =~
             "来源已结束告警"

    refute Jason.encode!(resolved_reply) =~ "已恢复"
  end

  defp p0_event(state) do
    labels = %{
      "comma_policy_id" => "external_session_runtime_failed",
      "comma_priority" => "p0",
      "comma_domain" => "availability",
      "managed_by" => "comma_alerting",
      "policy_version" => "v1",
      "environment" => "staging",
      "service" => "salix_agent"
    }

    state
    |> gcp_payload(project: "example-staging-project")
    |> put_in(["incident", "policy_user_labels"], labels)
    |> GCPMonitoring.normalize()
    |> then(fn {:ok, event} -> event end)
  end

  test "resolved lifecycle never regresses and conflicting reuse of an event id fails closed" do
    firing = gcp_event()
    resolved = gcp_event("closed")

    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(firing, route_mode: :shadow)
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(resolved, route_mode: :shadow)

    stale_firing = %{firing | event_id: "gcp:example-prod-project:message:late-open"}
    assert {:ok, %{disposition: :stale}} = AlertRouter.ingest(stale_firing, route_mode: :shadow)

    conflict = put_in(firing.evidence_values["observed"], "99%")

    assert {:error, {:event_contract_conflict, event_id}} =
             AlertRouter.ingest(conflict, route_mode: :shadow)

    assert event_id == firing.event_id
    assert Repo.get!(Incident, firing.incident_key).state == "resolved"
  end

  test "one generation cannot change its reviewed source or policy identity" do
    firing = gcp_event()

    assert {:ok, %{disposition: :accepted}} =
             AlertRouter.ingest(firing, route_mode: :shadow)

    attrs =
      firing
      |> Map.from_struct()
      |> Map.put(:policy_identity, ["gcp_monitoring", "comma_rfc11", "workload_unavailable"])
      |> put_in([:evidence_values, "observed"], "9.1%")

    assert {:ok, conflicting_identity} = AlertRouter.CanonicalEvent.build(attrs)
    refute conflicting_identity.event_id == firing.event_id

    assert {:error, {:generation_identity_conflict, _persisted, _incoming}} =
             AlertRouter.ingest(conflicting_identity, route_mode: :shadow)

    assert Repo.get!(Incident, firing.incident_key).policy_identity == firing.policy_identity
  end

  test "same-state latest-received evidence refreshes the root without growing the lifecycle timeline" do
    firing = gcp_event()

    assert %Plug.Conn{status: 202} =
             push_gcp(gcp_payload(), "gcp-message-firing", "2026-04-24T03:13:20Z")

    assert %{success: 2, failure: 0} = drain_delivery()

    refreshed_payload = put_in(gcp_payload(), ["incident", "observed_value"], "9.2%")

    assert %Plug.Conn{status: 202, resp_body: response} =
             push_gcp(refreshed_payload, "gcp-message-refresh", "2026-04-24T03:16:20Z")

    assert Jason.decode!(response) == %{"disposition" => "accepted"}
    assert %{success: 1, failure: 0} = drain_delivery()

    incident = Repo.get!(Incident, firing.incident_key)
    assert incident.state == "firing"
    assert incident.evidence_values["observed"] == "9.2%"
    assert incident.desired_revision == 2
    assert incident.delivered_revision == 2

    assert Repo.aggregate(
             from(event in EventRecord,
               where:
                 event.incident_key == ^firing.incident_key and event.timeline_state == "posted"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(event in EventRecord,
               where:
                 event.incident_key == ^firing.incident_key and event.timeline_state == "skipped"
             ),
             :count
           ) == 1

    assert [post_root, firing_thread, update_root] = AlertRouter.MockSlackAPI.requests()
    assert post_root.path == "/api/chat.postMessage"
    assert firing_thread.body["thread_ts"] == update_root.body["ts"]
    assert update_root.path == "/api/chat.update"
    assert Jason.encode!(update_root.body) =~ "9.2%"

    post_plan = get_in(post_root.body, ["blocks", Access.at(1)])
    update_plan = get_in(update_root.body, ["blocks", Access.at(1)])

    assert length(post_plan["tasks"]) == 1
    assert update_plan["tasks"] == post_plan["tasks"]
  end

  test "a new source status appends both the root timeline and a thread event" do
    firing = gcp_event()

    assert {:ok, %{disposition: :accepted}} =
             AlertRouter.ingest(firing, route_mode: :shadow)

    assert %{success: 2, failure: 0} = drain_delivery()

    acknowledged_attrs =
      firing
      |> Map.from_struct()
      |> Map.put(:source_state, "acknowledged")
      |> Map.put(:observed_at, ~U[2026-04-24 03:14:20.000000Z])

    assert {:ok, acknowledged} = AlertRouter.CanonicalEvent.build(acknowledged_attrs)
    assert acknowledged.latest == firing.latest

    assert {:ok, %{disposition: :accepted}} =
             AlertRouter.ingest(acknowledged, route_mode: :shadow)

    assert %{success: 2, failure: 0} = drain_delivery()

    assert [post_root, firing_thread, update_root, acknowledged_thread] =
             AlertRouter.MockSlackAPI.requests()

    post_plan = get_in(post_root.body, ["blocks", Access.at(1)])
    update_plan = get_in(update_root.body, ["blocks", Access.at(1)])

    assert Enum.map(post_plan["tasks"], & &1["title"]) == [
             "告警中 · open · 2026-04-24 03:06 UTC"
           ]

    assert Enum.map(update_plan["tasks"], & &1["title"]) == [
             "告警中 · open · 2026-04-24 03:06 UTC",
             "告警中 · acknowledged · 2026-04-24 03:14 UTC"
           ]

    assert firing_thread.body["thread_ts"] == update_root.body["ts"]
    assert acknowledged_thread.body["thread_ts"] == update_root.body["ts"]

    assert get_in(acknowledged_thread.body, ["blocks", Access.at(0), "title", "text"]) =~
             "告警中"
  end

  test "a lifecycle snapshot read failure rolls back before granting the first Slack mutation" do
    event = gcp_event()
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(event, route_mode: :shadow)

    Application.put_env(
      :alert_router,
      :lifecycle_event_reader,
      AlertRouter.FailingLifecycleEventReader
    )

    assert %{failure: 1} =
             Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    incident = Repo.get!(Incident, event.incident_key)
    assert incident.delivery_state == "pending"
    assert incident.delivery_attempt == 0
    assert incident.delivery_lease_token == nil
    assert AlertRouter.MockSlackAPI.requests() == []

    Application.put_env(
      :alert_router,
      :lifecycle_event_reader,
      AlertRouter.LifecycleEventReader.Repo
    )

    assert %{success: 2, failure: 0} = drain_delivery()
    assert Repo.get!(Incident, event.incident_key).delivery_state == "posted"
  end

  test "Slack 429 obeys Retry-After without creating an ambiguous root or a duplicate post" do
    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.postMessage",
      {:respond, 429, %{"ok" => false, "error" => "ratelimited"}, [{"retry-after", "7"}]}
    )

    event = gcp_event()
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(event, route_mode: :shadow)

    assert %{snoozed: 1, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    incident = Repo.get!(Incident, event.incident_key)
    assert incident.delivery_state == "pending"
    assert incident.delivery_attempt == 1
    assert incident.slack_root_ts == nil
    assert AlertRouter.MockSlackAPI.messages() == []

    assert %{success: 2, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban,
               queue: :alert_delivery,
               with_scheduled: true,
               with_recursion: true
             )

    requests = AlertRouter.MockSlackAPI.requests()

    assert Enum.count(
             requests,
             &(&1.path == "/api/chat.postMessage" and is_nil(&1.body["thread_ts"]))
           ) == 2

    assert Enum.count(AlertRouter.MockSlackAPI.messages(), &is_nil(&1["thread_ts"])) == 1
  end

  test "retryable root delivery stops at the persisted attempt budget" do
    for _attempt <- 1..5 do
      AlertRouter.MockSlackAPI.script_next(
        "/api/chat.postMessage",
        {:respond, 429, %{"ok" => false, "error" => "ratelimited"}, [{"retry-after", "1"}]}
      )
    end

    event = gcp_event()
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(event, route_mode: :shadow)

    assert %{snoozed: 5, discard: 1, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban,
               queue: :alert_delivery,
               with_scheduled: true,
               with_recursion: true
             )

    incident = Repo.get!(Incident, event.incident_key)
    assert incident.delivery_state == "dlq"
    assert incident.delivery_attempt == 5
    assert incident.last_error_class == "retry_exhausted"

    assert Enum.count(AlertRouter.MockSlackAPI.requests(), &(&1.path == "/api/chat.postMessage")) ==
             5

    assert AlertRouter.MockSlackAPI.messages() == []
  end

  test "ambiguous committed root is adopted from its Block Kit marker and never posted twice" do
    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.postMessage",
      {:commit, 500, %{"ok" => false, "error" => "internal_error"}}
    )

    event = gcp_event()
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(event, route_mode: :shadow)
    assert %{success: 1, failure: 0} = Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    incident = Repo.get!(Incident, event.incident_key)
    assert incident.delivery_state == "ambiguous"
    assert incident.slack_root_ts == nil
    assert Enum.count(AlertRouter.MockSlackAPI.messages(), &is_nil(&1["thread_ts"])) == 1

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban, queue: :alert_reconciliation)

    assert %{success: 2, failure: 0} = drain_delivery()

    incident = Repo.get!(Incident, event.incident_key)
    assert incident.delivery_state == "posted"
    assert is_binary(incident.slack_root_ts)

    requests = AlertRouter.MockSlackAPI.requests()
    assert Enum.count(requests, &(&1.path == "/api/conversations.history")) == 1

    assert Enum.count(
             requests,
             &(&1.path == "/api/chat.postMessage" and is_nil(&1.body["thread_ts"]))
           ) == 1

    assert Enum.count(AlertRouter.MockSlackAPI.messages(), &is_nil(&1["thread_ts"])) == 1
  end

  test "a replayed completed reconciliation re-derives lost delivery work from durable state" do
    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.postMessage",
      {:commit, 500, %{"ok" => false, "error" => "internal_error"}}
    )

    event = gcp_event()
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(event, route_mode: :shadow)
    assert %{success: 1, failure: 0} = Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban, queue: :alert_reconciliation)

    {deleted, _} =
      Repo.delete_all(
        from(job in Oban.Job,
          where: job.worker == "AlertRouter.Workers.DeliverIncident"
        )
      )

    assert deleted >= 1
    assert Repo.get!(EventRecord, event.event_id).timeline_state == "pending"

    reconcile_job = %Oban.Job{args: %{"incident_key" => event.incident_key}}
    assert :ok = AlertRouter.Workers.ReconcileRoot.perform(reconcile_job)
    assert %{success: 2, failure: 0} = drain_delivery()

    assert Repo.get!(EventRecord, event.event_id).timeline_state == "posted"

    requests = AlertRouter.MockSlackAPI.requests()

    assert Enum.count(
             requests,
             &(&1.path == "/api/chat.postMessage" and is_nil(&1.body["thread_ts"]))
           ) == 1

    assert Enum.count(
             requests,
             &(&1.path == "/api/chat.postMessage" and is_binary(&1.body["thread_ts"]))
           ) == 1
  end

  test "an unapproved shadow destination fails before persistence" do
    slack = Application.fetch_env!(:alert_router, :slack)

    Application.put_env(
      :alert_router,
      :slack,
      Keyword.put(slack, :routes, %{"shadow" => "C-production-alerts"})
    )

    response = push_gcp(gcp_payload(), "wrong-route", "2026-04-24T03:13:20Z")

    assert response.status == 503
    assert Jason.decode!(response.resp_body) == %{"error" => "unapproved_route_destination"}
    assert Repo.aggregate(Incident, :count) == 0
    assert Repo.aggregate(EventRecord, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "an ambiguous committed root update is read back at its exact timestamp before the timeline advances" do
    firing = gcp_event()
    resolved = gcp_event("closed")

    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(firing, route_mode: :shadow)
    assert %{success: 2, failure: 0} = drain_delivery()

    root_ts = Repo.get!(Incident, firing.incident_key).slack_root_ts

    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.update",
      {:commit, 200, %{"ok" => false, "error" => "internal_error"}}
    )

    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(resolved, route_mode: :shadow)
    assert %{success: 1, failure: 0} = Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    incident = Repo.get!(Incident, firing.incident_key)
    assert incident.delivery_state == "ambiguous"
    assert incident.slack_root_ts == root_ts
    assert incident.delivered_revision == 1

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban, queue: :alert_reconciliation)

    assert %{success: 2, failure: 0} = drain_delivery()

    incident = Repo.get!(Incident, firing.incident_key)
    assert incident.delivery_state == "posted"
    assert incident.delivered_revision == 2

    requests = AlertRouter.MockSlackAPI.requests()
    assert Enum.count(requests, &(&1.path == "/api/chat.update")) == 1

    assert [readback] = Enum.filter(requests, &(&1.path == "/api/conversations.history"))
    assert readback.query["latest"] == root_ts
    assert readback.query["inclusive"] == "true"
    assert readback.query["limit"] == "1"

    assert [root] = Enum.filter(AlertRouter.MockSlackAPI.messages(), &is_nil(&1["thread_ts"]))
    assert get_in(root, ["blocks", Access.at(0), "block_id"]) =~ "-r2-root"
  end

  test "an ambiguous uncommitted root update exhausts readback without a second update" do
    firing = gcp_event()
    resolved = gcp_event("closed")

    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(firing, route_mode: :shadow)
    assert %{success: 2, failure: 0} = drain_delivery()

    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.update",
      {:respond, 500, %{"ok" => false, "error" => "internal_error"}}
    )

    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(resolved, route_mode: :shadow)
    assert %{success: 1, failure: 0} = Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    assert %{snoozed: 2, discard: 1, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban,
               queue: :alert_reconciliation,
               with_scheduled: true,
               with_recursion: true
             )

    incident = Repo.get!(Incident, firing.incident_key)
    assert incident.delivery_state == "dlq"
    assert incident.delivered_revision == 1
    assert incident.reconcile_attempt == 3

    requests = AlertRouter.MockSlackAPI.requests()
    assert Enum.count(requests, &(&1.path == "/api/chat.update")) == 1
    assert Enum.count(requests, &(&1.path == "/api/conversations.history")) == 3

    assert [root] = Enum.filter(AlertRouter.MockSlackAPI.messages(), &is_nil(&1["thread_ts"]))
    assert get_in(root, ["blocks", Access.at(0), "block_id"]) =~ "-r1-root"
  end

  test "a newer projection cannot reopen a root DLQ after an ambiguous update" do
    firing = gcp_event()
    resolved = gcp_event("closed")

    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(firing, route_mode: :shadow)
    assert %{success: 2, failure: 0} = drain_delivery()

    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.update",
      {:respond, 500, %{"ok" => false, "error" => "internal_error"}}
    )

    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(resolved, route_mode: :shadow)
    assert %{success: 1, failure: 0} = Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    assert %{snoozed: 2, discard: 1, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban,
               queue: :alert_reconciliation,
               with_scheduled: true,
               with_recursion: true
             )

    refreshed = %{
      resolved
      | event_id: resolved.event_id <> ":refresh",
        evidence_values: Map.put(resolved.evidence_values, "observed", "0.8%")
    }

    assert {:ok, %{disposition: :accepted}} =
             AlertRouter.ingest(refreshed, route_mode: :shadow)

    assert %{discard: 1, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    incident = Repo.get!(Incident, firing.incident_key)
    assert incident.desired_revision == 3
    assert incident.delivered_revision == 1
    assert incident.delivery_state == "dlq"
    assert incident.ambiguous_revision == 2

    requests = AlertRouter.MockSlackAPI.requests()
    assert Enum.count(requests, &(&1.path == "/api/chat.update")) == 1

    assert [root] = Enum.filter(AlertRouter.MockSlackAPI.messages(), &is_nil(&1["thread_ts"]))
    assert get_in(root, ["blocks", Access.at(0), "block_id"]) =~ "-r1-root"
  end

  test "an expired root-update lease enters exact readback without granting another update" do
    firing = gcp_event()
    resolved = gcp_event("closed")

    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(firing, route_mode: :shadow)
    assert %{success: 2, failure: 0} = drain_delivery()
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(resolved, route_mode: :shadow)

    now = DateTime.utc_now()

    firing.incident_key
    |> then(&Repo.get!(Incident, &1))
    |> Incident.delivery_changeset(%{
      delivery_state: "posting",
      delivery_attempt: 1,
      delivery_attempt_revision: 2,
      ambiguous_revision: 2,
      ambiguous_since: DateTime.add(now, -5, :second),
      delivery_lease_token: Ecto.UUID.generate(),
      delivery_lease_revision: 2,
      delivery_lease_expires_at: DateTime.add(now, -1, :second)
    })
    |> Repo.update!()

    update_count =
      AlertRouter.MockSlackAPI.requests()
      |> Enum.count(&(&1.path == "/api/chat.update"))

    assert %{success: 1, failure: 0} = Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    incident = Repo.get!(Incident, firing.incident_key)
    assert incident.delivery_state == "ambiguous"
    assert incident.slack_root_ts != nil

    assert Enum.count(AlertRouter.MockSlackAPI.requests(), &(&1.path == "/api/chat.update")) ==
             update_count
  end

  test "incomplete Slack history exhausts a bounded reconciliation budget without reposting" do
    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.postMessage",
      {:respond, 500, %{"ok" => false, "error" => "internal_error"}}
    )

    AlertRouter.MockSlackAPI.set_complete(:history, false)

    event = gcp_event()
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(event, route_mode: :shadow)
    assert %{success: 1, failure: 0} = Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    assert %{snoozed: 2, discard: 1, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban,
               queue: :alert_reconciliation,
               with_scheduled: true,
               with_recursion: true
             )

    incident = Repo.get!(Incident, event.incident_key)
    assert incident.delivery_state == "dlq"
    assert incident.reconcile_attempt == 3
    assert incident.last_error_class == "retry_exhausted"
    assert incident.slack_root_ts == nil

    requests = AlertRouter.MockSlackAPI.requests()
    assert Enum.count(requests, &(&1.path == "/api/conversations.history")) == 3
    assert Enum.count(requests, &(&1.path == "/api/chat.postMessage")) == 1
    assert AlertRouter.MockSlackAPI.messages() == []
  end

  test "complete negative Slack history also exhausts reconciliation without reposting" do
    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.postMessage",
      {:respond, 500, %{"ok" => false, "error" => "internal_error"}}
    )

    event = gcp_event()
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(event, route_mode: :shadow)
    assert %{success: 1, failure: 0} = Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    assert %{snoozed: 2, discard: 1, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban,
               queue: :alert_reconciliation,
               with_scheduled: true,
               with_recursion: true
             )

    incident = Repo.get!(Incident, event.incident_key)
    assert incident.delivery_state == "dlq"
    assert incident.reconcile_attempt == 3
    assert incident.slack_root_ts == nil

    requests = AlertRouter.MockSlackAPI.requests()
    assert Enum.count(requests, &(&1.path == "/api/conversations.history")) == 3
    assert Enum.count(requests, &(&1.path == "/api/chat.postMessage")) == 1
  end

  test "an expired initial-post lease enters reconciliation without granting another send" do
    event = gcp_event()
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(event, route_mode: :shadow)

    now = DateTime.utc_now()

    event.incident_key
    |> then(&Repo.get!(Incident, &1))
    |> Incident.delivery_changeset(%{
      delivery_state: "posting",
      delivery_attempt: 1,
      delivery_attempt_revision: 1,
      ambiguous_revision: 1,
      ambiguous_since: DateTime.add(now, -5, :second),
      delivery_lease_token: Ecto.UUID.generate(),
      delivery_lease_revision: 1,
      delivery_lease_expires_at: DateTime.add(now, -1, :second)
    })
    |> Repo.update!()

    assert %{success: 1, failure: 0} = Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    incident = Repo.get!(Incident, event.incident_key)
    assert incident.delivery_state == "ambiguous"
    assert incident.slack_root_ts == nil
    assert AlertRouter.MockSlackAPI.requests() == []
  end

  test "two workers overlapping across the external call receive only one send permission" do
    event = gcp_event()
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(event, route_mode: :shadow)

    incident = Repo.get!(Incident, event.incident_key)
    ref = make_ref()

    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.postMessage",
      {:gate_commit, self(), ref}
    )

    job = %Oban.Job{
      args: %{
        "incident_key" => incident.incident_key,
        "render_revision" => incident.desired_revision,
        "route_revision" => incident.route_revision
      }
    }

    first = Task.async(fn -> AlertRouter.Workers.DeliverIncident.perform(job) end)
    assert_receive {:mock_slack_gate, ^ref, gate_pid}, 1_000

    second = Task.async(fn -> AlertRouter.Workers.DeliverIncident.perform(job) end)
    assert {:snooze, seconds} = Task.await(second)
    assert seconds > 0

    send(gate_pid, {:release_mock_slack_gate, ref})
    assert :ok = Task.await(first)

    requests = AlertRouter.MockSlackAPI.requests()
    assert Enum.count(requests, &(&1.path == "/api/chat.postMessage")) == 1
    assert Enum.count(AlertRouter.MockSlackAPI.messages(), &is_nil(&1["thread_ts"])) == 1
  end

  test "ambiguous committed timeline reply is adopted without a second thread post" do
    event = gcp_event()
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(event, route_mode: :shadow)

    assert %{success: 1, failure: 0} = Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.postMessage",
      {:commit, 500, %{"ok" => false, "error" => "internal_error"}}
    )

    assert %{success: 1, failure: 0} = Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    record = Repo.get!(EventRecord, event.event_id)
    assert record.timeline_state == "ambiguous"
    assert record.slack_reply_ts == nil

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban, queue: :alert_reconciliation)

    record = Repo.get!(EventRecord, event.event_id)
    assert record.timeline_state == "posted"
    assert is_binary(record.slack_reply_ts)

    requests = AlertRouter.MockSlackAPI.requests()
    assert Enum.count(requests, &(&1.path == "/api/conversations.replies")) == 1
    assert Enum.count(requests, &is_binary(&1.body["thread_ts"])) == 1
    assert Enum.count(AlertRouter.MockSlackAPI.messages(), &is_binary(&1["thread_ts"])) == 1
  end

  test "incomplete timeline lookup terminates in DLQ without posting a replacement reply" do
    event = gcp_event()
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(event, route_mode: :shadow)
    assert %{success: 1, failure: 0} = Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.postMessage",
      {:respond, 500, %{"ok" => false, "error" => "internal_error"}}
    )

    AlertRouter.MockSlackAPI.set_complete(:replies, false)
    assert %{success: 1, failure: 0} = Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    assert %{snoozed: 2, discard: 1, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban,
               queue: :alert_reconciliation,
               with_scheduled: true,
               with_recursion: true
             )

    record = Repo.get!(EventRecord, event.event_id)
    assert record.timeline_state == "dlq"
    assert record.reconcile_attempt == 3
    assert record.slack_reply_ts == nil

    requests = AlertRouter.MockSlackAPI.requests()
    assert Enum.count(requests, &(&1.path == "/api/conversations.replies")) == 3
    assert Enum.count(requests, &is_binary(&1.body["thread_ts"])) == 1
    assert Enum.count(AlertRouter.MockSlackAPI.messages(), &is_binary(&1["thread_ts"])) == 0
  end

  test "a later timeline event is DLQed behind an unresolved ambiguous predecessor" do
    firing = gcp_event()
    resolved = gcp_event("closed")

    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(firing, route_mode: :shadow)
    assert %{success: 1, failure: 0} = Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.postMessage",
      {:respond, 500, %{"ok" => false, "error" => "internal_error"}}
    )

    assert %{success: 1, failure: 0} = Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    assert %{snoozed: 2, discard: 1, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban,
               queue: :alert_reconciliation,
               with_scheduled: true,
               with_recursion: true
             )

    assert Repo.get!(EventRecord, firing.event_id).timeline_state == "dlq"

    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(resolved, route_mode: :shadow)

    assert %{success: 1, discard: 1, failure: 0} = drain_delivery()

    incident = Repo.get!(Incident, firing.incident_key)
    assert incident.state == "resolved"
    assert incident.delivered_revision == 2

    resolved_record = Repo.get!(EventRecord, resolved.event_id)
    assert resolved_record.timeline_state == "dlq"
    assert resolved_record.last_error_class == "predecessor_ambiguity"

    requests = AlertRouter.MockSlackAPI.requests()

    assert Enum.count(
             requests,
             &(&1.path == "/api/chat.postMessage" and is_binary(&1.body["thread_ts"]))
           ) == 1

    assert Enum.count(AlertRouter.MockSlackAPI.messages(), &is_binary(&1["thread_ts"])) == 0
  end

  test "a permanent Slack rejection goes directly to DLQ" do
    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.postMessage",
      {:respond, 400, %{"ok" => false, "error" => "invalid_blocks"}}
    )

    event = gcp_event()
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(event, route_mode: :shadow)

    assert %{discard: 1, failure: 0} =
             Oban.drain_queue(AlertRouter.Oban, queue: :alert_delivery)

    incident = Repo.get!(Incident, event.incident_key)
    assert incident.delivery_state == "dlq"
    assert is_nil(incident.ambiguous_revision)
    assert is_nil(incident.ambiguous_since)
    assert incident.last_error_class == "provider"
    assert incident.delivery_attempt == 1

    assert Enum.count(AlertRouter.MockSlackAPI.requests(), &(&1.path == "/api/chat.postMessage")) ==
             1
  end

  test "a permanent timeline rejection does not masquerade as an ambiguous predecessor" do
    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.postMessage",
      {:respond, 200, %{"ok" => true, "ts" => "1787301390.000001"}}
    )

    AlertRouter.MockSlackAPI.script_next(
      "/api/chat.postMessage",
      {:respond, 400, %{"ok" => false, "error" => "invalid_blocks"}}
    )

    firing = gcp_event()
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(firing, route_mode: :shadow)
    assert %{success: 1, discard: 1, failure: 0} = drain_delivery()

    firing_record = Repo.get!(EventRecord, firing.event_id)
    assert firing_record.timeline_state == "dlq"
    assert is_nil(firing_record.ambiguous_since)

    resolved = gcp_event("closed")
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(resolved, route_mode: :shadow)
    assert %{success: 2, discard: 0, failure: 0} = drain_delivery()

    resolved_record = Repo.get!(EventRecord, resolved.event_id)
    assert resolved_record.timeline_state == "posted"
    refute resolved_record.last_error_class == "predecessor_ambiguity"
  end

  test "an in-flight incident on a previous route rejects migration without a drain" do
    event = gcp_event()
    assert {:ok, %{disposition: :accepted}} = AlertRouter.ingest(event, route_mode: :shadow)

    Incident
    |> Repo.get!(event.incident_key)
    |> Ecto.Changeset.change(channel_id: "C-previous-shadow-route")
    |> Repo.update!()

    response =
      push_gcp(gcp_payload("closed"), "gcp-message-resolved", "2026-04-24T03:21:40Z")

    assert response.status == 409
    assert Jason.decode!(response.resp_body) == %{"error" => "route_change_requires_drain"}

    incident = Repo.get!(Incident, event.incident_key)
    assert incident.channel_id == "C-previous-shadow-route"
    assert incident.desired_revision == 1
  end

  test "Grafana HMAC webhook crosses persistence and the same Slack renderer" do
    assert %Plug.Conn{status: 202, resp_body: response} = push_grafana(grafana_payload())
    assert Jason.decode!(response) == %{"dispositions" => ["accepted"]}
    assert %{success: 2, failure: 0} = drain_delivery()

    assert [incident] = Repo.all(Incident)
    assert incident.source == "grafana"
    assert incident.delivery_state == "posted"

    assert [root, timeline] = AlertRouter.MockSlackAPI.requests()
    assert Enum.map(root.body["blocks"], & &1["type"]) == ["container", "plan"]
    assert [%{"type" => "container"}] = timeline.body["blocks"]

    metrics =
      root.body["blocks"]
      |> hd()
      |> Map.fetch!("child_blocks")
      |> Enum.find(&(&1["type"] == "table"))

    assert get_in(metrics, ["rows", Access.at(1), Access.at(0), "text"]) == "13%"
  end

  test "GitHub workflow webhook crosses authentication, persistence, and Slack delivery" do
    assert %Plug.Conn{status: 202, resp_body: response} =
             push_github(github_actions_payload())

    assert Jason.decode!(response) == %{"disposition" => "accepted"}
    assert %{success: 2, failure: 0} = drain_delivery()

    assert [incident] = Repo.all(Incident)
    assert incident.source == "github_actions"
    assert incident.source_state == "failure"
    assert incident.environment == "staging"
    assert incident.delivery_state == "posted"

    assert [root, timeline] = AlertRouter.MockSlackAPI.requests()
    assert Jason.encode!(root.body["blocks"]) =~ "Comma staging 部署失败"
    assert Jason.encode!(root.body["blocks"]) =~ "failure"
    assert Jason.encode!(timeline.body["blocks"]) =~ "失败或取消"

    assert %Plug.Conn{status: 202, resp_body: duplicate_response} =
             push_github(github_actions_payload())

    assert Jason.decode!(duplicate_response) == %{"disposition" => "duplicate"}
    assert %{success: 0, failure: 0} = drain_delivery()
  end

  test "GitHub workflow webhook acknowledges unrelated completions without persistence" do
    assert %Plug.Conn{status: 202, resp_body: response} =
             push_github(github_actions_payload("success"))

    assert Jason.decode!(response) == %{"disposition" => "ignored"}
    assert Repo.aggregate(Incident, :count) == 0
    assert Repo.aggregate(EventRecord, :count) == 0
  end

  test "GitHub webhook acknowledges its signed ping without persistence" do
    assert %Plug.Conn{status: 202, resp_body: response} =
             push_github(%{"hook_id" => 42, "zen" => "Keep it logically awesome."}, "ping")

    assert Jason.decode!(response) == %{"disposition" => "ignored"}
    assert Repo.aggregate(Incident, :count) == 0
    assert Repo.aggregate(EventRecord, :count) == 0
  end

  test "GCP webhook rejects a missing bearer before persistence" do
    envelope = %{
      "message" => %{
        "data" => gcp_payload() |> Jason.encode!() |> Base.encode64(),
        "messageId" => "unauthorized-message",
        "publishTime" => "2026-04-24T03:13:20Z"
      }
    }

    response =
      conn(:post, "/v1/events/gcp", Jason.encode!(envelope))
      |> put_req_header("content-type", "application/json")
      |> AlertRouter.Web.Router.call([])

    assert response.status == 401
    assert Repo.aggregate(Incident, :count) == 0
    assert Repo.aggregate(EventRecord, :count) == 0
  end

  defp drain_delivery do
    Oban.drain_queue(AlertRouter.Oban,
      queue: :alert_delivery,
      with_scheduled: true,
      with_recursion: true
    )
  end

  defp push_gcp(payload, message_id, publish_time) do
    envelope = %{
      "message" => %{
        "data" => payload |> Jason.encode!() |> Base.encode64(),
        "messageId" => message_id,
        "publishTime" => publish_time
      },
      "subscription" => "projects/example-prod-project/subscriptions/alert-router-shadow"
    }

    conn(:post, "/v1/events/gcp", Jason.encode!(envelope))
    |> put_req_header("authorization", "Bearer test-google-signed-jwt")
    |> put_req_header("content-type", "application/json")
    |> AlertRouter.Web.Router.call([])
  end

  defp push_grafana(payload) do
    body = Jason.encode!(payload)
    timestamp = System.system_time(:second) |> Integer.to_string()

    signature =
      :crypto.mac(
        :hmac,
        :sha256,
        "alert-router-grafana-test-secret",
        timestamp <> ":" <> body
      )
      |> Base.encode16(case: :lower)

    conn(:post, "/v1/events/grafana", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-grafana-alerting-signature", signature)
    |> put_req_header("x-grafana-alerting-signature-timestamp", timestamp)
    |> AlertRouter.Web.Router.call([])
  end

  defp push_github(payload, event \\ "workflow_run") do
    body = Jason.encode!(payload)

    signature =
      :crypto.mac(:hmac, :sha256, "alert-router-github-webhook-test-secret", body)
      |> Base.encode16(case: :lower)

    conn(:post, "/v1/events/github", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-hub-signature-256", "sha256=" <> signature)
    |> put_req_header("x-github-event", event)
    |> put_req_header("x-github-delivery", "72d3162e-cc78-11e3-81ab-4c9367dc0958")
    |> AlertRouter.Web.Router.call([])
  end
end
