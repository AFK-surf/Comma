defmodule SalixStore.TriagePatrolCursorsTest do
  use ExUnit.Case, async: false

  alias SalixStore.{
    Repo,
    SlackTriageChannels,
    TriagePatrolCursors,
    TriagePatrolScanState,
    ULID
  }

  setup do
    Repo.query!("TRUNCATE triage_patrol_cursors, slack_triage_channels")
    :ok
  end

  test "global discovery pages enabled channels only" do
    first = provision!("tenant-a", "group-a", "connect-a", "C_A", true)
    _disabled = provision!("tenant-a", "group-a", "connect-a", "C_B", false)
    second = provision!("tenant-b", "group-b", "connect-b", "C_C", true)

    assert {:ok, %{channels: [^first], scan_complete: false, next_cursor: cursor}} =
             SlackTriageChannels.list_enabled_page(nil, 1)

    assert is_binary(cursor)

    assert {:ok, %{channels: [^second], scan_complete: true, next_cursor: nil}} =
             SlackTriageChannels.list_enabled_page(cursor, 1)

    assert SlackTriageChannels.list_enabled_page("not-a-cursor", 10) ==
             {:error, :invalid_slack_triage_channel_cursor}
  end

  test "scan state checkpoints a fixed-tail pass and commits only its final page" do
    committed = cursor("2026-09-01T00:00:05.123Z", 50, 100)
    captured_tail = cursor("2026-09-01T00:00:10.456Z", 100, 200)
    newer_tail = cursor("2026-09-01T00:00:12.000Z", 120, 240)
    page_cursor = cursor("2026-09-01T00:00:07.000Z", 70, 140)

    assert {:ok, initial} = TriagePatrolScanState.initial(committed)
    assert {:ok, active} = TriagePatrolScanState.start_pass(initial, captured_tail, 5_000)

    assert {:ok,
            %{
              "lower_bound" => ^committed,
              "page_after" => ^committed,
              "tail" => ^captured_tail
            }} = TriagePatrolScanState.window(active)

    assert {:ok, partial} =
             TriagePatrolScanState.advance(active, %{
               next_cursor: page_cursor,
               has_more?: true
             })

    assert {:ok, ^page_cursor} = TriagePatrolScanState.progress_cursor(partial)

    # A restart/resume does not move the pass target to the now-newer CH tail.
    assert TriagePatrolScanState.start_pass(partial, newer_tail, 5_000) == {:ok, partial}

    assert {:ok, %{"page_after" => ^page_cursor, "tail" => ^captured_tail}} =
             TriagePatrolScanState.window(partial)

    assert {:ok, completed} =
             TriagePatrolScanState.advance(partial, %{
               next_cursor: captured_tail,
               has_more?: false
             })

    assert completed == %{
             "schema" => "comma.triage-clickhouse-scan-state.v2",
             "committed" => captured_tail,
             "floor" => committed,
             "pass" => nil
           }

    assert {:ok, overlapped} =
             TriagePatrolScanState.start_pass(completed, newer_tail, 5_000)

    assert {:ok,
            %{
              "lower_bound" => %{
                "ingest_at" => "2026-09-01T00:00:05.456Z",
                "message_ts_us" => 0,
                "version" => 0
              }
            }} = TriagePatrolScanState.window(overlapped)
  end

  test "cursor settlement advances once and an expired claim fences its old holder" do
    channel = provision!("tenant-a", "group-a", "connect-a", "C_A", true)
    authority = authority(channel)

    {:ok, initial} =
      cursor("2026-09-01T00:00:00.000Z", 1, 2)
      |> TriagePatrolScanState.initial()

    assert {:ok, stored} = TriagePatrolCursors.ensure(channel, authority, initial)
    assert stored["scan_state"] == initial
    assert stored["last_outcome"] == "initialized"

    assert {:ok, [claim]} =
             TriagePatrolCursors.claim_due("pod-a", limit: 1, lease_ms: 5_000)

    {:ok, next} =
      cursor("2026-09-01T00:00:01.000Z", 1_787_019_001_000_001, 3_574_038_002_000_002)
      |> TriagePatrolScanState.initial()

    result = %{
      scan_state: next,
      last_message_ts: "1787019001.000001",
      has_more?: false,
      created: 1,
      duplicate: 0,
      ineligible: 0
    }

    assert {:ok, %{status: :settled, revision: settled_revision}} =
             TriagePatrolCursors.settle(claim, result, interval_ms: 60_000)

    assert settled_revision == claim.revision + 1
    assert TriagePatrolCursors.settle(claim, result) == {:error, :conflict}

    assert {:ok, current} =
             TriagePatrolCursors.get("tenant-a", "group-a", "connect-a", "C_A")

    assert current["scan_state"] == next
    assert current["last_message_ts"] == "1787019001.000001"
    assert current["last_outcome"] == "admitted"
    assert is_nil(current["claim_token"])

    second = provision!("tenant-a", "group-a", "connect-a", "C_B", true)
    assert {:ok, _stored} = TriagePatrolCursors.ensure(second, authority(second), initial)

    assert {:ok, [old_claim]} =
             TriagePatrolCursors.claim_due("pod-old", limit: 1, lease_ms: 5_000)

    Repo.query!(
      "UPDATE triage_patrol_cursors SET lease_until = statement_timestamp() - interval '1 second' WHERE cursor_key = $1",
      [old_claim.cursor_key]
    )

    assert {:ok, [new_claim]} =
             TriagePatrolCursors.claim_due("pod-new", limit: 1, lease_ms: 5_000)

    assert new_claim.cursor_key == old_claim.cursor_key
    assert new_claim.revision == old_claim.revision + 1
    refute new_claim.claim_token == old_claim.claim_token
    assert TriagePatrolCursors.fail(old_claim, :stale_holder) == {:error, :conflict}
    assert {:ok, %{status: :failed}} = TriagePatrolCursors.fail(new_claim, :reader_unavailable)
  end

  test "inactive claims preserve progress, fence stale holders and resume after authority validation" do
    channel = provision!("tenant-a", "group-a", "connect-a", "C_A", true)
    authority = authority(channel)
    {:ok, initial} = TriagePatrolScanState.initial(cursor("2026-09-01T00:00:05.000Z", 50, 100))
    {:ok, _} = TriagePatrolCursors.ensure(channel, authority, initial)
    {:ok, [claim]} = TriagePatrolCursors.claim_due("pod-a", limit: 1)

    assert {:ok, %{status: :inactive}} = TriagePatrolCursors.deactivate(claim)
    assert {:error, :conflict} = TriagePatrolCursors.deactivate(claim)
    assert {:error, :conflict} = TriagePatrolCursors.fail(claim, :reader_unavailable)
    assert {:ok, []} = TriagePatrolCursors.claim_due("pod-b", limit: 1)

    {:ok, newer_tail} = TriagePatrolScanState.initial(cursor("2026-09-01T01:00:00.000Z", 60, 120))
    assert {:ok, resumed} = TriagePatrolCursors.ensure(channel, authority, newer_tail)
    assert resumed["scan_state"] == initial
    assert is_nil(resumed["last_error"])
    assert {:ok, [resumed_claim]} = TriagePatrolCursors.claim_due("pod-b", limit: 1)
    assert resumed_claim.scan_state == initial
    assert {:error, :conflict} = TriagePatrolCursors.deactivate(claim)

    assert {:ok, %{status: :failed}} =
             TriagePatrolCursors.fail(resumed_claim, :reader_unavailable)

    Repo.query!(
      "UPDATE triage_patrol_cursors SET next_due_at = statement_timestamp() WHERE cursor_key = $1",
      [claim.cursor_key]
    )

    assert {:ok, [_]} = TriagePatrolCursors.claim_due("pod-c", limit: 1)
  end

  test "NULL legacy scan state is never claimed and discovery repairs it from the current tail" do
    channel = provision!("tenant-a", "group-a", "connect-a", "C_A", true)
    authority = authority(channel)
    {:ok, initial} = TriagePatrolScanState.initial(cursor("2026-09-01T00:00:05.000Z", 50, 100))

    assert {:ok, stored} = TriagePatrolCursors.ensure(channel, authority, initial)

    Repo.query!(
      "UPDATE triage_patrol_cursors SET scan_state = NULL WHERE cursor_key = $1",
      [stored["cursor_key"]]
    )

    assert {:ok, []} = TriagePatrolCursors.claim_due("pod-a", limit: 1, lease_ms: 5_000)

    {:ok, repaired_state} =
      TriagePatrolScanState.initial(cursor("2026-09-01T00:00:10.000Z", 100, 200))

    assert {:ok, repaired} = TriagePatrolCursors.ensure(channel, authority, repaired_state)
    assert repaired["scan_state"] == repaired_state
    assert repaired["last_outcome"] == "reset"
    assert repaired["revision"] == stored["revision"] + 1

    assert {:ok, [claim]} =
             TriagePatrolCursors.claim_due("pod-a", limit: 1, lease_ms: 5_000)

    assert claim.scan_state == repaired_state
    assert {:ok, %{status: :failed}} = TriagePatrolCursors.fail(claim, :test_complete)
  end

  test "known deployed v1 scan state is reset before it can be claimed" do
    channel = provision!("tenant-a", "group-a", "connect-a", "C_A", true)
    authority = authority(channel)
    {:ok, initial} = TriagePatrolScanState.initial(cursor("2026-09-01T00:00:05.000Z", 50, 100))

    assert {:ok, stored} = TriagePatrolCursors.ensure(channel, authority, initial)

    legacy_state = %{
      "schema" => "comma.triage-patrol-scan.v1",
      "phase" => "history",
      "history" => %{
        "cursor" => "legacy-next-page",
        "oldest_ts" => "1787018000.000001",
        "newest_ts" => "1787019000.000001"
      },
      "range" => %{"oldest_ts" => "1787018000.000001", "newest_ts" => "1787019000.000001"},
      "source" => %{"mode" => "slack_history", "page_count" => 2},
      "summary" => %{"admitted" => 1, "ignored" => 3}
    }

    Repo.query!(
      """
      UPDATE triage_patrol_cursors
      SET scan_state = $2, claim_token = 'legacy-claim',
          lease_until = statement_timestamp() + interval '1 hour',
          last_outcome = 'running', last_error = 'legacy partial'
      WHERE cursor_key = $1
      """,
      [stored["cursor_key"], legacy_state]
    )

    {:ok, repaired_state} =
      TriagePatrolScanState.initial(cursor("2026-09-01T00:00:10.000Z", 100, 200))

    assert {:ok, repaired} = TriagePatrolCursors.ensure(channel, authority, repaired_state)
    assert repaired["scan_state"] == repaired_state
    assert repaired["revision"] == stored["revision"] + 1
    assert repaired["last_outcome"] == "reset"
    assert is_nil(repaired["claim_token"])
    assert is_nil(repaired["lease_until"])
    assert is_nil(repaired["last_error"])

    assert {:ok, [claim]} =
             TriagePatrolCursors.claim_due("pod-a", limit: 1, lease_ms: 5_000)

    assert claim.scan_state == repaired_state
    assert {:ok, %{status: :failed}} = TriagePatrolCursors.fail(claim, :test_complete)
  end

  defp provision!(tenant_id, group_id, connect_id, channel_id, enabled?) do
    attrs = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => connect_id,
      "channel_id" => channel_id,
      "installation_generation" => ULID.generate(),
      "workspace_id" => "T_#{tenant_id}",
      "channel_name" => "channel-#{channel_id}",
      "channel_generation" => ULID.generate()
    }

    assert {:ok, channel} = SlackTriageChannels.provision_and_set_enabled(attrs, enabled?)
    Map.put(channel, "enabled", enabled?)
  end

  defp authority(channel) do
    %{
      "tenant_id" => channel["tenant_id"],
      "group_id" => channel["group_id"],
      "connect_id" => channel["connect_id"],
      "approved_channel_id" => channel["channel_id"],
      "connect_generation" => ULID.generate()
    }
  end

  defp cursor(ingest_at, message_ts_us, version) do
    %{"ingest_at" => ingest_at, "message_ts_us" => message_ts_us, "version" => version}
  end
end
