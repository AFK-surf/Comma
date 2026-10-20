defmodule SalixMeet.CalendarProjectionTest do
  use SystemsClock.Case, async: false

  alias SalixMeet.{CalendarAutojoin, CalendarProjection}
  alias SalixStore.Ids

  @now 10_000_000
  @group %{
    "tenant_id" => "ten-calendar-projection",
    "group_id" => "grp-calendar-projection",
    "calendar_id" => "primary@example.com",
    "calendar_connected_account_id" => "ca-primary"
  }

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end

    SalixStore.S3.Fake.reset()

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, previous_backend)
    end)

    :ok
  end

  test "checkpoint rejects a stale projection snapshot with a CAS conflict" do
    original = event("original", @now + 10_000)
    seed_fresh!(@group, [original], max_events: 1)

    assert {:ok, first_reader} = CalendarProjection.load(@group, lease_epoch: 2, now: @now + 1)
    assert {:ok, stale_reader} = CalendarProjection.load(@group, lease_epoch: 2, now: @now + 1)

    assert {:ok, first_write, %{partial_errors: []}} =
             CalendarProjection.reconcile(
               first_reader,
               [event("winner", @now + 20_000)],
               %{},
               max_events: 1,
               now: @now + 2
             )

    assert {:ok, stale_write, %{partial_errors: []}} =
             CalendarProjection.reconcile(
               stale_reader,
               [event("stale", @now + 30_000)],
               %{},
               max_events: 1,
               now: @now + 2
             )

    assert {:ok, _checkpointed} = CalendarProjection.checkpoint(first_write)
    assert {:error, :stale} = CalendarProjection.checkpoint(stale_write)

    assert {:ok, persisted} = CalendarProjection.load(@group, lease_epoch: 3, now: @now + 3)

    assert [%{"event" => %{"event_id" => "winner"}}] =
             CalendarProjection.to_map(persisted)["fresh"]
  end

  defp seed_fresh!(group, events, opts) do
    assert {:ok, empty} = CalendarProjection.load(group, lease_epoch: 1, now: @now)

    assert {:ok, projection, %{partial_errors: []}} =
             CalendarProjection.reconcile(
               empty,
               events,
               %{},
               Keyword.merge([now: @now], opts)
             )

    assert {:ok, checkpointed} = CalendarProjection.checkpoint(projection)
    checkpointed
  end

  defp event(id, start_ms) do
    %{
      "event_id" => id,
      "occurrence_ref" => %{
        "calendar_id" => "calendar-projection-test",
        "scheduling_link_id" => "calendar-projection-series",
        "recurrence_key" => %{
          "kind" => "recurring",
          "value_kind" => "utc_date_time",
          "value" =>
            start_ms
            |> DateTime.from_unix!(:millisecond)
            |> DateTime.to_naive()
            |> NaiveDateTime.to_iso8601(),
          "time_zone" => "UTC"
        }
      },
      "start_ms" => start_ms,
      "end_ms" => start_ms + 1_800_000,
      "meet_url" => "https://meet.google.com/abc-defg-hij?event=#{id}",
      "title" => "Calendar #{id}"
    }
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
