defmodule SalixAgent.AgentConfigurationIsolationTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  require SystemsClock

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{AgentActor, AgentRoleActor, TestSupport}
  alias SalixStore.S3

  defmodule PluginGate do
    def runtime_projection(_attrs) do
      owner = SystemsRuntime.PersistentTerm.get(__MODULE__)
      SystemsRuntime.Proc.send(owner, {:configuration_held, SystemsRuntime.Proc.self()})

      SystemsClock.vreceive do
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
        old = SystemsRuntime.fetch_env(app, key)
        SystemsRuntime.put_env(app, key, value)
        {app, key, old}
      end

    SystemsRuntime.PersistentTerm.put(PluginGate, SystemsRuntime.Proc.self())

    on_exit(fn ->
      TestSupport.stop_all_agents()
      SystemsRuntime.PersistentTerm.erase(PluginGate)

      for {app, key, old} <- previous do
        case old do
          {:ok, value} -> SystemsRuntime.put_env(app, key, value)
          :error -> SystemsRuntime.delete_env(app, key)
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

      session_monitor = SystemsRuntime.Proc.monitor(session_actor)

      config =
        SystemsRuntime.Task.async(fn ->
          safe_call(fn -> AgentActor.runtime_session_config_local(agent["agent_id"], %{}) end)
        end)

      settle_receive({:configuration_held, dependency})
      assert SystemsRuntime.Task.yield(config, 0) == nil

      stop =
        SystemsRuntime.Task.async(fn ->
          safe_call(fn -> AgentRoleActor.stop_runtime(actor, :test, 5_000) end)
        end)

      try do
        assert {:ok, :ok} = SystemsClock.yield(stop, 500)
        settle_receive({:DOWN, ^session_monitor, :process, ^session_actor, _})
      after
        SystemsRuntime.Proc.send(dependency, :release)
        settled_await(config)
        SystemsRuntime.Task.shutdown(stop, :brutal_kill)
      end
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
