defmodule SalixAgent.InternalSessionFormat2StateTest do
  use ExUnit.Case, async: true

  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State
  alias SalixAgent.TestSupport.SessionData

  @session "ses1_0000000000000000900"

  defp base_state, do: new_session("agent-f2")

  defp new_session(agent_id),
    do: agent_id |> InternalSession.new(@session, %{}) |> InternalSession.export()

  defp normalize(state),
    do: state |> InternalSession.open() |> InternalSession.normalize() |> InternalSession.export()

  defp fork_session(state, session_id, attrs) do
    with {:ok, child} <-
           state |> InternalSession.open() |> InternalSession.fork(session_id, attrs) do
      {:ok, InternalSession.export(child)}
    end
  end

  defp deliver(id, content) do
    %{
      "type" => "delivery",
      "from_queue" => true,
      "message_id" => id,
      "role" => "user",
      "content" => content,
      "source_message_id" => "src-#{id}",
      "created_at" => 1_000 + id
    }
  end

  defp assistant(id) do
    %{
      "type" => "assistant",
      "message_id" => id,
      "content" => "reply #{id}",
      "created_at" => 2_000
    }
  end

  defp session_event(kind, attrs \\ %{}) do
    Map.merge(
      %{
        "type" => "session_event",
        "event_id" => "evt-#{System.unique_integer([:positive])}",
        "kind" => kind,
        "source" => "internal_runtime",
        "created_at" => 3_000
      },
      attrs
    )
  end

  defp llm_failed(hwm) do
    session_event("llm_call_failed", %{"event" => %{"transcript_hwm" => hwm}})
  end

  defp runtime_message(id, runtime_id) do
    %{
      "type" => "runtime_message",
      "from_queue" => true,
      "message_id" => id,
      "runtime_message_id" => runtime_id,
      "runtime_message_type" => "wait_timeout",
      "summary" => "runtime #{id}",
      "created_at" => 1_000 + id
    }
  end

  # Keep legacy payload fixtures to cover replay; new Round writes are keyless.
  defp runaway_unsettled(key) do
    session_event("runaway_unsettled_round", %{
      "event" => %{
        "activation_key" => key,
        "assistant_message_id" => 99
      }
    })
  end

  defp runaway_reset(key) do
    session_event("runaway_guard_reset", %{
      "event" => %{
        "activation_key" => key,
        "assistant_message_id" => 100
      }
    })
  end

  defp stored_result_event(ref, tool_call_id \\ "call-stored") do
    result_json = Jason.encode!(%{"answer" => "完整", "items" => [1, 2, 3]})

    %{
      "type" => "tool_result_stored",
      "session_id" => @session,
      "result_ref" => ref,
      "tool_call_id" => tool_call_id,
      "tool_name" => "composio.execute",
      "result_json" => result_json,
      "result_sha256" => sha256(result_json),
      "result_bytes" => byte_size(result_json),
      "result_chars" => String.length(result_json),
      "status" => "completed",
      "is_error" => false,
      "stored_at_ms" => 4_000
    }
  end

  defp stored_result_message(message_id, ref, shape) do
    content =
      case shape do
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
              "encoding" => "json",
              "result_ref" => ref,
              "offset" => 0,
              "content" => "{\"answer\":",
              "truncated" => true,
              "next_offset" => 10
            }
          }
      end

    %{
      "type" => "tool_result",
      "session_id" => @session,
      "message_id" => message_id,
      "tool_call_id" => "projection-#{message_id}",
      "content" => Jason.encode!(content),
      "created_at" => 4_000 + message_id
    }
  end

  defp compact_through(message_id) do
    %{
      "type" => "compaction",
      "session_id" => @session,
      "summary" => "summary through #{message_id}",
      "compacted_through" => message_id,
      "summary_sequence" => message_id
    }
  end

  defp archive_through(seq) do
    %{
      "type" => "archive_advance",
      "session_id" => @session,
      "archived_through" => seq,
      "segments" => []
    }
  end

  defp sha256(content),
    do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  describe "the compaction watermark is pinned to the summarized snapshot" do
    setup do
      state =
        %State{new_session("agent-w") | storage_format: 2}
        |> SessionData.apply_events([
          %{
            "type" => "delivery",
            "from_queue" => true,
            "message_id" => 1,
            "role" => "user",
            "content" => "hi"
          },
          %{
            "type" => "async_tool_call_started",
            "session_id" => @session,
            "tool_call_id" => "call-late",
            "status" => "running",
            "started_at" => 1
          }
        ])

      # What a summarizer covering message 1 would pin, computed against the
      # snapshot it actually summarized.
      {:ok, state: state, pinned: SessionData.query(state, :covered_seq, 1)}
    end

    defp land_late_result(state) do
      SessionData.apply_events(state, [
        %{
          "type" => "async_tool_call_completed",
          "session_id" => @session,
          "tool_call_id" => "call-late",
          "result" => %{"a" => 1},
          "completed_at" => 2
        }
      ])
    end

    defp compaction_event(extra) do
      Map.merge(
        %{
          "type" => "compaction",
          "session_id" => @session,
          "summary" => "s",
          "compacted_through" => 1,
          "summary_sequence" => 1
        },
        extra
      )
    end

    # #815: a stale owner's replay of a compaction built from a baseline that
    # already moved on must be a no-op, not a rollback. Without the fence the
    # summary and `compacted_through` went backwards while `compacted_seq`
    # (clamped monotone) did not, so message 2 was archived under a summary
    # that never saw it. The commit-side snapshot check rejects the replay
    # first; this pins the reducer's own guarantee.
    test "a compaction built from a baseline that already moved on is dropped",
         %{state: state} do
      state =
        SessionData.apply_events(state, [
          %{
            "type" => "delivery",
            "from_queue" => true,
            "message_id" => 2,
            "role" => "user",
            "content" => "again"
          }
        ])

      # Owner B: a summary over messages 1 and 2, built from summary_sequence 0.
      winner =
        SessionData.apply_events(state, [
          compaction_event(%{
            "summary" => "B",
            "compacted_through" => 2,
            "compacted_seq" => SessionData.query(state, :covered_seq, 2),
            "summary_sequence" => 1
          })
        ])

      assert winner.summary == "B"
      assert winner.compacted_through == 2

      # Stale owner A: a summary over message 1 only, built from the SAME
      # baseline, rebased onto B's object and replayed.
      stale =
        compaction_event(%{
          "summary" => "A",
          "compacted_through" => 1,
          "compacted_seq" => SessionData.query(state, :covered_seq, 1),
          "summary_sequence" => 1
        })

      replayed = SessionData.apply_events(winner, [stale])

      assert replayed.summary == "B"
      assert replayed.compacted_through == 2
      assert replayed.compacted_seq == winner.compacted_seq
      assert replayed.summary_sequence == 1

      # Same fence for a provider-side compaction from the same baseline.
      stale_provider = %{
        "type" => "provider_compaction",
        "session_id" => @session,
        "provider" => "openai",
        "items" => [],
        "compacted_through" => 1,
        "summary_sequence" => 1
      }

      provider_replayed = SessionData.apply_events(winner, [stale_provider])
      assert provider_replayed.summary == "B"
      assert provider_replayed.provider_compaction == nil
      assert provider_replayed.compacted_through == 2

      # A compaction built from the landed baseline still applies.
      next =
        SessionData.apply_events(replayed, [
          compaction_event(%{
            "summary" => "C",
            "compacted_through" => 2,
            "summary_sequence" => 2
          })
        ])

      assert next.summary == "C"
      assert next.summary_sequence == 2
    end

    test "a record landing between summarize and commit stays above it", %{
      state: state,
      pinned: pinned
    } do
      # The interleaving that becomes reachable once the summary runs off the
      # actor (docs/agent-runtime.md): an async tool
      # terminal is committed while the summary is still being produced.
      landed = land_late_result(state)
      late = List.last(landed.async_results)
      assert late["seq"] == 2

      compacted =
        SessionData.apply_events(landed, [
          compaction_event(%{"compacted_seq" => pinned})
        ])

      # Covered by the summary: message 1 only. The late result must NOT be
      # marked covered — it would archive out of the window while the summary
      # never described it.
      assert compacted.compacted_seq == 1
      assert compacted.compacted_seq < late["seq"]
    end

    test "deriving the watermark at apply time instead would swallow it", %{state: state} do
      # The pre-pin behaviour, kept as the fallback for replaying events
      # committed before the field existed. It is exactly why the field
      # exists: with every message covered, the derivation falls back to
      # last_seq, which now includes the late record.
      landed = land_late_result(state)

      compacted = SessionData.apply_events(landed, [compaction_event(%{})])

      assert compacted.compacted_seq == 2
    end

    test "the pin is clamped, never trusted blindly", %{state: state} do
      # Above last_seq: clamped down, so a bad or replayed-forward pin cannot
      # mark unwritten positions as covered.
      ahead =
        SessionData.apply_events(state, [
          compaction_event(%{"compacted_seq" => 99})
        ])

      assert ahead.compacted_seq == ahead.last_seq

      # Below the current watermark: clamped up, so the watermark never moves
      # backwards.
      forward =
        SessionData.apply_events(state, [compaction_event(%{"compacted_seq" => 1})])

      back =
        SessionData.apply_events(forward, [
          compaction_event(%{"compacted_seq" => 0, "summary_sequence" => 2})
        ])

      assert back.compacted_seq == forward.compacted_seq
    end
  end

  test "messages and facts share one monotone seq order in append order" do
    state =
      base_state()
      |> SessionData.apply_events([
        deliver(1, "hi"),
        session_event("connector_reconnected"),
        assistant(2),
        session_event("connector_disconnected")
      ])

    message_seqs = Enum.map(state.messages, & &1[:seq])
    event_seqs = Enum.map(state.events, & &1["seq"])

    assert message_seqs == [1, 3]
    assert event_seqs == [2, 4]
    assert state.last_seq == 4
  end

  test "tool_result_stored appends a lossless generic result and resolves its opaque ref" do
    ref = "trf1_0000000000000000001"
    event = stored_result_event(ref)

    assert :ok = State.validate_events([event])

    stored = SessionData.apply_event(base_state(), event)

    assert [record] = stored.async_results

    assert record == %{
             "kind" => "tool_result",
             "seq" => 1,
             "result_ref" => ref,
             "tool_call_id" => "call-stored",
             "tool_name" => "composio.execute",
             "result_json" => event["result_json"],
             "result_sha256" => event["result_sha256"],
             "result_bytes" => event["result_bytes"],
             "result_chars" => event["result_chars"],
             "status" => "completed",
             "is_error" => false,
             "stored_at_ms" => 4_000
           }

    assert stored.async_result_refs == %{ref => 1}
    assert {:ok, ^record} = SessionData.query(stored, :lookup_async_call, ref)
    assert {:ok, ^record} = SessionData.query(stored, :lookup_async_call, "call-stored")

    # Stable refs make a producer retry absorbing rather than duplicating the
    # complete source bytes in the session log.
    assert SessionData.apply_event(stored, event) == stored

    invalid = Map.put(event, "result_sha256", String.duplicate("0", 64))
    assert {:error, :invalid_tool_result_sha256} = State.validate_events([invalid])
    assert SessionData.apply_event(base_state(), invalid) == base_state()

    invalid_ref = Map.put(event, "result_ref", "result-1")
    assert {:error, :invalid_tool_result_ref} = State.validate_events([invalid_ref])

    invalid_session = Map.put(event, "session_id", "session-1")
    assert {:error, :invalid_session_id} = State.validate_events([invalid_session])
  end

  test "a generic ref retires after its final capsule and page leave the hot window" do
    ref = "trf1_0000000000000000002"

    state =
      base_state()
      |> SessionData.apply_events([
        deliver(1, "store a result"),
        stored_result_event(ref),
        stored_result_message(2, ref, :capsule),
        stored_result_message(3, ref, :page)
      ])

    assert state.async_result_refs == %{ref => 2}

    assert [%{"kind" => "tool_result"}] = state.async_results

    # Result seq 2 is summary-covered. Its full record leaves the hot snapshot,
    # while the source-session pointer continues to address the archive.
    through_result = SessionData.apply_event(state, compact_through(1))
    assert through_result.compacted_seq == 2

    result_archived = SessionData.apply_event(through_result, archive_through(2))
    assert result_archived.async_results == []
    assert result_archived.async_result_refs == %{ref => 2}
    assert {:archived, 2} = SessionData.query(result_archived, :lookup_async_call, ref)

    # The flat capsule can leave while the nested result_page remains live.
    through_capsule = SessionData.apply_event(result_archived, compact_through(2))
    assert through_capsule.compacted_seq == 3
    capsule_archived = SessionData.apply_event(through_capsule, archive_through(3))
    assert capsule_archived.async_result_refs == %{ref => 2}

    # Once the last live page leaves the window, the bounded lookup pointer
    # retires while the full canonical bytes remain archive-only by seq.
    through_page = SessionData.apply_event(capsule_archived, compact_through(3))
    assert through_page.compacted_seq == 4
    page_archived = SessionData.apply_event(through_page, archive_through(4))
    assert page_archived.async_results == []
    assert page_archived.async_result_refs == %{}
    assert SessionData.query(page_archived, :lookup_async_call, ref) == :not_found
  end

  test "generic result refs stay bounded by live projection messages" do
    refs = Enum.map(1..64, &"trf1_#{String.pad_leading(Integer.to_string(&1), 19, "0")}")

    state =
      refs
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {ref, message_id} ->
        [
          stored_result_event(ref, "call-#{message_id}"),
          stored_result_message(message_id, ref, :capsule)
        ]
      end)
      |> then(&SessionData.apply_events(base_state(), &1))

    assert map_size(state.async_result_refs) == 64

    compacted = SessionData.apply_event(state, compact_through(60))

    partially_archived =
      SessionData.apply_event(compacted, archive_through(compacted.compacted_seq))

    assert Map.keys(partially_archived.async_result_refs) |> Enum.sort() ==
             Enum.drop(refs, 60) |> Enum.sort()

    fully_compacted =
      SessionData.apply_event(partially_archived, compact_through(64))

    fully_archived =
      SessionData.apply_event(
        fully_compacted,
        archive_through(fully_compacted.compacted_seq)
      )

    assert fully_archived.async_result_refs == %{}
  end

  test "format-2 fork carries a live generic ref and remaps its seq" do
    ref = "trf1_0000000000000000003"

    %State{} =
      hot =
      base_state()
      |> SessionData.apply_events([
        deliver(1, "store a result"),
        stored_result_event(ref),
        stored_result_message(2, ref, :capsule),
        stored_result_message(3, ref, :page)
      ])

    [source_record] = hot.async_results
    assert hot.async_result_refs == %{ref => source_record["seq"]}

    compacted = SessionData.apply_event(hot, compact_through(1))
    archived = SessionData.apply_event(compacted, archive_through(2))
    assert archived.async_results == []
    assert archived.async_result_refs == %{ref => 2}

    assert {:ok, fork} =
             fork_session(archived, "ses1_0000000000000000902", %{
               inline_results: [source_record]
             })

    fork_record = Enum.find(fork.async_results, &(&1["result_ref"] == ref))
    assert fork_record["kind"] == "tool_result"
    assert fork_record["result_json"] == source_record["result_json"]
    refute fork_record["seq"] == source_record["seq"]
    assert fork.async_result_refs == %{ref => fork_record["seq"]}
    assert {:ok, ^fork_record} = SessionData.query(fork, :lookup_async_call, ref)
  end

  test "format-2 fork carries a compacted tool result only when its ref is cutoff-visible" do
    ref = "trf1_0000000000000000005"

    source =
      base_state()
      |> SessionData.apply_events([
        deliver(1, "store a result"),
        stored_result_event(ref),
        stored_result_message(2, ref, :capsule)
      ])
      |> SessionData.apply_event(compact_through(1))

    assert source.compacted_seq == 2
    [source_record] = source.async_results

    archived_pointer_source = %State{source | async_results: [], archived_through: 2}

    assert SessionData.query(archived_pointer_source, :fork_inline_result_seqs, %{
             "message_id" => 0
           }) == []

    assert SessionData.query(archived_pointer_source, :fork_inline_result_seqs, %{
             "message_id" => 1
           }) == []

    assert SessionData.query(archived_pointer_source, :fork_inline_result_seqs, %{
             "message_id" => 2
           }) == [2]

    # The result and its capsule are both after transcript cutoff 1. The
    # persistent source ref must not leak that future into the fork.
    assert {:ok, before_capsule} =
             fork_session(source, "ses1_0000000000000000903", %{
               "message_id" => 1
             })

    assert before_capsule.async_results == []
    assert before_capsule.async_result_refs == %{}
    assert SessionData.query(before_capsule, :lookup_async_call, ref) == :not_found

    # Once the cutoff includes the structured capsule, the exact canonical
    # bytes travel and receive a fresh seq in the fork.
    assert {:ok, through_capsule} =
             fork_session(source, "ses1_0000000000000000904", %{
               "message_id" => 2
             })

    assert {:ok, carried_record} =
             SessionData.query(through_capsule, :lookup_async_call, ref)

    assert carried_record["result_sha256"] == source_record["result_sha256"]
    assert carried_record["result_json"] == source_record["result_json"]

    # A copied compaction summary may retain an exact known result_ref even
    # when its capsule is beyond the cutoff.
    summarized = %State{source | summary: "Use stored result #{ref} in the continuation."}

    assert SessionData.query(
             %State{summarized | async_results: [], archived_through: 2},
             :fork_inline_result_seqs,
             %{"message_id" => 1}
           ) == [2]

    assert {:ok, through_summary} =
             fork_session(summarized, "ses1_0000000000000000905", %{
               "message_id" => 1
             })

    assert {:ok, summarized_record} =
             SessionData.query(through_summary, :lookup_async_call, ref)

    assert summarized_record["result_sha256"] == source_record["result_sha256"]

    # Opaque provider compaction has no ref manifest. A fork therefore carries
    # only refs named by its selected transcript/summary, never every known
    # historical result by default.
    future_ref = "trf1_0000000000000000006"
    provider_compaction = %{"encrypted_content" => "opaque-compaction"}

    opaque_source =
      source
      |> SessionData.apply_event(stored_result_event(future_ref, "call-future"))
      |> Map.put(:provider_compaction, provider_compaction)

    assert SessionData.query(
             %State{opaque_source | async_results: [], archived_through: 2},
             :fork_inline_result_seqs,
             %{"message_id" => 1}
           ) == []

    assert {:ok, through_provider_compaction} =
             fork_session(opaque_source, "ses1_0000000000000000906", %{
               "message_id" => 1
             })

    assert through_provider_compaction.provider_compaction == provider_compaction

    assert SessionData.query(through_provider_compaction, :lookup_async_call, ref) ==
             :not_found

    assert SessionData.query(through_provider_compaction, :lookup_async_call, future_ref) ==
             :not_found
  end

  test "seqs survive a normalize round-trip and never restamp" do
    state =
      SessionData.apply_events(base_state(), [deliver(1, "hi"), assistant(2)])

    normalized = normalize(state)

    assert Enum.map(normalized.messages, & &1[:seq]) ==
             Enum.map(state.messages, & &1[:seq])

    assert normalized.last_seq == state.last_seq
  end

  for {status, terminal_type, terminal_fields} <- [
        {"completed", "async_tool_call_completed",
         %{
           "result" => %{"answer" => 42},
           "duration_ms" => 17,
           "completed_at" => 2_000
         }},
        {"failed", "async_tool_call_failed",
         %{
           "error" => true,
           "error_class" => "provider_rejected",
           "error_message" => "denied",
           "completed_at" => 2_001
         }},
        {"cancelled", "async_tool_call_cancelled",
         %{
           "cancel_reason" => "user_cancelled",
           "cancelled_at" => 2_002
         }}
      ] do
    test "a late start cannot shadow a format-2 #{status} result" do
      call_id = "call-terminal-#{unquote(status)}"

      terminal =
        %State{base_state() | storage_format: 2}
        |> SessionData.apply_events([
          %{
            "type" => "async_tool_call_started",
            "session_id" => @session,
            "tool_call_id" => call_id,
            "tool_name" => "permission.request",
            "status" => "running",
            "completion_mode" => "local_background",
            "started_at" => 1_000
          },
          Map.merge(
            %{
              "type" => unquote(terminal_type),
              "session_id" => @session,
              "tool_call_id" => call_id
            },
            unquote(Macro.escape(terminal_fields))
          )
        ])

      assert {:ok, %{"status" => unquote(status)} = terminal_record} =
               SessionData.query(terminal, :lookup_async_call, call_id)

      refute Map.has_key?(terminal.async_tool_calls, call_id)
      assert terminal.async_result_refs[call_id] == terminal_record["seq"]

      replayed =
        SessionData.apply_event(terminal, %{
          "type" => "async_tool_call_started",
          "session_id" => @session,
          "tool_call_id" => call_id,
          "tool_name" => "permission.request",
          "status" => "running",
          "completion_mode" => "external_callback",
          "started_at" => 3_000
        })

      # The terminal projection is absorbing: a stale start is a complete
      # no-op, so it cannot sit in the higher-priority running map and shadow
      # the format-2 result-ref lookup.
      assert replayed == terminal
      refute Map.has_key?(replayed.async_tool_calls, call_id)

      assert {:ok, ^terminal_record} =
               SessionData.query(replayed, :lookup_async_call, call_id)
    end
  end

  test "a late start cannot shadow an archived format-2 terminal pointer" do
    call_id = "call-terminal-archived"

    %State{} =
      terminal =
      %State{base_state() | storage_format: 2}
      |> SessionData.apply_events([
        %{
          "type" => "async_tool_call_started",
          "session_id" => @session,
          "tool_call_id" => call_id,
          "tool_name" => "permission.request",
          "status" => "running",
          "completion_mode" => "local_background",
          "started_at" => 1_000
        },
        %{
          "type" => "async_tool_call_completed",
          "session_id" => @session,
          "tool_call_id" => call_id,
          "result" => %{"answer" => 42},
          "completed_at" => 2_000
        }
      ])

    terminal_seq = terminal.async_result_refs[call_id]
    archived = %State{terminal | async_results: []}

    assert {:archived, ^terminal_seq} =
             SessionData.query(archived, :lookup_async_call, call_id)

    replayed =
      SessionData.apply_event(archived, %{
        "type" => "async_tool_call_started",
        "session_id" => @session,
        "tool_call_id" => call_id,
        "tool_name" => "permission.request",
        "status" => "running",
        "completion_mode" => "external_callback",
        "started_at" => 3_000
      })

    assert replayed == archived
    refute Map.has_key?(replayed.async_tool_calls, call_id)

    assert {:archived, ^terminal_seq} =
             SessionData.query(replayed, :lookup_async_call, call_id)
  end

  test "legacy snapshots without the new fields normalize to defaults" do
    legacy =
      base_state()
      |> Map.from_struct()
      |> Map.drop([
        :storage_format,
        :last_seq,
        :compacted_seq,
        :archived_through,
        :flush_id,
        :async_results,
        :async_result_refs,
        :redactions,
        :llm_failure_streak
      ])

    restored = normalize(struct(State, legacy))

    assert restored.storage_format == 1
    assert restored.last_seq == 0
    assert restored.compacted_seq == 0
    assert restored.archived_through == 0
    assert restored.async_results == []
    assert restored.async_result_refs == %{}
    assert restored.redactions == []
  end

  test "a legacy snapshot with stamped records resumes past the highest stamp" do
    stamped =
      SessionData.apply_events(base_state(), [deliver(1, "hi"), assistant(2)])

    legacy = stamped |> Map.from_struct() |> Map.put(:last_seq, 0)
    legacy = normalize(struct(State, legacy))

    assert legacy.last_seq == 2

    appended = SessionData.apply_events(legacy, [deliver(3, "again")])
    assert List.last(appended.messages)[:seq] == 3
  end

  test "fork renumbers the copied window densely and appends continue from it" do
    source =
      SessionData.apply_events(base_state(), [deliver(1, "hi"), assistant(2)])

    {:ok, fork} = fork_session(source, "ses1_0000000000000000901", %{})

    assert Enum.map(fork.messages, & &1[:seq]) == [1, 2]
    assert fork.last_seq == 2
    assert {fork.archived_through, fork.compacted_seq} == {0, 0}

    appended = SessionData.apply_events(fork, [deliver(3, "fork input")])
    assert List.last(appended.messages)[:seq] == 3
  end

  test "format 2 reads the streak field and matches the format 1 scan" do
    events = [
      deliver(1, "hi"),
      llm_failed(1),
      llm_failed(1),
      llm_failed(1)
    ]

    format1 = SessionData.apply_events(base_state(), events)

    format2 =
      SessionData.apply_events(%State{base_state() | storage_format: 2}, events)

    assert SessionData.query(format1, :consecutive_llm_failures) == 3
    assert SessionData.query(format2, :consecutive_llm_failures) == 3
    # `terminal` rides the same field: this helper's failures carry no
    # `retryable` flag, so they stay non-terminal and only the count/hwm
    # parity with the format 1 scan is asserted here.
    assert format2.llm_failure_streak == %{"count" => 3, "hwm" => 1, "terminal" => false}
  end

  test "any other fact breaks the streak under both formats" do
    events = [deliver(1, "hi"), llm_failed(1), session_event("connector_reconnected")]

    format1 = SessionData.apply_events(base_state(), events)

    format2 =
      SessionData.apply_events(%State{base_state() | storage_format: 2}, events)

    assert SessionData.query(format1, :consecutive_llm_failures) == 0
    assert SessionData.query(format2, :consecutive_llm_failures) == 0
  end

  test "a message append moves the position and zeroes the streak read" do
    events = [deliver(1, "hi"), llm_failed(1), deliver(2, "more")]

    format2 =
      SessionData.apply_events(%State{base_state() | storage_format: 2}, events)

    assert SessionData.query(format2, :consecutive_llm_failures) == 0
    # The stale field is untouched — staleness itself is the reset.
    assert format2.llm_failure_streak == %{"count" => 1, "hwm" => 1, "terminal" => false}
  end

  test "manual compact results are bounded by recency, message-keyed ones by the watermark" do
    manual_results =
      for n <- 1..12 do
        %{
          "type" => "session_compact_result",
          "source_message_id" => "session:compact:manual-#{n}",
          "status" => "compacted",
          "created_at" => 3_000 + n
        }
      end

    state =
      SessionData.apply_events(base_state(), [deliver(1, "hi") | manual_results])

    # 12 random-keyed operations, cap of 8: only the most recent survive,
    # including the one just written (its caller polls for it immediately).
    assert map_size(state.compact_results) == 8

    kept = Map.keys(state.compact_results)
    assert "session:compact:manual-12" in kept
    refute "session:compact:manual-1" in kept
  end

  test "an hwm-less failure blocks the streak, a following match restarts it" do
    events = [
      deliver(1, "hi"),
      session_event("llm_call_failed"),
      llm_failed(1)
    ]

    format1 = SessionData.apply_events(base_state(), events)

    format2 =
      SessionData.apply_events(%State{base_state() | storage_format: 2}, events)

    assert SessionData.query(format1, :consecutive_llm_failures) == 1
    assert SessionData.query(format2, :consecutive_llm_failures) == 1
  end

  describe "runaway guard persisted counter and independent source scope" do
    test "counter is explicit control state and survives hot-window archive" do
      state = SessionData.apply_events(base_state(), [deliver(1, "hi")])
      key = SessionData.query(state, :current_activation_key, [])

      parked =
        SessionData.apply_events(state, [
          runaway_unsettled(key),
          runaway_unsettled(key)
        ])

      assert SessionData.query(parked, :consecutive_unsettled_rounds) == 2
      assert parked.runaway_unsettled_streak == %{"count" => 2}

      archived = %State{
        parked
        | messages: [],
          events: [],
          compacted_seq: parked.last_seq,
          archived_through: parked.last_seq
      }

      assert SessionData.query(archived, :consecutive_unsettled_rounds) == 2
    end

    test "stored streak normalizes across restart" do
      state = SessionData.apply_events(base_state(), [deliver(1, "hi")])
      key = SessionData.query(state, :current_activation_key, [])

      parked =
        SessionData.apply_events(state, [
          runaway_unsettled(key),
          runaway_unsettled(key)
        ])

      restarted = normalize(struct(State, Map.from_struct(parked)))

      assert SessionData.query(restarted, :current_activation_key, []) == key
      assert SessionData.query(restarted, :consecutive_unsettled_rounds) == 2
    end

    test "runtime input retains its status source independently of the counter" do
      state = SessionData.apply_events(base_state(), [runtime_message(1, "rt-1")])
      key = SessionData.query(state, :current_activation_key, [])

      assert key == ["rt-1"]

      parked =
        SessionData.apply_events(state, [
          runaway_unsettled(key),
          runaway_unsettled(key)
        ])

      assert SessionData.query(parked, :consecutive_unsettled_rounds) == 2
      assert parked.runaway_unsettled_streak == %{"count" => 2}
    end

    test "explicit status source ids are merged with live runtime input" do
      state =
        SessionData.apply_events(base_state(), [
          deliver(1, "hi"),
          runtime_message(2, "wait-1")
        ])

      assert SessionData.query(state, :current_activation_key, ["src-1"]) ==
               SessionData.query(state, :current_activation_key, [])

      assert SessionData.query(state, :current_activation_key, ["src-1"]) == [
               "src-1",
               "wait-1"
             ]
    end

    test "archived runtime-only input retains status scope and counter separately" do
      state =
        SessionData.apply_events(base_state(), [runtime_message(1, "rt-arch")])

      key = SessionData.query(state, :current_activation_key, [])

      %State{} =
        parked =
        SessionData.apply_events(state, [
          runaway_unsettled(key),
          runaway_unsettled(key)
        ])

      archived = %State{
        parked
        | messages: [],
          events: [],
          compacted_seq: parked.last_seq,
          archived_through: parked.last_seq
      }

      assert SessionData.query(archived, :current_activation_key, []) == ["rt-arch"]

      continued =
        SessionData.apply_events(archived, [
          runaway_unsettled(SessionData.query(archived, :current_activation_key, []))
        ])

      assert continued.runaway_unsettled_streak == %{"count" => 3}
      assert SessionData.query(continued, :consecutive_unsettled_rounds) == 3
    end

    test "new input changes the activation key and resets the readable streak" do
      state = SessionData.apply_events(base_state(), [deliver(1, "hi")])
      key = SessionData.query(state, :current_activation_key, [])

      parked =
        SessionData.apply_events(state, [
          runaway_unsettled(key),
          runaway_unsettled(key)
        ])

      with_new_input = SessionData.apply_events(parked, [deliver(2, "fresh")])

      assert SessionData.query(with_new_input, :current_activation_key, []) == [
               "src-1",
               "src-2"
             ]

      assert SessionData.query(with_new_input, :consecutive_unsettled_rounds) == 0

      assert with_new_input.runaway_unsettled_streak == %{
               "count" => 0
             }
    end

    test "fresh input survives pre-round archive without reviving an old exhausted streak" do
      cap = State.runaway_unsettled_round_cap()
      state = SessionData.apply_events(base_state(), [deliver(1, "old")])
      old_key = SessionData.query(state, :current_activation_key, [])
      old_events = Enum.map(1..cap, fn _ -> runaway_unsettled(old_key) end)
      old_exhausted = SessionData.apply_events(state, old_events)

      assert SessionData.query(old_exhausted, :runaway_unsettled_rounds_exhausted?)

      fresh = SessionData.apply_events(old_exhausted, [deliver(2, "fresh")])

      assert SessionData.query(fresh, :consecutive_unsettled_rounds) == 0

      assert fresh.runaway_unsettled_streak == %{
               "count" => 0
             }

      archived = %State{
        fresh
        | messages: [],
          events: [],
          compacted_seq: fresh.last_seq,
          archived_through: fresh.last_seq
      }

      assert SessionData.query(archived, :current_activation_key, []) == ["src-1", "src-2"]
      assert SessionData.query(archived, :consecutive_unsettled_rounds) == 0
      refute SessionData.query(archived, :runaway_unsettled_rounds_exhausted?)

      first_round =
        SessionData.apply_events(archived, [
          runaway_unsettled(SessionData.query(archived, :current_activation_key, []))
        ])

      assert first_round.runaway_unsettled_streak == %{
               "count" => 1
             }

      refute SessionData.query(first_round, :runaway_unsettled_rounds_exhausted?)
    end

    test "tool-call reset clears count but preserves status source scope" do
      state = SessionData.apply_events(base_state(), [deliver(1, "hi")])
      key = SessionData.query(state, :current_activation_key, [])

      parked =
        SessionData.apply_events(state, [
          runaway_unsettled(key),
          runaway_unsettled(key)
        ])

      reset = SessionData.apply_events(parked, [runaway_reset(key)])

      assert reset.runaway_unsettled_streak == %{"count" => 0}
      assert SessionData.query(reset, :consecutive_unsettled_rounds) == 0
    end

    test "runtime-only archived activation still exhausts after a tool reset" do
      cap = State.runaway_unsettled_round_cap()

      %State{} =
        state =
        SessionData.apply_events(base_state(), [runtime_message(1, "rt-reset")])

      archived = %State{
        state
        | messages: [],
          events: [],
          compacted_seq: state.last_seq,
          archived_through: state.last_seq
      }

      assert SessionData.query(archived, :current_activation_key, []) == ["rt-reset"]

      reset =
        SessionData.apply_events(archived, [
          runaway_reset(SessionData.query(archived, :current_activation_key, []))
        ])

      assert reset.runaway_unsettled_streak == %{"count" => 0}
      assert SessionData.query(reset, :consecutive_unsettled_rounds) == 0
      refute SessionData.query(reset, :runaway_unsettled_rounds_exhausted?)

      exhausted =
        SessionData.apply_events(
          reset,
          Enum.map(1..cap, fn _ ->
            runaway_unsettled(SessionData.query(reset, :current_activation_key, []))
          end)
        )

      assert exhausted.runaway_unsettled_streak == %{"count" => cap}
      assert SessionData.query(exhausted, :runaway_unsettled_rounds_exhausted?)
    end
  end
end
