defmodule Salix.Bindings.MeetingCalendarStatusTest do
  use ExUnit.Case, async: false

  alias Salix.Bindings.MeetingCalendarStatus
  alias SalixMeet.{CalendarProjection, Store}
  alias SalixStore.{CasRecord, Ids, Keys}

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_calendar_autojoin = Application.get_env(:salix_meet, :calendar_autojoin)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_meet, :calendar_autojoin, scan_interval_ms: 120_000)

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end

    SalixStore.S3.Fake.reset()

    if is_nil(Process.whereis(SalixMeet.CalendarAutojoin)) do
      start_supervised!(%{
        id: {Agent, SalixMeet.CalendarAutojoin},
        start: {Agent, :start_link, [fn -> :running end, [name: SalixMeet.CalendarAutojoin]]},
        restart: :temporary,
        type: :worker
      })
    end

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    agent_id = Ids.new_agent_id(group_id)
    connect_id = Ids.new_connect_id()
    calendar_id = Ids.new_calendar_id()

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_group(group_id), %{
               "tenant_id" => tenant_id,
               "group_id" => group_id
             })

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_agent(agent_id), %{
               "tenant_id" => tenant_id,
               "group_id" => group_id,
               "agent_id" => agent_id,
               "role" => "router",
               "heartbeat_schedule_id" => "heartbeat-#{agent_id}",
               "router_session_id" => Ids.new_session_id()
             })

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), %{
               "tenant_id" => tenant_id,
               "group_id" => group_id,
               "connect_id" => connect_id,
               "provider" => "slack",
               "oauth_completed_at" => 1
             })

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, previous_backend)
      restore_env(:salix_meet, :calendar_autojoin, previous_calendar_autojoin)
    end)

    {:ok,
     tenant_id: tenant_id,
     group_id: group_id,
     agent_id: agent_id,
     connect_id: connect_id,
     calendar_id: calendar_id}
  end

  test "reports projected meetings, preparation state, and autojoin state without provider reads",
       context do
    plan_id = Ids.new_meeting_plan_id()
    item_id = Ids.new_calendar_item_id()
    start_ms = System.system_time(:millisecond) + :timer.hours(1)

    occurrence_ref = %{
      "calendar_id" => context.calendar_id,
      "instance" => start_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
    }

    event = %{
      "event_id" => "event-standup",
      "calendar_id" => context.calendar_id,
      "calendar_item_id" => item_id,
      "occurrence_ref" => occurrence_ref,
      "meeting_plan_id" => plan_id,
      "calendar_revision" => 4,
      "start_ms" => start_ms,
      "end_ms" => start_ms + 30 * 60 * 1_000,
      "meet_url" => "https://meet.google.com/abc-defg-hij",
      "title" =>
        "Agenda https://docs.example.test/brief,Meet:https://meet.google.com:443/abc-defg-hij"
    }

    group = %{
      "tenant_id" => context.tenant_id,
      "group_id" => context.group_id,
      "calendar_id" => context.calendar_id
    }

    assert {:ok, empty} = CalendarProjection.load(group, now: start_ms - 1_000)

    assert {:ok, projection, %{partial_errors: []}} =
             CalendarProjection.reconcile(empty, [event], %{}, max_events: 50, now: start_ms)

    assert {:ok, _} = CalendarProjection.checkpoint(projection)
    meeting_id = CalendarProjection.meeting_id(group, event)

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_meeting_plan(context.group_id, plan_id), %{
               "meeting_plan_id" => plan_id,
               "group_id" => context.group_id,
               "occurrence_ref" => occurrence_ref,
               "conversation_id" => Ids.new_conversation_id(),
               "status" => "planned",
               "revision" => 2,
               "updated_at" => start_ms,
               "preparation" => %{
                 "decision_at" => start_ms - 30 * 60 * 1_000,
                 "publish_start_at" => start_ms - 7 * 60 * 1_000,
                 "publish_deadline_at" => start_ms - 5 * 60 * 1_000,
                 "research_decision" => "required",
                 "deadline_status" => "pending",
                 "baseline" => %{"private" => "must not be exposed"}
               }
             })

    assert {:ok, status} =
             MeetingCalendarStatus.get(context.agent_id, context.connect_id, 10)

    assert status["health"] == "ok"
    assert status["reason"] == "eligible_meetings_projected"
    assert status["runtime"]["status"] == "running"
    assert status["runtime"]["runtime_driver"] in ["none", "http", "connector", "unknown"]
    assert status["runtime"]["runtime_driver_conflict"] == false
    assert status["projection"]["stale"] == false

    assert status["summary"] == %{
             "candidate_count" => 1,
             "returned_count" => 1,
             "planned_count" => 1,
             "plan_error_count" => 0,
             "candidate_error_count" => 0,
             "autojoin_error_count" => 0
           }

    assert [reported] = status["events"]

    assert reported["title"] ==
             "Agenda https://docs.example.test/brief,Meet:[REDACTED_GOOGLE_MEET_URL]"

    assert reported["google_meet_eligible"] == true
    assert reported["plan"]["status"] == "planned"
    assert reported["plan"]["preparation"]["research_decision"] == "required"

    assert reported["autojoin"] == %{
             "status" => "not_started",
             "start_at" => nil,
             "join_requested_at" => nil,
             "joined_at" => nil,
             "abandoned_at" => nil,
             "error_present" => false
           }

    refute inspect(status) =~ "must not be exposed"
    refute inspect(status) =~ "abc-defg-hij"

    assert {:ok, _document, _etag} =
             Store.create_once(meeting_id,
               now: start_ms,
               state: %{"status" => "scheduled", "start_at" => start_ms}
             )

    assert {:ok, stored_status} =
             MeetingCalendarStatus.get(context.agent_id, context.connect_id, 10)

    assert get_in(stored_status, ["events", Access.at(0), "autojoin", "status"]) == "scheduled"

    :ok =
      SalixStore.S3.Fake.set_fault({:fail, 503, :get, Keys.meet_state(meeting_id)})

    assert {:ok, unavailable_status} =
             MeetingCalendarStatus.get(context.agent_id, context.connect_id, 10)

    assert unavailable_status["health"] == "degraded"
    assert unavailable_status["reason"] == "autojoin_runtime_error"

    assert get_in(unavailable_status, ["events", Access.at(0), "autojoin"]) == %{
             "status" => "unavailable",
             "start_at" => nil,
             "join_requested_at" => nil,
             "joined_at" => nil,
             "abandoned_at" => nil,
             "error_present" => true
           }
  end

  test "runtime status surfaces the effective driver and a runtime_url/driver conflict",
       context do
    previous_url = Application.get_env(:salix_meet, :runtime_base_url)
    previous_mode = Application.get_env(:salix_meet, :runtime_driver_mode)
    previous_driver = Application.get_env(:salix_meet, :runtime_driver)

    Application.put_env(:salix_meet, :runtime_base_url, "http://meeting-runtime:8080")
    Application.put_env(:salix_meet, :runtime_driver_mode, "connector")
    Application.put_env(:salix_meet, :runtime_driver, SalixMeet.RuntimeDriver.HTTP)

    on_exit(fn ->
      restore_env(:salix_meet, :runtime_base_url, previous_url)
      restore_env(:salix_meet, :runtime_driver_mode, previous_mode)
      restore_env(:salix_meet, :runtime_driver, previous_driver)
    end)

    assert {:ok, status} =
             MeetingCalendarStatus.get(context.agent_id, context.connect_id, 10)

    assert status["runtime"]["runtime_driver"] == "http"
    assert status["runtime"]["runtime_driver_conflict"] == true
  end

  test "rejects a connect outside the agent's active Slack scope", context do
    assert {:error, :not_found} =
             MeetingCalendarStatus.get(context.agent_id, Ids.new_connect_id(), 20)
  end

  test "marks an eligible projected event without a planned MeetingPlan as degraded", context do
    start_ms = System.system_time(:millisecond) + 60 * 60 * 1_000
    plan_id = Ids.new_meeting_plan_id()

    event = %{
      "event_id" => "event-missing-plan",
      "calendar_id" => context.calendar_id,
      "calendar_item_id" => Ids.new_calendar_item_id(),
      "occurrence_ref" => %{
        "calendar_id" => context.calendar_id,
        "instance" => "2026-08-06T11:00:00Z"
      },
      "meeting_plan_id" => plan_id,
      "start_ms" => start_ms,
      "end_ms" => start_ms + 30 * 60 * 1_000,
      "meet_url" => "https://meet.google.com/mno-pqrs-tuv",
      "title" => "Missing plan example"
    }

    group = %{
      "tenant_id" => context.tenant_id,
      "group_id" => context.group_id,
      "calendar_id" => context.calendar_id
    }

    assert {:ok, empty} = CalendarProjection.load(group, now: start_ms - 1_000)

    assert {:ok, projection, %{partial_errors: []}} =
             CalendarProjection.reconcile(empty, [event], %{}, max_events: 50, now: start_ms)

    assert {:ok, _} = CalendarProjection.checkpoint(projection)
    assert {:ok, status} = MeetingCalendarStatus.get(context.agent_id, context.connect_id, 20)
    assert status["health"] == "degraded"
    assert status["reason"] == "meeting_plan_unavailable"
    assert status["summary"]["plan_error_count"] == 1
    assert [reported] = status["events"]
    assert reported["plan"] == %{"status" => "missing"}

    assert reported["autojoin"] == %{
             "status" => "not_started",
             "start_at" => nil,
             "join_requested_at" => nil,
             "joined_at" => nil,
             "abandoned_at" => nil,
             "error_present" => false
           }
  end

  test "a display limit cannot hide unhealthy omitted candidates behind health ok", context do
    now = System.system_time(:millisecond)
    visible_plan_id = Ids.new_meeting_plan_id()
    hidden_plan_id = Ids.new_meeting_plan_id()

    visible = %{
      "event_id" => "event-visible-healthy",
      "calendar_id" => context.calendar_id,
      "calendar_item_id" => Ids.new_calendar_item_id(),
      "occurrence_ref" => %{"calendar_id" => context.calendar_id, "instance" => "visible"},
      "meeting_plan_id" => visible_plan_id,
      "start_ms" => now + 30 * 60 * 1_000,
      "end_ms" => now + 60 * 60 * 1_000,
      "meet_url" => "https://meet.google.com/aaa-bbbb-ccc",
      "title" => "Visible healthy meeting"
    }

    hidden = %{
      "event_id" => "event-hidden-unhealthy",
      "calendar_id" => context.calendar_id,
      "calendar_item_id" => Ids.new_calendar_item_id(),
      "occurrence_ref" => %{"calendar_id" => context.calendar_id, "instance" => "hidden"},
      "meeting_plan_id" => hidden_plan_id,
      "start_ms" => now + 90 * 60 * 1_000,
      "end_ms" => now + 120 * 60 * 1_000,
      "meet_url" => "https://meet.google.com/ddd-eeee-fff",
      "title" => "Hidden unhealthy meeting"
    }

    group = %{
      "tenant_id" => context.tenant_id,
      "group_id" => context.group_id,
      "calendar_id" => context.calendar_id
    }

    assert {:ok, empty} = CalendarProjection.load(group, now: now - 2)

    assert {:ok, seeded, %{partial_errors: []}} =
             CalendarProjection.reconcile(empty, [hidden], %{}, max_events: 50, now: now - 1)

    assert {:ok, _} = CalendarProjection.checkpoint(seeded)
    assert {:ok, loaded} = CalendarProjection.load(group, now: now)
    hidden_meeting_id = CalendarProjection.meeting_id(group, hidden)

    assert {:ok, projection, %{partial_errors: [_]}} =
             CalendarProjection.reconcile(
               loaded,
               [visible],
               %{hidden_meeting_id => {:retain, hidden, "PRIVATE_HIDDEN_RECOVERY_ERROR"}},
               max_events: 50,
               now: now
             )

    assert {:ok, _} = CalendarProjection.checkpoint(projection)

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_meeting_plan(context.group_id, visible_plan_id), %{
               "meeting_plan_id" => visible_plan_id,
               "group_id" => context.group_id,
               "occurrence_ref" => visible["occurrence_ref"],
               "conversation_id" => Ids.new_conversation_id(),
               "status" => "planned",
               "revision" => 1,
               "updated_at" => now,
               "preparation" => %{}
             })

    assert {:ok, _document, _etag} =
             Store.create_once(hidden_meeting_id,
               now: now,
               state: %{"status" => "failed", "error" => "PRIVATE_HIDDEN_AUTOJOIN_ERROR"}
             )

    assert {:ok, status} = MeetingCalendarStatus.get(context.agent_id, context.connect_id, 1)
    assert status["projection"]["truncated"] == true
    assert status["summary"]["candidate_count"] == 2
    assert status["summary"]["returned_count"] == 1
    assert status["summary"]["plan_error_count"] == 0
    assert status["summary"]["candidate_error_count"] == 0
    assert status["summary"]["autojoin_error_count"] == 0
    assert status["health"] == "degraded"
    assert status["reason"] == "calendar_status_truncated"
    refute inspect(status) =~ "PRIVATE_HIDDEN"
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
