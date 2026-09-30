defmodule SalixAgent.InternalSessionArchiveTest do
  @moduledoc """
  Legacy archive read compatibility and business behavior over historical JSONL
  fixtures. Fixture construction writes the retired layout directly; production
  business commits always use the current writer.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{
    Compaction,
    InternalAgentRuntime,
    InternalSession,
    InternalSessionActor,
    InternalSessionStore
  }

  alias SalixAgent.InternalSession.State
  alias SalixStore.{ArchiveLog, Codec, Keys, S3}

  @session "ses1_0000000000000000800"

  setup do
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

  defp seed_format2(agent_id, events) do
    state =
      agent_id
      |> InternalSession.new(@session, %{})
      |> InternalSession.export()
      |> Map.put(:storage_format, 2)
      |> InternalSession.open()
      |> InternalSession.apply_events(events)
      |> InternalSession.normalize()
      |> InternalSession.export()

    key = Keys.agent_internal_runtime_session(agent_id, @session)
    {:ok, _} = S3.put(key, Codec.encode_snapshot(state))

    {:ok, _} =
      Registry.register(SalixAgent.Registry, InternalSessionActor.key(agent_id, @session), nil)

    key
  end

  defp archive_key(agent_id),
    do: Keys.agent_internal_runtime_session_archive(agent_id, @session)

  defp archive_reads(read_log) do
    Enum.count(read_log, fn
      {:get, key} -> String.ends_with?(key, "archive.jsonl")
      _other -> false
    end)
  end

  defp archive_lists(read_log) do
    Enum.count(read_log, fn
      {:list, prefix, _opts} -> String.contains?(prefix, "archive")
      _other -> false
    end)
  end

  test "a live-referenced result stays reachable through the archive; ack retires it to not_found" do
    agent_id = "agent-#{System.unique_integer([:positive])}"

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

    seed_format2(agent_id, events)

    assert {:ok, compacted} = InternalSessionStore.commit(agent_id, @session, [compaction(511)])

    # The result record (seq 512, closing the second chunk) is covered by
    # the watermark yet its pointer survives compaction: the un-acked
    # notification protects it.
    assert InternalSession.get(compacted, :compacted_seq) ==
             InternalSession.get(compacted, :last_seq)

    assert %{"call-arch" => result_seq} = InternalSession.get(compacted, :async_result_refs)

    assert {:ok, :archived} =
             SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @session)

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

    assert {:ok, %{body: _}} = S3.get(archive_key(agent_id))
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

    assert {:error, :session_id_mismatch} =
             InternalSessionStore.prepare_commit(agent_id, @session, [mismatched_event])

    seed_format2(agent_id, [
      deliver(1),
      stored_event,
      stored_result_message(2, ref, :capsule),
      stored_result_message(3, ref, :page)
    ])

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
             SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @session)

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

    assert {:ok, :archived} =
             SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @session)

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

    assert {:ok, %{body: archive_bytes}} = S3.get(archive_key(agent_id))

    assert Enum.count(ArchiveLog.decode!(archive_bytes), &(&1.kind == "tool_result")) == 1
  end

  test "format-2 microcompact is a read-side overlay and archives the original bytes" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    seed_format2(agent_id, Enum.map(1..300, &deliver/1))

    assert {:ok, masked} =
             InternalSessionStore.commit(agent_id, @session, [
               %{
                 "type" => "session_microcompact",
                 "session_id" => @session,
                 "message_ids" => [10],
                 "new_content" => "[redacted]"
               }
             ])

    raw = Enum.find(InternalSession.get(masked, :messages), &(&1[:id] == 10))
    assert raw[:content] == "input 10"

    assert [%{"seq" => 10, "replacement" => "[redacted]"}] =
             InternalSession.get(masked, :redactions)

    assert Enum.find(InternalSession.masked_messages(masked), &(&1[:id] == 10))[:content] ==
             "[redacted]"

    masked_in_context = Enum.find(Compaction.context(masked), &(&1[:id] == 10))
    assert stringify(masked_in_context[:content]) == "[redacted]"

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(300)])

    assert {:ok, :archived} =
             SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @session)

    # The archived chunk carries the ORIGINAL bytes; masking stays read-side.
    assert {:ok, %{body: bytes}} = S3.get(archive_key(agent_id))
    archived = ArchiveLog.decode!(bytes) |> Enum.find(&(&1.seq == 10))
    assert archived.data["content"] == "input 10"

    # The overlay outlives archival for read-side masking of the archive.
    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    assert [%{"seq" => 10}] = InternalSession.get(session, :redactions)
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
    seed_format2(agent_id, [
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
             SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @session)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    queue_id = InternalSession.get(session, :input_queue) |> List.last() |> Map.fetch!("queue_id")

    assert {:ok, _} =
             InternalSessionStore.commit(agent_id, @session, [
               %{"type" => "queue_ack", "session_id" => @session, "queue_ack_id" => queue_id}
             ])

    session
  end

  test "an unpinned recovery summary swallows a result it never covered" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    seed_covered_message(agent_id)
    land_result_and_notification(agent_id)

    # No pin: the reducer derives the watermark at apply time. Every message
    # is covered, so it falls back to last_seq — which now counts the async
    # result that landed after the summarizer's snapshot.
    assert {:ok, compacted} =
             InternalSessionStore.commit(agent_id, @session, [recovery_compaction(%{})])

    assert InternalSession.get(compacted, :compacted_seq) == 2

    archive_then_ack(agent_id)

    # Archived and its pointer retired: the model can no longer reach a
    # result that no summary ever described.
    assert {:error, :not_found} =
             InternalAgentRuntime.get_async_tool_call(agent_id, @session, "call-late")
  end

  test "the pinned recovery summary leaves that result reachable" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
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
    agent_id = "agent-#{System.unique_integer([:positive])}"
    seed_format2(agent_id, Enum.map(1..300, &deliver/1))

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(280)])

    assert {:ok, :archived} =
             SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @session)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.archived_through(session) == 280

    # Message 42 archived out of the window: search does not fan out into
    # the archive (limit must bound work) and SAYS so instead of silently
    # pretending it searched everything (owner 2026-08-07 scope ruling).
    assert {:ok, %{"results" => [], "archived_not_searched" => true, "scope" => "live_window"}} =
             InternalAgentRuntime.search_messages(agent_id, "input 42")

    # The window is searched masked: redacting a live message removes the
    # original text from results and surfaces the replacement.
    assert {:ok, _} =
             InternalSessionStore.commit(agent_id, @session, [
               %{
                 "type" => "session_microcompact",
                 "session_id" => @session,
                 "message_ids" => [290],
                 "new_content" => "[REDACTED-290]"
               }
             ])

    assert {:ok, %{"results" => []}} = InternalAgentRuntime.search_messages(agent_id, "input 290")

    assert {:ok, %{"results" => [masked]}} =
             InternalAgentRuntime.search_messages(agent_id, "REDACTED-290")

    assert masked["message_id"] == 290

    # The full transcript still reaches the archived original through the
    # logical view (dashboard scope), masked where redacted.
    assert {:ok, transcript} = InternalSessionStore.transcript(agent_id, session, :full)
    assert Enum.any?(transcript.messages, &((&1["id"] || &1[:id]) == 42))
  end

  test "the compaction recovery file completes its body from the archive" do
    agent_id = "agent-#{System.unique_integer([:positive])}"

    recovery_event = %{
      "type" => "compaction_recovery",
      "session_id" => @session,
      "compacted_through" => 280,
      "summary_sequence" => 1,
      "category" => "llm_failure",
      "reason" => "compaction llm failed",
      "created_at" => 5_000
    }

    seed_format2(agent_id, Enum.map(1..300, &deliver/1) ++ [recovery_event])

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(280)])

    assert {:ok, :archived} =
             SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @session)

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
    agent_id = "agent-#{System.unique_integer([:positive])}"
    seed_format2(agent_id, Enum.map(1..600, &deliver/1))

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(500)])

    assert {:ok, :archived} =
             SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @session)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.archived_through(session) == 500

    # One PUT wrote the archive, but the catalog subdivides it: 1..256 and
    # 257..500. A tail of 100 needs 0 archived messages beyond the window's
    # 100 — force the archive by asking for more than the window holds.
    assert [[1, 256, 256, 0, _], [257, 500, 244, _, _]] =
             InternalSession.get(session, :archive_chunks)

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, tail} = InternalSessionStore.transcript(agent_id, session, {:tail, 150})
    read_log = SalixStore.S3.Fake.read_log()

    # ONE ranged read of the single span that holds the missing 50, and no
    # LIST at any point: the catalog is the address book.
    assert archive_reads(read_log) == 1
    assert archive_lists(read_log) == 0
    assert length(tail.messages) == 150
    assert Enum.map(tail.messages, &(&1["seq"] || &1[:seq])) == Enum.to_list(451..600)
    assert tail.has_older?

    # The older page walks backwards from the cursor with the same bound.
    SalixStore.S3.Fake.reset_read_log()

    assert {:ok, older} = InternalSessionStore.transcript(agent_id, session, {:before, 451, 100})

    assert archive_reads(SalixStore.S3.Fake.read_log()) == 1
    assert Enum.map(older.messages, & &1["seq"]) == Enum.to_list(351..450)
    assert older.has_older?
  end

  test "records appended past the watermark stay outside the committed read" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    seed_format2(agent_id, Enum.map(1..300, &deliver/1))

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(280)])

    assert {:ok, :archived} =
             SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @session)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.archived_through(session) == 280

    # A later archival's append landed but its advance CAS did not: seqs
    # 281.. now live BOTH in the hot window and past the catalog's end of
    # the object. The catalog bounds the read, so each seq appears once.
    {:ok, %{body: committed, etag: etag}} = S3.get(archive_key(agent_id))

    trailing =
      InternalSession.get(session, :messages)
      |> Enum.map(&ArchiveLog.shape("message", &1[:seq], &1))
      |> ArchiveLog.encode()

    {:ok, _} = S3.put(archive_key(agent_id), committed <> trailing, if_match: etag)

    assert {:ok, transcript} = InternalSessionStore.transcript(agent_id, session, :full)
    seqs = Enum.map(transcript.messages, &(&1["seq"] || &1[:seq]))
    assert seqs == Enum.to_list(1..300)

    # And the next archival truncates the uncommitted tail back to a pure
    # function of session state instead of doubling it.
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(300)])

    assert {:ok, :archived} =
             SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @session)

    assert {:ok, done} = InternalSessionStore.read(agent_id, @session)
    assert {:ok, records} = InternalSessionStore.archived_records(agent_id, done)
    assert Enum.map(records, & &1.seq) == Enum.to_list(1..300)
  end

  test "a missing archive object is a hard error, not a shortened history" do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    seed_format2(agent_id, Enum.map(1..600, &deliver/1))

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(600)])

    assert {:ok, :archived} =
             SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @session)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.archived_through(session) == 600

    assert :ok = S3.delete(archive_key(agent_id))

    assert {:error, {:archive_incomplete, _}} =
             InternalSessionStore.transcript(agent_id, session, :full)
  end

  test "microcompact fails loudly when the archive is unreadable, then succeeds after repair" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    tool_message = %{
      "type" => "delivery",
      "from_queue" => true,
      "message_id" => 5,
      "role" => "tool",
      "content" => "tool payload STILL-SECRET",
      "source_message_id" => "src-tool-5b",
      "created_at" => 1_005
    }

    events = Enum.map(1..4, &deliver/1) ++ [tool_message] ++ Enum.map(6..300, &deliver/1)
    seed_format2(agent_id, events)
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(280)])

    assert {:ok, :archived} =
             SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @session)

    # The HWM predicate needs NO archive discovery: even with a committed
    # chunk unreadable, the control covers every current tool message by
    # range — there is no partial cleanup to falsely certify.
    assert {:ok, %{body: chunk_bytes}} = S3.get(archive_key(agent_id))
    assert :ok = S3.delete(archive_key(agent_id))

    assert {:ok, %{"status" => "microcompacted"}} =
             InternalAgentRuntime.microcompact_session_local(agent_id, @session)

    assert {:ok, after_control} = InternalSessionStore.read(agent_id, @session)

    assert Enum.any?(
             InternalSession.get(after_control, :redactions),
             &(&1["kind"] == "tool_messages_through" and (&1["through_id"] || 0) >= 5)
           )

    # Restore the chunk: the archived original masks read-side as usual.
    {:ok, _} = S3.put(archive_key(agent_id), chunk_bytes)

    assert {:ok, transcript} =
             InternalSessionStore.transcript(agent_id, after_control, :full)

    masked = Enum.find(transcript.messages, &((&1["id"] || &1[:id]) == 5))
    assert (masked["content"] || masked[:content]) == "[microcompacted]"
  end

  test "the real microcompact control reaches archived tool messages" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    tool_message = %{
      "type" => "delivery",
      "from_queue" => true,
      "message_id" => 5,
      "role" => "tool",
      "content" => "tool payload SECRET-BODY",
      "source_message_id" => "src-tool-5",
      "created_at" => 1_005
    }

    events =
      Enum.map(1..4, &deliver/1) ++ [tool_message] ++ Enum.map(6..300, &deliver/1)

    seed_format2(agent_id, events)
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(280)])

    assert {:ok, :archived} =
             SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @session)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.archived_through(session) == 280
    refute Enum.any?(InternalSession.get(session, :messages), &(&1[:id] == 5))

    # The production entrypoint (stage_control -> actor selector -> reducer),
    # not a hand-fed reducer event.
    assert {:ok, %{"status" => "microcompacted"}} =
             InternalAgentRuntime.microcompact_session_local(agent_id, @session)

    assert {:ok, after_control} = InternalSessionStore.read(agent_id, @session)

    # One range predicate covers the archived tool message — overlay growth
    # is O(1) per control, not O(historical tool messages).
    assert [%{"kind" => "tool_messages_through"} = predicate] =
             InternalSession.get(after_control, :redactions)

    assert predicate["through_id"] >= 5

    # A repeated control merges instead of accumulating entries.
    assert {:ok, _} = InternalAgentRuntime.microcompact_session_local(agent_id, @session)
    assert {:ok, again} = InternalSessionStore.read(agent_id, @session)
    assert length(InternalSession.get(again, :redactions)) == 1

    # The archived original is masked out of every logical reader.
    assert {:ok, transcript} = InternalSessionStore.transcript(agent_id, after_control, :full)
    masked = Enum.find(transcript.messages, &((&1["id"] || &1[:id]) == 5))
    assert (masked["content"] || masked[:content]) == "[microcompacted]"

    # Original bytes stay in the archive underneath.
    assert {:ok, %{body: bytes}} = S3.get(archive_key(agent_id))
    assert bytes =~ "SECRET-BODY"
  end

  test "emergency compact masks oversized historical non-model messages across archive and window" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    oversized = "HISTORICAL-SECRET-" <> String.duplicate("x", 1_100)
    exact_limit = String.duplicate("y", 1_000)
    oversized_tool = "TOOL-SECRET-" <> String.duplicate("z", 1_100)
    oversized_runtime = "RUNTIME-SECRET-" <> String.duplicate("r", 1_100)
    oversized_assistant = "ASSISTANT-KEPT-" <> String.duplicate("a", 1_100)
    oversized_summary = "SUMMARY-SECRET-" <> String.duplicate("s", 1_100)

    events =
      Enum.map(1..4, &deliver/1) ++
        [
          deliver(5) |> Map.put("content", oversized),
          deliver(6) |> Map.put("content", exact_limit),
          deliver(7) |> Map.merge(%{"role" => "tool", "content" => oversized_tool}),
          deliver(8)
          |> Map.merge(%{
            "role" => "runtime",
            "content" => oversized_runtime,
            "no_wake" => true
          }),
          deliver(9) |> Map.merge(%{"role" => "assistant", "content" => oversized_assistant}),
          deliver(10)
          |> Map.merge(%{
            "role" => "summary",
            "content" => oversized_summary,
            "no_wake" => true
          })
        ] ++ Enum.map(11..300, &deliver/1)

    seed_format2(agent_id, events)
    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(280)])

    assert {:ok, :archived} =
             SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @session)

    assert {:ok, %{"status" => "emergency_compacted", "through_id" => 300}} =
             InternalAgentRuntime.emergency_compact_session_local(agent_id, @session)

    assert {:ok, after_control} = InternalSessionStore.read(agent_id, @session)

    assert [predicate] =
             Enum.filter(
               InternalSession.get(after_control, :redactions),
               &(&1["kind"] == "non_model_messages_over_bytes_through")
             )

    assert predicate["through_id"] == 300
    assert predicate["max_bytes"] == 1_000

    future = "FUTURE-SECRET-" <> String.duplicate("q", 1_100)

    assert {:ok, after_future} =
             InternalSessionStore.commit(agent_id, @session, [
               deliver(301) |> Map.put("content", future)
             ])

    assert {:ok, transcript} = InternalSessionStore.transcript(agent_id, after_future, :full)
    by_id = Map.new(transcript.messages, &{&1["id"] || &1[:id], &1["content"] || &1[:content]})

    placeholder = "[emergency-compacted non-model message over 1000 bytes]"

    assert by_id[5] == placeholder
    assert by_id[6] == exact_limit
    assert by_id[7] == placeholder
    assert by_id[8] == placeholder
    assert by_id[9] == oversized_assistant
    assert by_id[10] == placeholder
    assert by_id[301] == future

    assert {:ok, %{"status" => "emergency_compacted", "through_id" => 301}} =
             InternalAgentRuntime.emergency_compact_session_local(agent_id, @session)

    assert {:ok, again} = InternalSessionStore.read(agent_id, @session)

    assert 1 ==
             Enum.count(
               InternalSession.get(again, :redactions),
               &(&1["kind"] == "non_model_messages_over_bytes_through")
             )

    assert {:ok, transcript} = InternalSessionStore.transcript(agent_id, again, :full)
    future_message = Enum.find(transcript.messages, &((&1["id"] || &1[:id]) == 301))

    assert (future_message["content"] || future_message[:content]) == placeholder

    assert {:ok, %{body: raw_archive}} = S3.get(archive_key(agent_id))
    assert raw_archive =~ "HISTORICAL-SECRET-"
    assert raw_archive =~ "RUNTIME-SECRET-"
  end

  # The async-result pointer contract, pinned end to end through the REAL
  # completion event builder and a real store round trip. Two review rounds
  # have asked whether acking the completion notification can strand the
  # model's own tool_call.get_result; these two cases answer it in code.
  test "acking the completion notification does not retire the result pointer" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)
    marker = "PINNED-MARKER-#{System.unique_integer([:positive])}"

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

    seed_format2(agent_id, events)

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
             SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @session)

    assert {:ok, after_archive} = InternalSessionStore.read(agent_id, @session)

    assert InternalSession.archived_through(after_archive) ==
             InternalSession.get(after_archive, :compacted_seq)

    assert InternalSession.get(after_archive, :async_results) == []

    assert {:error, :not_found} =
             InternalAgentRuntime.get_async_tool_call(agent_id, @session, "call-retire")

    assert {:ok, records} = InternalSessionStore.archived_records(agent_id, after_archive)
    assert Enum.any?(records, &(&1.kind == "async_result"))
  end

  test "a page over a sparse archive transfers only the spans holding messages" do
    agent_id = "agent-#{System.unique_integer([:positive])}"

    # 256 messages, then three spans' worth of facts, then more messages: a
    # one-message page must not transfer the fact-only spans in between.
    facts =
      for n <- 1..768 do
        %{
          "type" => "session_event",
          "session_id" => @session,
          "event_id" => "evt-#{n}",
          "kind" => "connector_reconnected",
          "created_at" => 3_000 + n
        }
      end

    seed_format2(
      agent_id,
      Enum.map(1..256, &deliver/1) ++ facts ++ Enum.map(257..300, &deliver/1)
    )

    assert {:ok, _} = InternalSessionStore.commit(agent_id, @session, [compaction(290)])

    assert {:ok, :archived} =
             SalixAgent.TestSupport.LegacySessionArchive.write(agent_id, @session)

    assert {:ok, session} = InternalSessionStore.read(agent_id, @session)

    # Fact-only spans are recorded with a zero message count.
    assert Enum.any?(
             InternalSession.get(session, :archive_chunks),
             &match?([_first, _last, 0, _offset, _length], &1)
           )

    SalixStore.S3.Fake.reset_read_log()

    window_floor = InternalSession.get(session, :messages) |> Enum.map(& &1[:seq]) |> Enum.min()

    assert {:ok, page} =
             InternalSessionStore.transcript(agent_id, session, {:before, window_floor, 1})

    assert length(page.messages) == 1

    # One ranged read, and it addresses only the span that actually holds
    # the newest archived message — the fact-only spans are never fetched.
    read_log = SalixStore.S3.Fake.read_log()
    assert archive_reads(read_log) == 1
    assert archive_lists(read_log) == 0
  end

  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)
end
