defmodule SalixStore.SlackMirrorOutboxTest do
  @moduledoc """
  The webhook-to-ClickHouse outbox against a real database.

  What SQL has to hold, from `tla/salix/SlackMirrorOutbox.tla`: a row leaves
  only by an explicit delete, a claim keeps two drainers apart until it
  expires, and a deferred row comes back after its backoff with its attempts
  counted.
  """
  use ExUnit.Case, async: false

  alias SalixStore.{Repo, SlackMirrorOutbox}

  setup do
    Repo.query!("TRUNCATE slack_mirror_outbox")
    :ok
  end

  test "appended rows are claimed oldest first and come back intact" do
    for n <- 1..3, do: assert(:ok = SlackMirrorOutbox.append(row(n)))

    assert {:ok, entries} = SlackMirrorOutbox.claim(10, 60_000)

    assert Enum.map(entries, & &1.row["message_ts"]) == [
             "1787019000.000001",
             "1787019000.000002",
             "1787019000.000003"
           ]

    assert Enum.all?(entries, &(&1.attempts == 0))

    # Integers survive the jsonb round trip exactly: `version` is the merge
    # key, and a float there would be a different row.
    assert hd(entries).row["version"] == 1_787_019_000_000_001 * 2
  end

  test "old writers keep canonical rows intact while new writers retain only connection references" do
    canonical = row(1)
    # The old binary's INSERT omits context entirely and remains valid.
    Repo.query!(
      "INSERT INTO slack_mirror_outbox (kind, row, inserted_at) VALUES ('message', $1, timezone('UTC', clock_timestamp()))",
      [canonical]
    )

    assert :ok =
             SlackMirrorOutbox.append(row(2), "message", %{
               "group_id" => "group",
               "connect_id" => "connect",
               "bot_token" => "must-not-be-stored"
             })

    assert {:ok, [old, current]} = SlackMirrorOutbox.claim(10, 60_000)
    assert old.row == canonical
    assert old.context == %{}
    assert Map.delete(current.row, "source_write_id") == row(2)
    assert {:ok, _} = Ecto.UUID.cast(current.row["source_write_id"])
    assert current.context == %{"group_id" => "group", "connect_id" => "connect"}
    # Old readers only select row; no internal context becomes a Slack field.
    assert [[^canonical], [current_row]] =
             Repo.query!("SELECT row FROM slack_mirror_outbox ORDER BY id").rows

    assert current_row == current.row
  end

  test "a claimed row is invisible to a second drainer until the claim expires" do
    :ok = SlackMirrorOutbox.append(row(1))

    assert {:ok, [_entry]} = SlackMirrorOutbox.claim(10, 200)
    assert {:ok, []} = SlackMirrorOutbox.claim(10, 200)

    Process.sleep(250)
    assert {:ok, [_entry]} = SlackMirrorOutbox.claim(10, 60_000)
  end

  test "the claim honours its limit and leaves the rest claimable" do
    for n <- 1..5, do: :ok = SlackMirrorOutbox.append(row(n))

    assert {:ok, first} = SlackMirrorOutbox.claim(2, 60_000)
    assert {:ok, second} = SlackMirrorOutbox.claim(2, 60_000)
    assert {:ok, third} = SlackMirrorOutbox.claim(2, 60_000)

    assert length(first) == 2 and length(second) == 2 and length(third) == 1
    assert Enum.map(first ++ second ++ third, & &1.id) |> Enum.uniq() |> length() == 5
  end

  test "delete removes exactly the acknowledged rows" do
    for n <- 1..3, do: :ok = SlackMirrorOutbox.append(row(n))
    {:ok, [a, b, c]} = SlackMirrorOutbox.claim(10, 200)

    assert :ok = SlackMirrorOutbox.delete([a.id, c.id])

    Process.sleep(250)
    assert {:ok, [left]} = SlackMirrorOutbox.claim(10, 60_000)
    assert left.id == b.id
  end

  test "a deferred row waits out its backoff and carries its failure" do
    :ok = SlackMirrorOutbox.append(row(1))
    {:ok, [entry]} = SlackMirrorOutbox.claim(10, 60_000)

    assert :ok = SlackMirrorOutbox.defer([entry.id], {:error, :clickhouse_down}, 200)
    assert {:ok, []} = SlackMirrorOutbox.claim(10, 60_000)

    Process.sleep(250)
    assert {:ok, [again]} = SlackMirrorOutbox.claim(10, 60_000)
    assert again.id == entry.id
    assert again.attempts == 1

    assert %{rows: [[error]]} =
             Repo.query!("SELECT last_error FROM slack_mirror_outbox WHERE id = $1", [entry.id])

    assert error =~ "clickhouse_down"
  end

  test "pending_message_ts returns only undrained timestamps in the asked list" do
    :ok = SlackMirrorOutbox.append(row(1))
    :ok = SlackMirrorOutbox.append(row(2))

    scope = %{
      "tenant_id" => "ten1_outbox",
      "workspace_id" => "T_OUTBOX",
      "channel_id" => "C_OUTBOX"
    }

    assert {:ok, pending} =
             SlackMirrorOutbox.pending_message_ts(scope, [
               "1787019000.000001",
               "1787019000.000003"
             ])

    assert pending == ["1787019000.000001"]
  end

  test "pending_message_keys matches workspace pairs and ignores other channels" do
    :ok = SlackMirrorOutbox.append(row(1))
    :ok = SlackMirrorOutbox.append(Map.put(row(2), "channel_id", "C_OTHER"))

    scope = %{"tenant_id" => "ten1_outbox", "workspace_id" => "T_OUTBOX"}

    assert {:ok, pending} =
             SlackMirrorOutbox.pending_message_keys(scope, [
               {"C_OUTBOX", "1787019000.000001"},
               {"C_MISSING", "1787019000.000001"}
             ])

    assert pending == [{"C_OUTBOX", "1787019000.000001"}]
  end

  test "the lag signal is the age of the oldest row and nil when empty" do
    assert {:ok, nil} = SlackMirrorOutbox.oldest_pending_age_ms()

    :ok = SlackMirrorOutbox.append(row(1))
    Process.sleep(20)
    :ok = SlackMirrorOutbox.append(row(2))

    assert {:ok, age} = SlackMirrorOutbox.oldest_pending_age_ms()
    assert is_integer(age) and age >= 20
  end

  defp row(n) do
    ts_us = 1_787_019_000_000_000 + n

    %{
      "event_date" => "2026-08-18",
      "tenant_id" => "ten1_outbox",
      "workspace_id" => "T_OUTBOX",
      "channel_id" => "C_OUTBOX",
      "message_ts_us" => ts_us,
      "message_ts" => "1787019000.#{String.pad_leading(Integer.to_string(n), 6, "0")}",
      "version" => ts_us * 2,
      "deleted" => false,
      "text" => "row #{n}",
      "body_text" => "",
      "blocks" => "",
      "files" => "[]",
      "ingest_source" => "webhook"
    }
  end
end
