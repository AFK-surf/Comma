defmodule SalixAgent.InternalSessionStoreTest do
  use ExUnit.Case, async: false

  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State
  require SalixAgent.InternalSession

  alias SalixAgent.{
    InternalAgentRuntime,
    InternalSessionActor,
    InternalSessionStore,
    SessionStorageRevision,
    SessionWorkIndex,
    SessionWorkRecovery
  }

  alias SalixStore.{Codec, Keys, S3}

  @session_main "ses1_0000000000000000001"
  @session_a "ses1_0000000000000000002"
  @session_b "ses1_0000000000000000003"
  @session_hashed "ses1_0000000000000000004"
  @session_old "ses1_0000000000000000005"
  @session_seeded "ses1_0000000000000000006"

  setup do
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    :ok
  end

  test "runtime mutators require the target internal session actor owner" do
    agent_id = unique_id("agent")

    assert {:error, :not_session_owner} =
             InternalSessionStore.commit(agent_id, @session_main, [
               %{"type" => "session_created", "session_id" => @session_main}
             ])

    assert {:error, :not_session_owner} =
             InternalSessionStore.create(agent_id, @session_main, %{})

    assert {:error, :not_session_owner} =
             InternalSessionStore.seed(
               agent_id,
               InternalSession.new(agent_id, @session_main, %{})
             )

    assert {:error, :not_session_owner} =
             InternalSessionStore.ensure(agent_id, @session_main, %{})
  end

  test "revision reads bind the stored bytes and ETag and reject a misplaced snapshot" do
    agent_id = unique_id("agent")
    key = Keys.agent_internal_runtime_session(agent_id, @session_main)
    state = InternalSession.new(agent_id, @session_main, %{})
    body = state |> InternalSession.persist() |> Codec.compress_snapshot_etf()
    assert {:ok, _} = S3.put(key, body)
    assert {:ok, %{etag: etag}} = S3.get(key)
    assert {:ok, revision} = InternalSessionStore.read_revision(agent_id, @session_main)
    assert revision.etag == etag
    assert InternalSession.session_id(revision.state) == @session_main
    assert InternalSession.agent_id(revision.state) == agent_id
    refute InternalSession.revision_pending?(revision.cursor)

    wrong = InternalSession.new(unique_id("other-agent"), @session_main, %{})

    assert {:ok, _} =
             S3.put(key, wrong |> InternalSession.persist() |> Codec.compress_snapshot_etf())

    assert {:error, :session_agent_id_mismatch} =
             InternalSessionStore.read_revision(agent_id, @session_main)

    assert {:ok, _} = S3.put(Keys.agent_internal_runtime_session(agent_id, @session_a), body)

    assert {:error, :session_id_mismatch} =
             InternalSessionStore.read_revision(agent_id, @session_a)
  end

  test "a versioned write cannot move the snapshot to a different owner" do
    agent_id = unique_id("agent")
    assert {:ok, _} = InternalSessionStore.prepare_create(agent_id, @session_main, %{})

    assert {:ok, _} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, @session_main),
               nil
             )

    assert {:ok, revision} = InternalSessionStore.read_revision(agent_id, @session_main)
    key = Keys.agent_internal_runtime_session(agent_id, @session_main)
    assert {:ok, before} = S3.get(key)

    assert {:error, :session_key_mismatch} =
             InternalSessionStore.commit_revision(agent_id, @session_main, revision, [
               %{"type" => "session_stamp", "agent_id" => unique_id("other-agent")}
             ])

    assert {:ok, after_write} = S3.get(key)
    assert after_write.body == before.body
    assert after_write.etag == before.etag
    assert {:ok, stored} = InternalSessionStore.read(agent_id, @session_main)
    assert InternalSession.agent_id(stored) == agent_id
    assert InternalSession.session_id(stored) == @session_main
  end

  test "a new input uses create-if-absent and cannot acknowledge a losing payload" do
    agent_id = unique_id("agent")

    assert {:ok, _} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, @session_main),
               nil
             )

    assert {:ok, absent} = InternalSessionStore.read_or_new_revision(agent_id, @session_main)
    assert absent.etag == nil
    assert InternalSession.revision_pending?(absent.cursor)
    assert {:error, :not_found} = InternalSessionStore.read(agent_id, @session_main)

    losing = %{source_message_id: "same-source", payload: %{content: "losing payload"}}
    winning = %{source_message_id: "same-source", payload: %{content: "durable payload"}}

    assert {{:awaiting_fence, command}, _staged, nil} =
             InternalSession.Command.prepare(
               agent_id,
               @session_main,
               absent,
               :input,
               {losing, true}
             )

    assert {{:ok, :committed}, committed, nil} =
             InternalSession.Command.run(agent_id, @session_main, absent, :input, {winning, true})

    assert is_binary(committed.etag)
    refute InternalSession.revision_pending?(committed.cursor)

    assert {:error, :precondition_failed} =
             InternalSessionStore.fence_command(agent_id, @session_main, command)

    {rejected, {:rejected, :precondition_failed}} =
      InternalSession.command_step(command, :fence_reject, {:error, :precondition_failed})

    {failed, {:return, {:error, :precondition_failed}, nil}} =
      InternalSession.command_step(rejected, :next, nil)

    restored = InternalSessionStore.command_revision(failed)
    assert restored.etag == nil
    assert InternalSession.revision_pending?(restored.cursor)
    assert InternalSession.get(restored.state, :input_queue) == []
    assert {:ok, stored} = InternalSessionStore.read(agent_id, @session_main)

    assert [%{"payload" => %{"content" => "durable payload"}}] =
             InternalSession.get(stored, :input_queue)

    token = InternalSession.work_index_token(stored)

    assert {:ok, %{records: [%{"token" => ^token}], next: nil}} =
             SessionWorkIndex.list_discovery()
  end

  test "a refused fresh birth leaves no session or work-index candidate" do
    agent_id = unique_id("agent")

    assert {:ok, _} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, @session_main),
               nil
             )

    assert {:ok, :external} = SalixAgent.SessionBirth.claim(agent_id, @session_main, :external)

    assert {:error, :session_born_external} =
             InternalSessionStore.read_or_new_revision(agent_id, @session_main)

    assert {:error, :not_found} = InternalSessionStore.read(agent_id, @session_main)
    assert %{rows: [[0]]} = SalixStore.Repo.query!("SELECT count(*) FROM session_work_candidates")
  end

  test "a multi-write fence persists the working revision once and rejects its stale base" do
    agent_id = unique_id("agent")
    assert {:ok, _} = InternalSessionStore.prepare_create(agent_id, @session_main, %{})

    assert {:ok, _} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, @session_main),
               nil
             )

    assert {:ok, base} = InternalSessionStore.read_revision(agent_id, @session_main)

    events = [
      %{"type" => "status", "session_id" => @session_main, "status" => "active"},
      %{
        "type" => "activity_status",
        "session_id" => @session_main,
        "activity_status" => "thinking"
      }
    ]

    assert {:ok, first} = InternalSessionStore.write_revision(base, Enum.take(events, 1))
    assert {:ok, working} = InternalSessionStore.write_revision(first, Enum.drop(events, 1))
    expected = InternalSession.export(working.state)
    # Host projections cannot discard a staged write or replace its CAS base.
    stale_view = %{working | state: base.state, etag: "unrelated", pending: nil}

    assert {:ok, committed} =
             InternalSessionStore.durable_fence(agent_id, @session_main, stale_view)

    actual = InternalSession.export(committed.state)

    for field <- [:messages, :events, :async_results, :last_seq, :status, :activity_status] do
      assert Map.fetch!(actual, field) == Map.fetch!(expected, field)
    end

    # Compare states, not snapshot bytes: the kernel encodes equal states with
    # a map key order that depends on how each state was built.
    assert {:ok, persisted} = InternalSessionStore.read(agent_id, @session_main)
    assert stored_value(persisted) == stored_value(committed.state)

    assert {:error, :precondition_failed} =
             InternalSessionStore.durable_fence(agent_id, @session_main, working)

    assert {:ok, unchanged} = InternalSessionStore.read(agent_id, @session_main)
    assert stored_value(unchanged) == stored_value(committed.state)
  end

  test "an owned revision commits without re-reading and invalidates on conflict" do
    agent_id = unique_id("agent")
    session_key = Keys.agent_internal_runtime_session(agent_id, @session_main)

    assert {:ok, _session} =
             InternalSessionStore.prepare_create(agent_id, @session_main, %{})

    assert {:ok, _registry_value} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, @session_main),
               nil
             )

    assert {:ok, revision} = InternalSessionStore.read_revision(agent_id, @session_main)
    :ok = S3.Fake.reset_read_log()

    assert {:ok, written} =
             InternalSessionStore.write_revision(
               revision,
               [%{"type" => "status", "session_id" => @session_main, "status" => "active"}]
             )

    assert written.etag == revision.etag
    assert InternalSession.status(written.state) == :active
    assert {:ok, durable} = InternalSessionStore.read(agent_id, @session_main)
    assert InternalSession.status(durable) == InternalSession.status(revision.state)
    :ok = S3.Fake.reset_read_log()

    assert {:ok, fence} =
             InternalSessionStore.start_durable_fence(agent_id, @session_main, written)

    assert InternalSession.status(written.state) == :active
    assert {:ok, committed_revision} = InternalSessionStore.await_durable_fence(fence)

    refute committed_revision.etag == revision.etag
    assert InternalSession.status(committed_revision.state) == :active
    refute {:get, session_key} in S3.Fake.read_log()

    assert {:ok, %{body: body, etag: etag}} = S3.get(session_key)
    externally_updated = %{Codec.decode_snapshot(body) | name: "external writer won"}

    assert {:ok, _} =
             S3.put(
               session_key,
               Codec.encode_snapshot(externally_updated),
               if_match: etag
             )

    assert {:error, :precondition_failed} =
             InternalSessionStore.commit_revision(
               agent_id,
               @session_main,
               committed_revision,
               [%{"type" => "status", "session_id" => @session_main, "status" => "idle"}],
               on_conflict: :error
             )

    :ok = S3.Fake.reset_read_log()

    assert {:ok, rebased_revision} =
             InternalSessionStore.commit_revision(
               agent_id,
               @session_main,
               committed_revision,
               [%{"type" => "status", "session_id" => @session_main, "status" => "idle"}]
             )

    assert {:get, session_key} in S3.Fake.read_log()
    assert InternalSession.status(rebased_revision.state) == :idle
    assert InternalSession.get(rebased_revision.state, :name) == "external writer won"
  end

  test "input receipts preserve integer identities across reload and retry" do
    agent_id = unique_id("agent")
    assert {:ok, _} = InternalSessionStore.prepare_create(agent_id, @session_main, %{})

    assert {:ok, _} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, @session_main),
               nil
             )

    assert {:ok, base} = InternalSessionStore.read_revision(agent_id, @session_main)
    integer = %{source_message_id: 123, payload: %{content: "integer identity", no_wake: true}}
    binary = %{source_message_id: "123", payload: %{content: "binary identity", no_wake: true}}

    assert {{:ok, :committed}, first, nil} =
             InternalSession.Command.run(agent_id, @session_main, base, :input, {integer, false})

    assert {{:ok, :committed}, _, nil} =
             InternalSession.Command.run(agent_id, @session_main, first, :input, {binary, false})

    assert {:ok, reloaded} = InternalSessionStore.read_revision(agent_id, @session_main)
    retry = %{integer | payload: %{content: "retry must not replace original", no_wake: true}}

    assert {{:ok, :duplicate}, confirmed, nil} =
             InternalSession.Command.run(
               agent_id,
               @session_main,
               reloaded,
               :input,
               {retry, false}
             )

    assert confirmed.etag == reloaded.etag
    assert {:ok, durable} = InternalSessionStore.read(agent_id, @session_main)

    assert [
             %{"dedupe_key" => 123, "payload" => %{"content" => "integer identity"}},
             %{"dedupe_key" => "123", "payload" => %{"content" => "binary identity"}}
           ] = InternalSession.get(durable, :input_queue)
  end

  test "input admission detects normalized identity aliases in both directions at capacity" do
    previous_limit = Application.fetch_env(:salix_agent, :session_input_queue_limit)
    Application.put_env(:salix_agent, :session_input_queue_limit, 1)

    on_exit(fn ->
      case previous_limit do
        {:ok, value} -> Application.put_env(:salix_agent, :session_input_queue_limit, value)
        :error -> Application.delete_env(:salix_agent, :session_input_queue_limit)
      end
    end)

    for {first_id, retry_id} <- [{%{"id" => 123}, %{id: 123}}, {%{id: 123}, %{"id" => 123}}] do
      agent_id = unique_id("agent")
      assert {:ok, _} = InternalSessionStore.prepare_create(agent_id, @session_main, %{})

      assert {:ok, _} =
               Registry.register(
                 SalixAgent.Registry,
                 InternalSessionActor.key(agent_id, @session_main),
                 nil
               )

      assert {:ok, base} = InternalSessionStore.read_revision(agent_id, @session_main)
      original = %{source_message_id: first_id, payload: %{content: "original"}}
      retry = %{source_message_id: retry_id, payload: %{content: "changed retry"}}

      assert {{:ok, :committed}, accepted, nil} =
               InternalSession.Command.run(
                 agent_id,
                 @session_main,
                 base,
                 :input,
                 {original, false}
               )

      assert {{:ok, :duplicate}, confirmed, nil} =
               InternalSession.Command.run(
                 agent_id,
                 @session_main,
                 accepted,
                 :input,
                 {retry, false}
               )

      assert confirmed.etag == accepted.etag
      assert {:ok, durable} = InternalSessionStore.read(agent_id, @session_main)

      assert [%{"payload" => %{"content" => "original"}}] =
               InternalSession.get(durable, :input_queue)
    end
  end

  test "accepted inputs survive a failed materialization fence, compaction, sealing, and reload" do
    agent_id = unique_id("agent")
    assert {:ok, _} = InternalSessionStore.prepare_create(agent_id, @session_main, %{})

    assert {:ok, _} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, @session_main),
               nil
             )

    assert {:ok, base} = InternalSessionStore.read_revision(agent_id, @session_main)

    first = %{
      source_message_id: "accepted-first",
      payload: %{
        content: "保留这个请求 🌱",
        trusted_attachment_refs: [%{type: "file", path: "notes/brief.txt"}],
        trusted_origin: %{source: "conversation", message_id: "original-message"},
        workflow_context: %{task_id: "task", gate: %{attempt: 2}},
        billing_context: %{account_id: "account", source: "original-request"},
        provider_reply_obligation: %{
          provider: "slack",
          connect_id: "connect",
          channel: "channel",
          thread_ts: "thread"
        }
      }
    }

    second = %{source_message_id: "accepted-later", payload: %{content: "later input"}}

    assert {{:ok, :committed}, accepted, nil} =
             InternalSession.Command.run(agent_id, @session_main, base, :input, {first, false})

    assert {:ok, durable} = InternalSessionStore.read(agent_id, @session_main)

    assert [%{"payload" => %{"content" => "保留这个请求 🌱"}}] =
             InternalSession.get(durable, :input_queue)

    [queued] = InternalSession.get(durable, :input_queue)
    input_fact = {queued["queue_id"], queued["kind"], queued["dedupe_key"], queued["payload"]}

    {events, true, hwm} = InternalSession.materialize_pending_input_events(accepted.state)
    assert {:ok, working} = InternalSessionStore.write_revision(accepted, events, hwm: hwm)
    assert InternalSession.get(working.state, :input_queue) == []

    # A newer committed input makes the old materialization plan stale.
    assert {{:ok, :committed}, newer, nil} =
             InternalSession.Command.run(
               agent_id,
               @session_main,
               accepted,
               :input,
               {second, false}
             )

    assert {:error, :precondition_failed} =
             InternalSessionStore.durable_fence(agent_id, @session_main, working)

    assert {:ok, reloaded} = InternalSessionStore.read_revision(agent_id, @session_main)
    assert stored_value(reloaded.state) == stored_value(newer.state)

    assert Enum.map(InternalSession.get(reloaded.state, :input_queue), & &1["dedupe_key"]) ==
             ["accepted-first", "accepted-later"]

    compaction = %{
      "type" => "compaction",
      "session_id" => @session_main,
      "summary_sequence" => 1,
      "compacted_through" => 0,
      "summary" => "Earlier context"
    }

    assert {:ok, compacted} =
             InternalSessionStore.commit_revision(
               agent_id,
               @session_main,
               reloaded,
               [compaction, %{compaction | "summary" => "stale replacement"}],
               on_conflict: :error
             )

    assert {:ok, after_restart} = InternalSessionStore.read_revision(agent_id, @session_main)

    assert stored_value(after_restart.state) == stored_value(compacted.state)

    assert InternalSession.get(after_restart.state, :summary) == "Earlier context"

    {batch, true, watermark} =
      InternalSession.materialize_pending_input_events(after_restart.state, 1)

    assert {:ok, materialized} =
             InternalSessionStore.commit_revision(
               agent_id,
               @session_main,
               after_restart,
               batch,
               hwm: watermark,
               on_conflict: :error
             )

    assert {:ok, final} = InternalSessionStore.read(agent_id, @session_main)
    assert stored_value(final) == stored_value(materialized.state)

    assert [%{source_message_id: "accepted-first", content: "保留这个请求 🌱"}] =
             InternalSession.get(final, :messages)

    [record] = InternalSession.get(final, :messages)
    assert record[:accepted_input] == input_fact

    assert [%{"dedupe_key" => "accepted-later", "payload" => %{"content" => "later input"}}] =
             InternalSession.get(final, :input_queue)

    assert InternalSession.get(final, :queue_ack_id) == 1
    assert InternalSession.get(final, :last_ack_message_id) == 0

    assert {{:ok, :duplicate}, duplicate_revision, nil} =
             InternalSession.Command.run(
               agent_id,
               @session_main,
               materialized,
               :input,
               {first, false}
             )

    assert duplicate_revision.etag == materialized.etag

    assert {:ok, _} =
             InternalSessionStore.commit_revision(
               agent_id,
               @session_main,
               materialized,
               [%{compaction | "summary_sequence" => 2, "compacted_through" => record.id}],
               on_conflict: :error
             )

    assert {:ok, :archived} = InternalSessionStore.archive_compacted(agent_id, @session_main)
    assert {:ok, sealed} = InternalSessionStore.read(agent_id, @session_main)
    assert InternalSession.get(sealed, :messages) == []
    assert {:ok, archived} = InternalSessionStore.archived_records(agent_id, sealed)
    archived_input = Enum.find(archived, &(&1.kind == "message"))
    assert archived_input.data["accepted_input"] == input_fact
    assert [%{"dedupe_key" => "accepted-later"}] = InternalSession.get(sealed, :input_queue)

    assert {:ok, history} =
             InternalAgentRuntime.get_session_messages(agent_id, @session_main,
               history: {:tail, 1}
             )

    assert [%{"content" => "保留这个请求 🌱"} = message] = history["messages"]
    refute Map.has_key?(message, "accepted_input")
    assert {:ok, _json} = Jason.encode(history)
  end

  test "a later delivery cannot retire accepted work through embedded events" do
    agent_id = unique_id("agent")
    assert {:ok, _} = InternalSessionStore.prepare_create(agent_id, @session_main, %{})

    assert {:ok, _} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, @session_main),
               nil
             )

    first = %{source_message_id: "preserve-original", payload: %{content: "original work"}}

    assert {:ok, :committed} =
             InternalSessionActor.stage_delivery_in_owner(agent_id, @session_main, first)

    assert {:ok, accepted} = InternalSessionStore.read(agent_id, @session_main)

    assert [%{"payload" => %{"content" => "original work"}}] =
             InternalSession.get(accepted, :input_queue)

    second = %{
      source_message_id: "later-delivery",
      payload: %{
        content: "later work",
        events: [%{"type" => "queue_consume", "queue_id" => 1}]
      }
    }

    assert {:error, :invalid_delivery_events} =
             InternalSessionActor.stage_delivery_in_owner(agent_id, @session_main, second)

    assert {:ok, durable} = InternalSessionStore.read(agent_id, @session_main)
    assert InternalSession.get(durable, :messages) == []
    assert InternalSession.get(durable, :segment_catalog) == []

    assert Enum.any?(InternalSession.get(durable, :input_queue), fn item ->
             item["payload"]["source_message_id"] == "preserve-original" and
               item["payload"]["content"] == "original work"
           end)

    assert stored_value(durable) == stored_value(accepted)

    clean = put_in(second, [:payload, :events], [])

    assert {:ok, :committed} =
             InternalSessionActor.stage_delivery_in_owner(agent_id, @session_main, clean)

    assert {:ok, retried} = InternalSessionStore.read(agent_id, @session_main)
    assert length(InternalSession.get(retried, :input_queue)) == 2
  end

  defp stored_value(session), do: session |> InternalSession.persist() |> Codec.decode_snapshot()

  test "an embedded append cannot replace the main delivery under its source identity" do
    agent_id = unique_id("agent")
    assert {:ok, _} = InternalSessionStore.prepare_create(agent_id, @session_main, %{})

    assert {:ok, _} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, @session_main),
               nil
             )

    entry = %{
      source_message_id: "main-source",
      payload: %{
        content: "main work",
        events: [
          %{
            "type" => "queue_append",
            "kind" => "user_message",
            "dedupe_key" => "main-source",
            "payload" => %{"content" => "replacement work"}
          }
        ]
      }
    }

    result = InternalSessionActor.stage_delivery_in_owner(agent_id, @session_main, entry)
    assert {:ok, durable} = InternalSessionStore.read(agent_id, @session_main)
    queue = InternalSession.get(durable, :input_queue)

    if result == {:ok, :committed} do
      assert Enum.any?(queue, &(&1["payload"]["content"] == "main work")),
             "committed delivery lost its payload: #{inspect(queue)}"
    end

    assert {:error, :invalid_delivery_events} = result
    assert queue == []

    corrected = put_in(entry, [:payload, :events, Access.at(0), "dedupe_key"], "context-source")

    assert {:ok, :committed} =
             InternalSessionActor.stage_delivery_in_owner(agent_id, @session_main, corrected)

    assert {:ok, retried} = InternalSessionStore.read(agent_id, @session_main)

    assert Enum.map(InternalSession.get(retried, :input_queue), & &1["payload"]["content"]) ==
             ["replacement work", "main work"]
  end

  test "UTF-8 repair cannot make an embedded append replace the main delivery" do
    source = "main-" <> <<0xFFFD::utf8>>

    for embedded <- [
          %{
            "type" => "queue_append",
            "kind" => "user_message",
            "dedupe_key" => "main-" <> <<0xFF>>,
            "payload" => %{"content" => "replacement work"}
          },
          %{
            "type" => "queue_append",
            "kind" => "user_message",
            "dedupe_key" => "context-source",
            "payload" =>
              MapSet.new([
                {"content", "replacement work"},
                {"source_message_id", "main-" <> <<0xFF>>}
              ])
          }
        ] do
      agent_id = unique_id("agent")
      assert {:ok, _} = InternalSessionStore.prepare_create(agent_id, @session_main, %{})

      assert {:ok, _} =
               Registry.register(
                 SalixAgent.Registry,
                 InternalSessionActor.key(agent_id, @session_main),
                 nil
               )

      entry = %{
        source_message_id: source,
        payload: %{
          content: "main work",
          events: [embedded]
        }
      }

      result = InternalSessionActor.stage_delivery_in_owner(agent_id, @session_main, entry)
      assert {:ok, durable} = InternalSessionStore.read(agent_id, @session_main)
      queue = InternalSession.get(durable, :input_queue)

      if result == {:ok, :committed} do
        assert Enum.any?(queue, &(&1["payload"]["content"] == "main work")),
               "UTF-8 repair removed committed main work: #{inspect(queue)}"
      end

      assert {:error, :invalid_delivery_events} = result
      assert queue == []

      assert {:ok, base} = InternalSessionStore.read_revision(agent_id, @session_main)

      assert {{:error, :invalid_delivery_events}, prepared, nil} =
               InternalSession.Command.prepare(
                 agent_id,
                 @session_main,
                 base,
                 :input,
                 {entry, false}
               )

      assert stored_value(prepared.state) == stored_value(base.state)

      corrected =
        put_in(entry, [:payload, :events], [
          %{
            "type" => "queue_append",
            "kind" => "user_message",
            "dedupe_key" => "context-source",
            "payload" => %{"content" => "replacement work"}
          }
        ])

      assert {:ok, :committed} =
               InternalSessionActor.stage_delivery_in_owner(agent_id, @session_main, corrected)

      assert {:ok, retried} = InternalSessionStore.read(agent_id, @session_main)

      assert Enum.map(InternalSession.get(retried, :input_queue), & &1["payload"]["content"]) ==
               ["replacement work", "main work"]
    end
  end

  test "delivery cannot change the owner of accepted work" do
    agent_id = unique_id("agent")
    assert {:ok, _} = InternalSessionStore.prepare_create(agent_id, @session_main, %{})

    assert {:ok, _} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, @session_main),
               nil
             )

    entry = %{
      source_message_id: "owner-stamp-input",
      payload: %{
        content: "main work",
        events: [%{"type" => "session_stamp", "agent_id" => "another-agent"}]
      }
    }

    result = InternalSessionActor.stage_delivery_in_owner(agent_id, @session_main, entry)

    if result == {:ok, :committed} do
      loaded = InternalSessionStore.read(agent_id, @session_main)

      assert match?({:ok, _}, loaded),
             "committed input is unreadable by its owning Agent: #{inspect(loaded)}"
    end

    assert {:error, :invalid_delivery_events} = result
    assert {:ok, unchanged} = InternalSessionStore.read(agent_id, @session_main)
    assert InternalSession.agent_id(unchanged) == agent_id
    assert InternalSession.get(unchanged, :input_queue) == []

    corrected = put_in(entry, [:payload, :events], [])

    assert {:ok, :committed} =
             InternalSessionActor.stage_delivery_in_owner(agent_id, @session_main, corrected)

    assert {:ok, restored} = InternalSessionStore.read(agent_id, @session_main)
    assert InternalSession.agent_id(restored) == agent_id
    assert [item] = InternalSession.get(restored, :input_queue)
    assert item["payload"]["content"] == "main work"
  end

  test "a revision marker failure preserves the current recovery candidate" do
    agent_id = unique_id("agent")
    work_key = Keys.agent_session_work_index(agent_id, "internal", @session_main)

    assert {:ok, current} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{"type" => "session_created", "session_id" => @session_main},
               %{
                 "type" => "queue_append",
                 "session_id" => @session_main,
                 "kind" => "user_message",
                 "dedupe_key" => "preserved-recovery-candidate",
                 "payload" => %{
                   "source_message_id" => "preserved-recovery-candidate",
                   "content" => "wake"
                 }
               }
             ])

    assert {:ok, _registry_value} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, @session_main),
               nil
             )

    assert {:ok, revision} = InternalSessionStore.read_revision(agent_id, @session_main)

    assert InternalSession.work_index_token(revision.state) ==
             InternalSession.work_index_token(current)

    :ok = S3.Fake.set_fault({:fail, 503, :put, work_key})

    assert {:error, _reason} =
             InternalSessionStore.commit_revision(
               agent_id,
               @session_main,
               revision,
               [%{"type" => "status", "session_id" => @session_main, "status" => "active"}],
               [on_conflict: :error],
               fn -> :ok end
             )

    assert {:ok, %{records: [%{"token" => token}], next: nil}} =
             SessionWorkIndex.list_discovery()

    assert token == InternalSession.work_index_token(current)
  end

  test "prepare commit rejects invalid queue events before applying reducer" do
    agent_id = unique_id("agent")

    assert {:error, {:invalid_queue_kind, "unexpected"}} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{"type" => "session_created", "session_id" => @session_main},
               %{
                 "type" => "queue_append",
                 "session_id" => @session_main,
                 "kind" => "unexpected",
                 "payload" => %{}
               }
             ])

    assert {:error, :runtime_message_identity_required} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{"type" => "session_created", "session_id" => @session_main},
               %{
                 "type" => "queue_append",
                 "session_id" => @session_main,
                 "kind" => "runtime_message",
                 "payload" => %{"type" => "tool_call_completed"}
               }
             ])

    assert {:error, {:invalid_internal_session_status, "queued"}} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{"type" => "session_created", "session_id" => @session_main},
               %{"type" => "status", "session_id" => @session_main, "status" => "queued"}
             ])

    assert {:error, :not_found} = InternalSessionStore.read(agent_id, @session_main)
  end

  test "visible reply exhaustion remains identifiable as message-recoverable activity" do
    agent_id = unique_id("agent")

    assert {:ok, _session} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{"type" => "session_created", "session_id" => @session_main},
               %{
                 "type" => "visible_reply_repair",
                 "session_id" => @session_main,
                 "status" => "exhausted",
                 "attempts" => 2
               }
             ])

    assert {:ok,
            %{
              "state" => "error",
              "issue" => "visible_reply_repair_exhausted"
            }} = InternalAgentRuntime.get_session_activity(agent_id, @session_main)
  end

  test "runtime activity preserves the durable wait reason" do
    agent_id = unique_id("agent")

    assert {:ok, _session} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{"type" => "session_created", "session_id" => @session_main},
               %{
                 "type" => "wait_set",
                 "session_id" => @session_main,
                 "wait" => %{"wait_id" => "approval", "reason" => "user approval"}
               }
             ])

    assert {:ok,
            %{
              "state" => "active",
              "status" => "is waiting: user approval",
              "wait" => %{"reason" => "user approval"}
            }} = InternalAgentRuntime.get_session_activity(agent_id, @session_main)
  end

  test "runtime activity retains a direct source after its hot message is archived" do
    agent_id = unique_id("agent")

    assert {:ok, paused} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{"type" => "session_created", "session_id" => @session_main}
             ])

    live =
      InternalSession.apply_events(paused, [
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => 1,
          "role" => "user",
          "content" => "review this",
          "source_message_id" => "slack-direct-source"
        }
      ])

    source_key = InternalSession.current_activation_key(live)

    parked =
      InternalSession.apply_events(live, [
        %{
          "type" => "session_event",
          "event_id" => "runaway-source-scope",
          "kind" => "runaway_unsettled_round",
          "source" => "internal_runtime",
          "event" => %{"activation_key" => source_key, "assistant_message_id" => 2}
        }
      ])

    last_seq = InternalSession.get(parked, :last_seq)

    archived = %State{
      InternalSession.export(parked)
      | storage_format: 2,
        status: :active,
        messages: [],
        events: [],
        compacted_seq: last_seq,
        archived_through: last_seq
    }

    key = Keys.agent_internal_runtime_session(agent_id, @session_main)

    assert {:ok, _} =
             S3.put(key, Codec.encode_snapshot(archived))

    assert {:ok,
            %{
              "state" => "active",
              "_active_source_message_ids" => ["slack-direct-source"]
            }} = InternalAgentRuntime.get_session_activity(agent_id, @session_main)
  end

  test "malformed waits fail closed before durable state or discovery is written" do
    agent_id = unique_id("agent")

    invalid_waits = [
      %{"wait_id" => "string-deadline", "deadline_ms" => "1000"},
      %{"wait_id" => "zero-deadline", "deadline_ms" => 0},
      %{"wait_id" => "negative-deadline", "deadline_ms" => -1},
      %{"wait_id" => "nil-deadline", "deadline_ms" => nil}
    ]

    for wait <- invalid_waits do
      assert {:error, :invalid_wait} =
               InternalSessionStore.prepare_commit(agent_id, @session_main, [
                 %{"type" => "session_created", "session_id" => @session_main},
                 %{"type" => "wait_set", "session_id" => @session_main, "wait" => wait}
               ])

      assert {:error, :not_found} = InternalSessionStore.read(agent_id, @session_main)
      assert {:ok, []} = SessionWorkIndex.list(agent_id)
      assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()

      assert {:ok, %{records: [], next: nil}} =
               SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))
    end
  end

  test "commit timestamps lifecycle changes without promoting queued or tool work" do
    agent_id = unique_id("agent")

    assert {:ok, queued} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{"type" => "session_created", "session_id" => @session_main},
               %{
                 "type" => "queue_append",
                 "session_id" => @session_main,
                 "kind" => "user_message",
                 "dedupe_key" => "input-status",
                 "payload" => %{"source_message_id" => "input-status", "content" => "work"}
               },
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => @session_main,
                 "tool_call_id" => "tool-status",
                 "status" => "running"
               }
             ])

    assert InternalSession.derived_state(queued) == :queued
    assert InternalSession.status(queued) == :idle
    assert InternalSession.activity_status(queued) == :paused
    assert is_integer(InternalSession.get(queued, :activity_status_updated_at))

    assert {:ok, running} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{"type" => "status", "session_id" => @session_main, "status" => "active"}
             ])

    assert InternalSession.status(running) == :active
    assert InternalSession.activity_status(running) == :thinking

    assert InternalSession.get(running, :activity_status_updated_at) >=
             InternalSession.get(queued, :activity_status_updated_at)

    assert {:ok, executing} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{
                 "type" => "activity_status",
                 "session_id" => @session_main,
                 "activity_status" => "execution"
               }
             ])

    assert InternalSession.activity_status(executing) == :execution

    assert InternalSession.get(executing, :activity_status_updated_at) >=
             InternalSession.get(running, :activity_status_updated_at)
  end

  test "activity revision distinguishes same-timestamp paused ABA and ignores no-op writes" do
    agent_id = unique_id("agent")

    assert {:ok, paused} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{
                 "type" => "session_created",
                 "session_id" => @session_main,
                 "created_at" => 101
               }
             ])

    assert InternalSession.is_session(paused)

    assert {:ok, active} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{
                 "type" => "status",
                 "session_id" => @session_main,
                 "status" => "active",
                 "created_at" => 101
               }
             ])

    assert {:ok, restopped} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{
                 "type" => "status",
                 "session_id" => @session_main,
                 "status" => "idle",
                 "created_at" => 101
               }
             ])

    assert InternalSession.get(paused, :activity_status_updated_at) == 101
    assert InternalSession.get(active, :activity_status_updated_at) == 101
    assert InternalSession.get(restopped, :activity_status_updated_at) == 101

    revisions =
      Enum.map([paused, active, restopped], &InternalSession.get(&1, :activity_revision))

    assert Enum.all?(revisions, &(is_binary(&1) and &1 != ""))
    assert length(Enum.uniq(revisions)) == 3

    assert {:ok, metadata_only} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{
                 "type" => "session_update",
                 "session_id" => @session_main,
                 "name" => "Renamed without changing activity",
                 "updated_at" => 102
               }
             ])

    assert InternalSession.get(metadata_only, :activity_revision) ==
             InternalSession.get(restopped, :activity_revision)
  end

  test "a rolling old internal writer exposes and promotes its fresh storage revision" do
    agent_id = unique_id("agent")

    assert {:ok, paused} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{
                 "type" => "session_created",
                 "session_id" => @session_main,
                 "created_at" => 101
               }
             ])

    legacy_storage_revision = SessionStorageRevision.new()

    legacy = %State{
      InternalSession.export(paused)
      | activity_revision: nil,
        storage_revision: legacy_storage_revision
    }

    key = Keys.agent_internal_runtime_session(agent_id, @session_main)

    assert {:ok, _} =
             S3.put(key, Codec.encode_snapshot(legacy))

    assert {:ok, %{"state" => "stopped", "version" => ^legacy_storage_revision}} =
             InternalAgentRuntime.get_session_activity(agent_id, @session_main)

    assert {:ok, promoted} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{
                 "type" => "session_update",
                 "session_id" => @session_main,
                 "name" => "New writer adopts the fallback",
                 "updated_at" => 102
               }
             ])

    assert InternalSession.get(promoted, :activity_revision) == legacy_storage_revision
    refute InternalSession.storage_revision(promoted) == legacy_storage_revision
  end

  test "commits one session without creating an agent-global session map" do
    agent_id = unique_id("agent")

    assert {:ok, session} =
             InternalSessionStore.prepare_commit(
               agent_id,
               @session_main,
               [
                 %{"type" => "session_created", "session_id" => @session_main, "created_at" => 1},
                 %{
                   "type" => "delivery",
                   "from_queue" => true,
                   "session_id" => @session_main,
                   "message_id" => 1,
                   "source_message_id" => "src-1",
                   "content" => "hello"
                 }
               ],
               hwm: 1
             )

    assert InternalSession.agent_id(session) == agent_id
    assert InternalSession.session_id(session) == @session_main
    assert InternalSession.next_message_id(session) == 2
    assert [%{id: 1, role: "user", content: "hello"}] = InternalSession.get(session, :messages)
  end

  test "message id and input dedupe are session-local" do
    agent_id = unique_id("agent")

    for session_id <- [@session_a, @session_b] do
      assert {:ok, _} =
               InternalSessionStore.prepare_commit(
                 agent_id,
                 session_id,
                 [
                   %{"type" => "session_created", "session_id" => session_id},
                   %{
                     "type" => "queue_append",
                     "session_id" => session_id,
                     "kind" => "user_message",
                     "dedupe_key" => "same-source",
                     "payload" => %{"source_message_id" => "same-source", "content" => session_id}
                   },
                   %{
                     "type" => "queue_append",
                     "session_id" => session_id,
                     "kind" => "user_message",
                     "dedupe_key" => "same-source",
                     "payload" => %{
                       "source_message_id" => "same-source",
                       "content" => "duplicate"
                     }
                   }
                 ]
               )
    end

    assert {:ok, a} = InternalSessionStore.read(agent_id, @session_a)
    assert {:ok, b} = InternalSessionStore.read(agent_id, @session_b)

    assert Enum.map(InternalSession.get(a, :input_queue), & &1["payload"]["content"]) ==
             [@session_a]

    assert Enum.map(InternalSession.get(b, :input_queue), & &1["payload"]["content"]) ==
             [@session_b]

    assert InternalSession.get(a, :next_queue_id) == 2
    assert InternalSession.get(b, :next_queue_id) == 2
    assert MapSet.member?(InternalSession.get(a, :input_dedupe), "same-source")
    assert MapSet.member?(InternalSession.get(b, :input_dedupe), "same-source")
  end

  test "concurrent queue appends allocate monotonic session-local queue ids" do
    agent_id = unique_id("agent")
    session_id = @session_main

    assert {:ok, _} = InternalSessionStore.prepare_create(agent_id, session_id, %{})

    source_ids = for n <- 1..24, do: "src-#{n}"

    results =
      source_ids
      |> Task.async_stream(
        fn source_id ->
          InternalSessionStore.prepare_commit(agent_id, session_id, [
            %{
              "type" => "queue_append",
              "session_id" => session_id,
              "kind" => "user_message",
              "dedupe_key" => source_id,
              "payload" => %{"source_message_id" => source_id, "content" => source_id}
            }
          ])
        end,
        max_concurrency: 12,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, s} when InternalSession.is_session(s), &1))
    assert {:ok, session} = InternalSessionStore.read(agent_id, session_id)

    queue = InternalSession.get(session, :input_queue)
    assert Enum.map(queue, & &1["queue_id"]) == Enum.to_list(1..24)
    assert Enum.sort(Enum.map(queue, & &1["dedupe_key"])) == Enum.sort(source_ids)
    assert InternalSession.get(session, :next_queue_id) == 25
  end

  test "list loads state body to recover the hashed session id" do
    agent_id = unique_id("agent")

    assert {:ok, _} =
             InternalSessionStore.prepare_create(agent_id, @session_hashed, %{
               "name" => "Hashed"
             })

    assert {:ok, sessions} = InternalSessionStore.list(agent_id)

    assert Enum.map(sessions, &InternalSession.session_id/1) == [@session_hashed]
    assert Enum.map(sessions, &InternalSession.get(&1, :name)) == ["Hashed"]
  end

  test "loads older state snapshots that lack newly added struct fields" do
    agent_id = unique_id("agent")
    session_id = @session_old

    old_state =
      agent_id
      |> InternalSession.new(session_id, %{"name" => "Old State"})
      |> InternalSession.export()
      |> Map.delete(:compaction_failure)

    assert {:ok, _} =
             S3.put(
               Keys.agent_internal_runtime_session(agent_id, session_id),
               Codec.encode_snapshot(old_state)
             )

    assert {:ok, loaded} = InternalSessionStore.read(agent_id, session_id)
    assert InternalSession.get(loaded, :name) == "Old State"
    assert InternalSession.get(loaded, :compaction_failure) == nil

    assert {:ok, [listed]} = InternalSessionStore.list(agent_id)
    assert InternalSession.session_id(listed) == session_id
    assert InternalSession.get(listed, :compaction_failure) == nil
  end

  test "idempotent session_created does not clear pending input queue" do
    agent_id = unique_id("agent")

    events = [
      %{"type" => "session_created", "session_id" => @session_main},
      %{
        "type" => "queue_append",
        "session_id" => @session_main,
        "kind" => "user_message",
        "dedupe_key" => "src-1",
        "payload" => %{"source_message_id" => "src-1", "content" => "hello"}
      }
    ]

    assert {:ok, queued} = InternalSessionStore.prepare_commit(agent_id, @session_main, events)
    assert InternalSession.status(queued) == :idle
    assert InternalSession.derived_state(queued) == :queued

    # A racing replay of the same create+queue append must be harmless. The
    # duplicate input is skipped by source id, and session_created must not reset
    # the pending queue.
    assert {:ok, still_queued} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, events)

    assert InternalSession.status(still_queued) == :idle
    assert InternalSession.derived_state(still_queued) == :queued

    assert Enum.map(InternalSession.get(still_queued, :input_queue), & &1["dedupe_key"]) ==
             ["src-1"]
  end

  test "non-stable commit writes one per-session work index object" do
    agent_id = unique_id("agent")

    assert {:ok, session} =
             InternalSessionStore.prepare_commit(
               agent_id,
               @session_main,
               [
                 %{"type" => "session_created", "session_id" => @session_main},
                 %{
                   "type" => "queue_append",
                   "session_id" => @session_main,
                   "kind" => "user_message",
                   "dedupe_key" => "src-index",
                   "payload" => %{"source_message_id" => "src-index", "content" => "wake"}
                 }
               ]
             )

    assert InternalSession.status(session) == :idle
    assert InternalSession.derived_state(session) == :queued
    assert is_binary(InternalSession.work_index_token(session))
    assert InternalSession.get(session, :work_index_reasons) == ["unacked_queue_item"]

    assert {:ok, [record]} = SessionWorkIndex.list(agent_id)
    assert record["agent_id"] == agent_id
    assert record["session_id"] == @session_main
    assert record["runtime_kind"] == "internal"
    assert record["token"] == InternalSession.work_index_token(session)
    assert record["reasons"] == ["unacked_queue_item"]
    assert record["cas_base"] == "absent"

    assert {:ok, %{records: [discovery], next: nil}} =
             SessionWorkIndex.list_discovery()

    assert discovery["agent_id"] == agent_id
    assert discovery["session_id"] == @session_main
    assert discovery["token"] == InternalSession.work_index_token(session)
    assert discovery["base_revision"] == nil
    refute Map.has_key?(discovery, "cas_base")

    key = Keys.agent_session_work_index(agent_id, "internal", @session_main)
    assert {:ok, %{body: body}} = S3.get(key)
    assert {:ok, %{"session_id" => @session_main}} = Jason.decode(body)

    session_key = Keys.agent_internal_runtime_session(agent_id, @session_main)
    assert {:ok, %{body: persisted_body, etag: update_cas_base}} = S3.get(session_key)
    update_base_revision = Codec.decode_snapshot(persisted_body).storage_revision

    assert {:ok, updated} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{
                 "type" => "queue_append",
                 "session_id" => @session_main,
                 "kind" => "user_message",
                 "dedupe_key" => "src-index-update",
                 "payload" => %{
                   "source_message_id" => "src-index-update",
                   "content" => "wake again"
                 }
               }
             ])

    assert {:ok, [%{"cas_base" => ^update_cas_base, "token" => updated_token}]} =
             SessionWorkIndex.list(agent_id)

    assert updated_token == InternalSession.work_index_token(updated)

    assert {:ok,
            %{
              records: [
                %{"base_revision" => ^update_base_revision, "token" => ^updated_token}
              ]
            }} =
             SessionWorkIndex.list_discovery()
  end

  test "a callback-only CAS retry leaves one live local generation" do
    agent_id = unique_id("agent")
    session_id = @session_b
    assert {:ok, _stable} = InternalSessionStore.prepare_create(agent_id, session_id, %{})

    assert {:ok, _registry_value} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, session_id),
               nil
             )

    injected_key = {__MODULE__, :cas_retry_injected}
    Process.delete(injected_key)

    deadline_ms = System.system_time(:millisecond) + 60_000

    builder = fn _state ->
      unless Process.get(injected_key, false) do
        session_key = Keys.agent_internal_runtime_session(agent_id, session_id)
        assert {:ok, %{body: body, etag: etag}} = S3.get(session_key)
        persisted = Codec.decode_snapshot(body)
        bumped = %{persisted | last_activity_at: (persisted.last_activity_at || 0) + 1}

        assert {:ok, _new_etag} =
                 S3.put(
                   session_key,
                   Codec.encode_snapshot(bumped),
                   if_match: etag
                 )

        Process.put(injected_key, true)
      end

      {:ok,
       [
         %{
           "type" => "async_tool_call_started",
           "session_id" => session_id,
           "tool_call_id" => "retry-callback",
           "tool_name" => "permission.request",
           "status" => "running",
           "completion_mode" => "external_callback",
           "capability_deadline_ms" => deadline_ms
         }
       ]}
    end

    assert {:ok, committed, _meta} =
             InternalSessionStore.commit_dynamic(agent_id, session_id, builder)

    live_token = InternalSession.work_index_token(committed)
    assert Process.get(injected_key) == true
    Process.delete(injected_key)

    assert {:ok, [%{"token" => ^live_token}]} = SessionWorkIndex.list(agent_id)

    assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()

    assert {:ok, %{records: [], next: nil}} =
             SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))

    assert %{
             rewoken: [],
             cleaned: 0,
             failed: 0,
             unproven_retained: 0
           } = SessionWorkRecovery.sweep()

    assert {:ok, [%{"token" => ^live_token}]} = SessionWorkIndex.list(agent_id)

    assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()

    assert {:ok, %{records: [], next: nil}} =
             SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))
  end

  test "an eager CAS retry leaves only the committed discovery generation" do
    agent_id = unique_id("agent")
    session_id = @session_b
    assert {:ok, _stable} = InternalSessionStore.prepare_create(agent_id, session_id, %{})

    assert {:ok, _registry_value} =
             Registry.register(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, session_id),
               nil
             )

    injected_key = {__MODULE__, :eager_cas_retry_injected}
    Process.delete(injected_key)

    builder = fn _state ->
      unless Process.get(injected_key, false) do
        session_key = Keys.agent_internal_runtime_session(agent_id, session_id)
        assert {:ok, %{body: body, etag: etag}} = S3.get(session_key)
        persisted = Codec.decode_snapshot(body)
        bumped = %{persisted | last_activity_at: (persisted.last_activity_at || 0) + 1}

        assert {:ok, _new_etag} =
                 S3.put(
                   session_key,
                   Codec.encode_snapshot(bumped),
                   if_match: etag
                 )

        Process.put(injected_key, true)
      end

      {:ok,
       [
         %{
           "type" => "queue_append",
           "session_id" => session_id,
           "kind" => "user_message",
           "dedupe_key" => "retry-eager-input",
           "payload" => %{
             "source_message_id" => "retry-eager-input",
             "content" => "recover this input"
           }
         }
       ]}
    end

    assert {:ok, committed, _meta} =
             InternalSessionStore.commit_dynamic(agent_id, session_id, builder)

    live_token = InternalSession.work_index_token(committed)
    assert Process.get(injected_key) == true
    Process.delete(injected_key)

    assert {:ok, [%{"token" => ^live_token}]} = SessionWorkIndex.list(agent_id)

    assert {:ok, %{records: [%{"token" => ^live_token}], next: nil}} =
             SessionWorkIndex.list_discovery()
  end

  test "an eager reason sharing a token with a future wait is discovered immediately" do
    agent_id = unique_id("agent")
    deadline_ms = System.system_time(:millisecond) + 60_000

    assert {:ok, session} =
             InternalSessionStore.prepare_commit(
               agent_id,
               @session_main,
               [
                 %{"type" => "session_created", "session_id" => @session_main},
                 %{
                   "type" => "wait_set",
                   "session_id" => @session_main,
                   "wait" => %{
                     "wait_id" => "mixed-reason-wait",
                     "reason" => "wait for more work",
                     "deadline_ms" => deadline_ms
                   }
                 },
                 %{
                   "type" => "queue_append",
                   "session_id" => @session_main,
                   "kind" => "user_message",
                   "dedupe_key" => "mixed-reason-input",
                   "payload" => %{
                     "source_message_id" => "mixed-reason-input",
                     "content" => "this input must wake now"
                   }
                 }
               ]
             )

    assert InternalSession.get(session, :work_index_reasons) ==
             ["unacked_queue_item", "wait_deadline"]

    assert {:ok, [%{"token" => token} = local_record]} =
             SessionWorkIndex.list(agent_id)

    assert token == InternalSession.work_index_token(session)
    refute Map.has_key?(local_record, "recover_after_ms")

    assert {:ok, %{records: [%{"token" => ^token}], next: nil}} =
             SessionWorkIndex.list_discovery()

    assert {:ok, %{records: [], next: nil}} =
             SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))
  end

  test "changing a wait mints a new token and removes the old deferred command" do
    agent_id = unique_id("agent")
    first_deadline_ms = System.system_time(:millisecond) + 60_000
    second_deadline_ms = first_deadline_ms + 60_000

    assert {:ok, first} =
             InternalSessionStore.prepare_commit(
               agent_id,
               @session_main,
               [
                 %{"type" => "session_created", "session_id" => @session_main},
                 %{
                   "type" => "wait_set",
                   "session_id" => @session_main,
                   "wait" => %{
                     "wait_id" => "first-wait",
                     "reason" => "first deadline",
                     "deadline_ms" => first_deadline_ms
                   }
                 }
               ]
             )

    assert {:ok, %{records: [first_discovery], next: nil}} =
             SessionWorkIndex.list_due_discovery(first_deadline_ms)

    assert first_discovery["token"] == InternalSession.work_index_token(first)
    assert first_discovery["recover_after_ms"] == first_deadline_ms

    assert {:ok, second} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{
                 "type" => "wait_set",
                 "session_id" => @session_main,
                 "wait" => %{
                   "wait_id" => "second-wait",
                   "reason" => "replacement deadline",
                   "deadline_ms" => second_deadline_ms
                 }
               }
             ])

    refute InternalSession.work_index_token(second) == InternalSession.work_index_token(first)

    assert {:error, :not_found} =
             SalixStore.SessionWorkCandidates.fetch_exact(InternalSession.work_index_token(first))

    assert {:ok, %{records: [second_discovery], next: nil}} =
             SessionWorkIndex.list_due_discovery(second_deadline_ms)

    assert second_discovery["token"] == InternalSession.work_index_token(second)
    assert second_discovery["recover_after_ms"] == second_deadline_ms
  end

  test "prepare_seed writes work index for non-stable session snapshots" do
    agent_id = unique_id("agent")

    state =
      agent_id
      |> InternalSession.new(@session_seeded, %{})
      |> InternalSession.apply_events([
        %{
          "type" => "queue_append",
          "session_id" => @session_seeded,
          "kind" => "user_message",
          "dedupe_key" => "seed-input",
          "payload" => %{"source_message_id" => "seed-input", "content" => "wake me"}
        }
      ])
      |> InternalSession.normalize()

    assert :ok = InternalSessionStore.prepare_seed(agent_id, state)

    assert {:ok, seeded} = InternalSessionStore.read(agent_id, @session_seeded)
    assert InternalSession.get(seeded, :work_index_reasons) == ["unacked_queue_item"]
    assert is_binary(InternalSession.work_index_token(seeded))

    assert {:ok,
            [
              %{
                "cas_base" => "absent",
                "session_id" => @session_seeded,
                "runtime_kind" => "internal"
              }
            ]} = SessionWorkIndex.list(agent_id)

    stable =
      InternalSession.new(agent_id, @session_seeded, %{"name" => "Stable Seed"})

    assert :ok = InternalSessionStore.prepare_seed(agent_id, stable, force: true)

    assert {:ok, stable_seeded} = InternalSessionStore.read(agent_id, @session_seeded)
    assert InternalSession.get(stable_seeded, :work_index_reasons) == []
    assert InternalSession.work_index_token(stable_seeded) == nil
    assert {:ok, []} = SessionWorkIndex.list(agent_id)
  end

  test "definitive non-force seed rejection discards only the rejected work candidate" do
    agent_id = unique_id("agent")

    stable =
      InternalSession.new(agent_id, @session_seeded, %{"name" => "Existing"})

    assert :ok = InternalSessionStore.prepare_seed(agent_id, stable)
    assert {:ok, canonical_before} = InternalSessionStore.read(agent_id, @session_seeded)

    rejected =
      agent_id
      |> InternalSession.new(@session_seeded, %{"name" => "Rejected"})
      |> InternalSession.apply_events([
        %{
          "type" => "queue_append",
          "session_id" => @session_seeded,
          "kind" => "user_message",
          "dedupe_key" => "rejected-seed-input",
          "payload" => %{
            "source_message_id" => "rejected-seed-input",
            "content" => "must not become discoverable"
          }
        }
      ])
      |> InternalSession.normalize()

    assert {:error, :exists} = InternalSessionStore.prepare_seed(agent_id, rejected)
    assert {:ok, unchanged} = InternalSessionStore.read(agent_id, @session_seeded)
    assert InternalSession.export(unchanged) == InternalSession.export(canonical_before)
    assert {:ok, []} = SessionWorkIndex.list(agent_id)
    assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()

    assert {:ok, %{records: [], next: nil}} =
             SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))
  end

  test "definitive seed rejection restores the authoritative local work generation" do
    agent_id = unique_id("agent")

    authoritative =
      agent_id
      |> InternalSession.new(@session_seeded, %{"name" => "Existing Work"})
      |> InternalSession.apply_events([
        %{
          "type" => "queue_append",
          "session_id" => @session_seeded,
          "kind" => "user_message",
          "dedupe_key" => "authoritative-seed-input",
          "payload" => %{
            "source_message_id" => "authoritative-seed-input",
            "content" => "must remain discoverable"
          }
        }
      ])
      |> InternalSession.normalize()

    assert :ok = InternalSessionStore.prepare_seed(agent_id, authoritative)
    assert {:ok, canonical_before} = InternalSessionStore.read(agent_id, @session_seeded)
    authoritative_token = InternalSession.work_index_token(canonical_before)

    rejected =
      agent_id
      |> InternalSession.new(@session_seeded, %{"name" => "Rejected Work"})
      |> InternalSession.apply_events([
        %{
          "type" => "queue_append",
          "session_id" => @session_seeded,
          "kind" => "user_message",
          "dedupe_key" => "second-rejected-seed-input",
          "payload" => %{
            "source_message_id" => "second-rejected-seed-input",
            "content" => "must not replace authority"
          }
        }
      ])
      |> InternalSession.normalize()

    assert {:error, :exists} = InternalSessionStore.prepare_seed(agent_id, rejected)
    assert {:ok, unchanged} = InternalSessionStore.read(agent_id, @session_seeded)
    assert InternalSession.export(unchanged) == InternalSession.export(canonical_before)
    assert {:ok, [%{"token" => ^authoritative_token}]} = SessionWorkIndex.list(agent_id)

    assert {:ok, %{records: [%{"token" => ^authoritative_token}], next: nil}} =
             SessionWorkIndex.list_discovery()
  end

  test "definitive stable seed rejection leaves authoritative work indexes unchanged" do
    agent_id = unique_id("agent")

    authoritative =
      agent_id
      |> InternalSession.new(@session_seeded, %{"name" => "Existing Work"})
      |> InternalSession.apply_events([
        %{
          "type" => "queue_append",
          "session_id" => @session_seeded,
          "kind" => "user_message",
          "dedupe_key" => "authoritative-work-before-stable-rejection",
          "payload" => %{
            "source_message_id" => "authoritative-work-before-stable-rejection",
            "content" => "must remain discoverable"
          }
        }
      ])
      |> InternalSession.normalize()

    assert :ok = InternalSessionStore.prepare_seed(agent_id, authoritative)
    assert {:ok, canonical_before} = InternalSessionStore.read(agent_id, @session_seeded)
    authoritative_token = InternalSession.work_index_token(canonical_before)

    rejected =
      InternalSession.new(agent_id, @session_seeded, %{"name" => "Rejected Stable Seed"})

    assert {:error, :exists} = InternalSessionStore.prepare_seed(agent_id, rejected)
    assert {:ok, unchanged} = InternalSessionStore.read(agent_id, @session_seeded)
    assert InternalSession.export(unchanged) == InternalSession.export(canonical_before)
    assert {:ok, [%{"token" => ^authoritative_token}]} = SessionWorkIndex.list(agent_id)

    assert {:ok, %{records: [%{"token" => ^authoritative_token}], next: nil}} =
             SessionWorkIndex.list_discovery()
  end

  test "prepare_seed rejects a malformed durable wait without writing state or indexes" do
    agent_id = unique_id("agent")

    state = InternalSession.export(InternalSession.new(agent_id, @session_seeded, %{}))

    malformed =
      InternalSession.open(%State{
        state
        | wait: %{"wait_id" => "seed-invalid-deadline", "deadline_ms" => "later"}
      })

    assert {:error, :invalid_wait} =
             InternalSessionStore.prepare_seed(agent_id, malformed)

    assert {:error, :not_found} = InternalSessionStore.read(agent_id, @session_seeded)
    assert {:ok, []} = SessionWorkIndex.list(agent_id)
    assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()

    assert {:ok, %{records: [], next: nil}} =
             SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))
  end

  test "prepare_seed indexes fork snapshots with unprocessed stable input" do
    source_agent = unique_id("agent")
    target_agent = unique_id("agent")

    source =
      source_agent
      |> InternalSession.new(@session_main, %{})
      |> InternalSession.apply_events([
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => @session_main,
          "message_id" => 1,
          "source_message_id" => "fork-source",
          "content" => "copied but not acked"
        }
      ])
      |> InternalSession.bump_hwm(1)
      |> InternalSession.normalize()

    {:ok, fork} = InternalSession.fork(source, @session_main, %{"name" => "Fork"})
    assert "stable_input_pending" in InternalSession.work_reasons(fork)

    assert :ok = InternalSessionStore.prepare_seed(target_agent, fork)

    assert {:ok, [record]} = SessionWorkIndex.list(target_agent)
    assert record["session_id"] == @session_main
    assert record["reasons"] == ["stable_input_pending"]
    assert record["cas_base"] == "absent"

    assert {:ok, seeded} = InternalSessionStore.read(target_agent, @session_main)
    assert InternalSession.work_index_token(seeded) == record["token"]
  end

  test "stable internal commit clears only the matching work index token" do
    agent_id = unique_id("agent")

    assert {:ok, queued} =
             InternalSessionStore.prepare_commit(
               agent_id,
               @session_main,
               [
                 %{"type" => "session_created", "session_id" => @session_main},
                 %{
                   "type" => "queue_append",
                   "session_id" => @session_main,
                   "kind" => "user_message",
                   "dedupe_key" => "src-index-clear",
                   "payload" => %{
                     "source_message_id" => "src-index-clear",
                     "content" => "wake"
                   }
                 }
               ]
             )

    assert InternalSession.get(queued, :work_index_reasons) == ["unacked_queue_item"]

    {events, true, hwm} = InternalSession.materialize_pending_input_events(queued)
    assert hwm == 1

    assert {:ok, materialized} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, events, hwm: hwm)

    assert InternalSession.get(materialized, :work_index_reasons) == ["stable_input_pending"]
    stable_token = InternalSession.work_index_token(materialized)

    assert {:ok, %{records: [%{"token" => ^stable_token}], next: nil}} =
             SessionWorkIndex.list_discovery()

    assert {:ok, _} =
             InternalSessionStore.prepare_commit(agent_id, @session_main, [
               %{"type" => "ack", "session_id" => @session_main, "last_ack_message_id" => 1},
               %{"type" => "status", "session_id" => @session_main, "status" => "idle"}
             ])

    assert {:ok, []} = SessionWorkIndex.list(agent_id)
    assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()

    assert {:ok, stale} =
             SessionWorkIndex.mark(agent_id, :internal, @session_main, ["unacked_queue_item"])

    assert {:ok, :stale} =
             SessionWorkIndex.delete_if_token(
               agent_id,
               :internal,
               @session_main,
               stable_token
             )

    assert {:ok, [record]} = SessionWorkIndex.list(agent_id)
    assert record["token"] == stale["token"]

    assert {:ok, %{records: [%{"token" => stale_token}], next: nil}} =
             SessionWorkIndex.list_discovery()

    assert stale_token == stale["token"]
  end

  test "session work index rejects unknown reasons" do
    agent_id = unique_id("agent")

    assert {:error, {:invalid_work_index_reasons, ["unknown_reason"]}} =
             SessionWorkIndex.mark(agent_id, :internal, @session_main, [
               "unacked_queue_item",
               "unknown_reason"
             ])

    assert {:ok, []} = SessionWorkIndex.list(agent_id)
  end

  defp unique_id(prefix),
    do: prefix <> "-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
