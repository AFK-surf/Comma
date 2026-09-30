defmodule SalixAgent.RoleCoreTest do
  @moduledoc """
  Agent role/prompt config lives in the control record. Runtime state owns
  session execution facts such as `task_origin`, not agent identity.
  """
  use ExUnit.Case, async: false

  alias SalixStore.Agent
  alias SalixAgent.AgentRuntimeConfig
  require SalixAgent.InternalSession

  alias SalixAgent.InternalSession
  alias SalixAgent.State
  alias SalixAgent.LLM.Mock

  @origin_session "ses1_0000000000000000301"
  @task_session "ses1_0000000000000000302"
  @worker_session_a "ses1_0000000000000000303"
  @worker_session_b "ses1_0000000000000000304"

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :llm, Mock)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_backend)
      Application.put_env(:salix_agent, :llm, prev_llm)
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

  test "runtime config fails closed when the agent control record is missing", %{agent: a} do
    assert {:error, :not_found} = AgentRuntimeConfig.resolve(a)
  end

  test "unknown control role is rejected before agent state exists", %{agent: a} do
    SalixAgent.TestSupport.configure_control_fixtures!()
    template_id = "tmpl-#{a}"
    group_id = SalixStore.Ids.group_id_from_agent!(a)
    tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)

    {:ok, _template} =
      SalixAgent.Templates.create(%{
        "template_id" => template_id,
        "name" => template_id,
        "model" => "mock"
      })

    assert {:error, {:bad_request, "invalid role"}} =
             SalixAgent.Control.create_preallocated(
               %{
                 "group_id" => group_id,
                 "template_id" => template_id,
                 "name" => a,
                 "role" => "manager"
               },
               tenant_id,
               a
             )

    assert {:error, :not_found} = Agent.read_state(a, State)
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

  test "worker actor routes neutral deliveries by session hint" do
    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)

    worker =
      SalixAgent.TestSupport.create_control_agent!(SalixStore.Ids.new_agent_id(group_id), %{
        role: "worker",
        name: "Worker",
        group_id: group_id,
        tenant_id: tenant_id
      })

    {:ok, :created} =
      SalixAgent.deliver(
        worker["agent_id"],
        %{content: "task a", session_id: @worker_session_a},
        source_message_id: "role-core-worker-a:#{worker["agent_id"]}"
      )

    {:ok, :created} =
      SalixAgent.deliver(
        worker["agent_id"],
        %{content: "task b", session_id: @worker_session_b},
        source_message_id: "role-core-worker-b:#{worker["agent_id"]}"
      )

    assert eventually(fn ->
             match?(
               {:ok, session} when InternalSession.is_session(session),
               SalixAgent.InternalSessionStore.read(worker["agent_id"], @worker_session_a)
             )
           end)

    assert eventually(fn ->
             match?(
               {:ok, session} when InternalSession.is_session(session),
               SalixAgent.InternalSessionStore.read(worker["agent_id"], @worker_session_b)
             )
           end)
  end

  # ---- pure reductions, no I/O ----

  test "session_created without optional metadata creates a clean session" do
    state =
      reduce([
        %{"type" => "session_created", "session_id" => "old"},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "old",
          "message_id" => 1,
          "source_message_id" => "s-1",
          "content" => "hi"
        }
      ])

    assert %State{agent_id: "a-pure"} = state

    sess =
      Enum.reduce(
        [
          %{"type" => "session_created", "session_id" => "old"},
          %{
            "type" => "delivery",
            "from_queue" => true,
            "session_id" => "old",
            "message_id" => 1,
            "source_message_id" => "s-1",
            "content" => "hi"
          }
        ],
        InternalSession.new("a-pure", "old"),
        &InternalSession.apply_event(&2, &1)
      )

    assert InternalSession.get(sess, :platform) == nil
    assert InternalSession.get(sess, :task_origin) == nil
    assert length(InternalSession.get(sess, :messages)) == 1
  end

  # ---- helpers ----

  defp reduce(events) do
    Enum.reduce(events, State.init("a-pure"), &State.apply_event(&2, &1))
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, retries - 1)
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
