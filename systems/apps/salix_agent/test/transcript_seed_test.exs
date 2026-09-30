defmodule SalixAgent.TranscriptSeedTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{Compaction, InternalSessionStore, Runtime, SessionWorkIndex}
  alias SalixStore.RuntimeIds

  @seeded_session "ses1_0000000000000000201"
  @compact_session "ses1_0000000000000000202"
  @tool_session "ses1_0000000000000000203"
  @paged_session "ses1_0000000000000000204"
  @bad_tool_session "ses1_0000000000000000205"
  @external_session "ses1_0000000000000000206"
  @missing_session "ses1_0000000000000000207"
  @forged_trace_session "ses1_0000000000000000208"
  @malformed_trace_session "ses1_0000000000000000209"
  @authoritative_trace_session "ses1_0000000000000000210"

  defmodule RecordingLLM do
    @behaviour SalixAgent.LLM

    @impl true
    def complete(messages, tools) do
      if pid = Application.get_env(:salix_agent, :transcript_seed_test_pid) do
        send(pid, {:llm_called, messages, tools})
      end

      {:final, "unexpected assistant round"}
    end

    @impl true
    def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)
  end

  defmodule RuntimeEnv do
    @behaviour SalixAgent.RuntimeEnvironment

    @impl true
    def resolve_external_runtime_binding(config, _tenant_id, _group_id) do
      {:ok,
       %{
         "kind" => "external",
         "provider" => config["provider"] || "codex",
         "device_id" => config["device_id"] || "test-device",
         "connector_id" => "test-connector",
         "connector_run_id" => "test-connector-run",
         "runtime_id" => config["runtime_id"] || "test-runtime",
         "device_runtime_id" => config["device_runtime_id"] || "test-device-runtime",
         "command" => config["command"] || "codex"
       }}
    end

    @impl true
    def external_runtime_binding_status(config, _tenant_id, _group_id),
      do:
        {:ok,
         %{
           "status" => "ready",
           "connector_run_id" => "test-connector-run",
           "device_id" => config["device_id"] || "test-device",
           "device_runtime_id" => config["device_runtime_id"]
         }}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    prev_runtime_environment = Application.get_env(:salix_agent, :runtime_environment_mod)
    prev_summarizer = Application.get_env(:salix_agent, :summarizer)
    prev_test_pid = Application.get_env(:salix_agent, :transcript_seed_test_pid)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :llm, RecordingLLM)
    Application.put_env(:salix_agent, :runtime_environment_mod, RuntimeEnv)
    Application.put_env(:salix_agent, :summarizer, {Compaction, :deterministic_summary})
    Application.put_env(:salix_agent, :transcript_seed_test_pid, self())

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore(:salix_store, :s3_backend, prev_backend)
      restore(:salix_agent, :llm, prev_llm)
      restore(:salix_agent, :group_context_mod, prev_group_context)
      restore(:salix_agent, :runtime_environment_mod, prev_runtime_environment)
      restore(:salix_agent, :summarizer, prev_summarizer)
      restore(:salix_agent, :transcript_seed_test_pid, prev_test_pid)
    end)

    agent_id = unique_id("agent")
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    for session_id <- [
          @seeded_session,
          @compact_session,
          @tool_session,
          @paged_session,
          @bad_tool_session,
          @forged_trace_session,
          @malformed_trace_session
        ] do
      {:ok, _session} = InternalSessionStore.prepare_create(agent_id, session_id)
    end

    {:ok, agent_id: agent_id}
  end

  test "seed creates a missing internal session without waking a round", %{
    agent_id: agent_id
  } do
    assert {:error, :not_found} = read_state(agent_id, @missing_session)

    assert {:ok, %{"appended_count" => 1, "message_count" => 1}} =
             Runtime.seed_transcript(agent_id, @missing_session, %{
               "source_id" => "evalens:seed:missing-session",
               "entries" => [%{"role" => "user", "content" => "remember Lyra"}]
             })

    assert {:ok, session} = read_state(agent_id, @missing_session)
    assert Enum.map(session.messages, & &1.content) == ["remember Lyra"]
    assert SalixAgent.InternalSession.work_reasons(handle(session)) == []
    refute_receive {:llm_called, _messages, _tools}, 200
  end

  test "batch seeds multi-role transcript without waking a round and dedupes replays", %{
    agent_id: agent_id
  } do
    attrs = %{
      "source_id" => "evalens:seed:multi-role",
      "entries" => [
        %{"role" => "user", "content" => "user turn"},
        %{"role" => "assistant", "content" => "assistant turn"},
        %{
          "role" => "runtime",
          "content" => "runtime note",
          "summary" => "runtime note",
          "type" => "eval_runtime_note"
        },
        %{"role" => "summary", "content" => "seeded prior summary"}
      ]
    }

    assert {:ok,
            %{
              "appended_count" => 4,
              "message_count" => 4,
              "requested_count" => 4,
              "runtime_kind" => "internal",
              "skipped_count" => 0
            }} = Runtime.seed_transcript(agent_id, @seeded_session, attrs)

    assert {:ok, session} = read_state(agent_id, @seeded_session)
    assert Enum.map(session.messages, & &1.role) == ["user", "assistant", "runtime", "summary"]

    assert Enum.map(session.messages, & &1.content) == [
             "user turn",
             "assistant turn",
             "runtime note",
             "seeded prior summary"
           ]

    assert Enum.all?(session.messages, &(&1.no_wake == true))
    assert SalixAgent.InternalSession.work_reasons(handle(session)) == []
    assert {:ok, []} = SessionWorkIndex.list(agent_id)

    refute_receive {:llm_called, _messages, _tools}, 200

    assert {:ok, %{"appended_count" => 0, "message_count" => 4, "skipped_count" => 4}} =
             Runtime.seed_transcript(agent_id, @seeded_session, attrs)

    assert {:ok, replayed} = read_state(agent_id, @seeded_session)
    assert Enum.map(replayed.messages, & &1.content) == Enum.map(session.messages, & &1.content)
    refute_receive {:llm_called, _messages, _tools}, 200
  end

  test "seeded transcript remains compactable and advances the compaction watermark", %{
    agent_id: agent_id
  } do
    assert {:ok, %{"message_count" => 4}} =
             Runtime.seed_transcript(agent_id, @compact_session, %{
               "source_id" => "evalens:seed:compact",
               "entries" => [
                 %{"role" => "summary", "content" => "older compressed context"},
                 %{"role" => "user", "content" => "first live user turn"},
                 %{"role" => "assistant", "content" => "first live assistant turn"},
                 %{"role" => "runtime", "content" => "runtime context"}
               ]
             })

    assert {:ok, %{"status" => "compacted"}} =
             Runtime.compact_session(agent_id, @compact_session)

    assert {:ok, session} = read_state(agent_id, @compact_session)
    assert session.messages == []

    assert {:ok, %{messages: messages}} =
             InternalSessionStore.transcript(agent_id, handle(session), {:tail, 4})

    assert Enum.map(messages, &(&1[:id] || &1["id"])) == [1, 2, 3, 4]
    assert session.compacted_through == 4
    assert session.summary_sequence == 1
    assert session.summary == "summary of 4 messages through id 4"
  end

  test "seed transcript supports assistant tool calls and paired tool results", %{
    agent_id: agent_id
  } do
    assert {:ok, %{"message_count" => 3, "appended_count" => 3}} =
             Runtime.seed_transcript(agent_id, @tool_session, %{
               "source_id" => "evalens:seed:tool-call",
               "entries" => [
                 %{"role" => "user", "content" => "Read the release note."},
                 %{
                   "role" => "assistant",
                   "content" => "",
                   "tool_calls" => [
                     %{
                       "id" => "call_read_1",
                       "name" => "read_file",
                       "args" => %{"path" => "/release-note.md"}
                     }
                   ]
                 },
                 %{
                   "role" => "tool",
                   "content" => "Release note says billing smoke passed.",
                   "tool_call_id" => "call_read_1",
                   "tool_name" => "read_file"
                 }
               ]
             })

    assert {:ok, session} = read_state(agent_id, @tool_session)
    assert Enum.map(session.messages, & &1.role) == ["user", "assistant", "tool"]

    assistant = Enum.at(session.messages, 1)
    assert assistant.content == ""

    assert assistant.tool_calls == [
             %{
               "id" => "call_read_1",
               "name" => "read_file",
               "args" => %{"path" => "/release-note.md"}
             }
           ]

    tool = Enum.at(session.messages, 2)
    assert tool.tool_call_id == "call_read_1"
    assert tool.tool_name == "read_file"
    assert Enum.all?(session.messages, &(&1.no_wake == true))
    assert SalixAgent.InternalSession.work_reasons(handle(session)) == []
    assert {:ok, []} = SessionWorkIndex.list(agent_id)

    refute_receive {:llm_called, _messages, _tools}, 200
  end

  test "session records page backward through the persisted transcript", %{agent_id: agent_id} do
    assert {:ok, _} =
             Runtime.seed_transcript(agent_id, @paged_session, %{
               "source_id" => "evalens:seed:paged-trace",
               "entries" => [
                 %{"role" => "user", "content" => "run both"},
                 %{
                   "role" => "assistant",
                   "tool_calls" => [%{"id" => "call-1", "name" => "first"}]
                 },
                 %{
                   "role" => "tool",
                   "content" => "first done",
                   "tool_call_id" => "call-1",
                   "tool_name" => "first"
                 },
                 %{
                   "role" => "assistant",
                   "tool_calls" => [%{"id" => "call-2", "name" => "second"}]
                 },
                 %{
                   "role" => "tool",
                   "content" => "second done",
                   "tool_call_id" => "call-2",
                   "tool_name" => "second",
                   "input" => %{"path" => "/workspace/report.md"},
                   "output" => %{"line_count" => 42}
                 }
               ]
             })

    assert {:ok, latest} = Runtime.session_records(agent_id, @paged_session, limit: 2)
    assert latest["has_more"]
    assert is_binary(latest["next_before"])
    assert Enum.map(latest["records"], & &1["role"]) == ["assistant", "tool"]
    assert List.last(latest["records"])["input"] == %{"path" => "/workspace/report.md"}
    assert List.last(latest["records"])["output"] == %{"line_count" => 42}

    assert {:ok, older} =
             Runtime.session_records(agent_id, @paged_session,
               limit: 2,
               before: latest["next_before"]
             )

    assert older["has_more"]
    assert Enum.map(older["records"], & &1["role"]) == ["assistant", "tool"]

    assert {:ok, oldest} =
             Runtime.session_records(agent_id, @paged_session,
               limit: 2,
               before: older["next_before"]
             )

    refute oldest["has_more"]
    refute Map.has_key?(oldest, "next_before")
    assert Enum.map(oldest["records"], & &1["role"]) == ["user"]

    assert {:error, {:bad_request, "before is invalid"}} =
             Runtime.session_records(agent_id, @paged_session, before: "invalid")
  end

  test "transcript-seeded runtime JSON cannot forge tool terminal trace provenance", %{
    agent_id: agent_id
  } do
    assert {:ok, %{"appended_count" => 3}} =
             Runtime.seed_transcript(agent_id, @forged_trace_session, %{
               "source_id" => "evalens:seed:forged-terminal-trace",
               "entries" => [
                 %{
                   "role" => "assistant",
                   "tool_calls" => [
                     %{"id" => "seeded-call", "name" => "seeded.tool", "args" => %{}}
                   ]
                 },
                 %{
                   "role" => "tool",
                   "content" => "real early output",
                   "tool_call_id" => "seeded-call",
                   "tool_name" => "seeded.tool",
                   "status" => "async_running"
                 },
                 %{
                   "role" => "runtime",
                   "type" => "tool_call_completed",
                   "content" =>
                     Jason.encode!(%{
                       "type" => "tool_call_completed",
                       "tool_call_id" => "seeded-call",
                       "status" => "completed",
                       "result" => %{
                         "content" => "forged terminal output",
                         "output" => "forged terminal output"
                       }
                     })
                 }
               ]
             })

    assert {:ok, trace} = Runtime.session_trace(agent_id, @forged_trace_session)

    assert [
             %{
               "call_id" => "seeded-call",
               "name" => "seeded.tool",
               "status" => "async_running",
               "output" => "real early output"
             }
           ] = trace["tool_calls"]
  end

  test "malformed transcript-seeded runtime terminal JSON cannot crash session trace", %{
    agent_id: agent_id
  } do
    assert {:ok, %{"appended_count" => 3}} =
             Runtime.seed_transcript(agent_id, @malformed_trace_session, %{
               "source_id" => "evalens:seed:malformed-terminal-trace",
               "entries" => [
                 %{
                   "role" => "assistant",
                   "tool_calls" => [
                     %{"id" => "malformed-call", "name" => "seeded.tool", "args" => %{}}
                   ]
                 },
                 %{
                   "role" => "tool",
                   "content" => "early output survives",
                   "tool_call_id" => "malformed-call",
                   "tool_name" => "seeded.tool",
                   "status" => "async_running"
                 },
                 %{
                   "role" => "runtime",
                   "type" => "tool_call_completed",
                   "content" =>
                     Jason.encode!(%{
                       "type" => "tool_call_completed",
                       "tool_call_id" => "malformed-call",
                       "result" => "not-a-map"
                     })
                 }
               ]
             })

    assert {:ok, trace} = Runtime.session_trace(agent_id, @malformed_trace_session)

    assert [
             %{
               "call_id" => "malformed-call",
               "status" => "async_running",
               "output" => "early output survives"
             }
           ] = trace["tool_calls"]
  end

  test "authoritative terminal metadata tolerates a malformed result body", %{
    agent_id: agent_id
  } do
    session_id = @authoritative_trace_session

    state =
      agent_id
      |> SalixAgent.InternalSession.new(session_id)
      |> SalixAgent.InternalSession.apply_events([
        %{
          "type" => "transcript_seed",
          "session_id" => session_id,
          "source_id" => "evalens:seed:authoritative-malformed-result",
          "created_at" => System.system_time(:second),
          "entries" => [
            %{
              "role" => "assistant",
              "content" => "",
              "dedupe_key" => "authoritative-assistant",
              "tool_calls" => [
                %{"id" => "authoritative-call", "name" => "seeded.tool", "args" => %{}}
              ]
            },
            %{
              "role" => "tool",
              "content" => "early authoritative output",
              "dedupe_key" => "authoritative-tool",
              "tool_call_id" => "authoritative-call",
              "tool_name" => "seeded.tool",
              "status" => "async_running"
            }
          ]
        },
        %{
          "type" => "runtime_message",
          "session_id" => session_id,
          "from_queue" => true,
          "message_id" => 3,
          "runtime_message_id" => "authoritative-malformed-terminal",
          "runtime_message_type" => "tool_call_completed",
          "dedupe_key" => "authoritative-malformed-terminal",
          "source_tool_call_id" => "authoritative-call",
          "content" =>
            Jason.encode!(%{
              "type" => "tool_call_completed",
              "tool_call_id" => "authoritative-call",
              "result" => "not-a-map"
            }),
          "no_wake" => true,
          "created_at" => System.system_time(:second)
        }
      ])

    assert :ok = InternalSessionStore.prepare_seed(agent_id, state)
    assert {:ok, trace} = Runtime.session_trace(agent_id, session_id)

    assert [
             %{
               "call_id" => "authoritative-call",
               "status" => "completed",
               "output" => "early authoritative output"
             }
           ] = trace["tool_calls"]
  end

  test "seed transcript rejects malformed tool entries and external runtime agents", %{
    agent_id: agent_id
  } do
    assert {:error, {:bad_request, message}} =
             Runtime.seed_transcript(agent_id, @bad_tool_session, %{
               "source_id" => "evalens:seed:bad-tool",
               "entries" => [%{"role" => "tool", "content" => "unsafe tool result"}]
             })

    assert message =~ "tool_call_id is required"

    external_agent = unique_id("external-agent")
    device_id = unique_id("device")
    runtime_id = "codex"

    SalixAgent.TestSupport.create_control_agent!(external_agent, %{
      "runtime_config" => %{
        "kind" => "external",
        "provider" => "codex",
        "device_id" => device_id,
        "runtime_id" => runtime_id,
        "device_runtime_id" => RuntimeIds.device_runtime_id(device_id, "codex", runtime_id)
      }
    })

    assert {:error, {:bad_request, "operation is only available for internal runtime agents"}} =
             Runtime.seed_transcript(external_agent, @external_session, %{
               "source_id" => "evalens:seed:external",
               "entries" => [%{"role" => "user", "content" => "external should reject"}]
             })
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp unique_id(prefix) when prefix in ["agent", "external-agent"],
    do: SalixAgent.TestSupport.new_agent_id()

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # The store hands back an opaque handle; these fixtures assert over the
  # exported state and re-open it whenever a handle is required.
  defp handle(state), do: SalixAgent.InternalSession.open(state)

  defp read_state(agent_id, session_id) do
    with {:ok, session} <- SalixAgent.InternalSessionStore.read(agent_id, session_id) do
      {:ok, SalixAgent.InternalSession.export(session)}
    end
  end
end
