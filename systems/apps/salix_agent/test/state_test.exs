defmodule SalixAgent.StateTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.Compaction
  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State, as: SessionState
  alias SalixAgent.State
  alias SalixAgent.TestSupport.SessionData
  alias SalixStore.{Agent, Codec, Keys, S3}

  describe "agent root state shell" do
  end

  describe "internal session reducer" do
    test "scheduler status and detailed activity follow only durable session facts" do
      idle = new_session("agent-1", "s1", %{"created_at" => 10})

      queued =
        SessionData.apply_event(idle, %{
          type: "queue_append",
          session_id: "s1",
          kind: "user_message",
          dedupe_key: "input-1",
          created_at: 20,
          payload: %{source_message_id: "input-1", content: "hello"}
        })

      async_tool =
        SessionData.apply_event(queued, %{
          type: "async_tool_call_started",
          session_id: "s1",
          tool_call_id: "tool-1",
          status: "running",
          started_at: 30
        })

      assert SessionData.query(queued, :derived_state) == :queued
      assert queued.status == :idle
      assert SessionData.query(queued, :activity_status) == :paused
      assert SessionData.query(async_tool, :activity_status) == :paused
      assert async_tool.activity_status_updated_at == 10

      running =
        SessionData.apply_event(async_tool, %{
          type: "status",
          session_id: "s1",
          status: "active",
          created_at: 40
        })

      assert running.status == :active
      assert SessionData.query(running, :activity_status) == :thinking
      assert running.activity_status_updated_at == 40

      executing =
        SessionData.apply_event(running, %{
          type: "activity_status",
          session_id: "s1",
          activity_status: "execution",
          created_at: 41
        })

      assert SessionData.query(executing, :activity_status) == :execution
      assert executing.activity_status_updated_at == 41

      messaging =
        SessionData.apply_event(executing, %{
          type: "activity_status",
          session_id: "s1",
          activity_status: "messaging",
          created_at: 42
        })

      assert SessionData.query(messaging, :activity_status) == :messaging
      assert messaging.activity_status_updated_at == 42

      still_running =
        SessionData.apply_event(messaging, %{
          type: "wait_set",
          session_id: "s1",
          wait: %{"reason" => "approval"},
          created_at: 43
        })

      assert still_running.status == :active
      assert SessionData.query(still_running, :activity_status) == :messaging
      assert still_running.activity_status_updated_at == 42

      waiting =
        SessionData.apply_event(still_running, %{
          type: "status",
          session_id: "s1",
          status: "idle",
          created_at: 44
        })

      assert waiting.status == :idle
      assert SessionData.query(waiting, :activity_status) == :waiting
      assert waiting.activity_status_updated_at == 44

      settled =
        SessionData.apply_event(waiting, %{
          type: "wait_clear",
          session_id: "s1",
          created_at: 45
        })

      assert settled.status == :idle
      assert SessionData.query(settled, :activity_status) == :paused
      assert settled.activity_status_updated_at == 45

      failed =
        Enum.reduce(46..48, settled, fn timestamp, state ->
          SessionData.apply_event(state, %{
            type: "session_event",
            session_id: "s1",
            event_id: "failure-#{timestamp}",
            kind: "llm_call_failed",
            event: %{transcript_hwm: 0},
            created_at: timestamp
          })
        end)

      assert failed.status == :idle
      assert SessionData.query(failed, :activity_status) == :failed
      assert failed.activity_status_updated_at == 48

      recovered =
        SessionData.apply_event(failed, %{
          type: "delivery",
          session_id: "s1",
          from_queue: true,
          message_id: 1,
          role: "user",
          content: "retry with new input",
          source_message_id: "input-2",
          created_at: 49
        })

      assert recovered.status == :idle
      assert SessionData.query(recovered, :activity_status) == :paused
      assert recovered.activity_status_updated_at == 49
    end

    test "normalize keeps next queue id ahead of retained pending queue items" do
      session =
        normalize(%SessionState{
          agent_id: "agent-1",
          session_id: "s1",
          next_queue_id: nil,
          input_queue: [
            %{
              "queue_id" => 4,
              "kind" => "user_message",
              "dedupe_key" => "src-4",
              "payload" => %{"source_message_id" => "src-4", "content" => "four"}
            },
            %{
              "queue_id" => 7,
              "kind" => "user_message",
              "dedupe_key" => "src-7",
              "payload" => %{"source_message_id" => "src-7", "content" => "seven"}
            }
          ]
        })

      assert session.next_queue_id == 8

      appended =
        SessionData.apply_event(session, %{
          type: "queue_append",
          session_id: "s1",
          kind: "user_message",
          dedupe_key: "src-8",
          payload: %{source_message_id: "src-8", content: "eight"}
        })

      assert Enum.map(appended.input_queue, & &1["queue_id"]) == [4, 7, 8]
      assert appended.next_queue_id == 9
    end

    test "queue append dedupes by source id and materialized no_wake stays silent until wakeable input" do
      queued =
        reduce_session([
          %{type: "session_created", session_id: "s1"},
          %{
            type: "queue_append",
            session_id: "s1",
            kind: "user_message",
            dedupe_key: "src-A",
            payload: %{source_message_id: "src-A", content: "hi"}
          },
          %{
            type: "queue_append",
            session_id: "s1",
            kind: "user_message",
            dedupe_key: "src-A",
            payload: %{source_message_id: "src-A", content: "duplicate"}
          }
        ])

      {events, true, _hwm} = materialize(queued)
      session = SessionData.apply_events(queued, events)

      assert Enum.map(session.messages, & &1.content) == ["hi"]
      assert session.status == :idle
      assert SessionData.query(session, :derived_state) == :queued
      assert session.next_message_id == 2
      assert session.queue_ack_id == 1
      assert session.input_queue == []

      no_wake_queued =
        reduce_session(
          [
            %{type: "session_created", session_id: "s2"},
            %{
              type: "queue_append",
              session_id: "s2",
              kind: "user_message",
              wake: false,
              dedupe_key: "runtime-1",
              payload: %{source_message_id: "runtime-1", content: "runtime context"}
            }
          ],
          "agent-1",
          "s2"
        )

      {events, false, _hwm} = materialize(no_wake_queued)
      no_wake = SessionData.apply_events(no_wake_queued, events)

      assert Enum.map(no_wake.messages, & &1.content) == ["runtime context"]
      assert no_wake.status == :idle
      assert SessionData.query(no_wake, :derived_state) == :paused
      assert no_wake.queue_ack_id == 1
      assert no_wake.input_queue == []

      mixed =
        reduce_session(
          [
            %{type: "session_created", session_id: "s3"},
            %{
              type: "queue_append",
              session_id: "s3",
              kind: "user_message",
              wake: false,
              dedupe_key: "runtime-1",
              payload: %{source_message_id: "runtime-1", content: "runtime context"}
            },
            %{
              type: "queue_append",
              session_id: "s3",
              kind: "user_message",
              dedupe_key: "src-B",
              payload: %{source_message_id: "src-B", content: "please run"}
            }
          ],
          "agent-1",
          "s3"
        )

      {events, true, _hwm} = materialize(mixed)
      mixed = SessionData.apply_events(mixed, events)

      assert Enum.map(mixed.messages, & &1.content) == ["runtime context", "please run"]
      assert SessionData.query(mixed, :derived_state) == :queued
    end

    test "trusted delivery origin survives queue materialization into the user message" do
      trusted_origin = %{
        "provider" => "internal",
        "conversation_id" => "cnv1_0000000000000000001",
        "conversation_kind" => "user_chat",
        "message_id" => "msg1_0000000000000000001",
        "participant_id" => "ptp1_0000000000000000001",
        "source_actor_type" => "user",
        "agent_group_id" => "grp1_origin"
      }

      queued =
        reduce_session([
          %{type: "session_created", session_id: "s1"},
          %{
            type: "queue_append",
            session_id: "s1",
            kind: "user_message",
            dedupe_key: "source-origin",
            payload: %{
              source_message_id: "source-origin",
              content: "创建一个贪吃蛇单网页",
              trusted_origin: trusted_origin
            }
          }
        ])

      {events, true, _hwm} = materialize(queued)

      assert [
               %{"type" => "delivery", "trusted_origin" => ^trusted_origin},
               %{
                 "type" => "queue_ack"
               }
             ] = events

      session = SessionData.apply_events(queued, events)
      assert [%{trusted_origin: ^trusted_origin}] = session.messages
    end

    test "materialized input dedupe survives compaction and rejects later duplicate delivery" do
      queued =
        reduce_session([
          %{type: "session_created", session_id: "s1"},
          %{
            type: "queue_append",
            session_id: "s1",
            kind: "user_message",
            dedupe_key: "source-1",
            payload: %{source_message_id: "source-1", content: "first"}
          }
        ])

      {events, true, hwm} = materialize(queued)

      compacted =
        queued
        |> SessionData.apply_events(events)
        |> bump_hwm(hwm)
        |> SessionData.apply_event(%{
          type: "compaction",
          session_id: "s1",
          compacted_through: 1,
          summary: "summary through first",
          summary_sequence: 1
        })
        |> SessionData.apply_event(%{
          type: "queue_append",
          session_id: "s1",
          kind: "user_message",
          dedupe_key: "source-1",
          payload: %{source_message_id: "source-1", content: "duplicate"}
        })

      assert compacted.input_queue == []
      assert MapSet.member?(compacted.input_dedupe, "source-1")
      assert Enum.map(compacted.messages, & &1.content) == ["first"]
    end

    test "wait timeout queue append keeps wait until runtime message materialization" do
      base =
        reduce_session([
          %{type: "session_created", session_id: "s1"},
          %{
            type: "wait_set",
            session_id: "s1",
            wait: %{
              "wait_id" => "wait-1",
              "reason" => "worker reply",
              "deadline_ms" => 100
            }
          },
          %{
            type: "queue_append",
            session_id: "s1",
            kind: "runtime_message",
            dedupe_key: "wait-timeout:s1:wait-1",
            payload: %{
              runtime_message_id: "wait-timeout:s1:wait-1",
              type: "wait_expired",
              wait_id: "wait-1",
              reason: "worker reply",
              deadline_ms: 100,
              elapsed_ms: 60_000,
              overdue_ms: 5
            }
          }
        ])

      assert base.wait["wait_id"] == "wait-1"
      assert SessionData.query(base, :derived_state) == :queued

      {events, true, _hwm} = materialize(base)

      assert Enum.map(events, & &1["type"]) == ["runtime_message", "queue_ack"]

      materialized = SessionData.apply_events(base, events)

      assert materialized.wait == nil
      assert materialized.queue_ack_id == 1

      assert [
               %{
                 role: "runtime",
                 type: "wait_expired",
                 wait_id: "wait-1",
                 elapsed_ms: 60_000,
                 overdue_ms: 5
               }
             ] =
               materialized.messages
    end

    for {name, limit, activated?, delivered, remaining} <- [
          {"materialize batch respects the limit when wakeable input is beyond the batch", 2,
           false, ["context one", "context two"], ["go", "later"]},
          {"materialize batch includes all queued inputs up to the batch limit once activated", 4,
           true, ["context one", "context two", "go", "later"], []}
        ] do
      test name do
        queued =
          reduce_session([
            %{type: "session_created", session_id: "s1"}
            | for {id, content, wake} <- [
                    {"ctx-1", "context one", false},
                    {"ctx-2", "context two", false},
                    {"go", "go", true},
                    {"later", "later", true}
                  ] do
                %{
                  type: "queue_append",
                  session_id: "s1",
                  kind: "user_message",
                  wake: wake,
                  dedupe_key: id,
                  payload: %{source_message_id: id, content: content}
                }
              end
          ])

        limit = unquote(limit)
        assert {events, unquote(activated?), ^limit} = materialize(queued, limit)

        assert Enum.map(Enum.filter(events, &(&1["type"] == "delivery")), & &1["content"]) ==
                 unquote(delivered)

        assert List.last(events)["queue_ack_id"] == limit

        materialized = SessionData.apply_events(queued, events)
        assert materialized.queue_ack_id == limit
        assert Enum.map(materialized.input_queue, &queue_payload_content/1) == unquote(remaining)
      end
    end

    test "provider-backed wakeable inputs materialize one source activation at a time" do
      origin = fn source_message_id, thread_ts ->
        %{
          "provider" => "slack",
          "source_actor_type" => "provider_user",
          "source_message_id" => source_message_id,
          "provider_context" => %{
            "connect_id" => "slack-1",
            "channel_id" => "C-thread-race",
            "thread_ts" => thread_ts,
            "message_ts" => thread_ts
          }
        }
      end

      meeting_source = "im_provider:slack:slack-1:event-meeting"
      completion_source = "tool-call-result:join-meeting"
      unrelated_source = "im_provider:slack:slack-1:event-unrelated"

      queued =
        reduce_session([
          %{type: "session_created", session_id: "s1"},
          %{
            type: "queue_append",
            session_id: "s1",
            kind: "user_message",
            wake: true,
            dedupe_key: meeting_source,
            payload: %{
              source_message_id: meeting_source,
              content: "https://meet.google.com/nus-bxnr-wgt join",
              trusted_origin: origin.(meeting_source, "1788502784.380329")
            }
          },
          %{
            type: "queue_append",
            session_id: "s1",
            kind: "user_message",
            wake: false,
            dedupe_key: unrelated_source <> ":source-context",
            payload: %{
              source_message_id: unrelated_source <> ":source-context",
              activation_source_message_id: unrelated_source,
              role: "summary",
              content: "next request facts"
            }
          },
          %{
            type: "queue_append",
            session_id: "s1",
            kind: "user_message",
            wake: true,
            dedupe_key: unrelated_source,
            payload: %{
              source_message_id: unrelated_source,
              content: "这个",
              trusted_origin: origin.(unrelated_source, "1788502784.112249")
            }
          },
          %{
            type: "queue_append",
            session_id: "s1",
            kind: "runtime_message",
            wake: true,
            dedupe_key: completion_source,
            payload: %{
              runtime_message_id: completion_source,
              type: "tool_call_completed",
              content: "meeting tool completed",
              trusted_origin: origin.(meeting_source, "1788502784.380329")
            }
          }
        ])

      {first_events, true, first_hwm} =
        materialize(queued)

      assert first_hwm == 1

      assert materialize(queued, 1) ==
               {first_events, true, first_hwm}

      assert Enum.map(
               Enum.filter(first_events, &(&1["type"] == "delivery")),
               & &1["source_message_id"]
             ) == [meeting_source]

      assert List.last(first_events)["queue_ack_id"] == 1

      after_first =
        SessionData.apply_events(queued, first_events)

      assert Enum.map(after_first.input_queue, &queue_payload_content/1) == [
               "next request facts",
               "这个",
               "meeting tool completed"
             ]

      {completion_events, true, completion_hwm} =
        materialize(after_first)

      assert completion_hwm == 2

      assert materialize(after_first, 1) ==
               {completion_events, true, completion_hwm}

      assert [
               %{"type" => "runtime_message", "runtime_message_id" => ^completion_source},
               %{"type" => "queue_consume", "queue_id" => 4}
             ] = completion_events

      assert :ok = SessionState.validate_events(completion_events)

      before_ack = SessionData.apply_events(after_first, completion_events)

      assert Enum.map(before_ack.input_queue, &queue_payload_content/1) == [
               "next request facts",
               "这个"
             ]

      assert before_ack.queue_ack_id == 1
      assert {[], false, 0} = materialize(before_ack)

      after_ack =
        SessionData.apply_event(before_ack, %{
          "type" => "ack",
          "session_id" => "s1",
          "last_ack_message_id" => completion_hwm
        })

      {second_events, true, second_hwm} =
        materialize(after_ack)

      assert second_hwm == 4

      assert Enum.map(
               Enum.filter(second_events, &(&1["type"] == "delivery")),
               & &1["source_message_id"]
             ) == [unrelated_source <> ":source-context", unrelated_source]
    end

    for {label, event, error} <- [
          {"delivery events",
           %{
             type: "delivery",
             session_id: "s1",
             message_id: 1,
             source_message_id: "src-A",
             content: "hi"
           }, :delivery_must_come_from_queue},
          {"runtime messages",
           %{
             type: "runtime_message",
             session_id: "s1",
             message_id: 1,
             runtime_message_id: "runtime-direct-1",
             runtime_message_type: "runtime_recovered",
             summary: "recovered"
           }, :runtime_message_must_come_from_queue}
        ] do
    end

    test "session log dedupes by explicit dedupe key and stays out of model context" do
      session =
        reduce_session([
          %{type: "session_created", session_id: "s1"},
          %{
            type: "session_log_message",
            session_id: "s1",
            dedupe_key: "event-key-1",
            content: "hidden event"
          },
          %{
            type: "session_log_message",
            session_id: "s1",
            dedupe_key: "event-key-1",
            content: "duplicate event"
          },
          %{
            type: "delivery",
            from_queue: true,
            session_id: "s1",
            message_id: 2,
            source_message_id: "src-user-1",
            content: "visible input"
          }
        ])

      assert Enum.map(session.messages, & &1.role) == ["event", "user"]
      assert Enum.map(session.messages, & &1.content) == ["hidden event", "visible input"]

      assert Compaction.context(SalixAgent.InternalSession.open(session)) == [
               %{
                 id: 2,
                 seq: 2,
                 role: "user",
                 content: "visible input",
                 source_message_id: "src-user-1"
               }
             ]
    end

    test "pending input queue materializes user and runtime messages with one ack boundary" do
      queued =
        reduce_session([
          %{type: "session_created", session_id: "s1"},
          %{
            type: "queue_append",
            session_id: "s1",
            kind: "user_message",
            wake: false,
            dedupe_key: "pre-1",
            payload: %{source_message_id: "pre-1", content: "pre"}
          },
          %{
            type: "queue_append",
            session_id: "s1",
            kind: "runtime_message",
            wake: true,
            dedupe_key: "runtime-1",
            payload: %{
              runtime_message_id: "runtime-1",
              type: "tool_call_completed",
              summary: "tool finished",
              content: ~s({"type":"tool_call_completed","result":{"content":"short result"}}),
              source_tool_call_id: "call-1"
            }
          }
        ])

      assert queued.messages == []
      assert queued.queue_ack_id == 0
      assert queued.next_queue_id == 3
      assert SessionData.query(queued, :derived_state) == :queued

      {events, true, hwm} = materialize(queued)
      assert hwm == 2

      materialized = SessionData.apply_events(queued, events)
      assert materialized.queue_ack_id == 2
      assert Enum.map(materialized.messages, & &1.role) == ["user", "runtime"]

      assert Enum.map(materialized.messages, & &1.content) == [
               "pre",
               ~s({"type":"tool_call_completed","result":{"content":"short result"}})
             ]

      assert List.last(materialized.messages).runtime_message_id == "runtime-1"

      runtime_context_message =
        List.last(Compaction.context(SalixAgent.InternalSession.open(materialized)))

      assert runtime_context_message.role == "runtime"
      assert runtime_context_message.kind == "runtime_message"
      assert runtime_context_message.runtime_message_id == "runtime-1"
      assert runtime_context_message.type == "tool_call_completed"
      refute Map.has_key?(runtime_context_message, :runtime_type)

      assert SessionData.query(materialized, :derived_state) == :queued
    end

    for {kind, payload, message} <- [
          {"runtime_message", %{type: "runtime_recovered", summary: "missing identity"},
           "runtime_message queue item requires runtime_message_id or dedupe_key"},
          {"user_message", %{role: "user", content: "missing source"},
           "user_message queue item requires source_message_id or dedupe_key"}
        ] do
    end

    test "async tool calls are session-local records" do
      session =
        reduce_session([
          %{
            type: "async_tool_call_started",
            session_id: "s1",
            tool_call_id: "call-1",
            tool_name: "permission.request",
            input: "{}",
            started_at: 10
          },
          %{
            type: "async_tool_call_completed",
            session_id: "s1",
            tool_call_id: "call-1",
            result: %{"ok" => true},
            completed_at: 20
          }
        ])

      assert {:ok, %{"status" => "completed", "result" => %{"ok" => true}} = record} =
               SessionData.query(session, :lookup_async_call, "call-1")

      # The terminal result left the non-terminal map for the result log,
      # with a live-reference pointer at its seq.
      refute Map.has_key?(session.async_tool_calls, "call-1")
      assert session.async_result_refs["call-1"] == record["seq"]
    end

    test "fork copies internal transcript metadata but not wait or async state" do
      source =
        reduce_session(
          [
            %{type: "session_created", session_id: "source", platform: "telegram"},
            %{
              type: "delivery",
              from_queue: true,
              session_id: "source",
              message_id: 1,
              dedupe_key: "inbound-message-1",
              source_message_id: "source-message-1",
              content: "hello"
            },
            %{type: "wait_set", session_id: "source", wait: %{"reason" => "later"}},
            %{type: "async_tool_call_started", session_id: "source", tool_call_id: "call-1"}
          ],
          "agent-1",
          "source"
        )
        |> then(fn %SessionState{} = session ->
          %SessionState{
            session
            | input_dedupe: MapSet.put(session.input_dedupe, "compacted-source")
          }
        end)

      {:ok, fork} =
        fork_session(source, "fork", %{"created_at" => 100, "hidden" => true})

      assert source.input_dedupe ==
               MapSet.new(["inbound-message-1", "source-message-1", "compacted-source"])

      assert fork.source_session_id == "source"
      assert fork.source_agent_id == "agent-1"
      assert fork.platform == "telegram"
      assert fork.hidden == true
      assert Enum.map(fork.messages, & &1.content) == ["hello"]
      # A fork is a new internal session boundary: copy stable transcript
      # metadata and its already-materialized input dedupe facts, but never
      # inherit pending input or async/wait state from source.
      assert fork.input_queue == []

      # The ledger is derived from the records that actually travelled
      # (owner 2026-08-08): coordinate-free source keys cannot be clamped
      # to the snapshot, and whole-copy let post-cutoff keys suppress
      # legitimate branch deliveries.
      assert fork.input_dedupe == MapSet.new(["inbound-message-1", "source-message-1"])

      assert is_nil(fork.wait)
      assert fork.async_tool_calls == %{}
      assert fork.next_message_id == 2

      duplicate =
        SessionData.apply_event(fork, %{
          type: "queue_append",
          session_id: "fork",
          kind: "user_message",
          dedupe_key: "inbound-message-1",
          payload: %{source_message_id: "source-message-1", content: "duplicate"}
        })

      assert duplicate.input_queue == []
    end
  end

  describe "generic store root" do
    setup do
      prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
      SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
      start_supervised!(SalixStore.S3.Fake)
      on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, prev) end)
      {:ok, agent: SalixAgent.TestSupport.new_agent_id()}
    end
  end

  defp reduce_session(events, agent_id \\ "agent-1", session_id \\ "s1") do
    agent_id
    |> new_session(session_id)
    |> SessionData.apply_events(events)
  end

  defp new_session(agent_id, session_id, attrs \\ %{}),
    do: agent_id |> InternalSession.new(session_id, attrs) |> InternalSession.export()

  defp normalize(state),
    do: state |> InternalSession.open() |> InternalSession.normalize() |> InternalSession.export()

  defp bump_hwm(state, hwm) do
    state
    |> InternalSession.open()
    |> InternalSession.bump_hwm(hwm)
    |> InternalSession.export()
  end

  defp fork_session(state, session_id, attrs) do
    with {:ok, child} <-
           state |> InternalSession.open() |> InternalSession.fork(session_id, attrs) do
      {:ok, InternalSession.export(child)}
    end
  end

  defp materialize(state),
    do: state |> InternalSession.open() |> InternalSession.materialize_pending_input_events()

  defp materialize(state, limit),
    do: state |> InternalSession.open() |> InternalSession.materialize_pending_input_events(limit)

  defp queue_payload_content(item) do
    payload = item["payload"] || item[:payload] || %{}
    payload["content"] || payload[:content]
  end
end
