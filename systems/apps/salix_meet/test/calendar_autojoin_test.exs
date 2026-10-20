defmodule SalixMeet.CalendarAutojoinTest do
  use SystemsClock.Case, async: false

  alias SalixMeet.{CalendarAutojoin, CalendarProjection}

  defmodule TestCalendar do
    @behaviour SalixMeet.Ports.CalendarOccurrences

    @impl true
    def list(_group, _t0_ms, _t1_ms),
      do: {:ok, SystemsRuntime.get_env(:salix_meet, :calendar_autojoin_test_events, [])}

    @impl true
    def revalidate(_group, _event), do: :ok
  end

  defmodule SlowCalendar do
    @behaviour SalixMeet.Ports.CalendarOccurrences

    @impl true
    def list(group, _t0_ms, _t1_ms) do
      SystemsRuntime.Proc.sleep(group["test_delay_ms"])
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
      calls = SystemsRuntime.get_env(:salix_meet, :calendar_notifier_test_calls, %{})
      failures = SystemsRuntime.get_env(:salix_meet, :calendar_notifier_test_failures, %{})

      case Map.get(failures, occurrence_id, 0) do
        remaining when remaining > 0 ->
          SystemsRuntime.put_env(
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
              SystemsRuntime.put_env(
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
  setup do
    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end

    SalixStore.S3.Fake.reset()

    prev_cal = SystemsRuntime.get_env(:salix_meet, :calendar_occurrences_mod)
    SystemsRuntime.put_env(:salix_meet, :calendar_occurrences_mod, TestCalendar)

    prev_events = SystemsRuntime.get_env(:salix_meet, :calendar_autojoin_test_events)
    SystemsRuntime.put_env(:salix_meet, :calendar_autojoin_test_events, [])

    prev_channel = SystemsRuntime.get_env(:salix_meet, :meeting_channel_mod)
    SystemsRuntime.put_env(:salix_meet, :meeting_channel_mod, TestChannel)

    prev_notifier = SystemsRuntime.get_env(:salix_meet, :calendar_notifier_mod)
    SystemsRuntime.put_env(:salix_meet, :calendar_notifier_mod, TestNotifier)

    prev_notifier_calls = SystemsRuntime.get_env(:salix_meet, :calendar_notifier_test_calls)
    SystemsRuntime.put_env(:salix_meet, :calendar_notifier_test_calls, %{})

    prev_notifier_failures =
      SystemsRuntime.get_env(:salix_meet, :calendar_notifier_test_failures)

    SystemsRuntime.put_env(:salix_meet, :calendar_notifier_test_failures, %{})

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

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp set_events(events),
    do: SystemsRuntime.put_env(:salix_meet, :calendar_autojoin_test_events, events)

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

  test "scan_once materializes the group's events into its durable projection" do
    set_events([ev("a", 1_000), ev("b", 2_000)])

    assert [{"g-test", 2}] = CalendarAutojoin.scan_once([@group])

    projection = load_projection!(@group)

    assert %{"fresh" => fresh, "recovery" => [], "cursor" => ""} =
             CalendarProjection.to_map(projection)

    assert Enum.map(fresh, &get_in(&1, ["event", "event_id"])) == ["a", "b"]
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
             SystemsRuntime.fetch_env!(:salix_meet, :calendar_notifier_test_calls)

    assert [%{action: :already_notified, mid: ^occurrence_id}] =
             CalendarAutojoin.join_sweep([group], now: @now + 1)

    assert {:error, :not_found} = SalixMeet.Store.get(occurrence_id)
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

  defp load_projection!(group) do
    assert {:ok, projection} = CalendarProjection.load(group, now: @now)
    projection
  end
end
