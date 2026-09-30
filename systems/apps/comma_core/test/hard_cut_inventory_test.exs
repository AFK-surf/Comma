defmodule Comma.HardCutInventoryTest do
  use ExUnit.Case, async: false

  alias Comma.Migrations.LegacyS3Fixture

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    LegacyS3Fixture.reset!()

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, previous_backend)
      LegacyS3Fixture.reset!()
    end)

    :ok
  end

  test "Comma Conversation-era rows are reported only as retired physical data" do
    workspace = put_workspace()

    retired_rows = [
      {:conversations, "cnv-old", %{"messages" => [%{"content" => "legacy"}]}},
      {:salix_conversation_projections, "projection-old", %{"conversation_id" => "cnv-old"}},
      {:assistant_chat_bindings, "chat-old", %{"conversation_id" => "cnv-old"}},
      {:conversation_adoption_negatives, "negative-old", %{"conversation_id" => "cnv-old"}},
      {:conversation_adoption_retries, "retry-old", %{"conversation_id" => "cnv-old"}},
      {:conversation_adoption_attempts, "attempt-old", %{"conversation_id" => "cnv-old"}},
      {:conversation_reconciliation_cursors, "cursor-old", %{"cursor" => "legacy"}}
    ]

    for {bucket, id, value} <- retired_rows do
      assert {:ok, _} = LegacyS3Fixture.put(bucket, id, value)
    end

    assert {:ok, _} =
             LegacyS3Fixture.put(
               "workspace_conversation_items/#{workspace["id"]}",
               "cnv-old",
               %{"conversation_id" => "cnv-old"}
             )

    assert {:ok, report} = Comma.HardCutInventory.generate()
    assert report["machine_ready"]
    assert report["destructive_actions"] == []

    artifacts = Map.new(report["artifacts"], &{&1["id"], &1})

    assert artifacts["workspaces"]["category"] == "active_serving"
    assert artifacts["user_workspaces"]["category"] == "active_serving"

    for id <-
          Enum.map(retired_rows, fn {bucket, _id, _value} -> to_string(bucket) end) ++
            ["workspace_conversation_items"] do
      artifact = Map.fetch!(artifacts, id)
      assert artifact["category"] == "legacy_data"
      assert artifact["canonical_owner"] == "retired Comma-local Conversation implementation"
      assert artifact["current_writer"] == "none"
      assert artifact["current_writers"] == []

      assert artifact["current_readers"] == [
               "Comma.HardCutInventory (read-only inventory)"
             ]

      assert artifact["target_relation"] == "none"
      assert artifact["migration_mapping"] == "exclude_legacy"
      assert artifact["disposition"] == "inventory_then_purge"
    end

    assert Enum.map(report["machine_checks"], & &1["id"]) == ["legacy_auth_prefixes_empty"]
  end

  test "legacy auth prefixes remain a bounded release inventory" do
    put_workspace()

    for bucket <- [:users, :sessions, :grants], suffix <- 1..2 do
      assert {:ok, _} =
               LegacyS3Fixture.put(bucket, "legacy-row-#{suffix}", %{
                 "id" => "legacy-row-#{suffix}"
               })
    end

    assert :ok = SalixStore.S3.Fake.reset_read_log()
    assert {:ok, report} = Comma.HardCutInventory.generate()

    check = Enum.find(report["machine_checks"], &(&1["id"] == "legacy_auth_prefixes_empty"))

    assert check == %{
             "blocking_count" => 3,
             "expectation" =>
               "legacy S3 users/sessions/grants are empty; any rows stop cutover and require a separately owned migration design",
             "id" => "legacy_auth_prefixes_empty",
             "status" => "block"
           }

    artifacts = Map.new(report["artifacts"], &{&1["id"], &1})

    for bucket <- ["users", "sessions", "grants"] do
      assert artifacts[bucket]["record_count"] == 1
      assert artifacts[bucket]["record_count_semantics"] == "bounded_existence_lower_bound"
      assert artifacts[bucket]["record_count_limit"] == 1
      assert artifacts[bucket]["has_more"]
      assert artifacts[bucket]["disposition"] == "migration_decision_required"
    end

    for prefix <- Enum.map(["users", "sessions", "grants"], &"comma/#{&1}/") do
      assert Enum.any?(SalixStore.S3.Fake.read_log(), fn
               {:list, ^prefix, opts} -> Keyword.get(opts, :max_keys) == 1
               _other -> false
             end)
    end
  end

  test "auth stop inventory is read-only and carries no destructive action" do
    assert {:ok, inventory} = Comma.HardCutInventory.auth_cutover_stop_inventory()
    assert inventory["mode"] == "read_only"
    assert inventory["empty"]
    assert inventory["destructive_actions"] == []
    assert length(inventory["artifacts"]) == 3
  end

  test "physical S3 LastModified is reported for retired data" do
    put_workspace()

    assert {:ok, _} =
             SalixStore.S3.put(
               "comma/conversations/legacy-conversation.json",
               Jason.encode!(%{"conversation_id" => "legacy-conversation"})
             )

    assert {:ok, _} =
             SalixStore.S3.put(
               "comma/conversation_events/legacy-stream.json",
               Jason.encode!(%{"event" => "legacy"})
             )

    assert {:ok, _} =
             SalixStore.S3.put(
               "ctl/migrations/conversation_identity_v1/maps/legacy.json",
               Jason.encode!(%{"mapping" => "legacy"})
             )

    assert {:ok, report} = Comma.HardCutInventory.generate()
    artifacts = Map.new(report["artifacts"], &{&1["id"], &1})

    assert is_binary(artifacts["conversations"]["last_written_at"])
    assert is_binary(artifacts["conversation_event_streams"]["last_written_at"])
    assert is_binary(artifacts["conversation_identity_history"]["last_written_at"])
  end

  defp put_workspace do
    workspace = %{"id" => "wsp-1"}
    assert {:ok, _} = LegacyS3Fixture.put(:workspaces, workspace["id"], workspace)
    workspace
  end
end
