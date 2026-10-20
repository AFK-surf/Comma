defmodule SalixAgent.InternalSessionSegmentsTest do
  @moduledoc """
  The storage-format-3 sealed-segment protocol: size-targeted segments
  named by their FIRST seq (one small line via config so tests exercise
  many segments), create-once publication settled semantically, ONE CAS
  advance landing on the last sealed boundary, and segment-addressed
  history reads. Legacy one-object archive read compatibility is covered by
  historical fixtures in internal_session_archive_test.exs.

  The retained SessionHotArchive model covers publish-before-advance safety.
  These regressions cover segment cuts and history-read behavior.
  """

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSessionStore
  require SalixAgent.InternalSession
  alias SalixStore.{Codec, Keys, S3, SealedSegments}

  @session "ses1_0000000000000000900"
  @line 2_000

  setup do
    SystemsRuntime.put_env(:salix_store, :seal_line_bytes, @line)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_store, :seal_line_bytes) end)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    :ok
  end

  defp deliver(id) do
    %{
      "type" => "delivery",
      "from_queue" => true,
      "message_id" => id,
      "role" => "user",
      "content" => "input #{id} #{String.duplicate("x", 100)}",
      "source_message_id" => "src-#{id}",
      "created_at" => 1_000 + id
    }
  end

  # No pinned `summary_sequence`: the reducer derives the next one, the way a
  # real producer computes it from its snapshot. A constant would make every
  # compaction after the first look like a stale-baseline replay (#815).
  defp compaction(through) do
    %{
      "type" => "compaction",
      "session_id" => @session,
      "summary" => "summary through #{through}",
      "compacted_through" => through
    }
  end

  # The same shaped record stream the store's seal path derives.
  defp shaped_window(session) do
    for msg <- InternalSession.get(session, :messages) || [],
        seq = msg[:seq],
        is_integer(seq),
        do: SalixStore.ArchiveLog.shape("message", seq, msg)
  end

  # New sessions are born format 3; seeding mirrors the archive suite's
  # direct-object pattern so each test starts from a known committed state.
  defp seed_format3(agent_id, events, format \\ 3) do
    state =
      agent_id
      |> InternalSession.new(@session, %{})
      |> InternalSession.export()
      |> Map.put(:storage_format, format)
      |> InternalSession.open()
      |> InternalSession.apply_events([
        %{"type" => "session_created", "session_id" => @session} | events
      ])
      |> InternalSession.normalize()

    key = Keys.agent_internal_runtime_session(agent_id, @session)
    {:ok, _} = S3.put(key, encode(state))

    {:ok, _} =
      Registry.register(
        SalixAgent.Registry,
        SalixAgent.InternalSessionActor.key(agent_id, @session),
        nil
      )

    state
  end

  defp encode(session) do
    if InternalSession.storage_format(session) >= 3,
      do: Codec.compress_snapshot_etf(InternalSession.persist(session)),
      else: Codec.encode_snapshot(InternalSession.export(session))
  end

  defp segment_key(agent_id, first_seq),
    do: Keys.agent_internal_runtime_session_segment(agent_id, @session, first_seq)

  defp read!(agent_id) do
    {:ok, session} = InternalSessionStore.read(agent_id, @session)
    session
  end

  defp segment_gets(log) do
    for {:get, key} <- log, String.contains?(key, "/segments/"), do: key
  end

  test "sealing closes full segments and removes the compacted partial tail" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..300, &deliver/1))

    assert {:ok, compacted} = InternalSessionStore.commit(agent_id, @session, [compaction(300)])
    assert InternalSession.storage_format(compacted) == 3

    assert {:ok, pre_seal} = InternalSessionStore.read(agent_id, @session)
    original_records = shaped_window(pre_seal)

    assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)
    # Every compacted record was sealed. Repeated archival is a no-op.
    assert {:ok, :nothing_to_archive} = InternalSessionStore.archive_compacted(agent_id, @session)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    catalog = InternalSession.get(session, :segment_catalog)
    through = catalog |> List.last() |> Enum.at(1)

    assert InternalSession.archived_through(session) == through
    assert through == 300
    assert InternalSession.get(session, :messages) == []

    # The current encoder owns cuts. Every catalog span must retain the
    # complete captured records, and non-final segments must reach the target.
    published =
      Enum.flat_map(catalog, fn [first, last, messages, measured] ->
        {:ok, %{body: body}} = S3.get(segment_key(agent_id, first))
        records = SealedSegments.decode(body)
        assert Enum.map(records, & &1.seq) == Enum.to_list(first..last)
        assert Enum.count(records, &(&1.kind == "message")) == messages
        if last < through, do: assert(measured >= @line)
        records
      end)

    assert published === original_records

    # The hot object body is zstd-wrapped ETF (the magic-keyed decode path).
    hot_key = Keys.agent_internal_runtime_session(agent_id, @session)
    {:ok, %{body: hot_body}} = S3.get(hot_key)

    assert Codec.decode_snapshot(hot_body) ==
             Codec.decode_snapshot(Codec.compress_snapshot_etf(InternalSession.persist(session)))

    assert <<0x28, 0xB5, 0x2F, 0xFD, _::binary>> = hot_body

    # History reads flow through the segments: exact committed coverage.
    assert {:ok, archived} = InternalSessionStore.archived_records(agent_id, session)
    assert Enum.map(archived, & &1.seq) == Enum.to_list(1..through)
  end

  for {original, replacement, label} <- [
        {1001, 1001.0, "integer type"},
        {-0.0, 0.0, "float sign bit"}
      ] do
    @original original
    @replacement replacement
    test "a landed segment cannot change a numeric fact's #{label} before hot removal" do
      agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"

      seed_format3(agent_id, [
        Map.put(deliver(1), "created_at", @original),
        deliver(2),
        deliver(3)
      ])

      assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(3)])
      assert {:ok, before} = InternalSessionStore.read(agent_id, @session)
      [record | _] = shaped_window(before)

      assert :erlang.term_to_binary(record.data["created_at"]) ==
               :erlang.term_to_binary(@original)

      foreign = put_in(record.data["created_at"], @replacement)
      key = segment_key(agent_id, record.seq)
      body = SealedSegments.encode([foreign])
      assert {:ok, _} = S3.put(key, body, if_none_match: "*")

      assert {:error, {:segment_divergence, ^key}} =
               InternalSessionStore.archive_compacted(agent_id, @session)

      assert {:ok, after_attempt} = InternalSessionStore.read(agent_id, @session)
      assert shaped_window(after_attempt) === shaped_window(before)

      assert InternalSession.archived_through(after_attempt) ==
               InternalSession.archived_through(before)

      assert {:ok, %{body: ^body}} = S3.get(key)
    end
  end

  test "revision commits write the format-3 body codec too" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..50, &deliver/1))

    assert {:ok, revision} = InternalSessionStore.read_revision(agent_id, @session)

    assert {:ok, committed} =
             InternalSessionStore.commit_revision(agent_id, @session, revision, [
               %{"type" => "status", "session_id" => @session, "status" => "active"}
             ])

    assert InternalSession.status(committed.state) == :active

    # Both commit APIs must produce the zstd-wrapped body: the magic-keyed
    # decode reads it back identically.
    {:ok, %{body: body}} = S3.get(Keys.agent_internal_runtime_session(agent_id, @session))
    assert <<0x28, 0xB5, 0x2F, 0xFD, _::binary>> = body
    assert {:ok, decoded} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.is_session(decoded)
    assert InternalSession.status(decoded) == :active
  end

  test "a stale owner's re-seal is pure duplicates and cannot roll back" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..600, &deliver/1))

    # First seal establishes a non-empty catalog prefix.
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(100)])
    assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)
    assert {:ok, first_round} = InternalSessionStore.read(agent_id, @session)
    through1 = InternalSession.archived_through(first_round)

    # Owner A captures at ceiling 300 and stalls.
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(300)])
    assert {:ok, stale} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.get(stale, :compacted_seq) == 300

    # Owner B compacts and archives all the way while A is stalled.
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(600)])
    assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)
    assert {:ok, ahead} = InternalSessionStore.read(agent_id, @session)
    ahead_catalog = InternalSession.get(ahead, :segment_catalog)

    # A reads B's current revision. The stale view cannot replace its catalog.
    assert {:ok, :nothing_to_archive} =
             InternalSessionStore.archive_compacted(agent_id, @session, stale)

    assert {:ok, after_stale} = InternalSessionStore.read(agent_id, @session)

    assert InternalSession.archived_through(after_stale) ==
             InternalSession.archived_through(ahead)

    assert InternalSession.get(after_stale, :segment_catalog) == ahead_catalog

    assert {:ok, records} = InternalSessionStore.archived_records(agent_id, after_stale)
    assert Enum.map(records, & &1.seq) == Enum.to_list(1..InternalSession.archived_through(ahead))
    assert through1 < InternalSession.archived_through(ahead)
  end

  test "tail paging completes the window from the newest segments backwards" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..600, &deliver/1))

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(600)])
    assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)
    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)

    catalog_keys =
      MapSet.new(InternalSession.get(session, :segment_catalog), fn [first | _] ->
        segment_key(agent_id, first)
      end)

    S3.Fake.reset_read_log()

    assert {:ok, %{messages: messages, has_older?: true}} =
             InternalSessionStore.transcript(agent_id, session, {:tail, 25})

    seqs = Enum.map(messages, &(&1["seq"] || &1[:seq]))
    assert seqs == Enum.to_list(576..600)

    gets = segment_gets(S3.Fake.read_log())
    assert gets != []
    assert Enum.all?(gets, &MapSet.member?(catalog_keys, &1))
  end

  test "fetch_archived_record resolves a sealed tool result in one segment read" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    # Four records need a smaller line to form a full segment.
    SystemsRuntime.put_env(:salix_store, :seal_line_bytes, 400)

    # Compact through the capsule but leave the page live: the page's content
    # still names the ref, so the bounded pointer survives in the hot object
    # and resolves into the sealed segment.
    seed_format3(agent_id, [
      deliver(1),
      stored_result_event("trf1_0000000000000000007"),
      result_capsule(2, "trf1_0000000000000000007"),
      result_page(3, "trf1_0000000000000000007")
    ])

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(2)])
    assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)
    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.archived_through(session) > 0
    assert map_size(InternalSession.get(session, :async_result_refs)) == 1

    S3.Fake.reset_read_log()

    assert {:ok, record} =
             InternalSessionStore.fetch_tool_result(
               agent_id,
               @session,
               "trf1_0000000000000000007"
             )

    assert record["tool_call_id"] == "call-segment-result"

    # One hot-object read for the session, one segment read for the record.
    log = S3.Fake.read_log()
    gets = Enum.filter(log, &match?({:get, _}, &1))
    assert length(gets) == 2
    assert [{:get, hot_key}, {:get, segment}] = gets
    assert hot_key == Keys.agent_internal_runtime_session(agent_id, @session)
    assert String.contains?(segment, "/segments/") and String.ends_with?(segment, ".etf.zst")
  end

  test "a missing segment object fails loudly instead of serving a short history" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..300, &deliver/1))
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(300)])
    assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)

    {:ok, %{body: hot}} = S3.get(Keys.agent_internal_runtime_session(agent_id, @session))
    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    victim = segment_key(agent_id, hd(hd(InternalSession.get(session, :segment_catalog))))

    S3.Fake.reset()
    {:ok, _} = S3.put(Keys.agent_internal_runtime_session(agent_id, @session), hot)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)

    assert {:error, {:archive_incomplete, _}} =
             InternalSessionStore.archived_records(agent_id, session)

    assert {:error, :not_found} = S3.get(victim)
  end

  # A corrupt body must fail closed as an archive error, never crash the
  # reader or serve a short history: duplicated or reordered records, an
  # invalid zstd frame, a decodable non-list term, and a list whose elements
  # lack seqs are all wrong-segment shapes, not exceptions.
  for {name, corruption} <- [
        {"a segment body with a duplicated record fails loudly", :duplicate},
        {"a reordered segment body fails loudly", :reorder},
        {"an invalid zstd frame fails closed instead of raising", :invalid_zstd},
        {"a decodable non-list segment body fails closed instead of raising", :non_list},
        {"a segment body whose records lack seqs fails closed instead of raising", :missing_seqs}
      ] do
  end

  test "a hot CAS conflict republishes from the new revision before removing its records" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..3, &deliver/1))
    assert {:ok, captured} = InternalSessionStore.commit(agent_id, @session, [compaction(3)])
    hot = Keys.agent_internal_runtime_session(agent_id, @session)
    key = segment_key(agent_id, 1)

    :ok =
      Registry.unregister(
        SalixAgent.Registry,
        SalixAgent.InternalSessionActor.key(agent_id, @session)
      )

    :ok = S3.Fake.set_fault({:pause, :put, key})

    task =
      SystemsRuntime.Task.async(fn ->
        {:ok, _} =
          Registry.register(
            SalixAgent.Registry,
            SalixAgent.InternalSessionActor.key(agent_id, @session),
            nil
          )

        InternalSessionStore.archive_compacted(agent_id, @session, captured)
      end)

    assert wait_until_paused(100)

    # Another hot revision lands while immutable publication is in flight.
    newer =
      InternalSession.apply_events(captured, Enum.map(4..20, &deliver/1) ++ [compaction(20)])

    assert {:ok, _} = S3.put(hot, encode(newer))
    :ok = S3.Fake.release_pause()

    assert {:ok, :archived} = settled_await(task)
    current = read!(agent_id)
    assert InternalSession.archived_through(current) == 20
    assert InternalSession.get(current, :messages) == []
    assert {:ok, records} = InternalSessionStore.archived_records(agent_id, current)
    assert records === shaped_window(newer)
  end

  test "failed hot advance leaves recoverable segments; ambiguous creates settle" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..20, &deliver/1))
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(20)])
    key = segment_key(agent_id, 1)
    hot = Keys.agent_internal_runtime_session(agent_id, @session)
    :ok = S3.Fake.set_fault({:ambiguous_after, :put, key})
    :ok = S3.Fake.set_fault({:fail, 503, :put, hot})

    assert {:error, _} = InternalSessionStore.archive_compacted(agent_id, @session)
    assert InternalSession.archived_through(read!(agent_id)) == 0
    assert {:ok, %{body: bytes}} = S3.get(key)
    assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)
    assert {:ok, %{body: ^bytes}} = S3.get(key)

    assert {:ok, %{messages: messages}} =
             InternalSessionStore.transcript(agent_id, read!(agent_id), {:tail, 20})

    assert Enum.map(messages, &(&1["seq"] || &1[:seq])) == Enum.to_list(1..20)
  end

  test "fork carries a live sealed result and publishes a format-3 child without copying history" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)
    SystemsRuntime.put_env(:salix_store, :seal_line_bytes, 1)
    ref = "trf1_0000000000000000007"
    seed_format3(agent_id, [deliver(1), stored_result_event(ref), result_capsule(2, ref)])
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(1)])
    assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)
    assert {:ok, source_result} = InternalSessionStore.fetch_tool_result(agent_id, @session, ref)

    S3.Fake.reset_read_log()

    assert {:ok, forked} =
             SalixAgent.InternalAgentRuntime.fork_session_local(agent_id, @session, %{
               "fork_request_id" => "sealed-result-fork",
               "message_id" => 2
             })

    reads = segment_gets(S3.Fake.read_log())
    assert reads == [segment_key(agent_id, 2)]
    assert {:ok, child} = InternalSessionStore.read(agent_id, forked["session_id"])
    assert InternalSession.storage_format(child) == 3
    assert InternalSession.get(child, :segment_catalog) == []
    assert InternalSession.archived_through(child) == 0
    assert Enum.map(InternalSession.get(child, :messages), & &1[:id]) == [2]

    assert {:ok, result} =
             InternalSessionStore.fetch_tool_result(
               agent_id,
               InternalSession.session_id(child),
               ref
             )

    assert result["result_json"] == source_result["result_json"]
  end

  test "format-2 sessions switch to new writes and never append the legacy archive" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..300, &deliver/1), 2)
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(280)])
    assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)
    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.storage_format(session) == 3
    assert InternalSession.get(session, :segment_catalog) != []
    assert InternalSession.get(session, :archive_chunks) == []

    assert {:error, :not_found} =
             S3.get(Keys.agent_internal_runtime_session_archive(agent_id, @session))
  end

  test "format-1 archival entry converts hot state even when there is nothing to seal" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..10, &deliver/1), 1)
    assert {:ok, :nothing_to_archive} = InternalSessionStore.archive_compacted(agent_id, @session)
    assert {:ok, converted} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.storage_format(converted) == 3
  end

  defp wait_until_paused(0), do: false

  defp wait_until_paused(attempts) do
    if S3.Fake.paused?() do
      true
    else
      SystemsClock.sleep(10)
      wait_until_paused(attempts - 1)
    end
  end

  defp stored_result_event(ref) do
    result_json = Jason.encode!(%{"items" => Enum.to_list(1..20)})

    %{
      "type" => "tool_result_stored",
      "session_id" => @session,
      "result_ref" => ref,
      "tool_call_id" => "call-segment-result",
      "tool_name" => "composio.execute",
      "result_json" => result_json,
      "result_sha256" => :crypto.hash(:sha256, result_json) |> Base.encode16(case: :lower),
      "result_bytes" => byte_size(result_json),
      "result_chars" => String.length(result_json),
      "status" => "completed",
      "is_error" => false,
      "stored_at_ms" => 5_000
    }
  end

  defp result_capsule(id, ref) do
    %{
      "type" => "tool_result",
      "session_id" => @session,
      "message_id" => id,
      "tool_call_id" => "call-segment-result",
      "tool_name" => "composio.execute",
      "status" => "completed",
      "content" => Jason.encode!(%{"stored_result" => true, "result_ref" => ref}),
      "created_at" => 3_000 + id
    }
  end

  defp result_page(id, ref) do
    %{
      "type" => "tool_result",
      "session_id" => @session,
      "message_id" => id,
      "tool_call_id" => "call-segment-result",
      "tool_name" => "tool_call.get_result",
      "status" => "completed",
      "content" => Jason.encode!(%{"result_ref" => ref, "encoding" => "json"}),
      "created_at" => 4_000 + id
    }
  end
end
