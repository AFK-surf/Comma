defmodule SalixAgent.InternalSessionFormat3CutoverTest do
  use ExUnit.Case, async: false
  alias SalixAgent.{InternalSession, InternalSessionFormat3Cutover, InternalSessionStore}
  alias SalixStore.{ArchiveLog, Codec, Ids, Keys, S3}

  setup do
    old = Application.get_env(:salix_store, :seal_line_bytes)
    Application.put_env(:salix_store, :seal_line_bytes, 300)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)

    SalixStore.Repo.query!(
      "DELETE FROM salix_cutover_markers WHERE name = 'internal_session_format3_v1'"
    )

    on_exit(fn ->
      if old,
        do: Application.put_env(:salix_store, :seal_line_bytes, old),
        else: Application.delete_env(:salix_store, :seal_line_bytes)
    end)

    :ok
  end

  defp delivery(n),
    do: %{
      "type" => "delivery",
      "from_queue" => true,
      "message_id" => n,
      "role" => "user",
      "content" => "message #{n} " <> String.duplicate("x", 100),
      "source_message_id" => "source-#{n}",
      "created_at" => n
    }

  defp seed(format \\ 2) do
    agent = "migration-agent-#{System.unique_integer([:positive])}"
    session = Ids.new_session_id()

    state =
      agent
      |> InternalSession.new(session)
      |> InternalSession.export()
      |> Map.put(:storage_format, format)
      |> InternalSession.open()
      |> InternalSession.apply_events(
        Enum.map(1..8, &delivery/1) ++
          [
            %{
              "type" => "compaction",
              "session_id" => session,
              "compacted_through" => 6,
              "summary_sequence" => 1,
              "summary" => "summary"
            }
          ]
      )
      |> InternalSession.export()

    state = %{state | runtime_epoch: 7, work_index_token: "preserved-index"}

    state =
      if format == 1,
        do: %{
          state
          | messages: Enum.map(state.messages, &Map.delete(&1, :seq)),
            last_seq: 0,
            compacted_seq: 0
        },
        else: state

    state =
      if format == 2 do
        records =
          Enum.take(state.messages, 4) |> Enum.map(&ArchiveLog.shape("message", &1.seq, &1))

        {:ok, _} =
          S3.put(
            Keys.agent_internal_runtime_session_archive(agent, session),
            ArchiveLog.encode(records)
          )

        %{
          state
          | archived_through: 4,
            archive_chunks: ArchiveLog.spans(records, 0),
            messages: Enum.drop(state.messages, 4)
        }
      else
        state
      end

    key = Keys.agent_internal_runtime_session(agent, session)
    bytes = Codec.encode_snapshot(state)
    {:ok, _} = S3.put(key, bytes)
    {key, state, bytes}
  end

  # The stored snapshot as the kernel loads it: a handle.
  defp read!(key) do
    {:ok, %{body: bytes}} = S3.get(key)
    {:ok, session} = InternalSession.load(Codec.snapshot_etf(bytes))
    session
  end

  defp full_ids(session) do
    {:ok, page} =
      InternalSessionStore.transcript(InternalSession.agent_id(session), session, :full)

    Enum.map(page.messages, &(&1[:id] || &1["id"]))
  end

  defp backups(key) do
    prefix = String.replace_suffix(key, "state.etf.zst", "backup/format3/")
    {:ok, objects} = S3.list_all(prefix)
    objects
  end

  test "migrates both legacy formats, preserves controls, backs up original bytes, and reruns" do
    for format <- [1, 2] do
      {key, original, bytes} = seed(format)
      assert {:ok, :migrated} = InternalSessionFormat3Cutover.migrate_session(key)
      migrated = read!(key)
      assert InternalSession.storage_format(migrated) == 3
      assert InternalSession.archived_through(migrated) == 6
      assert InternalSession.get(migrated, :archive_chunks) == []
      assert InternalSession.get(migrated, :runtime_epoch) == original.runtime_epoch
      assert InternalSession.work_index_token(migrated) == original.work_index_token
      assert full_ids(migrated) == Enum.to_list(1..8)

      assert Enum.map(InternalSession.get(migrated, :messages), & &1.id) == [7, 8]

      assert Enum.any?(backups(key), fn o ->
               {:ok, %{body: body}} = S3.get(o.key)
               body == bytes
             end)

      assert {:ok, :skipped} = InternalSessionFormat3Cutover.migrate_session(key)
      assert full_ids(read!(key)) == Enum.to_list(1..8)
    end
  end

  test "only the committed archive prefix is backed up, and redactions remain an overlay" do
    {key, state, _} = seed()

    {:ok, %{body: prefix}} =
      S3.get(Keys.agent_internal_runtime_session_archive(state.agent_id, state.session_id))

    archived = ArchiveLog.decode!(prefix)

    extra =
      state.messages
      |> Enum.take(2)
      |> Enum.map(&ArchiveLog.shape("message", &1.seq, &1))
      |> ArchiveLog.encode()

    archive_key = Keys.agent_internal_runtime_session_archive(state.agent_id, state.session_id)
    {:ok, _} = S3.put(archive_key, prefix <> extra)

    state = %{
      state
      | archived_through: 4,
        archive_chunks: ArchiveLog.spans(archived, 0),
        redactions: [%{"seq" => 1, "replacement" => "masked"}]
    }

    {:ok, _} = S3.put(key, Codec.encode_snapshot(state))
    assert {:ok, :migrated} = InternalSessionFormat3Cutover.migrate_session(key)
    archive_backup = Enum.find(backups(key), &String.ends_with?(&1.key, "archive.jsonl"))
    assert {:ok, %{body: ^prefix}} = S3.get(archive_backup.key)
    assert {:ok, %{body: source}} = S3.get(archive_key)
    assert source == prefix <> extra
    migrated = read!(key)

    {:ok, raw} = InternalSessionStore.archived_records(state.agent_id, migrated, mask: false)

    assert hd(raw).data["content"] == hd(archived).data["content"]
    assert InternalSession.get(migrated, :redactions) == state.redactions
  end

  test "a failed segment write leaves the legacy snapshot readable and resumes from landed segments" do
    {key, state, _} = seed()
    second_key = Keys.agent_internal_runtime_session_segment(state.agent_id, state.session_id, 3)
    S3.Fake.set_fault({:fail, 403, :put, second_key})
    assert {:error, _} = InternalSessionFormat3Cutover.migrate_session(key)
    assert InternalSession.storage_format(read!(key)) == 2
    assert full_ids(read!(key)) == Enum.to_list(1..8)
    assert {:ok, :migrated} = InternalSessionFormat3Cutover.migrate_session(key)
    assert full_ids(read!(key)) == Enum.to_list(1..8)
  end

  test "a live write winning the final CAS is retained on migration retry" do
    {key, state, _} = seed()

    task =
      Task.async(fn ->
        S3.Fake.set_fault_for(self(), {:pause, :put, key})
        InternalSessionFormat3Cutover.migrate_session(key)
      end)

    wait_paused(200)
    newer = state |> InternalSession.open() |> InternalSession.apply_events([delivery(9)])
    {:ok, _} = S3.put(key, Codec.compress_snapshot_etf(InternalSession.persist(newer)))
    :ok = S3.Fake.release_pause()
    assert {:ok, :migrated} = Task.await(task)
    assert full_ids(read!(key)) == Enum.to_list(1..9)
  end

  test "backup failure preserves the original snapshot and prevents a completion marker" do
    {key, _, bytes} = seed(1)
    prefix = String.replace_suffix(key, "state.etf.zst", "backup/format3/")
    S3.Fake.set_fault_for(self(), {:fail, 403, :put, {:prefix, prefix}})

    assert {:error, {:session_migration_failed, ^key, _}} =
             InternalSessionFormat3Cutover.run(dry_run: false)

    assert {:ok, %{body: ^bytes}} = S3.get(key)

    assert %{rows: []} =
             SalixStore.Repo.query!(
               "SELECT 1 FROM salix_cutover_markers WHERE name = 'internal_session_format3_v1'"
             )

    assert {:ok, :migrated} = InternalSessionFormat3Cutover.migrate_session(key)
  end

  test "a lost normalization CAS reply is settled without duplicating legacy history" do
    {key, _, _} = seed(1)
    S3.Fake.set_fault_for(self(), {:ambiguous_after, :put, key})
    assert {:ok, :migrated} = InternalSessionFormat3Cutover.migrate_session(key)
    assert full_ids(read!(key)) == Enum.to_list(1..8)
  end

  test "a missing source record fails before segment publication" do
    {key, state, _} = seed()
    broken = %{state | messages: Enum.reject(state.messages, &(&1.seq == 6))}
    bytes = Codec.encode_snapshot(broken)
    {:ok, _} = S3.put(key, bytes)
    assert {:error, _} = InternalSessionFormat3Cutover.migrate_session(key)
    assert {:ok, %{body: ^bytes}} = S3.get(key)

    assert {:error, :not_found} =
             S3.get(
               Keys.agent_internal_runtime_session_segment(state.agent_id, state.session_id, 1)
             )
  end

  test "dry run is read-only and the complete paginated run records drained verification" do
    {key, _, bytes} = seed()
    assert {:ok, %{legacy: 1, dry_run: true}} = InternalSessionFormat3Cutover.run(page_size: 1)
    assert {:ok, %{body: ^bytes}} = S3.get(key)
    assert backups(key) == []

    assert {:ok, %{verified: 1, dry_run: false}} =
             InternalSessionFormat3Cutover.run(dry_run: false, page_size: 1)

    assert %{rows: [[1]]} =
             SalixStore.Repo.query!(
               "SELECT 1 FROM salix_cutover_markers WHERE name = 'internal_session_format3_v1'"
             )
  end

  test "backup retention gates deletion and cleanup verifies the actual migrated history" do
    {key, _, _} = seed()
    assert {:ok, _} = InternalSessionFormat3Cutover.run(dry_run: false)
    age_completed_marker!()
    prune = SalixAgent.SessionFormat3BackupPrune
    assert {:error, :retention_window_open} = prune.run(dry_run: false)
    assert {:ok, %{verified: 2, deleted: 0}} = prune.run(retention_days: 0)
    assert length(backups(key)) == 2
    assert {:ok, %{deleted: 2}} = prune.run(retention_days: 0, dry_run: false)
    assert backups(key) == []
    assert full_ids(read!(key)) == Enum.to_list(1..8)
  end

  test "a missing migrated segment prevents deleting the recovery backup" do
    {key, state, _} = seed()
    assert {:ok, _} = InternalSessionFormat3Cutover.run(dry_run: false)

    age_completed_marker!()

    :ok =
      S3.delete(Keys.agent_internal_runtime_session_segment(state.agent_id, state.session_id, 1))

    assert {:error, {:backup_prune_failed, _, _}} =
             SalixAgent.SessionFormat3BackupPrune.run(retention_days: 0, dry_run: false)

    assert length(backups(key)) == 2
  end

  test "legacy normalization backups verify and interrupted archive deletion resumes" do
    {key, _, _} = seed(1)
    assert {:ok, _} = InternalSessionFormat3Cutover.run(dry_run: false)
    age_completed_marker!()
    prune = SalixAgent.SessionFormat3BackupPrune
    assert {:ok, %{verified: 4}} = prune.run(retention_days: 0)

    archive_key =
      backups(key) |> Enum.find(&String.ends_with?(&1.key, "archive.jsonl")) |> Map.fetch!(:key)

    S3.Fake.set_fault_for(self(), {:fail, 403, :delete, archive_key})
    assert {:error, {:backup_prune_failed, _, _}} = prune.run(retention_days: 0, dry_run: false)

    assert {:error, :not_found} =
             S3.get(String.replace_suffix(archive_key, "archive.jsonl", "state.etf.zst"))

    assert {:ok, _} = S3.get(archive_key)
    assert {:ok, %{deleted: 3}} = prune.run(retention_days: 0, dry_run: false)
    assert backups(key) == []
    assert full_ids(read!(key)) == Enum.to_list(1..8)
  end

  test "verification after an interrupted last conversion restarts the retention clock" do
    seed()
    assert {:ok, _} = InternalSessionFormat3Cutover.run(dry_run: false)

    SalixStore.Repo.query!(
      "UPDATE salix_cutover_markers SET completed_at = now() - interval '30 days' WHERE name = 'internal_session_format3_v1'"
    )

    {key, _, _} = seed()
    # Last session CAS lands, then the operator dies before verification.
    assert {:ok, :migrated} = InternalSessionFormat3Cutover.migrate_session(key)
    assert {:ok, %{migrated: 0}} = InternalSessionFormat3Cutover.run(dry_run: false)

    assert {:error, :retention_window_open} =
             SalixAgent.SessionFormat3BackupPrune.run(dry_run: false)
  end

  # PostgreSQL timestamp(0) can round a freshly completed marker forward by
  # a fraction of a second. Give zero-day cleanup fixtures a definite past.
  defp age_completed_marker! do
    SalixStore.Repo.query!(
      "UPDATE salix_cutover_markers SET completed_at = now() - interval '2 seconds' WHERE name = 'internal_session_format3_v1'"
    )
  end

  defp wait_paused(0), do: flunk("migration did not reach final CAS")

  defp wait_paused(n) do
    if S3.Fake.paused?(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_paused(n - 1)
        )
  end
end
