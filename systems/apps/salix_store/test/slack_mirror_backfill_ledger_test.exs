defmodule SalixStore.SlackMirrorBackfillLedgerTest do
  @moduledoc """
  The backfill ledger against a real database.

  The rules under test are the ones `tla/salix/SlackMirrorBackfill.tla`
  proves and that SQL — not the caller — has to enforce: a watermark only
  moves down, `indexed_to` is set once, and a claim is a dedupe lease that
  expires rather than a fence.
  """
  use ExUnit.Case, async: false

  alias SalixStore.{Repo, SlackMirrorBackfillLedger, ULID}

  setup do
    Repo.query!("TRUNCATE slack_mirror_channel_watermarks, slack_mirror_backfill_connects")
    :ok
  end

  describe "channel watermarks" do
    test "first claim creates the row with no watermark and holds it" do
      key = key()

      assert {:ok, row} = SlackMirrorBackfillLedger.claim_channel(key, 60_000)
      assert row["indexed_from_ts_us"] == nil
      assert row["indexed_to_ts_us"] == nil
      assert row["exhausted"] == false

      assert :busy = SlackMirrorBackfillLedger.claim_channel(key, 60_000)
    end

    test "the watermark only ever moves down and indexed_to is set once" do
      key = key()
      {:ok, _row} = SlackMirrorBackfillLedger.claim_channel(key, 60_000)

      assert :ok = SlackMirrorBackfillLedger.lower_watermark(key, 800, 1_000)
      assert {:ok, %{"indexed_from_ts_us" => 800, "indexed_to_ts_us" => 1_000}} = watermark(key)

      # A stale or concurrent walker reporting a HIGHER timestamp, from a later
      # start, changes nothing: it has only said something already known.
      assert :ok = SlackMirrorBackfillLedger.lower_watermark(key, 900, 1_500)
      assert {:ok, %{"indexed_from_ts_us" => 800, "indexed_to_ts_us" => 1_000}} = watermark(key)

      assert :ok = SlackMirrorBackfillLedger.lower_watermark(key, 500, 1_500)
      assert {:ok, %{"indexed_from_ts_us" => 500, "indexed_to_ts_us" => 1_000}} = watermark(key)
    end

    test "lowering does not need a claim" do
      key = key()
      {:ok, _row} = SlackMirrorBackfillLedger.claim_channel(key, 60_000)
      :ok = SlackMirrorBackfillLedger.release_channel(key)

      assert :ok = SlackMirrorBackfillLedger.lower_watermark(key, 100, 200)
      assert {:ok, %{"indexed_from_ts_us" => 100}} = watermark(key)
    end

    test "a claim expires and can then be taken again" do
      key = key()

      assert {:ok, _row} = SlackMirrorBackfillLedger.claim_channel(key, 200)
      assert :busy = SlackMirrorBackfillLedger.claim_channel(key, 200)

      Process.sleep(250)
      assert {:ok, _row} = SlackMirrorBackfillLedger.claim_channel(key, 60_000)
    end

    test "renew extends only a live claim" do
      key = key()

      {:ok, _row} = SlackMirrorBackfillLedger.claim_channel(key, 200)
      assert :ok = SlackMirrorBackfillLedger.renew_channel(key, 60_000)

      Process.sleep(250)
      # Renewed, so still held.
      assert :busy = SlackMirrorBackfillLedger.claim_channel(key, 60_000)

      :ok = SlackMirrorBackfillLedger.release_channel(key)
      assert {:error, :claim_lost} = SlackMirrorBackfillLedger.renew_channel(key, 60_000)
    end

    test "exhaustion and errors are recorded without touching the watermark" do
      key = key()
      {:ok, _row} = SlackMirrorBackfillLedger.claim_channel(key, 60_000)
      :ok = SlackMirrorBackfillLedger.lower_watermark(key, 300, 900)

      assert :ok = SlackMirrorBackfillLedger.record_channel_error(key, {:slack, "ratelimited"})
      assert {:ok, %{"last_error" => error, "indexed_from_ts_us" => 300}} = watermark(key)
      assert error =~ "ratelimited"

      assert :ok = SlackMirrorBackfillLedger.mark_exhausted(key)

      assert {:ok, %{"exhausted" => true, "last_error" => nil, "indexed_from_ts_us" => 300}} =
               watermark(key)
    end

    test "list_watermarks is tenant and workspace scoped" do
      here = key()
      other = Map.merge(here, %{"workspace_id" => "T_OTHER", "channel_id" => "C_OTHER"})
      {:ok, _} = SlackMirrorBackfillLedger.claim_channel(here, 60_000)
      {:ok, _} = SlackMirrorBackfillLedger.claim_channel(other, 60_000)
      :ok = SlackMirrorBackfillLedger.lower_watermark(here, 100, 200)

      assert {:ok, [row]} =
               SlackMirrorBackfillLedger.list_watermarks(%{
                 "tenant_id" => here["tenant_id"],
                 "workspace_id" => here["workspace_id"]
               })

      assert row["channel_id"] == here["channel_id"]
      assert row["indexed_from_ts_us"] == 100

      assert {:ok, []} =
               SlackMirrorBackfillLedger.list_watermarks(%{
                 "tenant_id" => here["tenant_id"],
                 "workspace_id" => "T_MISSING"
               })
    end

    test "a malformed key is refused rather than written" do
      assert {:error, :invalid_slack_mirror_channel_key} =
               SlackMirrorBackfillLedger.claim_channel(%{"tenant_id" => "t"}, 60_000)

      assert {:error, :invalid_slack_mirror_channel_key} =
               SlackMirrorBackfillLedger.lower_watermark(
                 Map.put(key(), "channel_id", " C "),
                 1,
                 2
               )
    end
  end

  describe "installation claims" do
    test "a newly discovered installation is due at once and then held" do
      connect = connect()

      assert :ok = SlackMirrorBackfillLedger.upsert_connects([connect])
      assert {:ok, row} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
      assert row["connect_id"] == connect["connect_id"]
      assert row["group_id"] == connect["group_id"]
      assert :empty = SlackMirrorBackfillLedger.claim_due_connect(60_000)
    end

    test "rediscovery keeps the schedule and the claim" do
      connect = connect()
      :ok = SlackMirrorBackfillLedger.upsert_connects([connect])
      {:ok, _row} = SlackMirrorBackfillLedger.claim_due_connect(60_000)

      assert :ok = SlackMirrorBackfillLedger.upsert_connects([connect])
      assert :empty = SlackMirrorBackfillLedger.claim_due_connect(60_000)
    end

    test "two installations in one workspace are both claimable, because they are two budgets" do
      first = connect()
      second = connect()
      :ok = SlackMirrorBackfillLedger.upsert_connects([first, second])

      assert {:ok, a} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
      assert {:ok, b} = SlackMirrorBackfillLedger.claim_due_connect(60_000)

      assert MapSet.new([a["connect_id"], b["connect_id"]]) ==
               MapSet.new([first["connect_id"], second["connect_id"]])
    end

    test "the installation due the longest is claimed first" do
      first = connect()
      second = connect()
      :ok = SlackMirrorBackfillLedger.upsert_connects([first])
      Process.sleep(5)
      :ok = SlackMirrorBackfillLedger.upsert_connects([second])

      assert {:ok, %{"connect_id" => id}} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
      assert id == first["connect_id"]
    end

    test "finishing releases the claim and defers the next pass" do
      connect = connect()
      :ok = SlackMirrorBackfillLedger.upsert_connects([connect])
      {:ok, _row} = SlackMirrorBackfillLedger.claim_due_connect(60_000)

      assert :ok = SlackMirrorBackfillLedger.finish_connect(connect["connect_id"], 200, nil)
      # Released but not due.
      assert :empty = SlackMirrorBackfillLedger.claim_due_connect(60_000)

      Process.sleep(250)
      assert {:ok, _row} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
    end

    test "a kick makes an idle installation due now" do
      connect = connect()
      :ok = SlackMirrorBackfillLedger.upsert_connects([connect])
      {:ok, _row} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
      assert :ok = SlackMirrorBackfillLedger.finish_connect(connect["connect_id"], 60_000, nil)
      assert :empty = SlackMirrorBackfillLedger.claim_due_connect(60_000)

      assert :ok = SlackMirrorBackfillLedger.kick_connect(connect)
      assert {:ok, %{"connect_id" => id}} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
      assert id == connect["connect_id"]
    end

    test "a kick during a pass is still due after finish defers" do
      connect = connect()
      :ok = SlackMirrorBackfillLedger.upsert_connects([connect])
      {:ok, claimed} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
      assert :ok = SlackMirrorBackfillLedger.kick_connect(connect)

      assert :ok =
               SlackMirrorBackfillLedger.finish_connect(
                 connect["connect_id"],
                 60_000,
                 nil,
                 claimed["kick_generation"]
               )

      assert {:ok, %{"connect_id" => id}} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
      assert id == connect["connect_id"]
    end

    test "a kick survives every stale overlapping finisher" do
      connect = connect()
      :ok = SlackMirrorBackfillLedger.upsert_connects([connect])
      {:ok, first} = SlackMirrorBackfillLedger.claim_due_connect(200)
      Process.sleep(250)
      {:ok, second} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
      assert :ok = SlackMirrorBackfillLedger.kick_connect(connect)

      assert :ok =
               SlackMirrorBackfillLedger.finish_connect(
                 connect["connect_id"],
                 60_000,
                 nil,
                 first["kick_generation"]
               )

      assert :ok =
               SlackMirrorBackfillLedger.finish_connect(
                 connect["connect_id"],
                 60_000,
                 nil,
                 second["kick_generation"]
               )

      assert {:ok, %{"connect_id" => id}} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
      assert id == connect["connect_id"]
    end

    test "a pass that ended in error is recorded and still released" do
      connect = connect()
      :ok = SlackMirrorBackfillLedger.upsert_connects([connect])
      {:ok, _row} = SlackMirrorBackfillLedger.claim_due_connect(60_000)

      assert :ok =
               SlackMirrorBackfillLedger.finish_connect(
                 connect["connect_id"],
                 0,
                 {:slack, "invalid_auth"}
               )

      assert {:ok, %{"last_error" => error, "leased_until" => nil}} =
               SlackMirrorBackfillLedger.connect(connect["connect_id"])

      assert error =~ "invalid_auth"
      assert {:ok, _row} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
    end

    test "an expired claim is taken over; renew then reports it lost" do
      connect = connect()
      :ok = SlackMirrorBackfillLedger.upsert_connects([connect])
      {:ok, _row} = SlackMirrorBackfillLedger.claim_due_connect(200)

      Process.sleep(250)

      assert {:error, :claim_lost} =
               SlackMirrorBackfillLedger.renew_connect(connect["connect_id"], 60_000)

      assert {:ok, _row} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
      assert :ok = SlackMirrorBackfillLedger.renew_connect(connect["connect_id"], 60_000)
    end

    test "a forgotten installation is gone until rediscovered" do
      connect = connect()
      :ok = SlackMirrorBackfillLedger.upsert_connects([connect])

      assert :ok = SlackMirrorBackfillLedger.delete_connect(connect["connect_id"])
      assert {:error, :not_found} = SlackMirrorBackfillLedger.connect(connect["connect_id"])

      :ok = SlackMirrorBackfillLedger.upsert_connects([connect])
      assert {:ok, _row} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
    end

    test "a malformed installation is refused rather than written" do
      assert {:error, :invalid_slack_mirror_connect} =
               SlackMirrorBackfillLedger.upsert_connects([%{"connect_id" => "imc1"}])
    end
  end

  defp connect do
    %{
      "connect_id" => "imc_" <> ULID.generate(),
      "tenant_id" => "ten1_ledger",
      "group_id" => "grp1_ledger"
    }
  end

  defp key do
    %{
      "tenant_id" => "ten1_ledger",
      "workspace_id" => "T_LEDGER",
      "channel_id" => "C_" <> ULID.generate()
    }
  end

  defp watermark(key), do: SlackMirrorBackfillLedger.watermark(key)
end
