Code.require_file("../../../native/verified_kernel/test/support/activation_fixture.exs", __DIR__)

defmodule SalixAgent.ActivationLatencyTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{
    InternalSession,
    InternalSessionActor,
    InternalSessionFleet,
    InternalSessionStore
  }

  alias SalixVerifiedKernel.Test.ActivationFixture, as: Fixture

  defmodule ImmediateLLM do
    def complete_stream(_messages, _tools, _on_delta) do
      {:assistant, "Synthetic response",
       [
         %{id: "synthetic-end", name: "end_turn", args: %{"outcome" => "done"}}
       ]}
    end
  end

  defmodule Observer do
    def round_phase(fact) do
      send(Application.fetch_env!(:salix_agent, :activation_latency_test_pid), {:phase, fact})
      :ok
    end

    def agent_run(_), do: :ok
    def tool_call(_), do: :ok
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    changes = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_agent, :llm, ImmediateLLM},
      {:salix_agent, :agent_observability_mod, Observer},
      {:salix_agent, :activation_latency_test_pid, self()},
      {:salix_agent, :ifc_facts_mod, nil}
    ]

    previous =
      Enum.map(changes, fn {app, key, value} ->
        old = Application.fetch_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end)

    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      Enum.each(previous, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)
    end)

    :ok
  end

  @tag :activation_latency
  @tag timeout: 120_000
  test "resident Router activation with 16 MB history stays within 500 ms without IFC or LLM latency" do
    agent_id = SalixAgent.TestSupport.new_agent_id()

    agent =
      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"},
        # Keep this reproduction on the no-compaction activation path.
        "context_tokens" => 100_000_000
      })

    {:ok, session_id} = SalixStore.RuntimeIds.persisted_router_session_id(agent)
    session = Fixture.build(agent_id, session_id)
    assert byte_size(InternalSession.persist(session)) >= 15_000_000
    assert :ok = InternalSessionStore.prepare_seed(agent_id, session)
    {:ok, _} = SalixAgent.Placement.ensure_started(agent_id, create: false)

    {:ok, actor} =
      InternalSessionFleet.ensure_started(agent_id, session_id, process_on_init: false)

    {:ok, config} = SalixAgent.AgentRuntimeConfig.resolve(agent_id)
    assert SalixAgent.IFC.mode_for(config.tenant_id, config.group_id) == :off

    assert {:ok, :committed} =
             InternalSessionActor.stage_delivery(actor, %{
               source_message_id: "synthetic-wake",
               payload: %{
                 role: "user",
                 content: "Answer this new input.",
                 delivered_at_ms: System.system_time(:millisecond)
               }
             })

    # Admission loaded the revision. Exclude fixture setup, cold load and
    # admission from the budget; measure the actual runtime phase emitted by
    # the owner, not a copied implementation of activation.
    assert %{revision: %InternalSessionStore.Revision{}} = :sys.get_state(actor)
    InternalSessionActor.wake(agent_id, session_id)
    assert_receive {:phase, %{phase: "activation", duration_ms: ms}}, 60_000
    IO.puts("resident Router activation: #{ms} ms")

    assert ms <= 500,
           "resident Router activation took #{ms} ms (budget 500 ms, IFC off, fake S3, immediate LLM)"
  end
end
