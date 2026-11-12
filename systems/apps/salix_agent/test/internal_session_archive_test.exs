defmodule SalixAgent.InternalSessionArchiveTest do
  @moduledoc "PG Session writes and immutable archive reads, with one historical JSONL reader fixture."
  use SystemsClock.Case, async: false

  alias SalixAgent.{
    InternalAgentRuntime,
    InternalSession,
    InternalSessionActor,
    InternalSessionStore
  }

  alias SalixAgent.InternalSession.State
  alias SalixStore.{ArchiveLog, Keys, S3}

  @session "ses1_0000000000000000800"

  setup do
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    previous_line = SystemsRuntime.get_env(:salix_store, :seal_line_bytes)

    on_exit(fn ->
      if is_nil(previous_line),
        do: SystemsRuntime.delete_env(:salix_store, :seal_line_bytes),
        else: SystemsRuntime.put_env(:salix_store, :seal_line_bytes, previous_line)
    end)

    :ok
  end

  defp deliver(id) do
    %{
      "type" => "delivery",
      "from_queue" => true,
      "message_id" => id,
      "role" => "user",
      "content" => "input #{id}",
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

  defp stored_result_event(ref) do
    result_json = Jason.encode!(%{"items" => Enum.to_list(1..20), "unicode" => "完整结果"})

    %{
      "type" => "tool_result_stored",
      "session_id" => @session,
      "result_ref" => ref,
      "tool_call_id" => "call-generic-archive",
      "tool_name" => "composio.execute",
      "result_json" => result_json,
      "result_sha256" => sha256(result_json),
      "result_bytes" => byte_size(result_json),
      "result_chars" => String.length(result_json),
      "status" => "completed",
      "is_error" => false,
      "stored_at_ms" => 5_000
    }
  end

  defp stored_result_message(id, ref, kind) do
    content =
      case kind do
        :capsule ->
          %{
            "stored_result" => true,
            "result_ref" => ref,
            "get_result" => %{
              "tool" => "tool_call.get_result",
              "arguments" => %{"result_ref" => ref, "offset" => 0}
            }
          }

        :page ->
          %{
            "result_page" => %{
              "result_ref" => ref,
              "encoding" => "json",
              "offset" => 0,
              "content" => "{\"items\":[1,2,3]",
              "truncated" => true,
              "next_offset" => 17
            }
          }
      end

    %{
      "type" => "tool_result",
      "session_id" => @session,
      "message_id" => id,
      "tool_call_id" => "projection-#{id}",
      "content" => Jason.encode!(content),
      "created_at" => 5_000 + id
    }
  end

  defp sha256(content),
    do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp seed_session(agent_id, events) do
    alias SalixAgent.InternalSessionStore.PGCodec

    SalixAgent.TestSupport.SessionFixture.cleanup_on_exit(agent_id)

    SalixStore.Repo.query!(
      "INSERT INTO salix_agents (agent_id,tenant_id,group_id,role,config_revision,config_payload,owner_node,owner_epoch,root_revision) VALUES ($1,'tenant','group','worker',1,$2,'owner',1,1) ON CONFLICT (agent_id) DO NOTHING",
      [agent_id, PGCodec.encode(%{})]
    )

    :ok = SalixAgent.OwnershipCell.install(agent_id, 1)
    ExUnit.Callbacks.on_exit(fn -> SalixAgent.OwnershipCell.clear(agent_id) end)

    state =
      agent_id
      |> InternalSession.new(@session, %{})
      |> InternalSession.apply_events(events)
      |> InternalSession.normalize()

    assert :ok = InternalSessionStore.prepare_seed(agent_id, state)

    {:ok, _} =
      Registry.register(SalixAgent.Registry, InternalSessionActor.key(agent_id, @session), %{
        runtime_epoch: 1
      })

    :ok
  end

  defp archive_all(agent_id) do
    {:ok, state} = InternalSessionStore.read(agent_id, @session)
    archive_visits(agent_id, InternalSession.get(state, :last_seq) + 2, false)
  end

  defp archive_visits(_agent_id, 0, _advanced), do: flunk("archive target did not finish")

  defp archive_visits(agent_id, left, advanced) do
    case InternalSessionStore.archive_pending(agent_id, @session) do
      {:ok, :archived} ->
        archive_visits(agent_id, left - 1, true)

      {:ok, :nothing_to_archive} ->
        {:ok, head} = SalixAgent.InternalSessionStore.PG.archive_head(agent_id, @session)

        if head.target,
          do: archive_visits(agent_id, left - 1, advanced),
          else: {:ok, if(advanced, do: :archived, else: :nothing_to_archive)}

      error ->
        error
    end
  end

  defp archive_key(agent_id),
    do: Keys.agent_internal_runtime_session_archive(agent_id, @session)

  defp archive_lists(read_log) do
    Enum.count(read_log, fn
      {:list, prefix, _opts} -> String.contains?(prefix, "archive")
      _other -> false
    end)
  end

  test "a live-referenced result stays reachable through the archive; ack retires it to not_found" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    events =
      Enum.map(1..511, &deliver/1) ++
        [
          %{
            "type" => "async_tool_call_started",
            "session_id" => @session,
            "tool_call_id" => "call-arch",
            "status" => "running",
            "started_at" => 5_000
          },
          %{
            "type" => "async_tool_call_completed",
            "session_id" => @session,
            "tool_call_id" => "call-arch",
            "result" => %{"answer" => 42},
            "completed_at" => 5_001
          },
          %{
            "type" => "queue_append",
            "session_id" => @session,
            "kind" => "runtime_message",
            "dedupe_key" => "notify-call-arch",
            "payload" => %{
              "runtime_message_id" => "notify-call-arch",
              "type" => "tool_call_completed",
              "tool_call_id" => "call-arch",
              "summary" => "done"
            }
          }
        ]

    seed_session(agent_id, events)

    assert {:ok, compacted} = InternalSessionStore.commit(agent_id, @session, [compaction(511)])

    # The result record (seq 512, closing the second chunk) is covered by
    # the watermark yet its pointer survives compaction: the un-acked
    # notification protects it.
    assert InternalSession.get(compacted, :compacted_seq) ==
             InternalSession.get(compacted, :last_seq)

    assert %{"call-arch" => result_seq} = InternalSession.get(compacted, :async_result_refs)

    assert {:ok, :archived} =
             archive_all(agent_id)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.archived_through(session) >= result_seq
    assert InternalSession.get(session, :async_results) == []

    # Pointer tier: archived but live-referenced resolves through one chunk.
    assert {:ok, record} =
             InternalAgentRuntime.get_async_tool_call(agent_id, @session, "call-arch")

    assert record["status"] == "completed"
    assert record["result"] == %{"answer" => 42}
    assert record["seq"] == result_seq

    # Acking the notification retires the pointer; bare id is the signed
    # explicit not_found while the data stays in the archive.
    queue_id = InternalSession.get(session, :input_queue) |> List.last() |> Map.fetch!("queue_id")

    assert {:ok, acked} =
             InternalSessionStore.commit(agent_id, @session, [
               %{"type" => "queue_ack", "session_id" => @session, "queue_ack_id" => queue_id}
             ])

    assert InternalSession.get(acked, :async_result_refs) == %{}

    assert {:error, :not_found} =
             InternalAgentRuntime.get_async_tool_call(agent_id, @session, "call-arch")

    assert {:ok, %{body: _}} =
             S3.get(
               InternalSessionStore.normalized_catalog(session)
               |> List.first()
               |> Map.fetch!(:object_key)
             )
  end

  test "a generic tool result survives snapshot reload and archive fetch by opaque ref" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    other_agent_id = SalixAgent.TestSupport.new_agent_id()
    ref = "trf1_0000000000000000004"
    stored_event = stored_result_event(ref)
    conflicting_json = Jason.encode!(%{"items" => ["different"]})

    conflicting_event =
      Map.merge(stored_event, %{
        "result_json" => conflicting_json,
        "result_sha256" => sha256(conflicting_json),
        "result_bytes" => byte_size(conflicting_json),
        "result_chars" => String.length(conflicting_json)
      })

    assert :ok = State.validate_events([conflicting_event])

    mismatched_event =
      Map.put(stored_event, "session_id", "ses1_0000000000000000801")

    seed_session(agent_id, [
      deliver(1),
      stored_event,
      stored_result_message(2, ref, :capsule),
      stored_result_message(3, ref, :page)
    ])

    assert {:error, :session_id_mismatch} =
             InternalSessionStore.prepare_commit(agent_id, @session, [mismatched_event])

    # Stable refs absorb exact producer retries, but they are never
    # last-write-wins aliases for different canonical bytes.
    assert {:ok, exact_replay} =
             InternalSessionStore.prepare_commit(agent_id, @session, [stored_event])

    assert length(InternalSession.get(exact_replay, :async_results)) == 1

    assert {:error, :tool_result_ref_conflict} =
             InternalSessionStore.commit_dynamic(agent_id, @session, fn _session ->
               {:ok, [conflicting_event]}
             end)

    # A real snapshot decode preserves the complete canonical record and its
    # opaque pointer before compaction.
    assert {:ok, reloaded} = InternalSessionStore.read(agent_id, @session)
    assert {:ok, hot_record} = InternalSessionStore.fetch_tool_result(agent_id, @session, ref)
    assert InternalSession.get(reloaded, :async_result_refs) == %{ref => hot_record["seq"]}
    assert hot_record["result_json"] == stored_event["result_json"]
    assert hot_record["result_sha256"] == sha256(hot_record["result_json"])

    assert {:error, :not_found} =
             InternalSessionStore.fetch_tool_result(other_agent_id, @session, ref)

    # Compact through the capsule but leave the page live. Full canonical bytes
    # move to the immutable archive; only the small source-session ref remains
    # in the snapshot.
    assert {:ok, compacted} =
             InternalSessionStore.commit(agent_id, @session, [compaction(2)])

    assert InternalSession.get(compacted, :compacted_seq) == 3

    assert {:ok, :archived} =
             archive_all(agent_id)

    assert {:ok, archived_session} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.get(archived_session, :async_results) == []

    assert InternalSession.get(archived_session, :async_result_refs) == %{
             ref => hot_record["seq"]
           }

    # Idempotency and conflict detection still compare against the immutable
    # archive once only the small ref pointer remains in the hot snapshot.
    assert {:ok, archived_replay} =
             InternalSessionStore.prepare_commit(agent_id, @session, [stored_event])

    assert InternalSession.get(archived_replay, :async_results) == []

    assert {:error, :tool_result_ref_conflict} =
             InternalSessionStore.prepare_commit(agent_id, @session, [conflicting_event])

    assert {:ok, archived_record} =
             InternalSessionStore.fetch_tool_result(agent_id, @session, ref)

    assert archived_record == hot_record

    assert {:ok, archived_records} =
             InternalSessionStore.archived_records(agent_id, archived_session)

    assert %{kind: "tool_result", data: archived_data} =
             Enum.find(archived_records, &(&1.seq == hot_record["seq"]))

    assert archived_data["kind"] == "tool_result"
    assert archived_data["result_ref"] == ref

    assert {:ok, ^hot_record} =
             InternalSessionStore.fetch_archived_record(
               agent_id,
               @session,
               archived_session,
               hot_record["seq"]
             )

    # Once the final page is summary-covered and archived, the bounded pointer
    # retires. Canonical bytes remain available through the seq-based archive
    # reader, but a bare result_ref no longer opens deep history.
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(3)])

    assert {:ok, :nothing_to_archive} =
             archive_all(agent_id)

    assert {:ok, retained} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.get(retained, :async_results) == []
    assert InternalSession.get(retained, :async_result_refs) == %{}

    assert {:error, :not_found} =
             InternalSessionStore.fetch_tool_result(agent_id, @session, ref)

    assert {:ok, ^hot_record} =
             InternalSessionStore.fetch_archived_record(
               agent_id,
               @session,
               retained,
               hot_record["seq"]
             )

    assert {:ok, records} = InternalSessionStore.archived_records(agent_id, retained)
    assert Enum.count(records, &(&1.kind == "tool_result")) == 1
  end

  # The consequence the pinned watermark exists to prevent, driven through
  # the real store: commit -> archive -> queue ack -> get_result.
  #
  # The interleaving that PRODUCES an unpinned recovery event is not
  # reachable from the public path yet — compaction is synchronous in the
  # actor, so nothing can commit between snapshot and commit, and the pin
  # equals what the reducer would derive. It becomes reachable with
  # docs/agent-runtime.md. These two tests pin the
  # consequence now so that change cannot land without it.
  defp seed_covered_message(agent_id) do
    seed_session(agent_id, [
      deliver(1),
      %{
        "type" => "async_tool_call_started",
        "session_id" => @session,
        "tool_call_id" => "call-late",
        "status" => "running",
        "started_at" => 5_000
      }
    ])
  end

  # The record that lands AFTER the summarizer took its snapshot.
  defp land_result_and_notification(agent_id) do
    assert {:ok, landed} =
             InternalSessionStore.commit(agent_id, @session, [
               %{
                 "type" => "async_tool_call_completed",
                 "session_id" => @session,
                 "tool_call_id" => "call-late",
                 "result" => %{"answer" => 42},
                 "completed_at" => 5_001
               },
               %{
                 "type" => "queue_append",
                 "session_id" => @session,
                 "kind" => "runtime_message",
                 "dedupe_key" => "notify-call-late",
                 "payload" => %{
                   "runtime_message_id" => "notify-call-late",
                   "type" => "tool_call_completed",
                   "tool_call_id" => "call-late",
                   "summary" => "done"
                 }
               }
             ])

    assert List.last(InternalSession.get(landed, :async_results))["seq"] == 2
    landed
  end

  defp recovery_compaction(extra) do
    Map.merge(
      %{
        "type" => "compaction",
        "session_id" => @session,
        "summary" => "<compacted-context>recovery</compacted-context>",
        "compacted_through" => 1
      },
      extra
    )
  end

  defp archive_then_ack(agent_id) do
    assert {:ok, :archived} =
             archive_all(agent_id)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    queue_id = InternalSession.get(session, :input_queue) |> List.last() |> Map.fetch!("queue_id")

    assert {:ok, _} =
             InternalSessionStore.commit(agent_id, @session, [
               %{"type" => "queue_ack", "session_id" => @session, "queue_ack_id" => queue_id}
             ])

    session
  end

  test "the pinned recovery summary leaves that result reachable" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_covered_message(agent_id)

    # The pin is taken from the snapshot the summarizer actually saw —
    # BEFORE the result lands. That ordering is the whole point.
    assert {:ok, snapshot} = InternalSessionStore.read(agent_id, @session)
    pinned = InternalSession.covered_seq(snapshot, 1)
    assert pinned == 1

    land_result_and_notification(agent_id)

    assert {:ok, compacted} =
             InternalSessionStore.commit(agent_id, @session, [
               recovery_compaction(%{"compacted_seq" => pinned})
             ])

    assert InternalSession.get(compacted, :compacted_seq) == 1

    archive_then_ack(agent_id)

    assert {:ok, record} =
             InternalAgentRuntime.get_async_tool_call(agent_id, @session, "call-late")

    assert record["result"] == %{"answer" => 42}
  end

  test "message search is a live-window surface that names unsearched archive" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_session(agent_id, Enum.map(1..300, &deliver/1))

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(280)])

    assert {:ok, :archived} =
             archive_all(agent_id)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.archived_through(session) == 300

    # Message 42 archived out of the window: search does not fan out into
    # the archive (limit must bound work) and SAYS so instead of silently
    # pretending it searched everything (owner 2026-08-07 scope ruling).
    assert {:ok, %{"results" => [], "archived_not_searched" => true, "scope" => "live_window"}} =
             InternalAgentRuntime.search_messages(agent_id, "input 42")

    assert {:ok, %{"results" => [hit]}} =
             InternalAgentRuntime.search_messages(agent_id, "input 290")

    assert hit["message_id"] == 290

    # The full transcript still reaches the archived original through the
    # logical view (dashboard scope).
    assert {:ok, transcript} = InternalSessionStore.transcript(agent_id, session, :full)
    assert Enum.any?(transcript.messages, &((&1["id"] || &1[:id]) == 42))
  end

  test "the compaction recovery file completes its body from the archive" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    recovery_event = %{
      "type" => "compaction_recovery",
      "session_id" => @session,
      "compacted_through" => 280,
      "summary_sequence" => 1,
      "category" => "llm_failure",
      "reason" => "compaction llm failed",
      "created_at" => 5_000
    }

    seed_session(agent_id, Enum.map(1..300, &deliver/1) ++ [recovery_event])

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(280)])

    assert {:ok, :archived} =
             archive_all(agent_id)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.archived_through(session) > 0

    assert InternalSession.get(session, :last_compaction_recovery)["kind"] ==
             "compaction_recovery"

    assert {:ok, body} =
             SalixAgent.RuntimeFiles.read(
               %{agent_id: agent_id, session_id: @session},
               "/.runtime/compaction-recovery.md"
             )

    # Covered messages archived out of the window still render their text.
    assert body =~ "input 5"
    # Covered messages still in the window render too.
    assert body =~ "input 260"
    refute body =~ "No compacted messages are available."
  end

  test "tail and before pages read only the spans they need" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_session(agent_id, Enum.map(1..600, &deliver/1))

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(500)])

    assert {:ok, :archived} =
             archive_all(agent_id)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.archived_through(session) == 600

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, tail} = InternalSessionStore.transcript(agent_id, session, {:tail, 150})
    read_log = SalixStore.S3.Fake.read_log()

    # The cursor crosses the 257..512 span. Its catalog count is not a
    # count before the cursor, so the existing page plan also reads 1..256.
    assert read_log ==
             Enum.map(
               [1, 257],
               &{:get, Keys.agent_internal_runtime_session_segment(agent_id, @session, &1)}
             )

    assert archive_lists(read_log) == 0
    assert length(tail.messages) == 150
    assert Enum.map(tail.messages, &(&1["seq"] || &1[:seq])) == Enum.to_list(451..600)
    assert tail.has_older?

    # The older page walks backwards from the cursor with the same bound.
    SalixStore.S3.Fake.reset_read_log()

    assert {:ok, older} = InternalSessionStore.transcript(agent_id, session, {:before, 451, 100})

    assert SalixStore.S3.Fake.read_log() ==
             Enum.map(
               [1, 257],
               &{:get, Keys.agent_internal_runtime_session_segment(agent_id, @session, &1)}
             )

    assert Enum.map(older.messages, & &1["seq"]) == Enum.to_list(351..450)
    assert older.has_older?
  end

  test "historical JSONL reads exclude bytes beyond its committed watermark" do
    agent_id = "legacy-reader"

    records =
      for seq <- 1..3,
          do: %{
            seq: seq,
            kind: "message",
            data: %{"id" => seq, "role" => "user", "content" => "message #{seq}"}
          }

    committed = Enum.take(records, 2)
    {:ok, _} = S3.put(archive_key(agent_id), ArchiveLog.encode(records))

    state =
      InternalSession.new(agent_id, @session)
      |> InternalSession.export()
      |> Map.merge(%{
        storage_format: 2,
        archived_through: 2,
        archive_chunks: ArchiveLog.spans(committed, 0)
      })
      |> InternalSession.open()

    assert {:ok, ^committed} = InternalSessionStore.archived_records(agent_id, state)

    assert {:ok, %{messages: messages}} =
             InternalSessionStore.transcript(agent_id, state, {:before, 3, 2})

    assert Enum.map(messages, & &1["id"]) == [1, 2]
  end

  test "a missing archive object is a hard error, not a shortened history" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_session(agent_id, Enum.map(1..600, &deliver/1))

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(600)])

    assert {:ok, :archived} =
             archive_all(agent_id)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.archived_through(session) == 600

    assert :ok =
             S3.delete(
               InternalSessionStore.normalized_catalog(session)
               |> List.first()
               |> Map.fetch!(:object_key)
             )

    assert {:error, {:archive_incomplete, _}} =
             InternalSessionStore.transcript(agent_id, session, :full)
  end

  # The async-result pointer contract, pinned end to end through the REAL
  # completion event builder and a real store round trip. Two review rounds
  # have asked whether acking the completion notification can strand the
  # model's own tool_call.get_result; these two cases answer it in code.
  test "acking the completion notification does not retire the result pointer" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)
    marker = "PINNED-MARKER-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    seed_session(agent_id, [])

    {:ok, _} =
      InternalSessionStore.prepare_commit(agent_id, @session, [
        %{"type" => "session_created", "session_id" => @session, "name" => "Pinned"},
        deliver(1),
        %{
          "type" => "async_tool_call_started",
          "session_id" => @session,
          "tool_call_id" => "call-pinned",
          "tool_name" => "permission.request",
          "status" => "running",
          "started_at" => 5_000
        }
      ])

    result_json = Jason.encode!(%{"status" => "approved", "marker" => marker})

    events =
      SalixAgent.AsyncToolResults.internal_events(
        %{
          "session_id" => @session,
          "tool_call_id" => "call-pinned",
          "tool_name" => "permission.request"
        },
        %{"content" => result_json, "output" => result_json, "status" => "completed"}
      )

    {:ok, completed} = InternalSessionStore.prepare_commit(agent_id, @session, events)
    assert Map.has_key?(InternalSession.get(completed, :async_result_refs), "call-pinned")

    # Materialize the queued notification and ack it — the production
    # sequence that runs BEFORE the model's next round.
    {materialized, _wake?, hwm} = InternalSession.materialize_pending_input_events(completed)
    opts = if hwm > 0, do: [hwm: hwm], else: []
    {:ok, acked} = InternalSessionStore.prepare_commit(agent_id, @session, materialized, opts)

    # The pointer survives the ack, and the model's bare-id lookup resolves.
    assert Map.has_key?(InternalSession.get(acked, :async_result_refs), "call-pinned")

    assert {:ok, record} =
             InternalAgentRuntime.get_async_tool_call(agent_id, @session, "call-pinned")

    assert record["status"] == "completed"

    # The notification itself already carries the result to the model, so
    # the resumed round never depends on that lookup.
    assert Enum.any?(InternalSession.get(acked, :messages), &(stringify(&1[:content]) =~ marker))
  end

  test "pointer retirement needs compaction AND archival, not an ack" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    events =
      Enum.map(1..300, &deliver/1) ++
        [
          %{
            "type" => "async_tool_call_started",
            "session_id" => @session,
            "tool_call_id" => "call-retire",
            "status" => "running",
            "started_at" => 5_000
          },
          %{
            "type" => "async_tool_call_completed",
            "session_id" => @session,
            "tool_call_id" => "call-retire",
            "result" => %{"answer" => 7},
            "completed_at" => 5_001
          }
        ]

    seed_session(agent_id, events)

    # Compaction alone retires the pointer (no window tool_call protects it)
    # but the ladder's window tier still answers.
    assert {:ok, compacted} = InternalSessionStore.commit(agent_id, @session, [compaction(302)])
    assert InternalSession.get(compacted, :async_result_refs) == %{}

    assert {:ok, record} =
             InternalAgentRuntime.get_async_tool_call(agent_id, @session, "call-retire")

    assert record["result"] == %{"answer" => 7}

    # Archival now moves the record out of the window in the same step the
    # watermark covers it — there is no packing delay to keep answering
    # from. With the pointer already retired by compaction, the bare id is
    # the owner-signed not_found while the data stays in the archive.
    assert {:ok, :archived} =
             archive_all(agent_id)

    assert {:ok, after_archive} = InternalSessionStore.read(agent_id, @session)

    assert InternalSession.archived_through(after_archive) ==
             InternalSession.get(after_archive, :last_seq)

    assert InternalSession.get(after_archive, :async_results) == []

    assert {:error, :not_found} =
             InternalAgentRuntime.get_async_tool_call(agent_id, @session, "call-retire")

    assert {:ok, records} = InternalSessionStore.archived_records(agent_id, after_archive)
    assert Enum.any?(records, &(&1.kind == "async_result"))
  end

  test "a page over a sparse archive transfers only the spans holding messages" do
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    SystemsRuntime.put_env(:salix_store, :seal_line_bytes, 256)
    # A one-message page skips fact-only segments between message spans.
    facts =
      for n <- 1..20 do
        %{
          "type" => "session_event",
          "session_id" => @session,
          "event_id" => "evt-#{n}",
          "kind" => "connector_reconnected",
          "created_at" => 3_000 + n
        }
      end

    seed_session(
      agent_id,
      Enum.map(1..3, &deliver/1) ++ facts ++ Enum.map(4..6, &deliver/1)
    )

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(5)])

    assert {:ok, :archived} = archive_all(agent_id)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)

    # Fact-only spans are recorded with a zero message count.
    assert Enum.any?(
             InternalSession.get(session, :segment_catalog),
             &match?([_first, _last, 0, _bytes], &1)
           )

    SalixStore.S3.Fake.reset_read_log()

    window_floor = InternalSession.get(session, :messages) |> Enum.map(& &1[:seq]) |> Enum.min()

    assert {:ok, page} =
             InternalSessionStore.transcript(agent_id, session, {:before, window_floor, 1})

    assert length(page.messages) == 1

    # The straddling message span and its preceding message span suffice;
    # the intervening fact-only spans are never fetched.
    read_log = SalixStore.S3.Fake.read_log()

    assert read_log ==
             Enum.map(
               [23, 25],
               &{:get, Keys.agent_internal_runtime_session_segment(agent_id, @session, &1)}
             )

    assert archive_lists(read_log) == 0
  end

  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)
end
