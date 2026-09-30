defmodule SalixAgent.CompactionLlmTest do
  @moduledoc """
  The willow-parity compaction port: LLM-backed summarization (the session's
  own model answers a `<compaction-summary>` request; the stored summary is
  wrapped in `<compacted-context>` tags), soft-fail on a tag-less or erroring
  response, and the auto trigger at 0.9 × the template context window
  (provider-reported tokens). Against the Fake S3 backend with the scriptable
  `LLM.Mock`.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{
    AgentWorkspace,
    Compaction,
    InternalSession,
    InternalSessionActor,
    InternalSessionFleet,
    InternalSessionStore,
    SessionDriver,
    Tools
  }

  alias SalixAgent.LLM.Mock
  alias SalixStore.Agent.Owned

  defmodule FailingLlmResolver do
    @behaviour SalixAgent.LlmResolver

    @impl true
    def resolve(_agent_id), do: {:error, :missing_template}
  end

  defmodule ControlTemplateResolver do
    @behaviour SalixAgent.LlmResolver

    @impl true
    def resolve(agent_id), do: SalixAgent.Templates.resolve_llm_for_agent(agent_id)
  end

  defmodule ConfiguredMediaResolver do
    @behaviour SalixAgent.MediaResolver

    @impl true
    def resolve(_agent_id) do
      {:ok,
       %{
         "video_config" => %{
           "provider" => "test",
           "model" => "test",
           "provider_config" => %{"base_url" => "https://example.test"}
         }
       }}
    end
  end

  defmodule NativeCompactLLM do
    @behaviour SalixAgent.LLM

    @impl true
    def complete(_messages, _tools), do: raise("summary LLM should not be called")

    @impl true
    def complete(_messages, _tools, _opts), do: raise("summary LLM should not be called")

    @impl true
    def compact_context(messages, _tools, opts) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:native_compact, messages, opts})

      {:ok,
       [
         %{
           "type" => "compaction",
           "id" => "cmp_test",
           "encrypted_content" => "ciphertext"
         }
       ], %{"usage" => %{"total_tokens" => 12}}}
    end
  end

  setup do
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_llm_resolver = Application.get_env(:salix_agent, :llm_resolver)
    prev_summarizer = Application.get_env(:salix_agent, :summarizer)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    # The production path: no summarizer seam, LLM = scripted mock.
    Application.put_env(:salix_agent, :llm, Mock)
    Application.put_env(:salix_agent, :llm_resolver, ControlTemplateResolver)
    Application.delete_env(:salix_agent, :summarizer)
    start_supervised!(Mock)
    Mock.script([])

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, prev_backend)
      restore(:llm, prev_llm)
      restore(:llm_resolver, prev_llm_resolver)
      restore(:summarizer, prev_summarizer)
      restore(:group_context_mod, prev_group_context)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    runtime = %{agent_id: agent}

    commit_session!(agent, "ses1_0000000000000001001", [
      %{
        "type" => "session_created",
        "session_id" => "ses1_0000000000000001001",
        "billing_context" => %{
          "billing_account_id" => "ba-compact",
          "entrypoint" => "conversation_send"
        }
      },
      %{
        "type" => "delivery",
        "from_queue" => true,
        "session_id" => "ses1_0000000000000001001",
        "message_id" => 1,
        "content" => "build the report",
        "billing_context" => %{
          "billing_account_id" => "ba-compact",
          "entrypoint" => "conversation_send"
        }
      },
      %{
        "type" => "assistant",
        "session_id" => "ses1_0000000000000001001",
        "message_id" => 2,
        "content" => "Wrote /report.md with the Q2 numbers."
      },
      %{
        "type" => "ack",
        "session_id" => "ses1_0000000000000001001",
        "last_ack_message_id" => 2
      }
    ])

    {:ok, agent: agent, owned: runtime}
  end

  describe "LLM-backed compaction (willow Compact)" do
    test "requires session runtime context rather than the agent lease handle", %{owned: owned} do
      lease = %Owned{agent_id: owned.agent_id}

      assert {:error, :agent_lease_not_session_runtime_context} =
               Compaction.compact(lease, "ses1_0000000000000001001")

      assert {:error, :agent_lease_not_session_runtime_context} =
               Compaction.maybe_compact_session(lease, "ses1_0000000000000001001")

      assert {:error, {:session_runtime_context_missing, "ses1_0000000000000001001"}} =
               Compaction.compact(%{agent_id: owned.agent_id}, "ses1_0000000000000001001")

      assert {:error,
              {:session_runtime_context_mismatch, "ses1_0000000000000001001",
               "ses1_0000000000000001022"}} =
               Compaction.maybe_compact_session(
                 %{agent_id: owned.agent_id, session_id: "ses1_0000000000000001022"},
                 "ses1_0000000000000001001"
               )
    end

    test "summarizes via the session LLM and stores <compacted-context>", %{owned: owned} do
      Mock.script([
        {:final,
         "Here you go.\n<compaction-summary>\nUser asked for a report; /report.md written.\n</compaction-summary>"}
      ])

      {:ok, owned, %{"status" => "compacted"}} =
        Compaction.compact(
          runtime_context(owned, "ses1_0000000000000001001"),
          "ses1_0000000000000001001"
        )

      session = read_session!(owned.agent_id, "ses1_0000000000000001001")

      assert session.summary ==
               "<compacted-context>\nUser asked for a report; /report.md written.\n</compacted-context>"

      assert session.compacted_through == 2
      assert session.summary_sequence == 1
      # Compaction preserves the archived transcript and removes the hot prefix.
      assert session.messages == []

      assert {:ok, %{messages: messages}} =
               InternalSessionStore.transcript(owned.agent_id, handle(session), {:tail, 2})

      assert Enum.map(messages, &(&1[:id] || &1["id"])) == [1, 2]

      assert [%{role: "summary", content: "<compacted-context>" <> _}] =
               Compaction.context(handle(session))
    end

    test "does not absorb historical project knowledge into a compaction summary", %{
      owned: owned
    } do
      session_id = "ses1_0000000000000001001"

      commit_session!(owned.agent_id, session_id, [
        %{
          "type" => "runtime_message",
          "from_context_provider" => true,
          "session_id" => session_id,
          "message_id" => 3,
          "runtime_message_id" => "project-knowledge:historical",
          "runtime_message_type" => "project_knowledge",
          "summary" => "Resolved project knowledge for this question",
          "content" => "The historical launch code is ORCHID.",
          "no_wake" => true
        }
      ])

      test_pid = self()

      summarizer = fn _previous, live_messages ->
        send(test_pid, {:compaction_live_messages, live_messages})
        "summary without question-scoped knowledge"
      end

      assert {:ok, _owned, %{"status" => "compacted"}} =
               Compaction.compact(runtime_context(owned, session_id), session_id,
                 summarizer: summarizer
               )

      assert_receive {:compaction_live_messages, live_messages}
      refute Enum.any?(live_messages, &(&1[:type] == "project_knowledge"))
      refute Enum.any?(live_messages, &String.contains?(&1[:content] || "", "ORCHID"))
    end

    @tag :fresh_input_compaction
    test "automatic compaction keeps unread recommendation facts exact across storage reload", %{
      owned: owned
    } do
      session_id = "ses1_0000000000000001001"
      facts = ~s({"sourceId":"ca_exact-source","url":"https://example.test/messages/123"})

      commit_session!(owned.agent_id, session_id, [
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => session_id,
          "message_id" => 3,
          "content" => facts
        },
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => session_id,
          "message_id" => 4,
          "content" => "ambient context",
          "no_wake" => true
        }
      ])

      parent = self()

      assert {:ok, _owned, %{"status" => "compacted"}} =
               Compaction.maybe_compact_session(runtime_context(owned, session_id), session_id,
                 threshold: 1,
                 summarizer: fn _previous, messages ->
                   send(parent, {:summarized_ids, Enum.map(messages, & &1[:id])})
                   "completed report"
                 end
               )

      assert_receive {:summarized_ids, [1, 2]}
      reloaded = read_session!(owned.agent_id, session_id)
      assert reloaded.compacted_through == 2
      assert InternalSession.has_pending_stable_input?(handle(reloaded))

      assert [%{id: 0}, %{id: 3, content: ^facts}, %{id: 4}] =
               Compaction.context(handle(reloaded))
    end

    @tag :fresh_input_compaction
    test "manual compaction does not summarize the only unread input", %{owned: owned} do
      session_id = "ses1_0000000000000001022"

      commit_session!(owned.agent_id, session_id, [
        %{"type" => "session_created", "session_id" => session_id},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => session_id,
          "message_id" => 1,
          "content" => "first request"
        }
      ])

      assert {:ok, _owned, %{"status" => "noop", "reason" => "no_new_live_messages"}} =
               Compaction.compact(runtime_context(owned, session_id), session_id,
                 summarizer: fn _, _ -> flunk("unread input must not be summarized") end
               )

      reloaded = read_session!(owned.agent_id, session_id)
      assert [%{id: 1, content: "first request"}] = Compaction.context(handle(reloaded))
      assert InternalSession.has_pending_stable_input?(handle(reloaded))
    end

    @tag :fresh_input_compaction
    test "a later assistant append cannot consume input outside its request snapshot", %{
      owned: owned
    } do
      session_id = "ses1_0000000000000001001"

      commit_session!(owned.agent_id, session_id, [
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => session_id,
          "message_id" => 3,
          "content" => "unseen source ca_exact-new"
        },
        %{
          "type" => "assistant",
          "session_id" => session_id,
          "message_id" => 4,
          "request_input_through" => 2,
          "content" => "response to the old request"
        }
      ])

      assert {:ok, _, %{"status" => "compacted"}} =
               Compaction.compact(runtime_context(owned, session_id), session_id,
                 summarizer: fn _, messages ->
                   assert Enum.map(messages, & &1.id) == [1, 2]
                   "old settled history"
                 end
               )

      reloaded = read_session!(owned.agent_id, session_id)
      assert reloaded.compacted_through == 2

      assert Enum.any?(
               Compaction.context(handle(reloaded)),
               &(&1[:content] == "unseen source ca_exact-new")
             )

      assert Enum.find(reloaded.messages, &(&1.id == 4)).request_input_through == 2
    end

    test "keeps the pending no-tool attempt and trailing no-wake context hot", %{owned: owned} do
      commit_session!(owned.agent_id, "ses1_0000000000000001001", [
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001001",
          "message_id" => 3,
          "content" => "continue the report"
        },
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001001",
          "message_id" => 4,
          "content" => "I will keep going.",
          "request_input_through" => 3,
          "tool_calls" => []
        },
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001001",
          "message_id" => 5,
          "role" => "user",
          "content" => "ambient context",
          "no_wake" => true
        }
      ])

      Mock.script([{:final, "<compaction-summary>settled prefix</compaction-summary>"}])

      assert {:ok, _owned, %{"status" => "compacted"}} =
               Compaction.compact(
                 runtime_context(owned, "ses1_0000000000000001001"),
                 "ses1_0000000000000001001"
               )

      session = read_session!(owned.agent_id, "ses1_0000000000000001001")
      assert session.compacted_through == 3
      assert Enum.map(session.messages, & &1.id) == [4, 5]
      assert SalixAgent.TurnOutcome.decision_required?(handle(session))
      assert Enum.map(Compaction.context(handle(session)), & &1[:id]) == [0, 4, 5]
    end

    test "keeps a runnable assistant-tool/result suffix restart-recoverable", %{
      owned: owned
    } do
      session_id = "ses1_0000000000000001001"

      commit_session!(owned.agent_id, session_id, [
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => session_id,
          "message_id" => 3,
          "content" => "inspect the workspace"
        },
        %{
          "type" => "assistant",
          "session_id" => session_id,
          "message_id" => 4,
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call-before-compact",
              "name" => "call",
              "args" => %{"tool" => "fs.list", "params" => %{"path" => "/"}}
            }
          ]
        },
        %{
          "type" => "tool_result",
          "session_id" => session_id,
          "message_id" => 5,
          "tool_call_id" => "call-before-compact",
          "content" => ~s({"entries":["report.md"]})
        },
        ack_event(session_id, 3)
      ])

      before_compact = read_session!(owned.agent_id, session_id)
      assert InternalSession.needs_transcript_continuation?(handle(before_compact))

      assert {:ok, _owned, %{"status" => "compacted"}} =
               Compaction.compact(runtime_context(owned, session_id), session_id,
                 summarizer: fn _previous, _live -> "settled prefix" end
               )

      # Only the completed prefix moves behind the watermark. The exact
      # provider-protocol pair needed for the next round remains durable, so a
      # new actor can derive and recover the work without an in-memory
      # `{:run_round, context}` continuation from the old actor.
      session = read_session!(owned.agent_id, session_id)
      assert session.compacted_through == 3
      assert Enum.map(session.messages, & &1.id) == [4, 5]
      assert InternalSession.needs_transcript_continuation?(handle(session))
      assert InternalSession.derived_state(handle(session)) == :queued
      assert Enum.map(Compaction.context(handle(session)), & &1[:id]) == [0, 4, 5]
    end

    for provider <- ["slack", "internal"] do
      @compaction_source_provider provider
      test "keeps an unacknowledged #{provider} human source hot across tool-continuation compaction",
           %{
             owned: owned
           } do
        session_id = "ses1_0000000000000001001"

        commit_session!(owned.agent_id, session_id, [
          %{
            "type" => "delivery",
            "from_queue" => true,
            "session_id" => session_id,
            "message_id" => 3,
            "source_message_id" => "slack-source-a",
            "content" => "inspect the workspace from thread A",
            "trusted_origin" => %{
              "provider" => @compaction_source_provider,
              "source_actor_type" =>
                if(@compaction_source_provider == "internal", do: "user", else: "provider_user"),
              "source_message_id" => "slack-source-a",
              "provider_context" => %{
                "connect_id" => "slack-connect",
                "channel_id" => "C-source",
                "thread_ts" => "100.000001"
              }
            },
            "provider_reply_obligation" =>
              if(@compaction_source_provider == "slack",
                do: %{
                  "provider" => "slack",
                  "connect_id" => "slack-connect",
                  "channel" => "C-source",
                  "thread_ts" => "100.000001"
                }
              )
          },
          %{
            "type" => "assistant",
            "session_id" => session_id,
            "message_id" => 4,
            "content" => "",
            "request_input_through" => 3,
            "tool_calls" => [
              %{
                "id" => "call-for-slack-source",
                "name" => "call",
                "args" => %{"tool" => "fs.list", "params" => %{"path" => "/"}}
              }
            ]
          },
          %{
            "type" => "tool_result",
            "session_id" => session_id,
            "message_id" => 5,
            "tool_call_id" => "call-for-slack-source",
            "content" => ~s({"entries":["report.md"]})
          }
        ])

        before_compact = read_session!(owned.agent_id, session_id)

        assert SalixAgent.ProviderReplyObligation.pending?(handle(before_compact)) ==
                 (@compaction_source_provider == "slack")

        assert InternalSession.needs_transcript_continuation?(handle(before_compact))

        assert {:ok, _owned, %{"status" => "compacted"}} =
                 Compaction.compact(runtime_context(owned, session_id), session_id,
                   summarizer: fn _previous, messages ->
                     assert Enum.map(messages, & &1.id) == [1, 2]
                     "settled prefix"
                   end
                 )

        session = read_session!(owned.agent_id, session_id)
        assert session.compacted_through == 2
        assert Enum.map(session.messages, & &1.id) == [3, 4, 5]
        assert Enum.map(Compaction.context(handle(session)), & &1[:id]) == [0, 3, 4, 5]

        assert SalixAgent.ProviderReplyObligation.pending?(handle(session)) ==
                 (@compaction_source_provider == "slack")

        assert InternalSession.needs_transcript_continuation?(handle(session))
      end
    end

    test "a prepared legacy compaction cannot commit across the migration coordinate boundary", %{
      owned: owned
    } do
      session_id = "ses1_0000000000000001001"
      key = SalixStore.Keys.agent_internal_runtime_session(owned.agent_id, session_id)
      legacy = %{read_session!(owned.agent_id, session_id) | storage_format: 1}

      {:ok, _} =
        SalixStore.S3.put(
          key,
          SalixStore.Codec.encode_snapshot(legacy)
        )

      {:ok, owner} =
        InternalSessionFleet.ensure_started(owned.agent_id, session_id, process_on_init: false)

      assert {:prepared, prepared} =
               prepare_compaction(runtime_context(owned, session_id), :compact)

      # Even when visible messages happen to retain their coordinates, the
      # old plan's pinned fact/result ceiling has lost its coordinate contract.
      migrated = %{legacy | storage_format: 2}

      {:ok, _} =
        SalixStore.S3.put(
          key,
          SalixStore.Codec.encode_snapshot(migrated)
        )

      parent = self()

      :sys.replace_state(owner, fn data ->
        result = commit_prepared(prepared, {:ok, {:summary, "old coordinate summary"}})
        send(parent, {:migration_compaction, result})
        data
      end)

      assert_receive {:migration_compaction, {:error, {:stale_compaction_snapshot, _}}}, 2_000
      assert read_session!(owned.agent_id, session_id).summary == migrated.summary
    end

    test "commit revalidates the semantic fence after a conditional-write conflict", %{
      owned: owned
    } do
      session_id = "ses1_0000000000000001001"
      context = runtime_context(owned, session_id)

      {:ok, owner} =
        InternalSessionFleet.ensure_started(owned.agent_id, session_id, process_on_init: false)

      assert {:prepared, prepared} = prepare_compaction(context, :compact)

      key = SalixStore.Keys.agent_internal_runtime_session(owned.agent_id, session_id)
      :ok = SalixStore.S3.Fake.set_fault({:pause, :put, key})

      on_exit(fn ->
        if Process.whereis(SalixStore.S3.Fake) && SalixStore.S3.Fake.paused?(),
          do: SalixStore.S3.Fake.release_pause()
      end)

      parent = self()

      commit_task =
        Task.async(fn ->
          :sys.replace_state(owner, fn state ->
            result =
              commit_prepared(
                prepared,
                {:ok, {:summary, "<compacted-context>stale loser</compacted-context>"}}
              )

            send(parent, {:racing_compaction_result, result})
            state
          end)
        end)

      assert eventually(&SalixStore.S3.Fake.paused?/0)

      current = read_session!(owned.agent_id, session_id)

      assert {:ok, _winner} =
               InternalSessionStore.prepare_commit(owned.agent_id, session_id, [
                 %{
                   "type" => "compaction",
                   "session_id" => session_id,
                   "summary" => "<compacted-context>winner summary</compacted-context>",
                   "compacted_through" => 2,
                   "compacted_seq" => InternalSession.covered_seq(handle(current), 2),
                   "summary_sequence" => current.summary_sequence + 1
                 }
               ])

      :ok = SalixStore.S3.Fake.release_pause()

      assert_receive {:racing_compaction_result,
                      {:error, {:stale_compaction_snapshot, _details}}},
                     2_000

      _ = Task.await(commit_task)

      session = read_session!(owned.agent_id, session_id)
      assert session.summary == "<compacted-context>winner summary</compacted-context>"
      refute String.contains?(session.summary, "stale loser")
    end

    test "configured OpenAI Responses compaction stores provider compacted context" do
      Application.put_env(:salix_agent, :llm, NativeCompactLLM)
      Application.put_env(:salix_agent, :llm_resolver, ControlTemplateResolver)
      :persistent_term.put({NativeCompactLLM, :test_pid}, self())
      on_exit(fn -> :persistent_term.erase({NativeCompactLLM, :test_pid}) end)

      agent = SalixAgent.TestSupport.new_agent_id()

      SalixAgent.TestSupport.create_control_agent!(agent, %{
        "provider_config" => %{
          "protocol" => "responses",
          "base_url" => "https://api.openai.test/v1",
          "api_key" => "test-key",
          "compaction" => %{"strategy" => "openai_responses"}
        }
      })

      commit_session!(agent, "ses1_0000000000000001001", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001001"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001001",
          "message_id" => 1,
          "content" => "build the report"
        },
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001001",
          "message_id" => 2,
          "content" => "Wrote /report.md."
        },
        ack_event("ses1_0000000000000001001", 2)
      ])

      assert {:ok, _context, %{"status" => "compacted"}} =
               Compaction.compact(
                 runtime_context(%{agent_id: agent}, "ses1_0000000000000001001"),
                 "ses1_0000000000000001001"
               )

      assert_receive {:native_compact, messages, opts}

      refute Enum.any?(
               messages,
               &(is_binary(&1[:content]) and
                   String.contains?(&1[:content], "Summarize the conversation so far"))
             )

      assert opt(opts, "protocol") == "responses"

      session = read_session!(agent, "ses1_0000000000000001001")
      assert session.summary == nil
      assert session.compacted_through == 2

      assert %{
               "protocol" => "responses",
               "strategy" => "openai_responses",
               "items" => [%{"type" => "compaction", "encrypted_content" => "ciphertext"}]
             } = session.provider_compaction

      assert [
               %{
                 role: "provider_context",
                 provider_meta: %{
                   "responses_items" => [%{"type" => "compaction", "id" => "cmp_test"}]
                 }
               }
             ] = Compaction.context(handle(session))
    end

    test "accepts provider metadata on a tagged final compaction response", %{owned: owned} do
      Mock.script([
        {:final, "<compaction-summary>metadata-bearing summary</compaction-summary>",
         %{"usage" => %{"prompt_tokens" => 1}, "model" => "test-model"}}
      ])

      {:ok, owned, %{"status" => "compacted"}} =
        Compaction.compact(
          runtime_context(owned, "ses1_0000000000000001001"),
          "ses1_0000000000000001001"
        )

      assert read_session!(owned.agent_id, "ses1_0000000000000001001").summary ==
               "<compacted-context>\nmetadata-bearing summary\n</compacted-context>"
    end

    test "drops incomplete calls but keeps provider-complete terminal calls during compaction", %{
      owned: owned
    } do
      defmodule ToolRequestCaptureLLM do
        @behaviour SalixAgent.LLM

        @impl true
        def complete(messages, _tools, _opts) do
          send(:persistent_term.get({__MODULE__, :test_pid}), {:compaction_messages, messages})
          {:final, "<compaction-summary>captured</compaction-summary>"}
        end

        @impl true
        def complete(messages, tools), do: complete(messages, tools, [])
      end

      Application.put_env(:salix_agent, :llm, ToolRequestCaptureLLM)
      :persistent_term.put({ToolRequestCaptureLLM, :test_pid}, self())
      on_exit(fn -> :persistent_term.erase({ToolRequestCaptureLLM, :test_pid}) end)

      commit_session!(owned.agent_id, "ses1_0000000000000001001", [
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001001",
          "message_id" => 3,
          "content" => "calling tools",
          "tool_calls" => [
            %{
              "id" => "call_missing",
              "name" => "call",
              "args" => %{
                "tool" => "help",
                "params" => %{"tool" => "fs.read_file"}
              }
            },
            %{
              "id" => "call_done",
              "name" => "call",
              "args" => %{
                "tool" => "help",
                "params" => %{"tool" => "fs.read_file"}
              }
            },
            %{
              "id" => "terminal_provider_only",
              "name" => "end_turn",
              "args" => %{"outcome" => "done"}
            }
          ],
          "provider_meta" => %{
            "responses_items" => [
              %{
                "type" => "message",
                "content" => [%{"type" => "output_text", "text" => "m"}]
              },
              %{"type" => "function_call", "call_id" => "call_missing", "name" => "call"},
              %{"type" => "function_call", "call_id" => "call_done", "name" => "call"},
              %{
                "type" => "function_call",
                "call_id" => "terminal_provider_only",
                "name" => "end_turn"
              },
              %{
                "type" => "function_call_output",
                "call_id" => "terminal_provider_only",
                "output" => ~s({"status":"accepted","outcome":"done"})
              },
              %{"type" => "reasoning", "summary" => []}
            ]
          }
        },
        %{
          "type" => "tool_result",
          "session_id" => "ses1_0000000000000001001",
          "message_id" => 4,
          "tool_call_id" => "call_done",
          "content" => "done"
        },
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001001",
          "message_id" => 5,
          "content" => "tool exchange settled",
          "tool_calls" => []
        },
        ack_event("ses1_0000000000000001001", 5)
      ])

      {:ok, _owned, %{"status" => "compacted"}} =
        Compaction.compact(
          runtime_context(owned, "ses1_0000000000000001001"),
          "ses1_0000000000000001001"
        )

      assert_receive {:compaction_messages, messages}

      assistant = Enum.find(messages, &(&1[:id] == 3))

      assert Enum.map(assistant.tool_calls, & &1["id"]) == [
               "call_done",
               "terminal_provider_only"
             ]

      response_items = assistant.provider_meta["responses_items"]
      refute Enum.any?(response_items, &(&1["call_id"] == "call_missing"))
      assert Enum.any?(response_items, &(&1["call_id"] == "call_done"))

      terminal_index =
        Enum.find_index(response_items, &(&1["call_id"] == "terminal_provider_only"))

      assert %{
               "type" => "function_call",
               "call_id" => "terminal_provider_only"
             } = Enum.at(response_items, terminal_index)

      assert %{
               "type" => "function_call_output",
               "call_id" => "terminal_provider_only"
             } = Enum.at(response_items, terminal_index + 1)

      assert Enum.any?(response_items, &(&1["type"] == "message"))
      assert Enum.any?(response_items, &(&1["type"] == "reasoning"))
    end

    test "compaction keeps zero-wait attachments provider-neutral instead of loading their bytes" do
      defmodule AsyncAttachmentCaptureLLM do
        @behaviour SalixAgent.LLM

        @impl true
        def complete(messages, _tools, _opts) do
          send(
            :persistent_term.get({__MODULE__, :test_pid}),
            {:async_attachment_compaction_messages, messages}
          )

          {:final, "<compaction-summary>captured attachment</compaction-summary>"}
        end

        @impl true
        def complete(messages, tools), do: complete(messages, tools, [])
      end

      Application.put_env(:salix_agent, :llm, AsyncAttachmentCaptureLLM)
      :persistent_term.put({AsyncAttachmentCaptureLLM, :test_pid}, self())
      on_exit(fn -> :persistent_term.erase({AsyncAttachmentCaptureLLM, :test_pid}) end)

      agent = SalixAgent.TestSupport.new_agent_id()
      session_id = "ses1_0000000000000001033"
      tool_call_id = "get-provider-before-compaction"

      SalixAgent.TestSupport.create_control_agent!(agent, %{
        "provider_config" => %{
          "protocol" => "responses",
          "base_url" => "https://api.openai.test/v1",
          "api_key" => "test-key",
          "compaction" => %{"strategy" => "summary"}
        }
      })

      {:ok, _} =
        Registry.register(
          SalixAgent.Registry,
          InternalSessionActor.key(agent, session_id),
          nil
        )

      pdf = "%PDF-1.4\nasync result before compaction\n%%EOF\n"
      {:ok, write_event} = AgentWorkspace.prepare_write(agent, "/before-compaction.pdf", pdf)

      assert {:ok, _} =
               AgentWorkspace.seed_operation(agent, "before-compaction-file", %{}, [write_event])

      provider_record = %{
        "status" => "completed",
        "tool_call_id" => "provider-before-compaction",
        "tool_name" => "im_api.feishu.fetch_message_resource",
        "error" => false,
        "result" => %{
          "id" => "provider-before-compaction",
          "name" => "im_api.feishu.fetch_message_resource",
          "status" => "completed",
          "content" =>
            Jason.encode!([
              %{
                "type" => "file",
                "path" => "/before-compaction.pdf",
                "file_name" => "before-compaction.pdf",
                "mime_type" => "application/pdf"
              }
            ]),
          "error" => false
        }
      }

      queued =
        commit_session!(agent, session_id, [
          %{"type" => "session_created", "session_id" => session_id},
          %{
            "type" => "delivery",
            "from_queue" => true,
            "session_id" => session_id,
            "message_id" => 1,
            "role" => "user",
            "content" => "inspect the provider attachment"
          },
          ack_event(session_id, 1),
          %{
            "type" => "async_tool_call_started",
            "session_id" => session_id,
            "tool_call_id" => tool_call_id,
            "tool_name" => "tool_call.get_result",
            "status" => "running",
            "started_at" => 5_000
          },
          %{
            "type" => "async_tool_call_completed",
            "session_id" => session_id,
            "tool_call_id" => tool_call_id,
            "result" => %{
              "id" => tool_call_id,
              "name" => "tool_call.get_result",
              "status" => "completed",
              "content" => Jason.encode!(provider_record),
              "error" => false
            },
            "error" => false,
            "completed_at" => 5_001
          },
          %{
            "type" => "queue_append",
            "session_id" => session_id,
            "kind" => "runtime_message",
            "dedupe_key" => "notify-get-provider-before-compaction",
            "payload" => %{
              "runtime_message_id" => "notify-get-provider-before-compaction",
              "type" => "tool_call_completed",
              "tool_call_id" => tool_call_id,
              "source_tool_call_id" => tool_call_id,
              "summary" => "provider attachment ready",
              "content" => ~s({"untrusted":"notification wrapper"})
            }
          }
        ])

      {materialized, _wake?, hwm} =
        InternalSession.materialize_pending_input_events(handle(queued))

      opts = if hwm > 0, do: [hwm: hwm], else: []
      assert {:ok, _} = InternalSessionStore.prepare_commit(agent, session_id, materialized, opts)

      # The session actor compacts; this process only stood in as the owner
      # to seed the session.
      :ok = Registry.unregister(SalixAgent.Registry, InternalSessionActor.key(agent, session_id))

      assert {:ok, _context, %{"status" => "compacted"}} =
               Compaction.compact(runtime_context(%{agent_id: agent}, session_id), session_id)

      assert_receive {:async_attachment_compaction_messages, messages}

      runtime_message =
        Enum.find(
          messages,
          &(&1[:runtime_message_id] == "notify-get-provider-before-compaction")
        )

      refute Map.has_key?(runtime_message, :native_content_trusted)
      refute Map.has_key?(runtime_message, :result_seq)
      refute Map.has_key?(runtime_message, "result_seq")
      source_prefix = "[" <> SalixAgent.IFC.assistant_ref(runtime_message.id) <> "]\n"
      assert runtime_message.content == source_prefix <> ~s({"untrusted":"notification wrapper"})
      refute inspect(messages) =~ Base.encode64(pdf)
    end

    test "passes billing context into the generic compaction LLM call", %{owned: owned} do
      defmodule CapturingCompactionLLM do
        @behaviour SalixAgent.LLM

        @impl true
        def complete(_messages, _tools, opts) do
          send(:compaction_llm_test_runner, {:compaction_opts, opts})
          {:final, "<compaction-summary>captured</compaction-summary>"}
        end

        @impl true
        def complete(_messages, _tools), do: complete([], [], [])
      end

      Process.register(self(), :compaction_llm_test_runner)
      Application.put_env(:salix_agent, :llm, CapturingCompactionLLM)

      on_exit(fn ->
        if Process.whereis(:compaction_llm_test_runner) == self(),
          do: Process.unregister(:compaction_llm_test_runner)
      end)

      assert {:ok, _owned, %{"status" => "compacted"}} =
               Compaction.compact(
                 runtime_context(owned, "ses1_0000000000000001001"),
                 "ses1_0000000000000001001"
               )

      assert_receive {:compaction_opts, opts}
      assert opt(opts, "entrypoint") == "compaction"
      assert opt(opts, "actor_type") == "system"
      assert opts |> opt("billing_context") |> opt("billing_account_id") == "ba-compact"
    end

    test "normal rounds and compaction receive the same resolved provider protocol", %{
      owned: owned
    } do
      defmodule ProtocolCaptureLLM do
        @behaviour SalixAgent.LLM

        @impl true
        def complete(_messages, _tools, opts) do
          send(
            :persistent_term.get({__MODULE__, :test_pid}),
            {:compaction_protocol, protocol(opts)}
          )

          {:final, "<compaction-summary>captured</compaction-summary>"}
        end

        @impl true
        def complete(_messages, _tools), do: complete([], [], [])

        @impl true
        def complete_stream(_messages, _tools, _on_delta, opts) do
          send(:persistent_term.get({__MODULE__, :test_pid}), {:round_protocol, protocol(opts)})

          {:assistant, "round final",
           [
             %{
               id: "protocol_capture_end_turn",
               name: "end_turn",
               args: %{"outcome" => "done"}
             }
           ]}
        end

        defp protocol(opts) when is_map(opts), do: opts["protocol"] || opts[:protocol]

        defp protocol(opts) when is_list(opts) do
          Keyword.get(opts, :protocol) ||
            case List.keyfind(opts, "protocol", 0) do
              {"protocol", value} -> value
              _ -> nil
            end
        end

        defp protocol(_opts), do: nil
      end

      Application.put_env(:salix_agent, :llm, ProtocolCaptureLLM)
      :persistent_term.put({ProtocolCaptureLLM, :test_pid}, self())
      on_exit(fn -> :persistent_term.erase({ProtocolCaptureLLM, :test_pid}) end)

      llm = %{
        "protocol" => "anthropic",
        "base_url" => "https://llm.example.test",
        "api_key" => "test-key",
        "model" => "test-model"
      }

      {:ok, agent} = SalixAgent.Control.get(owned.agent_id)

      {:ok, _template} =
        SalixAgent.Templates.update(agent["template_id"], %{
          "model" => llm["model"],
          "provider" => "anthropic",
          "provider_config" => Map.drop(llm, ["model"])
        })

      {:ok, owned, :final} =
        SalixAgent.Round.run(
          runtime_context(owned, "ses1_0000000000000001001"),
          "ses1_0000000000000001001"
        )

      {:ok, _owned, %{"status" => "compacted"}} =
        Compaction.compact(
          runtime_context(owned, "ses1_0000000000000001001"),
          "ses1_0000000000000001001"
        )

      assert_receive {:round_protocol, "anthropic"}
      assert_receive {:compaction_protocol, "anthropic"}
    end

    test "a tag-less response soft-fails: logged, session untouched", %{owned: owned} do
      Mock.script([{:final, "I summarized it but forgot the tags."}])

      {:ok, owned, %{"status" => "failed_soft"}} =
        Compaction.compact(
          runtime_context(owned, "ses1_0000000000000001001"),
          "ses1_0000000000000001001"
        )

      session = read_session!(owned.agent_id, "ses1_0000000000000001001")
      assert session.summary == nil
      assert session.compacted_through == 0
      assert session.summary_sequence == 0
    end

    test "an LLM exception soft-fails too", %{owned: owned} do
      defmodule RaisingLLM do
        @behaviour SalixAgent.LLM
        @impl true
        def complete(_m, _t), do: raise("provider down")
        @impl true
        def complete_stream(m, t, _cb), do: complete(m, t)
      end

      Application.put_env(:salix_agent, :llm, RaisingLLM)

      assert {:ok, owned, %{"status" => "failed_soft"}} =
               Compaction.compact(
                 runtime_context(owned, "ses1_0000000000000001001"),
                 "ses1_0000000000000001001"
               )

      assert read_session!(owned.agent_id, "ses1_0000000000000001001").summary == nil
    end

    test "a buffer too small to compact meaningfully is skipped (willow (false, nil))",
         %{agent: agent} do
      # Fresh agent: one lone assistant message — no user turn to anchor a summary.
      tiny_agent = SalixAgent.TestSupport.new_agent_id()
      SalixAgent.TestSupport.create_control_agent!(tiny_agent)
      owned = %{agent_id: tiny_agent}

      commit_session!(owned.agent_id, "ses1_0000000000000001013", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001013"},
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001013",
          "message_id" => 1,
          "content" => "hi"
        },
        ack_event("ses1_0000000000000001013", 1)
      ])

      # No LLM consumed, no warning, no compaction event.
      {:ok, owned, %{"status" => "skipped"}} =
        Compaction.compact(
          runtime_context(owned, "ses1_0000000000000001013"),
          "ses1_0000000000000001013"
        )

      session = read_session!(owned.agent_id, "ses1_0000000000000001013")
      assert session.summary == nil
      assert session.summary_sequence == 0
    end

    test "explicit runtime compact returns session owner result statuses", %{agent: agent} do
      Mock.script([{:final, "<compaction-summary>first runtime summary</compaction-summary>"}])

      assert {:ok, %{"status" => "compacted"}} =
               SalixAgent.Runtime.compact_session(agent, "ses1_0000000000000001001")

      session = read_session!(agent, "ses1_0000000000000001001")
      assert session.summary =~ "first runtime summary"
      assert compact_result_statuses(session) == ["compacted"]

      assert {:ok, %{"status" => "noop", "reason" => "no_new_live_messages"}} =
               SalixAgent.Runtime.compact_session(agent, "ses1_0000000000000001001")

      session = read_session!(agent, "ses1_0000000000000001001")
      assert compact_result_statuses(session) == ["compacted", "noop"]

      commit_session!(agent, "ses1_0000000000000001016", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001016"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001016",
          "message_id" => 1,
          "content" => "u"
        },
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001016",
          "message_id" => 2,
          "content" => "a"
        },
        ack_event("ses1_0000000000000001016", 2)
      ])

      Mock.script([{:final, "missing tags"}])

      assert {:ok, %{"status" => "failed_soft", "reason" => "missing_compaction_summary_tags"}} =
               SalixAgent.Runtime.compact_session(agent, "ses1_0000000000000001016")

      assert compact_result_statuses(read_session!(agent, "ses1_0000000000000001016")) == [
               "failed_soft"
             ]

      commit_session!(agent, "ses1_0000000000000001017", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001017"},
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001017",
          "message_id" => 1,
          "content" => "hi"
        },
        ack_event("ses1_0000000000000001017", 1)
      ])

      assert {:ok, %{"status" => "skipped", "reason" => "not_enough_context"}} =
               SalixAgent.Runtime.compact_session(agent, "ses1_0000000000000001017")

      assert compact_result_statuses(read_session!(agent, "ses1_0000000000000001017")) == [
               "skipped"
             ]

      commit_session!(agent, "ses1_0000000000000001006", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001006"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001006",
          "message_id" => 1,
          "content" => "summarize this"
        },
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001006",
          "message_id" => 2,
          "content" => "working"
        },
        ack_event("ses1_0000000000000001006", 2)
      ])

      defmodule LongReasonCompactionLLM do
        @behaviour SalixAgent.LLM

        @impl true
        def complete(_messages, _tools),
          do: raise(RuntimeError, message: String.duplicate("provider-error-", 400))

        @impl true
        def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)
      end

      Application.put_env(:salix_agent, :llm, LongReasonCompactionLLM)

      assert {:ok, %{"status" => "failed_soft", "reason" => reason}} =
               SalixAgent.Runtime.compact_session(agent, "ses1_0000000000000001006")

      assert byte_size(reason) <= 2048
      assert String.ends_with?(reason, "...[truncated]")

      [event] = compact_result_events(read_session!(agent, "ses1_0000000000000001006"))
      assert event["reason"] == reason

      commit_session!(agent, "ses1_0000000000000001005", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001005"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001005",
          "message_id" => 1,
          "content" => "summarize this hard error path"
        },
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001005",
          "message_id" => 2,
          "content" => "hard error content"
        },
        ack_event("ses1_0000000000000001005", 2)
      ])

      Application.put_env(:salix_agent, :llm, Mock)
      Mock.script([{:final, "<compaction-summary>hard failure summary</compaction-summary>"}])

      SalixStore.S3.Fake.set_fault(
        {:fail, 503, :put,
         SalixStore.Keys.agent_internal_runtime_session(agent, "ses1_0000000000000001005")}
      )

      assert {:error, {:compact_failed_hard, hard_reason}} =
               SalixAgent.Runtime.compact_session(agent, "ses1_0000000000000001005")

      assert hard_reason =~ "{:http, 503}"

      [hard_event] = compact_result_events(read_session!(agent, "ses1_0000000000000001005"))
      assert hard_event["status"] == "failed_hard"
      assert hard_event["reason"] == hard_reason

      assert {:ok, sessions} = SalixAgent.Runtime.list_sessions(agent)
      listed_hard = Enum.find(sessions, &(&1["session_id"] == "ses1_0000000000000001005"))
      refute Map.has_key?(listed_hard, "events")

      assert {:ok, detail} = SalixAgent.Runtime.get_session(agent, "ses1_0000000000000001005")
      refute Map.has_key?(detail, "events")
      refute Map.has_key?(detail, "messages")
    end

    test "explicit compact control returns before a slow summarizer finishes", %{agent: agent} do
      commit_session!(agent, "ses1_0000000000000001015", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001015"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001015",
          "message_id" => 1,
          "content" => "compress this later"
        },
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001015",
          "message_id" => 2,
          "content" => "this content should be summarized"
        },
        ack_event("ses1_0000000000000001015", 2)
      ])

      test_pid = self()

      Application.put_env(:salix_agent, :summarizer, fn _prev_summary, _live_messages ->
        send(test_pid, {:compact_summary_waiting, self()})

        receive do
          :release_compact_summary -> "slow control compact summary"
        after
          5_000 -> raise "test did not release the summarizer"
        end
      end)

      source_id = "test:compact:slow-control"

      entry = %{
        payload: %{kind: "session_compact", session_id: "ses1_0000000000000001015"},
        source_message_id: source_id
      }

      # Acknowledge staging while the summarizer is blocked. A handshake tests
      # this ordering without requiring a 10 ms RPC on a loaded test host.
      assert {:ok, :committed} =
               InternalSessionFleet.stage_control(agent, "ses1_0000000000000001015", entry,
                 timeout: 2_000
               )

      assert_receive {:compact_summary_waiting, summarizer}, 2_000
      send(summarizer, :release_compact_summary)

      assert eventually(fn ->
               session = read_session!(agent, "ses1_0000000000000001015")

               Enum.any?(session.events, fn event ->
                 event["kind"] == "session_compact_result" and
                   event["source_message_id"] == source_id and
                   event["status"] == "compacted"
               end)
             end)

      assert read_session!(agent, "ses1_0000000000000001015").summary =~
               "slow control compact summary"
    end

    test "public compact_session waits for a slow compact result after control staging", %{
      agent: agent
    } do
      commit_session!(agent, "ses1_0000000000000001014", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001014"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001014",
          "message_id" => 1,
          "content" => "compress through public api"
        },
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001014",
          "message_id" => 2,
          "content" => "this public api content should be summarized"
        },
        ack_event("ses1_0000000000000001014", 2)
      ])

      Application.put_env(:salix_agent, :summarizer, fn _prev_summary, _live_messages ->
        Process.sleep(10_500)
        "slow public api compact summary"
      end)

      assert {:ok, %{"status" => "compacted"}} =
               SalixAgent.Runtime.compact_session(agent, "ses1_0000000000000001014")

      assert read_session!(agent, "ses1_0000000000000001014").summary =~
               "slow public api compact summary"
    end

    test "recompaction folds the previous summary into the next request", %{owned: owned} do
      Mock.script([{:final, "<compaction-summary>first pass</compaction-summary>"}])

      {:ok, owned, %{"status" => "compacted"}} =
        Compaction.compact(
          runtime_context(owned, "ses1_0000000000000001001"),
          "ses1_0000000000000001001"
        )

      commit_session!(owned.agent_id, "ses1_0000000000000001001", [
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001001",
          "message_id" => 3,
          "content" => "now translate it"
        },
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001001",
          "message_id" => 4,
          "content" => "Translated the report."
        },
        ack_event("ses1_0000000000000001001", 4)
      ])

      Mock.script([
        {:final, "<compaction-summary>report written, then translated</compaction-summary>"}
      ])

      {:ok, owned, %{"status" => "compacted"}} =
        Compaction.compact(
          runtime_context(owned, "ses1_0000000000000001001"),
          "ses1_0000000000000001001"
        )

      session = read_session!(owned.agent_id, "ses1_0000000000000001001")

      assert session.summary ==
               "<compacted-context>\nreport written, then translated\n</compacted-context>"

      assert session.compacted_through == 4
      assert session.summary_sequence == 2
    end
  end

  describe "auto trigger (willow ShouldCompact: 0.9 x context window)" do
    test "large byte estimates without provider usage do not trigger compaction" do
      # ~4 bytes/token: 460,800 bytes ≈ 115,200 tokens — just over 0.9 * 128000.
      over =
        normalized_session(%{
          messages: [%{id: 1, role: "user", content: String.duplicate("z", 470_000)}]
        })

      under =
        normalized_session(%{
          messages: [%{id: 1, role: "user", content: String.duplicate("z", 100_000)}]
        })

      refute Compaction.should_compact?(over)
      refute Compaction.should_compact?(under)
    end

    test "the template context window narrows the trigger" do
      s =
        normalized_session(%{
          messages: [%{id: 1, role: "assistant", content: "ok", input_tokens: 10_000}]
        })

      # 40KB ≈ 10K tokens: over 0.9 * 8192, far under the 128K default.
      assert Compaction.should_compact?(s, context_tokens: 8192)
      refute Compaction.should_compact?(s)
    end

    test "provider prompt usage triggers when the byte estimate misses request-only context" do
      observed =
        normalized_session(%{
          messages: [
            %{id: 1, role: "user", content: "small durable transcript"},
            %{
              id: 2,
              role: "assistant",
              content: "ok",
              input_tokens: 605_139,
              request_summary_sequence: 0,
              request_compacted_through: 0
            }
          ]
        })

      assert InternalSession.estimated_tokens(observed) < 100
      assert Compaction.should_compact?(observed, context_tokens: 200_000)
    end

    test "only provider prompt usage from the current compaction generation triggers" do
      compacted = %{
        summary_sequence: 2,
        compacted_through: 40,
        summary: "<compacted-context>summary</compacted-context>"
      }

      current =
        normalized_session(
          Map.put(compacted, :messages, [
            %{
              id: 41,
              role: "assistant",
              content: "unfinished suffix",
              input_tokens: 605_139,
              request_summary_sequence: 2,
              request_compacted_through: 40
            }
          ])
        )

      stale =
        normalized_session(
          Map.put(compacted, :messages, [
            %{
              id: 41,
              role: "assistant",
              content: "unfinished suffix",
              input_tokens: 605_139,
              request_summary_sequence: 1,
              request_compacted_through: 20
            }
          ])
        )

      legacy_before_first_compaction =
        normalized_session(%{
          messages: [%{id: 1, role: "assistant", content: "legacy", input_tokens: 605_139}]
        })

      legacy_after_compaction =
        normalized_session(
          Map.put(compacted, :messages, [
            %{id: 41, role: "assistant", content: "legacy", input_tokens: 605_139}
          ])
        )

      assert Compaction.should_compact?(current, context_tokens: 200_000)
      refute Compaction.should_compact?(stale, context_tokens: 200_000)
      assert Compaction.should_compact?(legacy_before_first_compaction, context_tokens: 200_000)
      refute Compaction.should_compact?(legacy_after_compaction, context_tokens: 200_000)
    end

    test "maybe_compact_session uses the observed provider prompt size", %{owned: owned} do
      session_id = "ses1_0000000000000001023"

      commit_session!(owned.agent_id, session_id, [
        %{"type" => "session_created", "session_id" => session_id},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => session_id,
          "message_id" => 1,
          "content" => "small durable transcript"
        },
        %{
          "type" => "assistant",
          "session_id" => session_id,
          "message_id" => 2,
          "content" => "ok",
          "input_tokens" => 10_000,
          "input_tokens" => 605_139,
          "request_summary_sequence" => 0,
          "request_compacted_through" => 0
        },
        ack_event(session_id, 2)
      ])

      Mock.script([{:final, "<compaction-summary>bounded again</compaction-summary>"}])

      assert {:ok, _owned, %{"status" => "compacted"}} =
               Compaction.maybe_compact_session(
                 runtime_context(owned, session_id),
                 session_id,
                 llm_opts: [],
                 context_tokens: 200_000
               )

      session = read_session!(owned.agent_id, session_id)
      assert session.summary =~ "bounded again"
      assert session.compacted_through == 2
    end

    test "automatic compaction does not summarize without a new settled watermark", %{
      owned: owned
    } do
      session_id = "ses1_0000000000000001024"

      commit_session!(owned.agent_id, session_id, [
        %{"type" => "session_created", "session_id" => session_id},
        %{
          "type" => "compaction",
          "session_id" => session_id,
          "summary" => "<compacted-context>already compacted</compacted-context>",
          "compacted_through" => 4,
          "summary_sequence" => 1
        }
      ])

      Mock.script([{:final, "<compaction-summary>must not be consumed</compaction-summary>"}])

      assert {:ok, _owned, %{"status" => "noop", "reason" => "no_new_live_messages"}} =
               Compaction.maybe_compact_session(
                 runtime_context(owned, session_id),
                 session_id,
                 llm_opts: [],
                 context_tokens: 1
               )

      assert read_session!(owned.agent_id, session_id).summary =~ "already compacted"
    end

    test "maybe_compact_session compacts only the target over-trigger session", %{
      owned: owned
    } do
      commit_session!(owned.agent_id, "ses1_0000000000000001002", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001002"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001002",
          "message_id" => 3,
          "content" => String.duplicate("z", 40_000)
        },
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001002",
          "message_id" => 4,
          "content" => "ok",
          "input_tokens" => 10_000
        },
        ack_event("ses1_0000000000000001002", 4)
      ])

      Mock.script([{:final, "<compaction-summary>big session history</compaction-summary>"}])

      {:ok, owned, %{"status" => "compacted"}} =
        Compaction.maybe_compact_session(
          runtime_context(owned, "ses1_0000000000000001002"),
          "ses1_0000000000000001002",
          llm_opts: [],
          context_tokens: 8192
        )

      # "ses1_0000000000000001002" (10K observed tokens > 0.9 * 8192) compacted; "ses1_0000000000000001001" untouched.
      assert read_session!(owned.agent_id, "ses1_0000000000000001002").summary ==
               "<compacted-context>\nbig session history\n</compacted-context>"

      assert read_session!(owned.agent_id, "ses1_0000000000000001001").summary == nil

      # Replay parity: durable session storage reproduces the compacted state.
      assert read_session!(owned.agent_id, "ses1_0000000000000001002").summary =~
               "big session history"
    end

    test "auto compaction records retryable failure and backs off", %{owned: owned} do
      commit_session!(owned.agent_id, "ses1_0000000000000001010", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001010"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001010",
          "message_id" => 3,
          "content" => String.duplicate("z", 40_000)
        },
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001010",
          "message_id" => 4,
          "content" => "ok",
          "input_tokens" => 10_000
        },
        ack_event("ses1_0000000000000001010", 4)
      ])

      {:error, llm_error} = SalixAgent.LLM.Error.transport("mock", :timeout)
      Mock.script([{:error, llm_error}])

      assert {:ok, _owned, %{"status" => "failed_soft", "reason" => reason}} =
               Compaction.maybe_compact_session(
                 runtime_context(owned, "ses1_0000000000000001010"),
                 "ses1_0000000000000001010",
                 llm_opts: [],
                 context_tokens: 8192
               )

      assert reason =~ "transport_error"

      session = read_session!(owned.agent_id, "ses1_0000000000000001010")
      assert session.summary == nil
      assert session.compaction_failure["category"] == "transport_error"
      assert session.compaction_failure["retryable"] == true
      assert session.compaction_failure["attempts"] == 1
      assert session.compaction_failure["next_retry_at"] > System.system_time(:second)

      assert session.compaction_failure["config_fingerprint"] ==
               stable_config_fingerprint([], 8192)

      Mock.script([{:final, "<compaction-summary>should not be consumed</compaction-summary>"}])

      assert {:ok, _owned, %{"status" => "noop", "reason" => backoff_reason}} =
               Compaction.maybe_compact_session(
                 runtime_context(owned, "ses1_0000000000000001010"),
                 "ses1_0000000000000001010",
                 llm_opts: [],
                 context_tokens: 8192
               )

      assert backoff_reason =~ "compaction_backoff"
      assert read_session!(owned.agent_id, "ses1_0000000000000001010").summary == nil
    end

    test "auto compaction writes recovery summary for permanent provider errors", %{
      owned: owned
    } do
      commit_session!(owned.agent_id, "ses1_0000000000000001008", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001008"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001008",
          "message_id" => 3,
          "content" => String.duplicate("z", 40_000)
        },
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001008",
          "message_id" => 4,
          "content" => "ok",
          "input_tokens" => 10_000
        },
        ack_event("ses1_0000000000000001008", 4)
      ])

      {:error, llm_error} = SalixAgent.LLM.Error.http("mock", 401, "bad key")
      Mock.script([{:error, llm_error}])

      assert {:ok, _owned, %{"status" => "failed_soft", "reason" => reason}} =
               Compaction.maybe_compact_session(
                 runtime_context(owned, "ses1_0000000000000001008"),
                 "ses1_0000000000000001008",
                 llm_opts: [],
                 context_tokens: 8192
               )

      assert reason =~ "permanent_provider_error"

      session = read_session!(owned.agent_id, "ses1_0000000000000001008")
      assert session.summary =~ "System recovery summary"
      assert session.summary =~ "permanent_provider_error"
      assert session.compacted_through == 4
      assert session.summary_sequence == 1
      assert session.compaction_failure["category"] == "permanent_provider_error"
      assert session.compaction_failure["retryable"] == false
      assert session.compaction_failure["attempts"] == 1
      assert session.compaction_failure["recovery_summary_written"] == true
      refute Map.has_key?(session.compaction_failure, "next_retry_at")
    end

    test "auto compaction preserves unread input during recovery and resumes after settlement", %{
      owned: owned
    } do
      commit_session!(owned.agent_id, "ses1_0000000000000001011", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001011"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001011",
          "message_id" => 3,
          "content" => String.duplicate("z", 40_000)
        },
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001011",
          "message_id" => 4,
          "content" => "ok",
          "input_tokens" => 10_000
        },
        ack_event("ses1_0000000000000001011", 4)
      ])

      {:error, llm_error} = SalixAgent.LLM.Error.transport("mock", :timeout)

      for attempt <- 1..3 do
        Mock.script([{:error, llm_error}])

        assert {:ok, _owned, %{"status" => "failed_soft"}} =
                 Compaction.maybe_compact_session(
                   runtime_context(owned, "ses1_0000000000000001011"),
                   "ses1_0000000000000001011",
                   llm_opts: [],
                   context_tokens: 8192
                 )

        session = read_session!(owned.agent_id, "ses1_0000000000000001011")
        assert session.compaction_failure["attempts"] == attempt

        if attempt < 3 do
          expire_compaction_backoff!(owned.agent_id, "ses1_0000000000000001011")

          commit_session!(owned.agent_id, "ses1_0000000000000001011", [
            %{
              "type" => "delivery",
              "from_queue" => true,
              "session_id" => "ses1_0000000000000001011",
              "message_id" => 4 + attempt,
              "content" => "new message #{attempt}"
            }
          ])
        end
      end

      session = read_session!(owned.agent_id, "ses1_0000000000000001011")
      assert session.summary =~ "System recovery summary"
      assert session.summary =~ "transport_error"
      assert session.compacted_through == 4
      assert Enum.map(Compaction.context(handle(session)), & &1[:id]) == [0, 5, 6]
      assert session.summary_sequence == 1
      assert session.compaction_failure["attempts"] == 3
      assert session.compaction_failure["recovery_summary_written"] == true
      refute Map.has_key?(session.compaction_failure, "next_retry_at")

      commit_session!(owned.agent_id, "ses1_0000000000000001011", [
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001011",
          "message_id" => 7,
          "content" => String.duplicate("new recovery context", 2_000)
        },
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001011",
          "message_id" => 8,
          "content" => "Handled the new context.",
          "input_tokens" => 10_000,
          "request_summary_sequence" => 1,
          "request_compacted_through" => 4
        },
        ack_event("ses1_0000000000000001011", 8)
      ])

      Mock.script([{:error, llm_error}])

      assert {:ok, _owned, %{"status" => "failed_soft"}} =
               Compaction.maybe_compact_session(
                 runtime_context(owned, "ses1_0000000000000001011"),
                 "ses1_0000000000000001011",
                 llm_opts: [],
                 context_tokens: 8192
               )

      session = read_session!(owned.agent_id, "ses1_0000000000000001011")
      assert session.compacted_through == 8
      assert session.summary_sequence == 2
      assert session.compaction_failure["attempts"] == 4
      assert session.compaction_failure["live_context_watermark"] == 8
      assert session.compaction_failure["recovery_summary_written"] == true
      assert [%{role: "summary"}] = Compaction.context(handle(session))
    end

    test "auto compaction classifies LLM resolver failures as session config errors", %{
      owned: owned
    } do
      Application.put_env(:salix_agent, :llm_resolver, FailingLlmResolver)

      commit_session!(owned.agent_id, "ses1_0000000000000001003", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001003"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001003",
          "message_id" => 3,
          "content" => String.duplicate("z", 40_000)
        },
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001003",
          "message_id" => 4,
          "content" => "ok",
          "input_tokens" => 10_000
        },
        ack_event("ses1_0000000000000001003", 4)
      ])

      assert {:ok, _owned, %{"status" => "failed_soft", "reason" => reason}} =
               Compaction.maybe_compact_session(
                 runtime_context(owned, "ses1_0000000000000001003"),
                 "ses1_0000000000000001003",
                 context_tokens: 8192
               )

      assert reason =~ "session_config"

      session = read_session!(owned.agent_id, "ses1_0000000000000001003")
      assert session.compaction_failure["category"] == "session_config_error"
      assert session.compaction_failure["retryable"] == true
      assert session.compaction_failure["config_fingerprint"] == "unresolved"
    end

    test "auto compaction writes fixed recovery summary for context overflow", %{owned: owned} do
      commit_session!(owned.agent_id, "ses1_0000000000000001007", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001007"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001007",
          "message_id" => 3,
          "content" => String.duplicate("z", 40_000)
        },
        %{
          "type" => "assistant",
          "session_id" => "ses1_0000000000000001007",
          "message_id" => 4,
          "content" => "ok",
          "input_tokens" => 10_000
        },
        ack_event("ses1_0000000000000001007", 4)
      ])

      {:error, llm_error} = SalixAgent.LLM.Error.context_overflow("mock", "too many tokens")
      Mock.script([{:error, llm_error}])

      assert {:ok, _owned, %{"status" => "failed_soft"}} =
               Compaction.maybe_compact_session(
                 runtime_context(owned, "ses1_0000000000000001007"),
                 "ses1_0000000000000001007",
                 llm_opts: [],
                 context_tokens: 8192
               )

      session = read_session!(owned.agent_id, "ses1_0000000000000001007")
      assert session.summary =~ "System recovery summary"
      assert session.summary =~ "context_overflow"
      assert session.summary =~ "fs.read_file"
      assert session.summary =~ "/.runtime/compaction-recovery.md"
      assert session.compacted_through == 4
      assert session.summary_sequence == 1
      assert session.compaction_failure["category"] == "context_overflow"
      assert session.compaction_failure["recovery_summary_written"] == true

      assert [%{role: "summary", content: "<compacted-context>" <> _}] =
               Compaction.context(handle(session))

      assert Enum.any?(session.events, &(&1["kind"] == "compaction_recovery"))

      [tool_result] =
        Tools.execute(
          [
            %{
              "id" => "read-recovery-1",
              "name" => "fs.read_file",
              "args" => %{"path" => "/.runtime/compaction-recovery.md", "num_lines" => 21}
            }
          ],
          tool_ctx(owned.agent_id, "ses1_0000000000000001007")
        )

      assert tool_result.error == false
      payload = Jason.decode!(tool_result.content)
      assert payload["path"] == "/.runtime/compaction-recovery.md"
      assert payload["truncated"] == true
      assert is_integer(payload["next_start_line"])
      assert payload["content"] =~ "Session: ses1_0000000000000001007"
      assert payload["content"] =~ "Failure category: context_overflow"
      assert payload["content"] =~ "Message 3"
      refute payload["content"] =~ "Message 4"

      [continuation] =
        Tools.execute(
          [
            %{
              "id" => "read-recovery-2",
              "name" => "fs.read_file",
              "args" => %{
                "path" => "/.runtime/compaction-recovery.md",
                "start_line" => payload["next_start_line"],
                "num_lines" => 64
              }
            }
          ],
          tool_ctx(owned.agent_id, "ses1_0000000000000001007")
        )

      assert continuation.error == false
      continuation_payload = Jason.decode!(continuation.content)
      assert continuation_payload["start_line"] == payload["next_start_line"]
      assert continuation_payload["end_line"] >= continuation_payload["start_line"]

      [full_recovery] =
        Tools.execute(
          [
            %{
              "id" => "read-recovery-full",
              "name" => "fs.read_file",
              "args" => %{"path" => "/.runtime/compaction-recovery.md", "num_lines" => 2_000}
            }
          ],
          tool_ctx(owned.agent_id, "ses1_0000000000000001007")
        )

      full_payload = Jason.decode!(full_recovery.content)
      assert full_payload["content"] =~ "Message 4"
      assert full_payload["content"] =~ "ok"
    end

    test "runtime recovery file is scoped to the current session", %{
      owned: owned
    } do
      commit_session!(owned.agent_id, "ses1_0000000000000001018", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001018"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001018",
          "message_id" => 1,
          "content" => "session-specific recovery text"
        },
        %{
          "type" => "compaction",
          "session_id" => "ses1_0000000000000001018",
          "summary" => "fixed recovery",
          "compacted_through" => 1,
          "summary_sequence" => 1
        },
        %{
          "type" => "compaction_recovery",
          "session_id" => "ses1_0000000000000001018",
          "kind" => "compaction_recovery",
          "category" => "context_overflow",
          "reason" => "too large",
          "compacted_through" => 1,
          "summary_sequence" => 1,
          "created_at" => 123
        }
      ])

      commit_session!(owned.agent_id, "ses1_0000000000000001019", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001019"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001019",
          "message_id" => 1,
          "content" => "ordinary session text"
        }
      ])

      [with_recovery] =
        Tools.execute(
          [
            %{
              "id" => "read-recovery-with",
              "name" => "fs.read_file",
              "args" => %{"path" => "/.runtime/compaction-recovery.md", "num_lines" => 2_000}
            }
          ],
          tool_ctx(owned.agent_id, "ses1_0000000000000001018")
        )

      [without_recovery] =
        Tools.execute(
          [
            %{
              "id" => "read-recovery-without",
              "name" => "fs.read_file",
              "args" => %{"path" => "/.runtime/compaction-recovery.md", "num_lines" => 2_000}
            }
          ],
          tool_ctx(owned.agent_id, "ses1_0000000000000001019")
        )

      assert with_recovery.error == false
      assert without_recovery.error == false
      assert Jason.decode!(with_recovery.content)["content"] =~ "session-specific recovery text"

      [tail_recovery] =
        Tools.execute(
          [
            %{
              "id" => "read-recovery-tail",
              "name" => "fs.read_file",
              "args" => %{"path" => "/.runtime/compaction-recovery.md", "tail_lines" => 6}
            }
          ],
          tool_ctx(owned.agent_id, "ses1_0000000000000001018")
        )

      assert tail_recovery.error == false
      tail_payload = Jason.decode!(tail_recovery.content)
      assert tail_payload["tail_lines"] == 6
      assert tail_payload["truncated"] == true
      assert tail_payload["content"] =~ "session-specific recovery text"

      runtime_files =
        Tools.list_files(%{"prefix" => "/.runtime"}, %{
          agent_id: owned.agent_id,
          session_id: "ses1_0000000000000001018"
        })
        |> String.split("\n", trim: true)

      assert "/.runtime/compaction-recovery.md" in runtime_files

      assert Tools.list_files(%{"prefix" => "/.runtime/compaction-recovery.md/child"}, %{
               agent_id: owned.agent_id,
               session_id: "ses1_0000000000000001018"
             }) == ""

      runtime_without_session =
        Tools.list_files(%{"prefix" => "/.runtime"}, %{agent_id: owned.agent_id})
        |> String.split("\n", trim: true)

      refute "/.runtime/compaction-recovery.md" in runtime_without_session

      assert Jason.decode!(without_recovery.content)["content"] =~
               "No compaction recovery context"

      refute Jason.decode!(without_recovery.content)["content"] =~
               "session-specific recovery text"
    end

    test "runtime recovery fallback uses compaction failure time", %{owned: owned} do
      commit_session!(owned.agent_id, "ses1_0000000000000001004", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001004"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001004",
          "message_id" => 1,
          "content" => "context before failed recovery"
        },
        %{
          "type" => "compaction_failure",
          "session_id" => "ses1_0000000000000001004",
          "category" => "context_overflow",
          "reason" => "too many tokens",
          "compacted_through" => 1,
          "failed_at" => 123_456,
          "recovery_summary_written" => true
        }
      ])

      [recovery] =
        Tools.execute(
          [
            %{
              "id" => "read-recovery-fallback-time",
              "name" => "fs.read_file",
              "args" => %{"path" => "/.runtime/compaction-recovery.md", "num_lines" => 2_000}
            }
          ],
          tool_ctx(owned.agent_id, "ses1_0000000000000001004")
        )

      assert recovery.error == false
      content = Jason.decode!(recovery.content)["content"]
      assert content =~ "Generated at: 123456"
      refute content =~ "Generated at: unknown"
    end

    test "runtime recovery file full reads use the common middle omission rule", %{
      owned: owned
    } do
      large_recovery_text =
        String.duplicate("R", 80_000) <>
          "RUNTIME_RECOVERY_OMITTED_SENTINEL" <> String.duplicate("T", 80_000)

      commit_session!(owned.agent_id, "ses1_0000000000000001012", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001012"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001012",
          "message_id" => 1,
          "content" => large_recovery_text
        },
        %{
          "type" => "compaction",
          "session_id" => "ses1_0000000000000001012",
          "summary" => "fixed recovery",
          "compacted_through" => 1,
          "summary_sequence" => 1
        },
        %{
          "type" => "compaction_recovery",
          "session_id" => "ses1_0000000000000001012",
          "kind" => "compaction_recovery",
          "category" => "context_overflow",
          "reason" => "too large",
          "compacted_through" => 1,
          "summary_sequence" => 1,
          "created_at" => 123
        }
      ])

      [full_recovery] =
        Tools.execute(
          [
            %{
              "id" => "read-runtime-omission",
              "name" => "fs.read_file",
              "args" => %{"path" => "/.runtime/compaction-recovery.md"}
            }
          ],
          tool_ctx(owned.agent_id, "ses1_0000000000000001012")
        )

      assert full_recovery.error == false
      payload = Jason.decode!(full_recovery.content)
      assert payload["path"] == "/.runtime/compaction-recovery.md"
      assert payload["content_omitted"] == true
      assert payload["omitted_characters"] > 0
      assert payload["content"] =~ "fs.read_file omitted"
      assert payload["content"] =~ String.duplicate("R", 32)
      assert payload["content"] =~ String.duplicate("T", 32)
      refute payload["content"] =~ "RUNTIME_RECOVERY_OMITTED_SENTINEL"
    end

    test "runtime virtual files are read-only to file mutation tools", %{owned: owned} do
      # Keep video callable so this test reaches the filesystem write guard.
      previous = Application.get_env(:salix_agent, :media_resolver)
      on_exit(fn -> restore(:media_resolver, previous) end)
      Application.put_env(:salix_agent, :media_resolver, ConfiguredMediaResolver)

      commit_session!(owned.agent_id, "ses1_0000000000000001009", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001009"}
      ])

      ctx =
        %{agent_id: owned.agent_id, session_id: "ses1_0000000000000001009"}
        |> SalixAgent.TestSupport.with_plugin_projection()

      ctx =
        Map.put(
          ctx,
          :tool_disclosure,
          SalixAgent.ToolDisclosure.materialize("worker", :internal, ctx)
        )

      path = "/.runtime/compaction-recovery.md"

      direct_calls = [
        %{
          "id" => "write-runtime",
          "name" => "fs.write_file",
          "args" => %{"path" => path, "content" => "x"}
        },
        %{"id" => "delete-runtime", "name" => "fs.delete_file", "args" => %{"path" => path}},
        %{
          "id" => "edit-runtime",
          "name" => "fs.edit_file",
          "args" => %{"path" => path, "old" => "a", "new" => "b"}
        }
      ]

      llm_ctx = Map.put(ctx, :llm_tool_envelope, true)

      allowed_runtime_source_copy_calls = [
        %{
          "id" => "copy-runtime",
          "name" => "call",
          "args" => %{
            "tool" => "fs.copy_file",
            "params" => %{"from" => path, "to" => "/copy.md"}
          }
        },
        %{
          "id" => "peer-copy-runtime-source",
          "name" => "call",
          "args" => %{
            "tool" => "env.copy",
            "params" => %{
              "src_environment" => "vfs",
              "src_path" => path,
              "dst_environment" => "vfs",
              "dst_path" => "/env-copy.md"
            }
          }
        }
      ]

      llm_calls = [
        %{
          "id" => "move-runtime",
          "name" => "call",
          "args" => %{
            "tool" => "fs.move_file",
            "params" => %{"from" => path, "to" => "/moved.md"}
          }
        },
        %{
          "id" => "peer-copy-runtime-destination",
          "name" => "call",
          "args" => %{
            "tool" => "env.copy",
            "params" => %{
              "src_environment" => "vfs",
              "src_path" => "/copy.md",
              "dst_environment" => "vfs",
              "dst_path" => path
            }
          }
        },
        %{
          "id" => "generate-image-runtime",
          "name" => "call",
          "args" => %{
            "tool" => "image.generate",
            "params" => %{"prompt" => "test", "output_path" => path}
          }
        },
        %{
          "id" => "generate-video-runtime",
          "name" => "call",
          "args" => %{
            "tool" => "video.generate",
            "params" => %{"prompt" => "test", "output_path" => path}
          }
        }
      ]

      for call <- allowed_runtime_source_copy_calls do
        [result] = Tools.execute([call], llm_ctx)
        assert result.error == false
      end

      {:ok, copy_source_event} = AgentWorkspace.prepare_write(owned.agent_id, "/copy.md", "x")

      assert {:ok, _} =
               AgentWorkspace.seed_operation(
                 owned.agent_id,
                 "runtime-readonly-copy-source",
                 %{},
                 [copy_source_event]
               )

      for {call, call_ctx} <-
            Enum.map(direct_calls, &{&1, ctx}) ++ Enum.map(llm_calls, &{&1, llm_ctx}) do
        [result] = Tools.execute([call], call_ctx)
        assert result.error == true
        assert result.content =~ "/.runtime is read-only"
      end
    end

    test "maybe_compact_session skips active sessions with in-flight work", %{owned: owned} do
      commit_session!(owned.agent_id, "ses1_0000000000000001020", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001020"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001020",
          "message_id" => 3,
          "content" => String.duplicate("z", 40_000)
        },
        %{"type" => "status", "session_id" => "ses1_0000000000000001020", "status" => "active"}
      ])

      Mock.script([{:final, "<compaction-summary>should not run</compaction-summary>"}])

      {:ok, owned, %{"status" => "noop"}} =
        Compaction.maybe_compact_session(
          runtime_context(owned, "ses1_0000000000000001020"),
          "ses1_0000000000000001020",
          llm_opts: [],
          context_tokens: 8192
        )

      session = read_session!(owned.agent_id, "ses1_0000000000000001020")
      assert session.summary == nil
      assert session.compacted_through == 0
    end

    test "explicit compact_session skips active sessions without rewriting context", %{
      agent: agent
    } do
      commit_session!(agent, "ses1_0000000000000001021", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000001021"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000001021",
          "message_id" => 3,
          "content" => String.duplicate("z", 40_000)
        },
        %{"type" => "status", "session_id" => "ses1_0000000000000001021", "status" => "active"}
      ])

      Application.put_env(:salix_agent, :summarizer, fn _prev_summary, _live_messages ->
        flunk("active explicit compact must not call the summarizer")
      end)

      assert {:ok, %{"status" => "noop", "reason" => "session_active"}} =
               SalixAgent.Runtime.compact_session(agent, "ses1_0000000000000001021")

      session = read_session!(agent, "ses1_0000000000000001021")
      assert session.summary == nil
      assert session.compacted_through == 0

      assert Enum.any?(compact_result_events(session), fn event ->
               event["status"] == "noop" and event["reason"] == "session_active"
             end)
    end

    test "maybe_compact_session is a no-op below the pre-filter floor", %{owned: owned} do
      # No script installed: an LLM call would return {:final, "done"} and
      # then soft-fail on missing tags — but nothing should even be attempted.
      {:ok, owned2, %{"status" => "noop"}} =
        Compaction.maybe_compact_session(
          runtime_context(owned, "ses1_0000000000000001001"),
          "ses1_0000000000000001001"
        )

      assert read_session!(owned2.agent_id, "ses1_0000000000000001001").summary == nil
    end
  end

  defp restore(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore(key, value), do: Application.put_env(:salix_agent, key, value)

  defp opt(opts, key) when is_map(opts), do: opts[key] || opts[String.to_atom(key)]

  defp opt(opts, key) when is_list(opts) do
    Keyword.get(opts, String.to_atom(key)) ||
      case List.keyfind(opts, key, 0) do
        {^key, value} -> value
        _ -> nil
      end
  end

  defp opt(_opts, _key), do: nil

  defp runtime_context(%{agent_id: agent_id}, session_id),
    do: %{agent_id: agent_id, session_id: session_id}

  # A compaction driven up to its summarizing request, and then answered
  # later, so a test can change the session in between.
  defp prepare_compaction(context, mode) do
    {:ok, session} = InternalSessionStore.read(context.agent_id, context.session_id)

    drive_compaction(
      Compaction.host(context, session, []),
      nil,
      Compaction.event(mode, [], :reply)
    )
  end

  defp commit_prepared({plan, driver}, outcome) do
    {driver, :await} = SessionDriver.step(plan.state, driver, {:done, :started})

    {:complete, result} =
      drive_compaction(plan, driver, {:done, Compaction.summarized(plan, outcome)})

    result
  end

  defp drive_compaction(host, driver, event) do
    {driver, effect} = SessionDriver.step(host.state, driver, event)
    compaction_effect(host, driver, effect)
  end

  defp compaction_effect(host, driver, effect) do
    case Compaction.perform(host, driver, effect) do
      {:answer, value, host, driver} -> drive_compaction(host, driver, {:done, value})
      {:rerouted, host, driver, effect} -> compaction_effect(host, driver, effect)
      {:summarize, plan} -> {:prepared, {plan, driver}}
      {:result, result} -> {:complete, result}
    end
  end

  defp ack_event(session_id, message_id) do
    %{"type" => "ack", "session_id" => session_id, "last_ack_message_id" => message_id}
  end

  defp tool_ctx(agent_id, session_id) do
    ctx =
      %{agent_id: agent_id, session_id: session_id, role: "worker", runtime_kind: :external}
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(
      ctx,
      :tool_disclosure,
      SalixAgent.ToolDisclosure.materialize("worker", :external, ctx)
    )
  end

  defp commit_session!(agent_id, session_id, events) do
    {:ok, session} = InternalSessionStore.prepare_commit(agent_id, session_id, events)
    InternalSession.export(session)
  end

  # The store hands back an opaque handle; tests assert over the exported state.
  defp read_session!(agent_id, session_id) do
    {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, session_id)
    InternalSession.export(session)
  end

  defp handle(state), do: InternalSession.open(state)

  defp normalized_session(attrs) do
    %{agent_id: "agent", session_id: "ses1_0000000000000001013"}
    |> Map.merge(attrs)
    |> then(&struct(InternalSession.State, &1))
    |> handle()
    |> InternalSession.normalize()
  end

  defp expire_compaction_backoff!(agent_id, session_id) do
    session = read_session!(agent_id, session_id)

    failure =
      session.compaction_failure
      |> Map.put("type", "compaction_failure")
      |> Map.put("session_id", session_id)
      |> Map.put("next_retry_at", System.system_time(:second) - 1)

    commit_session!(
      agent_id,
      session_id,
      [
        failure
      ]
    )
  end

  defp compact_result_statuses(session) do
    session
    |> compact_result_events()
    |> Enum.map(& &1["status"])
  end

  defp compact_result_events(session) do
    session.events
    |> Enum.filter(&(&1["kind"] == "session_compact_result"))
  end

  defp eventually(fun, retries \\ 50)

  defp eventually(fun, retries) do
    case fun.() do
      true -> true
      _ when retries <= 0 -> false
      _ -> Process.sleep(20) && eventually(fun, retries - 1)
    end
  end

  defp stable_config_fingerprint(llm_opts, context_tokens) do
    %{
      "protocol" => opt(llm_opts, "protocol"),
      "provider" => opt(llm_opts, "provider"),
      "model" => opt(llm_opts, "model"),
      "base_url" => opt(llm_opts, "base_url"),
      "max_tokens" => opt(llm_opts, "max_tokens"),
      "context_tokens" => context_tokens,
      "compaction_strategy" => "summary"
    }
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> [key, value] end)
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
