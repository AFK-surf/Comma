defmodule SalixWeb.AgentRuntimeConfigTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{AgentRuntimeConfig, LlmResolver}
  alias SalixStore.Agent

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    prev_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    Salix.App.configure()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_store)
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Runtime Config"})
    Process.put(:test_tenant_id, tenant["tenant_id"])

    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Runtime Config"}, tenant_id())

    SalixAgent.TestSupport.configure_platform_tier!(
      "router",
      "https://runtime-config.example.test/v1",
      "platform-router-model"
    )

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "group_id" => group["group_id"],
          "name" => "Config Agent",
          "role" => "router",
          "system_prompt" => "control system",
          "router_system_prompt" => "control router"
        },
        tenant_id()
      )

    {:ok, agent: agent}
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  test "runtime role and prompts come from control record instead of stale state", %{
    agent: agent
  } do
    commit_state_events!(agent["agent_id"], [
      %{
        "type" => "agent_config",
        "role" => "worker",
        "system_prompt" => "stale worker prompt"
      }
    ])

    assert {:ok,
            %{
              role: "router",
              prompts: %{
                "system_prompt" => "control system",
                "router_system_prompt" => "control router"
              }
            }} = AgentRuntimeConfig.resolve(agent["agent_id"])
  end

  test "runtime llm config comes from the live platform model instead of stale state", %{
    agent: agent
  } do
    commit_state_events!(agent["agent_id"], [
      %{
        "type" => "llm_config",
        "llm" => %{
          "model" => "stale-state-model",
          "protocol" => "stale"
        }
      }
    ])

    assert {:ok, llm} = LlmResolver.resolve_runtime(agent["agent_id"])
    assert llm["model"] == "platform-router-model"
    assert llm["protocol"] == "chat_completions"
    assert llm["base_url"] == "https://runtime-config.example.test/v1"
  end

  defp commit_state_events!(agent_id, events) do
    {:ok, owned} = Agent.claim(agent_id, "runtime-config-test", SalixAgent.State, steal: true)
    {:ok, owned} = Agent.commit(owned, events)
    :ok = Agent.release(owned)
  end
end
