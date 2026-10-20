defmodule Salix.Bindings.MeetingCalendarStatusTest do
  use SystemsClock.Case, async: false

  alias Salix.Bindings.MeetingCalendarStatus
  alias SalixMeet.{CalendarProjection, Store}
  alias SalixStore.{CasRecord, Ids, Keys}

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_calendar_autojoin = SystemsRuntime.get_env(:salix_meet, :calendar_autojoin)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_meet, :calendar_autojoin, scan_interval_ms: 120_000)

    case SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end

    SalixStore.S3.Fake.reset()

    if is_nil(SystemsRuntime.Proc.whereis(SalixMeet.CalendarAutojoin)) do
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
    start_ms = SystemsClock.system_time(:millisecond) + :timer.hours(1)

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

  test "rejects a connect outside the agent's active Slack scope", context do
    assert {:error, :not_found} =
             MeetingCalendarStatus.get(context.agent_id, Ids.new_connect_id(), 20)
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
