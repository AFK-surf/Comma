defmodule AlertRouter.SlackRendererTest do
  use ExUnit.Case, async: true

  import AlertRouter.TestFixtures

  alias AlertRouter.Data.{EventRecord, Incident}
  alias AlertRouter.Slack.{MessageMarker, Renderer}

  test "root lifecycle plan appends every observed state with its event time" do
    firing_event = gcp_event()
    incident = incident(firing_event)
    firing_record = event_record(firing_event, 1)

    acknowledged_record = %{
      firing_record
      | event_id: "gcp:example-prod-project:message:acknowledged",
        source_state: "acknowledged",
        observed_at: ~U[2026-04-24 03:14:20.000000Z],
        render_revision: 2,
        canonical_payload:
          Map.put(firing_record.canonical_payload, "source_state", "acknowledged")
    }

    terminal_event =
      gcp_event("closed", observed_at: ~U[2026-04-24 03:21:40.000000Z])

    terminal = incident(terminal_event)
    terminal_record = event_record(terminal_event, 3)

    verified_record = %{
      terminal_record
      | event_id: "gcp:example-prod-project:message:recovery-verified",
        observed_at: ~U[2026-04-24 03:25:00.000000Z],
        render_revision: 4,
        canonical_payload:
          Map.put(terminal_record.canonical_payload, "recovery_status", "verified")
    }

    first = Renderer.root(incident, 1, lifecycle_events: [firing_record])

    acknowledged =
      Renderer.root(%{incident | desired_revision: 2}, 2,
        lifecycle_events: [firing_record, acknowledged_record]
      )

    second =
      Renderer.root(terminal, 3,
        lifecycle_events: [firing_record, acknowledged_record, terminal_record]
      )

    verified =
      Renderer.root(%{terminal | recovery_status: "verified"}, 4,
        lifecycle_events: [
          firing_record,
          acknowledged_record,
          terminal_record,
          verified_record
        ]
      )

    assert Enum.map(first["blocks"], & &1["type"]) == ["container", "plan"]
    assert Enum.map(second["blocks"], & &1["type"]) == ["container", "plan"]

    refute Enum.map(first["blocks"], & &1["block_id"]) ==
             Enum.map(second["blocks"], & &1["block_id"])

    firing_plan = Enum.at(first["blocks"], 1)
    terminal_plan = Enum.at(second["blocks"], 1)
    verified_plan = Enum.at(verified["blocks"], 1)

    acknowledged_plan = Enum.at(acknowledged["blocks"], 1)

    assert Enum.take(Enum.map(acknowledged_plan["tasks"], & &1["task_id"]), 1) ==
             Enum.map(firing_plan["tasks"], & &1["task_id"])

    assert Enum.take(Enum.map(terminal_plan["tasks"], & &1["task_id"]), 2) ==
             Enum.map(acknowledged_plan["tasks"], & &1["task_id"])

    assert Enum.map(firing_plan["tasks"], & &1["title"]) == [
             "告警中 · open · 2026-04-24 03:06 UTC"
           ]

    assert Enum.map(firing_plan["tasks"], & &1["status"]) == [
             "pending"
           ]

    assert Enum.map(acknowledged_plan["tasks"], & &1["title"]) == [
             "告警中 · open · 2026-04-24 03:06 UTC",
             "告警中 · acknowledged · 2026-04-24 03:14 UTC"
           ]

    assert Enum.map(acknowledged_plan["tasks"], & &1["status"]) == [
             "complete",
             "pending"
           ]

    assert Enum.map(terminal_plan["tasks"], & &1["title"]) == [
             "告警中 · open · 2026-04-24 03:06 UTC",
             "告警中 · acknowledged · 2026-04-24 03:14 UTC",
             "来源已结束告警 · closed · 2026-04-24 03:21 UTC · 服务恢复待确认"
           ]

    assert Enum.map(terminal_plan["tasks"], & &1["status"]) == [
             "complete",
             "complete",
             "pending"
           ]

    assert Enum.map(verified_plan["tasks"], & &1["title"]) == [
             "告警中 · open · 2026-04-24 03:06 UTC",
             "告警中 · acknowledged · 2026-04-24 03:14 UTC",
             "来源已结束告警 · closed · 2026-04-24 03:21 UTC · 服务恢复待确认",
             "已确认恢复 · closed · 2026-04-24 03:25 UTC"
           ]

    assert Enum.all?(verified_plan["tasks"], &(&1["status"] == "complete"))

    assert get_in(first, ["blocks", Access.at(0), "title", "emoji"]) == false
    assert get_in(first, ["blocks", Access.at(0), "title", "text"]) =~ "告警中"
    assert get_in(second, ["blocks", Access.at(0), "title", "text"]) =~ "来源已结束告警"
    refute get_in(second, ["blocks", Access.at(0), "title", "text"]) =~ "已恢复"
    assert firing_plan["title"] == "告警生命周期"

    assert get_in(child_block(first, "metrics"), ["rows", Access.at(0), Access.at(0), "text"]) ==
             "最新值"

    assert get_in(first, [
             "blocks",
             Access.at(0),
             "child_blocks",
             Access.at(0),
             "elements",
             Access.at(0)
           ]) == %{
             "type" => "image",
             "image_url" =>
               "https://cloud.google.com/images/social-icon-google-cloud-1200-630.png",
             "alt_text" => "Google Cloud"
           }

    assert get_in(verified, ["blocks", Access.at(0), "title", "text"]) =~ "已确认恢复"

    unknown_body =
      child_block(second, "status")["text"]["text"]

    verified_body =
      child_block(verified, "status")["text"]["text"]

    assert unknown_body =~ "来源已结束告警，服务恢复待确认。"
    assert second["text"] =~ "来源已结束告警，服务恢复待确认。"
    assert verified_body =~ "本次告警对应的故障已由正向证据确认恢复。"
    refute verified_body =~ "待确认"
    assert verified["text"] =~ "本次告警对应的故障已由正向证据确认恢复。"
    refute verified["text"] =~ "待确认"

    assert %{kind: :root, render_revision: 1} = MessageMarker.identify(first)
    assert %{kind: :root, render_revision: 3} = MessageMarker.identify(second)
    refute Map.has_key?(first, "metadata")
    assert get_in(first, ["blocks", Access.at(0), "title", "text"]) =~ "🔴"
    refute Jason.encode!(first) =~ ~r/\b(?:FIRING|CURRENT|THRESHOLD|DURATION|Latest|Owner)\b/
  end

  test "P0 recovery exhaustion keeps original evidence and actions with the requested context" do
    evidence = %{
      "observed" => "1",
      "threshold" => ">= 1 个自动恢复耗尽事件",
      "duration" => "单次事件",
      "cluster" => "example-cluster",
      "tenant" => "tenant-demo",
      "agent_group" => "support-agents",
      "agent" => "agent-01",
      "session" => "session-01",
      "trigger_error" => "recovery_exhausted"
    }

    p0 = %{
      incident(gcp_event())
      | priority: "P0",
        policy_identity: [
          "gcp_monitoring",
          "comma_alerting",
          "external_session_runtime_failed"
        ],
        service: "salix_agent",
        evidence_values: evidence,
        route_id: "live"
    }

    firing = Renderer.root(p0, 1, channel_mention: true)
    assert child_block(firing, "progress")["text"]["text"] =~ "尚无调查回报"

    assert get_in(child_block(firing, "source"), ["elements", Access.at(0)]) == %{
             "type" => "image",
             "image_url" =>
               "https://cloud.google.com/images/social-icon-google-cloud-1200-630.png",
             "alt_text" => "Google Cloud"
           }

    title = get_in(firing, ["blocks", Access.at(0), "title", "text"])
    assert title =~ "🔴 P0 · 告警中"

    source = child_block(firing, "source") |> Jason.encode!()
    assert source =~ "2026-04-24 03:06 UTC"
    assert source =~ "负责人 未指派"

    assert get_in(firing, ["blocks", Access.at(0), "subtitle", "text"]) ==
             "production · salix_agent · example-cluster"

    runtime = child_block(firing, "diagnostic-context") |> Jason.encode!()

    for value <- [
          "tenant-demo",
          "support-agents",
          "agent-01",
          "session-01"
        ] do
      assert runtime =~ value
    end

    metrics = child_block(firing, "metrics")
    assert metrics["type"] == "table"
    assert Enum.map(Enum.at(metrics["rows"], 0), & &1["text"]) == ["最新值", "触发阈值", "窗口"]
    status = child_block(firing, "status") |> Jason.encode!()
    assert status =~ "recovery_exhausted"
    refute status =~ "Runtime 进程异常退出"
    assert status =~ "告警状态"
    assert status =~ "影响"

    actions = child_block(firing, "actions")

    assert Enum.map(actions["elements"], &get_in(&1, ["text", "text"])) ==
             ["打开事件", "查看仪表盘", "查看处置手册"]

    source_terminal =
      Renderer.root(%{p0 | state: "resolved", recovery_status: "unknown"}, 2)

    verified =
      Renderer.root(%{p0 | state: "resolved", recovery_status: "verified"}, 3)

    assert get_in(source_terminal, ["blocks", Access.at(0), "title", "text"]) =~
             "🟡 P0 · 来源已结束告警"

    assert get_in(verified, ["blocks", Access.at(0), "title", "text"]) =~
             "🟢 P0 · 已确认恢复"
  end

  test "normalized runtime P1 and exhaustion P0 use one card and never equate source closure with recovery" do
    for {policy, priority, issue} <- [
          {"external_session_runtime_interrupted", "P1", "执行异常"},
          {"external_session_runtime_failed", "P0", "recovery_exhausted"}
        ] do
      payload =
        gcp_payload()
        |> put_in(["incident", "policy_user_labels"], %{
          "comma_policy_id" => policy,
          "comma_priority" => String.downcase(priority),
          "comma_domain" => "availability",
          "managed_by" => "comma_alerting",
          "service" => "salix_agent"
        })

      assert {:ok, event} = AlertRouter.Adapters.GCPMonitoring.normalize(payload)
      root = Renderer.root(%{incident(event) | route_id: "live"}, 1, channel_mention: true)
      assert get_in(root, ["blocks", Access.at(0), "title", "text"]) =~ "🔴 #{priority}"
      assert child_block(root, "status")["text"]["text"] =~ issue
      assert child_block(root, "metrics")["type"] == "table"
      assert Jason.encode!(root) =~ "<!channel>" == priority in ["P0", "P1"]

      closed =
        payload
        |> put_in(["incident", "state"], "closed")
        |> put_in(["incident", "ended_at"], 1_777_000_000)

      assert {:ok, terminal} = AlertRouter.Adapters.GCPMonitoring.normalize(closed)
      assert terminal.recovery_status == "unknown"
      card = Renderer.root(incident(terminal), 2)
      assert get_in(card, ["blocks", Access.at(0), "title", "text"]) =~ "🟡 #{priority}"
      refute Jason.encode!(card) =~ "已确认恢复"
    end
  end

  test "diagnostic context omits absent fields without guessing values" do
    p0 = %{
      incident(gcp_event())
      | priority: "P0",
        policy_identity: [
          "gcp_monitoring",
          "comma_alerting",
          "external_session_runtime_failed"
        ]
    }

    assert Renderer.root(p0, 1) |> child_block("diagnostic-context") == nil

    partial = %{p0 | evidence_values: %{"tenant" => "tenant-demo", "session" => " "}}
    context = Renderer.root(partial, 1) |> child_block("diagnostic-context") |> Jason.encode!()
    assert context =~ "Tenant"
    assert context =~ "tenant-demo"
    refute context =~ "Agent Group"
    refute context =~ "Session"
    refute context =~ "未提供"
  end

  test "timeline updates are Block Kit cards rather than plain text replies" do
    incident = incident(gcp_event())

    event = %EventRecord{
      event_id: "event-1",
      incident_key: incident.incident_key,
      state: "firing",
      observed_at: incident.observed_at,
      render_revision: 1
    }

    payload = Renderer.timeline(event, incident)

    assert [%{"type" => "container", "child_blocks" => child_blocks}] = payload["blocks"]
    assert Enum.map(child_blocks, & &1["type"]) == ["context", "section", "context"]
    assert get_in(payload, ["blocks", Access.at(0), "title", "text"]) =~ "告警中"

    assert get_in(payload, ["blocks", Access.at(0), "child_blocks", Access.at(1), "text", "text"]) =~
             "最新状态"

    assert %{kind: :timeline, render_revision: 1} = MessageMarker.identify(payload)
    refute Map.has_key?(payload, "metadata")
  end

  test "only accepted channel escalations mention, excluding legacy thread deliveries" do
    root = %{incident(gcp_event()) | source: "salix_runtime", route_id: "live", priority: "P0"}

    event = %EventRecord{
      event_id: "escalation",
      canonical_payload: %{"channel_notification" => true},
      incident_key: root.incident_key,
      state: "firing",
      source_state: "recovery_exhausted",
      render_revision: 2,
      observed_at: root.observed_at
    }

    assert Jason.encode!(Renderer.timeline(event, root)) =~ "<!channel>"

    refute Jason.encode!(Renderer.timeline(%{event | canonical_payload: %{}}, root)) =~
             "<!channel>"

    refute Jason.encode!(Renderer.timeline(event, %{root | slack_root_revision: 2})) =~
             "<!channel>"

    refute Jason.encode!(Renderer.timeline(%{event | render_revision: 1}, root)) =~ "<!channel>"
    refute Jason.encode!(Renderer.timeline(event, %{root | route_id: "shadow"})) =~ "<!channel>"

    refute Jason.encode!(
             Renderer.timeline(
               %{event | source_state: "runtime_recovered", state: "resolved"},
               root
             )
           ) =~ "<!channel>"
  end

  test "only live P0 and P1 firing roots can render the channel-wide mention" do
    p0 = %{incident(gcp_event()) | priority: "P0", route_id: "live"}

    firing = Renderer.root(p0, 1, channel_mention: true)
    p1 = Renderer.root(%{p0 | priority: "P1"}, 1, channel_mention: true)
    update = Renderer.root(p0, 2)
    shadow = Renderer.root(%{p0 | route_id: "shadow"}, 1, channel_mention: true)

    resolved =
      Renderer.root(%{p0 | state: "resolved", recovery_status: "unknown"}, 2,
        channel_mention: true
      )

    assert String.starts_with?(firing["text"], "<!channel> P0")

    assert get_in(firing, [
             "blocks",
             Access.at(0),
             "child_blocks",
             Access.at(0),
             "text",
             "text"
           ]) == "<!channel> *P0 全员告警*"

    assert p1["text"] =~ "<!channel> P1"

    for payload <- [update, shadow, resolved] do
      refute Jason.encode!(payload) =~ "<!channel>"
    end
  end

  test "verified recovery uses one display projection without rewriting canonical latest" do
    terminal = %{
      incident(gcp_event())
      | state: "resolved",
        recovery_status: "verified",
        latest: "来源已结束告警，服务恢复待确认。"
    }

    event = %EventRecord{
      event_id: "event-verified",
      incident_key: terminal.incident_key,
      state: "resolved",
      observed_at: terminal.observed_at,
      render_revision: 2,
      canonical_payload: %{
        "source" => terminal.source,
        "summary" => terminal.summary,
        "latest" => terminal.latest,
        "recovery_status" => "verified"
      }
    }

    payload = Renderer.timeline(event, terminal)
    body = get_in(payload, ["blocks", Access.at(0), "child_blocks", Access.at(1), "text", "text"])

    assert body =~ "本次告警对应的故障已由正向证据确认恢复。"
    refute body =~ "待确认"
    assert terminal.latest == "来源已结束告警，服务恢复待确认。"
  end

  test "a delayed timeline render uses the event snapshot rather than the newer root projection" do
    firing = gcp_event()

    incident = %{
      incident(firing)
      | state: "resolved",
        recovery_status: "unknown",
        latest: "The source incident has recovered."
    }

    event = %EventRecord{
      event_id: firing.event_id,
      incident_key: incident.incident_key,
      state: "firing",
      observed_at: firing.observed_at,
      render_revision: 1,
      canonical_payload: %{
        "source" => firing.source,
        "summary" => firing.summary,
        "latest" => firing.latest
      }
    }

    payload = Renderer.timeline(event, incident)
    body = get_in(payload, ["blocks", Access.at(0), "child_blocks", Access.at(1), "text", "text"])

    assert body =~ firing.latest
    refute body =~ incident.latest

    assert Renderer.root(incident(firing), 1, lifecycle_events: [event_record(firing, 1)])["text"] =~
             firing.latest
  end

  test "Grafana events use the reviewed Grafana provider icon" do
    event = grafana_events() |> hd()
    payload = Renderer.root(incident(event), 1, lifecycle_events: [event_record(event, 1)])

    assert get_in(payload, [
             "blocks",
             Access.at(0),
             "child_blocks",
             Access.at(0),
             "elements",
             Access.at(0)
           ]) == %{
             "type" => "image",
             "image_url" => "https://grafana.com/static/assets/img/fav32.png",
             "alt_text" => "Grafana"
           }
  end

  defp incident(event) do
    attrs =
      event
      |> Map.from_struct()
      |> Map.drop([:schema_version, :event_id])

    struct!(
      Incident,
      Map.merge(attrs, %{desired_revision: 1, route_id: "shadow", channel_id: "C-test"})
    )
  end

  defp event_record(event, revision) do
    %EventRecord{
      event_id: event.event_id,
      incident_key: event.incident_key,
      source_state: event.source_state,
      state: event.state,
      observed_at: event.observed_at,
      render_revision: revision,
      canonical_payload: %{
        "source_state" => event.source_state,
        "recovery_status" => event.recovery_status
      }
    }
  end

  defp child_block(payload, suffix) do
    payload
    |> get_in(["blocks", Access.at(0), "child_blocks"])
    |> Enum.find(&String.ends_with?(&1["block_id"], "-#{suffix}"))
  end
end
