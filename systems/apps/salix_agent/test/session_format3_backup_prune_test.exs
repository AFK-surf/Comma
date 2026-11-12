defmodule SalixAgent.SessionFormat3BackupPruneTest do
  use SystemsClock.Case, async: false
  alias SalixAgent.{InternalSession, InternalSessionFormat3Legacy, SessionFormat3BackupPrune}
  alias SalixStore.{ArchiveLog, Codec, Ids, Keys, Repo, S3, SealedSegments}

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name='internal_session_format3_v1'")

    Repo.query!(
      "INSERT INTO salix_cutover_markers(name,completed_at,evidence) VALUES('internal_session_format3_v1',$1,$2)",
      [SystemsClock.utc_now(), %{"historical_fixture" => true}]
    )

    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, previous) end)
    :ok
  end

  test "retention and complete retained history protect the old recovery backup" do
    fixture = historical_backup(2)
    assert {:error, :retention_window_open} = SessionFormat3BackupPrune.run(dry_run: false)
    assert {:ok, %{verified: 2, deleted: 0}} = SessionFormat3BackupPrune.run(retention_days: 0)
    assert {:ok, %{deleted: 2}} = SessionFormat3BackupPrune.run(retention_days: 0, dry_run: false)
    assert {:error, :not_found} = S3.get(fixture.backup_state)
    assert {:error, :not_found} = S3.get(fixture.backup_archive)
    assert {:ok, %{body: body}} = S3.get(fixture.segment)
    assert length(SealedSegments.decode(body)) == 6
    assert {:ok, %{body: original}} = S3.get(fixture.archive)
    assert original == fixture.original_archive
  end

  test "missing current history stops backup deletion" do
    fixture = historical_backup(2)
    :ok = S3.delete(fixture.segment)

    assert {:error, {:backup_prune_failed, _, _}} =
             SessionFormat3BackupPrune.run(retention_days: 0, dry_run: false)

    assert {:ok, _} = S3.get(fixture.backup_state)
    assert {:ok, _} = S3.get(fixture.backup_archive)
  end

  test "format-1 backup verification resumes after the state backup was deleted" do
    fixture = historical_backup(1)
    S3.Fake.set_fault_for(self(), {:fail, 403, :delete, fixture.backup_archive})

    assert {:error, {:backup_prune_failed, _, _}} =
             SessionFormat3BackupPrune.run(retention_days: 0, dry_run: false)

    assert {:error, :not_found} = S3.get(fixture.backup_state)
    assert {:ok, _} = S3.get(fixture.backup_archive)
    assert {:ok, %{deleted: 1}} = SessionFormat3BackupPrune.run(retention_days: 0, dry_run: false)
    assert {:error, :not_found} = S3.get(fixture.backup_archive)
  end

  # Actual historical input and output layouts, assembled as source fixtures.
  # No retired online writer runs to arrange a current maintenance test.
  defp historical_backup(format) do
    agent = "backup-" <> Base.encode16(SystemsRuntime.Proc.random_bytes(8), case: :lower)
    session = Ids.new_session_id()

    base =
      InternalSession.new(agent, session)
      |> InternalSession.apply_events(
        for id <- 1..8,
            do: %{
              "type" => "delivery",
              "from_queue" => true,
              "message_id" => id,
              "role" => "user",
              "content" => "message #{id}",
              "source_message_id" => "source-#{id}",
              "created_at" => id
            }
      )
      |> InternalSession.export()

    records = Enum.map(base.messages, &ArchiveLog.shape("message", &1.seq, &1))
    archive_key = Keys.agent_internal_runtime_session_archive(agent, session)
    original_archive = if format == 2, do: ArchiveLog.encode(Enum.take(records, 4)), else: ""
    {:ok, _} = S3.put(archive_key, original_archive)

    source =
      if format == 2 do
        %{
          base
          | storage_format: 2,
            archived_through: 4,
            archive_chunks: ArchiveLog.spans(Enum.take(records, 4), 0),
            messages: Enum.drop(base.messages, 4)
        }
      else
        %{
          base
          | storage_format: 1,
            messages: Enum.map(base.messages, &Map.delete(&1, :seq)),
            last_seq: 0,
            compacted_seq: 0
        }
      end

    original_bytes = Codec.encode_snapshot(source)
    key = Keys.agent_internal_runtime_session(agent, session)
    {:ok, %{etag: etag}} = S3.put(key, original_bytes)

    prefix =
      String.replace_suffix(
        key,
        "state.etf.zst",
        "backup/format3/#{Base.url_encode64(etag, padding: false)}/"
      )

    {:ok, _} = S3.put(prefix <> "state.etf.zst", original_bytes)
    {:ok, _} = S3.put(prefix <> "archive.jsonl", original_archive)
    {:ok, normalized} = InternalSessionFormat3Legacy.normalize(InternalSession.open(source))
    normalized = InternalSession.export(normalized)
    segment = Keys.agent_internal_runtime_session_segment(agent, session, 1)
    archived = Enum.take(records, 6)
    {:ok, _} = S3.put(segment, SealedSegments.encode(archived))

    current = %{
      normalized
      | storage_format: 3,
        archive_chunks: [],
        archived_through: 6,
        segment_catalog: [SealedSegments.entry_for(archived)],
        messages: Enum.drop(base.messages, 6)
    }

    {:ok, _} = S3.put(key, Codec.encode_session_snapshot(current))

    %{
      backup_state: prefix <> "state.etf.zst",
      backup_archive: prefix <> "archive.jsonl",
      segment: segment,
      archive: archive_key,
      original_archive: original_archive
    }
  end
end
