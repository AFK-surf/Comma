defmodule Salix.Bindings.MemberMeetingStatusTest do
  use SystemsClock.Case, async: false

  alias Salix.Bindings.MemberMeetingStatus
  alias SalixMeet.CalendarProjection
  alias SalixStore.{CasRecord, Ids, Keys}

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end

    SalixStore.S3.Fake.reset()

    on_exit(fn ->
      if previous_backend,
        do: SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend),
        else: SystemsRuntime.delete_env(:salix_store, :s3_backend)
    end)

    tenant_id = Ids.new_tenant_id()
    {:ok, tenant_id: tenant_id, group_id: Ids.new_group_id(tenant_id)}
  end

  test "without a preparer record a meeting is one row on its first copy's plan, two reads per row",
       context do
    start_ms = SystemsClock.system_time(:millisecond) + :timer.hours(2)
    ana = unit("Ana@Example.test")
    ben = unit("ben@example.test")

    ana_plan =
      copy(context, ana, start_ms, %{
        "personal_preparation" => false,
        "preparation" => %{"policy_revision" => 3}
      })

    # Ben's copy prepares, but no record names it: the row stays on the
    # first copy and names nobody.
    copy(context, ben, start_ms, %{
      "personal_preparation" => true,
      "personal_recipients" => ["ana@example.test", "ben@example.test"],
      "preparation" => %{"policy_revision" => 3, "report" => "Agenda"}
    })

    # Members without a projection yet, beyond the read cap.
    others = for n <- 1..24, do: unit("member#{n}@example.test")

    SalixStore.S3.Fake.reset_read_log()

    assert {:ok, status} =
             MemberMeetingStatus.get(enrolled(context, [ana, ben | others], true))

    assert [row] = status["events"]
    assert row["meeting_plan_id"] == ana_plan
    assert row["title"] == "Weekly sync"
    assert row["start_ms"] == start_ms
    assert row["recipients"] == []
    assert %{"status" => "planned", "settings_revision" => 3} = row["plan"]
    # The report itself stays out of the status read.
    refute inspect(status) =~ "Agenda"

    assert status["member_calendars"] == 26
    assert status["projection"]["truncated"] == true
    assert status["health"] == "members"

    # 25 projections, then one preparer record and one plan for the row.
    assert reads("ctl/meet/calendar_autojoin/members/#{context.group_id}/") == 25
    assert reads("ctl/meet/member_preparer/#{context.group_id}/") == 1
    assert reads(Keys.ctl_meeting_plans_prefix(context.group_id)) == 1
  end

  test "with the Group's reminders off a row reads only its first copy's plan", context do
    start_ms = SystemsClock.system_time(:millisecond) + :timer.hours(1)
    ana = unit("ana@example.test")
    ben = unit("ben@example.test")
    plan_id = copy(context, ana, start_ms, %{"personal_preparation" => false})
    copy(context, ben, start_ms, %{"personal_preparation" => false})

    SalixStore.S3.Fake.reset_read_log()

    assert {:ok, %{"events" => [row], "projection" => %{"truncated" => false}}} =
             MemberMeetingStatus.get(enrolled(context, [ana, ben], false))

    assert row["meeting_plan_id"] == plan_id
    assert row["recipients"] == []
    assert row["plan"]["personal_preparation"] == false
    assert reads("ctl/meet/member_preparer/#{context.group_id}/") == 0
    assert reads(Keys.ctl_meeting_plans_prefix(context.group_id)) == 1
  end

  defp reads(prefix),
    do:
      Enum.count(SalixStore.S3.Fake.read_log(), fn
        {:get, key} -> String.starts_with?(key, prefix)
        _ -> false
      end)

  defp unit(email),
    do: %{
      "account_id" => "ca-" <> email,
      "account_email" => email,
      "calendar_id" => Ids.new_calendar_id(),
      "calendars" => [%{"external_calendar_id" => email}]
    }

  defp enrolled(context, units, personal_preparation),
    do: %{
      "tenant_id" => context.tenant_id,
      "group_id" => context.group_id,
      "calendar_scope" => "members",
      "personal_preparation" => personal_preparation,
      "units" => units
    }

  # One member's copy of the meeting: its projection entry and its plan.
  defp copy(context, unit, start_ms, plan) do
    plan_id = Ids.new_meeting_plan_id()

    occurrence_ref = %{
      "calendar_id" => unit["calendar_id"],
      "instance" => start_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
    }

    event = %{
      "event_id" => "sync-" <> unit["calendar_id"],
      "calendar_id" => unit["calendar_id"],
      "calendar_item_id" => Ids.new_calendar_item_id(),
      "occurrence_ref" => occurrence_ref,
      "meeting_plan_id" => plan_id,
      "start_ms" => start_ms,
      "end_ms" => start_ms + :timer.minutes(30),
      "meet_url" => "https://meet.google.com/abc-defg-hij",
      "meeting_identity" => "meet",
      "title" => "Weekly sync"
    }

    group = %{
      "tenant_id" => context.tenant_id,
      "group_id" => context.group_id,
      "calendar_scope" => "members",
      "calendar_id" => unit["calendar_id"]
    }

    now = SystemsClock.system_time(:millisecond)
    assert {:ok, empty} = CalendarProjection.load(group, now: now)

    assert {:ok, projection, %{partial_errors: []}} =
             CalendarProjection.reconcile(empty, [event], %{}, max_events: 50, now: now)

    assert {:ok, _} = CalendarProjection.checkpoint(projection)

    assert {:ok, _} =
             CasRecord.create(
               Keys.ctl_meeting_plan(context.group_id, plan_id),
               Map.merge(
                 %{
                   "meeting_plan_id" => plan_id,
                   "group_id" => context.group_id,
                   "occurrence_ref" => occurrence_ref,
                   "status" => "planned",
                   "managed_calendar" => true,
                   "revision" => 1,
                   "updated_at" => now
                 },
                 plan
               )
             )

    plan_id
  end
end
