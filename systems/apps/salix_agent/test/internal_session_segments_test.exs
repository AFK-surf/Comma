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

  use ExUnit.Case, async: false

  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSessionStore
  require SalixAgent.InternalSession
  alias SalixStore.{Codec, Keys, S3, SealedSegments}

  @session "ses1_0000000000000000900"
  @line 2_000

  setup do
    Application.put_env(:salix_store, :seal_line_bytes, @line)
    on_exit(fn -> Application.delete_env(:salix_store, :seal_line_bytes) end)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
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

  defp expected_segments(session, ceiling) do
    session
    |> shaped_window()
    |> Enum.take_while(&(&1.seq <= ceiling))
    |> SealedSegments.sealable(@line)
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

  # Seals for real, then rewrites the FIRST segment's body through the
  # mutator — the corrupted-body shape a partial write or bad writer would
  # leave behind while the catalog still addresses the original span.
  # Returns the seq of the second record inside that segment (the interior
  # seq a gap removes).
  # Seeds 300 records, compacts, and seals for real; returns the first
  # catalog entry's key and body so tests can corrupt that segment in place.
  defp sealed_first_segment(agent_id) do
    seed_format3(agent_id, Enum.map(1..300, &deliver/1))
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(300)])
    assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)

    {:ok, session} = InternalSessionStore.read(agent_id, @session)
    first = hd(hd(InternalSession.get(session, :segment_catalog)))
    key = segment_key(agent_id, first)

    {:ok, %{body: body}} = S3.get(key)
    {key, body}
  end

  defp corrupt_first_segment(agent_id, mutator) do
    {key, body} = sealed_first_segment(agent_id)
    records = SealedSegments.decode(body)
    {:ok, _} = S3.put(key, SealedSegments.encode(mutator.(records)))

    {agent_id, hd(records).seq + 1}
  end

  defp replace_first_segment_body(agent_id, body) do
    {key, _} = sealed_first_segment(agent_id)
    {:ok, _} = S3.put(key, body)
    :ok
  end

  defp read!(agent_id) do
    {:ok, session} = InternalSessionStore.read(agent_id, @session)
    session
  end

  defp segment_gets(log) do
    for {:get, key} <- log, String.contains?(key, "/segments/"), do: key
  end

  test "sealing closes full segments and removes the compacted partial tail" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
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

  test "a landed segment whose advance was lost is adopted by DECODED records, never divergence" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..300, &deliver/1))
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(300)])
    assert {:ok, crashed} = InternalSessionStore.read(agent_id, @session)

    # Crash simulation with a cross-version transport: the landed segment
    # body was produced by the one-shot call at a different zstd level —
    # same records, different bytes. A byte-based settle would wedge as
    # permanent divergence; the semantic settle must adopt it.
    [first_segment | _] = expected_segments(crashed, 300)

    landed =
      :zstd.compress(
        :erlang.term_to_binary(first_segment.records, minor_version: 1),
        %{compressionLevel: 9}
      )
      |> IO.iodata_to_binary()

    {:ok, _} =
      S3.put(segment_key(agent_id, first_segment.first_seq), landed, if_none_match: "*")

    assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)

    assert {:ok, adopted} = InternalSessionStore.read(agent_id, @session)

    assert InternalSession.archived_through(adopted) ==
             List.last(expected_segments(crashed, 300)).last_seq

    # The landed transport is left exactly as it was — adopted, not rewritten.
    assert {:ok, %{body: ^landed}} = S3.get(segment_key(agent_id, first_segment.first_seq))

    assert {:ok, records} = InternalSessionStore.archived_records(agent_id, adopted)

    assert Enum.map(records, & &1.seq) ==
             Enum.to_list(1..InternalSession.archived_through(adopted))
  end

  for {original, replacement, label} <- [
        {1001, 1001.0, "integer type"},
        {-0.0, 0.0, "float sign bit"}
      ] do
    @original original
    @replacement replacement
    test "a landed segment cannot change a numeric fact's #{label} before hot removal" do
      agent_id = "agent-#{System.unique_integer([:positive])}"

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

  test "a landed boundary that differs from our own fill is adopted, never re-cut" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..300, &deliver/1))

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(300)])
    assert {:ok, pre_seal} = InternalSessionStore.read(agent_id, @session)
    shaped = shaped_window(pre_seal)

    # A writer with a DIFFERENT seal line (or size measurement) sealed
    # [1..3] and crashed before the advance. Our own fill from the same
    # window would cut a much larger first segment — the landed object is
    # the authority on its own boundary, so the walk must adopt it and
    # continue from seq 4 instead of erroring (or re-cutting).
    landed_records = Enum.take(shaped, 3)
    landed = SealedSegments.encode(landed_records)
    {:ok, _} = S3.put(segment_key(agent_id, 1), landed, if_none_match: "*")

    assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    first_entry = hd(InternalSession.get(session, :segment_catalog))
    assert [1, 3, 3, _measured] = first_entry

    # The tiling continues exactly at the adopted boundary.
    assert hd(tl(InternalSession.get(session, :segment_catalog))) |> hd() == 4

    # The landed transport is untouched.
    assert {:ok, %{body: ^landed}} = S3.get(segment_key(agent_id, 1))

    assert {:ok, records} = InternalSessionStore.archived_records(agent_id, session)

    assert Enum.map(records, & &1.seq) ==
             Enum.to_list(1..InternalSession.archived_through(session))
  end

  test "a lost create race adopts the winner's LONGER boundary, not our proposal" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..300, &deliver/1))

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(300)])
    assert {:ok, pre_seal} = InternalSessionStore.read(agent_id, @session)
    shaped = shaped_window(pre_seal)

    # Pause the actual conditional create after its GET observed absence.
    # Another writer wins that name with a longer boundary while it waits.
    ours = SealedSegments.next_segment(shaped, @line)
    winner_records = Enum.take(shaped, length(ours.records) + 4)
    winner = SealedSegments.encode(winner_records)
    key = segment_key(agent_id, 1)

    :ok =
      Registry.unregister(
        SalixAgent.Registry,
        SalixAgent.InternalSessionActor.key(agent_id, @session)
      )

    :ok = S3.Fake.set_fault({:pause, :put, key})

    task =
      Task.async(fn ->
        {:ok, _} =
          Registry.register(
            SalixAgent.Registry,
            SalixAgent.InternalSessionActor.key(agent_id, @session),
            nil
          )

        InternalSessionStore.archive_compacted(agent_id, @session, pre_seal)
      end)

    assert wait_until_paused(100)
    assert {:ok, _} = S3.put(key, winner, if_none_match: "*")
    :ok = S3.Fake.release_pause()
    assert {:ok, :archived} = Task.await(task, 5_000)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    winner_last = List.last(winner_records).seq
    first_entry = hd(InternalSession.get(session, :segment_catalog))
    assert Enum.at(first_entry, 1) == winner_last
    assert hd(tl(InternalSession.get(session, :segment_catalog))) |> hd() == winner_last + 1
    assert {:ok, %{body: ^winner}} = S3.get(segment_key(agent_id, 1))

    assert {:ok, records} = InternalSessionStore.archived_records(agent_id, session)

    assert Enum.map(records, & &1.seq) ==
             Enum.to_list(1..InternalSession.archived_through(session))
  end

  test "revision commits write the format-3 body codec too" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
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
    agent_id = "agent-#{System.unique_integer([:positive])}"
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

  test "incremental seals extend the catalog at fill boundaries without rewriting" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..600, &deliver/1))

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(200)])
    assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)
    assert {:ok, round1} = InternalSessionStore.read(agent_id, @session)

    first_key = segment_key(agent_id, hd(InternalSession.get(round1, :segment_catalog)) |> hd())
    {:ok, %{body: first_body}} = S3.get(first_key)
    prefix = InternalSession.get(round1, :segment_catalog)

    for through <- [400, 600] do
      assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(through)])
      assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)
    end

    assert {:ok, final} = InternalSessionStore.read(agent_id, @session)
    # The catalog only ever GROWS at the tail: earlier entries are stable.
    assert Enum.take(InternalSession.get(final, :segment_catalog), length(prefix)) == prefix
    assert length(InternalSession.get(final, :segment_catalog)) > length(prefix)

    # Sealed bytes are immutable.
    assert {:ok, %{body: ^first_body}} = S3.get(first_key)
  end

  test "paging reads only catalog segments, never a LIST" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..600, &deliver/1))

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(600)])
    assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)
    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)

    catalog_keys =
      MapSet.new(InternalSession.get(session, :segment_catalog), fn [first | _] ->
        segment_key(agent_id, first)
      end)

    S3.Fake.reset_read_log()

    assert {:ok, %{messages: messages}} =
             InternalSessionStore.transcript(agent_id, session, {:before, 350, 10})

    assert Enum.map(messages, & &1["seq"]) == Enum.to_list(340..349)

    log = S3.Fake.read_log()
    gets = segment_gets(log)
    # Every segment read is a catalog segment and at least one page-worth
    # was served from them; zero LIST anywhere.
    assert gets != []
    assert Enum.all?(gets, &MapSet.member?(catalog_keys, &1))
    assert Enum.empty?(Enum.filter(log, &match?({:list, _, _}, &1)))
  end

  test "tail paging completes the window from the newest segments backwards" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
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
    agent_id = "agent-#{System.unique_integer([:positive])}"
    # Four records need a smaller line to form a full segment.
    Application.put_env(:salix_store, :seal_line_bytes, 400)

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
    agent_id = "agent-#{System.unique_integer([:positive])}"
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

  # A body holding records 1 and 3 still matches {min, max} = {1, 3}: the
  # ordered seq LIST must be compared, or the interior gap surfaces later as
  # a false :not_found for the missing seq instead of a loud failure.
  test "a segment body with an interior gap fails loudly instead of a false not_found" do
    agent_id = "agent-#{System.unique_integer([:positive])}"

    {agent_id, gap_seq} =
      corrupt_first_segment(agent_id, fn records -> List.delete_at(records, 1) end)

    assert {:error, {:archive_incomplete, _}} =
             InternalSessionStore.fetch_archived_record(
               agent_id,
               @session,
               read!(agent_id),
               gap_seq
             )

    assert {:error, {:archive_incomplete, _}} =
             InternalSessionStore.archived_records(agent_id, read!(agent_id))
  end

  test "a segment body with a duplicated record fails loudly" do
    agent_id = "agent-#{System.unique_integer([:positive])}"

    {agent_id, _} =
      corrupt_first_segment(agent_id, fn [first | rest] -> [first, first | rest] end)

    assert {:error, {:archive_incomplete, _}} =
             InternalSessionStore.archived_records(agent_id, read!(agent_id))
  end

  test "a reordered segment body fails loudly" do
    agent_id = "agent-#{System.unique_integer([:positive])}"

    {agent_id, _} =
      corrupt_first_segment(agent_id, fn [a, b | rest] -> [b, a | rest] end)

    assert {:error, {:archive_incomplete, _}} =
             InternalSessionStore.archived_records(agent_id, read!(agent_id))
  end

  # A corrupt body must fail closed as an archive error, never crash the
  # reader: invalid zstd frame, a decodable non-list term, and a list whose
  # elements lack seqs are all wrong-segment shapes, not exceptions.
  test "an invalid zstd frame fails closed instead of raising" do
    agent_id = "agent-#{System.unique_integer([:positive])}"

    replace_first_segment_body(agent_id, <<1, 2, 3, "not a zstd frame">>)

    assert {:error, {:archive_incomplete, _}} =
             InternalSessionStore.archived_records(agent_id, read!(agent_id))
  end

  test "a decodable non-list segment body fails closed instead of raising" do
    agent_id = "agent-#{System.unique_integer([:positive])}"

    replace_first_segment_body(agent_id, SealedSegments.encode(%{"not" => "a list"}))

    assert {:error, {:archive_incomplete, _}} =
             InternalSessionStore.archived_records(agent_id, read!(agent_id))
  end

  test "a segment body whose records lack seqs fails closed instead of raising" do
    agent_id = "agent-#{System.unique_integer([:positive])}"

    replace_first_segment_body(agent_id, SealedSegments.encode([%{seq: 1}, %{no_seq: true}, 3]))

    assert {:error, {:archive_incomplete, _}} =
             InternalSessionStore.archived_records(agent_id, read!(agent_id))
  end

  @tag :redo_regression
  test "a seq-only record cannot silently disappear from transcript paging" do
    agent_id = "agent-#{System.unique_integer([:positive])}"

    {agent_id, _} =
      corrupt_first_segment(agent_id, fn records ->
        Enum.map(records, &Map.drop(&1, [:kind, :data]))
      end)

    assert {:error, {:archive_incomplete, %{key: _, reason: :segment_body_invalid}}} =
             InternalSessionStore.transcript(agent_id, read!(agent_id), {:before, 4, 2})
  end

  @tag :redo_regression
  test "a message with malformed data returns an archive error through redaction" do
    agent_id = "agent-#{System.unique_integer([:positive])}"

    {agent_id, _} =
      corrupt_first_segment(agent_id, fn records ->
        Enum.map(records, &Map.put(&1, :data, nil))
      end)

    state =
      agent_id
      |> read!()
      |> InternalSession.export()
      |> Map.put(:redactions, [%{"seq" => 1, "replacement" => "hidden"}])
      |> InternalSession.open()

    assert {:error, {:archive_incomplete, %{reason: :segment_body_invalid}}} =
             InternalSessionStore.transcript(agent_id, state, {:before, 4, 2})
  end

  @tag :redo_regression
  test "a stale archive hint refreshes before adopting a longer landed segment" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..3, &deliver/1))
    assert {:ok, stale} = InternalSessionStore.commit(agent_id, @session, [compaction(3)])
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, Enum.map(4..20, &deliver/1))
    assert {:ok, fresh} = InternalSessionStore.commit(agent_id, @session, [compaction(20)])
    winner = SealedSegments.next_segment(shaped_window(fresh), @line)
    assert winner.last_seq > InternalSession.get(stale, :last_seq)
    key = segment_key(agent_id, 1)
    bytes = SealedSegments.encode(winner.records)
    assert {:ok, _} = S3.put(key, bytes, if_none_match: "*")

    assert {:ok, :archived} =
             InternalSessionStore.archive_compacted(agent_id, @session, stale)

    assert InternalSession.archived_through(read!(agent_id)) == 20
    assert {:ok, :nothing_to_archive} = InternalSessionStore.archive_compacted(agent_id, @session)
    assert {:ok, %{body: ^bytes}} = S3.get(key)

    assert {:ok, %{messages: messages}} =
             InternalSessionStore.transcript(agent_id, read!(agent_id), {:tail, 20})

    assert Enum.map(messages, &(&1["seq"] || &1[:seq])) == Enum.to_list(1..20)
  end

  test "a hot CAS conflict republishes from the new revision before removing its records" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
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
      Task.async(fn ->
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

    assert {:ok, :archived} = Task.await(task, 5_000)
    current = read!(agent_id)
    assert InternalSession.archived_through(current) == 20
    assert InternalSession.get(current, :messages) == []
    assert {:ok, records} = InternalSessionStore.archived_records(agent_id, current)
    assert records === shaped_window(newer)
  end

  test "failed hot advance leaves recoverable segments; ambiguous creates settle" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
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

  test "redaction remains an overlay across sealing and snapshot reload" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..20, &deliver/1))

    assert {:ok, _} =
             InternalSessionStore.commit(agent_id, @session, [
               %{
                 "type" => "session_microcompact",
                 "session_id" => @session,
                 "message_ids" => [2],
                 "new_content" => "[redacted]"
               },
               compaction(20)
             ])

    assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)
    assert {:ok, %{body: bytes}} = S3.get(segment_key(agent_id, 1))
    raw = SealedSegments.decode(bytes) |> Enum.find(&(&1.seq == 2))
    assert raw.data["content"] =~ "input 2 "

    assert {:ok, %{messages: [masked]}} =
             InternalSessionStore.transcript(agent_id, read!(agent_id), {:before, 3, 1})

    assert masked["content"] == "[redacted]"
  end

  test "fork carries a live sealed result and publishes a format-3 child without copying history" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)
    Application.put_env(:salix_store, :seal_line_bytes, 1)
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

  for format <- [2, 3] do
    test "format #{format} listings count sealed messages and the live tail without archive reads" do
      format = unquote(format)
      agent_id = "agent-#{System.unique_integer([:positive])}"
      Application.put_env(:salix_store, :seal_line_bytes, 1)

      # The stored result occupies a seq but is not a transcript message.
      seed_format3(
        agent_id,
        [deliver(1), stored_result_event("trf1_0000000000000000008"), deliver(2), deliver(3)],
        format
      )

      assert {:ok, %{"message_count" => 3}} =
               SalixAgent.InternalAgentRuntime.get_session_summary(agent_id, @session)

      for through <- [2, 3] do
        assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(through)])
        assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session)
        session = read!(agent_id)
        assert length(InternalSession.get(session, :messages)) == 3 - through
        assert InternalSession.archived_through(session) == through + 1

        S3.Fake.reset_read_log()

        assert {:ok, [%{"message_count" => 3}]} =
                 SalixAgent.InternalAgentRuntime.list_sessions(agent_id)

        assert {:ok, %{"message_count" => 3}} =
                 SalixAgent.InternalAgentRuntime.get_session_summary(agent_id, @session)

        hot_key = Keys.agent_internal_runtime_session(agent_id, @session)

        assert Enum.all?(S3.Fake.read_log(), fn
                 {:get, key} -> key == hot_key
                 _operation -> true
               end)
      end
    end
  end

  test "format-2 sessions switch to new writes and never append the legacy archive" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
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
    agent_id = "agent-#{System.unique_integer([:positive])}"
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
      Process.sleep(10)
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
