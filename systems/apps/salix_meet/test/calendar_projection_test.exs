defmodule SalixMeet.CalendarProjectionTest do
  use ExUnit.Case, async: false

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
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end

    SalixStore.S3.Fake.reset()

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, previous_backend)
    end)

    :ok
  end

  test "fresh and recovery each retain an independent max_events_per_group capacity" do
    retained = event("retained-a", @now + 20_000)
    fresh = event("fresh-b", @now + 30_000)

    seeded = seed_fresh!(@group, [retained], max_events: 1)
    retained_mid = meeting_id(@group, retained)
    fresh_mid = meeting_id(@group, fresh)

    assert {:ok, loaded} =
             CalendarProjection.load(@group, lease_epoch: 2, now: @now + 1)

    assert {:ok, reconciled, %{partial_errors: []}} =
             CalendarProjection.reconcile(
               loaded,
               [fresh],
               %{retained_mid => {:retain, retained, nil}},
               max_events: 1,
               now: @now + 1
             )

    assert %{
             "fresh" => [%{"meeting_id" => ^fresh_mid, "event" => ^fresh}],
             "recovery" => [
               %{
                 "meeting_id" => ^retained_mid,
                 "event" => ^retained,
                 "last_error" => nil
               }
             ]
           } = CalendarProjection.to_map(reconciled)

    assert [
             %{kind: :fresh, meeting_id: ^fresh_mid} = fresh_candidate,
             %{kind: :recovery, meeting_id: ^retained_mid}
           ] = CalendarProjection.candidates(reconciled)

    # A completed attempt advances the one group cursor in the same projection.
    # After that checkpoint, the retained recovery item is selected next.
    reconciled = CalendarProjection.advance(reconciled, fresh_candidate.key)
    assert {:ok, _checkpointed} = CalendarProjection.checkpoint(reconciled)

    assert {:ok, next_pass} =
             CalendarProjection.load(@group, lease_epoch: 3, now: @now + 2)

    assert [%{kind: :recovery, meeting_id: ^retained_mid} | _] =
             CalendarProjection.candidates(next_pass)

    refute seeded == reconciled
  end

  test "a transient recovery error preserves A while fresh B is persisted and dispatchable" do
    retained = event("transient-a", @now + 20_000)
    fresh = event("fresh-after-transient-b", @now + 30_000)
    retained_mid = meeting_id(@group, retained)
    fresh_mid = meeting_id(@group, fresh)
    error = "calendar exact GET timed out"

    seed_fresh!(@group, [retained], max_events: 1)
    assert {:ok, loaded} = CalendarProjection.load(@group, lease_epoch: 2, now: @now + 1)

    assert {:ok, reconciled, %{partial_errors: [%{meeting_id: ^retained_mid, reason: ^error}]}} =
             CalendarProjection.reconcile(
               loaded,
               [fresh],
               %{retained_mid => {:retain, retained, error}},
               max_events: 1,
               now: @now + 1
             )

    assert [
             %{kind: :fresh, meeting_id: ^fresh_mid},
             %{kind: :recovery, meeting_id: ^retained_mid}
           ] = CalendarProjection.candidates(reconciled)

    assert {:ok, _checkpointed} = CalendarProjection.checkpoint(reconciled)
    assert {:ok, persisted} = CalendarProjection.load(@group, lease_epoch: 3, now: @now + 2)

    assert %{
             "fresh" => [%{"meeting_id" => ^fresh_mid}],
             "recovery" => [
               %{"meeting_id" => ^retained_mid, "last_error" => ^error}
             ]
           } = CalendarProjection.to_map(persisted)

    # The partial recovery failure is not a group failure: fresh B remains the
    # first dispatch candidate in the durable projection.
    assert [%{kind: :fresh, meeting_id: ^fresh_mid} | _] =
             CalendarProjection.candidates(persisted)
  end

  test "fresh and recovery rotate through one shared cursor without starvation" do
    retained = event("recovery-a", @now + 20_000)
    fresh = event("failing-fresh-b", @now + 30_000)
    retained_mid = meeting_id(@group, retained)
    fresh_mid = meeting_id(@group, fresh)

    seed_fresh!(@group, [retained], max_events: 1)
    assert {:ok, loaded} = CalendarProjection.load(@group, lease_epoch: 2, now: @now + 1)

    assert {:ok, projection, %{partial_errors: []}} =
             CalendarProjection.reconcile(
               loaded,
               [fresh],
               %{retained_mid => {:retain, retained, nil}},
               max_events: 1,
               now: @now + 1
             )

    assert [
             %{kind: :fresh, meeting_id: ^fresh_mid} = fresh_candidate,
             %{kind: :recovery, meeting_id: ^retained_mid} = recovery_candidate
           ] = CalendarProjection.candidates(projection)

    # Even when fresh B fails, checkpointing the attempted candidate rotates
    # recovery A to the front on the following pass.
    after_fresh_failure = CalendarProjection.advance(projection, fresh_candidate.key)

    assert [
             %{kind: :recovery, meeting_id: ^retained_mid},
             %{kind: :fresh, meeting_id: ^fresh_mid}
           ] = CalendarProjection.candidates(after_fresh_failure)

    # Advancing the same cursor after A wraps to B. There is no second cursor
    # whose independent position could permanently hide either work class.
    after_recovery_attempt =
      CalendarProjection.advance(after_fresh_failure, recovery_candidate.key)

    assert [
             %{kind: :fresh, meeting_id: ^fresh_mid},
             %{kind: :recovery, meeting_id: ^retained_mid}
           ] = CalendarProjection.candidates(after_recovery_attempt)
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

  test "each bounded group result carries one checkpoint intent for one projection object" do
    groups =
      for number <- 1..3 do
        Map.put(@group, "group_id", "grp-calendar-projection-#{number}")
      end

    intents =
      for group <- groups do
        old_events = for number <- 1..3, do: event("old-#{number}", @now + number)
        new_events = for number <- 1..3, do: event("new-#{number}", @now + number + 100)

        seed_fresh!(group, old_events, max_events: 1)
        assert {:ok, loaded} = CalendarProjection.load(group, lease_epoch: 2, now: @now + 1)

        retained = hd(old_events)
        retained_mid = meeting_id(group, retained)

        assert {:ok, projection, %{partial_errors: []}} =
                 CalendarProjection.reconcile(
                   loaded,
                   new_events,
                   %{retained_mid => {:retain, retained, nil}},
                   max_events: 1,
                   now: @now + 1
                 )

        document = CalendarProjection.to_map(projection)
        assert length(document["fresh"]) == 1
        assert length(document["recovery"]) == 1
        assert length(document["fresh"]) + length(document["recovery"]) <= 2

        CalendarProjection.checkpoint_intent(projection)
      end

    assert length(intents) == length(groups)
    assert Enum.uniq_by(intents, & &1.group_id) == intents

    SalixStore.S3.Fake.reset_put_log()

    assert Enum.all?(intents, fn intent ->
             match?({:ok, _snapshot}, CalendarProjection.checkpoint(intent))
           end)

    expected_keys = Enum.map(groups, &projection_key(&1["group_id"])) |> Enum.sort()
    assert SalixStore.S3.Fake.put_log() |> Enum.sort() == expected_keys

    refute Enum.any?(SalixStore.S3.Fake.put_log(), fn key ->
             String.contains?(key, "/events/") or String.contains?(key, "/calendar/")
           end)
  end

  test "status returns a bounded read-only view of the persisted projection" do
    tenant_id = Ids.new_tenant_id()

    group = %{
      "tenant_id" => tenant_id,
      "group_id" => Ids.new_group_id(tenant_id),
      "calendar_id" => Ids.new_calendar_id()
    }

    events = [event("later", @now + 30_000), event("first", @now + 10_000)]
    seed_fresh!(group, events, max_events: 2)

    assert {:ok, status} = CalendarProjection.status(group["group_id"], 1)
    assert status["state"] == "active"
    assert status["candidate_count"] == 2
    assert status["returned_count"] == 1
    assert status["truncated"] == true
    assert [%{"event" => %{"event_id" => "first"}, "kind" => "fresh"}] = status["entries"]
  end

  test "status reports an unscanned group without creating a projection" do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    assert {:ok, %{"state" => "not_scanned", "entries" => [], "candidate_count" => 0}} =
             CalendarProjection.status(group_id, 20)

    assert {:error, :not_found} = SalixStore.S3.get(CalendarProjection.key(group_id))
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

  defp meeting_id(group, event), do: CalendarAutojoin.meeting_id(group, event)

  defp projection_key(group_id),
    do: "ctl/meet/calendar_autojoin/groups/#{group_id}.json"

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

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
