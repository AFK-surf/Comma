defmodule SalixStore.SlackMirrorOutboxTest do
  @moduledoc """
  The webhook-to-ClickHouse outbox against a real database.

  What SQL has to hold, from `tla/salix/SlackMirrorOutbox.tla`: a row leaves
  only by an explicit delete, a claim keeps two drainers apart until it
  expires, and a deferred row comes back after its backoff with its attempts
  counted.
  """
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:slack_mirror_outbox]

  alias SalixStore.SlackMirrorOutbox

  setup do
    # Claims expire on the database's clock, which follows a manual
    # SystemsClock (SystemsRuntime.DbClock): the test moves it past a claim.
    SystemsClock.manual()
    on_exit(&SystemsClock.reset/0)
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

  test "writers retain only connection references in the outbox context" do
    assert :ok =
             SlackMirrorOutbox.append(row(2), "message", %{
               "group_id" => "group",
               "connect_id" => "connect",
               "bot_token" => "must-not-be-stored"
             })

    assert {:ok, [current]} = SlackMirrorOutbox.claim(10, 60_000)
    assert Map.delete(current.row, "source_write_id") == row(2)
    assert {:ok, _} = Ecto.UUID.cast(current.row["source_write_id"])
    assert current.context == %{"group_id" => "group", "connect_id" => "connect"}
  end

  test "a claimed row is invisible to a second drainer until the claim expires" do
    :ok = SlackMirrorOutbox.append(row(1))

    assert {:ok, [_entry]} = SlackMirrorOutbox.claim(10, 200)
    assert {:ok, []} = SlackMirrorOutbox.claim(10, 200)

    SystemsClock.advance(250)
    assert {:ok, [_entry]} = SlackMirrorOutbox.claim(10, 60_000)
  end

  test "delete removes exactly the acknowledged rows" do
    for n <- 1..3, do: :ok = SlackMirrorOutbox.append(row(n))
    {:ok, [a, b, c]} = SlackMirrorOutbox.claim(10, 200)

    assert :ok = SlackMirrorOutbox.delete([a.id, c.id])

    SystemsClock.advance(250)
    assert {:ok, [left]} = SlackMirrorOutbox.claim(10, 60_000)
    assert left.id == b.id
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
