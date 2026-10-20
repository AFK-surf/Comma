defmodule SalixAgent.RoleCoreTest do
  @moduledoc """
  Agent role/prompt config lives in the control record. Runtime state owns
  session execution facts such as `task_origin`, not agent identity.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixStore.Agent
  alias SalixAgent.AgentRuntimeConfig
  require SalixAgent.InternalSession

  alias SalixAgent.InternalSession
  alias SalixAgent.State
  alias SalixAgent.LLM.Mock

  @origin_session "ses1_0000000000000000301"
  @task_session "ses1_0000000000000000302"
  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_group_context = SystemsRuntime.get_env(:salix_agent, :group_context_mod)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)
      SystemsRuntime.put_env(:salix_agent, :llm, prev_llm)
      restore(:salix_agent, :group_context_mod, prev_group_context)
    end)

    {:ok, agent: SalixAgent.TestSupport.new_agent_id()}
  end

  test "role and prompts come from control record, not runtime state", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a, %{
      role: "router",
      system_prompt: "base prompt",
      router_system_prompt: "route, do not chat"
    })

    {:ok, state} = Agent.read_state(a, State)
    refute Map.has_key?(state, :role)
    refute Map.has_key?(state, :prompts)

    assert {:ok,
            %{
              role: "router",
              prompts: %{
                "system_prompt" => "base prompt",
                "router_system_prompt" => "route, do not chat"
              }
            }} = AgentRuntimeConfig.resolve(a)
  end

  # ---- task_origin stamping ----

  test "task delivery carries task_origin, durable across replay", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)
    Mock.script([{:final, "on it"}])
    origin = %{agent_id: "delegator-7", session_id: @origin_session}

    {:ok, :created} =
      SalixAgent.deliver(
        a,
        %{
          content: "please summarize the report",
          session_id: @task_session,
          task_origin: origin
        },
        source_message_id: "role-core-task-origin:#{a}"
      )

    assert eventually(fn ->
             match?(
               {:ok, session} when InternalSession.is_session(session),
               SalixAgent.InternalSessionStore.read(a, @task_session)
             )
           end)

    # The journal and state both persist string-keyed task origins.
    {:ok, sess} = SalixAgent.InternalSessionStore.read(a, @task_session)

    assert InternalSession.get(sess, :task_origin) == %{
             "agent_id" => "delegator-7",
             "session_id" => @origin_session
           }

    # A fresh agent claim does not own sessions; the session store carries it.
    {:ok, _state} = Agent.read_state(a, State)
    {:ok, replayed} = SalixAgent.InternalSessionStore.read(a, @task_session)

    assert InternalSession.get(replayed, :task_origin) == %{
             "agent_id" => "delegator-7",
             "session_id" => @origin_session
           }
  end

  # ---- pure reductions, no I/O ----

  # ---- helpers ----

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
