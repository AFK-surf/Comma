defmodule SalixAgent.InternalSessionSegmentsTest do
  @moduledoc """
  Immutable segment cuts and adoption, PG directory publication, and exact
  history reads. Each worker visit publishes one cut. The retained
  SessionHotArchive model covers the storage publication boundary.
  """

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSessionStore
  alias SalixStore.{Keys, S3, SealedSegments}
  alias SalixAgent.InternalSessionStore.{PG, PGCodec}
  alias SalixStore.Repo

  @session "ses1_0000000000000000900"
  @line 2_000

  setup do
    SystemsRuntime.put_env(:salix_store, :seal_line_bytes, @line)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_store, :seal_line_bytes) end)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
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
  defp seed_format3(agent_id, events, format \\ 3, session_id \\ @session) do
    state =
      agent_id
      |> InternalSession.new(session_id, %{})
      |> InternalSession.export()
      |> Map.put(:storage_format, format)
      |> InternalSession.open()
      |> InternalSession.apply_events([
        %{"type" => "session_created", "session_id" => session_id} | events
      ])
      |> InternalSession.normalize()

    SalixAgent.TestSupport.SessionFixture.cleanup_on_exit(agent_id)

    Repo.query!(
      "INSERT INTO salix_agents (agent_id,tenant_id,group_id,role,config_revision,config_payload,owner_node,owner_epoch,root_revision) VALUES($1,'tenant','group','worker',1,$2,'owner',1,1) ON CONFLICT(agent_id) DO NOTHING",
      [agent_id, PGCodec.encode(%{})]
    )

    [[epoch]] =
      Repo.query!("SELECT owner_epoch FROM salix_agents WHERE agent_id=$1", [agent_id]).rows

    :ok = SalixAgent.OwnershipCell.install(agent_id, epoch)
    on_exit(fn -> SalixAgent.OwnershipCell.clear(agent_id) end)
    assert :ok = InternalSessionStore.prepare_seed(agent_id, state)

    {:ok, _} =
      Registry.register(
        SalixAgent.Registry,
        SalixAgent.InternalSessionActor.key(agent_id, session_id),
        %{runtime_epoch: epoch}
      )

    state
  end

  defp archive_all(agent, session, captured \\ nil) do
    {:ok, state} = InternalSessionStore.read(agent, session)
    archive_visits(agent, session, captured, InternalSession.get(state, :last_seq) + 2, false)
  end

  defp archive_visits(_agent, _session, _captured, 0, _advanced),
    do: flunk("archive target did not finish")

  defp archive_visits(agent, session, captured, left, advanced) do
    case InternalSessionStore.archive_pending(agent, session, captured) do
      {:ok, :archived} ->
        archive_visits(agent, session, nil, left - 1, true)

      {:ok, :nothing_to_archive} ->
        {:ok, head} = PG.archive_head(agent, session)

        if head.target,
          do: archive_visits(agent, session, nil, left - 1, advanced),
          else: {:ok, if(advanced, do: :archived, else: :nothing_to_archive)}

      error ->
        error
    end
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

  test "an uncompacted cold window restores model context, typed messages and fork results" do
    agent = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    ref = "trf1_0000000000000000017"
    accepted = {1, "user_message", "src-1", %{"content" => "kept", "identity" => {17, "17"}}}

    seed_format3(agent, [
      Map.put(deliver(1), "accepted_input", accepted),
      %{
        "type" => "assistant",
        "message_id" => 2,
        "content" => "checking",
        "created_at" => 2_000,
        "input_tokens" => 19,
        "provider_meta" => %{"context_provider_states" => %{"notice" => %{"version" => 1}}},
        "tool_calls" => [
          %{
            "id" => "call-segment-result",
            "type" => "function",
            "function" => %{"name" => "composio.execute", "arguments" => "{}"}
          }
        ]
      },
      stored_result_event(ref),
      result_capsule(3, ref),
      deliver(4)
    ])

    before = read!(agent)
    context = InternalSession.query(before, :provider_context)
    {:ok, fork_before} = InternalSession.fork(before, @session, %{})

    through = InternalSession.get(before, :last_seq)
    key = segment_key(agent, 1)
    assert {:ok, :archived} = archive_all(agent, @session)

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM salix_session_records WHERE agent_id=$1 AND session_id=$2",
               [agent, @session]
             ).rows

    after_cold = read!(agent)
    assert InternalSession.get(after_cold, :compacted_seq) == 0
    assert InternalSession.archived_through(after_cold) == through
    assert InternalSession.query(after_cold, :provider_context) === context
    assert InternalSession.get(after_cold, :messages) === InternalSession.get(before, :messages)
    assert hd(InternalSession.get(after_cold, :messages)).accepted_input === accepted

    assert {:ok, %{"archived_not_searched" => false, "results" => [%{"message_id" => 1}]}} =
             SalixAgent.InternalAgentRuntime.search_messages(agent, "input 1")

    assert InternalSession.fork_inline_result_seqs(after_cold, %{}) == []
    expected_seqs = Enum.map(InternalSession.get(before, :messages), & &1.seq)
    assert InternalSessionStore.window_records_shaped(after_cold) == []

    assert {:ok, %{truncated?: false}} =
             InternalSessionStore.transcript(agent, after_cold, :window)

    for scope <- [:full, {:tail, 20}, {:before, through + 1, 20}] do
      assert {:ok, %{messages: messages}} =
               InternalSessionStore.transcript(agent, after_cold, scope)

      assert Enum.map(messages, &(&1[:seq] || &1["seq"])) == expected_seqs
    end

    compacted_cached = InternalSession.apply_event(after_cold, compaction(4))

    assert {:ok, %{messages: cached_tail}} =
             InternalSessionStore.transcript(agent, compacted_cached, {:tail, 20})

    assert Enum.map(cached_tail, &(&1[:seq] || &1["seq"])) == expected_seqs

    assert {:ok, fork_after} = InternalSession.fork(after_cold, @session, %{})
    assert InternalSession.export(fork_after) === InternalSession.export(fork_before)
    assert {:ok, result} = InternalSessionStore.fetch_tool_result(agent, @session, ref)
    assert result["result_json"] == Jason.encode!(%{"items" => Enum.to_list(1..20)})

    assert {:ok, _} = InternalSessionStore.commit(agent, @session, [compaction(2)])
    compacted_cold = read!(agent)
    assert InternalSession.get(compacted_cold, :compacted_seq) == 3
    assert InternalSession.get(compacted_cold, :async_results) == []
    assert InternalSession.fork_inline_result_seqs(compacted_cold, %{}) == [3]
    assert {:ok, ^result} = InternalSessionStore.fetch_tool_result(agent, @session, ref)

    assert {:ok, carried_fork} =
             InternalSession.fork(compacted_cold, @session, %{"inline_results" => [result]})

    assert [%{"result_ref" => ^ref}] = InternalSession.get(carried_fork, :async_results)

    :ok = S3.Fake.blackhole({:fail, 503, :get, key})
    assert {:error, {:archive_unreadable, ^key, _}} = InternalSessionStore.read(agent, @session)
  end

  test "a rejected body deletion rolls back publication and the landed segment is adopted" do
    agent = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_format3(agent, Enum.map(1..3, &deliver/1))
    assert {:ok, _} = InternalSessionStore.commit(agent, @session, [compaction(1)])
    before = read!(agent)
    context = InternalSession.query(before, :provider_context)
    function = "session_archive_delete_reject_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    trigger = function <> "_t"
    [[agent_literal]] = Repo.query!("SELECT quote_literal($1::text)", [agent]).rows

    Repo.query!(
      "CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'archive delete rejected'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER #{trigger} BEFORE DELETE ON salix_session_records FOR EACH ROW WHEN (OLD.agent_id=#{agent_literal}) EXECUTE FUNCTION #{function}()"
    )

    try do
      assert {:error, {:rolled_back, %Postgrex.Error{}}} =
               InternalSessionStore.archive_pending(agent, @session)

      assert [[0, 3, 0]] =
               Repo.query!(
                 "SELECT archived_through,(SELECT count(*) FROM salix_session_records WHERE agent_id=$1 AND session_id=$2),(SELECT count(*) FROM salix_session_archives WHERE agent_id=$1 AND session_id=$2) FROM salix_sessions WHERE agent_id=$1 AND session_id=$2",
                 [agent, @session]
               ).rows

      key = segment_key(agent, 1)
      assert {:ok, %{body: body}} = S3.get(key)
      Repo.query!("DROP TRIGGER #{trigger} ON salix_session_records")
      assert {:ok, :archived} = archive_all(agent, @session)
      assert {:ok, %{body: ^body}} = S3.get(key)

      assert [[0]] =
               Repo.query!(
                 "SELECT count(*) FROM salix_session_records WHERE agent_id=$1 AND session_id=$2",
                 [agent, @session]
               ).rows

      assert InternalSession.query(read!(agent), :provider_context) === context
    after
      Repo.query!("DROP TRIGGER IF EXISTS #{trigger} ON salix_session_records")
      Repo.query!("DROP FUNCTION IF EXISTS #{function}()")
    end
  end

  test "continuous input seals a record batch and idle discovery flushes its partial tail" do
    agent = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    SystemsRuntime.put_env(:salix_store, :seal_line_bytes, 16 * 1024 * 1024)
    seed_format3(agent, [])

    for batch <- 0..15 do
      events =
        for id <- (batch * 16 + 1)..((batch + 1) * 16),
            do: Map.put(deliver(id), "created_at", SystemsClock.system_time(:millisecond))

      assert {:ok, _} = InternalSessionStore.commit(agent, @session, events)
      expected = if batch == 15, do: :archived, else: :nothing_to_archive
      assert {:ok, ^expected} = InternalSessionStore.archive_pending(agent, @session)
    end

    assert S3.Fake.put_log() == [segment_key(agent, 1)]
    assert InternalSession.archived_through(read!(agent)) == 256

    assert {:ok, _} =
             InternalSessionStore.commit(agent, @session, [
               Map.put(deliver(257), "created_at", SystemsClock.system_time(:millisecond))
             ])

    assert {:ok, :nothing_to_archive} = InternalSessionStore.archive_pending(agent, @session)
    assert {:ok, waiting, _} = PG.archive_work_page()
    refute [agent, @session] in waiting

    settle_after(30_000)
    assert {:ok, ready, _} = PG.archive_work_page()
    assert [agent, @session] in ready
    assert {:ok, :archived} = InternalSessionStore.archive_pending(agent, @session)
    assert S3.Fake.put_log() == [segment_key(agent, 1), segment_key(agent, 257)]
    assert length(InternalSession.get(read!(agent), :messages)) == 257
  end

  test "the maintenance runner resumes its published target and preserves accepted input" do
    agent = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    SystemsRuntime.put_env(:salix_store, :seal_line_bytes, 1)

    seed_format3(
      agent,
      Enum.map(1..5, &deliver/1) ++
        [
          %{
            "type" => "queue_append",
            "kind" => "user_message",
            "dedupe_key" => "pending-input",
            "payload" => %{"content" => "waiting"}
          }
        ]
    )

    before = read!(agent)
    assert {:ok, captured} = PG.admit_archive_maintenance(agent, @session)
    assert {:ok, :archived} = InternalSessionStore.archive_captured(captured)

    assert [[2, 1, 5]] =
             Repo.query!(
               "SELECT revision,archived_through,archive_target_seq FROM salix_sessions WHERE agent_id=$1 AND session_id=$2",
               [agent, @session]
             ).rows

    assert {:ok, %{sessions: 1, failed: 0, archive_visits: 4}} =
             SalixAgent.SessionHistory.ArchiveEviction.run(agent_id: agent)

    after_cold = read!(agent)
    assert InternalSession.archived_through(after_cold) == 5

    assert InternalSession.get(after_cold, :input_queue) ===
             InternalSession.get(before, :input_queue)

    assert InternalSession.get(after_cold, :storage_revision) ===
             InternalSession.get(before, :storage_revision)

    assert InternalSession.query(after_cold, :provider_context) ===
             InternalSession.query(before, :provider_context)

    assert [[0, nil]] =
             Repo.query!(
               "SELECT (SELECT count(*) FROM salix_session_records WHERE agent_id=$1 AND session_id=$2),archive_target_seq FROM salix_sessions WHERE agent_id=$1 AND session_id=$2",
               [agent, @session]
             ).rows

    assert {:ok, %{sessions: 0, failed: 0}} =
             SalixAgent.SessionHistory.ArchiveEviction.run(agent_id: agent)

    assert length(S3.Fake.put_log()) == 5
  end

  test "a business change during maintenance leaves the captured prefix for the normal owner" do
    agent = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_format3(agent, Enum.map(1..3, &deliver/1))
    assert {:ok, captured} = PG.admit_archive_maintenance(agent, @session)
    key = segment_key(agent, 1)
    :ok = S3.Fake.set_fault({:pause, :put, key})
    task = SystemsRuntime.Task.async(fn -> InternalSessionStore.archive_captured(captured) end)
    assert wait_until_paused(100)
    assert {:ok, newer} = InternalSessionStore.commit(agent, @session, [deliver(4)])
    :ok = S3.Fake.release_pause()
    assert {:error, :session_changed} = settled_await(task)

    assert [[0, 4]] =
             Repo.query!(
               "SELECT archived_through,(SELECT count(*) FROM salix_session_records WHERE agent_id=$1 AND session_id=$2) FROM salix_sessions WHERE agent_id=$1 AND session_id=$2",
               [agent, @session]
             ).rows

    assert {:ok, %{body: body}} = S3.get(key)
    assert {:ok, :archived} = archive_all(agent, @session)
    assert {:ok, %{body: ^body}} = S3.get(key)

    assert InternalSession.query(read!(agent), :provider_context) ===
             InternalSession.query(newer, :provider_context)
  end

  for kind <- [:missing, :partial] do
    test "maintenance hands the #{kind} old target's untouched tail to the normal owner" do
      agent = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"

      if unquote(kind) == :missing do
        seed_format3(agent, Enum.map(1..2, &deliver/1))
        assert {:ok, :archived} = archive_all(agent, @session)
        assert {:ok, _} = InternalSessionStore.commit(agent, @session, Enum.map(3..5, &deliver/1))
      else
        seed_format3(agent, Enum.map(1..5, &deliver/1))
        assert {:ok, _} = InternalSessionStore.commit(agent, @session, [compaction(2)])
      end

      # Reproduce the target written by the old producer during policy rollout.
      old_target = if unquote(kind) == :missing, do: nil, else: 2

      Repo.query!(
        "UPDATE salix_sessions SET archive_target_seq=$3 WHERE agent_id=$1 AND session_id=$2",
        [agent, @session, old_target]
      )

      context = InternalSession.query(read!(agent), :provider_context)

      assert {:ok, %{sessions: 1, failed: 0}} =
               SalixAgent.SessionHistory.ArchiveEviction.run(agent_id: agent)

      assert [[2, 5, 3]] =
               Repo.query!(
                 "SELECT archived_through,archive_target_seq,(SELECT count(*) FROM salix_session_records WHERE agent_id=$1 AND session_id=$2) FROM salix_sessions WHERE agent_id=$1 AND session_id=$2",
                 [agent, @session]
               ).rows

      assert {:ok, ready, _} = PG.archive_work_page()
      assert [agent, @session] in ready
      assert {:ok, :archived} = archive_all(agent, @session)
      assert InternalSession.query(read!(agent), :provider_context) === context

      assert [[0]] =
               Repo.query!(
                 "SELECT count(*) FROM salix_session_records WHERE agent_id=$1 AND session_id=$2",
                 [agent, @session]
               ).rows
    end
  end

  test "one failed maintenance target does not block another Session" do
    agent = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    other = "ses1_0000000000000000901"
    seed_format3(agent, Enum.map(1..2, &deliver/1))
    seed_format3(agent, Enum.map(1..2, &deliver/1), 3, other)
    :ok = S3.Fake.blackhole({:fail, 503, :put, segment_key(agent, 1)})

    assert {:error, %{sessions: 2, failed: 1}} =
             SalixAgent.SessionHistory.ArchiveEviction.run(agent_id: agent)

    assert [[^other, 2, 0], [@session, 0, 2]] =
             Repo.query!(
               "SELECT session_id,archived_through,(SELECT count(*) FROM salix_session_records r WHERE r.agent_id=s.agent_id AND r.session_id=s.session_id) FROM salix_sessions s WHERE agent_id=$1 ORDER BY archived_through DESC",
               [agent]
             ).rows

    :ok = S3.Fake.clear_blackhole()

    assert {:ok, %{sessions: 1, failed: 0}} =
             SalixAgent.SessionHistory.ArchiveEviction.run(agent_id: agent)
  end

  test "sealing closes full segments and removes the compacted partial tail" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..300, &deliver/1))

    assert {:ok, compacted} = InternalSessionStore.commit(agent_id, @session, [compaction(300)])
    assert InternalSession.storage_format(compacted) == 3

    assert {:ok, pre_seal} = InternalSessionStore.read(agent_id, @session)
    original_records = shaped_window(pre_seal)

    assert {:ok, :archived} = archive_all(agent_id, @session)
    # Every compacted record was sealed. Repeated archival is a no-op.
    assert {:ok, :nothing_to_archive} = archive_all(agent_id, @session)

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
        if last < through, do: assert(measured >= @line or last - first + 1 == 256)
        records
      end)

    assert published === original_records

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
               archive_all(agent_id, @session)

      assert {:ok, after_attempt} = InternalSessionStore.read(agent_id, @session)
      assert shaped_window(after_attempt) === shaped_window(before)

      assert InternalSession.archived_through(after_attempt) ==
               InternalSession.archived_through(before)

      assert {:ok, %{body: ^body}} = S3.get(key)
    end
  end

  test "a stale owner's re-seal is pure duplicates and cannot roll back" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..600, &deliver/1))

    # First seal establishes a non-empty catalog prefix.
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(100)])
    assert {:ok, :archived} = InternalSessionStore.archive_pending(agent_id, @session)
    assert {:ok, first_round} = InternalSessionStore.read(agent_id, @session)
    through1 = InternalSession.archived_through(first_round)

    # Owner A captures at ceiling 300 and stalls.
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(300)])
    assert {:ok, stale} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.get(stale, :compacted_seq) == 300

    # Owner B compacts and archives all the way while A is stalled.
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(600)])
    assert {:ok, :archived} = archive_all(agent_id, @session)
    assert {:ok, ahead} = InternalSessionStore.read(agent_id, @session)
    ahead_catalog = InternalSession.get(ahead, :segment_catalog)

    # A reads B's current revision. The stale view cannot replace its catalog.
    assert {:ok, :nothing_to_archive} =
             archive_all(agent_id, @session, stale)

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
    assert {:ok, :archived} = archive_all(agent_id, @session)
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

  test "a sealed tool result reads only its model context and protected result segments" do
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
    assert {:ok, :archived} = archive_all(agent_id, @session)
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

    # Loading the current model window reads its cold page; resolving the
    # protected result reads only the separate segment that contains it.
    assert segment_gets(S3.Fake.read_log()) == [
             segment_key(agent_id, 3),
             segment_key(agent_id, 1)
           ]
  end

  test "a missing segment object fails loudly instead of serving a short history" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..300, &deliver/1))
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(300)])
    assert {:ok, :archived} = archive_all(agent_id, @session)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    victim = segment_key(agent_id, hd(hd(InternalSession.get(session, :segment_catalog))))

    S3.Fake.reset()

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)

    assert {:error, {:archive_incomplete, _}} =
             InternalSessionStore.archived_records(agent_id, session)

    assert {:error, :not_found} = S3.get(victim)
  end

  test "new input does not invalidate an uncompacted archive cut" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..3, &deliver/1))
    captured = read!(agent_id)
    key = segment_key(agent_id, 1)
    :ok = S3.Fake.set_fault({:pause, :put, key})

    task =
      SystemsRuntime.Task.async(fn ->
        InternalSessionStore.archive_pending(agent_id, @session, captured)
      end)

    assert wait_until_paused(100)

    assert {:ok, newer} =
             InternalSessionStore.commit(
               agent_id,
               @session,
               Enum.map(4..20, &deliver/1)
             )

    :ok = S3.Fake.release_pause()
    assert {:ok, :archived} = settled_await(task)
    current = read!(agent_id)
    assert InternalSession.archived_through(current) == 3
    assert InternalSession.get(current, :compacted_seq) == 0
    assert {:ok, :archived} = archive_all(agent_id, @session)
    current = read!(agent_id)
    assert InternalSession.archived_through(current) == 20
    assert {:ok, records} = InternalSessionStore.archived_records(agent_id, current)
    assert Enum.map(records, & &1.seq) == Enum.to_list(1..20)
    assert Enum.map(InternalSession.get(newer, :messages), & &1[:id]) == Enum.to_list(1..20)
  end

  test "a landed orphan is adopted and an ambiguous create settles without replacing bytes" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_format3(agent_id, Enum.map(1..20, &deliver/1))
    assert {:ok, compacted} = InternalSessionStore.commit(agent_id, @session, [compaction(20)])
    first = SealedSegments.next_segment(shaped_window(compacted), @line)
    body = SealedSegments.encode(first.records)
    key = segment_key(agent_id, 1)
    assert {:ok, _} = S3.put(key, body, if_none_match: "*")
    assert InternalSession.archived_through(read!(agent_id)) == 0
    next_key = segment_key(agent_id, first.last_seq + 1)
    :ok = S3.Fake.set_fault({:ambiguous_after, :put, next_key})
    assert {:ok, :archived} = archive_all(agent_id, @session)
    assert {:ok, %{body: ^body}} = S3.get(key)

    assert {:ok, %{messages: messages}} =
             InternalSessionStore.transcript(agent_id, read!(agent_id), {:tail, 20})

    assert Enum.map(messages, &(&1["seq"] || &1[:seq])) == Enum.to_list(1..20)
  end

  test "a longer cut landing during create is captured on the next ordinary visit" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    SystemsRuntime.put_env(:salix_store, :seal_line_bytes, 1)
    seed_format3(agent_id, Enum.map(1..3, &deliver/1))
    assert {:ok, compacted} = InternalSessionStore.commit(agent_id, @session, [compaction(3)])
    key = segment_key(agent_id, 1)
    :ok = S3.Fake.set_fault({:pause, :put, key})

    task =
      SystemsRuntime.Task.async(fn ->
        InternalSessionStore.archive_pending(agent_id, @session)
      end)

    assert wait_until_paused(100)
    landed = SealedSegments.encode(shaped_window(compacted))
    assert {:ok, _} = S3.put(key, landed, if_none_match: "*")
    :ok = S3.Fake.release_pause()
    assert {:ok, :archived} = settled_await(task)
    current = read!(agent_id)
    assert InternalSession.archived_through(current) == 3
    assert [[1, 3, 3, _]] = InternalSession.get(current, :segment_catalog)
    assert {:ok, %{body: ^landed}} = S3.get(key)
  end

  test "fork carries a live sealed result and publishes a format-3 child without copying history" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)
    {:ok, _} = SalixAgent.Placement.ensure_started(agent_id, process_on_init: false)
    assert {:parked, _} = SalixAgent.Server.info(agent_id)
    SystemsRuntime.put_env(:salix_store, :seal_line_bytes, 1)
    ref = "trf1_0000000000000000007"
    seed_format3(agent_id, [deliver(1), stored_result_event(ref), result_capsule(2, ref)])
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(1)])
    assert {:ok, :archived} = archive_all(agent_id, @session)
    assert {:ok, source_result} = InternalSessionStore.fetch_tool_result(agent_id, @session, ref)

    S3.Fake.reset_read_log()

    assert {:ok, forked} =
             SalixAgent.InternalAgentRuntime.fork_session_local(agent_id, @session, %{
               "fork_request_id" => "sealed-result-fork",
               "message_id" => 2
             })

    reads = segment_gets(S3.Fake.read_log())
    # Cold model context and the one protected result are separate segments.
    assert reads == [segment_key(agent_id, 3), segment_key(agent_id, 2)]
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
