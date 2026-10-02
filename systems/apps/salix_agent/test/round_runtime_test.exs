defmodule SalixAgent.RoundRuntimeTest do
  @moduledoc """
  Round runtime boundary tests: Round requires a session runtime context, records
  LLM metering around provider calls, and leaves cross-session delivery routing
  to the session/agent actor boundary.
  """
  use ExUnit.Case, async: false
  require OpenTelemetry.Tracer, as: Tracer

  alias SalixAgent.{
    AsyncToolResults,
    InternalAgentRuntime,
    InternalSession,
    InternalSessionStore,
    Round,
    SessionWorkIndex,
    ToolResultProjection
  }

  alias SalixStore.{Agent.Owned, Keys, S3}

  defmodule FunLLM do
    @moduledoc "Scriptable LLM where each turn is a fun of (messages, tools)."
    @behaviour SalixAgent.LLM
    use Elixir.Agent

    def start_link(_), do: Elixir.Agent.start_link(fn -> [] end, name: __MODULE__)
    def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
    def script(funs), do: Elixir.Agent.update(__MODULE__, fn _ -> funs end)

    @impl true
    def complete(messages, tools) do
      __MODULE__
      |> Elixir.Agent.get_and_update(fn
        [f | rest] -> {f, rest}
        [] -> {nil, []}
      end)
      |> then(fn
        nil -> {:final, "script exhausted"}
        fun -> fun.(messages, tools)
      end)
      |> normalize_result()
    end

    @impl true
    def complete_stream(messages, tools, on_delta) do
      __MODULE__
      |> Elixir.Agent.get_and_update(fn
        [f | rest] -> {f, rest}
        [] -> {nil, []}
      end)
      |> then(fn
        nil -> {:final, "script exhausted"}
        fun when is_function(fun, 3) -> fun.(messages, tools, on_delta)
        fun -> fun.(messages, tools)
      end)
      |> normalize_result()
    end

    # This test helper's historical `:final` fixtures describe successful
    # normal turns. Preserve that intent through the explicit outcome protocol
    # instead of making production accept provider prose as terminal again.
    defp normalize_result({:raw, result}), do: result

    defp normalize_result({:final, content}),
      do: {:assistant, content, [done_call()]}

    defp normalize_result({:final, content, trace_meta}),
      do: {:assistant, content, [done_call()], nil, trace_meta}

    defp normalize_result({:final, content, provider_meta, trace_meta}),
      do: {:assistant, content, [done_call()], provider_meta, trace_meta}

    defp normalize_result(result), do: result

    defp done_call do
      %{
        id: "round_runtime_end_turn_#{System.unique_integer([:positive, :monotonic])}",
        name: "end_turn",
        args: %{"outcome" => "done"}
      }
    end
  end

  defmodule TimingLLM do
    def complete(_, _), do: raise("timing test expects streaming")

    def complete_stream(_messages, _tools, on_delta, opts) do
      opts = Map.new(opts)
      Process.sleep(20)
      before_delta = System.system_time(:millisecond)

      case Application.fetch_env!(:salix_agent, :timing_test_delta) do
        :text ->
          on_delta.("first")

        :tool ->
          opts.on_tool_delta.(%{index: 0, id: "timing-call", name: "end_turn", fragment: "{"})

        :reasoning ->
          opts.on_reasoning_delta.(%SalixAgent.LLM.ReasoningDelta{
            visibility: :private_reasoning,
            text: "private"
          })
      end

      send(
        Application.fetch_env!(:salix_agent, :metering_test_pid),
        {:first_output_bounds, before_delta, System.system_time(:millisecond)}
      )

      Process.sleep(20)
      on_delta.("later")

      {:assistant, "timing complete",
       [%{id: "timing-end", name: "end_turn", args: %{"outcome" => "done"}}]}
    end
  end

  # A round that answers with a tool call and no prose. This is the ordinary
  # shape for a tool-calling model, and it never reaches `on_delta`.
  defmodule ToolOnlyStreamLLM do
    def complete(_, _), do: raise("tool-only test expects streaming")

    def complete_stream(_messages, _tools, _on_delta, opts) do
      opts = Map.new(opts)
      Process.sleep(20)
      opts.on_tool_delta.(%{index: 0, id: "tool-only-call", name: "end_turn", fragment: "{"})
      opts.on_tool_delta.(%{index: 0, id: "tool-only-call", name: "end_turn", fragment: "}"})

      {:assistant, "", [%{id: "tool-only-call", name: "end_turn", args: %{"outcome" => "done"}}]}
    end
  end

  defmodule MeteringFake do
    @moduledoc false
    @behaviour SalixAgent.LLMMetering

    @impl true
    def before_llm_call(fact) do
      send(Application.fetch_env!(:salix_agent, :metering_test_pid), {:meter_before, fact})
      :ok
    end

    @impl true
    def after_llm_call(fact) do
      send(Application.fetch_env!(:salix_agent, :metering_test_pid), {:meter_after, fact})
      :ok
    end
  end

  defmodule FreeRouterMetering do
    @behaviour SalixAgent.LLMMetering
    def before_llm_call(fact) do
      send(Application.fetch_env!(:salix_agent, :metering_test_pid), {:free_main_admission, fact})
      {:ok, %{billing_exemption: "free_router_model"}}
    end

    def after_llm_call(fact), do: MeteringFake.after_llm_call(fact)
  end

  defmodule ObservabilityFake do
    @moduledoc false
    @behaviour SalixAgent.Observability

    @impl true
    def tool_call(fact) do
      send(Application.fetch_env!(:salix_agent, :metering_test_pid), {:tool_observation, fact})
      :ok
    end

    @impl true
    def agent_run(fact) do
      send(Application.fetch_env!(:salix_agent, :metering_test_pid), {:run_observation, fact})
      :ok
    end

    @impl true
    def round_phase(fact) do
      send(Application.fetch_env!(:salix_agent, :metering_test_pid), {:phase_observation, fact})
      :ok
    end

    @impl true
    def llm_attempt(fact) do
      send(Application.fetch_env!(:salix_agent, :metering_test_pid), {:attempt_observation, fact})
      :ok
    end
  end

  defmodule ResponsesResolver do
    @moduledoc false
    def resolve(_agent_id), do: {:ok, %{protocol: "responses"}}
  end

  defmodule ProjectKnowledgeProvider do
    @moduledoc false

    def retrieve(agent_id, question, context) do
      test_pid = Application.fetch_env!(:salix_agent, :metering_test_pid)

      send(
        test_pid,
        {:project_knowledge_retrieved, agent_id, question, context}
      )

      delay_ms = Application.get_env(:salix_agent, :project_knowledge_round_delay_ms, 0)

      if delay_ms > 0 do
        Process.send_after(
          test_pid,
          {:project_knowledge_provider_delay_elapsed, context.session_id},
          delay_ms
        )
      end

      Process.sleep(delay_ms)

      :salix_agent
      |> Application.get_env(:project_knowledge_round_result, :none)
      |> with_default_subject()
    end

    defp with_default_subject({:ok, %{status: :resolved, facts: facts} = result})
         when not is_map_key(result, :entities) do
      subject = {:project, "project-test"}

      {:ok,
       result
       |> Map.put(:entities, [
         %{kind: :project, id: "project-test", matched_alias: "Test Project"}
       ])
       |> Map.put(:facts, Enum.map(facts, &Map.put_new(&1, :about, [subject])))}
    end

    defp with_default_subject(result), do: result
  end

  defmodule BlockingEnvDispatch do
    @moduledoc false
    @behaviour SalixAgent.EnvDispatch

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    @impl true
    def list_devices(_agent_id, _opts), do: {:ok, %{devices: [], next_cursor: nil}}

    @impl true
    def list_envs(_agent_id), do: {:ok, []}

    @impl true
    def get_device(_agent_id, _device_id), do: {:error, :no_environment}

    @impl true
    def exec(_agent_id, _env_id, _cmd, _opts), do: {:error, :no_environment}

    @impl true
    def computer_use(_agent_id, _env_id, _action), do: {:error, :no_environment}
    @impl true
    def android(_agent_id, _env_id, _action), do: {:error, :no_environment}

    @impl true
    def process_list(_agent_id, _env_id), do: {:error, :no_environment}

    @impl true
    def process_write(_agent_id, _env_id, _process_name, _data, _opts),
      do: {:error, :no_environment}

    @impl true
    def process_tail(_agent_id, _env_id, _process_name, _opts),
      do: {:error, :no_environment}

    @impl true
    def read_stream(_agent_id, _env_id, _path) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:zero_wait_tool_started, self()})

      receive do
        :release_zero_wait_tool -> {:ok, ["copy-body"], 9}
      after
        5_000 -> {:error, :blocked_copy_timeout}
      end
    end

    @impl true
    def write_stream(_agent_id, _env_id, _path, stream) do
      body = Enum.to_list(stream)
      {:ok, %{"size" => IO.iodata_length(body)}}
    end
  end

  defmodule DenyMetering do
    @moduledoc false
    @behaviour SalixAgent.LLMMetering

    @impl true
    def before_llm_call(fact) do
      send(Application.fetch_env!(:salix_agent, :metering_test_pid), {:meter_denied, fact})

      {:error,
       {:billing_unavailable,
        struct!(BillingCore.FeeControl.Decision, allowed?: false, reason: "insufficient_credits")}}
    end

    @impl true
    def after_llm_call(fact) do
      send(Application.fetch_env!(:salix_agent, :metering_test_pid), {:meter_after, fact})
      :ok
    end
  end

  setup do
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_metering = Application.get_env(:salix_agent, :llm_metering_mod)
    prev_observability = Application.get_env(:salix_agent, :agent_observability_mod)
    prev_metering_pid = Application.get_env(:salix_agent, :metering_test_pid)
    prev_knowledge_provider = Application.get_env(:salix_agent, :project_knowledge_provider_mod)
    prev_knowledge_result = Application.get_env(:salix_agent, :project_knowledge_round_result)
    prev_knowledge_delay = Application.get_env(:salix_agent, :project_knowledge_round_delay_ms)

    prev_knowledge_timeout =
      Application.get_env(:salix_agent, :project_knowledge_provider_timeout_ms)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(FunLLM)
    Application.put_env(:salix_agent, :llm, FunLLM)
    Application.put_env(:salix_agent, :llm_metering_mod, MeteringFake)
    Application.put_env(:salix_agent, :agent_observability_mod, ObservabilityFake)
    Application.put_env(:salix_agent, :metering_test_pid, self())

    Application.put_env(
      :salix_agent,
      :project_knowledge_provider_mod,
      ProjectKnowledgeProvider
    )

    Application.put_env(:salix_agent, :project_knowledge_round_result, :none)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_backend)

      if prev_llm,
        do: Application.put_env(:salix_agent, :llm, prev_llm),
        else: Application.delete_env(:salix_agent, :llm)

      if prev_metering,
        do: Application.put_env(:salix_agent, :llm_metering_mod, prev_metering),
        else: Application.delete_env(:salix_agent, :llm_metering_mod)

      if prev_observability,
        do: Application.put_env(:salix_agent, :agent_observability_mod, prev_observability),
        else: Application.delete_env(:salix_agent, :agent_observability_mod)

      if prev_metering_pid,
        do: Application.put_env(:salix_agent, :metering_test_pid, prev_metering_pid),
        else: Application.delete_env(:salix_agent, :metering_test_pid)

      if prev_knowledge_provider,
        do:
          Application.put_env(
            :salix_agent,
            :project_knowledge_provider_mod,
            prev_knowledge_provider
          ),
        else: Application.delete_env(:salix_agent, :project_knowledge_provider_mod)

      if prev_knowledge_result,
        do:
          Application.put_env(
            :salix_agent,
            :project_knowledge_round_result,
            prev_knowledge_result
          ),
        else: Application.delete_env(:salix_agent, :project_knowledge_round_result)

      if prev_knowledge_delay,
        do:
          Application.put_env(
            :salix_agent,
            :project_knowledge_round_delay_ms,
            prev_knowledge_delay
          ),
        else: Application.delete_env(:salix_agent, :project_knowledge_round_delay_ms)

      if prev_knowledge_timeout,
        do:
          Application.put_env(
            :salix_agent,
            :project_knowledge_provider_timeout_ms,
            prev_knowledge_timeout
          ),
        else: Application.delete_env(:salix_agent, :project_knowledge_provider_timeout_ms)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    group_id = SalixStore.Ids.group_id_from_agent!(agent)
    tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)

    SalixAgent.TestSupport.create_control_agent!(agent, %{
      tenant_id: tenant_id,
      group_id: group_id,
      role: "worker"
    })

    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent, "ses1_0000000000000000902", [
        %{
          "type" => "session_created",
          "session_id" => "ses1_0000000000000000902",
          "platform" => "raft",
          "task_origin" => "trajectory:case_1",
          "source_schedule_id" => "schedule_1"
        },
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000000902",
          "message_id" => 1,
          "content" => "do the long task"
        }
      ])

    {:ok,
     agent: agent,
     context: %{agent_id: agent, session_id: "ses1_0000000000000000902"},
     tenant_id: tenant_id,
     group_id: group_id}
  end

  defmodule MiniskillPlugins do
    def runtime_projection(attrs) do
      with {:ok, projection} <- Salix.Bindings.AgentPluginStore.runtime_projection(attrs) do
        {:ok,
         Map.update(
           projection,
           "visible_skill_ids",
           ["miniskill-runtime"],
           &["miniskill-runtime" | &1]
         )}
      end
    end
  end

  test "accepted human input receives selected instructions through the Session owner", %{
    context: context,
    tenant_id: tenant,
    group_id: group
  } do
    alias SalixAgent.{DecideFixture, InternalSession, SkillStore}
    DecideFixture.start_provider()
    DecideFixture.put_env(:decide_test_pid, self())
    DecideFixture.put_env(:decide_selected_miniskill, "miniskill-runtime")
    DecideFixture.put_env(:plugin_store_mod, MiniskillPlugins)
    DecideFixture.put_env(:ifc_facts_mod, nil)
    ctx = %{agent_id: context.agent_id, tenant_id: tenant, group_id: group}

    {:ok, event} =
      SkillStore.prepare_group_create(ctx, %{
        "skill_id" => "miniskill-runtime",
        "name" => "miniskill-runtime",
        "content" =>
          "---\nname: miniskill-runtime\ndescription: Diagnose build failures\nactivation: per-message\n---\nMINISKILL_RUNTIME_INSTRUCTION"
      })

    assert {:ok, _} = SkillStore.commit_operation("miniskill-runtime", %{}, [event])

    assert {:ok, _} =
             InternalSessionStore.prepare_commit(context.agent_id, context.session_id, [
               %{
                 "type" => "delivery",
                 "from_queue" => true,
                 "message_id" => 2,
                 "role" => "user",
                 "source_message_id" => "miniskill-source",
                 "content" => "Fix the build",
                 "trusted_origin" => %{"provider" => "internal", "source_actor_type" => "user"}
               }
             ])

    pid = self()

    FunLLM.script([
      fn messages, _tools ->
        send(pid, {:miniskill_agent_request, messages})
        {:final, "done"}
      end
    ])

    assert :ok = SalixAgent.InternalSessionFleet.wake(context.agent_id, context.session_id)
    assert_receive {:decision_request, _, _, decision}, 5_000
    assert decision["state"]["message"]["text"] == "Fix the build"
    assert_receive {:miniskill_agent_request, messages}, 5_000

    assert_receive {:phase_observation,
                    %{
                      phase: "miniskill",
                      duration_ms: miniskill_ms,
                      round_id: miniskill_round,
                      session_id: miniskill_session
                    }},
                   1_000

    assert miniskill_ms >= 0 and miniskill_ms <= 1_000
    assert is_binary(miniskill_round)
    assert miniskill_session == context.session_id

    assert Enum.any?(
             messages,
             &(is_binary(&1[:content]) and
                 String.contains?(&1[:content], "MINISKILL_RUNTIME_INSTRUCTION"))
           )

    :ok = SalixAgent.TestSupport.join_session_owner(context.agent_id, context.session_id)
    assert {:ok, stored} = InternalSessionStore.read(context.agent_id, context.session_id)

    assert [
             %{
               "outcome" => "selected",
               "source_message_id" => "miniskill-source",
               "skills" => [%{"skill_id" => "miniskill-runtime"}]
             }
           ] = InternalSession.get(stored, :miniskills)["inputs"]

    refute Enum.any?(
             messages,
             &(&1[:role] == "system" and
                 is_binary(&1[:content]) and
                 String.contains?(&1[:content], "Diagnose build failures"))
           )

    refute Enum.any?(
             InternalSession.get(stored, :messages),
             &(&1[:content] == "MINISKILL_RUNTIME_INSTRUCTION")
           )
  end

  test "Round carries the admitted free decision through provider completion", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(agent, "ses1_0000000000000000902")
    Application.put_env(:salix_agent, :llm_metering_mod, FreeRouterMetering)

    FunLLM.script([
      fn _messages, _tools ->
        # A policy change while the provider runs must not change this call.
        Application.put_env(:salix_agent, :llm_metering_mod, MeteringFake)
        {:final, "done", %{"usage" => %{"prompt_tokens" => 10}}}
      end
    ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")
    assert_receive {:free_main_admission, %{model_purpose: :agent_main, salix_agent_id: ^agent}}

    assert_receive {:meter_after,
                    %{billing_exemption: "free_router_model", usage: %{"prompt_tokens" => 10}}}
  end

  test "a failed provider attempt is recorded with its outcome before the retry succeeds", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(agent, "ses1_0000000000000000902")

    FunLLM.script([
      fn _messages, _tools ->
        {:error,
         %{
           "category" => "transport_error",
           "message" => "LLM provider transport failed",
           "reason" => "{:stream_idle_timeout, 30000}",
           "retryable" => true
         }}
      end,
      fn _messages, _tools -> {:final, "recovered"} end
    ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")

    assert_receive {:attempt_observation, fact}
    assert fact.attempt == 1
    assert fact.max_attempts == 6
    assert fact.outcome == "retry"
    assert fact.category == "transport_error"
    assert fact.reason =~ "stream_idle_timeout"
    assert fact.delay_ms == 250
    assert is_integer(fact.duration_ms)
    assert is_binary(fact.round_id)
    assert fact.session_id == "ses1_0000000000000000902"
    refute_receive {:attempt_observation, _}, 50
  end

  test "a permanent provider error is recorded as exhausted on its only attempt", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(agent, "ses1_0000000000000000902")

    FunLLM.script([
      fn _messages, _tools ->
        {:error,
         %{
           "category" => "permanent_provider_error",
           "message" => "LLM provider rejected the request",
           "status" => 400,
           "retryable" => false
         }}
      end
    ])

    _ = Round.run(context, "ses1_0000000000000000902")

    assert_receive {:attempt_observation, fact}
    assert fact.attempt == 1
    assert fact.outcome == "exhausted"
    assert fact.category == "permanent_provider_error"
    assert fact.http_status == 400
    assert fact.delay_ms == 0
    refute_receive {:attempt_observation, _}, 50
  end

  test "assistant usage is bound to the request compaction generation", %{
    agent: agent,
    context: context
  } do
    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent, "ses1_0000000000000000902", [
        %{
          "type" => "compaction",
          "session_id" => "ses1_0000000000000000902",
          "summary" => "<compacted-context>existing summary</compacted-context>",
          "compacted_through" => 0,
          "summary_sequence" => 7
        }
      ])

    ack_setup_input!(agent, "ses1_0000000000000000902")

    FunLLM.script([
      fn _messages, _tools ->
        {:final, "done",
         %{
           "model" => "usage-model",
           "usage" => %{
             "prompt_tokens" => 605_139,
             "completion_tokens" => 12,
             "cache_read_input_tokens" => 595_663
           }
         }}
      end
    ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")

    assistant =
      agent
      |> read_session!("ses1_0000000000000000902")
      |> SalixAgent.InternalSession.get(:messages)
      |> Enum.find(&(&1[:role] == "assistant"))

    assert assistant.input_tokens == 605_139
    assert assistant.cache_read_input_tokens == 595_663
    assert assistant.request_summary_sequence == 7
    assert assistant.request_compacted_through == 0
    assert assistant.request_input_through == 1
  end

  test "a resolved project fact reaches the LLM and is committed with its source evidence", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(agent, "ses1_0000000000000000902")

    Application.put_env(
      :salix_agent,
      :project_knowledge_round_result,
      {:ok,
       %{
         status: :resolved,
         facts: [
           %{
             id: "assertion-atlas-owner",
             kind: :decision,
             content: "Lin owns the Atlas launch checklist.",
             source_refs: [
               %{type: "slack_receipt", ref: "s3://triage/receipts/atlas-owner.json"}
             ]
           }
         ]
       }}
    )

    test_pid = self()

    FunLLM.script([
      fn messages, _tools ->
        send(test_pid, {:knowledge_llm_messages, messages})
        {:final, "Lin owns it."}
      end
    ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")

    assert_receive {:project_knowledge_retrieved, ^agent, "do the long task",
                    %{
                      session_id: "ses1_0000000000000000902"
                    }}

    assert_receive {:knowledge_llm_messages, messages}

    assert %{role: "runtime", type: "project_knowledge", source_refs: source_refs} =
             Enum.find(messages, &(&1[:type] == "project_knowledge"))

    assert source_refs["assertions"] == [
             %{
               "id" => "assertion-atlas-owner",
               "sources" => [
                 %{
                   "type" => "slack_receipt",
                   "ref" => "s3://triage/receipts/atlas-owner.json"
                 }
               ]
             }
           ]

    session = read_session!(agent, "ses1_0000000000000000902")

    assert Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
             message.role == "runtime" and message.type == "project_knowledge" and
               get_in(message.source_refs, ["assertions", Access.at(0), "id"]) ==
                 "assertion-atlas-owner"
           end)

    :ok = S3.Fake.reset_read_log()

    assert {:ok,
            %{
              "uses" => [use],
              "complete" => true,
              "history_truncated" => false,
              "sessions_scanned" => 1
            }} =
             InternalAgentRuntime.list_project_knowledge_uses(agent,
               assertion_ids: ["assertion-atlas-owner"]
             )

    prefix = Keys.agent_internal_runtime_sessions_prefix(agent)

    assert {:list, ^prefix, list_opts} =
             Enum.find(S3.Fake.read_log(self()), fn
               {:list, ^prefix, _opts} -> true
               _ -> false
             end)

    assert list_opts[:max_keys] == 100

    :ok = S3.Fake.reset_read_log()

    assert {:ok,
            %{
              "uses" => [],
              "complete" => true,
              "sessions_scanned" => 0
            }} = InternalAgentRuntime.list_project_knowledge_uses(agent, assertion_ids: [])

    assert S3.Fake.read_log(self()) == []

    assert use["session_id"] == "ses1_0000000000000000902"
    assert use["retrieval_id"] =~ "project-knowledge:"
    assert use["assistant_excerpt"] == "Lin owns it."
    assert get_in(use, ["assertions", Access.at(0), "id"]) == "assertion-atlas-owner"
  end

  test "a stalled project knowledge provider cannot indefinitely block an ordinary round", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(agent, "ses1_0000000000000000902")
    Application.put_env(:salix_agent, :project_knowledge_provider_timeout_ms, 20)
    Application.put_env(:salix_agent, :project_knowledge_round_delay_ms, 250)
    test_pid = self()
    handler_id = "round-project-knowledge-timeout-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:salix, :project_knowledge, :retrieve, :stop],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:project_knowledge_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    FunLLM.script([
      fn messages, _tools ->
        send(test_pid, {:llm_after_knowledge_timeout, messages})
        {:final, "Fallback answer"}
      end
    ])

    round = Task.async(fn -> Round.run(context, "ses1_0000000000000000902") end)

    # Round admission precedes the provider watchdog. Wait for that handshake
    # without changing the provider timeout or the fallback assertions below.
    assert_receive {:project_knowledge_retrieved, _agent_id, _question,
                    %{session_id: "ses1_0000000000000000902"}},
                   2_000

    assert_receive {:project_knowledge_telemetry, [:salix, :project_knowledge, :retrieve, :stop],
                    _measurements, %{outcome: :timeout}}

    assert_receive {:llm_after_knowledge_timeout, messages}
    refute_receive {:project_knowledge_provider_delay_elapsed, _session_id}, 0
    refute Enum.any?(messages, &(&1[:type] == "project_knowledge"))

    assert {:ok, _context, :final} = Task.await(round, 2_000)
  end

  test "historical project knowledge is absent from a later unrelated round", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(agent, "ses1_0000000000000000902")

    Application.put_env(
      :salix_agent,
      :project_knowledge_round_result,
      {:ok,
       %{
         status: :resolved,
         facts: [
           %{
             id: "assertion-atlas-private",
             kind: :fact,
             content: "The Atlas launch code is ORCHID.",
             source_refs: [
               %{type: "slack_receipt", ref: "s3://triage/receipts/atlas-private.json"}
             ]
           }
         ]
       }}
    )

    test_pid = self()

    FunLLM.script([
      fn messages, _tools ->
        send(test_pid, {:first_knowledge_round, messages})
        {:final, "First answer"}
      end,
      fn messages, _tools ->
        send(test_pid, {:second_knowledge_round, messages})
        {:final, "Second answer"}
      end
    ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")
    assert_receive {:first_knowledge_round, first_messages}
    assert Enum.any?(first_messages, &(&1[:type] == "project_knowledge"))

    session = read_session!(agent, "ses1_0000000000000000902")
    next_id = Enum.max_by(SalixAgent.InternalSession.get(session, :messages), & &1.id).id + 1

    assert {:ok, _session} =
             InternalSessionStore.prepare_commit(agent, "ses1_0000000000000000902", [
               %{
                 "type" => "delivery",
                 "from_queue" => true,
                 "session_id" => "ses1_0000000000000000902",
                 "message_id" => next_id,
                 "content" => "What is the weather?"
               },
               %{
                 "type" => "ack",
                 "session_id" => "ses1_0000000000000000902",
                 "last_ack_message_id" => next_id
               }
             ])

    Application.put_env(:salix_agent, :project_knowledge_round_result, :none)

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")
    assert_receive {:second_knowledge_round, second_messages}

    refute Enum.any?(second_messages, &(&1[:type] == "project_knowledge"))
    refute Enum.any?(second_messages, &String.contains?(&1[:content] || "", "ORCHID"))
  end

  test "a continuation round keeps the activation's project knowledge in place and stores it once",
       %{agent: agent, context: context} do
    ack_setup_input!(agent, "ses1_0000000000000000902")

    Application.put_env(
      :salix_agent,
      :project_knowledge_round_result,
      {:ok,
       %{
         status: :resolved,
         facts: [
           %{
             id: "assertion-atlas-continue",
             kind: :fact,
             content: "Lin owns the Atlas launch checklist.",
             source_refs: [
               %{type: "slack_receipt", ref: "s3://triage/receipts/atlas-continue.json"}
             ]
           }
         ]
       }}
    )

    test_pid = self()

    FunLLM.script([
      fn messages, _tools ->
        send(test_pid, {:first_continuation_round, messages})
        {:assistant, "working", []}
      end,
      fn messages, _tools ->
        send(test_pid, {:second_continuation_round, messages})
        {:final, "done"}
      end
    ])

    assert {:ok, _context, :round_boundary} = Round.run(context, "ses1_0000000000000000902")
    assert_receive {:first_continuation_round, first_messages}
    assert Enum.count(first_messages, &(&1[:type] == "project_knowledge")) == 1

    # The unacknowledged input continues on the fleet without a second call.
    assert_receive {:second_continuation_round, second_messages}, 5_000

    # The block sits where round one committed it, ahead of that round's reply,
    # rather than being retrieved again and appended after it.
    assert Enum.count(second_messages, &(&1[:type] == "project_knowledge")) == 1

    knowledge_index = Enum.find_index(second_messages, &(&1[:type] == "project_knowledge"))

    working_index =
      Enum.find_index(second_messages, &(&1[:role] == "assistant" and &1[:content] == "working"))

    assert knowledge_index < working_index

    assert eventually(fn ->
             agent
             |> read_session!("ses1_0000000000000000902")
             |> SalixAgent.InternalSession.get(:messages)
             |> Enum.any?(&(&1[:role] == "assistant" and &1[:content] == "done"))
           end)

    assert agent
           |> read_session!("ses1_0000000000000000902")
           |> SalixAgent.InternalSession.get(:messages)
           |> Enum.count(&(&1[:type] == "project_knowledge")) == 1
  end

  test "repeating a question activates the same project knowledge for the new user message", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(agent, "ses1_0000000000000000902")

    Application.put_env(
      :salix_agent,
      :project_knowledge_round_result,
      {:ok,
       %{
         status: :resolved,
         facts: [
           %{
             id: "assertion-atlas-repeat",
             kind: :fact,
             content: "Lin owns the Atlas launch checklist.",
             source_refs: [
               %{type: "slack_receipt", ref: "s3://triage/receipts/atlas-repeat.json"}
             ]
           }
         ]
       }}
    )

    test_pid = self()

    FunLLM.script([
      fn messages, _tools ->
        send(test_pid, {:first_repeated_question_round, messages})
        {:final, "First answer"}
      end,
      fn messages, _tools ->
        send(test_pid, {:second_repeated_question_round, messages})
        {:final, "Second answer"}
      end
    ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")
    assert_receive {:first_repeated_question_round, first_messages}
    assert Enum.any?(first_messages, &(&1[:type] == "project_knowledge"))

    session = read_session!(agent, "ses1_0000000000000000902")
    next_id = Enum.max_by(SalixAgent.InternalSession.get(session, :messages), & &1.id).id + 1

    assert {:ok, _session} =
             InternalSessionStore.prepare_commit(agent, "ses1_0000000000000000902", [
               %{
                 "type" => "delivery",
                 "from_queue" => true,
                 "session_id" => "ses1_0000000000000000902",
                 "message_id" => next_id,
                 "content" => "do the long task"
               },
               %{
                 "type" => "ack",
                 "session_id" => "ses1_0000000000000000902",
                 "last_ack_message_id" => next_id
               }
             ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")
    assert_receive {:second_repeated_question_round, second_messages}
    assert Enum.any?(second_messages, &(&1[:type] == "project_knowledge"))
  end

  test "one round retrieves project knowledge for every ordered user delivery", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(agent, "ses1_0000000000000000902")
    test_pid = self()

    FunLLM.script([
      fn _messages, _tools -> {:final, "Setup complete"} end,
      fn messages, _tools ->
        send(test_pid, {:multi_delivery_knowledge_round, messages})
        {:final, "Lin owns Atlas. Hello."}
      end
    ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")
    assert_receive {:project_knowledge_retrieved, ^agent, "do the long task", _context}

    session = read_session!(agent, "ses1_0000000000000000902")

    first_delivery_id =
      Enum.max_by(SalixAgent.InternalSession.get(session, :messages), & &1.id).id + 1

    second_delivery_id = first_delivery_id + 1

    assert {:ok, _session} =
             InternalSessionStore.prepare_commit(agent, "ses1_0000000000000000902", [
               %{
                 "type" => "delivery",
                 "from_queue" => true,
                 "session_id" => "ses1_0000000000000000902",
                 "message_id" => first_delivery_id,
                 "content" => "What does Lin own in Atlas?"
               },
               %{
                 "type" => "delivery",
                 "from_queue" => true,
                 "session_id" => "ses1_0000000000000000902",
                 "message_id" => second_delivery_id,
                 "content" => "Also say hello."
               },
               %{
                 "type" => "ack",
                 "session_id" => "ses1_0000000000000000902",
                 "last_ack_message_id" => second_delivery_id
               }
             ])

    Application.put_env(
      :salix_agent,
      :project_knowledge_round_result,
      {:ok,
       %{
         status: :resolved,
         facts: [
           %{
             id: "assertion-atlas-multi-delivery",
             kind: :fact,
             content: "Lin owns the Atlas launch checklist.",
             source_refs: [
               %{type: "slack_receipt", ref: "s3://triage/receipts/atlas-multi.json"}
             ]
           }
         ]
       }}
    )

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")

    assert_receive {:project_knowledge_retrieved, ^agent,
                    "What does Lin own in Atlas?\n\nAlso say hello.", _context}

    assert_receive {:multi_delivery_knowledge_round, messages}
    assert Enum.any?(messages, &(&1[:type] == "project_knowledge"))
  end

  test "InternalSessionActor GenServer restores caller observability context", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")
    test = self()

    FunLLM.script([
      fn _messages, _tools ->
        span = OpenTelemetry.Tracer.current_span_ctx()

        send(test, {
          :actor_observability_context,
          SystemsObservability.Context.current_surface(),
          Logger.metadata()[:correlation_id],
          OpenTelemetry.Span.trace_id(span)
        })

        {:final, "done"}
      end
    ])

    Tracer.with_span "round_runtime_test.parent" do
      parent = OpenTelemetry.Tracer.current_span_ctx()

      SystemsObservability.Context.with_surface("comma", fn ->
        correlation_id = Logger.metadata()[:correlation_id]

        assert {:ok, _context, :final} =
                 SalixAgent.InternalSessionFleet.run_round(
                   agent,
                   "ses1_0000000000000000902",
                   Map.put(context, :surface, "comma"),
                   __round_run_delegate__: true
                 )

        assert_receive {:actor_observability_context, "comma", ^correlation_id, trace_id}
        assert trace_id == OpenTelemetry.Span.trace_id(parent)
      end)
    end
  end

  test "public Round.run cannot force a user provider back into the actor mailbox", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(agent, "ses1_0000000000000000902")
    previous_timeout = Application.get_env(:salix_agent, :dependency_job_timeout_ms)
    Application.put_env(:salix_agent, :dependency_job_timeout_ms, %{llm: 100})

    on_exit(fn ->
      if previous_timeout do
        Application.put_env(:salix_agent, :dependency_job_timeout_ms, previous_timeout)
      else
        Application.delete_env(:salix_agent, :dependency_job_timeout_ms)
      end
    end)

    test = self()

    FunLLM.script([
      fn _messages, _tools ->
        send(test, {:delegated_llm_blocked, self()})
        Process.sleep(:infinity)
      end
    ])

    # `Round.run/3` delegates from this non-owner process. Even an explicit
    # request for the old synchronous mode cannot execute the provider in the
    # session actor mailbox.
    caller =
      Task.async(fn ->
        Round.run(context, "ses1_0000000000000000902", async_llm: false)
      end)

    assert_receive {:delegated_llm_blocked, dependency_pid}, 1_000

    [{actor_pid, _metadata}] =
      Registry.lookup(
        SalixAgent.Registry,
        SalixAgent.InternalSessionActor.key(agent, "ses1_0000000000000000902")
      )

    assert {:error, :session_busy} =
             SalixAgent.InternalSessionActor.run_round(actor_pid, context, [], 250)

    assert {:error, {:dependency_timeout, :llm}} = Task.await(caller, 1_000)
    assert eventually(fn -> :sys.get_state(actor_pid).pending_llm == nil end)
    refute Process.alive?(dependency_pid)
  end

  test "async LLM task retains the actor trace and surface context", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")
    test = self()

    FunLLM.script([
      fn _messages, _tools ->
        span = OpenTelemetry.Tracer.current_span_ctx()

        send(test, {
          :async_actor_observability_context,
          SystemsObservability.Context.current_surface(),
          Logger.metadata()[:correlation_id],
          OpenTelemetry.Span.trace_id(span)
        })

        {:final, "done"}
      end
    ])

    Tracer.with_span "round_runtime_test.async_parent" do
      parent = OpenTelemetry.Tracer.current_span_ctx()

      SystemsObservability.Context.with_surface("comma", fn ->
        correlation_id = Logger.metadata()[:correlation_id]

        assert {:ok, _context, {:llm_pending, _pending}} =
                 SalixAgent.InternalSessionFleet.run_round(
                   agent,
                   "ses1_0000000000000000902",
                   Map.put(context, :surface, "comma"),
                   []
                 )

        assert_receive {:async_actor_observability_context, "comma", ^correlation_id, trace_id},
                       1_000

        assert trace_id == OpenTelemetry.Span.trace_id(parent)
      end)
    end

    assert eventually(fn ->
             assistant_message?(agent, "ses1_0000000000000000902")
           end)
  end

  test "round requires session runtime context rather than the agent lease handle", %{
    agent: agent
  } do
    owned = %Owned{agent_id: agent}

    assert {:error, :agent_lease_not_session_runtime_context} =
             Round.run(owned, "ses1_0000000000000000902")

    assert {:error, :agent_lease_not_session_runtime_context} =
             Round.response_host(
               owned,
               %{session_id: "ses1_0000000000000000902"},
               {:final, "ignored"},
               0
             )

    assert {:error, {:session_runtime_context_missing, "ses1_0000000000000000902"}} =
             Round.run(%{agent_id: agent}, "ses1_0000000000000000902")

    assert {:error,
            {:session_runtime_context_mismatch, "ses1_0000000000000000902",
             "ses1_0000000000000000903"}} =
             Round.run(
               %{agent_id: agent, session_id: "ses1_0000000000000000903"},
               "ses1_0000000000000000902"
             )
  end

  test "metering records provider exceptions before preserving the failure", %{context: context} do
    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")

    FunLLM.script(
      List.duplicate(
        fn _messages, _tools ->
          raise "provider down"
        end,
        6
      )
    )

    assert {:error,
            {:dependency_crashed, :llm, {%RuntimeError{message: "provider down"}, _stacktrace}}} =
             Round.run(context, "ses1_0000000000000000902")

    assert_receive {:meter_before, %{entrypoint: "agent_round"}}
    assert_receive {:meter_after, %{status: "error", error: error, error_type: "exception"}}
    assert error =~ "provider down"
  end

  test "metering records async provider exceptions before the task exits", %{context: context} do
    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")

    FunLLM.script(
      List.duplicate(
        fn _messages, _tools ->
          raise "async provider down"
        end,
        6
      )
    )

    assert {:ok, _context, {:llm_pending, pending}} =
             Round.run(context, "ses1_0000000000000000902", async_llm: true)

    assert_receive {:meter_before, %{entrypoint: "agent_round"}}
    assert_receive {:meter_after, %{status: "error", error: error}}, 12_000
    assert error =~ "async provider down"

    assert is_reference(pending.ref)

    assert_receive {:run_observation,
                    %{
                      status: "actor_failed",
                      session_id: "ses1_0000000000000000902",
                      round_id: round_id,
                      duration_ms: duration_ms,
                      started_at: %DateTime{},
                      platform: "raft",
                      task_origin: "trajectory:case_1",
                      source_schedule_id: "schedule_1"
                    }},
                   2_000

    assert is_binary(round_id)
    assert duration_ms >= 0

    assert eventually(fn ->
             SalixAgent.InternalSession.get(
               read_session!(context.agent_id, "ses1_0000000000000000902"),
               :status
             ) == :idle
           end)
  end

  # Regression for the production incident that native file input caused: a
  # multi-attachment request was rejected by the provider and surfaced as a slow
  # generic connection failure. The request now carries no attachment bytes at
  # all, so there is nothing for a provider to reject and no recovery path to
  # get right. Both a synchronous provider fetch and an async result recovered
  # through tool_call.get_result are covered in one round.
  test "full Round announces provider attachments by path and sends no file bytes", %{
    agent: agent
  } do
    previous_resolver = Application.get_env(:salix_agent, :llm_resolver)
    Application.put_env(:salix_agent, :llm_resolver, ResponsesResolver)

    on_exit(fn ->
      if previous_resolver,
        do: Application.put_env(:salix_agent, :llm_resolver, previous_resolver),
        else: Application.delete_env(:salix_agent, :llm_resolver)
    end)

    ack_setup_input!(agent, "ses1_0000000000000000902")

    old_path = "/provider-history/old-async-report.pdf"
    current_path = "/provider-history/current-report.pdf"
    old_pdf = "%PDF-1.4\nold async report\n%%EOF\n"
    current_pdf = "%PDF-1.4\ncurrent report\n%%EOF\n"
    {:ok, old_write} = SalixAgent.AgentWorkspace.prepare_write(agent, old_path, old_pdf)

    {:ok, current_write} =
      SalixAgent.AgentWorkspace.prepare_write(agent, current_path, current_pdf)

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(
               agent,
               "round-provider-pdf-announcement",
               %{},
               [old_write, current_write]
             )

    provider_tool = "im_api.feishu.fetch_message_resource"
    old_provider_call_id = "provider-fetch-old-async-pdf"

    old_attachment = %{
      "type" => "file",
      "path" => old_path,
      "file_name" => "old-report.pdf",
      "mime_type" => "application/pdf",
      "size" => byte_size(old_pdf)
    }

    current_attachment = %{
      "type" => "file",
      "path" => current_path,
      "file_name" => "current-report.pdf",
      "mime_type" => "application/pdf",
      "size" => byte_size(current_pdf)
    }

    old_async_record =
      Jason.encode!(%{
        "status" => "completed",
        "tool_call_id" => old_provider_call_id,
        "tool_name" => provider_tool,
        "error" => false,
        "result" => %{
          "id" => old_provider_call_id,
          "name" => provider_tool,
          "status" => "completed",
          "content" => Jason.encode!([old_attachment]),
          "error" => false
        }
      })

    assert {:ok, _session} =
             InternalSessionStore.prepare_commit(agent, "ses1_0000000000000000902", [
               %{
                 "type" => "assistant",
                 "session_id" => "ses1_0000000000000000902",
                 "message_id" => 2,
                 "content" => "Reading the old completed provider result",
                 "tool_calls" => [
                   %{
                     "id" => "get-old-provider-result",
                     "name" => "tool_call.get_result",
                     "args" => %{"tool_call_id" => old_provider_call_id}
                   }
                 ]
               },
               %{
                 "type" => "tool_result",
                 "session_id" => "ses1_0000000000000000902",
                 "message_id" => 3,
                 "tool_call_id" => "get-old-provider-result",
                 "tool_name" => "tool_call.get_result",
                 "status" => "completed",
                 "content" => old_async_record
               },
               %{
                 "type" => "assistant",
                 "session_id" => "ses1_0000000000000000902",
                 "message_id" => 4,
                 "content" => "Fetching the current provider PDF",
                 "tool_calls" => [
                   %{
                     "id" => "provider-fetch-current-pdf",
                     "name" => provider_tool,
                     "args" => %{}
                   }
                 ]
               },
               %{
                 "type" => "tool_result",
                 "session_id" => "ses1_0000000000000000902",
                 "message_id" => 5,
                 "tool_call_id" => "provider-fetch-current-pdf",
                 "tool_name" => provider_tool,
                 "status" => "completed",
                 "content" => Jason.encode!([current_attachment])
               },
               %{
                 "type" => "queue_append",
                 "session_id" => "ses1_0000000000000000902",
                 "kind" => "user_message",
                 "wake" => true,
                 "dedupe_key" => "round-provider-current-pdf-user",
                 "payload" => %{
                   "source_message_id" => "round-provider-current-pdf-user",
                   "content" => "Analyze the current PDF"
                 }
               }
             ])

    test_pid = self()

    FunLLM.script([
      fn messages, _tools ->
        send(test_pid, {:round_attachment_request, Jason.encode!(messages)})
        {:final, "read the PDFs with my own tools"}
      end
    ])

    assert :ok = SalixAgent.InternalSessionFleet.wake(agent, "ses1_0000000000000000902")

    assert_receive {:round_attachment_request, request}, 2_000

    # No file input, on any protocol, for either attachment.
    refute request =~ "input_file"
    refute request =~ "file_data"
    refute request =~ Base.encode64(old_pdf)
    refute request =~ Base.encode64(current_pdf)

    # Announced, not dropped: the agent can still act on both.
    assert request =~ old_path
    assert request =~ current_path
    assert request =~ "fs.read_file"

    assert eventually(fn ->
             SalixAgent.InternalSession.get(
               read_session!(agent, "ses1_0000000000000000902"),
               :messages
             )
             |> Enum.any?(&(&1[:content] == "read the PDFs with my own tools"))
           end)

    # One provider call: there is no rejection to recover from.
    refute_receive {:round_attachment_request, _}
  end

  @tag subscription_timeout_regression: true
  test "a round waits for a provider cooldown before it retries", %{context: context} do
    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")
    owner = self()

    FunLLM.script([
      fn _messages, _tools ->
        send(owner, {:cooldown_started, System.monotonic_time(:millisecond)})

        {:error, error} =
          SalixAgent.LLM.Error.http("codex", 503, "subscription accounts unavailable")

        {:error, Map.put(error, "retry_after_ms", 1_000)}
      end,
      fn _messages, _tools ->
        send(owner, {:cooldown_retried, System.monotonic_time(:millisecond)})
        {:final, "recovered"}
      end
    ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")
    assert_receive {:cooldown_started, started}
    assert_receive {:cooldown_retried, retried}
    assert retried - started >= 1_000
    assert_receive {:meter_after, %{status: "ok", attempts: 2}}, 2_000
  end

  test "metering records attempts and first text token from the successful retry", %{
    context: context
  } do
    telemetry_handler = "round-logical-llm-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        telemetry_handler,
        [[:salix, :llm, :request, :stop], [:salix, :llm, :attempt, :stop]],
        fn event, measurements, metadata, _ ->
          send(parent, {:platform_llm, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)
    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")

    FunLLM.script([
      fn _messages, _tools, on_delta ->
        on_delta.("failed-attempt-delta")
        SalixAgent.LLM.Error.transport("mock", :timeout)
      end,
      fn _messages, _tools, on_delta ->
        Process.sleep(30)
        on_delta.("ok")
        {:final, "kept"}
      end
    ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")

    assert_receive {:meter_after,
                    %{
                      status: "ok",
                      attempts: 2,
                      response_kind: :assistant,
                      first_token_ms: first_token_ms,
                      duration_ms: duration_ms
                    }},
                   2_000

    assert first_token_ms >= 20
    # This should be measured from the successful retry attempt, not from the
    # original failed attempt plus retry backoff. Keep the upper bound below the
    # first retry delay while leaving scheduler headroom for loaded CI hosts.
    assert first_token_ms < 250
    assert first_token_ms < duration_ms

    assert_receive {:platform_llm, [:salix, :llm, :request, :stop], %{}, %{outcome: "ok"}}
    refute_receive {:platform_llm, [:salix, :llm, :request, :stop], _, _}

    scrape = SystemsObservability.scrape()
    assert scrape =~ "salix_llm_attempts_total"

    assert Enum.any?(String.split(scrape, "\n"), fn line ->
             String.starts_with?(line, "salix_llm_attempts_total{") and
               line =~ ~s(outcome="error")
           end)
  end

  test "final response emits completed agent run observation with attribution", %{
    context: context
  } do
    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")

    FunLLM.script([
      fn _messages, _tools ->
        {:final, "kept"}
      end
    ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")

    assert_receive {:run_observation,
                    %{
                      status: "completed",
                      salix_agent_id: agent_id,
                      session_id: "ses1_0000000000000000902",
                      round_id: round_id,
                      duration_ms: duration_ms,
                      started_at: %DateTime{},
                      app_revision: app_revision,
                      platform: "raft",
                      task_origin: "trajectory:case_1",
                      source_schedule_id: "schedule_1"
                    }},
                   1_000

    assert agent_id == context.agent_id
    assert is_binary(round_id)
    assert duration_ms >= 0
    assert is_binary(app_revision)
    assert app_revision != ""

    # Phase facts bracket the model call: `prepare` before the dispatch and
    # `finalize` after the final message commit, both on this round. A
    # direct Round.run has no actor activation, so no `activation` fact.
    assert_receive {:phase_observation,
                    %{
                      phase: "prepare",
                      round_id: ^round_id,
                      session_id: "ses1_0000000000000000902",
                      salix_agent_id: ^agent_id,
                      started_at: %DateTime{},
                      duration_ms: prepare_ms
                    }},
                   1_000

    assert_receive {:phase_observation, %{phase: "finalize", round_id: ^round_id}}, 1_000
    assert prepare_ms >= 0
    refute_received {:phase_observation, %{phase: "activation"}}
  end

  test "an actor-driven activation emits the activation phase ahead of prepare and finalize",
       %{agent: agent} do
    # The setup's delivery (message 1) is left unacked, so the session actor
    # activates on its own when started: repair → read → materialize →
    # config → dispatch. That whole stretch is the `activation` fact.
    FunLLM.script([fn _messages, _tools -> {:final, "activated"} end])

    {:ok, _} =
      SalixAgent.InternalSessionFleet.ensure_started(agent, "ses1_0000000000000000902",
        process_on_init: true
      )

    assert_receive {:run_observation, %{status: "completed", round_id: round_id}}, 10_000
    :ok = SalixAgent.TestSupport.await_session_quiet(agent, "ses1_0000000000000000902")

    assert_receive {:phase_observation,
                    %{phase: "activation", round_id: ^round_id, duration_ms: activation_ms}},
                   1_000

    assert_receive {:phase_observation,
                    %{phase: "prepare", round_id: ^round_id, started_at: prepare_at}},
                   1_000

    assert_receive {:phase_observation, %{phase: "finalize", round_id: ^round_id}}, 1_000

    # Activation ends where prepare starts: no gap and no overlap between
    # the two facts of one dispatch.
    assert activation_ms >= 0
    assert %DateTime{} = prepare_at
  end

  test "an input delivered through the facade reports how long it waited for activation",
       %{agent: agent} do
    ack_setup_input!(agent, "ses1_0000000000000000902")

    # A tool round followed by its continuation: the input is answered over
    # two rounds, and only the first may report how long it waited.
    FunLLM.script([
      fn _messages, _tools ->
        {:assistant, "checking",
         [
           %{
             id: "t1",
             name: "call",
             args: %{"tool" => "help", "params" => %{"tool" => "fs.read_file"}}
           }
         ]}
      end,
      fn _messages, _tools -> {:final, "answered"} end
    ])

    before = System.system_time(:millisecond)

    # SalixAgent.deliver stamps delivered_at_ms on the payload; the queued
    # item carries it into the transcript, and the round it wakes reports
    # the wait from that instant to the actor's processing entry.
    assert {:ok, :created} =
             SalixAgent.deliver(
               agent,
               %{
                 content: "how long did I wait?",
                 role: "user",
                 session_id: "ses1_0000000000000000902",
                 created_at: System.system_time(:second)
               },
               source_message_id: "wait-probe-1"
             )

    assert_receive {:run_observation, %{status: "completed", round_id: round_id}}, 10_000
    :ok = SalixAgent.TestSupport.await_session_quiet(agent, "ses1_0000000000000000902")

    assert_receive {:phase_observation,
                    %{
                      phase: "delivery_wait",
                      round_id: delivery_round,
                      started_at: %DateTime{} = delivered_at,
                      duration_ms: wait_ms,
                      activation_key: "wait-probe-1"
                    }},
                   1_000

    assert DateTime.to_unix(delivered_at, :millisecond) >= before
    assert wait_ms >= 0

    # Exactly one delivery_wait for the input: the continuation round (the
    # one that completed) reports its re-activation, not the arrival again.
    refute_received {:phase_observation, %{phase: "delivery_wait"}}
    assert delivery_round != round_id
    assert_receive {:phase_observation, %{phase: "activation", round_id: ^round_id}}, 1_000

    # The stamp is durable on the transcript message, not just in flight.
    {:ok, session} = SalixAgent.InternalSessionStore.read(agent, "ses1_0000000000000000902")

    assert Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
             (message[:source_message_id] || message["source_message_id"]) == "wait-probe-1" and
               is_integer(message[:delivered_at_ms] || message["delivered_at_ms"])
           end)
  end

  test "a no_wake context delivery is not charged as the next input's wait",
       %{agent: agent} do
    session_id = "ses1_0000000000000000902"
    ack_setup_input!(agent, session_id)

    FunLLM.script([fn _messages, _tools -> {:final, "answered"} end])

    # Staged context: committed durably, scheduling no round. Its id stays
    # unacked, so it rides along in the activation that the next ordinary
    # input opens — but it was never itself waiting for a round.
    assert {:ok, :created} =
             SalixAgent.deliver(
               agent,
               %{
                 content: "triage replied in the thread; context only",
                 role: "user",
                 session_id: session_id,
                 created_at: System.system_time(:second)
               },
               source_message_id: "triage-participation:ob1",
               no_wake: true
             )

    # No round, so no phase of any kind. This also separates the two
    # arrivals far enough that charging the wrong one is unambiguous.
    refute_receive {:phase_observation, _}, 300

    input_delivered_at = System.system_time(:millisecond)

    assert {:ok, :created} =
             SalixAgent.deliver(
               agent,
               %{
                 content: "an ordinary message",
                 role: "user",
                 session_id: session_id,
                 created_at: System.system_time(:second)
               },
               source_message_id: "groupconv-probe-1"
             )

    assert_receive {:run_observation, %{status: "completed"}}, 10_000
    :ok = SalixAgent.TestSupport.await_session_quiet(agent, session_id)

    assert_receive {:phase_observation,
                    %{phase: "delivery_wait", started_at: %DateTime{} = delivered_at}},
                   1_000

    # The wait spans the ordinary input's arrival, not the staged context's.
    # Charging the context reported every minute since it was staged as
    # queueing for an input that had only just arrived.
    assert DateTime.to_unix(delivered_at, :millisecond) >= input_delivered_at
  end

  test "the owner runs an input on its resident revision without re-reading the session",
       %{agent: agent} do
    session_id = "ses1_0000000000000000902"
    ack_setup_input!(agent, session_id)
    test_pid = self()
    handler = "round-runtime-store-reads-#{System.unique_integer([:positive])}"

    # Every store fetch reports here from the process that made it; the
    # session actor's own fetches are the session reads under test.
    :ok =
      :telemetry.attach(
        handler,
        [:salix, :operation, :stop],
        fn _event, _measurements, %{operation: operation}, _config ->
          if operation in ["store_get", "store_put"] do
            {:current_stacktrace, frames} = Process.info(self(), :current_stacktrace)

            callers =
              frames
              |> Enum.map(fn {mod, fun, arity, _} -> "#{inspect(mod)}.#{fun}/#{arity}" end)
              |> Enum.filter(&String.contains?(&1, "SalixAgent."))
              |> Enum.take(8)

            send(test_pid, {:store_get, self(), operation, callers})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    # One input answered over two rounds: a tool round, then its continuation.
    FunLLM.script([
      fn _messages, _tools ->
        {:assistant, "checking",
         [
           %{
             id: "t1",
             name: "call",
             args: %{"tool" => "help", "params" => %{"tool" => "fs.read_file"}}
           }
         ]}
      end,
      fn _messages, _tools -> {:final, "answered"} end
    ])

    assert {:ok, :created} =
             SalixAgent.deliver(
               agent,
               %{
                 content: "count the reads",
                 role: "user",
                 session_id: session_id,
                 created_at: System.system_time(:second)
               },
               source_message_id: "read-count-1"
             )

    assert_receive {:run_observation, %{status: "completed"}}, 10_000
    :ok = SalixAgent.TestSupport.await_session_quiet(agent, session_id)

    [{actor, _}] =
      Registry.lookup(SalixAgent.Registry, SalixAgent.InternalSessionActor.key(agent, session_id))

    # Only the session snapshot fetches count; the actor also fetches the
    # agent's control record from the same store.
    store_calls = collect_store_gets([])

    session_reads =
      store_calls
      |> Enum.filter(fn {pid, operation, callers} ->
        pid == actor and operation == "store_get" and
          Enum.any?(callers, &String.contains?(&1, "InternalSessionStore.traced_read_for_update"))
      end)
      |> Enum.map(fn {_pid, _operation, callers} -> Enum.join(callers, " <- ") end)

    session_writes =
      store_calls
      |> Enum.filter(fn {pid, operation, callers} ->
        pid == actor and operation == "store_put" and
          Enum.any?(callers, &String.contains?(&1, "InternalSessionStore.write_state"))
      end)
      |> Enum.map(fn {_pid, _operation, callers} ->
        callers
        |> Enum.reject(&String.contains?(&1, "RoundRuntimeTest"))
        |> Enum.drop_while(&String.contains?(&1, "InternalSessionStore."))
        |> List.first()
      end)

    # Every write is a whole snapshot, so each round writes as few as the
    # protocol needs: one combined activation CAS (materialization,
    # visible-reply installation, prompt snapshot, active status), the
    # assistant turn (durable before its tools run), the tool results, and
    # the background tool's terminal; the final round is its activation and
    # the settling assistant turn. Plus the delivery's admission: seven.
    assert length(session_writes) <= 7,
           "the owner wrote the session #{length(session_writes)} times:\n" <>
             Enum.join(session_writes, "\n")

    # The owner is the only writer of its session, so the revision it holds
    # is the session: the delivery's admission, the wake that activates the
    # first round, that round's provider completion, the async tool terminal
    # that continues into the second round, and its provider completion all
    # run on the resident revision. The one fetch is the actor's first, on
    # the delivery that started it. Before the owner kept its revision, the
    # same input cost more than twenty.
    assert length(session_reads) <= 1,
           "the owner fetched the session #{length(session_reads)} times:\n" <>
             Enum.join(session_reads, "\n")
  end

  defp collect_store_gets(acc) do
    receive do
      {:store_get, pid, operation, callers} ->
        collect_store_gets([{pid, operation, callers} | acc])
    after
      0 -> acc
    end
  end

  test "assistant prose without tool calls remains unacknowledged and continues",
       %{
         context: context
       } do
    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")

    FunLLM.script([
      fn _messages, _tools ->
        {:assistant, "kept", []}
      end
    ])

    assert {:ok, _context, :round_boundary} =
             Round.run(context, "ses1_0000000000000000902")

    session = read_session!(context.agent_id, "ses1_0000000000000000902")

    assert SalixAgent.InternalSession.get(session, :last_ack_message_id) == 1
    assert List.last(SalixAgent.InternalSession.get(session, :messages)).content == "kept"

    assert List.last(SalixAgent.InternalSession.get(session, :messages)).id >
             SalixAgent.InternalSession.get(session, :last_ack_message_id)
  end

  test "context overflow compacts old history once and retries without acknowledging fresh input",
       %{context: context} do
    sid = context.session_id
    ack_setup_input!(context.agent_id, sid)

    {:ok, _} =
      InternalSessionStore.prepare_commit(context.agent_id, sid, [
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => 2,
          "content" => "fresh protected request"
        }
      ])

    previous = Application.get_env(:salix_agent, :summarizer)
    on_exit(fn -> Application.put_env(:salix_agent, :summarizer, previous) end)
    test_pid = self()

    Application.put_env(:salix_agent, :summarizer, fn _summary, messages ->
      send(test_pid, {:overflow_summary, Enum.map(messages, & &1.id)})
      "settled old history"
    end)

    FunLLM.script([
      fn _messages, _tools ->
        SalixAgent.LLM.Error.context_overflow("mock", "context_length_exceeded")
      end,
      fn messages, _tools ->
        session = read_session!(context.agent_id, sid)
        assert SalixAgent.InternalSession.get(session, :last_ack_message_id) == 1
        assert inspect(messages) =~ "fresh protected request"
        send(test_pid, :overflow_retried)
        {:final, "recovered"}
      end
    ])

    assert :ok = SalixAgent.InternalSessionFleet.wake(context.agent_id, sid)
    assert_receive {:overflow_summary, [1]}, 5_000
    assert_receive :overflow_retried, 5_000
    assert eventually(fn -> assistant_message?(context.agent_id, sid) end)
    refute_receive {:overflow_summary, _}, 50
    session = read_session!(context.agent_id, sid)
    assert SalixAgent.InternalSession.compacted_through(session) == 1

    assert SalixAgent.InternalSession.get(session, :context_overflow_recovery)["transcript_hwm"] ==
             2
  end

  test "oversized fresh input without compactable history terminates without a second provider call",
       %{context: context} do
    test_pid = self()

    FunLLM.script([
      fn _messages, _tools ->
        SalixAgent.LLM.Error.context_overflow("mock", "context_length_exceeded")
      end,
      fn _messages, _tools ->
        send(test_pid, :unexpected_overflow_retry)
        {:final, "unexpected"}
      end
    ])

    assert :ok = SalixAgent.InternalSessionFleet.wake(context.agent_id, context.session_id)

    assert eventually(fn ->
             session = read_session!(context.agent_id, context.session_id)
             SalixAgent.InternalSession.llm_failure_terminal?(session)
           end)

    refute_receive :unexpected_overflow_retry, 100
    session = read_session!(context.agent_id, context.session_id)
    assert SalixAgent.InternalSession.get(session, :summary_sequence) == 0
  end

  test "repeated overflow settles after one compaction and two provider calls", %{
    context: context
  } do
    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")

    test_pid = self()
    previous = Application.get_env(:salix_agent, :summarizer)
    on_exit(fn -> Application.put_env(:salix_agent, :summarizer, previous) end)

    Application.put_env(:salix_agent, :summarizer, fn _summary, _messages ->
      send(test_pid, :bounded_overflow_summary)
      "settled history"
    end)

    FunLLM.script(
      Enum.map(1..3, fn attempt ->
        fn _messages, _tools ->
          send(test_pid, {:bounded_overflow_attempt, attempt})
          SalixAgent.LLM.Error.context_overflow("mock", "context_length_exceeded")
        end
      end)
    )

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")

    assert_receive {:run_observation,
                    %{
                      status: "llm_failed",
                      session_id: "ses1_0000000000000000902",
                      round_id: round_id,
                      duration_ms: duration_ms,
                      started_at: %DateTime{},
                      platform: "raft",
                      task_origin: "trajectory:case_1",
                      source_schedule_id: "schedule_1"
                    }},
                   1_000

    assert is_binary(round_id)
    assert duration_ms >= 0
    assert_receive {:bounded_overflow_attempt, 1}
    assert_receive :bounded_overflow_summary
    assert_receive {:bounded_overflow_attempt, 2}
    refute_receive {:bounded_overflow_attempt, 3}, 100
    refute_receive :bounded_overflow_summary, 100
  end

  @tag :session_optimization
  test "a canonical replayable read executes while its assistant intent is persisting", %{
    agent: agent,
    context: context
  } do
    session_id = context.session_id
    ack_setup_input!(agent, session_id)
    session_key = Keys.agent_internal_runtime_session(agent, session_id)
    workspace_key = Keys.agent_workspace_state(agent)
    owner = self()

    FunLLM.script([
      fn _, _ ->
        :ok = S3.Fake.reset_read_log()
        :ok = S3.Fake.set_fault({:pause, :put, session_key})
        send(owner, :intent_prepared)

        {:assistant, "inspect files",
         [
           %{
             id: "speculative-list",
             name: "call",
             args: %{"tool" => "fs.list_files", "params" => %{}}
           }
         ]}
      end
    ])

    on_exit(fn -> if Process.whereis(S3.Fake), do: S3.Fake.release_pause() end)

    round =
      Task.async(fn ->
        SalixAgent.InternalSessionFleet.run_round(agent, session_id, context,
          __round_run_delegate__: true
        )
      end)

    assert_receive :intent_prepared, 3_000
    assert eventually(fn -> {:get, workspace_key} in S3.Fake.read_log() end)
    assert S3.Fake.paused?()
    assert Task.yield(round, 20) == nil
    refute assistant_message?(agent, session_id)
    refute_receive {:tool_observation, %{source_key: "speculative-list"}}, 20

    :ok = S3.Fake.release_pause()
    assert {:ok, _, {:async_tools_started, _}} = Task.await(round, 5_000)

    assert_receive {:tool_observation, %{source_key: "speculative-list", status: "completed"}},
                   5_000

    assert assistant_message?(agent, session_id)
  end

  @tag :session_optimization
  test "a completed speculative read cannot publish after its intent commit fails", %{
    agent: agent,
    context: context
  } do
    session_id = context.session_id
    ack_setup_input!(agent, session_id)
    session_key = Keys.agent_internal_runtime_session(agent, session_id)
    workspace_key = Keys.agent_workspace_state(agent)

    FunLLM.script([
      fn _, _ ->
        :ok = S3.Fake.reset_read_log()
        :ok = S3.Fake.blackhole({:fail, 503, :put, session_key})

        {:assistant, "inspect files",
         [
           %{
             id: "discarded-read",
             name: "call",
             args: %{"tool" => "fs.list_files", "params" => %{}}
           }
         ]}
      end
    ])

    on_exit(fn -> if Process.whereis(S3.Fake), do: S3.Fake.clear_blackhole() end)

    assert {:error, _} =
             SalixAgent.InternalSessionFleet.run_round(agent, session_id, context,
               __round_run_delegate__: true
             )

    assert {:get, workspace_key} in S3.Fake.read_log()
    refute assistant_message?(agent, session_id)
    refute_receive {:tool_observation, %{source_key: "discarded-read"}}, 50
    session = read_session!(agent, session_id)

    refute Map.has_key?(
             SalixAgent.InternalSession.get(session, :async_tool_calls),
             "discarded-read"
           )
  end

  @tag :session_optimization
  test "a mixed read and HTTP GET batch waits for durable intent", %{
    agent: agent,
    context: context
  } do
    session_id = context.session_id
    ack_setup_input!(agent, session_id)
    session_key = Keys.agent_internal_runtime_session(agent, session_id)
    workspace_key = Keys.agent_workspace_state(agent)

    FunLLM.script([
      fn _, _ ->
        :ok = S3.Fake.reset_read_log()
        :ok = S3.Fake.blackhole({:fail, 503, :put, session_key})

        {:assistant, "read both sources",
         [
           %{id: "mixed-read", name: "call", args: %{"tool" => "fs.list_files", "params" => %{}}},
           %{
             id: "mixed-http",
             name: "call",
             args: %{
               "tool" => "web.http_request",
               "params" => %{"url" => "https://example.com", "method" => "GET"}
             }
           }
         ]}
      end
    ])

    on_exit(fn -> if Process.whereis(S3.Fake), do: S3.Fake.clear_blackhole() end)

    assert {:error, _} =
             SalixAgent.InternalSessionFleet.run_round(agent, session_id, context,
               __round_run_delegate__: true
             )

    refute {:get, workspace_key} in S3.Fake.read_log()
    refute assistant_message?(agent, session_id)
    refute_receive {:tool_observation, %{source_key: "mixed-read"}}, 50
    refute_receive {:tool_observation, %{source_key: "mixed-http"}}, 50
  end

  @tag :session_optimization
  test "a failed assistant intent commit does not start its tool and recovery can dispatch it", %{
    agent: agent,
    context: context
  } do
    session_id = context.session_id
    ack_setup_input!(agent, session_id)
    session_key = Keys.agent_internal_runtime_session(agent, session_id)
    tool_call_id = "intent-commit-fence"

    response = fn ->
      {:assistant, "write the requested file",
       [
         %{
           id: tool_call_id,
           name: "call",
           args: %{
             "tool" => "fs.write_file",
             "params" => %{"path" => "/intent-test.txt", "content" => "saved"}
           }
         }
       ]}
    end

    FunLLM.script([
      fn _messages, _tools ->
        # Fail only after the provider has produced a real tool request. An
        # earlier activation failure would not exercise the dispatch bracket.
        :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :put, session_key})
        response.()
      end
    ])

    assert {:error, _reason} =
             SalixAgent.InternalSessionFleet.run_round(agent, session_id, context,
               __round_run_delegate__: true
             )

    refute assistant_message?(agent, session_id)

    refute Enum.any?(SalixAgent.ExecutionSurface.get(agent, session_id), fn record ->
             record["execution"]["id"] == tool_call_id
           end)

    refute_receive {:tool_observation, %{source_key: ^tool_call_id}}, 100

    # A positive control uses the same request and production dispatch seam.
    # The failed attempt must neither execute it nor permanently poison it.
    :ok = SalixStore.S3.Fake.clear_blackhole()
    FunLLM.script([fn _messages, _tools -> response.() end])

    # A failed response leaves activation repair work. A new user request must
    # pass through normal delivery and activation, not the direct-round guard.
    assert {:ok, _} =
             SalixAgent.deliver(
               agent,
               %{session_id: session_id, content: "Retry the file write."},
               source_message_id: "intent-commit-recovery:#{agent}"
             )

    assert_receive {:tool_observation, %{source_key: ^tool_call_id, status: "completed"}},
                   5_000

    assert assistant_message?(agent, session_id)

    assert eventually(fn ->
             Enum.any?(SalixAgent.ExecutionSurface.get(agent, session_id), fn record ->
               record["execution"]["id"] == tool_call_id
             end)
           end)
  end

  test "zero-wait tool observation emits one terminal fact with dual fingerprints", %{
    context: context,
    tenant_id: tenant_id,
    group_id: group_id
  } do
    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")

    FunLLM.script([
      fn _messages, _tools ->
        {:assistant, "using a tool",
         [
           %{
             id: "tool-obs-1",
             name: "call",
             args: %{"tool" => "help", "params" => %{"tool" => "fs.read_file"}}
           }
         ]}
      end
    ])

    assert {:ok, _context, outcome} =
             SalixAgent.InternalSessionFleet.run_round(
               context.agent_id,
               "ses1_0000000000000000902",
               context,
               __round_run_delegate__: true
             )

    # Zero-wait execution may find an already completed dependency. Its
    # inline observation is synchronous; only the pending branch is async.
    expected_async =
      case outcome do
        {:async_tools_started, [pending]} ->
          assert pending.tool_call_id == "tool-obs-1"
          true

        :round_boundary ->
          false
      end

    assert_receive {:tool_observation,
                    %{
                      source_key: "tool-obs-1",
                      tool_name: "help",
                      tool_source: "core",
                      status: "completed",
                      async: ^expected_async,
                      call_index: 0,
                      tenant_id: ^tenant_id,
                      group_id: ^group_id,
                      salix_agent_id: agent_id,
                      session_id: "ses1_0000000000000000902",
                      round_id: round_id,
                      args_fingerprint: args_fingerprint,
                      result_fingerprint: result_fingerprint
                    }},
                   1_000

    assert agent_id == context.agent_id
    assert is_binary(round_id)
    assert args_fingerprint =~ ~r/^[0-9a-f]{16}$/
    assert result_fingerprint =~ ~r/^[0-9a-f]{16}$/
    refute_receive {:tool_observation, _}, 100
  end

  test "zero-wait tool error emits one terminal error observation", %{context: context} do
    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")

    FunLLM.script([
      fn _messages, _tools ->
        {:assistant, "using a missing file",
         [
           %{
             id: "tool-error-1",
             name: "call",
             args: %{"tool" => "fs.stat_file", "params" => %{"path" => "/missing.txt"}}
           }
         ]}
      end,
      fn _messages, _tools -> {:assistant, "repair attempt one", []} end,
      fn _messages, _tools -> {:assistant, "repair attempt two", []} end
    ])

    assert {:ok, _context, outcome} =
             SalixAgent.InternalSessionFleet.run_round(
               context.agent_id,
               "ses1_0000000000000000902",
               context,
               __round_run_delegate__: true
             )

    # Match the observation mode to the same zero-wait fast/pending paths.
    expected_async =
      case outcome do
        {:async_tools_started, [pending]} ->
          assert pending.tool_call_id == "tool-error-1"
          true

        :round_boundary ->
          false
      end

    assert_receive {:tool_observation,
                    %{
                      source_key: "tool-error-1",
                      tool_name: "fs.stat_file",
                      status: "error",
                      error_type: error_type,
                      async: ^expected_async
                    }},
                   5_000

    assert error_type == "tool_error"
    refute_receive {:tool_observation, _}, 100
  end

  test "wait_for emits one committed terminal observation", %{context: context} do
    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")

    FunLLM.script([
      fn _messages, _tools ->
        {:assistant, "waiting",
         [
           %{
             id: "wait-for-telemetry-1",
             name: "wait_for",
             args: %{"reason" => "worker reply"}
           }
         ]}
      end
    ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")

    assert_receive {:tool_observation,
                    %{
                      source_key: "wait-for-telemetry-1",
                      tool_name: "wait_for",
                      status: "completed",
                      async: false,
                      call_index: 0
                    }},
                   1_000

    refute_receive {:tool_observation, _}, 100
  end

  test "async_running early tool result does not emit a non-terminal observation", %{
    context: context
  } do
    assert :ok =
             SalixAgent.ToolTelemetry.emit_tool_call(
               %{
                 id: "permission-async-1",
                 name: "permission.request",
                 status: "async_running",
                 input: %{"capability" => "host_access", "description" => "run command"},
                 output: %{"status" => "running"},
                 duration_ms: 10,
                 started_at: System.system_time(:millisecond)
               },
               %{agent_id: context.agent_id, session_id: "ses1_0000000000000000902", async: false}
             )

    refute_receive {:tool_observation, %{source_key: "permission-async-1"}}, 200
  end

  test "internal actor execute_tool returns before a blocked tool emits its terminal observation",
       %{
         agent: agent
       } do
    previous_env_dispatch = Application.get_env(:salix_agent, :env_dispatch)
    Application.put_env(:salix_agent, :env_dispatch, BlockingEnvDispatch)
    BlockingEnvDispatch.set_owner(self())

    on_exit(fn ->
      :persistent_term.erase({BlockingEnvDispatch, :owner})

      if previous_env_dispatch do
        Application.put_env(:salix_agent, :env_dispatch, previous_env_dispatch)
      else
        Application.delete_env(:salix_agent, :env_dispatch)
      end
    end)

    # A fast tool may finish before the zero-wait poll. Hold this dependency
    # until the actor returns so the test always exercises async completion.
    assert {:ok, result} =
             SalixAgent.InternalSessionFleet.execute_tool(
               agent,
               "ses1_0000000000000000902",
               "env.copy",
               %{
                 "src_device_id" => "device-test",
                 "src_environment" => "source",
                 "src_path" => "/source.txt",
                 "dst_device_id" => "device-test",
                 "dst_environment" => "target",
                 "dst_path" => "/target.txt"
               },
               timeout: 2_000
             )

    assert result.status == "async_running"
    refute Map.has_key?(result, :tool_observations)
    refute Map.has_key?(result, "tool_observations")
    assert_receive {:zero_wait_tool_started, tool_pid}, 2_000
    on_exit(fn -> send(tool_pid, :release_zero_wait_tool) end)
    tool_call_id = result.id
    refute_receive {:tool_observation, %{source_key: ^tool_call_id}}

    send(tool_pid, :release_zero_wait_tool)

    assert_receive {:tool_observation,
                    %{
                      source_key: ^tool_call_id,
                      tool_name: "env.copy",
                      status: "completed",
                      async: true,
                      session_id: "ses1_0000000000000000902",
                      salix_agent_id: ^agent
                    }},
                   2_000

    assert eventually(fn ->
             case SalixAgent.InternalAgentRuntime.get_async_tool_call(
                    agent,
                    "ses1_0000000000000000902",
                    result.id
                  ) do
               {:ok, %{"status" => "completed"}} -> true
               _other -> false
             end
           end)
  end

  test "surface async completion emits a terminal async tool observation", %{
    agent: agent
  } do
    started_at_ms = 1_735_000_000_123

    capability =
      SalixAgent.TestSupport.pending_capability_fields!(
        agent,
        "ses1_0000000000000000902",
        "surface-async-1"
      )

    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent, "ses1_0000000000000000902", [
        %{
          "type" => "async_tool_call_started",
          "session_id" => "ses1_0000000000000000902",
          "tool_call_id" => "surface-async-1",
          "tool_name" => "permission.request",
          "status" => "running",
          "completion_mode" => "external_callback",
          "capability_request_id" => capability["capability_request_id"],
          "capability_deadline_ms" => capability["capability_deadline_ms"],
          "started_at" => started_at_ms
        }
      ])

    content = Jason.encode!(%{"status" => "approved"})

    # Floor must be sampled BEFORE the completion call: duration_ms is derived
    # at emit time inside complete_async_tool_call, so any later sample would
    # exceed it whenever more than a millisecond elapses (CI is slower).
    completion_floor_ms = System.system_time(:millisecond) - started_at_ms

    assert {:ok, %{"status" => "completed", "tool_call_id" => "surface-async-1"}} =
             SalixAgent.complete_async_tool_call(
               agent,
               "ses1_0000000000000000902",
               "surface-async-1",
               %{
                 "content" => content,
                 "output" => content,
                 "status" => "completed",
                 "error" => false
               },
               %{"tool_name" => "permission.request"}
             )

    assert_receive {:tool_observation,
                    %{
                      source_key: "surface-async-1",
                      tool_name: "permission.request",
                      status: "completed",
                      async: true,
                      session_id: "ses1_0000000000000000902",
                      salix_agent_id: ^agent,
                      started_at: started_at,
                      duration_ms: duration_ms
                    }},
                   1_000

    assert DateTime.to_unix(started_at, :millisecond) == started_at_ms
    # Surface completion result carries no duration; it must be derived from
    # the recorded spawn time rather than coerced to 0.
    assert is_integer(duration_ms)

    # System time can slew backwards by a millisecond between the completion
    # process and this assertion. Keep the bound tight without treating that
    # wall-clock adjustment as a runtime regression.
    completion_ceiling_ms = System.system_time(:millisecond) - started_at_ms
    assert duration_ms >= completion_floor_ms - 5
    assert duration_ms <= completion_ceiling_ms + 5
  end

  @tag :spinfoam
  @tag skip:
         if(SalixAgent.SpinfoamFixture.available?(),
           do: false,
           else: "spinfoam binary unavailable"
         )
  test "script host calls emit their own tool observation after parent commit", %{
    context: context
  } do
    help_call = Jason.encode!(%{"tool" => "help", "args" => %{"tool" => "fs.read_file"}})

    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")

    FunLLM.script([
      fn _messages, _tools ->
        {:assistant, "using a script",
         [
           %{
             id: "js-parent-1",
             name: "call",
             args: %{
               "tool" => "script.run",
               "params" => %{
                 "source" =>
                   SalixAgent.SpinfoamFixture.script_call_program(help_call, pick: "name")
               }
             }
           }
         ]}
      end
    ])

    assert {:ok, _context, {:async_tools_started, [pending]}} =
             SalixAgent.InternalSessionFleet.run_round(
               context.agent_id,
               "ses1_0000000000000000902",
               context,
               __round_run_delegate__: true
             )

    assert pending.tool_call_id == "js-parent-1"

    observations = receive_tool_observations(2)

    assert Enum.any?(
             observations,
             &match?(
               %{
                 source_key: "js-parent-1",
                 tool_name: "script.run",
                 status: "completed"
               },
               &1
             )
           )

    assert Enum.any?(
             observations,
             &match?(
               %{
                 tool_name: "help",
                 status: "completed",
                 session_id: "ses1_0000000000000000902"
               },
               &1
             )
           )
  end

  @tag :spinfoam
  @tag skip:
         if(SalixAgent.SpinfoamFixture.available?(),
           do: false,
           else: "spinfoam binary unavailable"
         )
  test "async script.run completion flushes deferred host tool observations", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")
    help_call = Jason.encode!(%{"tool" => "help", "args" => %{"tool" => "fs.read_file"}})

    FunLLM.script([
      fn _messages, _tools ->
        {:assistant, "using a slow script",
         [
           %{
             id: "js-async-parent-1",
             name: "call",
             args: %{
               "tool" => "script.run",
               "params" => %{
                 "source" =>
                   SalixAgent.SpinfoamFixture.script_call_program(help_call,
                     pick: "name",
                     sleep_ms: 3300
                   )
               }
             }
           }
         ]}
      end
    ])

    assert {:ok, _context, {:async_tools_started, [pending]}} =
             SalixAgent.InternalSessionFleet.run_round(agent, "ses1_0000000000000000902", context,
               __round_run_delegate__: true
             )

    assert pending.tool_call_id == "js-async-parent-1"

    observations = receive_tool_observations(2)

    assert Enum.any?(
             observations,
             &match?(
               %{
                 source_key: "js-async-parent-1",
                 tool_name: "script.run",
                 status: "completed",
                 async: true
               },
               &1
             )
           )

    assert Enum.any?(
             observations,
             &match?(
               %{
                 tool_name: "help",
                 status: "completed",
                 session_id: "ses1_0000000000000000902"
               },
               &1
             )
           )
  end

  test "tool guidance observation includes closed guidance reason", %{context: context} do
    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")

    FunLLM.script([
      fn _messages, _tools ->
        {:assistant, "using a missing tool",
         [
           %{
             id: "tool-guidance-1",
             name: "call",
             args: %{"tool" => "missing.tool", "params" => %{}}
           }
         ]}
      end
    ])

    assert {:ok, _context, :round_boundary} =
             SalixAgent.InternalSessionFleet.run_round(
               context.agent_id,
               "ses1_0000000000000000902",
               context,
               __round_run_delegate__: true
             )

    assert_receive {:tool_observation,
                    %{
                      source_key: "tool-guidance-1",
                      status: "guidance",
                      guidance_reason: "not_callable",
                      app_revision: app_revision
                    }},
                   1_000

    assert is_binary(app_revision)
    assert app_revision != ""
  end

  test "tool observation tolerates unencodable fingerprint payloads", %{
    context: context,
    tenant_id: tenant_id,
    group_id: group_id
  } do
    assert :ok =
             SalixAgent.ToolTelemetry.emit_tool_call(
               %{
                 id: "tool-obs-weird",
                 name: "help",
                 status: "completed",
                 input: %{"pid" => self()},
                 output: {:tuple, self()},
                 duration_ms: 1,
                 started_at: System.system_time(:millisecond),
                 call_index: 1
               },
               %{
                 agent_id: context.agent_id,
                 session_id: "ses1_0000000000000000902",
                 tenant_id: tenant_id,
                 group_id: group_id,
                 async: false
               }
             )

    assert_receive {:tool_observation,
                    %{
                      source_key: "tool-obs-weird",
                      args_fingerprint: nil,
                      result_fingerprint: nil
                    }},
                   1_000
  end

  test "async tool crash repair can mark terminal tool error as crashed" do
    [result] =
      Round.tool_error_results(
        [%{"id" => "crashed-async-1", "name" => "env.exec", "args" => %{}}],
        :killed,
        "crashed"
      )

    assert result.error_class == "crashed"
    assert result.status == "error"
  end

  test "internal async tool DOWN emits crashed terminal observation", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")

    FunLLM.script([
      fn _messages, _tools ->
        {:assistant, "using a doomed script",
         [
           %{
             id: "js-crash-1",
             name: "call",
             args: %{
               "tool" => "script.run",
               "params" => %{"source" => SalixAgent.SpinfoamFixture.script_sleep_program(4500)}
             }
           }
         ]}
      end
    ])

    assert {:ok, _context, {:async_tools_started, [pending]}} =
             SalixAgent.InternalSessionFleet.run_round(agent, "ses1_0000000000000000902", context,
               __round_run_delegate__: true
             )

    Process.exit(pending.pid, :kill)

    assert_receive {:tool_observation,
                    %{
                      source_key: "js-crash-1",
                      tool_name: "script.run",
                      status: "error",
                      error_type: "crashed",
                      async: true,
                      duration_ms: duration_ms
                    }},
                   2_000

    # DOWN repair stamps duration_ms: 0; the row must derive real latency
    # from the pending spawn time instead of recording a 0ms crash.
    assert is_integer(duration_ms) and duration_ms > 0
  end

  test "direct run_round refuses to start a second LLM round while one is pending", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(agent, "ses1_0000000000000000902")

    test_pid = self()

    FunLLM.script([
      fn _messages, _tools ->
        send(test_pid, {:llm_blocked, self()})

        receive do
          :release_llm -> {:final, "first round finished"}
        end
      end
    ])

    assert {:ok, _context, {:llm_pending, _pending}} =
             SalixAgent.InternalSessionFleet.run_round(
               agent,
               "ses1_0000000000000000902",
               context,
               []
             )

    assert_receive {:llm_blocked, llm_pid}, 1_000

    assert {:error, :session_busy} =
             SalixAgent.InternalSessionFleet.run_round(
               agent,
               "ses1_0000000000000000902",
               context,
               []
             )

    send(llm_pid, :release_llm)

    assert eventually(fn ->
             Enum.any?(
               SalixAgent.InternalSession.get(
                 read_session!(agent, "ses1_0000000000000000902"),
                 :messages
               ),
               &(&1[:content] == "first round finished")
             )
           end)
  end

  for {label, session_id, events} <- [
        {"the pending input queue", "ses1_0000000000000000904",
         [
           %{
             "type" => "queue_append",
             "kind" => "user_message",
             "dedupe_key" => "queued-input",
             "payload" => %{"source_message_id" => "queued-input", "content" => "queued"}
           }
         ]},
        {"no_wake pending queue context", "ses1_0000000000000000905",
         [
           %{
             "type" => "queue_append",
             "kind" => "user_message",
             "wake" => false,
             "dedupe_key" => "queued-no-wake-context",
             "payload" => %{
               "source_message_id" => "queued-no-wake-context",
               "content" => "context only"
             }
           }
         ]},
        {"transcript continuation", "ses1_0000000000000000906",
         [
           %{
             "type" => "tool_result",
             "message_id" => 1,
             "tool_call_id" => "tool-1",
             "content" => "done"
           },
           %{"type" => "ack", "last_ack_message_id" => 1}
         ]}
      ] do
    test "direct run_round refuses to bypass #{label}", %{agent: agent} do
      session_id = unquote(session_id)

      events =
        Enum.map(
          [%{"type" => "session_created"} | unquote(Macro.escape(events))],
          &Map.put(&1, "session_id", session_id)
        )

      {:ok, _session} = InternalSessionStore.prepare_commit(agent, session_id, events)

      assert {:error, :activation_required} =
               SalixAgent.InternalSessionFleet.run_round(
                 agent,
                 session_id,
                 %{agent_id: agent, session_id: session_id},
                 []
               )
    end
  end

  test "direct run_round refuses to bypass already materialized stable input", %{
    agent: agent,
    context: context
  } do
    assert {:error, :activation_required} =
             SalixAgent.InternalSessionFleet.run_round(
               agent,
               "ses1_0000000000000000902",
               context,
               []
             )
  end

  test "financial refusal ends the input durably and does not retry after actor restart", %{
    agent: agent
  } do
    session_id = "ses1_0000000000000000902"
    Application.put_env(:salix_agent, :llm_metering_mod, DenyMetering)
    FunLLM.script([fn _messages, _tools -> flunk("a refused input reached the provider") end])

    assert :ok = SalixAgent.InternalSessionFleet.wake(agent, session_id)
    assert_receive {:meter_denied, %{entrypoint: "agent_round"}}, 2_000

    assert eventually(fn ->
             session = read_session!(agent, session_id)

             InternalSession.activity_status(session) == :failed and
               InternalSession.activity_issue(session) == "insufficient_credits" and
               not InternalSession.has_unprocessed_stable_work?(session)
           end)

    session = read_session!(agent, session_id)

    assert Enum.any?(
             InternalSession.get(session, :messages),
             &(&1[:content] == "do the long task")
           )

    refute_receive {:meter_after, _}, 20
    refute_receive {:meter_denied, _}, 100

    SalixAgent.TestSupport.stop_all_agents()
    assert :ok = SalixAgent.InternalSessionFleet.wake(agent, session_id)
    refute_receive {:meter_denied, _}, 200

    assert InternalSession.activity_issue(read_session!(agent, session_id)) ==
             "insufficient_credits"
  end

  test "no fresh session input keeps the response", %{agent: agent, context: context} do
    ack_setup_input!(agent, "ses1_0000000000000000902")

    FunLLM.script([
      fn _messages, _tools ->
        {:final, "kept"}
      end
    ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")

    assert Enum.any?(
             SalixAgent.InternalSession.get(
               read_session!(agent, "ses1_0000000000000000902"),
               :messages
             ),
             &(&1[:content] == "kept")
           )
  end

  test "Session transcript records provider execution time and preserves tool intervals", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(agent, "ses1_0000000000000000902")
    test_pid = self()

    FunLLM.script([
      fn _messages, _tools ->
        send(test_pid, {:provider_entered_at, System.system_time(:millisecond)})
        Process.sleep(20)
        {:final, "timed response"}
      end
    ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")
    assert_receive {:provider_entered_at, entered_at}

    message =
      Enum.find(
        SalixAgent.InternalSession.get(
          read_session!(agent, "ses1_0000000000000000902"),
          :messages
        ),
        &(&1[:content] == "timed response")
      )

    timing = message.execution_timing
    assert timing["started_at_ms"] <= entered_at
    assert timing["duration_ms"] >= 20
    assert timing["first_token_at_ms"] == nil
    assert timing["completed_at_ms"] == timing["started_at_ms"] + timing["duration_ms"]

    started = System.system_time(:millisecond) - 500

    pending = %{
      session_id: "ses1_0000000000000000902",
      trace_ctx: %{turn_id: "turn", round_id: "round", request_id: "request", trace_id: "trace"}
    }

    results =
      for {id, status} <- [{"timed-complete", "completed"}, {"timed-async", "async_running"}] do
        %{
          id: id,
          name: "memory.search",
          content: "result",
          error: false,
          status: status,
          started_at: started,
          duration_ms: 80,
          events: []
        }
      end

    assert {:ok, _} = Round.commit_tool_results(context, pending, results)

    messages =
      SalixAgent.InternalSession.get(read_session!(agent, "ses1_0000000000000000902"), :messages)

    complete = Enum.find(messages, &(&1[:tool_call_id] == "timed-complete"))
    running = Enum.find(messages, &(&1[:tool_call_id] == "timed-async"))
    assert complete.execution_timing["started_at_ms"] == started
    assert complete.execution_timing["completed_at_ms"] == started + 80
    assert running.execution_timing["observed_at_ms"] == started + 80
    assert running.execution_timing["completed_at_ms"] == nil
  end

  for delta <- [:text, :tool, :reasoning] do
    @timing_delta delta
    test "Session request TTFT records the first #{@timing_delta} delta", %{
      agent: agent,
      context: context
    } do
      ack_setup_input!(agent, "ses1_0000000000000000902")
      Application.put_env(:salix_agent, :llm, TimingLLM)
      Application.put_env(:salix_agent, :timing_test_delta, @timing_delta)
      on_exit(fn -> Application.delete_env(:salix_agent, :timing_test_delta) end)
      assert {:ok, _, :final} = Round.run(context, "ses1_0000000000000000902")
      assert_receive {:first_output_bounds, earliest, latest}

      message =
        Enum.find(
          SalixAgent.InternalSession.get(
            read_session!(agent, "ses1_0000000000000000902"),
            :messages
          ),
          &(&1[:content] == "timing complete")
        )

      timing = message.execution_timing
      # Epoch and monotonic clocks round independently to milliseconds at the anchor.
      assert timing["first_token_at_ms"] >= earliest - 1
      assert timing["first_token_at_ms"] <= latest + 1
      assert timing["first_token_at_ms"] > timing["started_at_ms"]
      assert timing["first_token_at_ms"] < timing["completed_at_ms"]
      [observation] = SalixAgent.ExecutionSurface.get(agent, "ses1_0000000000000000902")
      assert observation["execution"]["id"] == message.request_id
      assert observation["execution"]["live"] == false
      assert observation["execution"]["first_token_at_ms"] == timing["first_token_at_ms"]
      assert observation["execution"]["completed_at_ms"] == timing["completed_at_ms"]
    end
  end

  test "metering times the first token of a round that answers with only a tool call", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(agent, "ses1_0000000000000000902")
    Application.put_env(:salix_agent, :llm, ToolOnlyStreamLLM)

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")

    assert_receive {:meter_after, %{first_token_ms: first_token_ms}}, 2_000

    # Metering used to stamp this only on a text delta, so a round with no
    # prose measured nothing at all. `llm_call_events_v2.first_token_ms` stayed
    # NULL and the dashboard showed "—" for exactly the models that answer
    # with tool calls most often.
    assert is_integer(first_token_ms)
    assert first_token_ms >= 20
  end

  test "oversized tool result stores the complete source and exposes one budgeted capsule", %{
    agent: agent,
    context: context
  } do
    content = String.duplicate("linear-result-", 20_000)

    pending = %{
      session_id: "ses1_0000000000000000902",
      trace_ctx: %{turn_id: "turn", round_id: "round", request_id: "request", trace_id: "trace"}
    }

    result = %{
      id: "call-duplicate-output",
      name: "mcp.linear.list_issues",
      content: content,
      output: content,
      error: false,
      status: "completed",
      events: []
    }

    assert {:ok, _context} = Round.commit_tool_results(context, pending, [result])

    session = read_session!(agent, "ses1_0000000000000000902")

    tool_result =
      Enum.find(
        SalixAgent.InternalSession.get(session, :messages),
        &(&1[:tool_call_id] == "call-duplicate-output")
      )

    capsule = Jason.decode!(tool_result.content)
    result_ref = capsule["result_ref"]

    assert capsule["stored_result"] == true
    assert capsule["encoding"] == "json"
    assert capsule["tool_name"] == "mcp.linear.list_issues"
    assert capsule["get_result"]["tool"] == "tool_call.get_result"
    assert capsule["get_result"]["arguments"]["result_ref"] == result_ref
    assert SalixStore.Ids.valid_tool_result_ref?(result_ref)
    assert is_nil(tool_result[:output])

    assert {:ok, stored} =
             InternalSessionStore.fetch_tool_result(
               agent,
               "ses1_0000000000000000902",
               result_ref
             )

    assert Jason.decode!(stored["result_json"]) == content
    assert stored["result_bytes"] == byte_size(stored["result_json"])
    assert stored["result_chars"] == String.length(stored["result_json"])
    assert stored["result_sha256"] == capsule["sha256"]

    projected_tool_message =
      session
      |> SalixAgent.Compaction.context()
      |> Enum.find(fn message ->
        (message[:role] || message["role"]) == "tool" and
          (message[:tool_call_id] || message["tool_call_id"]) == "call-duplicate-output"
      end)

    assert byte_size(Jason.encode!(%{"tool_results" => [projected_tool_message]})) <= 120_000
  end

  test "oversized synchronous failure deduplicates model error text but stores the complete source",
       %{
         agent: agent,
         context: context
       } do
    content = String.duplicate("sync-failure-", 20_000)

    pending = %{
      session_id: "ses1_0000000000000000902",
      trace_ctx: %{
        turn_id: "failure-turn",
        round_id: "failure-round",
        request_id: "failure-request",
        trace_id: "failure-trace"
      }
    }

    result = %{
      id: "call-oversized-sync-failure",
      name: "demo.fail",
      content: content,
      output: content,
      error: true,
      error_class: "tool_error",
      error_message: content,
      status: "error",
      events: []
    }

    assert byte_size(content) > ToolResultProjection.model_envelope_max_bytes()
    assert {:ok, _context} = Round.commit_tool_results(context, pending, [result])

    session = read_session!(agent, "ses1_0000000000000000902")

    tool_result =
      Enum.find(SalixAgent.InternalSession.get(session, :messages), fn message ->
        message[:tool_call_id] == "call-oversized-sync-failure"
      end)

    capsule = Jason.decode!(tool_result.content)
    result_ref = capsule["result_ref"]

    assert capsule["stored_result"] == true
    assert capsule["tool_name"] == "demo.fail"
    assert tool_result.error_message == tool_result.content
    assert is_nil(tool_result[:output])

    assert {:ok, stored} =
             InternalSessionStore.fetch_tool_result(
               agent,
               "ses1_0000000000000000902",
               result_ref
             )

    assert stored["is_error"] == true
    assert stored["status"] == "error"
    assert Jason.decode!(stored["result_json"]) == content
    assert stored["result_bytes"] == byte_size(stored["result_json"])
    assert stored["result_chars"] == String.length(stored["result_json"])
    assert stored["result_sha256"] == capsule["sha256"]

    projected_tool_message =
      session
      |> SalixAgent.Compaction.context()
      |> Enum.find(fn message ->
        (message[:role] || message["role"]) == "tool" and
          (message[:tool_call_id] || message["tool_call_id"]) ==
            "call-oversized-sync-failure"
      end)

    final_envelope = %{"tool_results" => [projected_tool_message]}

    assert byte_size(Jason.encode!(final_envelope)) <=
             ToolResultProjection.model_envelope_max_bytes()
  end

  test "reader result page is shrunk inside the actual outer envelope without recursive spill", %{
    agent: agent,
    context: context
  } do
    result_ref = "trf1_0000000000000000001"

    result_json =
      Jason.encode!(%{
        "payload" => String.duplicate("quote:\" slash:\\ controls:\n\t multibyte:雪🚀 ", 25_000)
      })

    record = %{
      "kind" => "tool_result",
      "result_ref" => result_ref,
      "result_json" => result_json,
      "result_bytes" => byte_size(result_json),
      "result_chars" => String.length(result_json),
      "result_sha256" =>
        result_json |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower),
      "tool_name" => "composio.execute",
      "status" => "completed",
      "is_error" => false
    }

    initial_page = AsyncToolResults.result_page_envelope(record, 0, 120_000)
    initial_content = Jason.encode!(initial_page)

    pending = %{
      session_id: "ses1_0000000000000000902",
      trace_ctx: %{turn_id: "turn", round_id: "round", request_id: "request", trace_id: "trace"}
    }

    result = %{
      id: "reader-call",
      name: "tool_call.get_result",
      content: initial_content,
      output: initial_content,
      input: Jason.encode!(%{"result_ref" => result_ref, "offset" => 0}),
      error: false,
      status: "completed",
      events: []
    }

    assert byte_size(initial_content) > 118_000
    assert byte_size(initial_content) <= ToolResultProjection.model_envelope_max_bytes()
    assert {:ok, _context} = Round.commit_tool_results(context, pending, [result])

    session = read_session!(agent, "ses1_0000000000000000902")
    assert SalixAgent.InternalSession.get(session, :async_results) == []
    assert SalixAgent.InternalSession.get(session, :async_result_refs) == %{}

    projected_tool_message =
      session
      |> SalixAgent.Compaction.context()
      |> Enum.find(fn message ->
        (message[:role] || message["role"]) == "tool" and
          (message[:tool_call_id] || message["tool_call_id"]) == "reader-call"
      end)

    projected_content = projected_tool_message[:content] || projected_tool_message["content"]
    projected_page = Jason.decode!(projected_content)["result_page"]
    original_page = initial_page["result_page"]

    assert projected_page["result_ref"] == result_ref
    refute Map.has_key?(Jason.decode!(projected_content), "stored_result")
    assert projected_page["content_chars"] == String.length(projected_page["content"])
    assert projected_page["next_offset"] == projected_page["content_chars"]
    assert projected_page["content_chars"] < original_page["content_chars"]
    assert String.starts_with?(original_page["content"], projected_page["content"])

    final_outer = %{"tool_results" => [projected_tool_message]}

    assert byte_size(Jason.encode!(final_outer)) <=
             ToolResultProjection.model_envelope_max_bytes()

    unshrunk_tool_message = Map.put(projected_tool_message, :content, initial_content)
    unshrunk_outer = %{"tool_results" => [unshrunk_tool_message]}

    assert byte_size(Jason.encode!(unshrunk_outer)) >
             ToolResultProjection.model_envelope_max_bytes()
  end

  test "one assistant batch preserves every unread page for the same result ref", %{
    agent: agent,
    context: context
  } do
    session_id = "ses1_0000000000000000902"
    result_ref = "trf1_0000000000000000002"

    assert {:ok, _session} =
             InternalSessionStore.prepare_commit(agent, session_id, [
               %{
                 "type" => "assistant",
                 "session_id" => session_id,
                 "message_id" => 2,
                 "content" => "",
                 "tool_calls" => [
                   %{
                     "id" => "reader-page-0",
                     "name" => "tool_call.get_result",
                     "args" => %{"result_ref" => result_ref, "offset" => 0}
                   },
                   %{
                     "id" => "reader-page-100",
                     "name" => "tool_call.get_result",
                     "args" => %{"result_ref" => result_ref, "offset" => 100}
                   }
                 ]
               }
             ])

    page_result = fn tool_call_id, offset ->
      content =
        Jason.encode!(%{
          "status" => "completed",
          "result_page" => %{
            "encoding" => "json",
            "result_ref" => result_ref,
            "offset" => offset,
            "content" => String.duplicate("page-#{offset}-雪", 10),
            "content_chars" => 100,
            "total_chars" => 1_000,
            "total_bytes" => 1_200,
            "sha256" => String.duplicate("a", 64),
            "next_offset" => offset + 100,
            "truncated" => true
          }
        })

      %{
        id: tool_call_id,
        name: "tool_call.get_result",
        content: content,
        output: content,
        input: Jason.encode!(%{"result_ref" => result_ref, "offset" => offset}),
        error: false,
        status: "completed",
        events: []
      }
    end

    pending = %{
      session_id: session_id,
      trace_ctx: %{turn_id: "turn", round_id: "round", request_id: "request", trace_id: "trace"}
    }

    assert {:ok, _context} =
             Round.commit_tool_results(context, pending, [
               page_result.("reader-page-0", 0),
               page_result.("reader-page-100", 100)
             ])

    offsets =
      agent
      |> read_session!(session_id)
      |> SalixAgent.Compaction.context()
      |> Enum.filter(fn message ->
        (message[:role] || message["role"]) == "tool" and
          (message[:tool_name] || message["tool_name"]) == "tool_call.get_result"
      end)
      |> Enum.map(fn message ->
        message
        |> Map.get(:content, Map.get(message, "content"))
        |> Jason.decode!()
        |> get_in(["result_page", "offset"])
      end)

    assert offsets == [0, 100]
  end

  for {label, call_id, event} <- [
        {"delivery events", "call-delivery", %{"type" => "delivery", "content" => "pollution"}},
        {"queue append events", "call-queue-append",
         %{
           "type" => "queue_append",
           "kind" => "user_message",
           "dedupe_key" => "tool-pollution",
           "payload" => %{"content" => "pollution"}
         }},
        {"runtime messages", "call-runtime-message",
         %{
           "type" => "runtime_message",
           "runtime_message_id" => "tool-direct-runtime",
           "runtime_message_type" => "tool_call_completed",
           "summary" => "pollution"
         }}
      ] do
    test "tool side effects cannot bypass pending input queue with #{label}", %{
      agent: agent,
      context: context
    } do
      call_id = unquote(call_id)

      event =
        Map.put(unquote(Macro.escape(event)), "session_id", "ses1_0000000000000000902")

      pending = %{
        session_id: "ses1_0000000000000000902",
        trace_ctx: %{turn_id: "turn", round_id: "round", request_id: "request", trace_id: "trace"}
      }

      result = %{id: call_id, name: "bad_tool", content: "attempted bypass", events: [event]}

      assert {:error, {:invalid_tool_side_effect_event, event_type}} =
               Round.commit_tool_results(context, pending, [result])

      assert event_type == event["type"]

      session = read_session!(agent, "ses1_0000000000000000902")
      messages = SalixAgent.InternalSession.get(session, :messages)

      refute Enum.any?(messages, &(&1[:tool_call_id] == call_id))
      refute Enum.any?(messages, &(&1[:content] == "pollution"))
      refute Enum.any?(messages, &(&1[:runtime_message_id] == "tool-direct-runtime"))

      refute Enum.any?(SalixAgent.InternalSession.get(session, :input_queue), fn item ->
               (item["payload"] || %{})["content"] == "pollution"
             end)
    end
  end

  test "same-session input during an active round waits in the queue for the next activation", %{
    agent: _agent
  } do
    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    test_pid = self()

    FunLLM.script([
      fn messages, _tools ->
        send(test_pid, {:first_call, self(), messages})

        receive do
          :release_first -> :ok
        after
          2_000 -> raise "test did not release first LLM call"
        end

        {:final, "first answer"}
      end,
      fn messages, _tools ->
        send(test_pid, {:second_call, messages})
        {:final, "second answer"}
      end
    ])

    {:ok, _} =
      SalixAgent.deliver(agent, %{session_id: "ses1_0000000000000000902", content: "first"},
        create: true,
        source_message_id: "round-runtime-first:#{agent}"
      )

    assert_receive {:first_call, llm_pid, first_messages}, 1_000
    assert Enum.any?(first_messages, &(&1[:content] == "first"))
    refute Enum.any?(first_messages, &(&1[:content] == "second"))

    {:ok, _} =
      SalixAgent.deliver(agent, %{session_id: "ses1_0000000000000000902", content: "second"},
        source_message_id: "round-runtime-queued-second:#{agent}"
      )

    assert eventually(fn ->
             {:ok, session} =
               SalixAgent.InternalSessionStore.read(agent, "ses1_0000000000000000902")

             Enum.any?(SalixAgent.InternalSession.get(session, :input_queue), fn item ->
               get_in(item, ["payload", "content"]) == "second" and
                 item["queue_id"] > SalixAgent.InternalSession.get(session, :queue_ack_id)
             end) and
               not Enum.any?(
                 SalixAgent.InternalSession.get(session, :messages),
                 &(&1[:content] == "second")
               )
           end)

    send(llm_pid, :release_first)

    assert_receive {:second_call, second_messages}, 2_000
    assert Enum.any?(second_messages, &(&1[:content] == "first answer"))
    assert Enum.any?(second_messages, &(&1[:content] == "second"))

    assert eventually(fn ->
             contents =
               SalixAgent.InternalSession.get(
                 read_session!(agent, "ses1_0000000000000000902"),
                 :messages
               )
               |> Enum.map(& &1[:content])

             "first answer" in contents and "second answer" in contents
           end)
  end

  test "zero-wait tool completion returns through runtime input before the next LLM request", %{
    agent: _agent
  } do
    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    test_pid = self()
    previous_env_dispatch = Application.get_env(:salix_agent, :env_dispatch)
    Application.put_env(:salix_agent, :env_dispatch, BlockingEnvDispatch)
    BlockingEnvDispatch.set_owner(self())

    on_exit(fn ->
      :persistent_term.erase({BlockingEnvDispatch, :owner})

      if previous_env_dispatch do
        Application.put_env(:salix_agent, :env_dispatch, previous_env_dispatch)
      else
        Application.delete_env(:salix_agent, :env_dispatch)
      end
    end)

    FunLLM.script([
      fn messages, _tools ->
        send(test_pid, {:first_call, self(), messages})

        receive do
          :release_first -> :ok
        after
          2_000 -> raise "test did not release first LLM call"
        end

        {:assistant, "using a tool",
         [
           %{
             id: "copy-1",
             name: "call",
             args: %{
               "tool" => "env.copy",
               "params" => %{
                 "src_device_id" => "device-test",
                 "src_environment" => "source",
                 "src_path" => "/source.txt",
                 "dst_device_id" => "device-test",
                 "dst_environment" => "target",
                 "dst_path" => "/target.txt"
               }
             }
           }
         ]}
      end,
      fn messages, _tools ->
        send(test_pid, {:second_call, messages})
        {:final, "second answer"}
      end
    ])

    {:ok, _} =
      SalixAgent.deliver(agent, %{session_id: "ses1_0000000000000000902", content: "first"},
        create: true,
        source_message_id: "round-runtime-first:#{agent}"
      )

    assert_receive {:first_call, llm_pid, first_messages}, 1_000
    assert Enum.any?(first_messages, &(&1[:content] == "first"))

    send(llm_pid, :release_first)

    assert_receive {:zero_wait_tool_started, tool_pid}, 2_000

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "running"}},
               SalixAgent.InternalAgentRuntime.get_async_tool_call(
                 agent,
                 "ses1_0000000000000000902",
                 "copy-1"
               )
             )
           end)

    send(tool_pid, :release_zero_wait_tool)

    assert_receive {:second_call, second_messages}, 2_000
    assert Enum.any?(second_messages, &(&1[:role] == "tool" and &1[:tool_call_id] == "copy-1"))

    assert Enum.any?(second_messages, fn message ->
             message[:role] == "runtime" and
               message[:type] == "tool_call_completed" and
               message[:source_tool_call_id] == "copy-1"
           end)

    assert eventually(fn ->
             SalixAgent.InternalSession.get(
               read_session!(agent, "ses1_0000000000000000902"),
               :messages
             )
             |> Enum.any?(&(&1[:content] == "second answer"))
           end)

    session = read_session!(agent, "ses1_0000000000000000902")

    {context_messages, conversation_messages} =
      Enum.split_with(
        SalixAgent.InternalSession.get(session, :messages),
        &(&1[:content_kind] == "model_context")
      )

    assert length(context_messages) == 2
    assert Enum.all?(context_messages, &(&1[:role] == "runtime"))
    roles = Enum.map(conversation_messages, & &1[:role])
    assert roles == ["user", "assistant", "tool", "runtime", "assistant"]

    assert Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
             message[:role] == "runtime" and
               message[:type] == "tool_call_completed" and
               message[:source_tool_call_id] == "copy-1"
           end)

    assert List.last(SalixAgent.InternalSession.get(session, :messages)).content ==
             "second answer"
  end

  test "zero-wait result reader exposes one direct budgeted page in terminal context", %{
    agent: agent,
    context: context
  } do
    session_id = "ses1_0000000000000000902"
    result_ref = "trf1_0000000000000000006"
    requested_offset = 137
    requested_limit = ToolResultProjection.model_envelope_max_bytes()

    result_json =
      Jason.encode!(%{
        "payload" => String.duplicate("quote:\" slash:\\ controls:\n\t multibyte:雪🚀 ", 25_000)
      })

    result_sha256 =
      result_json
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    ack_setup_input!(agent, session_id)

    assert {:ok, seeded} =
             InternalSessionStore.prepare_commit(agent, session_id, [
               %{
                 "type" => "tool_result_stored",
                 "session_id" => session_id,
                 "result_ref" => result_ref,
                 "tool_call_id" => "large-source-call",
                 "tool_name" => "composio.execute",
                 "result_json" => result_json,
                 "result_sha256" => result_sha256,
                 "result_bytes" => byte_size(result_json),
                 "result_chars" => String.length(result_json),
                 "status" => "completed",
                 "is_error" => false,
                 "stored_at_ms" => 1
               }
             ])

    baseline_result_refs =
      Map.keys(SalixAgent.InternalSession.get(seeded, :async_result_refs)) |> MapSet.new()

    session_key = Keys.agent_internal_runtime_session(agent, session_id)

    # The production scheduler polls every admitted tool at zero wait. Make
    # this real store read deterministically slower than that poll without
    # replacing the dispatcher, reader, terminal commit, or context path.
    assert :ok = S3.Fake.blackhole({:delay, 25, :get, session_key})
    on_exit(&S3.Fake.clear_blackhole/0)

    test_pid = self()

    FunLLM.script([
      fn _messages, _tools ->
        {:assistant, "Reading the stored result",
         [
           %{
             id: "zero-wait-reader-page",
             name: "call",
             args: %{
               "tool" => "tool_call.get_result",
               "params" => %{
                 "result_ref" => result_ref,
                 "offset" => requested_offset,
                 "limit" => requested_limit
               }
             }
           }
         ]}
      end,
      fn messages, _tools ->
        send(test_pid, {:zero_wait_reader_context, messages})
        {:final, "reader page observed"}
      end
    ])

    assert {:ok, _context, {:async_tools_started, [pending]}} =
             SalixAgent.InternalSessionFleet.run_round(
               context.agent_id,
               session_id,
               context,
               __round_run_delegate__: true
             )

    assert pending.tool_call_id == "zero-wait-reader-page"
    assert pending.tool_name == "tool_call.get_result"

    assert_receive {:zero_wait_reader_context, messages}, 10_000

    runtime_message =
      Enum.find(messages, fn message ->
        message[:role] == "runtime" and
          message[:source_tool_call_id] == "zero-wait-reader-page"
      end)

    assert is_map(runtime_message)
    source_prefix = "[" <> SalixAgent.IFC.assistant_ref(runtime_message.id) <> "]\n"
    assert String.starts_with?(runtime_message.content, source_prefix)

    page_envelope =
      runtime_message.content |> String.replace_prefix(source_prefix, "") |> Jason.decode!()

    page = page_envelope["result_page"]

    assert is_map(page)
    assert page["result_ref"] == result_ref
    assert page["encoding"] == "json"
    assert page["offset"] == requested_offset
    assert page["content_chars"] == String.length(page["content"])

    assert page["content"] ==
             String.slice(result_json, requested_offset, page["content_chars"])

    assert page["total_chars"] == String.length(result_json)
    assert page["total_bytes"] == byte_size(result_json)
    assert page["sha256"] == result_sha256
    assert page["next_offset"] == requested_offset + page["content_chars"]
    assert page["truncated"] == true
    refute Map.has_key?(page_envelope, "stored_result")

    actual_model_envelope_bytes = byte_size(Jason.encode!([runtime_message]))

    assert actual_model_envelope_bytes <=
             ToolResultProjection.model_envelope_max_bytes()

    assert {:ok, stored_record} =
             InternalSessionStore.fetch_tool_result(agent, session_id, result_ref)

    unshrunk_page =
      stored_record
      |> AsyncToolResults.result_page_envelope(requested_offset, requested_limit)
      |> Map.fetch!("result_page")

    assert page["content_chars"] < unshrunk_page["content_chars"]

    replace_runtime_content = fn message, content ->
      content = source_prefix <> content

      if Map.has_key?(message, :content),
        do: Map.put(message, :content, content),
        else: Map.put(message, "content", content)
    end

    unshrunk_runtime_message =
      replace_runtime_content.(
        runtime_message,
        page_envelope
        |> Map.put("result_page", unshrunk_page)
        |> Jason.encode!()
      )

    assert byte_size(Jason.encode!([unshrunk_runtime_message])) >
             ToolResultProjection.model_envelope_max_bytes()

    grown_content_chars = page["content_chars"] + 1
    grown_next_offset = requested_offset + grown_content_chars

    grown_page =
      page
      |> Map.put("content", String.slice(unshrunk_page["content"], 0, grown_content_chars))
      |> Map.put("content_chars", grown_content_chars)
      |> Map.put("next_offset", grown_next_offset)
      |> Map.put("truncated", grown_next_offset < page["total_chars"])

    grown_runtime_message =
      replace_runtime_content.(
        runtime_message,
        page_envelope
        |> Map.put("result_page", grown_page)
        |> Jason.encode!()
      )

    assert byte_size(Jason.encode!([grown_runtime_message])) >
             ToolResultProjection.model_envelope_max_bytes()

    durable_session = read_session!(agent, session_id)

    durable_runtime_message =
      Enum.find(SalixAgent.InternalSession.get(durable_session, :messages), fn message ->
        message[:role] == "runtime" and
          message[:source_tool_call_id] == "zero-wait-reader-page"
      end)

    durable_page = Jason.decode!(durable_runtime_message.content)["result_page"]
    assert durable_page["result_ref"] == result_ref
    assert durable_page["content_chars"] == unshrunk_page["content_chars"]

    current_result_refs =
      Map.keys(SalixAgent.InternalSession.get(durable_session, :async_result_refs))
      |> MapSet.new()

    new_lookup_refs = MapSet.difference(current_result_refs, baseline_result_refs)

    # The normal async terminal owns its legacy tool_call_id lookup pointer.
    # Reader projection must not mint a second opaque stored-result ref.
    assert new_lookup_refs == MapSet.new(["zero-wait-reader-page"])
    refute Enum.any?(new_lookup_refs, &SalixStore.Ids.valid_tool_result_ref?/1)

    assert {:error, :not_found} =
             InternalSessionStore.fetch_tool_result(
               agent,
               session_id,
               "zero-wait-reader-page"
             )
  end

  test "activation drains no_wake context before running the wakeable input", %{agent: _agent} do
    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    test_pid = self()

    FunLLM.script([
      fn messages, _tools ->
        send(test_pid, {:llm_messages, Enum.map(messages, & &1[:content])})
        {:final, "done"}
      end
    ])

    context_events =
      Enum.map(1..101, fn index ->
        %{
          "type" => "queue_append",
          "session_id" => "ses1_0000000000000000902",
          "kind" => "user_message",
          "wake" => false,
          "dedupe_key" => "ctx-#{index}",
          "payload" => %{
            "source_message_id" => "ctx-#{index}",
            "content" => "context #{index}"
          }
        }
      end)

    wake_event = %{
      "type" => "queue_append",
      "session_id" => "ses1_0000000000000000902",
      "kind" => "user_message",
      "wake" => true,
      "dedupe_key" => "go",
      "payload" => %{"source_message_id" => "go", "content" => "go"}
    }

    assert {:ok, _queued} =
             InternalSessionStore.prepare_commit(
               agent,
               "ses1_0000000000000000902",
               [%{"type" => "session_created", "session_id" => "ses1_0000000000000000902"}] ++
                 context_events ++ [wake_event]
             )

    assert :ok = SalixAgent.InternalSessionFleet.wake(agent, "ses1_0000000000000000902")

    assert_receive {:llm_messages, contents}, 2_000
    assert "go" in contents
    assert Enum.count(contents, &String.starts_with?(&1, "context ")) == 101
  end

  test "a mid-round delivery to another session wakes that target session", %{agent: _agent} do
    # Full Server path: session a's round stages a delivery to session b. The
    # delivery carries its own explicit session target; session b must run via
    # that target wake, not by scanning every session of the agent.
    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)

    FunLLM.script([
      fn messages, _tools ->
        if Enum.any?(messages, &(&1[:content] == "hello a")) do
          # Session a's round: deliver to b while a is still running.
          {:ok, _} =
            SalixAgent.deliver(
              agent,
              %{session_id: "ses1_0000000000000000908", content: "hello b"},
              source_message_id: "round-runtime-cross-session-b:#{agent}"
            )

          {:final, "answer a"}
        else
          {:final, "answer b"}
        end
      end,
      fn _messages, _tools -> {:final, "answer b"} end
    ])

    {:ok, _} =
      SalixAgent.deliver(agent, %{session_id: "ses1_0000000000000000907", content: "hello a"},
        create: true,
        source_message_id: "round-runtime-cross-session-a:#{agent}"
      )

    assert eventually(fn ->
             assistant_message?(agent, "ses1_0000000000000000907") &&
               assistant_message?(agent, "ses1_0000000000000000908")
           end)
  end

  defp read_session!(agent_id, session_id) do
    {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, session_id)
    session
  end

  defp ack_setup_input!(agent_id, session_id) do
    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent_id, session_id, [
        %{"type" => "ack", "session_id" => session_id, "last_ack_message_id" => 1}
      ])
  end

  defp assistant_message?(agent_id, session_id) do
    case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} ->
        Enum.any?(SalixAgent.InternalSession.get(session, :messages), &(&1[:role] == "assistant"))

      _ ->
        false
    end
  end

  # Async script.run settlement crosses several actor hops, a workspace commit and a
  # session commit before any observation is emitted. Instrumenting the emitter
  # showed both facts DO arrive with `status="completed"` — they were simply
  # late, so this is a budget, not a dropped observation. 2s failed ~1 run in 3
  # and 8s still failed ~1 in 10 on an idle machine; a generous budget costs
  # nothing on the happy path and a genuinely stuck settlement still fails,
  # just later. ExUnit's own per-test timeout (60s) remains the real backstop.
  @tool_observation_timeout_ms 30_000

  defp receive_tool_observations(count, timeout_ms \\ @tool_observation_timeout_ms) do
    for _ <- 1..count do
      assert_receive {:tool_observation, fact}, timeout_ms
      fact
    end
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() ->
        true

      retries == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, retries - 1)
    end
  end
end
