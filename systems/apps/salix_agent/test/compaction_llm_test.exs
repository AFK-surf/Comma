defmodule SalixAgent.CompactionLlmTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The willow-parity compaction port: LLM-backed summarization (the session's
  own model answers a `<compaction-summary>` request; the stored summary is
  wrapped in `<compacted-context>` tags), soft-fail on a tag-less or erroring
  response, and the auto trigger at 0.9 × the template context window
  (provider-reported tokens). Against the Fake S3 backend with the scriptable
  `LLM.Mock`.
  """
  use SystemsClock.Case, async: false

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
    def resolve(agent_id), do: SalixAgent.AgentModel.resolve_llm_for_agent(agent_id)
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
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :test_pid}),
        {:native_compact, messages, opts}
      )

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
    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_llm_resolver = SystemsRuntime.get_env(:salix_agent, :llm_resolver)
    prev_summarizer = SystemsRuntime.get_env(:salix_agent, :summarizer)
    prev_group_context = SystemsRuntime.get_env(:salix_agent, :group_context_mod)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    # The production path: no summarizer seam, LLM = scripted mock.
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)
    SystemsRuntime.put_env(:salix_agent, :llm_resolver, ControlTemplateResolver)
    SystemsRuntime.delete_env(:salix_agent, :summarizer)
    start_supervised!(Mock)
    Mock.script([])

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)
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

      parent = SystemsRuntime.Proc.self()

      assert {:ok, _owned, %{"status" => "compacted"}} =
               Compaction.maybe_compact_session(runtime_context(owned, session_id), session_id,
                 threshold: 1,
                 summarizer: fn _previous, messages ->
                   SystemsRuntime.Proc.send(
                     parent,
                     {:summarized_ids, Enum.map(messages, & &1[:id])}
                   )

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

      parent = SystemsRuntime.Proc.self()

      :sys.replace_state(
        owner,
        fn data ->
          result = commit_prepared(prepared, {:ok, {:summary, "old coordinate summary"}})
          SystemsRuntime.Proc.send(parent, {:migration_compaction, result})
          data
        end,
        :infinity
      )

      assert_receive {:migration_compaction, {:error, {:stale_compaction_snapshot, _}}}
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
        if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) && SalixStore.S3.Fake.paused?(),
          do: SalixStore.S3.Fake.release_pause()
      end)

      parent = SystemsRuntime.Proc.self()

      commit_task =
        SystemsRuntime.Task.async(fn ->
          :sys.replace_state(
            owner,
            fn state ->
              result =
                commit_prepared(
                  prepared,
                  {:ok, {:summary, "<compacted-context>stale loser</compacted-context>"}}
                )

              SystemsRuntime.Proc.send(parent, {:racing_compaction_result, result})
              state
            end,
            :infinity
          )
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

      assert_receive {:racing_compaction_result, {:error, {:stale_compaction_snapshot, _details}}}

      _ = SystemsRuntime.Task.await(commit_task, :infinity)

      session = read_session!(owned.agent_id, session_id)
      assert session.summary == "<compacted-context>winner summary</compacted-context>"
      refute String.contains?(session.summary, "stale loser")
    end

    test "configured OpenAI Responses compaction stores provider compacted context" do
      SystemsRuntime.put_env(:salix_agent, :llm, NativeCompactLLM)
      SystemsRuntime.put_env(:salix_agent, :llm_resolver, ControlTemplateResolver)
      SystemsRuntime.PersistentTerm.put({NativeCompactLLM, :test_pid}, SystemsRuntime.Proc.self())
      on_exit(fn -> SystemsRuntime.PersistentTerm.erase({NativeCompactLLM, :test_pid}) end)

      previous_strategy = SystemsRuntime.get_env(:salix_agent, :compaction_strategy)
      SystemsRuntime.put_env(:salix_agent, :compaction_strategy, "openai_responses")

      on_exit(fn ->
        if is_nil(previous_strategy),
          do: SystemsRuntime.delete_env(:salix_agent, :compaction_strategy),
          else: SystemsRuntime.put_env(:salix_agent, :compaction_strategy, previous_strategy)
      end)

      agent = SalixAgent.TestSupport.new_agent_id()
      SalixAgent.TestSupport.create_control_agent!(agent)

      # The Worker follows the platform Worker model: a Responses endpoint.
      SalixAgent.TestSupport.configure_platform_tier!(
        "worker",
        "https://api.openai.test/v1",
        "gpt-test",
        %{"protocol" => "responses"}
      )

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

    test "passes billing context into the generic compaction LLM call", %{owned: owned} do
      defmodule CapturingCompactionLLM do
        @behaviour SalixAgent.LLM

        @impl true
        def complete(_messages, _tools, opts) do
          SystemsRuntime.Proc.send(:compaction_llm_test_runner, {:compaction_opts, opts})
          {:final, "<compaction-summary>captured</compaction-summary>"}
        end

        @impl true
        def complete(_messages, _tools), do: complete([], [], [])
      end

      Process.register(SystemsRuntime.Proc.self(), :compaction_llm_test_runner)
      SystemsRuntime.put_env(:salix_agent, :llm, CapturingCompactionLLM)

      on_exit(fn ->
        if SystemsRuntime.Proc.whereis(:compaction_llm_test_runner) == SystemsRuntime.Proc.self(),
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

      SystemsRuntime.put_env(:salix_agent, :llm, LongReasonCompactionLLM)

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

      SystemsRuntime.put_env(:salix_agent, :llm, Mock)
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
  end

  describe "auto trigger (willow ShouldCompact: 0.9 x context window)" do
    test "the template context window narrows the trigger" do
      s =
        normalized_session(%{
          messages: [%{id: 1, role: "assistant", content: "ok", input_tokens: 10_000}]
        })

      # 40KB ≈ 10K tokens: over 0.9 * 8192, far under the 128K default.
      assert Compaction.should_compact?(s, context_tokens: 8192)
      refute Compaction.should_compact?(s)
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
  end

  defp restore(key, nil), do: SystemsRuntime.delete_env(:salix_agent, key)
  defp restore(key, value), do: SystemsRuntime.put_env(:salix_agent, key, value)

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
      %{agent_id: agent_id, session_id: session_id, role: "worker", runtime_kind: :internal}
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(
      ctx,
      :tool_disclosure,
      SalixAgent.ToolDisclosure.materialize("worker", :internal, ctx)
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

  defp compact_result_statuses(session) do
    session
    |> compact_result_events()
    |> Enum.map(& &1["status"])
  end

  defp compact_result_events(session) do
    session.events
    |> Enum.filter(&(&1["kind"] == "session_compact_result"))
  end

  defp eventually(fun, retries \\ 1500)

  defp eventually(fun, retries) do
    case fun.() do
      true -> true
      _ when retries <= 0 -> false
      _ -> SystemsRuntime.Proc.sleep(20) && eventually(fun, retries - 1)
    end
  end
end
