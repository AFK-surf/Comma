defmodule SalixAgent.PGImportTest do
  use SystemsClock.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.SalixAgent.PGImport", "Elixir.SalixStore"]

  alias SalixAgent.{InternalSession, InternalSessionStore, PGImport}
  alias SalixAgent.InternalSessionStore.PG, as: SessionPG

  alias SalixStore.{
    AgentPGStore,
    ArchiveLog,
    Codec,
    Head,
    Ids,
    Keys,
    PGAuthorityImport,
    Repo,
    S3,
    SealedSegments
  }

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name='salix_pg_authority_s_v1'")
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, previous) end)
    {:ok, agent: "g1-" <> Base.encode16(SystemsRuntime.Proc.random_bytes(8), case: :lower)}
  end

  test "bounded pages resume with complete root, queued input, source frontier and exact cold history",
       %{agent: agent} do
    {record, head} = agent_source(agent)
    session = Ids.new_session_id()

    old =
      InternalSession.new(agent, session, %{created_at: 10})
      |> InternalSession.apply_events([
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => 1,
          "role" => "user",
          "content" => "cold",
          "source_message_id" => "old-message"
        },
        %{
          "type" => "queue_append",
          "kind" => "user_message",
          "dedupe_key" => "accepted-once",
          "payload" => %{"content" => "pending"}
        },
        %{
          "type" => "conversation_source_advance",
          "source" => %{
            "participant_id" => "participant",
            "conversation_id" => "conversation",
            "generation" => session,
            "start_seq" => 1,
            "seq" => 2
          }
        },
        %{
          "type" => "async_tool_call_started",
          "tool_call_id" => "callback",
          "tool_name" => "lookup",
          "completion_mode" => "external_callback",
          "capability_request_id" => "request"
        }
      ])
      |> InternalSession.stamp(storage_revision: "source-storage", runtime_epoch: 7)

    exported = InternalSession.export(old)
    [message] = exported.messages
    archive = [ArchiveLog.shape("message", message.seq, message)]
    entry = SealedSegments.entry_for(archive)
    cold_key = Keys.agent_internal_runtime_session_segment(agent, session, message.seq)
    put(cold_key, SealedSegments.encode(archive))
    state = %{exported | archived_through: message.seq, segment_catalog: [entry], messages: []}
    put(Keys.agent_internal_runtime_session(agent, session), Codec.encode_session_snapshot(state))
    put(Keys.agent_session_birth(agent, session), Jason.encode!(%{"runtime" => "internal"}))
    retired = Ids.new_session_id()

    put(
      Keys.agent_external_runtime_session(agent, retired),
      Jason.encode!(%{"agent_id" => agent, "session_id" => retired, "name" => "retired history"})
    )

    born = Ids.new_session_id()
    birth_key = Keys.agent_session_birth(agent, born)
    put(birth_key, Jason.encode!(%{"runtime" => "internal"}))

    %{rows: [[lsn]]} = Repo.query!("SELECT pg_current_wal_insert_lsn()::text")
    assert {:ok, first} = PGImport.step(page_size: 1)
    assert first.step == 1
    assert {:ok, %{record: ^record}} = AgentPGStore.read_config(agent)
    assert {:error, :not_found} = InternalSessionStore.read(agent, session)
    assert {:ok, ^first} = PGAuthorityImport.state(:s)

    {elapsed, result} =
      :timer.tc(fn ->
        PGImport.run(max_pages: 1000, known_sessions: %{birth_key => born})
      end)

    assert {:ok, %{phase: "complete", stats: stats} = completed} = result
    reads = S3.Fake.read_log()
    assert Enum.count(reads, &match?({:list, "agents/", _}, &1)) == 1
    refute {:get, cold_key} in reads
    assert stats["list_requests"] > 0 and stats["listed_objects"] > 0
    assert {:ok, ^completed} = PGImport.run(max_pages: 1)
    assert {:ok, loaded} = InternalSessionStore.read(agent, session)
    assert InternalSession.get(loaded, :storage_revision) == "source-storage"
    assert InternalSession.get(loaded, :runtime_epoch) == 7
    assert InternalSession.get(loaded, :input_queue) == InternalSession.get(old, :input_queue)

    assert InternalSession.conversation_sources(loaded) ==
             InternalSession.conversation_sources(old)

    assert InternalSession.get(loaded, :async_tool_calls) ==
             InternalSession.get(old, :async_tool_calls)

    assert {:ok, :retired} = SessionPG.birth(agent, retired)
    assert {:ok, :internal} = SessionPG.birth(agent, born)
    assert {:error, :not_found} = SessionPG.read(agent, born)
    assert {:ok, page} = InternalSessionStore.transcript(agent, loaded, :full)
    assert Enum.map(page.messages, &(&1[:content] || &1["content"])) == ["cold"]

    %{rows: [[^cold_key, "etf.zst"]]} =
      Repo.query!(
        "SELECT object_key,encoding FROM salix_session_archives WHERE agent_id=$1 AND session_id=$2",
        [agent, session]
      )

    assert {:ok, imported_root} = AgentPGStore.read_root(agent)
    assert imported_root.head == %{head | owner_node: nil, lease_until: nil}
    assert {:ok, claimed} = AgentPGStore.claim(agent, "new-owner", SalixAgent.State)
    assert claimed.epoch == head.epoch + 1

    assert Map.drop(Map.from_struct(claimed.head), [
             :epoch,
             :owner_node,
             :lease_until,
             :commit_uuid
           ]) ==
             Map.drop(Map.from_struct(head), [:epoch, :owner_node, :lease_until, :commit_uuid])

    assert :ok = AgentPGStore.release(claimed)

    %{rows: [[wal]]} =
      Repo.query!(
        "SELECT pg_wal_lsn_diff(pg_current_wal_insert_lsn(),$1::text::pg_lsn)::bigint",
        [lsn]
      )

    IO.puts(
      "G1_S_SAMPLE " <>
        Jason.encode!(%{
          elapsed_us: elapsed,
          objects: stats["objects"],
          wire_bytes: stats["wire_bytes"],
          inflated_bytes: stats["inflated_bytes"],
          wal_bytes: wal
        })
    )
  end

  test "an Agent page writes bounded root batches and preserves every original fact", %{
    agent: prefix
  } do
    sources =
      for n <- 1..129 do
        agent = prefix <> "-" <> String.pad_leading(Integer.to_string(n), 3, "0")
        {record, head} = agent_source(agent)
        {agent, record, head}
      end

    handler = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        fn _, _, meta, _ ->
          if self() == owner, do: send(owner, {:import_query, meta.query, meta.params})
        end,
        nil
      )

    try do
      assert {:ok, %{step: 1}} = PGImport.step()
    after
      :telemetry.detach(handler)
    end

    inserts =
      import_queries([])
      |> Enum.count(fn {query, _} ->
        String.starts_with?(query, "INSERT INTO \"salix_agents\"")
      end)

    assert inserts == 2

    for {agent, record, head} <- sources do
      assert {:ok, %{record: ^record}} = AgentPGStore.read_config(agent)
      assert {:ok, imported} = AgentPGStore.read_root(agent)
      assert imported.head == %{head | owner_node: nil, lease_until: nil}
    end
  end

  test "a rejected Agent batch names its failing source and rolls back the page", %{agent: prefix} do
    good = prefix <> "-a"
    bad = prefix <> "-z"
    agent_source(good)
    {_, head} = agent_source(bad)

    put(
      Keys.agent_state(bad),
      Codec.encode_snapshot(%{
        format: 2,
        sm: SalixAgent.State,
        head: %{head | epoch: nil},
        payload: %{mode: :whole, state: SalixAgent.State.init(bad)}
      })
    )

    key = Keys.ctl_agent(bad)
    assert {:error, {:import_object_failed, ^key, :not_null_violation}} = PGImport.step()
    assert {:error, :not_found} = AgentPGStore.read_config(good)
    assert {:error, :not_found} = AgentPGStore.read_config(bad)
    assert {:ok, nil} = PGAuthorityImport.state(:s)
  end

  test "a same-page birth-kind conflict rejects all Session facts before commit", %{agent: agent} do
    agent_source(agent)
    session = Ids.new_session_id()
    state = InternalSession.new(agent, session)

    put(
      Keys.agent_internal_runtime_session(agent, session),
      Codec.encode_session_snapshot(InternalSession.export(state))
    )

    key = Keys.agent_session_birth(agent, session)
    put(key, Jason.encode!(%{"runtime" => "external"}))

    assert {:error, {:import_source_object, ^key, :conflicting_session_birth}} =
             PGImport.run(max_pages: 1_000)

    assert {:ok, :new} = SessionPG.birth(agent, session)

    put(key, Jason.encode!(%{"runtime" => "internal"}))
    assert {:ok, %{phase: "complete"}} = PGImport.run(max_pages: 1_000)
    assert {:ok, :internal} = SessionPG.birth(agent, session)
  end

  test "unresolved marker identity stops the unit and explicit real ID resumes it", %{
    agent: agent
  } do
    agent_source(agent)
    session = Ids.new_session_id()
    key = Keys.agent_session_birth(agent, session)
    put(key, Jason.encode!(%{"runtime" => "external"}))

    assert {:error, {:import_source_object, ^key, {:unresolved_birth_identity, ^key}}} =
             PGImport.run(max_pages: 1000)

    assert {:ok, %{phase: "importing"}} = PGAuthorityImport.state(:s)

    assert {:ok, %{phase: "complete"}} =
             PGImport.run(max_pages: 1000, known_sessions: %{key => session})

    assert {:ok, :retired} = SessionPG.birth(agent, session)
  end

  test "birth reuses committed original identities across pages and importer processes", %{
    agent: agent
  } do
    agent_source(agent)
    internal = Ids.new_session_id()
    retired = Ids.new_session_id()
    internal_key = Keys.agent_internal_runtime_session(agent, internal)
    external_key = Keys.agent_external_runtime_session(agent, retired)

    put(
      internal_key,
      Codec.encode_session_snapshot(InternalSession.export(InternalSession.new(agent, internal)))
    )

    put(external_key, Jason.encode!(%{"agent_id" => agent, "session_id" => retired}))
    put(Keys.agent_session_birth(agent, internal), Jason.encode!(%{"runtime" => "internal"}))
    put(Keys.agent_session_birth(agent, retired), Jason.encode!(%{"runtime" => "external"}))

    # Each step owns a fresh transient index, as it does after a process restart.
    Enum.reduce_while(1..20, nil, fn _, _ ->
      task = SystemsRuntime.Task.async(fn -> PGImport.step(page_size: 1) end)
      assert {:ok, progress} = settled_await(task)
      if progress.phase == "complete", do: {:halt, progress}, else: {:cont, progress}
    end)

    assert {:ok, %{phase: "complete"}} = PGAuthorityImport.state(:s)
    assert {:ok, :internal} = SessionPG.birth(agent, internal)
    assert {:ok, :retired} = SessionPG.birth(agent, retired)
    reads = S3.Fake.read_log()
    assert Enum.count(reads, &(&1 == {:get, internal_key})) == 1
    assert Enum.count(reads, &(&1 == {:get, external_key})) == 1
    assert {:ok, loaded} = SessionPG.read(agent, internal)
    assert InternalSession.session_id(loaded.state) == internal
  end

  test "source-only inventory resolves a birth after its Session page without imported owners", %{
    agent: agent
  } do
    agent_source(agent)
    session = Ids.new_session_id()

    put(
      Keys.agent_internal_runtime_session(agent, session),
      Codec.encode_session_snapshot(InternalSession.export(InternalSession.new(agent, session)))
    )

    birth_key = Keys.agent_session_birth(agent, session)
    put(birth_key, Jason.encode!(%{"runtime" => "internal"}))

    {objects, final} =
      Enum.reduce_while(1..20, {[], nil}, fn _, {seen, cursor} ->
        assert {:ok, page} = PGImport.inventory(cursor, page_size: 1)
        seen = seen ++ page.objects
        if is_nil(page.next), do: {:halt, {seen, nil}}, else: {:cont, {seen, page.next}}
      end)

    assert is_nil(final)
    assert Enum.any?(objects, &(&1.key == birth_key and &1.kind == :birth))
    assert {:ok, nil} = PGAuthorityImport.state(:s)
    assert {:ok, :new} = SessionPG.birth(agent, session)
    assert {:error, :not_found} = AgentPGStore.read_config(agent)
  end

  test "expanded page overflow commits the source prefix and resumes the valid next object", %{
    agent: agent
  } do
    agent_source(agent)
    sessions = for _ <- 1..3, do: Ids.new_session_id()

    for session <- sessions do
      state = InternalSession.new(agent, session)

      put(
        Keys.agent_internal_runtime_session(agent, session),
        Codec.encode_session_snapshot(InternalSession.export(state))
      )

      put(Keys.agent_session_birth(agent, session), Jason.encode!(%{"runtime" => "internal"}))
    end

    assert {:ok, %{phase: "complete", stats: stats}} =
             PGImport.run(max_pages: 1000, max_page_inflated_bytes: 1)

    assert stats["objects"] == Enum.count(S3.Fake.read_log(), &match?({:get, _}, &1))
    for session <- sessions, do: assert({:ok, _} = SessionPG.read(agent, session))
    assert Enum.count(S3.Fake.read_log(), &match?({:list, "agents/", _}, &1)) > 1
  end

  test "inventory and byte failure write neither facts nor progress", %{agent: agent} do
    agent_source(agent)
    before = S3.Fake.dump()

    assert {:ok, %{objects: [%{kind: :agent}], validation: :source_codec_only}} =
             PGImport.inventory(nil, page_size: 1)

    assert S3.Fake.dump() == before
    assert {:ok, nil} = PGAuthorityImport.state(:s)
    assert {:error, :not_found} = AgentPGStore.read_config(agent)

    assert {:error, {:import_source_object, _, {:source_byte_limit, _}}} =
             PGImport.step(max_object_bytes: 20)

    assert {:ok, nil} = PGAuthorityImport.state(:s)
  end

  test "legacy split requires its original owner and retains the source", %{
    agent: agent
  } do
    {_record, head} = agent_source(agent)

    root = %{
      format: 2,
      sm: SalixAgent.State,
      head: head,
      payload: %{mode: :split, meta: %{agent_id: agent}, refs: %{vfs: "missing", sessions: %{}}}
    }

    put(Keys.agent_state(agent), Codec.encode_snapshot(root))

    assert {:error, {:import_source_object, _, {:missing_split_reference, missing}}} =
             PGImport.step()

    assert missing == "agents/#{agent}/vfs/missing.etf.zst"
    put(missing, Codec.encode_snapshot(%{}))

    assert {:error,
            {:import_source_object, source_key, {:unresolved_legacy_split, root_key, ^missing}}} =
             PGImport.step()

    assert source_key == Keys.ctl_agent(agent)
    assert root_key == Keys.agent_state(agent)
    assert {:ok, nil} = PGAuthorityImport.state(:s)
    assert {:ok, %{body: bytes}} = S3.get(Keys.agent_state(agent))
    assert Codec.decode_snapshot(bytes) == root
  end

  test "capability import retains pending delivery and acknowledges existing Session terminals",
       %{agent: agent} do
    agent_source(agent)
    session = Ids.new_session_id()

    state =
      InternalSession.new(agent, session)
      |> InternalSession.apply_events([
        capability_started("due", "due"),
        capability_started("resolved", "resolved"),
        capability_started("pre-handoff", nil),
        %{
          "type" => "async_tool_call_completed",
          "tool_call_id" => "resolved",
          "completed_at" => 100,
          "result" => %{"content" => "original terminal"}
        }
      ])

    session_source(state)

    for id <- ~w(due resolved pre-handoff cancelled) do
      capability_source(
        agent,
        session,
        id,
        if(id == "cancelled", do: "cancelled", else: "completed")
      )
    end

    %{rows: [[before]]} = Repo.query!("SELECT clock_timestamp()")
    assert {:ok, %{phase: "complete"} = completed} = PGImport.run(max_pages: 1000)

    %{rows: rows} =
      Repo.query!(
        "SELECT request_id,result_delivery_due_at,result_delivered_at FROM salix_capability_requests WHERE group_id=$1 ORDER BY request_id",
        [agent]
      )

    assert [
             ["cancelled", nil, nil],
             ["due", due, nil],
             ["pre-handoff", handoff, nil],
             ["resolved", nil, acknowledged]
           ] = rows

    assert DateTime.to_unix(due) == 2
    assert DateTime.to_unix(handoff) == 2
    assert DateTime.compare(acknowledged, before) != :lt
    assert {:ok, record} = SalixAgent.CapabilityRequestStore.PG.get(agent, "resolved")
    assert record["tool_call_id"] == "resolved"
    assert record["result"]["content"] == "frozen"
    assert record["settlement_deadline_ms"] == 30_002

    assert {:ok, acknowledged_row} = SalixAgent.CapabilityRequestStore.PG.read(agent, "resolved")
    SystemsClock.advance(1_000)
    assert DateTime.compare(SystemsClock.utc_now(), acknowledged_row.delivered_at) == :gt
    assert {:ok, ^completed} = PGImport.run(max_pages: 1000)
    assert {:ok, ^acknowledged_row} = SalixAgent.CapabilityRequestStore.PG.read(agent, "resolved")
  end

  test "legacy requests without deadlines keep their outcomes and use the owner's expiry policy",
       %{
         agent: agent
       } do
    agent_source(agent)
    session = Ids.new_session_id()

    for status <- ~w(pending completed cancelled) do
      capability_source(agent, session, status, status, %{
        "request_type" => "mcp_management",
        "expires_at" => nil,
        "created_at" => 1_788_317_301,
        "result" => nil
      })
    end

    capability_source(agent, session, "explicit", "pending", %{"result" => nil})
    source = S3.Fake.dump()
    assert {:ok, %{phase: "complete"} = completed} = PGImport.run(max_pages: 1000)
    assert S3.Fake.dump() == source

    for status <- ~w(pending completed cancelled) do
      assert {:ok, %{record: record, due_at: nil, delivered_at: nil}} =
               SalixAgent.CapabilityRequestStore.PG.read(agent, status)

      assert record["status"] == status
      assert record["request_type"] == "mcp_management"
      assert record["created_at"] == 1_788_317_301
      assert record["expires_at"] == 1_788_317_421
      assert is_nil(record["result"])
    end

    assert %{rows: [[3]]} =
             Repo.query!(
               "SELECT count(*) FROM salix_capability_requests WHERE group_id=$1 AND expires_at=to_timestamp($2)",
               [agent, 1_788_317_421]
             )

    assert {:ok, explicit} = SalixAgent.CapabilityRequestStore.PG.get(agent, "explicit")
    assert explicit["expires_at"] == 2_000_000_000
    assert {:ok, ^completed} = PGImport.run(max_pages: 1000)
  end

  test "unresolved consumers retain the exact source and reject the whole Capability page", %{
    agent: agent
  } do
    agent_source(agent)
    session = Ids.new_session_id()

    session_source(
      InternalSession.new(agent, session)
      |> InternalSession.apply_events([capability_started("known", "known")])
    )

    capability_source(agent, session, "known")
    key = capability_source(agent, session, "unknown")
    assert {:ok, _} = PGImport.step()
    assert {:ok, before} = PGImport.step()
    objects = S3.Fake.dump()

    assert {:error, {:import_source_object, ^key, :unresolved_completion_target}} =
             PGImport.step()

    assert {:ok, ^before} = PGAuthorityImport.state(:s)
    assert S3.Fake.dump() == objects

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM salix_capability_requests WHERE group_id=$1", [
               agent
             ])

    capability_source(agent, session, "unknown", "pending", %{"result" => nil})
    assert {:ok, %{phase: "complete"}} = PGImport.step()
  end

  for {label, patch} <- [
        {"another Capability binding", %{"capability_request_id" => "other"}},
        {"another request type", %{"tool_name" => "location.request"}}
      ] do
    test "running call rejects #{label}", %{agent: agent} do
      agent_source(agent)
      session = Ids.new_session_id()
      event = Map.merge(capability_started("request", "request"), unquote(Macro.escape(patch)))
      session_source(InternalSession.new(agent, session) |> InternalSession.apply_events([event]))
      key = capability_source(agent, session, "request")

      assert {:error, {:import_source_object, ^key, :conflicting_completion_target}} =
               PGImport.run(max_pages: 1000)
    end
  end

  test "a same-named call in another Session supplies no consumer evidence", %{agent: agent} do
    agent_source(agent)
    actual = Ids.new_session_id()
    other = Ids.new_session_id()

    session_source(
      InternalSession.new(agent, actual)
      |> InternalSession.apply_events([capability_started("call", "call")])
    )

    session_source(InternalSession.new(agent, other))
    key = capability_source(agent, other, "call")

    assert {:error, {:import_source_object, ^key, :unresolved_completion_target}} =
             PGImport.run(max_pages: 1000)
  end

  test "one Capability page reads one control per Session and no retained history", %{
    agent: agent
  } do
    agent_source(agent)
    session = Ids.new_session_id()

    events =
      for id <- 1..200, do: capability_started("call-#{id}", nil) |> Map.delete("completion_mode")

    state =
      InternalSession.new(agent, session)
      |> InternalSession.apply_events(
        events ++
          for(
            id <- 1..150,
            do: %{"type" => "assistant", "message_id" => id, "content" => "unrelated"}
          )
      )

    session_source(state)
    for id <- 1..200, do: capability_source(agent, session, "call-#{id}")
    assert {:ok, _} = PGImport.step()
    assert {:ok, _} = PGImport.step()
    handler = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        fn _, _, meta, _ ->
          if self() == owner, do: send(owner, {:import_query, meta.query, meta.params})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, %{phase: "complete"}} = PGImport.step()
    queries = import_queries([])

    session_reads =
      Enum.filter(queries, fn {sql, _} -> String.contains?(sql, "salix_session") end)

    assert [{control, [^agent, ^session, limit]}] = session_reads
    assert String.contains?(control, "control_payload")
    assert limit <= 16 * 1_048_576

    assert %{rows: [[200]]} =
             Repo.query!(
               "SELECT count(*) FROM salix_capability_requests WHERE group_id=$1 AND result_delivery_due_at IS NOT NULL",
               [agent]
             )
  end

  test "consumer byte limits leave the Capability page and marker unchanged", %{agent: agent} do
    agent_source(agent)
    session = Ids.new_session_id()
    events = for id <- 1..25, do: capability_started("call-#{id}", nil)
    session_source(InternalSession.new(agent, session) |> InternalSession.apply_events(events))
    key = capability_source(agent, session, "call-1")
    assert {:ok, _} = PGImport.step()
    assert {:ok, before} = PGImport.step()

    assert {:error, {:import_source_object, ^key, :completion_target_byte_limit}} =
             PGImport.step(max_page_bytes: 1200)

    assert {:ok, ^before} = PGAuthorityImport.state(:s)
    assert {:ok, %{phase: "complete"}} = PGImport.step()
  end

  test "a different existing Capability value rolls back every insert and its page marker", %{
    agent: agent
  } do
    agent_source(agent)
    session = Ids.new_session_id()

    session_source(
      InternalSession.new(agent, session)
      |> InternalSession.apply_events([
        capability_started("a-new", nil),
        capability_started("z-conflict", nil)
      ])
    )

    capability_source(agent, session, "a-new")
    key = capability_source(agent, session, "z-conflict")
    {:ok, %{body: bytes}} = S3.get(key)

    existing =
      Jason.decode!(bytes) |> Map.put("result", %{"content" => "different durable result"})

    assert {:ok, old} =
             existing
             |> SalixAgent.CapabilityRequestStore.PG.prepare_insert()
             |> SalixAgent.CapabilityRequestStore.PG.execute()

    assert {:ok, _} = PGImport.step()
    assert {:ok, before} = PGImport.step()

    assert {:error,
            {:import_conflict, "salix_capability_requests",
             %{"group_id" => ^agent, "request_id" => "z-conflict"}}} = PGImport.step()

    assert {:ok, ^before} = PGAuthorityImport.state(:s)
    assert {:ok, ^old} = SalixAgent.CapabilityRequestStore.PG.read(agent, "z-conflict")
    assert {:error, :not_found} = SalixAgent.CapabilityRequestStore.PG.read(agent, "a-new")
  end

  for encoding <- [:segment, :jsonl] do
    test "exact #{encoding} terminal wrappers hydrate while archived result references need no body",
         %{
           agent: agent
         } do
      agent_source(agent)
      session = Ids.new_session_id()

      state =
        InternalSession.new(agent, session)
        |> InternalSession.apply_events([
          capability_started("cold", "cold"),
          capability_started("reference", "reference"),
          %{
            "type" => "async_tool_call_completed",
            "tool_call_id" => "cold",
            "completed_at" => 100,
            "result" => %{"content" => "cold result"}
          },
          %{
            "type" => "async_tool_call_completed",
            "tool_call_id" => "reference",
            "completed_at" => 100,
            "result" => %{"content" => "reference result"}
          },
          %{"type" => "capability_request_sync", "tool_call_id" => "reference", "settled" => true}
        ])

      source = InternalSession.export(state)
      [cold, reference] = source.async_results
      cold_record = ArchiveLog.shape("async_result", cold["seq"], cold)
      ref_record = ArchiveLog.shape("async_result", reference["seq"], reference)
      cold_key = Keys.agent_internal_runtime_session_segment(agent, session, cold["seq"])
      ref_key = Keys.agent_internal_runtime_session_segment(agent, session, reference["seq"])

      cold_key =
        if unquote(encoding) == :jsonl,
          do: Keys.agent_internal_runtime_session_archive(agent, session),
          else: cold_key

      put(
        cold_key,
        if(unquote(encoding) == :jsonl,
          do: ArchiveLog.encode([cold_record]),
          else: SealedSegments.encode([cold_record])
        )
      )

      # The result-reference path already has the immutable terminal position.
      # It must not require the unrelated reference body to remain readable.
      source = %{
        source
        | archived_through: 2,
          compacted_seq: 2,
          async_results: [],
          archive_chunks:
            if(unquote(encoding) == :jsonl,
              do:
                Enum.map(ArchiveLog.spans([cold_record], 0), fn [
                                                                  first,
                                                                  last,
                                                                  _count,
                                                                  offset,
                                                                  length
                                                                ] ->
                  [first, last, 99, offset, length]
                end),
              else: []
            ),
          segment_catalog:
            if(unquote(encoding) == :segment,
              do: [SealedSegments.entry_for([cold_record])],
              else: []
            ) ++
              [SealedSegments.entry_for([ref_record])]
      }

      session_source(InternalSession.open(source))
      capability_source(agent, session, "cold")
      capability_source(agent, session, "reference")
      assert {:ok, %{phase: "complete"}} = PGImport.run(max_pages: 1000)
      assert {:get, cold_key} in S3.Fake.read_log()
      refute {:get, ref_key} in S3.Fake.read_log()

      assert %{rows: [[2]]} =
               Repo.query!(
                 "SELECT count(*) FROM salix_capability_requests WHERE group_id=$1 AND result_delivery_due_at IS NULL AND result_delivered_at IS NOT NULL",
                 [agent]
               )
    end
  end

  for encoding <- [:segment, :jsonl] do
    test "pruned #{encoding} terminals use release locations and one committed span read", %{
      agent: agent
    } do
      alias SalixAgent.InternalSessionStore.PGCodec
      agent_source(agent)
      session = Ids.new_session_id()
      cold = pruned_cold_source(agent, session, ~w(a-cold b-cold), unquote(encoding))
      key = capability_source(agent, session, "a-cold")
      capability_source(agent, session, "b-cold")

      assert {:error, {:import_source_object, ^key, :unresolved_completion_target}} =
               PGImport.run(max_pages: 1000)

      assert {:ok, before} = PGAuthorityImport.state(:s)

      %{rows: [[control]]} =
        Repo.query!(
          "SELECT control_payload FROM salix_sessions WHERE agent_id=$1 AND session_id=$2",
          [agent, session]
        )

      assert PGCodec.decode(control)["async_result_refs"] == %{}

      assert {:error, {:import_source_object, ^key, reason}} =
               PGImport.step(cold_result_locations: cold.locations, max_page_bytes: 4096)

      assert reason == :completion_target_byte_limit

      assert {:ok, ^before} = PGAuthorityImport.state(:s)

      if unquote(encoding) == :jsonl do
        body = S3.Fake.dump()[cold.key].body

        selected =
          for record <- ArchiveLog.decode!(body),
              do: record.data |> Map.put("seq", record.seq) |> Map.put("kind", "async_result")

        retained = byte_size(PGCodec.encode(selected))

        {:ok, exact} =
          PGAuthorityImport.limits(
            max_page_bytes: max(byte_size(body), retained) + byte_size(control)
          )

        index = Map.new(cold.locations, &{{agent, session, &1["tool_call_id"]}, &1["seq"]})

        assert {:ok, %{"a-cold" => :already_resolved, "b-cold" => :already_resolved}, spent} =
                 SalixAgent.InternalSessionStore.ImportTargets.read(
                   agent,
                   session,
                   ~w(a-cold b-cold),
                   exact,
                   cold_result_locations: index
                 )

        assert spent.remaining_bytes == 0
      end

      reads = Enum.count(S3.Fake.read_log(), &(&1 == {:get, cold.key}))

      assert {:ok, %{phase: "complete"} = complete} =
               PGImport.run(max_pages: 1000, cold_result_locations: cold.locations)

      assert Enum.count(S3.Fake.read_log(), &(&1 == {:get, cold.key})) == reads + 1

      assert Repo.query!(
               "SELECT control_payload FROM salix_sessions WHERE agent_id=$1 AND session_id=$2",
               [agent, session]
             ).rows == [[control]]

      assert Repo.query!(
               "SELECT count(*) FROM salix_capability_requests WHERE group_id=$1 AND result_delivery_due_at IS NULL AND result_delivered_at IS NOT NULL",
               [agent]
             ).rows == [[2]]

      assert {:ok, ^complete} =
               PGImport.run(max_pages: 1000, cold_result_locations: cold.locations)

      assert Enum.count(S3.Fake.read_log(), &(&1 == {:get, cold.key})) == reads + 1
    end
  end

  test "release config supplies optional cold locations to the unchanged no-opts entry point", %{
    agent: agent
  } do
    agent_source(agent)
    session = Ids.new_session_id()
    cold = pruned_cold_source(agent, session, ["configured"])
    capability_source(agent, session, "configured")
    dir = Path.join(System.tmp_dir!(), "rfc53-cold-config-#{agent}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "config.json")

    File.write!(
      path,
      Jason.encode!(%{
        "release" => %{"pg_authority_s_cold_result_locations" => cold.locations},
        "billing" => %{"database" => %{"url" => "postgres://localhost/rfc53-config-only"}},
        "storage" => %{
          "endpoint" => "http://localhost",
          "bucket" => "fixture",
          "access_key_id" => "fixture",
          "secret_access_key" => "fixture"
        },
        "web" => %{"api_token" => "fixture"},
        "salix_dashboard" => %{"secret_key_base" => String.duplicate("fixture-", 8)},
        "salix" => %{
          "database" => %{"url" => "postgres://localhost/rfc53-config-only", "pool_size" => 7}
        }
      })
    )

    changes = %{
      "SALIX_CONFIG_PATH" => path,
      "COMMA_RELEASE_JOB" => "1",
      "COMMA_SUBSYSTEMS" => "salix",
      "REDIS_URL" => "redis://localhost/0",
      "COMMA_ENVIRONMENT" => "local"
    }

    previous = Map.new(changes, fn {key, _} -> {key, System.get_env(key)} end)
    old = SystemsRuntime.get_env(:salix_agent, :pg_import_cold_result_locations)

    on_exit(fn ->
      System.put_env(previous)

      if old,
        do: SystemsRuntime.put_env(:salix_agent, :pg_import_cold_result_locations, old),
        else: SystemsRuntime.delete_env(:salix_agent, :pg_import_cold_result_locations)

      File.rm_rf!(dir)
    end)

    System.put_env(changes)
    runtime = Path.expand("../../../config/runtime.exs", __DIR__)
    config = Config.Reader.read!(runtime, env: :prod, target: :host)
    configured = get_in(config, [:salix_agent, :pg_import_cold_result_locations])
    assert configured == cold.locations
    assert config[:salix_store][Repo][:timeout] == 120_000
    assert config[:salix_store][Repo][:pool_size] == 3
    SystemsRuntime.put_env(:salix_agent, :pg_import_cold_result_locations, configured)
    assert {:ok, %{phase: "complete"}} = PGImport.run(max_pages: 1000)

    assert {:ok, %{due_at: nil, delivered_at: %DateTime{}}} =
             SalixAgent.CapabilityRequestStore.PG.read(agent, "configured")

    System.put_env("COMMA_RELEASE_JOB", "0")
    config = Config.Reader.read!(runtime, env: :prod, target: :host)
    assert config[:salix_store][Repo][:pool_size] == 7
    refute Keyword.has_key?(config[:salix_store][Repo], :timeout)
    System.put_env("COMMA_SUBSYSTEMS", "alert_router")
    config = Config.Reader.read!(runtime, env: :test, target: :host)
    assert get_in(config, [:salix_agent, :pg_import_cold_result_locations]) == nil
  end

  test "cold windows charge retained targets while preserving all inflated statistics", %{
    agent: agent
  } do
    agent_source(agent)
    session = Ids.new_session_id()
    filler = String.duplicate("x", 12 * 1_048_576)

    state =
      InternalSession.new(agent, session)
      |> InternalSession.apply_events(
        Enum.flat_map(1..6, fn id ->
          call = "window-#{id}"

          [
            capability_started(call, call),
            %{
              "type" => "async_tool_call_completed",
              "tool_call_id" => call,
              "completed_at" => 100,
              "result" => %{"content" => "terminal"}
            },
            %{"type" => "capability_request_sync", "tool_call_id" => call, "settled" => true},
            %{"type" => "assistant", "message_id" => id, "content" => filler}
          ]
        end)
      )

    results = InternalSession.get(state, :async_results)
    windows = state |> InternalSessionStore.window_records_shaped() |> Enum.chunk_every(2)
    entries = Enum.map(windows, &SealedSegments.entry_for/1)

    keys =
      Enum.map(windows, fn records ->
        key = Keys.agent_internal_runtime_session_segment(agent, session, hd(records).seq)
        put(key, SealedSegments.encode(records))
        key
      end)

    last = InternalSession.get(state, :last_seq)

    state =
      InternalSession.apply_events(state, [
        %{
          "type" => "compaction",
          "summary_sequence" => 1,
          "compacted_through" => 0,
          "compacted_seq" => last,
          "summary" => "compacted"
        },
        %{"type" => "archive_advance", "archived_through" => last, "segments" => entries}
      ])

    assert InternalSession.get(state, :async_tool_calls) == %{}
    assert InternalSession.get(state, :async_result_refs) == %{}
    session_source(state)

    locations =
      for record <- results,
          do: %{
            "agent_id" => agent,
            "session_id" => session,
            "tool_call_id" => record["tool_call_id"],
            "seq" => record["seq"]
          }

    for record <- results, do: capability_source(agent, session, record["tool_call_id"])
    sources = S3.Fake.dump()

    assert {:ok, %{phase: "complete", stats: stats}} =
             PGImport.run(max_pages: 1000, cold_result_locations: locations)

    assert stats["inflated_bytes"] > 64 * 1_048_576
    assert stats["wire_bytes"] < 16 * 1_048_576
    for key <- keys, do: assert(Enum.count(S3.Fake.read_log(), &(&1 == {:get, key})) == 1)
    assert S3.Fake.dump() == sources

    assert Repo.query!(
             "SELECT count(*) FROM salix_capability_requests WHERE group_id=$1 AND result_delivery_due_at IS NULL AND result_delivered_at IS NOT NULL",
             [agent]
           ).rows == [[6]]
  end

  test "wrong-scoped, absent and another call's cold locations remain unresolved", %{agent: agent} do
    agent_source(agent)
    session = Ids.new_session_id()
    cold = pruned_cold_source(agent, session, ~w(a-cold b-cold))
    key = capability_source(agent, session, "a-cold")
    [first, second] = cold.locations
    assert {:ok, _} = PGImport.step()
    assert {:ok, before} = PGImport.step()

    for location <- [
          %{first | "session_id" => Ids.new_session_id()},
          %{first | "seq" => 999_999},
          %{first | "seq" => second["seq"]}
        ] do
      assert {:error, {:import_source_object, ^key, :unresolved_completion_target}} =
               PGImport.step(cold_result_locations: [location])

      assert {:ok, ^before} = PGAuthorityImport.state(:s)
    end

    assert {:error, :not_found} = SalixAgent.CapabilityRequestStore.PG.read(agent, "a-cold")
  end

  test "a nonterminal cold record cannot become an acknowledgement through a location", %{
    agent: agent
  } do
    agent_source(agent)
    session = Ids.new_session_id()
    cold = pruned_cold_source(agent, session, ["cold"], :segment, "running")
    key = capability_source(agent, session, "cold")

    assert {:error, {:import_source_object, ^key, :unresolved_completion_target}} =
             PGImport.run(max_pages: 1000, cold_result_locations: cold.locations)

    assert {:error, :not_found} = SalixAgent.CapabilityRequestStore.PG.read(agent, "cold")
  end

  test "an old cold location cannot replace a current running call", %{agent: agent} do
    agent_source(agent)
    session = Ids.new_session_id()
    cold = pruned_cold_source(agent, session, ["call"])

    cold.state
    |> InternalSession.apply_events([capability_started("call", "call")])
    |> session_source()

    capability_source(agent, session, "call")

    assert {:ok, %{phase: "complete"}} =
             PGImport.run(max_pages: 1000, cold_result_locations: cold.locations)

    assert {:ok, %{due_at: %DateTime{}, delivered_at: nil}} =
             SalixAgent.CapabilityRequestStore.PG.read(agent, "call")

    refute {:get, cold.key} in S3.Fake.read_log()
  end

  test "cold locations do not repair a damaged result-reference owner", %{agent: agent} do
    alias SalixAgent.InternalSessionStore.PGCodec
    agent_source(agent)
    session = Ids.new_session_id()
    cold = pruned_cold_source(agent, session, ["call"])
    key = capability_source(agent, session, "call")
    assert {:ok, _} = PGImport.step()
    assert {:ok, before} = PGImport.step()

    %{rows: [[payload]]} =
      Repo.query!(
        "SELECT control_payload FROM salix_sessions WHERE agent_id=$1 AND session_id=$2",
        [agent, session]
      )

    for refs <- ["damaged", false] do
      broken = PGCodec.decode(payload) |> Map.put("async_result_refs", refs) |> PGCodec.encode()

      Repo.query!(
        "UPDATE salix_sessions SET control_payload=$3 WHERE agent_id=$1 AND session_id=$2",
        [agent, session, broken]
      )

      assert {:error, {:import_source_object, ^key, :invalid_completion_target}} =
               PGImport.step(cold_result_locations: cold.locations)

      assert {:ok, ^before} = PGAuthorityImport.state(:s)
    end

    refute {:get, cold.key} in S3.Fake.read_log()
  end

  test "a terminal omitted from control is found through its scoped result identity index", %{
    agent: agent
  } do
    alias SalixAgent.InternalSessionStore.PGCodec
    agent_source(agent)
    session = Ids.new_session_id()

    session_source(
      InternalSession.new(agent, session)
      |> InternalSession.apply_events([
        capability_started("indexed", "indexed"),
        %{
          "type" => "async_tool_call_completed",
          "tool_call_id" => "indexed",
          "completed_at" => 100,
          "result" => %{"content" => "accepted result"}
        },
        %{"type" => "capability_request_sync", "tool_call_id" => "indexed", "settled" => true}
      ])
    )

    capability_source(agent, session, "indexed")
    assert {:ok, _} = PGImport.step()
    assert {:ok, _} = PGImport.step()

    %{rows: [[payload]]} =
      Repo.query!(
        "SELECT control_payload FROM salix_sessions WHERE agent_id=$1 AND session_id=$2",
        [agent, session]
      )

    control = PGCodec.decode(payload) |> Map.put("async_result_refs", %{})

    Repo.query!(
      "UPDATE salix_sessions SET control_payload=$3 WHERE agent_id=$1 AND session_id=$2",
      [agent, session, PGCodec.encode(control)]
    )

    assert {:ok, %{phase: "complete"}} = PGImport.step()

    assert {:ok, %{due_at: nil, delivered_at: acknowledged}} =
             SalixAgent.CapabilityRequestStore.PG.read(agent, "indexed")

    assert %DateTime{} = acknowledged
  end

  test "legacy JSONL keeps its exact source address and committed byte range", %{agent: agent} do
    agent_source(agent)
    session = Ids.new_session_id()

    source =
      InternalSession.new(agent, session)
      |> InternalSession.apply_events(
        for id <- 1..2,
            do: %{
              "type" => "delivery",
              "from_queue" => true,
              "message_id" => id,
              "role" => "user",
              "content" => "message #{id}",
              "source_message_id" => "message-#{id}"
            }
      )
      |> InternalSession.export()

    [first, second] = source.messages
    records = [ArchiveLog.shape("message", first.seq, first)]
    bytes = ArchiveLog.encode(records)
    key = Keys.agent_internal_runtime_session_archive(agent, session)
    put(key, bytes <> "uncommitted suffix")

    state = %{
      source
      | storage_format: 2,
        archive_chunks: ArchiveLog.spans(records, 0),
        archived_through: first.seq,
        messages: [second]
    }

    put(Keys.agent_internal_runtime_session(agent, session), Codec.encode_snapshot(state))
    objects = S3.Fake.dump()
    assert {:ok, %{phase: "complete"}} = PGImport.run(max_pages: 1000)
    assert S3.Fake.dump() == objects

    %{rows: [[^key, "jsonl", 0, length]]} =
      Repo.query!(
        "SELECT object_key,encoding,byte_offset,byte_length FROM salix_session_archives WHERE agent_id=$1 AND session_id=$2",
        [agent, session]
      )

    assert length == byte_size(bytes)
    assert {:ok, loaded} = InternalSessionStore.read(agent, session)
    assert {:ok, page} = InternalSessionStore.transcript(agent, loaded, :full)
    assert Enum.map(page.messages, &(&1[:content] || &1["content"])) == ["message 1", "message 2"]
  end

  defp import_queries(acc) do
    receive do
      {:import_query, sql, params} -> import_queries([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp capability_started(id, request) do
    %{
      "type" => "async_tool_call_started",
      "tool_call_id" => id,
      "tool_name" => "ifc.request_declassification",
      "completion_mode" => "external_callback"
    }
    |> then(&if(request, do: Map.put(&1, "capability_request_id", request), else: &1))
  end

  defp pruned_cold_source(agent, session, ids, encoding \\ :segment, record_status \\ nil) do
    events =
      ids
      |> Enum.with_index()
      |> Enum.flat_map(fn {id, index} ->
        [
          capability_started(id, id),
          %{
            "type" =>
              if(index == 0, do: "async_tool_call_failed", else: "async_tool_call_completed"),
            "tool_call_id" => id,
            "completed_at" => 100,
            "result" => %{"content" => String.duplicate("cold", 5000)}
          },
          %{"type" => "capability_request_sync", "tool_call_id" => id, "settled" => true}
        ]
      end)

    state = InternalSession.new(agent, session) |> InternalSession.apply_events(events)
    results = InternalSession.get(state, :async_results)

    records =
      Enum.map(results, fn result ->
        result = if record_status, do: Map.put(result, "status", record_status), else: result
        ArchiveLog.shape("async_result", result["seq"], result)
      end)

    last = InternalSession.get(state, :last_seq)
    entry = SealedSegments.entry_for(records)

    state =
      state
      |> InternalSession.apply_events([
        %{
          "type" => "compaction",
          "summary_sequence" => 1,
          "compacted_through" => 0,
          "compacted_seq" => last,
          "summary" => "compacted"
        },
        %{"type" => "archive_advance", "archived_through" => last, "segments" => [entry]}
      ])

    assert InternalSession.get(state, :async_tool_calls) == %{}
    assert InternalSession.get(state, :async_result_refs) == %{}
    assert InternalSession.get(state, :async_results) == []

    key =
      if encoding == :jsonl,
        do: Keys.agent_internal_runtime_session_archive(agent, session),
        else: Keys.agent_internal_runtime_session_segment(agent, session, hd(results)["seq"])

    bytes =
      if encoding == :jsonl, do: ArchiveLog.encode(records), else: SealedSegments.encode(records)

    put(key, bytes)

    state =
      if encoding == :jsonl do
        source = InternalSession.export(state)

        InternalSession.open(%{
          source
          | archive_chunks: ArchiveLog.spans(records, 0),
            segment_catalog: []
        })
      else
        state
      end

    session_source(state)

    locations =
      Enum.map(
        results,
        &%{
          "agent_id" => agent,
          "session_id" => session,
          "tool_call_id" => &1["tool_call_id"],
          "seq" => &1["seq"]
        }
      )

    %{state: state, key: key, locations: locations}
  end

  defp session_source(state) do
    put(
      Keys.agent_internal_runtime_session(
        InternalSession.agent_id(state),
        InternalSession.session_id(state)
      ),
      Codec.encode_session_snapshot(InternalSession.export(state))
    )
  end

  defp capability_source(agent, session, id, status \\ "completed", attrs \\ %{}) do
    record =
      Map.merge(
        %{
          "group_id" => agent,
          "request_id" => id,
          "tenant_id" => "tenant",
          "request_type" => "ifc_declassify",
          "status" => status,
          "expires_at" => 2_000_000_000,
          "source_agent_id" => agent,
          "source_session_id" => session,
          "tool_call_id" => id,
          "created_at" => 1,
          "updated_at" => 2,
          "result" => %{"status" => "completed", "content" => "frozen"},
          "settlement_deadline_ms" => 30_002
        },
        attrs
      )

    key = Keys.ctl_capability_request(agent, id)
    put(key, Jason.encode!(record))
    key
  end

  defp agent_source(agent) do
    record = %{
      "agent_id" => agent,
      "tenant_id" => "tenant",
      "group_id" => agent,
      "role" => "worker",
      "runtime_config" => %{"kind" => "internal"}
    }

    head = %Head{
      epoch: 7,
      owner_node: "old-owner",
      lease_until: 9_999_999,
      commit_uuid: "old-commit",
      journal_tail: %{epoch: 6, seq: 23},
      snapshot_seq: 23,
      message_id_hwm: 41,
      parent_id: "fork-parent",
      fork_seq: 17,
      spill: ["old-spill"],
      format_version: 2,
      hot: %{"original" => true}
    }

    put(Keys.ctl_agent(agent), Jason.encode!(record))

    put(
      Keys.agent_state(agent),
      Codec.encode_snapshot(%{
        format: 2,
        sm: SalixAgent.State,
        head: head,
        payload: %{mode: :whole, state: SalixAgent.State.init(agent)}
      })
    )

    {record, head}
  end

  defp put(key, body), do: {:ok, _} = S3.put(key, body)
end
