defmodule SalixAgent.InternalSessionStoreTest do
  use SystemsClock.Case, async: false

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
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
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

  test "changing a wait mints a new token and removes the old deferred command" do
    agent_id = unique_id("agent")
    first_deadline_ms = SystemsClock.system_time(:millisecond) + 60_000
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

  defp unique_id(prefix),
    do: prefix <> "-" <> Base.encode16(SystemsRuntime.Proc.random_bytes(6), case: :lower)
end
