defmodule SalixAgent.InternalSessionFormatTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{
    InternalSession,
    InternalSessionActor,
    InternalSessionFormat3Cutover,
    InternalSessionStore
  }

  alias SalixAgent.InternalSession.State
  alias SalixStore.{ArchiveLog, Codec, Ids, Keys, S3}

  setup do
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    old = Application.get_env(:salix_store, :seal_line_bytes)
    Application.put_env(:salix_store, :seal_line_bytes, 1)

    on_exit(fn ->
      if old,
        do: Application.put_env(:salix_store, :seal_line_bytes, old),
        else: Application.delete_env(:salix_store, :seal_line_bytes)
    end)

    :ok
  end

  defp delivery(id),
    do: %{
      "type" => "delivery",
      "from_queue" => true,
      "message_id" => id,
      "role" => "user",
      "content" => "message #{id}",
      "source_message_id" => "source-#{id}",
      "created_at" => id
    }

  defp seed(format) do
    agent = "format-agent-#{System.unique_integer([:positive])}"
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

    archive_key = Keys.agent_internal_runtime_session_archive(agent, session)

    state =
      if format == 1 do
        %{
          state
          | messages: Enum.map(state.messages, &Map.delete(&1, :seq)),
            last_seq: 0,
            compacted_seq: 0
        }
      else
        records =
          state.messages |> Enum.take(4) |> Enum.map(&ArchiveLog.shape("message", &1.seq, &1))

        {:ok, _} = S3.put(archive_key, ArchiveLog.encode(records))

        %{
          state
          | archived_through: 4,
            archive_chunks: ArchiveLog.spans(records, 0),
            messages: Enum.drop(state.messages, 4)
        }
      end

    key = Keys.agent_internal_runtime_session(agent, session)
    {:ok, _} = S3.put(key, Codec.encode_snapshot(state))

    {:ok, _} =
      Registry.register(SalixAgent.Registry, InternalSessionActor.key(agent, session), nil)

    {key, archive_key, state}
  end

  defp ids(page), do: Enum.map(page.messages, &(&1[:id] || &1["id"]))

  # The persistable state the handle would write, as data.
  defp persisted(session),
    do:
      session
      |> InternalSession.persist()
      |> Codec.compress_snapshot_etf()
      |> Codec.decode_snapshot()

  test "the first business write to either legacy format publishes new hot without reading old archives" do
    for format <- [1, 2] do
      {key, archive_key, source} = seed(format)
      archive_puts = Enum.count(S3.Fake.put_log(), &(&1 == archive_key))
      S3.Fake.blackhole({:fail, 403, :get, archive_key})

      assert {:ok, next} =
               InternalSessionStore.commit(source.agent_id, source.session_id, [delivery(9)])

      assert InternalSession.storage_format(next) == 3
      assert {:ok, %{body: bytes}} = S3.get(key)

      assert {:comma_internal_session, 3, %State{storage_format: 3}} =
               Codec.decode_zstd_etf(bytes)

      assert Codec.decode_snapshot(bytes) == persisted(next)
      assert Enum.count(S3.Fake.put_log(), &(&1 == archive_key)) == archive_puts
      S3.Fake.clear_blackhole()
      assert {:ok, page} = InternalSessionStore.transcript(source.agent_id, next, :full)
      assert ids(page) == Enum.to_list(1..9)
      assert InternalSession.total_message_count(next) == 9
    end
  end

  test "old prefix and new segments share bounded paging and background rewrite preserves both" do
    {_key, archive_key, source} = seed(2)
    assert {:ok, %{body: original_archive}} = S3.get(archive_key)
    assert {:ok, next} = InternalSessionStore.commit(source.agent_id, source.session_id, [])

    assert {:ok, :archived} =
             InternalSessionStore.archive_compacted(source.agent_id, source.session_id, next)

    assert {:ok, mixed} = InternalSessionStore.read(source.agent_id, source.session_id)
    assert InternalSession.get(mixed, :archive_chunks) == source.archive_chunks
    assert Enum.map(InternalSession.get(mixed, :segment_catalog), &hd/1) == [5, 6]
    assert InternalSession.archived_through(mixed) == 6
    assert {:ok, page} = InternalSessionStore.transcript(source.agent_id, mixed, {:before, 7, 5})
    assert ids(page) == [2, 3, 4, 5, 6]
    assert InternalSession.total_message_count(mixed) == 8
    key = Keys.agent_internal_runtime_session(source.agent_id, source.session_id)
    assert {:ok, :migrated} = InternalSessionFormat3Cutover.migrate_session(key)
    assert {:ok, converted} = InternalSessionStore.read(source.agent_id, source.session_id)
    assert InternalSession.get(converted, :archive_chunks) == []
    assert Enum.map(InternalSession.get(converted, :segment_catalog), &hd/1) == Enum.to_list(1..6)
    assert {:ok, page} = InternalSessionStore.transcript(source.agent_id, converted, :full)
    assert ids(page) == Enum.to_list(1..8)
    assert {:ok, %{body: ^original_archive}} = S3.get(archive_key)
  end

  test "a delayed legacy chunks advance cannot replace the frozen prefix or drop hot records" do
    {_key, _, source} = seed(2)
    assert {:ok, next} = InternalSessionStore.commit(source.agent_id, source.session_id, [])

    late = %{
      "type" => "archive_advance",
      "session_id" => source.session_id,
      "archived_through" => 6,
      "chunks" => []
    }

    assert {:ok, after_late} =
             InternalSessionStore.commit(source.agent_id, source.session_id, [late])

    assert InternalSession.archived_through(after_late) == InternalSession.archived_through(next)

    assert InternalSession.get(after_late, :archive_chunks) ==
             InternalSession.get(next, :archive_chunks)

    assert InternalSession.get(after_late, :messages) == InternalSession.get(next, :messages)
  end

  test "a seal captured before prefix backfill retains the newly converted prefix on commit" do
    {key, _, source} = seed(2)
    assert {:ok, mixed} = InternalSessionStore.commit(source.agent_id, source.session_id, [])

    entries =
      InternalSession.get(mixed, :messages)
      |> Enum.take(2)
      |> Enum.map(fn message ->
        record = ArchiveLog.shape("message", message.seq, message)

        {:ok, _} =
          S3.put(
            Keys.agent_internal_runtime_session_segment(
              source.agent_id,
              source.session_id,
              message.seq
            ),
            SalixStore.SealedSegments.encode([record])
          )

        SalixStore.SealedSegments.entry_for([record])
      end)

    late = %{
      "type" => "archive_advance",
      "session_id" => source.session_id,
      "archived_through" => 6,
      "segments" => entries
    }

    assert {:ok, :migrated} = InternalSessionFormat3Cutover.migrate_session(key)
    assert {:ok, final} = InternalSessionStore.commit(source.agent_id, source.session_id, [late])
    assert InternalSession.get(final, :archive_chunks) == []
    assert Enum.map(InternalSession.get(final, :segment_catalog), &hd/1) == Enum.to_list(1..6)
    assert {:ok, page} = InternalSessionStore.transcript(source.agent_id, final, :full)
    assert ids(page) == Enum.to_list(1..8)
  end

  test "the new envelope refuses the previous reader and invalidates its captured CAS" do
    {key, _, source} = seed(2)
    {:ok, %{etag: old_etag}} = S3.get(key)

    assert {:ok, _} =
             InternalSessionStore.commit(source.agent_id, source.session_id, [delivery(9)])

    {:ok, %{body: bytes}} = S3.get(key)
    # This is the previous Codec's exact zstd decode result; its store only
    # accepts %State{}, so it cannot discard an unknown mixed-layout prefix.
    refute match?(%State{}, Codec.decode_zstd_etf(bytes))

    assert {:error, :precondition_failed} =
             S3.put(key, Codec.encode_snapshot(source), if_match: old_etag)

    assert {:ok, %{body: ^bytes}} = S3.get(key)
    {:ok, _} = S3.put(key, Codec.encode_zstd_etf({:comma_internal_session, 99, source}))

    assert {:error, :invalid_session_snapshot} =
             InternalSessionStore.read(source.agent_id, source.session_id)
  end

  test "a captured legacy Revision must reload after another write fixes its coordinates" do
    {_key, _, source} = seed(1)

    assert {:ok, revision} =
             InternalSessionStore.read_revision(source.agent_id, source.session_id)

    assert {:ok, _} =
             InternalSessionStore.commit(source.agent_id, source.session_id, [delivery(9)])

    assert {:error, :stale_internal_session} =
             InternalSessionStore.commit_revision(
               source.agent_id,
               source.session_id,
               revision,
               [delivery(10)]
             )

    assert {:ok, current} = InternalSessionStore.read(source.agent_id, source.session_id)
    assert {:ok, page} = InternalSessionStore.transcript(source.agent_id, current, :full)
    assert ids(page) == Enum.to_list(1..9)
  end

  test "seed and retained legacy-fork entrypoints also publish only the new hot format" do
    {_key, _, source} = seed(1)
    child_id = Ids.new_session_id()
    assert {:ok, child} = InternalSession.fork(InternalSession.open(source), child_id, %{})
    assert :ok = InternalSessionStore.prepare_seed(source.agent_id, child)
    {:ok, %{body: bytes}} = S3.get(Keys.agent_internal_runtime_session(source.agent_id, child_id))
    assert {:comma_internal_session, 3, %State{storage_format: 3}} = Codec.decode_zstd_etf(bytes)
    import_id = Ids.new_session_id()

    assert :ok =
             InternalSessionStore.prepare_seed(
               source.agent_id,
               InternalSession.open(%{source | session_id: import_id})
             )

    {:ok, %{body: bytes}} =
      S3.get(Keys.agent_internal_runtime_session(source.agent_id, import_id))

    assert {:comma_internal_session, 3, %State{storage_format: 3}} = Codec.decode_zstd_etf(bytes)
  end
end
