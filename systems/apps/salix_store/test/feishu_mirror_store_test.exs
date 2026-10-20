defmodule SalixStore.FeishuMirrorStoreTest do
  @moduledoc """
  The Feishu mirror's PostgreSQL state against a real database: the outbox
  keeps a row until an explicit delete, and the backfill ledger leases one
  installation at a time and only ever lowers a container's watermark.
  """
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:feishu_mirror_outbox, :feishu_mirror_backfill]

  alias SalixStore.{FeishuMirrorBackfillLedger, FeishuMirrorOutbox, Repo}

  @scope %{"tenant_id" => "tenant-a", "app_id" => "cli_app_a"}

  setup do
    Repo.query!("TRUNCATE feishu_mirror_containers")

    :ok
  end

  describe "outbox" do
    test "rows leave only by delete; a claim keeps drainers apart and a deferral counts" do
      for n <- 1..3, do: assert(:ok = FeishuMirrorOutbox.append(row("om_#{n}")))

      assert {:ok, claimed} = FeishuMirrorOutbox.claim(2, 60_000)
      assert Enum.map(claimed, & &1.row["message_id"]) == ~w(om_1 om_2)
      # Integers survive jsonb exactly: `version` is the merge key.
      assert hd(claimed).row["version"] == 2_000_000_000_000_000

      assert {:ok, [third]} = FeishuMirrorOutbox.claim(10, 60_000)
      assert third.row["message_id"] == "om_3"

      assert {:ok, [{"oc_chat", "om_1"}]} =
               FeishuMirrorOutbox.pending_message_keys(@scope, [
                 {"oc_chat", "om_1"},
                 {"oc_chat", "om_missing"}
               ])

      assert {:ok, []} =
               FeishuMirrorOutbox.pending_message_keys(
                 Map.put(@scope, "app_id", "cli_other"),
                 [{"oc_chat", "om_1"}]
               )

      assert :ok = FeishuMirrorOutbox.defer([third.id], :clickhouse_down, 0)
      assert {:ok, [retried]} = FeishuMirrorOutbox.claim(10, 60_000)
      assert retried.id == third.id and retried.attempts == 1

      assert :ok = FeishuMirrorOutbox.delete(Enum.map(claimed, & &1.id) ++ [third.id])
      assert {:ok, nil} = FeishuMirrorOutbox.oldest_pending_age_ms()
    end
  end

  describe "backfill ledger" do
    test "one due installation is leased at a time and finishing reschedules it" do
      assert :ok =
               FeishuMirrorBackfillLedger.upsert_connects([
                 %{"connect_id" => "c1", "tenant_id" => "tenant-a", "group_id" => "g1"},
                 %{"connect_id" => "", "tenant_id" => "tenant-a", "group_id" => "g1"}
               ])

      assert {:ok, %{"connect_id" => "c1", "group_id" => "g1"}} =
               FeishuMirrorBackfillLedger.claim_due_connect(60_000)

      assert :empty = FeishuMirrorBackfillLedger.claim_due_connect(60_000)
      assert :ok = FeishuMirrorBackfillLedger.finish_connect("c1", 0, nil)
      assert {:ok, %{"connect_id" => "c1"}} = FeishuMirrorBackfillLedger.claim_due_connect(60_000)
      assert :ok = FeishuMirrorBackfillLedger.finish_connect("c1", 3_600_000, :boom)
      assert :empty = FeishuMirrorBackfillLedger.claim_due_connect(60_000)
    end

    test "watermarks only move down and coverage reports the holes" do
      assert {:ok, :not_synced} = FeishuMirrorBackfillLedger.coverage(@scope, nil, 0)

      chat = %{"container_type" => "chat", "container_id" => "oc_a", "chat_id" => "oc_a"}
      thread = %{"container_type" => "thread", "container_id" => "omt_1", "chat_id" => "oc_a"}
      assert :ok = FeishuMirrorBackfillLedger.upsert_containers(@scope, [chat, thread, chat])

      assert {:ok, {:incomplete, nil}} = FeishuMirrorBackfillLedger.coverage(@scope, "oc_a", 0)

      commit = fn container, oldest, token ->
        FeishuMirrorBackfillLedger.commit_page(@scope, container, %{
          "oldest_us" => oldest,
          "observed_us" => 9_000,
          "page_token" => token,
          "exhausted" => is_nil(token)
        })
      end

      assert :ok = commit.(chat, 5_000, "next")
      # A stale walker commits a newer page; the watermark does not rise.
      assert :ok = commit.(chat, 7_000, "stale")
      assert :ok = commit.(thread, 6_000, nil)

      assert {:ok, [current]} = FeishuMirrorBackfillLedger.next_containers(@scope, 10)
      assert current["container_id"] == "oc_a"
      assert current["indexed_from_us"] == 5_000
      assert current["indexed_to_us"] == 9_000

      assert {:ok, {:incomplete, 5_000}} = FeishuMirrorBackfillLedger.coverage(@scope, nil, 0)
      assert {:ok, :complete} = FeishuMirrorBackfillLedger.coverage(@scope, nil, 5_000)
      assert {:ok, :not_synced} = FeishuMirrorBackfillLedger.coverage(@scope, "oc_b", 0)

      assert :ok = FeishuMirrorBackfillLedger.fail_container(@scope, chat, :timeout)

      assert {:ok, [%{"page_token" => nil}]} =
               FeishuMirrorBackfillLedger.next_containers(@scope, 10)

      assert :ok = commit.(chat, 1_000, nil)
      assert {:ok, []} = FeishuMirrorBackfillLedger.next_containers(@scope, 10)
      assert {:ok, :complete} = FeishuMirrorBackfillLedger.coverage(@scope, nil, 0)
    end
  end

  defp row(message_id) do
    %{
      "tenant_id" => "tenant-a",
      "app_id" => "cli_app_a",
      "chat_id" => "oc_chat",
      "message_id" => message_id,
      "version" => 2_000_000_000_000_000,
      "text" => "hello"
    }
  end
end
