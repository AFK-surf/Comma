defmodule SalixAgent.SessionFormat1BackupPruneTest do
  use ExUnit.Case, async: false

  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State
  alias SalixAgent.InternalSessionStore
  alias SalixAgent.SessionFormat1BackupPrune, as: Prune
  alias SalixStore.{ArchiveLog, Codec, Keys, S3}

  @session "ses1_0000000000000000870"

  setup do
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    SalixStore.Repo.query!("DELETE FROM salix_cutover_markers WHERE name = $1", [
      "internal_session_format2_v1"
    ])

    :ok
  end

  defp deliver(id) do
    %{
      "type" => "delivery",
      "from_queue" => true,
      "message_id" => id,
      "role" => "user",
      "content" => "input #{id}",
      "source_message_id" => "src-#{id}",
      "created_at" => 1_000 + id
    }
  end

  # Historical migration fixture: original format-1 bytes (including a nil-result
  # failed call), the resulting archive/hot object and a real marker row.
  # The retired format-2 writer is deliberately not invoked.
  defp migrate_legacy_fleet! do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    {:ok, _} = S3.put(Keys.ctl_agent(agent_id), Jason.encode!(%{"agent_id" => agent_id}))

    state =
      agent_id
      |> InternalSession.new(@session, %{})
      |> InternalSession.export()
      |> Map.put(:storage_format, 1)
      |> InternalSession.open()
      |> InternalSession.apply_events(Enum.map(1..5, &deliver/1))
      |> InternalSession.export()

    state = %State{
      state
      | messages: Enum.map(state.messages, &Map.delete(&1, :seq)),
        last_seq: 0,
        compacted_through: 5,
        summary: "covered",
        async_tool_calls: %{
          "call-failed" => %{
            "tool_call_id" => "call-failed",
            "status" => "failed",
            "result" => nil,
            "error" => "boom",
            "completed_at" => 2_000
          }
        }
    }

    key = Keys.agent_internal_runtime_session(agent_id, @session)
    {:ok, _} = S3.put(key, Codec.encode_snapshot(state))

    {:ok, _} =
      S3.put(
        String.replace_suffix(key, "state.etf.zst", "backup/format1-state.etf.zst"),
        Codec.encode_snapshot(state)
      )

    {:ok, normalized} =
      state |> InternalSession.open() |> SalixAgent.InternalSessionFormat3Legacy.normalize()

    records = InternalSessionStore.window_records_shaped(normalized)
    compacted_seq = InternalSession.get(normalized, :compacted_seq)
    archived = Enum.take_while(records, &(&1.seq <= compacted_seq))

    {:ok, _} =
      S3.put(
        String.replace_suffix(key, "state.etf.zst", "archive.jsonl"),
        ArchiveLog.encode(archived)
      )

    current = %{
      InternalSession.export(normalized)
      | archive_chunks: ArchiveLog.spans(archived, 0),
        archived_through: compacted_seq,
        messages:
          Enum.reject(InternalSession.get(normalized, :messages), &(&1.seq <= compacted_seq)),
        events: [],
        async_results: []
    }

    {:ok, _} = S3.put(key, Codec.encode_snapshot(current))

    SalixStore.Repo.query!(
      "INSERT INTO salix_cutover_markers (name, completed_at, evidence) VALUES ('internal_session_format2_v1', now(), '{}')"
    )

    {agent_id, key}
  end

  defp expire_retention! do
    SalixStore.Repo.query!(
      "UPDATE salix_cutover_markers SET completed_at = now() - interval '15 days' WHERE name = $1",
      ["internal_session_format2_v1"]
    )
  end

  test "an open retention window refuses through the REAL marker row type" do
    {_agent_id, _key} = migrate_legacy_fleet!()

    # The marker row was just written by the fixture: the window is open.
    # Before the NaiveDateTime fix this path crashed with FunctionClauseError
    # instead of refusing.
    assert {:error, {:retention_window_open, _age, 14}} = Prune.run()
  end

  test "an expired window verifies through the real path and deletes the backup" do
    {_agent_id, key} = migrate_legacy_fleet!()
    expire_retention!()

    backup_key = String.replace_suffix(key, "/state.etf.zst", "/backup/format1-state.etf.zst")
    assert {:ok, _} = S3.get(backup_key)

    assert {:ok, %{"backups" => 1, "deleted" => 0, "dry_run" => true}} = Prune.run(dry_run: true)
    assert {:ok, _} = S3.get(backup_key)

    assert {:ok, %{"backups" => 1, "deleted" => 1, "dry_run" => false}} = Prune.run()
    assert {:error, :not_found} = S3.get(backup_key)
  end

  # The migrated terminal record now lives in the archive object (a single
  # object has no packing boundary to leave it behind), so corrupting the
  # format-2 side means rewriting that object AND the catalog that
  # addresses it — otherwise the read fails structurally and never reaches
  # the content comparison the prune is supposed to make.
  defp rewrite_archive!(key, fun) do
    archive_key = String.replace_suffix(key, "state.etf.zst", "archive.jsonl")
    {:ok, %{body: bytes, etag: archive_etag}} = S3.get(archive_key)

    records =
      bytes
      |> ArchiveLog.decode!()
      |> fun.()
      |> Enum.sort_by(& &1.seq)

    rewritten = ArchiveLog.encode(records)
    {:ok, _} = S3.put(archive_key, rewritten, if_match: archive_etag)

    {:ok, %{body: state_bytes, etag: etag}} = S3.get(key)
    {:ok, loaded} = InternalSession.load(Codec.snapshot_etf(state_bytes))
    current = InternalSession.export(loaded)
    through = if records == [], do: 0, else: List.last(records).seq

    catalog =
      if records == [],
        do: [],
        else: [
          [
            List.first(records).seq,
            through,
            ArchiveLog.message_count(records),
            0,
            byte_size(rewritten)
          ]
        ]

    repaired = %State{current | archived_through: through, archive_chunks: catalog}

    {:ok, _} =
      S3.put(key, Codec.encode_snapshot(repaired), if_match: etag)
  end

  test "a corrupted omitted-payload field refuses deletion" do
    {_agent_id, key} = migrate_legacy_fleet!()
    expire_retention!()

    # The failed call's diagnostic field (error) is corrupted in the
    # migrated record: full-record equality must catch what the old
    # status/result-only comparison ignored.
    rewrite_archive!(key, fn records ->
      Enum.map(records, fn
        %{kind: "async_result"} = record ->
          %{record | data: Map.put(record.data, "error", "rewritten")}

        record ->
          record
      end)
    end)

    assert {:error, {:verification_failed, _backup, {:result_mismatch, "call-failed"}}} =
             Prune.run()
  end

  test "an otherwise-identical record at the wrong seq refuses deletion" do
    {_agent_id, key} = migrate_legacy_fleet!()
    expire_retention!()

    # Swap the terminal record with the last message: every record is still
    # present and the range still tiles, but the result now sits at a seq
    # that is not the one the backup replays to.
    rewrite_archive!(key, fn records ->
      result = Enum.find(records, &(&1.kind == "async_result"))
      other = records |> Enum.filter(&(&1.kind == "message")) |> List.last()

      Enum.map(records, fn
        ^result -> %{result | seq: other.seq}
        ^other -> %{other | seq: result.seq}
        record -> record
      end)
    end)

    assert {:error,
            {:verification_failed, _backup, {:result_seq_mismatch, "call-failed", _exp, _got}}} =
             Prune.run()
  end

  test "a missing nil-result terminal record refuses deletion instead of certifying" do
    {agent_id, key} = migrate_legacy_fleet!()
    expire_retention!()

    # Drop the migrated failed-call record: its result is nil in the backup
    # too, so the old Map.get == comparison would have certified the loss.
    rewrite_archive!(key, fn records -> Enum.reject(records, &(&1.kind == "async_result")) end)

    assert {:error, {:verification_failed, _backup, {:result_missing, "call-failed"}}} =
             Prune.run()

    backup_key = String.replace_suffix(key, "/state.etf.zst", "/backup/format1-state.etf.zst")
    assert {:ok, _} = S3.get(backup_key)
    _ = agent_id
  end
end
