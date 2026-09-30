defmodule SalixAgent.AgentConfigurationIsolationTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{AgentActor, AgentRoleActor, TestSupport}
  alias SalixStore.S3

  defmodule PluginGate do
    def runtime_projection(_attrs) do
      owner = :persistent_term.get(__MODULE__)
      send(owner, {:configuration_held, self()})

      receive do
        :release -> {:error, :test_unavailable}
      after
        10_000 -> {:error, :test_barrier_timeout}
      end
    end
  end

  setup do
    TestSupport.stop_all_agents()
    start_supervised!(S3.Fake)

    previous =
      for {app, key, value} <- [
            {:salix_store, :s3_backend, S3.Fake},
            {:salix_agent, :plugin_store_mod, PluginGate}
          ] do
        old = Application.fetch_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end

    :persistent_term.put(PluginGate, self())

    on_exit(fn ->
      TestSupport.stop_all_agents()
      :persistent_term.erase(PluginGate)

      for {app, key, old} <- previous do
        case old do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    :ok
  end

  for role <- ["router", "worker", "meeting"] do
    @tag config_isolation: true
    test "#{role} can stop its runtime while a configuration read waits for a dependency" do
      agent =
        TestSupport.create_control_agent!(TestSupport.new_agent_id(), %{"role" => unquote(role)})

      {:ok, actor} = AgentActor.ensure_started(agent)

      session_id =
        if unquote(role) == "router",
          do: agent["router_session_id"],
          else: "ses1_0000000000000000101"

      {:ok, _} = SalixAgent.InternalSessionStore.prepare_create(agent["agent_id"], session_id)

      {:ok, session_actor} =
        SalixAgent.InternalSessionFleet.ensure_started(agent["agent_id"], session_id,
          process_on_init: false
        )

      session_monitor = Process.monitor(session_actor)

      config =
        Task.async(fn ->
          safe_call(fn -> AgentActor.runtime_session_config_local(agent["agent_id"], %{}) end)
        end)

      assert_receive {:configuration_held, dependency}, 3_000
      assert Task.yield(config, 0) == nil

      stop =
        Task.async(fn ->
          safe_call(fn -> AgentRoleActor.stop_runtime(actor, :test, 5_000) end)
        end)

      try do
        assert {:ok, :ok} = Task.yield(stop, 500)
        assert_receive {:DOWN, ^session_monitor, :process, ^session_actor, _}, 500
      after
        send(dependency, :release)
        Task.await(config, 5_000)
        Task.shutdown(stop, :brutal_kill)
      end
    end
  end

  @tag config_isolation: true
  test "a timed-out delivery can cancel its staging task during a configuration read" do
    agent = TestSupport.create_control_agent!(TestSupport.new_agent_id(), %{"role" => "router"})
    {:ok, session_id} = SalixStore.RuntimeIds.persisted_router_session_id(agent)
    {:ok, _} = SalixAgent.InternalSessionStore.prepare_create(agent["agent_id"], session_id)
    {:ok, actor} = AgentActor.ensure_started(agent)
    key = SalixStore.Keys.agent_internal_runtime_session(agent["agent_id"], session_id)
    S3.Fake.set_fault({:pause, :get, key})

    owner = self()

    delivery =
      Task.async(fn ->
        result =
          AgentRoleActor.stage_delivery(
            actor,
            %{
              source_message_id: "config-isolation-input",
              payload: %{content: "pending"}
            },
            1_000
          )

        send(owner, {:delivery_result, result})
        # Keep the caller alive so caller-death cleanup cannot hide a blocked
        # cancel_stage_delivery handler in the role actor.
        receive do
          :caller_done -> :ok
        end
      end)

    await_pause(200)
    [{stage_owner, _}] = :sys.get_state(actor).stage_tasks |> Map.values()
    monitor = Process.monitor(stage_owner)

    config =
      Task.async(fn ->
        safe_call(fn ->
          AgentActor.runtime_session_config_local(agent["agent_id"], %{})
        end)
      end)

    assert_receive {:configuration_held, dependency}, 3_000

    try do
      assert_receive {:delivery_result, {:error, _}}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^stage_owner, _}, 500
      assert Task.yield(config, 0) == nil
    after
      send(dependency, :release)
      S3.Fake.release_pause()
      send(delivery.pid, :caller_done)
      Task.await(delivery, 5_000)
      Task.await(config, 5_000)
    end
  end

  defp await_pause(0), do: flunk("delivery did not reach the storage barrier")

  defp await_pause(attempts) do
    unless S3.Fake.paused?() do
      Process.sleep(5)
      await_pause(attempts - 1)
    end
  end

  defp safe_call(fun) do
    try do
      fun.()
    catch
      :exit, reason -> {:call_exit, reason}
    end
  end
end
