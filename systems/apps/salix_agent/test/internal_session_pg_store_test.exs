defmodule SalixAgent.InternalSessionPGStoreTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSessionStore.{PG, PGCodec, Revision}
  alias SalixStore.Repo

  @session "ses1_0000000000000000031"

  defmodule UnavailableS3 do
    def get(_, _), do: raise("online Session touched S3")
    def put(_, _, _), do: raise("online Session touched S3")
    def head(_, _), do: raise("online Session touched S3")
    def list(_, _), do: raise("online Session touched S3")
  end

  # Close the real connection after server COMMIT, before Postgrex sees its reply.
  defmodule CommitReplyProxy do
    def start(upstream_port, owner) do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, {_, port}} = :inet.sockname(listener)

      pid =
        spawn_link(fn ->
          {:ok, client} = :gen_tcp.accept(listener)
          :gen_tcp.close(listener)

          {:ok, upstream} =
            :gen_tcp.connect({127, 0, 0, 1}, upstream_port, [:binary, active: :once])

          :inet.setopts(client, active: :once)
          relay(client, upstream, owner, false, <<>>)
        end)

      {pid, port}
    end

    defp relay(client, upstream, owner, armed, pending) do
      receive do
        {:arm, caller} ->
          send(caller, :proxy_armed)
          relay(client, upstream, owner, true, pending)

        {:tcp, ^client, bytes} ->
          :ok = :gen_tcp.send(upstream, bytes)
          :inet.setopts(client, active: :once)
          relay(client, upstream, owner, armed, pending)

        {:tcp, ^upstream, bytes} ->
          case forward(pending <> bytes, client, armed) do
            :committed ->
              send(owner, :commit_reply_dropped)
              :gen_tcp.close(client)
              :gen_tcp.close(upstream)

            pending ->
              :inet.setopts(upstream, active: :once)
              relay(client, upstream, owner, armed, pending)
          end

        {:tcp_closed, _socket} ->
          :gen_tcp.close(client)
          :gen_tcp.close(upstream)
      end
    end

    defp forward(<<tag, size::32, rest::binary>> = bytes, client, armed)
         when byte_size(rest) >= size - 4 do
      body_size = size - 4
      <<body::binary-size(^body_size), tail::binary>> = rest

      if armed and tag == ?C and body == "COMMIT\0" do
        :committed
      else
        :ok = :gen_tcp.send(client, binary_part(bytes, 0, size + 1))
        forward(tail, client, armed)
      end
    end

    defp forward(bytes, _client, _armed), do: bytes
  end

  setup do
    previous_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    agent = "pg-session-" <> Base.encode16(SystemsRuntime.Proc.random_bytes(8), case: :lower)

    SalixAgent.TestSupport.SessionFixture.cleanup_on_exit(agent)

    Repo.query!(
      """
      INSERT INTO salix_agents
        (agent_id, tenant_id, group_id, role, config_revision, config_payload,
         owner_node, owner_epoch, lease_until, root_revision)
      VALUES ($1, 'tenant', 'group', 'worker', 1, $2, 'owner', 1,
              clock_timestamp() + interval '1 minute', 1)
      """,
      [agent, PGCodec.encode(%{})]
    )

    SystemsRuntime.put_env(:salix_store, :s3_backend, UnavailableS3)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, previous_s3) end)
    {:ok, agent: agent}
  end

  test "offline Session batches retain accepted inputs, dedupe, sources and records", %{
    agent: agent
  } do
    state =
      InternalSession.new(agent, @session)
      |> InternalSession.apply_events(
        Enum.flat_map(1..513, fn id ->
          [
            %{"type" => "assistant", "message_id" => id, "content" => "record #{id}"},
            %{
              "type" => "queue_append",
              "kind" => "user_message",
              "dedupe_key" => "accepted-#{id}",
              "payload" => %{"content" => "input #{id}"}
            },
            %{
              "type" => "conversation_source_advance",
              "source" => %{
                "participant_id" => "participant-#{id}",
                "conversation_id" => "conversation",
                "generation" => @session,
                "start_seq" => 0,
                "seq" => 1
              }
            }
          ]
        end)
      )

    assert {:ok, frozen} = PG.prepare_import(agent, state, %{})
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        fn _, _, meta, _ ->
          if self() == owner, do: send(owner, {:bulk_query, meta.query})
        end,
        nil
      )

    try do
      assert {:ok, :ok} = Repo.transaction(fn -> PG.import_session!(frozen) end)
    after
      :telemetry.detach(handler)
    end

    queries =
      Stream.repeatedly(fn ->
        receive do
          {:bulk_query, sql} -> sql
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)

    for table <-
          ~w(salix_session_records salix_session_inputs salix_session_input_dedupe salix_session_sources) do
      assert Enum.count(queries, &String.starts_with?(&1, "INSERT INTO \"#{table}\"")) == 2
      assert count(agent, table) == 513
    end

    assert {:ok, loaded} = PG.read(agent, @session)

    assert InternalSession.get(loaded.state, :input_queue) ==
             InternalSession.get(state, :input_queue)

    assert InternalSession.get(loaded.state, :input_dedupe) ==
             InternalSession.get(state, :input_dedupe)

    assert InternalSession.conversation_sources(loaded.state) ==
             InternalSession.conversation_sources(state)

    assert InternalSession.get(loaded.state, :messages) == InternalSession.get(state, :messages)
  end

  test "offline archive directories batch original locators without changing nullable fields", %{
    agent: agent
  } do
    state =
      InternalSession.new(agent, @session)
      |> InternalSession.apply_events(
        for id <- 1..513,
            do: %{"type" => "assistant", "message_id" => id, "content" => "cold #{id}"}
      )

    records = SalixAgent.InternalSessionStore.window_records_shaped(state)
    entries = Enum.map(records, &SalixStore.SealedSegments.entry_for([&1]))

    refs =
      Map.new(entries, fn [first, last, messages, bytes] ->
        {first,
         %{
           "first_seq" => first,
           "last_seq" => last,
           "message_count" => messages,
           "record_count" => 1,
           "uncompressed_bytes" => bytes,
           "encoding" => "etf.zst",
           "object_key" =>
             SalixStore.Keys.agent_internal_runtime_session_segment(agent, @session, first),
           "source_session" => nil,
           "byte_offset" => nil,
           "byte_length" => nil
         }}
      end)

    state =
      InternalSession.apply_event(state, %{
        "type" => "archive_advance",
        "archived_through" => 513,
        "segments" => entries
      })

    assert {:ok, frozen} = PG.prepare_import(agent, state, refs)
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        fn _, _, meta, _ ->
          if self() == owner, do: send(owner, {:bulk_archive_query, meta.query})
        end,
        nil
      )

    try do
      assert {:ok, :ok} = Repo.transaction(fn -> PG.import_session!(frozen) end)
    after
      :telemetry.detach(handler)
    end

    queries =
      Stream.repeatedly(fn ->
        receive do
          {:bulk_archive_query, sql} -> sql
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)

    assert Enum.count(queries, &String.starts_with?(&1, "INSERT INTO \"salix_session_archives\"")) ==
             2

    columns =
      ~w(first_seq last_seq object_key encoding record_count message_count uncompressed_bytes source_session byte_offset byte_length)

    expected = refs |> Enum.sort() |> Enum.map(fn {_, row} -> Enum.map(columns, &row[&1]) end)

    assert Repo.query!(
             "SELECT " <>
               Enum.join(columns, ",") <>
               " FROM salix_session_archives WHERE agent_id=$1 AND session_id=$2 ORDER BY first_seq",
             [agent, @session]
           ).rows == expected
  end

  test "duplicate archive locators roll back publication and retain original bodies", %{
    agent: agent
  } do
    assert {:ok, initial} = PG.create(agent, @session, 1)

    assert {:ok, _} =
             PG.commit_revision(initial, 1, [
               %{"type" => "assistant", "message_id" => 1, "content" => "retained"},
               %{"type" => "compaction", "summary" => "summary", "compacted_through" => 1}
             ])

    archive = prepare_cut(agent)
    duplicate = %{archive | entries: archive.entries ++ archive.entries}

    assert {:error, {:rolled_back, %Postgrex.Error{postgres: %{code: :unique_violation}}}} =
             PG.publish_archive(duplicate)

    assert count(agent, "salix_session_archives") == 0
    assert count(agent, "salix_session_records") == 1
    assert {:ok, loaded} = PG.read(agent, @session)
    assert InternalSession.archived_through(loaded.state) == 0
    assert [%{content: "retained"}] = InternalSession.get(loaded.state, :messages)
  end

  test "birth, accepted input, source frontier and materialized record commit without S3", %{
    agent: agent
  } do
    assert {{:ok, :committed}, accepted} = input(agent, @session, 1, entry("source", 1))
    assert accepted.revision == 1
    assert {:ok, reloaded} = PG.read(agent, @session)
    assert InternalSession.conversation_sources(reloaded.state)["participant"]["seq"] == 1
    assert length(InternalSession.get(reloaded.state, :input_queue)) == 1

    {events, true, _hwm} =
      InternalSession.query(reloaded.state, :materialize_pending_input_events)

    assert {:ok, settled} = PG.commit_revision(reloaded, 1, events)
    assert InternalSession.get(settled.state, :input_queue) == []
    assert {:ok, after_crash} = PG.read(agent, @session)

    assert [%{content: "body", accepted_input: {1, "user_message", "source", _}}] =
             InternalSession.get(after_crash.state, :messages)

    assert InternalSession.get(after_crash.state, :input_queue) == []
    assert count(agent, "salix_session_input_dedupe") == 1
    assert count(agent, "salix_session_records") == 1
    assert count(agent, "salix_session_inputs") == 0

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT target_seq FROM agent_session_history_states WHERE agent_id = $1 AND session_id = $2",
               [agent, @session]
             )
  end

  test "duplicate envelopes ignore attached bodies and a new source position still advances", %{
    agent: agent
  } do
    assert {{:ok, :committed}, _} = input(agent, @session, 1, entry("source", 1))
    repeated = %{entry("source", 1) | payload: %{events: :unreadable}}
    assert {{:ok, :duplicate}, duplicate} = input(agent, @session, 1, repeated)
    assert duplicate.revision == 1

    next = %{
      entry("source", 2)
      | payload: %{events: [%{"type" => "vfs_write", "path" => "file", "content" => "repeat"}]}
    }

    assert {{:ok, :committed}, advanced} = input(agent, @session, 1, next)
    assert advanced.revision == 2
    assert InternalSession.conversation_sources(advanced.state)["participant"]["seq"] == 2
    assert count(agent, "salix_session_inputs") == 1
    assert count(agent, "salix_session_input_dedupe") == 1
  end

  test "new envelopes keep original whole-batch capacity even when attached inputs duplicate", %{
    agent: agent
  } do
    previous_limit = SystemsRuntime.fetch_env(:salix_agent, :session_input_queue_limit)
    SystemsRuntime.put_env(:salix_agent, :session_input_queue_limit, 3)

    on_exit(fn ->
      case previous_limit do
        {:ok, limit} -> SystemsRuntime.put_env(:salix_agent, :session_input_queue_limit, limit)
        :error -> SystemsRuntime.delete_env(:salix_agent, :session_input_queue_limit)
      end
    end)

    assert {{:ok, :committed}, _} =
             input(agent, @session, 1, %{
               source_message_id: "existing",
               payload: %{content: "first"}
             })

    new = %{
      source_message_id: "new",
      payload: %{
        content: "new",
        pre_deliveries: [%{source_message_id: "existing", content: "same"}],
        events: [
          %{
            "type" => "queue_append",
            "kind" => "user_message",
            "dedupe_key" => "existing",
            "payload" => %{}
          }
        ]
      }
    }

    assert {:error, :saturated} = input(agent, @session, 1, new)
    assert count(agent, "salix_session_inputs") == 1
    assert count(agent, "salix_session_input_dedupe") == 1
  end

  test "a frozen commit settles once and a newer owner cannot release its old continuation", %{
    agent: agent
  } do
    assert {:ok, created} = PG.create(agent, @session, 1, %{created_at: 1})

    working =
      InternalSession.write_revision(
        created.cursor,
        [%{"type" => "assistant", "message_id" => 1, "content" => "one", "created_at" => 2}],
        nil
      )

    {state, etag, true} = InternalSession.revision_view(working)
    pending = PG.freeze(%{created | cursor: working, state: state, revision: etag}, 1)
    assert {:ok, first} = PG.execute(pending)
    assert {:ok, settled} = PG.settle(pending)
    assert settled.revision == first.revision
    assert count(agent, "salix_session_records") == 1
    Repo.query!("UPDATE salix_agents SET owner_epoch = 2 WHERE agent_id = $1", [agent])
    assert {:error, {:fenced, 2}} = PG.settle(pending)
    assert count(agent, "salix_session_records") == 1
  end

  test "ordinary log retry uses historical SQL aliases absent from the resident queue", %{
    agent: agent
  } do
    alias SalixAgent.{InternalSessionActor, InternalSessionStore, OwnershipCell}

    {:ok, _} =
      Registry.register(SalixAgent.Registry, InternalSessionActor.key(agent, @session), %{
        runtime_epoch: 1
      })

    :ok = OwnershipCell.install(agent, 1)
    on_exit(fn -> OwnershipCell.clear(agent) end)
    assert {:ok, initial} = PG.create(agent, @session, 1)
    entry = %{source_message_id: "historical-log", payload: %{role: "event", content: "once"}}

    assert {{:ok, :committed}, first, _} =
             InternalSession.Command.run(agent, @session, initial, :log, entry)

    assert InternalSession.get(first.state, :input_queue) == []
    refute MapSet.member?(InternalSession.get(first.state, :input_dedupe), "historical-log")

    assert {{:ok, :committed}, second, _} =
             InternalSession.Command.run(agent, @session, first, :log, entry)

    assert count(agent, "salix_session_records") == 1
    assert {:ok, loaded} = InternalSessionStore.read_revision(agent, @session)
    assert length(InternalSession.get(loaded.state, :messages)) == 1
    assert loaded.revision == second.revision
  end

  test "a lost real COMMIT reply settles its original revision after independent archive publication",
       %{agent: agent} do
    assert {:ok, created} = PG.create(agent, @session, 1)

    assert {:ok, initial} =
             PG.commit_revision(created, 1, [
               %{"type" => "assistant", "message_id" => 1, "content" => "first"},
               %{"type" => "assistant", "message_id" => 2, "content" => "second"},
               %{"type" => "compaction", "summary" => "both", "compacted_through" => 2}
             ])

    {command, {:validate_write, _events}} =
      InternalSession.start_command(
        initial.cursor,
        :log,
        %{source_message_id: "logged-once", payload: %{role: "event", content: "once"}},
        nil
      )

    {command, {:fence}} = InternalSession.command_step(command, :write_result, :ok)
    assert {:ok, pending} = PG.freeze_command(command, 1)
    config = Repo.config()
    {proxy, port} = CommitReplyProxy.start(config[:port], self())

    {:ok, isolated_repo} =
      Repo.start_link(
        Keyword.merge(config,
          name: nil,
          pool_size: 1,
          hostname: "127.0.0.1",
          port: port,
          ssl: false,
          after_connect: nil
        )
      )

    original_repo = Repo.get_dynamic_repo()

    try do
      Repo.put_dynamic_repo(isolated_repo)
      Repo.query!("SELECT 1")
      send(proxy, {:arm, self()})
      settle_receive(:proxy_armed)
      assert {:error, :commit_indeterminate, ^pending} = PG.execute(pending)
      settle_receive(:commit_reply_dropped)
    after
      Repo.put_dynamic_repo(original_repo)
      Supervisor.stop(isolated_repo)
    end

    assert count(agent, "salix_session_records") == 3
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    assert {:ok, head} = PG.archive_head(agent, @session)
    assert head.target == 3
    assert {:ok, :archived} = SalixAgent.InternalSessionStore.archive_captured(head)
    assert {:ok, confirmed} = PG.settle(pending)

    {confirmed, {:return, {:ok, :committed}, _}} =
      InternalSession.command_step(confirmed, :next, nil)

    {_, revision, false} =
      confirmed |> InternalSession.command_revision() |> InternalSession.revision_view()

    assert revision == initial.revision + 1
    assert count(agent, "salix_session_records") == 0

    version = %SalixAgent.InternalSessionStore.Revision{
      cursor: InternalSession.command_revision(confirmed),
      state: elem(InternalSession.revision_view(InternalSession.command_revision(confirmed)), 0),
      revision: revision
    }

    assert InternalSession.archived_through(version.state) == 0

    assert {:error, {:stale_revision, actual}} =
             PG.commit_revision(version, 1, [%{"type" => "session_update", "name" => "next"}])

    assert actual == revision + 1
    assert {:ok, current} = PG.read(agent, @session)
    assert current.revision == actual
    assert InternalSession.archived_through(current.state) == 3
    assert length(InternalSession.get(current.state, :messages)) == 1
  end

  test "a lost archive COMMIT reply settles its directory and body eviction together", %{
    agent: agent
  } do
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    assert {:ok, initial} = PG.create(agent, @session, 1)

    assert {:ok, committed} =
             PG.commit_revision(initial, 1, [
               %{"type" => "assistant", "message_id" => 1, "content" => "first"},
               %{"type" => "assistant", "message_id" => 2, "content" => "second"}
             ])

    context = InternalSession.query(committed.state, :provider_context)
    records = SalixAgent.InternalSessionStore.window_records_shaped(committed.state)
    key = SalixStore.Keys.agent_internal_runtime_session_segment(agent, @session, 1)

    assert {:ok, _} =
             SalixStore.S3.put(key, SalixStore.SealedSegments.encode(records), if_none_match: "*")

    archive = prepare_cut(agent)
    config = Repo.config()
    {proxy, port} = CommitReplyProxy.start(config[:port], self())

    {:ok, isolated_repo} =
      Repo.start_link(
        Keyword.merge(config,
          name: nil,
          pool_size: 1,
          hostname: "127.0.0.1",
          port: port,
          ssl: false,
          after_connect: nil
        )
      )

    original_repo = Repo.get_dynamic_repo()

    try do
      Repo.put_dynamic_repo(isolated_repo)
      Repo.query!("SELECT 1")
      send(proxy, {:arm, self()})
      settle_receive(:proxy_armed)
      assert {:error, :archive_indeterminate, ^archive} = PG.publish_archive(archive)
      settle_receive(:commit_reply_dropped)
    after
      Repo.put_dynamic_repo(original_repo)
      Supervisor.stop(isolated_repo)
    end

    assert count(agent, "salix_session_records") == 0
    assert {:ok, :archived} = PG.settle_archive(archive)
    assert {:ok, loaded} = PG.read(agent, @session)
    assert InternalSession.archived_through(loaded.state) == 2
    assert InternalSession.get(loaded.state, :compacted_seq) == 0

    assert InternalSession.get(loaded.state, :storage_revision) ===
             InternalSession.get(committed.state, :storage_revision)

    assert InternalSession.query(loaded.state, :provider_context) === context
    assert SalixStore.S3.Fake.put_log() == [key]
  end

  test "callback terminal references hydrate from one canonical result record", %{agent: agent} do
    assert {:ok, initial} = PG.create(agent, @session, 1)

    events = [
      %{
        "type" => "async_tool_call_started",
        "tool_call_id" => "call",
        "tool_name" => "lookup",
        "completion_mode" => "external_callback",
        "capability_request_id" => "request"
      },
      %{
        "type" => "async_tool_call_completed",
        "tool_call_id" => "call",
        "completed_at" => 100,
        "result" => %{"content" => "canonical body"}
      }
    ]

    assert {:ok, _} = PG.commit_revision(initial, 1, events)
    assert {:ok, loaded} = PG.read(agent, @session)

    assert InternalSession.get(loaded.state, :async_tool_calls)["call"]["result"] == %{
             "content" => "canonical body"
           }

    %{rows: [[control]]} =
      Repo.query!(
        "SELECT control_payload FROM salix_sessions WHERE agent_id = $1 AND session_id = $2",
        [agent, @session]
      )

    assert %{"record_seq" => 1, "pending" => _} =
             PGCodec.decode(control)["async_tool_calls"]["call"]

    assert count(agent, "salix_session_records") == 1
  end

  for {kind, collection, field, events} <- [
        {"message", :messages, :provider_meta,
         [%{"type" => "assistant", "message_id" => 1, "content" => "old message"}]},
        {"fact", :events, "event",
         [%{"type" => "session_event", "kind" => "legacy", "event" => %{}}]},
        {"async_result", :async_results, "result",
         [
           %{
             "type" => "async_tool_call_started",
             "tool_call_id" => "legacy-call",
             "tool_name" => "lookup",
             "completion_mode" => "external_callback"
           },
           %{
             "type" => "async_tool_call_completed",
             "tool_call_id" => "legacy-call",
             "result" => %{"content" => "old result"}
           }
         ]}
      ],
      mode <- ["read", "history"] ++ if(kind == "async_result", do: ["hydrate"], else: []) do
    test "a fresh VM reads historical #{kind} metadata through #{mode}", %{agent: agent} do
      assert {:ok, initial} = PG.create(agent, @session, 1)
      assert {:ok, _} = PG.commit_revision(initial, 1, unquote(Macro.escape(events)))

      [[payload]] =
        Repo.query!(
          "SELECT payload FROM salix_session_records WHERE agent_id=$1 AND session_id=$2 AND kind=$3",
          [agent, @session, unquote(kind)]
        ).rows

      # Model a field written by an older binary, absent from the reader's atom pool.
      name = "retired_record_field_" <> Base.encode16(SystemsRuntime.Proc.random_bytes(12))
      metadata = %{String.to_atom(name) => {17, "17"}, name => "binary key"}
      body = payload |> PGCodec.decode() |> Map.put(unquote(field), metadata)
      payload = PGCodec.encode(body)

      Repo.query!(
        "UPDATE salix_session_records SET payload=$3 WHERE agent_id=$1 AND session_id=$2",
        [agent, @session, payload]
      )

      fresh_record_reader(
        agent,
        name,
        unquote(mode),
        unquote(collection),
        unquote(field),
        payload
      )
    end
  end

  test "archive publication atomically clears bodies and preserves newer control and target",
       %{agent: agent} do
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    assert {:ok, initial} = PG.create(agent, @session, 1)

    records =
      for seq <- 1..3, do: %{"type" => "assistant", "message_id" => seq, "content" => "body"}

    assert {:ok, compacted} =
             PG.commit_revision(
               initial,
               1,
               records ++
                 [
                   %{"type" => "compaction", "summary" => "old", "compacted_through" => 3}
                 ]
             )

    archive = prepare_cut(agent)

    assert {:ok, _} =
             SalixStore.S3.put(
               SalixStore.Keys.agent_internal_runtime_session_segment(agent, @session, 1),
               SalixStore.SealedSegments.encode(
                 SalixAgent.InternalSessionStore.window_records_shaped(compacted.state)
               )
             )

    assert {:ok, newer} =
             PG.commit_revision(compacted, 1, [
               %{"type" => "session_update", "name" => "new control"},
               %{"type" => "assistant", "message_id" => 4, "content" => "new input"}
             ])

    [[control, storage]] =
      Repo.query!(
        "SELECT control_payload,storage_revision FROM salix_sessions WHERE agent_id=$1 AND session_id=$2",
        [agent, @session]
      ).rows

    assert {:ok, :archived} = PG.publish_archive(archive)

    assert [[4]] =
             Repo.query!(
               "SELECT seq FROM salix_session_records WHERE agent_id=$1 AND session_id=$2 ORDER BY seq",
               [agent, @session]
             ).rows

    assert [[^control, ^storage, 4]] =
             Repo.query!(
               "SELECT control_payload,storage_revision,archive_target_seq FROM salix_sessions WHERE agent_id=$1 AND session_id=$2",
               [agent, @session]
             ).rows

    assert {:ok, loaded} = PG.read(agent, @session)
    assert loaded.revision == newer.revision + 1
    assert InternalSession.get(loaded.state, :name) == "new control"
    assert [%{id: 4}] = InternalSession.get(loaded.state, :messages)

    next = prepare_cut(agent)

    assert {:ok, _} =
             SalixStore.S3.put(
               SalixStore.Keys.agent_internal_runtime_session_segment(agent, @session, 4),
               SalixStore.SealedSegments.encode(
                 SalixAgent.InternalSessionStore.window_records_shaped(loaded.state)
               )
             )

    assert {:ok, :archived} = PG.publish_archive(next)
    assert count(agent, "salix_session_records") == 0
    assert {:ok, loaded} = PG.read(agent, @session)

    assert {:ok, _} =
             PG.commit_revision(loaded, 1, [%{"type" => "session_update", "name" => "idle"}])

    assert [[nil]] =
             Repo.query!(
               "SELECT archive_target_seq FROM salix_sessions WHERE agent_id=$1 AND session_id=$2",
               [agent, @session]
             ).rows
  end

  # A publication from another node advances the SQL revision while the owner
  # waits on a model call. The owner's frozen write must still land: refusing
  # it as stale dropped the model response, and the recovery message it left
  # was archived in turn, so the Session retried forever.
  test "an owner write lands over an archive publication made since its read",
       %{agent: agent} do
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    assert {:ok, initial} = PG.create(agent, @session, 1)

    records =
      for seq <- 1..3, do: %{"type" => "assistant", "message_id" => seq, "content" => "body"}

    assert {:ok, owned} = PG.commit_revision(initial, 1, records)
    archive = prepare_cut(agent)

    assert {:ok, _} =
             SalixStore.S3.put(
               SalixStore.Keys.agent_internal_runtime_session_segment(agent, @session, 1),
               SalixStore.SealedSegments.encode(
                 SalixAgent.InternalSessionStore.window_records_shaped(owned.state)
               )
             )

    assert {:ok, :archived} = PG.publish_archive(archive)
    assert count(agent, "salix_session_records") == 0

    assert {:ok, staged} =
             PG.stage_revision(owned, 1, [
               %{"type" => "assistant", "message_id" => 4, "content" => "response"}
             ])

    assert {:ok, written} = staged |> PG.freeze(1) |> PG.execute()
    assert written.revision == owned.revision + 2
    assert InternalSession.archived_through(written.state) == 3

    assert {:ok, loaded} = PG.read(agent, @session)
    assert loaded.revision == written.revision
    assert Enum.map(InternalSession.get(loaded.state, :messages), & &1.id) == [1, 2, 3, 4]
  end

  test "a small archive cut does not fetch later oversized payloads", %{agent: agent} do
    assert {:ok, initial} = PG.create(agent, @session, 1)

    assert {:ok, _} =
             PG.commit_revision(initial, 1, [
               %{"type" => "assistant", "message_id" => 1, "content" => "first"},
               %{
                 "type" => "assistant",
                 "message_id" => 2,
                 "content" => String.duplicate("b", 1_000_000)
               },
               %{
                 "type" => "assistant",
                 "message_id" => 3,
                 "content" => String.duplicate("c", 1_000_000)
               },
               %{"type" => "compaction", "summary" => "all", "compacted_through" => 3}
             ])

    assert {:ok, head} = PG.archive_head(agent, @session)
    owner = self()
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _, _, metadata, _ ->
          if String.starts_with?(metadata.query || "", "SELECT seq,kind,payload") do
            {:ok, result} = metadata.result
            send(owner, {:archive_payloads, result.rows})
          end
        end,
        nil
      )

    try do
      assert {:ok, window} = PG.archive_window(head, {:error, :not_found}, 1)
      assert window.candidate_through == 1
      assert window.record_count == 1
      assert_received {:archive_payloads, [[1, "message", payload]]}
      assert byte_size(payload) < 1_000
      refute_received {:archive_payloads, _}
      malformed = [%{seq: 3, kind: "message", data: %{}}]
      assert {:ok, adopted} = PG.archive_window(head, {:ok, malformed}, 1)
      assert adopted.record_count == 1
      assert_received {:archive_payloads, [[1, "message", _]]}

      assert {:error, {:segment_divergence, 1}} =
               InternalSession.archive_publication(adopted.state, 1, fn
                 {:read_segment, _, _, _} ->
                   {:ok, malformed}

                 {:deterministic_etf, value} ->
                   :erlang.term_to_binary(value, [:deterministic, {:minor_version, 1}])
               end)
    after
      :telemetry.detach(id)
    end
  end

  test "reload uses the snapshot directory for cold callback refs and ignores published hot residue",
       %{agent: agent} do
    alias SalixStore.{S3, SealedSegments}
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    assert {:ok, initial} = PG.create(agent, @session, 1)

    events = [
      %{
        "type" => "async_tool_call_started",
        "tool_call_id" => "cold-call",
        "tool_name" => "lookup",
        "completion_mode" => "external_callback",
        "capability_request_id" => "request"
      },
      %{
        "type" => "async_tool_call_completed",
        "tool_call_id" => "cold-call",
        "completed_at" => 100,
        "result" => %{"content" => "from source segment"}
      }
    ]

    assert {:ok, _} = PG.commit_revision(initial, 1, events)

    %{rows: [[payload]]} =
      Repo.query!(
        "SELECT payload FROM salix_session_records WHERE agent_id=$1 AND session_id=$2 AND seq=1",
        [agent, @session]
      )

    records = [%{seq: 1, kind: "async_result", data: PGCodec.decode(payload)}]
    source_key = "agents/source/internal_runtime/sessions/source/segments/1.etf.zst"
    {:ok, _} = S3.put(source_key, SealedSegments.encode(records))

    Repo.query!(
      "INSERT INTO salix_session_archives (agent_id,session_id,first_seq,last_seq,object_key,encoding,record_count,message_count,uncompressed_bytes,source_session) VALUES($1,$2,1,1,$3,'etf.zst',1,0,100,$4)",
      [
        agent,
        @session,
        source_key,
        PGCodec.encode(%{"agent_id" => "source", "session_id" => "source"})
      ]
    )

    Repo.query!(
      "UPDATE salix_sessions SET archived_through=1,compacted_seq=1 WHERE agent_id=$1 AND session_id=$2",
      [agent, @session]
    )

    assert {:ok, loaded} = PG.read(agent, @session)
    assert InternalSession.get(loaded.state, :async_results) == []

    assert {:ok, %{"result" => %{"content" => "from source segment"}}} =
             InternalSession.lookup_async_call(loaded.state, "cold-call")

    assert {:ok, ^records} = SalixAgent.InternalSessionStore.archived_records(agent, loaded.state)
    # The published directory, not cleanup timing, controls the read window.
    assert count(agent, "salix_session_records") == 1
    puts = S3.Fake.put_log()

    assert {:ok, %{sessions: 1, archive_visits: 0, residue_deleted: 1, failed: 0}} =
             SalixAgent.SessionHistory.ArchiveEviction.run(agent_id: agent)

    assert S3.Fake.put_log() == puts
    assert count(agent, "salix_session_records") == 0
    assert {:ok, _} = PG.read(agent, @session)
    :ok = S3.delete(source_key)
    assert {:error, {:archive_incomplete, %{key: ^source_key}}} = PG.read(agent, @session)
  end

  test "JSONL directory ranges restore callbacks and history without rewriting their source", %{
    agent: agent
  } do
    alias SalixStore.{ArchiveLog, S3}
    alias SalixAgent.{InternalSessionArchiveReader, InternalSessionStore}
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    opts = Repo.config() |> Keyword.drop([:name, :pool, :pool_size]) |> Keyword.put(:pool_size, 4)
    start_supervised!({SalixStore.SessionHistoryRepo, opts})

    source =
      InternalSession.new(agent, @session)
      |> InternalSession.apply_events([
        %{
          "type" => "async_tool_call_started",
          "tool_call_id" => "jsonl-call",
          "completion_mode" => "external_callback",
          "capability_request_id" => "request"
        },
        %{
          "type" => "async_tool_call_completed",
          "tool_call_id" => "jsonl-call",
          "completed_at" => 100,
          "result" => %{"content" => "original callback"}
        },
        %{"type" => "assistant", "message_id" => 1, "content" => "covered"},
        %{"type" => "assistant", "message_id" => 2, "content" => "unpublished tail"},
        %{
          "type" => "queue_append",
          "kind" => "runtime_message",
          "dedupe_key" => "jsonl-notice",
          "payload" => %{"tool_call_id" => "jsonl-call"}
        },
        %{"type" => "compaction", "summary" => "first", "compacted_through" => 1}
      ])

    all = InternalSessionStore.window_records_shaped(source)
    covered = Enum.take(all, 2)
    spans = ArchiveLog.spans(covered, 0, 1)
    key = "agents/original-source/internal_runtime/sessions/original/archive.jsonl"
    body = ArchiveLog.encode(all)
    assert {:ok, _} = S3.put(key, body)

    refs =
      Map.new(spans, fn [first, last, messages, offset, length] ->
        {first,
         %{
           "first_seq" => first,
           "last_seq" => last,
           "message_count" => messages,
           "record_count" => last - first + 1,
           "uncompressed_bytes" => length,
           "encoding" => "jsonl",
           "object_key" => key,
           "byte_offset" => offset,
           "byte_length" => length,
           "source_session" => nil
         }}
      end)

    source =
      InternalSession.apply_event(source, %{
        "type" => "archive_advance",
        "archived_through" => 2,
        "segments" => []
      })

    assert {:ok, frozen} = PG.prepare_import(agent, source, refs)
    assert {:ok, :ok} = Repo.transaction(fn -> PG.import_session!(frozen) end)
    assert {:ok, loaded} = PG.read(agent, @session)
    assert InternalSession.get(loaded.state, :archive_chunks) == spans
    assert InternalSession.get(loaded.state, :segment_catalog) == []

    assert InternalSession.get(loaded.state, :async_tool_calls)["jsonl-call"]["result"] == %{
             "content" => "original callback"
           }

    # Full state seeds retain their source directory at a new address.
    copy_id = "ses1_0000000000000000032"

    copy =
      loaded.state
      |> InternalSession.export()
      |> Map.put(:session_id, copy_id)
      |> InternalSession.open()

    fresh = %SalixAgent.InternalSessionStore.Revision{
      state: copy,
      cursor: InternalSession.start_revision(copy, nil),
      revision: nil
    }

    assert {:ok, _} = fresh |> PG.freeze(1) |> PG.execute()
    assert {:ok, copied} = PG.read(agent, copy_id)
    assert InternalSession.get(copied.state, :archive_chunks) == spans

    addresses = fn state ->
      Map.new(InternalSession.get(state, :archive_refs), fn {first, row} ->
        {first, Map.drop(row, ~w(agent_id session_id))}
      end)
    end

    assert addresses.(copied.state) == addresses.(loaded.state)

    S3.Fake.reset_read_log()
    assert {:ok, ^covered} = InternalSessionStore.archived_records(agent, loaded.state)
    assert S3.Fake.read_log() == [{:get, key}]
    assert {:ok, [%{kind: "async_result", seq: 1}]} = PG.history_page(agent, @session, 0, 2)

    # Adjacent seqs in different objects must not share one range request.
    other = put_in(Enum.at(covered, 1).data["content"], "different object")
    other_key = key <> ".other"
    assert {:ok, _} = S3.put(other_key, ArchiveLog.encode([hd(covered), other]))

    other_ref =
      refs[2]
      |> Map.put("object_key", other_key)
      |> Map.put("byte_length", byte_size(ArchiveLog.encode([other])))

    S3.Fake.reset_read_log()

    assert {:ok, [first, ^other]} =
             InternalSessionArchiveReader.read_descriptors([refs[1], other_ref])

    assert first == hd(covered)
    assert S3.Fake.read_log() == [{:get, key}, {:get, other_key}]
    S3.Fake.reset_read_log()

    assert {:error, {:archive_incomplete, %{missing_locator: {1, 1}}}} =
             InternalSessionArchiveReader.read_descriptors([Map.put(refs[1], "object_key", nil)])

    assert S3.Fake.read_log() == []

    # New archive publication adds an ETF cut to the same SQL directory.
    assert {:ok, _} =
             PG.commit_revision(loaded, 1, [
               %{"type" => "compaction", "summary" => "both", "compacted_through" => 2}
             ])

    assert {:ok, :archived} = InternalSessionStore.archive_pending(agent, @session)
    assert {:ok, mixed} = PG.read(agent, @session)
    assert InternalSession.get(mixed.state, :archive_chunks) == spans
    assert [[3, 3, 1, _]] = InternalSession.get(mixed.state, :segment_catalog)
    assert {:ok, ^all} = InternalSessionStore.archived_records(agent, mixed.state)
    assert {:ok, %{body: ^body}} = S3.get(key)
  end

  test "the newest messages read a bounded number of archive objects", %{agent: agent} do
    alias SalixStore.{ArchiveLog, S3}
    alias SalixAgent.InternalSessionStore
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)

    messages =
      for id <- 1..60, do: %{"type" => "assistant", "message_id" => id, "content" => "m#{id}"}

    source =
      InternalSession.new(agent, @session)
      |> InternalSession.apply_events(
        messages ++ [%{"type" => "compaction", "summary" => "s", "compacted_through" => 5}]
      )

    covered = source |> InternalSessionStore.window_records_shaped() |> Enum.take(50)
    key = "agents/original-source/internal_runtime/sessions/original/archive.jsonl"
    assert {:ok, _} = S3.put(key, ArchiveLog.encode(covered))

    refs =
      covered
      |> ArchiveLog.spans(0, 1)
      |> Map.new(fn [first, last, count, offset, length] ->
        {first,
         %{
           "first_seq" => first,
           "last_seq" => last,
           "message_count" => count,
           "record_count" => last - first + 1,
           "uncompressed_bytes" => length,
           "encoding" => "jsonl",
           "object_key" => key,
           "byte_offset" => offset,
           "byte_length" => length,
           "source_session" => nil
         }}
      end)

    assert map_size(refs) == 50

    source =
      InternalSession.apply_event(source, %{
        "type" => "archive_advance",
        "archived_through" => 50,
        "segments" => []
      })

    assert {:ok, frozen} = PG.prepare_import(agent, source, refs)
    assert {:ok, :ok} = Repo.transaction(fn -> PG.import_session!(frozen) end)

    texts = fn limit ->
      InternalSessionStore.recent_messages(agent, @session, limit, &[&1.content])
    end

    newest = fn count -> Enum.map(60..(61 - count)//-1, &"m#{&1}") end

    # The rows after the archive answer alone.
    S3.Fake.reset_read_log()
    assert {:ok, result} = texts.(4)
    assert result == newest.(4)
    assert S3.Fake.read_log() == []

    # Beyond them the walk goes from the newest object, for at most eight.
    assert {:ok, result} = texts.(40)
    assert result == newest.(18)
    assert length(S3.Fake.read_log()) == 8

    # A failed object read keeps what was read before it.
    :ok = S3.delete(key)
    assert {:ok, result} = texts.(40)
    assert result == newest.(10)

    assert {:error, :not_found} =
             InternalSessionStore.recent_messages(agent, "ses1_0000000000000000099", 4, &[&1])
  end

  test "the newest texts from sealed segments keep their order and labels", %{agent: agent} do
    alias SalixStore.{ArchiveLog, S3, SealedSegments}
    alias SalixAgent.{InternalSessionStore, RouterDecision}
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)

    source =
      InternalSession.new(agent, @session)
      |> InternalSession.apply_events([
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => 1,
          "role" => "user",
          "content" => "archived question",
          "source_message_id" => "source-1",
          "trusted_origin" => %{"provider" => "internal", "ifc" => %{"label" => ["origin"]}}
        },
        %{
          "type" => "assistant",
          "message_id" => 2,
          "content" => "archived answer",
          "ifc" => %{"label" => ["own"]}
        },
        %{"type" => "assistant", "message_id" => 3, "content" => "newest"}
      ])

    records = source |> InternalSessionStore.window_records_shaped() |> Enum.take(2)
    assert [%{seq: first}, %{seq: last}] = records
    key = "agents/#{agent}/internal_runtime/sessions/#{@session}/segments/1.etf.zst"
    body = SealedSegments.encode(records)
    assert {:ok, _} = S3.put(key, body)

    refs = %{
      first => %{
        "first_seq" => first,
        "last_seq" => last,
        "message_count" => ArchiveLog.message_count(records),
        "record_count" => length(records),
        "uncompressed_bytes" => byte_size(body),
        "encoding" => "etf.zst",
        "object_key" => key,
        "byte_offset" => nil,
        "byte_length" => nil,
        "source_session" => nil
      }
    }

    source =
      InternalSession.apply_event(source, %{
        "type" => "archive_advance",
        "archived_through" => last,
        "segments" => []
      })

    assert {:ok, frozen} = PG.prepare_import(agent, source, refs)
    assert {:ok, :ok} = Repo.transaction(fn -> PG.import_session!(frozen) end)

    assert {:ok,
            [
              %{"role" => "assistant", "text" => "newest", "label" => nil},
              %{"role" => "assistant", "text" => "archived answer", "label" => ["own"]},
              %{"role" => "user", "text" => "archived question", "label" => ["origin"]}
            ]} = RouterDecision.recent_labelled_texts(%{"agent_id" => agent}, @session, 3)
  end

  test "delivery timestamps keep their original units while resident and PG metadata use seconds",
       %{
         agent: agent
       } do
    sent_at_ms = 1_793_127_285_857

    delivery = %{
      entry("modern-delivery", 1)
      | payload: %{content: "body", created_at: sent_at_ms, delivered_at_ms: sent_at_ms + 1}
    }

    assert {{:ok, :committed}, accepted} = input(agent, @session, 1, delivery)
    assert InternalSession.get(accepted.state, :last_activity_at) == div(sent_at_ms, 1000)

    {events, true, _hwm} =
      InternalSession.query(accepted.state, :materialize_pending_input_events)

    assert {:ok, committed} = PG.commit_revision(accepted, 1, events)
    assert InternalSession.get(committed.state, :last_activity_at) == div(sent_at_ms, 1000)
    assert {:ok, reloaded} = PG.read(agent, @session)
    assert InternalSession.get(reloaded.state, :last_activity_at) == div(sent_at_ms, 1000)

    assert [%{created_at: ^sent_at_ms, delivered_at_ms: arrived}] =
             InternalSession.get(reloaded.state, :messages)

    assert arrived == sent_at_ms + 1
  end

  test "a stored result keeps milliseconds in its record and seconds in Session metadata", %{
    agent: agent
  } do
    assert {:ok, initial} = PG.create(agent, @session, 1)
    stored_at_ms = 1_700_000_000_123
    result_json = Jason.encode!(%{"content" => "stored result"})

    event = %{
      "type" => "tool_result_stored",
      "session_id" => @session,
      "result_ref" => SalixStore.Ids.new_tool_result_ref(),
      "tool_call_id" => "stored-call",
      "tool_name" => "lookup",
      "result_json" => result_json,
      "result_sha256" => :crypto.hash(:sha256, result_json) |> Base.encode16(case: :lower),
      "result_bytes" => byte_size(result_json),
      "result_chars" => String.length(result_json),
      "status" => "completed",
      "is_error" => false,
      "stored_at_ms" => stored_at_ms
    }

    assert {:ok, committed} = PG.commit_revision(initial, 1, [event])
    assert InternalSession.get(committed.state, :last_activity_at) == div(stored_at_ms, 1000)
    assert {:ok, loaded} = PG.read(agent, @session)
    assert InternalSession.get(loaded.state, :last_activity_at) == div(stored_at_ms, 1000)

    assert [%{"stored_at_ms" => ^stored_at_ms}] =
             InternalSession.get(loaded.state, :async_results)

    assert {:ok, exact_retry} = PG.commit_revision(loaded, 1, [event])

    assert {:error, :tool_result_ref_conflict} =
             PG.commit_revision(exact_retry, 1, [%{event | "status" => "failed"}])

    assert count(agent, "salix_session_records") == 1
  end

  test "historical metadata is normalized once before PG storage", %{agent: agent} do
    assert {:ok, created} = PG.create(agent, @session, 1, %{created_at: 1_700_000_000_123})
    assert InternalSession.get(created.state, :created_at) == 1_700_000_000
    assert InternalSession.get(created.state, :last_activity_at) == 1_700_000_000
    assert {:ok, loaded} = PG.read(agent, @session)
    assert InternalSession.get(loaded.state, :last_activity_at) == 1_700_000_000
    assert PGCodec.timestamp(nil) == nil
    assert PGCodec.timestamp(0) == ~U[1970-01-01 00:00:00Z]
  end

  test "retired birth-only identities and deleted internal ids cannot be reborn", %{agent: agent} do
    Repo.query!(
      "INSERT INTO salix_sessions (agent_id, session_id, birth_kind, revision) VALUES ($1, $2, 'retired', 0)",
      [agent, @session]
    )

    assert {:error, :session_read_only} = PG.create(agent, @session, 1)

    assert %{rows: [[nil, nil, nil]]} =
             Repo.query!(
               "SELECT control_payload, context_revision, storage_revision FROM salix_sessions WHERE agent_id = $1 AND session_id = $2",
               [agent, @session]
             )

    internal = "ses1_0000000000000000032"
    assert {:ok, _} = PG.create(agent, internal, 1)

    Repo.query!(
      "UPDATE salix_sessions SET deleted_at = clock_timestamp() WHERE agent_id = $1 AND session_id = $2",
      [agent, internal]
    )

    assert {:error, :not_found} = PG.create(agent, internal, 1)
  end

  test "ordinary input and frozen commits cannot write an unpublished parent", %{agent: agent} do
    assert {:ok, initial} = PG.create(agent, @session, 1)
    pending = PG.freeze(initial, 1)
    Repo.query!("UPDATE salix_agents SET config_revision = 0 WHERE agent_id = $1", [agent])
    assert {:error, :agent_not_found} = input(agent, @session, 1, entry("new", 1))
    assert {:error, :agent_not_found} = PG.execute(pending)
    assert count(agent, "salix_session_inputs") == 0
  end

  test "workspace effects run between transactions and resume only their frozen revision", %{
    agent: agent
  } do
    input = %{
      source_message_id: "workspace-input",
      payload: %{
        content: "body",
        events: [%{"type" => "vfs_write", "path" => "file", "content" => "value"}]
      }
    }

    assert {:effect_required, effect} = input(agent, @session, 1, input)
    assert {:workspace, _, _, [%{"type" => "vfs_write"}], _} = effect.request
    assert PG.read(agent, @session) == {:error, :not_found}
    assert {{:ok, :committed}, accepted} = PG.continue_input(effect, :ok)
    assert {{:ok, :duplicate}, duplicate} = PG.input_revision(accepted, 1, input)
    assert duplicate.revision == accepted.revision
    assert count(agent, "salix_session_inputs") == 1

    assert {:effect_required, old_effect} =
             PG.input_revision(accepted, 1, %{input | source_message_id: "next"})

    Repo.query!("UPDATE salix_agents SET owner_epoch = 2 WHERE agent_id = $1", [agent])
    assert {:error, {:fenced, 2}} = PG.continue_input(old_effect, :ok)
    assert count(agent, "salix_session_inputs") == 1
  end

  test "staged Conversation input stays volatile until its activation commits", %{agent: agent} do
    state = InternalSession.new(agent, @session)

    fresh = %SalixAgent.InternalSessionStore.Revision{
      cursor: InternalSession.start_revision(state, nil),
      state: state,
      revision: nil
    }

    assert {{:ok, :staged, events}, staged} =
             PG.stage_input_revision(fresh, 1, entry("staged", 1))

    assert Enum.any?(events, &(&1["type"] == "conversation_source_advance"))
    assert PG.read(agent, @session) == {:error, :not_found}

    assert {:ok, committed} =
             PG.commit_revision(staged, 1, [%{"type" => "status", "status" => "active"}])

    assert InternalSession.status(committed.state) == :active
    assert {:ok, reloaded} = PG.read(agent, @session)
    assert InternalSession.conversation_sources(reloaded.state)["participant"]["seq"] == 1
    assert count(agent, "salix_session_inputs") == 1
    assert count(agent, "salix_session_input_dedupe") == 1
  end

  test "resident control commits do not reload the retained record history", %{agent: agent} do
    assert {:ok, initial} = PG.create(agent, @session, 1, %{created_at: 1})

    events =
      Enum.map(1..130, fn id ->
        %{"type" => "assistant", "message_id" => id, "content" => "record #{id}"}
      end)

    assert {:ok, resident} = PG.commit_revision(initial, 1, events)
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        fn _, _, metadata, _ ->
          send(owner, {:resident_query, metadata.query, metadata.params})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, changed} =
             PG.commit_revision(resident, 1, [%{"type" => "session_update", "name" => "renamed"}])

    assert InternalSession.get(changed.state, :name) == "renamed"

    assert InternalSession.get(changed.state, :activity_revision) ==
             InternalSession.get(resident.state, :activity_revision)

    queries = drain_queries([])
    assert queries != []

    refute Enum.any?(queries, fn {sql, _} ->
             String.starts_with?(sql, "SELECT * FROM salix_session_records")
           end)

    assert count(agent, "salix_session_records") == 130
  end

  test "paged reload keeps one snapshot while a later page changes", %{agent: agent} do
    assert {:ok, initial} = PG.create(agent, @session, 1, %{created_at: 1})
    events = Enum.map(1..130, &%{"type" => "assistant", "message_id" => &1, "content" => "old"})
    assert {:ok, _} = PG.commit_revision(initial, 1, events)
    {:ok, blocker} = Postgrex.start_link(pg_connection_opts())
    on_exit(fn -> if Process.alive?(blocker), do: GenServer.stop(blocker) end)
    Postgrex.query!(blocker, "BEGIN", [])
    Postgrex.query!(blocker, "LOCK TABLE salix_session_sources IN ACCESS EXCLUSIVE MODE", [])
    %{rows: [[blocker_pid]]} = Postgrex.query!(blocker, "SELECT pg_backend_pid()", [])
    reading = Task.async(fn -> PG.read(agent, @session) end)
    await_blocked_reader(blocker_pid)

    %{rows: [[payload]]} =
      Repo.query!(
        "SELECT payload FROM salix_session_records WHERE agent_id = $1 AND session_id = $2 AND seq = 130",
        [agent, @session]
      )

    new_payload = payload |> PGCodec.decode() |> Map.put(:content, "new") |> PGCodec.encode()

    Repo.query!(
      "UPDATE salix_session_records SET payload = $3 WHERE agent_id = $1 AND session_id = $2 AND seq = 130",
      [agent, @session, new_payload]
    )

    Postgrex.query!(blocker, "COMMIT", [])
    assert {:ok, snapshot} = settled_await(reading)
    assert List.last(InternalSession.get(snapshot.state, :messages)).content == "old"
    assert {:ok, current} = PG.read(agent, @session)
    assert List.last(InternalSession.get(current.state, :messages)).content == "new"
  end

  test "record reload crosses bounded pages with one revision", %{agent: agent} do
    assert {:ok, initial} = PG.create(agent, @session, 1, %{created_at: 1})

    events =
      Enum.map(
        1..130,
        &%{
          "type" => "assistant",
          "message_id" => &1,
          "content" => "record #{&1}",
          "created_at" => 2
        }
      )

    assert {:ok, committed} = PG.commit_revision(initial, 1, events)
    assert {:ok, loaded} = PG.read(agent, @session)
    assert loaded.revision == committed.revision
    assert Enum.map(InternalSession.get(loaded.state, :messages), & &1.id) == Enum.to_list(1..130)
  end

  defp fresh_record_reader(agent, name, mode, collection, field, payload) do
    args =
      {pg_connection_opts(), agent, @session, name, mode, collection, field, payload}
      |> PGCodec.encode()
      |> Base.encode64()

    code = """
    import ExUnit.Assertions
    alias SalixAgent.InternalSession
    alias SalixAgent.InternalSessionStore.{PG, PGCodec}
    alias SalixStore.{Repo, SessionHistoryRepo}
    [encoded] = System.argv()
    {config, agent, session, name, mode, collection, field, payload} =
      encoded |> Base.decode64!() |> :erlang.binary_to_term()
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Repo.start_link(config ++ [pool_size: 1, after_connect: nil])
    {:ok, _} = SessionHistoryRepo.start_link(config ++ [pool_size: 1, after_connect: nil])
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    assert_raise ArgumentError, fn -> PGCodec.decode(payload) end

    case mode do
      "read" ->
        {:ok, loaded} = PG.read(agent, session)
        [record] = InternalSession.get(loaded.state, collection)
        expected = :erlang.binary_to_term(payload)
        assert record[field] === expected[field]
        if collection == :async_results do
          {:ok, call} = InternalSession.lookup_async_call(loaded.state, "legacy-call")
          assert call["result"] === expected[field]
        end

      "history" ->
        {:ok, [record]} = PG.history_page(agent, session, 0, 1)
        expected = :erlang.binary_to_term(payload)
        assert record === SalixStore.ArchiveLog.shape(record.kind, 1, expected)

      "hydrate" ->
        # A compacted result is used only by its live terminal reference.
        %{columns: columns, rows: [values]} = Repo.query!(
          "SELECT * FROM salix_sessions WHERE agent_id=$1 AND session_id=$2", [agent, session])
        row = Map.new(Enum.zip(columns, values)) |> Map.put("compacted_seq", 1)
        [[context]] = Repo.query!(
          "SELECT payload FROM salix_session_contexts WHERE agent_id=$1 AND session_id=$2",
          [agent, session]).rows
        cold = [%{"kind" => "async_result", "seq" => 1, "payload" => payload}]
        {:ok, state} = PGCodec.state(row, context, [], [], [], [], cold)
        {:ok, call} = InternalSession.lookup_async_call(state, "legacy-call")
        expected = :erlang.binary_to_term(payload)
        assert call["result"] === expected[field]
    end
    IO.puts("fresh record reader passed")
    """

    paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        ["--erl", "+S 2:2"] ++ paths ++ ["-e", code, args],
        stderr_to_stdout: true
      )

    assert status == 0, "#{mode}: #{output}"
    assert output =~ "fresh record reader passed"
  end

  defp entry(id, seq) do
    %{
      source_message_id: id,
      payload: %{content: "body", created_at: 1},
      conversation_source: %{
        "conversation_id" => "conversation",
        "participant_id" => "participant",
        "generation" => @session,
        "start_seq" => 0,
        "seq" => seq
      }
    }
  end

  defp count(agent, table) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM #{table} WHERE agent_id = $1 AND session_id = $2", [
        agent,
        @session
      ])

    count
  end

  defp prepare_cut(agent) do
    assert {:ok, head} = PG.archive_head(agent, @session)
    assert {:ok, window} = PG.archive_window(head, {:error, :not_found}, 1_000_000)

    assert {:advance, event} =
             InternalSession.archive_publication(window.state, 1_000_000, fn
               {:read_segment, _, _, _} ->
                 {:error, :not_found}

               {:create_segment, _, _, _, _} ->
                 :created

               {:deterministic_etf, value} ->
                 :erlang.term_to_binary(value, [:deterministic, {:minor_version, 1}])
             end)

    assert {:ok, archive} = PG.prepare_archive(window, event)
    archive
  end

  defp pg_connection_opts do
    Repo.config() |> Keyword.take([:hostname, :port, :username, :password, :database])
  end

  defp drain_queries(acc) do
    receive do
      {:resident_query, sql, params} -> drain_queries([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp await_blocked_reader(blocker_pid) do
    assert settle_until(fn ->
             Repo.query!(
               "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid)))",
               [blocker_pid]
             ).rows == [[true]]
           end)
  end

  defp input(agent, session, epoch, entry) do
    resident =
      case PG.read(agent, session) do
        {:ok, resident} ->
          resident

        {:error, :not_found} ->
          attrs = InternalSession.initial_attributes(entry[:payload] || %{})
          state = InternalSession.new(agent, session, attrs)

          %Revision{
            state: state,
            revision: nil,
            cursor: InternalSession.start_revision(state, nil)
          }
      end

    PG.input_revision(resident, epoch, entry)
  end
end
