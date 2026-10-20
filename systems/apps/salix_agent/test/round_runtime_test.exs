defmodule SalixAgent.RoundRuntimeTest do
  require SystemsRuntime.Proc

  require SystemsClock

  @moduledoc """
  Round runtime boundary tests: Round requires a session runtime context, records
  LLM metering around provider calls, and leaves cross-session delivery routing
  to the session/agent actor boundary.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
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
        id:
          "round_runtime_end_turn_#{SystemsRuntime.Proc.unique_integer([:positive, :monotonic])}",
        name: "end_turn",
        args: %{"outcome" => "done"}
      }
    end
  end

  defmodule TimingLLM do
    def complete(_, _), do: raise("timing test expects streaming")

    def complete_stream(_messages, _tools, on_delta, opts) do
      opts = Map.new(opts)
      SystemsClock.sleep(20)
      before_delta = SystemsClock.system_time(:millisecond)

      case SystemsRuntime.fetch_env!(:salix_agent, :timing_test_delta) do
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

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :metering_test_pid),
        {:first_output_bounds, before_delta, SystemsClock.system_time(:millisecond)}
      )

      SystemsClock.sleep(20)
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
      SystemsClock.sleep(20)
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
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :metering_test_pid),
        {:meter_before, fact}
      )

      :ok
    end

    @impl true
    def after_llm_call(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :metering_test_pid),
        {:meter_after, fact}
      )

      :ok
    end
  end

  defmodule FreeRouterMetering do
    @behaviour SalixAgent.LLMMetering
    def before_llm_call(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :metering_test_pid),
        {:free_main_admission, fact}
      )

      {:ok, %{billing_exemption: "free_router_model"}}
    end

    def after_llm_call(fact), do: MeteringFake.after_llm_call(fact)
  end

  defmodule ObservabilityFake do
    @moduledoc false
    @behaviour SalixAgent.Observability

    @impl true
    def tool_call(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :metering_test_pid),
        {:tool_observation, fact}
      )

      :ok
    end

    @impl true
    def agent_run(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :metering_test_pid),
        {:run_observation, fact}
      )

      :ok
    end

    @impl true
    def round_phase(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :metering_test_pid),
        {:phase_observation, fact}
      )

      :ok
    end

    @impl true
    def llm_attempt(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :metering_test_pid),
        {:attempt_observation, fact}
      )

      :ok
    end
  end

  defmodule ResponsesResolver do
    @moduledoc false
    def resolve(_agent_id), do: {:ok, %{protocol: "responses"}}
  end

  defmodule TenantResolver do
    @moduledoc false
    def resolve(_agent_id),
      do:
        {:ok,
         %{protocol: "chat_completions", model: "gemini-2.5-pro", credential_scope: "tenant"}}
  end

  defmodule ProjectKnowledgeProvider do
    @moduledoc false

    def retrieve(agent_id, question, context) do
      test_pid = SystemsRuntime.fetch_env!(:salix_agent, :metering_test_pid)

      SystemsRuntime.Proc.send(
        test_pid,
        {:project_knowledge_retrieved, agent_id, question, context}
      )

      delay_ms = SystemsRuntime.get_env(:salix_agent, :project_knowledge_round_delay_ms, 0)

      # On the test's clock, as the sleep below and the provider timeout are.
      if delay_ms > 0 do
        SystemsClock.send_after(
          test_pid,
          {:project_knowledge_provider_delay_elapsed, context.session_id},
          delay_ms
        )
      end

      SystemsClock.sleep(delay_ms)

      :salix_agent
      |> SystemsRuntime.get_env(:project_knowledge_round_result, :none)
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

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)

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
      owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner})
      SystemsRuntime.Proc.send(owner, {:zero_wait_tool_started, SystemsRuntime.Proc.self()})

      SystemsClock.vreceive do
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
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :metering_test_pid),
        {:meter_denied, fact}
      )

      {:error,
       {:billing_unavailable,
        struct!(BillingCore.FeeControl.Decision, allowed?: false, reason: "insufficient_credits")}}
    end

    @impl true
    def after_llm_call(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :metering_test_pid),
        {:meter_after, fact}
      )

      :ok
    end
  end

  setup do
    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_metering = SystemsRuntime.get_env(:salix_agent, :llm_metering_mod)
    prev_observability = SystemsRuntime.get_env(:salix_agent, :agent_observability_mod)
    prev_metering_pid = SystemsRuntime.get_env(:salix_agent, :metering_test_pid)

    prev_knowledge_provider =
      SystemsRuntime.get_env(:salix_agent, :project_knowledge_provider_mod)

    prev_knowledge_result = SystemsRuntime.get_env(:salix_agent, :project_knowledge_round_result)
    prev_knowledge_delay = SystemsRuntime.get_env(:salix_agent, :project_knowledge_round_delay_ms)

    prev_knowledge_timeout =
      SystemsRuntime.get_env(:salix_agent, :project_knowledge_provider_timeout_ms)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(FunLLM)
    SystemsRuntime.put_env(:salix_agent, :llm, FunLLM)
    SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, MeteringFake)
    SystemsRuntime.put_env(:salix_agent, :agent_observability_mod, ObservabilityFake)
    SystemsRuntime.put_env(:salix_agent, :metering_test_pid, SystemsRuntime.Proc.self())

    SystemsRuntime.put_env(
      :salix_agent,
      :project_knowledge_provider_mod,
      ProjectKnowledgeProvider
    )

    SystemsRuntime.put_env(:salix_agent, :project_knowledge_round_result, :none)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)

      if prev_llm,
        do: SystemsRuntime.put_env(:salix_agent, :llm, prev_llm),
        else: SystemsRuntime.delete_env(:salix_agent, :llm)

      if prev_metering,
        do: SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, prev_metering),
        else: SystemsRuntime.delete_env(:salix_agent, :llm_metering_mod)

      if prev_observability,
        do: SystemsRuntime.put_env(:salix_agent, :agent_observability_mod, prev_observability),
        else: SystemsRuntime.delete_env(:salix_agent, :agent_observability_mod)

      if prev_metering_pid,
        do: SystemsRuntime.put_env(:salix_agent, :metering_test_pid, prev_metering_pid),
        else: SystemsRuntime.delete_env(:salix_agent, :metering_test_pid)

      if prev_knowledge_provider,
        do:
          SystemsRuntime.put_env(
            :salix_agent,
            :project_knowledge_provider_mod,
            prev_knowledge_provider
          ),
        else: SystemsRuntime.delete_env(:salix_agent, :project_knowledge_provider_mod)

      if prev_knowledge_result,
        do:
          SystemsRuntime.put_env(
            :salix_agent,
            :project_knowledge_round_result,
            prev_knowledge_result
          ),
        else: SystemsRuntime.delete_env(:salix_agent, :project_knowledge_round_result)

      if prev_knowledge_delay,
        do:
          SystemsRuntime.put_env(
            :salix_agent,
            :project_knowledge_round_delay_ms,
            prev_knowledge_delay
          ),
        else: SystemsRuntime.delete_env(:salix_agent, :project_knowledge_round_delay_ms)

      if prev_knowledge_timeout,
        do:
          SystemsRuntime.put_env(
            :salix_agent,
            :project_knowledge_provider_timeout_ms,
            prev_knowledge_timeout
          ),
        else: SystemsRuntime.delete_env(:salix_agent, :project_knowledge_provider_timeout_ms)
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

  test "accepted human input receives only selected skill metadata through the Session owner", %{
    context: context,
    tenant_id: tenant,
    group_id: group
  } do
    alias SalixAgent.{DecideFixture, InternalSession, SkillStore}
    # Selection has a one-second budget on the Systems clock. Holding the clock
    # keeps a slow machine from spending it, so selection always finishes.
    DecideFixture.start_provider()
    DecideFixture.put_env(:decide_test_pid, SystemsRuntime.Proc.self())
    DecideFixture.put_env(:decide_selected_miniskill, "miniskill-runtime")
    DecideFixture.put_env(:plugin_store_mod, MiniskillPlugins)
    DecideFixture.put_env(:ifc_facts_mod, nil)
    ctx = %{agent_id: context.agent_id, tenant_id: tenant, group_id: group}

    body = String.duplicate("MINISKILL_RUNTIME_INSTRUCTION\n", 500)

    {:ok, event} =
      SkillStore.prepare_group_create(ctx, %{
        "skill_id" => "miniskill-runtime",
        "name" => "miniskill-runtime",
        "content" =>
          "---\nname: miniskill-runtime\ndescription: Diagnose build failures\nactivation: per-message\n---\n" <>
            body
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

    pid = SystemsRuntime.Proc.self()

    FunLLM.script([
      fn messages, _tools ->
        SystemsRuntime.Proc.send(pid, {:miniskill_agent_request, messages})
        {:final, "done"}
      end
    ])

    assert :ok = SalixAgent.InternalSessionFleet.wake(context.agent_id, context.session_id)
    settle_receive({:decision_request, _, _, decision})
    assert decision["state"]["message"]["text"] == "Fix the build"
    refute Jason.encode!(decision) =~ "MINISKILL_RUNTIME_INSTRUCTION"
    settle_receive({:miniskill_agent_request, messages})

    settle_receive(
      {:phase_observation,
       %{
         phase: "miniskill",
         duration_ms: miniskill_ms,
         round_id: miniskill_round,
         session_id: miniskill_session
       }}
    )

    assert miniskill_ms >= 0 and miniskill_ms <= 1_000
    assert is_binary(miniskill_round)
    assert miniskill_session == context.session_id

    assert Enum.any?(
             messages,
             &(is_binary(&1[:content]) and
                 String.contains?(&1[:content], "Diagnose build failures"))
           )

    refute Enum.any?(
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
               "skills" => [
                 %{
                   "skill_id" => "miniskill-runtime",
                   "name" => "miniskill-runtime",
                   "description" => "Diagnose build failures"
                 }
               ]
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
    SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, FreeRouterMetering)

    FunLLM.script([
      fn _messages, _tools ->
        # A policy change while the provider runs must not change this call.
        SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, MeteringFake)
        {:final, "done", %{"usage" => %{"prompt_tokens" => 10}}}
      end
    ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")
    settle_receive({:free_main_admission, %{model_purpose: :agent_main, salix_agent_id: ^agent}})

    settle_receive(
      {:meter_after, %{billing_exemption: "free_router_model", usage: %{"prompt_tokens" => 10}}}
    )
  end

  test "a resolved project fact reaches the LLM and is committed with its source evidence", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(agent, "ses1_0000000000000000902")

    SystemsRuntime.put_env(
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

    test_pid = SystemsRuntime.Proc.self()

    FunLLM.script([
      fn messages, _tools ->
        SystemsRuntime.Proc.send(test_pid, {:knowledge_llm_messages, messages})
        {:final, "Lin owns it."}
      end
    ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")

    settle_receive(
      {:project_knowledge_retrieved, ^agent, "do the long task",
       %{
         session_id: "ses1_0000000000000000902"
       }}
    )

    settle_receive({:knowledge_llm_messages, messages})

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
             Enum.find(S3.Fake.read_log(SystemsRuntime.Proc.self()), fn
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

    assert S3.Fake.read_log(SystemsRuntime.Proc.self()) == []

    assert use["session_id"] == "ses1_0000000000000000902"
    assert use["retrieval_id"] =~ "project-knowledge:"
    assert use["assistant_excerpt"] == "Lin owns it."
    assert get_in(use, ["assertions", Access.at(0), "id"]) == "assertion-atlas-owner"
  end

  test "metering records async provider exceptions before the task exits", %{context: context} do
    # Five provider retries back off 7.75s of clock time; settling runs them at once.
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

    settle_receive({:meter_before, %{entrypoint: "agent_round"}})
    settle_receive({:meter_after, %{status: "error", error: error}})
    assert error =~ "async provider down"

    assert is_reference(pending.ref)

    settle_receive(
      {:run_observation,
       %{
         status: "actor_failed",
         session_id: "ses1_0000000000000000902",
         round_id: round_id,
         duration_ms: duration_ms,
         started_at: %DateTime{},
         platform: "raft",
         task_origin: "trajectory:case_1",
         source_schedule_id: "schedule_1"
       }}
    )

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
    previous_resolver = SystemsRuntime.get_env(:salix_agent, :llm_resolver)
    SystemsRuntime.put_env(:salix_agent, :llm_resolver, ResponsesResolver)

    on_exit(fn ->
      if previous_resolver,
        do: SystemsRuntime.put_env(:salix_agent, :llm_resolver, previous_resolver),
        else: SystemsRuntime.delete_env(:salix_agent, :llm_resolver)
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

    test_pid = SystemsRuntime.Proc.self()

    FunLLM.script([
      fn messages, _tools ->
        SystemsRuntime.Proc.send(test_pid, {:round_attachment_request, Jason.encode!(messages)})
        {:final, "read the PDFs with my own tools"}
      end
    ])

    assert :ok = SalixAgent.InternalSessionFleet.wake(agent, "ses1_0000000000000000902")

    settle_receive({:round_attachment_request, request})

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
    settle_refute_receive({:round_attachment_request, _})
  end

  test "metering records attempts and first text token from the successful retry", %{
    context: context
  } do
    telemetry_handler = "round-logical-llm-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    parent = SystemsRuntime.Proc.self()

    :ok =
      SystemsRuntime.Telemetry.attach_many(
        telemetry_handler,
        [[:salix, :llm, :request, :stop], [:salix, :llm, :attempt, :stop]],
        fn event, measurements, metadata, _ ->
          SystemsRuntime.Proc.send(parent, {:platform_llm, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(telemetry_handler) end)
    ack_setup_input!(context.agent_id, "ses1_0000000000000000902")

    FunLLM.script([
      fn _messages, _tools, on_delta ->
        on_delta.("failed-attempt-delta")
        SalixAgent.LLM.Error.transport("mock", :timeout)
      end,
      fn _messages, _tools, on_delta ->
        SystemsClock.sleep(30)
        on_delta.("ok")
        {:final, "kept"}
      end
    ])

    assert {:ok, _context, :final} = Round.run(context, "ses1_0000000000000000902")

    settle_receive(
      {:meter_after,
       %{
         status: "ok",
         attempts: 2,
         response_kind: :assistant,
         first_token_ms: first_token_ms,
         duration_ms: duration_ms
       }}
    )

    assert first_token_ms >= 20
    # This should be measured from the successful retry attempt, not from the
    # original failed attempt plus retry backoff. Keep the upper bound below the
    # first retry delay while leaving scheduler headroom for loaded CI hosts.
    assert first_token_ms < 250
    assert first_token_ms < duration_ms

    settle_receive({:platform_llm, [:salix, :llm, :request, :stop], %{}, %{outcome: "ok"}})
    settle_refute_receive({:platform_llm, [:salix, :llm, :request, :stop], _, _})

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

    settle_receive(
      {:run_observation,
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
       }}
    )

    assert agent_id == context.agent_id
    assert is_binary(round_id)
    assert duration_ms >= 0
    assert is_binary(app_revision)
    assert app_revision != ""

    # Phase facts bracket the model call: `prepare` before the dispatch and
    # `finalize` after the final message commit, both on this round. A
    # direct Round.run has no actor activation, so no `activation` fact.
    settle_receive(
      {:phase_observation,
       %{
         phase: "prepare",
         round_id: ^round_id,
         session_id: "ses1_0000000000000000902",
         salix_agent_id: ^agent_id,
         started_at: %DateTime{},
         duration_ms: prepare_ms
       }}
    )

    settle_receive({:phase_observation, %{phase: "finalize", round_id: ^round_id}})
    assert prepare_ms >= 0
    refute_received {:phase_observation, %{phase: "activation"}}
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

    previous = SystemsRuntime.get_env(:salix_agent, :summarizer)
    on_exit(fn -> SystemsRuntime.put_env(:salix_agent, :summarizer, previous) end)
    test_pid = SystemsRuntime.Proc.self()

    SystemsRuntime.put_env(:salix_agent, :summarizer, fn _summary, messages ->
      SystemsRuntime.Proc.send(test_pid, {:overflow_summary, Enum.map(messages, & &1.id)})
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
        SystemsRuntime.Proc.send(test_pid, :overflow_retried)
        {:final, "recovered"}
      end
    ])

    assert :ok = SalixAgent.InternalSessionFleet.wake(context.agent_id, sid)
    settle_receive({:overflow_summary, [1]})
    settle_receive(:overflow_retried)
    assert eventually(fn -> assistant_message?(context.agent_id, sid) end)
    settle_refute_receive({:overflow_summary, _}, 50)
    session = read_session!(context.agent_id, sid)
    assert SalixAgent.InternalSession.compacted_through(session) == 1

    assert SalixAgent.InternalSession.get(session, :context_overflow_recovery)["transcript_hwm"] ==
             2
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

    settle_refute_receive({:tool_observation, %{source_key: ^tool_call_id}}, 100)

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

    settle_receive({:tool_observation, %{source_key: ^tool_call_id, status: "completed"}})

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

    settle_receive(
      {:tool_observation,
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
       }}
    )

    assert agent_id == context.agent_id
    assert is_binary(round_id)
    assert args_fingerprint =~ ~r/^[0-9a-f]{16}$/
    assert result_fingerprint =~ ~r/^[0-9a-f]{16}$/
    settle_refute_receive({:tool_observation, _}, 100)
  end

  @tag :spinfoam
  @tag skip:
         if(SalixAgent.SpinfoamFixture.available?(),
           do: false,
           else: "spinfoam binary unavailable"
         )
  @tag :spinfoam
  @tag skip:
         if(SalixAgent.SpinfoamFixture.available?(),
           do: false,
           else: "spinfoam binary unavailable"
         )

  test "direct run_round refuses to start a second LLM round while one is pending", %{
    agent: agent,
    context: context
  } do
    ack_setup_input!(agent, "ses1_0000000000000000902")

    test_pid = SystemsRuntime.Proc.self()

    FunLLM.script([
      fn _messages, _tools ->
        SystemsRuntime.Proc.send(test_pid, {:llm_blocked, SystemsRuntime.Proc.self()})

        SystemsRuntime.Proc.receive do
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

    settle_receive({:llm_blocked, llm_pid})

    assert {:error, :session_busy} =
             SalixAgent.InternalSessionFleet.run_round(
               agent,
               "ses1_0000000000000000902",
               context,
               []
             )

    SystemsRuntime.Proc.send(llm_pid, :release_llm)

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
  end

  test "financial refusal ends the input durably and does not retry after actor restart", %{
    agent: agent
  } do
    session_id = "ses1_0000000000000000902"
    SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, DenyMetering)
    FunLLM.script([fn _messages, _tools -> flunk("a refused input reached the provider") end])

    assert :ok = SalixAgent.InternalSessionFleet.wake(agent, session_id)
    settle_receive({:meter_denied, %{entrypoint: "agent_round"}})

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

    settle_refute_receive({:meter_after, _}, 20)
    settle_refute_receive({:meter_denied, _}, 100)

    SalixAgent.TestSupport.stop_all_agents()
    assert :ok = SalixAgent.InternalSessionFleet.wake(agent, session_id)
    settle_refute_receive({:meter_denied, _}, 200)

    assert InternalSession.activity_issue(read_session!(agent, session_id)) ==
             "insufficient_credits"
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
    test_pid = SystemsRuntime.Proc.self()

    FunLLM.script([
      fn messages, _tools ->
        SystemsRuntime.Proc.send(test_pid, {:first_call, SystemsRuntime.Proc.self(), messages})

        SystemsClock.vreceive do
          :release_first -> :ok
        after
          2_000 -> raise "test did not release first LLM call"
        end

        {:final, "first answer"}
      end,
      fn messages, _tools ->
        SystemsRuntime.Proc.send(test_pid, {:second_call, messages})
        {:final, "second answer"}
      end
    ])

    {:ok, _} =
      SalixAgent.deliver(agent, %{session_id: "ses1_0000000000000000902", content: "first"},
        create: true,
        source_message_id: "round-runtime-first:#{agent}"
      )

    settle_receive({:first_call, llm_pid, first_messages})
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

    SystemsRuntime.Proc.send(llm_pid, :release_first)

    settle_receive({:second_call, second_messages})
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
    test_pid = SystemsRuntime.Proc.self()
    previous_env_dispatch = SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, BlockingEnvDispatch)
    BlockingEnvDispatch.set_owner(SystemsRuntime.Proc.self())

    on_exit(fn ->
      SystemsRuntime.PersistentTerm.erase({BlockingEnvDispatch, :owner})

      if previous_env_dispatch do
        SystemsRuntime.put_env(:salix_agent, :env_dispatch, previous_env_dispatch)
      else
        SystemsRuntime.delete_env(:salix_agent, :env_dispatch)
      end
    end)

    FunLLM.script([
      fn messages, _tools ->
        SystemsRuntime.Proc.send(test_pid, {:first_call, SystemsRuntime.Proc.self(), messages})

        SystemsClock.vreceive do
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
        SystemsRuntime.Proc.send(test_pid, {:second_call, messages})
        {:final, "second answer"}
      end
    ])

    {:ok, _} =
      SalixAgent.deliver(agent, %{session_id: "ses1_0000000000000000902", content: "first"},
        create: true,
        source_message_id: "round-runtime-first:#{agent}"
      )

    settle_receive({:first_call, llm_pid, first_messages})
    assert Enum.any?(first_messages, &(&1[:content] == "first"))

    SystemsRuntime.Proc.send(llm_pid, :release_first)

    settle_receive({:zero_wait_tool_started, tool_pid})

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

    SystemsRuntime.Proc.send(tool_pid, :release_zero_wait_tool)

    settle_receive({:second_call, second_messages})
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

  test "activation drains no_wake context before running the wakeable input", %{agent: _agent} do
    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    test_pid = SystemsRuntime.Proc.self()

    FunLLM.script([
      fn messages, _tools ->
        SystemsRuntime.Proc.send(test_pid, {:llm_messages, Enum.map(messages, & &1[:content])})
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

    settle_receive({:llm_messages, contents})
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

  defp eventually(fun, _retries \\ nil), do: settle_until(fun)
end
