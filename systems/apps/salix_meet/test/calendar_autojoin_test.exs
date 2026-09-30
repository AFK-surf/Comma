defmodule SalixMeet.CalendarAutojoinTest do
  use ExUnit.Case, async: false

  alias SalixMeet.{CalendarAutojoin, CalendarProjection}

  defmodule TestCalendar do
    @behaviour SalixMeet.Ports.CalendarOccurrences

    @impl true
    def list(_group, _t0_ms, _t1_ms),
      do: {:ok, Application.get_env(:salix_meet, :calendar_autojoin_test_events, [])}

    @impl true
    def revalidate(_group, _event), do: :ok
  end

  defmodule SlowCalendar do
    @behaviour SalixMeet.Ports.CalendarOccurrences

    @impl true
    def list(group, _t0_ms, _t1_ms) do
      Process.sleep(group["test_delay_ms"])
      {:ok, group["test_events"]}
    end

    @impl true
    def revalidate(_group, _event), do: :ok
  end

  defmodule TestChannel do
    @behaviour SalixMeet.Ports.MeetingChannel

    @impl true
    def resolve(_group),
      do: {:ok, %{"connect_id" => "slack-test", "channel_id" => "C-test"}}
  end

  defmodule TestNotifier do
    @behaviour SalixMeet.Ports.CalendarNotifier

    @impl true
    def notify(group, event, occurrence_id) do
      calls = Application.get_env(:salix_meet, :calendar_notifier_test_calls, %{})
      failures = Application.get_env(:salix_meet, :calendar_notifier_test_failures, %{})

      case Map.get(failures, occurrence_id, 0) do
        remaining when remaining > 0 ->
          Application.put_env(
            :salix_meet,
            :calendar_notifier_test_failures,
            Map.put(failures, occurrence_id, remaining - 1)
          )

          {:error, :temporary_outbox_failure}

        _ ->
          case Map.has_key?(calls, occurrence_id) do
            true ->
              {:ok, :exists}

            false ->
              Application.put_env(
                :salix_meet,
                :calendar_notifier_test_calls,
                Map.put(calls, occurrence_id, {group, event})
              )

              {:ok, :queued}
          end
      end
    end
  end

  @group %{"tenant_id" => "default", "group_id" => "g-test", "meeting_agent_id" => "ma-g-test"}
  @now 10_000_000
  @lead 120_000
  @grace 300_000

  setup do
    prev_s3 = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end

    SalixStore.S3.Fake.reset()

    prev_cal = Application.get_env(:salix_meet, :calendar_occurrences_mod)
    Application.put_env(:salix_meet, :calendar_occurrences_mod, TestCalendar)

    prev_events = Application.get_env(:salix_meet, :calendar_autojoin_test_events)
    Application.put_env(:salix_meet, :calendar_autojoin_test_events, [])

    prev_channel = Application.get_env(:salix_meet, :meeting_channel_mod)
    Application.put_env(:salix_meet, :meeting_channel_mod, TestChannel)

    prev_notifier = Application.get_env(:salix_meet, :calendar_notifier_mod)
    Application.put_env(:salix_meet, :calendar_notifier_mod, TestNotifier)

    prev_notifier_calls = Application.get_env(:salix_meet, :calendar_notifier_test_calls)
    Application.put_env(:salix_meet, :calendar_notifier_test_calls, %{})

    prev_notifier_failures =
      Application.get_env(:salix_meet, :calendar_notifier_test_failures)

    Application.put_env(:salix_meet, :calendar_notifier_test_failures, %{})

    on_exit(fn ->
      restore(:salix_store, :s3_backend, prev_s3)
      restore(:salix_meet, :calendar_occurrences_mod, prev_cal)
      restore(:salix_meet, :calendar_autojoin_test_events, prev_events)
      restore(:salix_meet, :meeting_channel_mod, prev_channel)
      restore(:salix_meet, :calendar_notifier_mod, prev_notifier)
      restore(:salix_meet, :calendar_notifier_test_calls, prev_notifier_calls)
      restore(:salix_meet, :calendar_notifier_test_failures, prev_notifier_failures)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp set_events(events),
    do: Application.put_env(:salix_meet, :calendar_autojoin_test_events, events)

  defp ev(id, start_ms) do
    %{
      "event_id" => id,
      "calendar_id" => "cal-test",
      "calendar_item_id" => "item-#{id}",
      "occurrence_ref" => occurrence_ref(id, start_ms),
      "meeting_plan_id" => "plan-#{id}",
      "start_ms" => start_ms,
      "end_ms" => start_ms + 1_800_000,
      "meet_url" => "https://meet.google.com/abc-defg-hij?event=#{id}",
      "title" => "T-#{id}"
    }
  end

  defp occurrence_ref(id, start_ms) do
    %{
      "calendar_id" => "cal-test",
      "scheduling_link_id" => "link-#{id}",
      "recurrence_key" => %{"kind" => "recurring", "value" => "slot-#{start_ms}"}
    }
  end

  defp candidate_titles(candidates), do: candidates |> Enum.map(& &1.title) |> Enum.sort()

  test "scan_once materializes the group's events into its durable projection" do
    set_events([ev("a", 1_000), ev("b", 2_000)])

    assert [{"g-test", 2}] = CalendarAutojoin.scan_once([@group])

    projection = load_projection!(@group)

    assert %{"fresh" => fresh, "recovery" => [], "cursor" => ""} =
             CalendarProjection.to_map(projection)

    assert Enum.map(fresh, &get_in(&1, ["event", "event_id"])) == ["a", "b"]
  end

  test "scan_once reconciles removed events in the durable projection" do
    set_events([ev("a", 1_000), ev("b", 2_000)])
    CalendarAutojoin.scan_once([@group])

    set_events([ev("a", 1_000)])
    CalendarAutojoin.scan_once([@group])

    assert %{"fresh" => [%{"event" => %{"event_id" => "a"}}], "recovery" => []} =
             @group |> load_projection!() |> CalendarProjection.to_map()
  end

  test "scan_once enforces both group and event bounds" do
    groups =
      for number <- 1..3 do
        Map.put(@group, "group_id", "g-#{number}")
      end

    set_events([ev("a", 1_000), ev("b", 2_000), ev("c", 3_000)])

    assert [{"g-1", 2}, {"g-2", 2}] =
             CalendarAutojoin.scan_once(groups,
               max_groups_per_pass: 2,
               max_events_per_group: 2
             )

    for group_id <- ["g-1", "g-2"] do
      group = Map.put(@group, "group_id", group_id)
      projection = load_projection!(group)
      assert projection.new? == false
      assert length(CalendarProjection.to_map(projection)["fresh"]) == 2
    end

    missing = load_projection!(Map.put(@group, "group_id", "g-3"))
    assert missing.new? == true
    assert %{"fresh" => [], "recovery" => []} = CalendarProjection.to_map(missing)
  end

  test "scan_once surfaces a projection checkpoint failure and preserves the last good projection" do
    set_events([ev("old", 1_000)])
    assert [{"g-test", 1}] = CalendarAutojoin.scan_once([@group])

    key = CalendarProjection.key("g-test")
    set_events([ev("new", 2_000)])
    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, key})

    assert [
             {"g-test",
              {:error,
               {:calendar_projection_checkpoint, {:calendar_projection_write, {:http, 503}}}}}
           ] = CalendarAutojoin.scan_once([@group])

    assert %{"fresh" => [%{"event" => %{"event_id" => "old"}}]} =
             @group |> load_projection!() |> CalendarProjection.to_map()
  end

  test "scan_once applies task timeout even when concurrency is one" do
    Application.put_env(:salix_meet, :calendar_occurrences_mod, SlowCalendar)

    group =
      @group
      |> Map.put("test_delay_ms", 50)
      |> Map.put("test_events", [ev("slow", 1_000)])

    assert [{"g-test", {:error, {:task_exit, :timeout}}}] =
             CalendarAutojoin.scan_once([group],
               max_concurrency: 1,
               task_timeout_ms: 10
             )
  end

  # "late" ended a minute ago (ev/2 gives a 30-minute duration): a meeting that
  # is still in progress is inside the window now, so the excluded case is one
  # that is actually over.
  test "join_sweep(dry_run) selects only meetings inside the join window" do
    set_events([
      ev("in", @now + 30_000),
      ev("early", @now + 10 * 60_000),
      ev("late", @now - 31 * 60_000)
    ])

    CalendarAutojoin.scan_once([@group], now: @now)
    cands = CalendarAutojoin.join_sweep([@group], now: @now, dry_run: true)

    assert [%{action: :would_join, mid: mid, title: "T-in"}] = cands
    assert String.starts_with?(mid, "mtg-cal-")
  end

  # ev/2 gives every event a 30-minute duration, so "at_end" starts 30 minutes
  # ago and ends exactly now. The old upper bound (start + five minutes) is
  # gone: a meeting stays joinable until it ends, so a dispatcher outage or a
  # slow admit no longer forfeits it.
  test "join window runs from the lead edge to the meeting end" do
    duration = 1_800_000

    set_events([
      ev("at_lead", @now + @lead),
      ev("before_lead", @now + @lead + 1),
      ev("past_grace", @now - @grace - 1),
      ev("at_end", @now - duration),
      ev("after_end", @now - duration - 1)
    ])

    CalendarAutojoin.scan_once([@group], now: @now)
    cands = CalendarAutojoin.join_sweep([@group], now: @now, dry_run: true)

    assert Enum.sort(candidate_titles(cands)) == ["T-at_end", "T-at_lead", "T-past_grace"]
  end

  test "an event without end_ms keeps the conservative five-minute bound" do
    set_events([
      ev("open", @now - @grace) |> Map.delete("end_ms"),
      ev("closed", @now - @grace - 1) |> Map.delete("end_ms")
    ])

    CalendarAutojoin.scan_once([@group], now: @now)
    cands = CalendarAutojoin.join_sweep([@group], now: @now, dry_run: true)

    assert candidate_titles(cands) == ["T-open"]
  end

  test "Feishu notify mode dispatches once at start and never starts a meeting" do
    group =
      Map.merge(@group, %{
        "provider" => "feishu",
        "mode" => "notify",
        "connect_id" => "feishu-test",
        "chat_id" => "oc-test"
      })

    event = ev("notify", @now - 1)
    set_events([event])

    assert [{"g-test", 1}] = CalendarAutojoin.scan_once([group], now: @now)

    assert [%{action: :notified, mid: occurrence_id}] =
             CalendarAutojoin.join_sweep([group], now: @now)

    assert %{^occurrence_id => {^group, ^event}} =
             Application.fetch_env!(:salix_meet, :calendar_notifier_test_calls)

    assert [%{action: :already_notified, mid: ^occurrence_id}] =
             CalendarAutojoin.join_sweep([group], now: @now + 1)

    assert {:error, :not_found} = SalixMeet.Store.get(occurrence_id)
  end

  test "Feishu notify mode does not pre-notify or recover after five minutes" do
    group = Map.merge(@group, %{"provider" => "feishu", "mode" => "notify"})

    set_events([
      ev("future", @now + 1),
      ev("expired", @now - @grace - 1)
    ])

    assert [{"g-test", 2}] = CalendarAutojoin.scan_once([group], now: @now)
    assert [] = CalendarAutojoin.join_sweep([group], now: @now, dry_run: true)
    assert Application.fetch_env!(:salix_meet, :calendar_notifier_test_calls) == %{}
  end

  test "Feishu notify mode retries a transient outbox enqueue failure within the recovery window" do
    group =
      Map.merge(@group, %{
        "provider" => "feishu",
        "mode" => "notify",
        "connect_id" => "feishu-test",
        "chat_id" => "oc-test"
      })

    event = ev("notify-retry", @now - 1)
    set_events([event])
    assert [{"g-test", 1}] = CalendarAutojoin.scan_once([group], now: @now)

    assert [%{mid: occurrence_id}] =
             CalendarAutojoin.join_sweep([group], now: @now, dry_run: true)

    Application.put_env(
      :salix_meet,
      :calendar_notifier_test_failures,
      %{occurrence_id => 1}
    )

    assert [
             %{
               action: :error,
               mid: ^occurrence_id,
               reason: :temporary_outbox_failure,
               retry: true
             }
           ] = CalendarAutojoin.join_sweep([group], now: @now)

    assert Application.fetch_env!(:salix_meet, :calendar_notifier_test_calls) == %{}

    assert [%{action: :notified, mid: ^occurrence_id}] =
             CalendarAutojoin.join_sweep([group], now: @now + 1)

    assert %{^occurrence_id => {^group, ^event}} =
             Application.fetch_env!(:salix_meet, :calendar_notifier_test_calls)
  end

  test "join_sweep caps dispatch attempts per pass" do
    set_events([
      ev("first", @now + 10_000),
      ev("second", @now + 20_000),
      ev("third", @now + 30_000)
    ])

    assert [{"g-test", 3}] = CalendarAutojoin.scan_once([@group], now: @now)
    Application.put_env(:salix_meet, :meeting_channel_mod, SalixMeet.Ports.MeetingChannel.None)

    assert [first, second] =
             CalendarAutojoin.join_sweep([@group],
               now: @now,
               max_events_per_group: 3,
               max_joins_per_pass: 2
             )

    assert Enum.map([first, second], & &1.action) == [:skipped, :skipped]
    assert Enum.map([first, second], & &1.reason) == [:not_configured, :not_configured]
  end

  test "the production group-bounded path attempts at most one incomplete event per group" do
    first = ev("first", @now + 10_000)
    second = ev("second", @now + 20_000)
    third = ev("third", @now + 30_000)
    set_events([first, second, third])

    assert [{"g-test", 3}] = CalendarAutojoin.scan_once([@group], now: @now)
    Application.put_env(:salix_meet, :meeting_channel_mod, SalixMeet.Ports.MeetingChannel.None)

    assert [%{action: :skipped, reason: :not_configured, mid: attempted_mid}] =
             CalendarAutojoin.join_sweep([@group],
               now: @now,
               group_bounded: true,
               max_events_per_group: 3,
               max_joins_per_pass: 1
             )

    assert attempted_mid == CalendarAutojoin.meeting_id(@group, first)

    assert [%{action: :skipped, reason: :not_configured, mid: next_mid}] =
             CalendarAutojoin.join_sweep([@group],
               now: @now,
               group_bounded: true,
               max_events_per_group: 3,
               max_joins_per_pass: 1
             )

    assert next_mid == CalendarAutojoin.meeting_id(@group, second)

    assert [%{action: :skipped, reason: :not_configured, mid: third_mid}] =
             CalendarAutojoin.join_sweep([@group],
               now: @now,
               group_bounded: true,
               max_events_per_group: 3,
               max_joins_per_pass: 1
             )

    assert third_mid == CalendarAutojoin.meeting_id(@group, third)
  end

  test "the production group-bounded path surfaces projection cursor checkpoint failures" do
    first = ev("first-cursor-failure", @now + 10_000)
    second = ev("second-cursor-failure", @now + 20_000)
    set_events([first, second])

    assert [{"g-test", 2}] = CalendarAutojoin.scan_once([@group], now: @now)
    Application.put_env(:salix_meet, :meeting_channel_mod, SalixMeet.Ports.MeetingChannel.None)

    key = CalendarProjection.key("g-test")
    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, key})

    assert [
             %{
               action: :error,
               mid: attempted_mid,
               reason: {:calendar_projection_checkpoint, _reason},
               event_result: %{action: :skipped, reason: :not_configured}
             }
           ] =
             CalendarAutojoin.join_sweep([@group],
               now: @now,
               group_bounded: true,
               max_events_per_group: 2,
               max_joins_per_pass: 1
             )

    assert attempted_mid == CalendarAutojoin.meeting_id(@group, first)

    # The event attempt must not advance the shared cursor unless its CAS
    # checkpoint succeeds. The prior durable projection remains authoritative.
    assert %{"cursor" => ""} =
             @group |> load_projection!() |> CalendarProjection.to_map()
  end

  test "max_events one keeps one fresh plus one recovery and rotates their shared cursor" do
    retained = ev("retained-a", @now + 10_000)
    fresh = ev("fresh-b", @now + 20_000)

    set_events([retained])

    assert [{"g-test", 1}] =
             CalendarAutojoin.scan_once([@group], now: @now, max_events_per_group: 1)

    retained_mid = CalendarAutojoin.meeting_id(@group, retained)
    fresh_mid = CalendarAutojoin.meeting_id(@group, fresh)

    # A pre-dispatch meeting remains eligible for recovery when it disappears
    # from the provider's fresh window.
    assert {:ok, _doc, _etag} = SalixMeet.Store.create_once(retained_mid, state: %{}, now: @now)

    set_events([fresh])

    assert [{"g-test", 2}] =
             CalendarAutojoin.scan_once([@group],
               now: @now + 1,
               max_events_per_group: 1
             )

    projection = load_projection!(@group)

    assert %{
             "fresh" => [%{"meeting_id" => ^fresh_mid}],
             "recovery" => [%{"meeting_id" => ^retained_mid}],
             "cursor" => ""
           } = CalendarProjection.to_map(projection)

    assert [
             %{kind: :fresh, meeting_id: ^fresh_mid},
             %{kind: :recovery, meeting_id: ^retained_mid}
           ] = CalendarProjection.candidates(projection)

    Application.put_env(:salix_meet, :meeting_channel_mod, SalixMeet.Ports.MeetingChannel.None)

    assert [%{action: :skipped, reason: :not_configured, mid: ^fresh_mid}] =
             CalendarAutojoin.join_sweep([@group],
               now: @now + 1,
               group_bounded: true,
               max_events_per_group: 1,
               max_joins_per_pass: 1
             )

    rotated = load_projection!(@group)

    assert [
             %{kind: :recovery, meeting_id: ^retained_mid},
             %{kind: :fresh, meeting_id: ^fresh_mid}
           ] = CalendarProjection.candidates(rotated)

    assert [%{action: :would_join, mid: ^retained_mid}] =
             CalendarAutojoin.join_sweep([@group],
               now: @now + 1,
               dry_run: true,
               group_bounded: true,
               max_events_per_group: 1,
               max_joins_per_pass: 1
             )
  end

  test "the production group-bounded path skips completed events without starving the next one" do
    first = ev("first-completed", @now + 10_000)
    second = ev("second-pending", @now + 20_000)
    set_events([first, second])

    assert [{"g-test", 2}] = CalendarAutojoin.scan_once([@group], now: @now)

    first_mid = CalendarAutojoin.meeting_id(@group, first)
    assert {:ok, _doc, etag} = SalixMeet.Store.create_once(first_mid, state: %{}, now: @now)
    assert {:ok, _joined, _etag} = SalixMeet.Store.set_join_requested(first_mid, etag, at: @now)

    Application.put_env(:salix_meet, :meeting_channel_mod, SalixMeet.Ports.MeetingChannel.None)

    assert [%{action: :skipped, reason: :not_configured, mid: attempted_mid}] =
             CalendarAutojoin.join_sweep([@group],
               now: @now,
               group_bounded: true,
               max_events_per_group: 2,
               max_joins_per_pass: 1
             )

    assert attempted_mid == CalendarAutojoin.meeting_id(@group, second)
  end

  test "an event without a Meet link is never joinable" do
    set_events([
      %{"event_id" => "no-meet", "start_ms" => @now + 30_000, "meet_url" => nil, "title" => "T-x"}
    ])

    CalendarAutojoin.scan_once([@group], now: @now)
    assert [] = CalendarAutojoin.join_sweep([@group], now: @now, dry_run: true)
  end

  test "a projected video URL outside the exact Google Meet origin is never joinable" do
    set_events([
      %{
        "event_id" => "evil-host",
        "start_ms" => @now + 30_000,
        "meet_url" => "https://meet.google.com.evil.test/abc-defg-hij",
        "title" => "T-evil"
      },
      %{
        "event_id" => "userinfo-trick",
        "start_ms" => @now + 30_000,
        "meet_url" => "https://meet.google.com@evil.test/abc-defg-hij",
        "title" => "T-userinfo"
      },
      %{
        "event_id" => "http",
        "start_ms" => @now + 30_000,
        "meet_url" => "http://meet.google.com/abc-defg-hij",
        "title" => "T-http"
      },
      %{
        "event_id" => "landing",
        "start_ms" => @now + 30_000,
        "meet_url" => "https://meet.google.com/landing",
        "title" => "T-landing"
      },
      %{
        "event_id" => "extra-path",
        "start_ms" => @now + 30_000,
        "meet_url" => "https://meet.google.com/abc-defg-hij/extra",
        "title" => "T-extra"
      },
      %{
        "event_id" => "root",
        "start_ms" => @now + 30_000,
        "meet_url" => "https://meet.google.com/",
        "title" => "T-root"
      }
    ])

    CalendarAutojoin.scan_once([@group], now: @now)
    assert [] = CalendarAutojoin.join_sweep([@group], now: @now, dry_run: true)
  end

  test "meeting id differs across occurrences and survives a Meet-link change" do
    set_events([ev("s", @now + 30_000), ev("s", @now + 40_000)])
    CalendarAutojoin.scan_once([@group], now: @now)

    mids = CalendarAutojoin.join_sweep([@group], now: @now, dry_run: true) |> Enum.map(& &1.mid)
    assert length(Enum.uniq(mids)) == 2

    original = ev("link-change", @now + 30_000)
    changed_link = Map.put(original, "meet_url", "https://meet.google.com/xyz-abcd-uvw")

    assert CalendarAutojoin.meeting_id(@group, original) ==
             CalendarAutojoin.meeting_id(@group, changed_link)
  end

  test "a meeting with no resolvable delivery target is skipped, not joined" do
    Application.put_env(:salix_meet, :meeting_channel_mod, SalixMeet.Ports.MeetingChannel.None)

    set_events([ev("no-target", @now + 30_000)])
    CalendarAutojoin.scan_once([@group], now: @now)

    assert [%{action: :skipped, reason: :not_configured}] =
             CalendarAutojoin.join_sweep([@group], now: @now)
  end

  defp load_projection!(group) do
    assert {:ok, projection} = CalendarProjection.load(group, now: @now)
    projection
  end
end
