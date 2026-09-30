defmodule SalixWeb.AgentRuntimeConfigTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{AgentRuntimeConfig, LlmResolver}
  alias SalixStore.Agent

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    prev_store = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    Salix.App.configure()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_store)
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Runtime Config"})
    Process.put(:test_tenant_id, tenant["tenant_id"])

    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Runtime Config"}, tenant_id())

    template_id = "tmpl-runtime-config-#{System.unique_integer([:positive])}"

    {:ok, template} =
      SalixAgent.Templates.create(%{
        "template_id" => template_id,
        "name" => "Runtime Config",
        "model" => "template-model",
        "provider" => "openai",
        "provider_config" => %{
          "protocol" => "responses",
          "api_key_env" => "TEMPLATE_KEY"
        }
      })

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "group_id" => group["group_id"],
          "template_id" => template["template_id"],
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

  test "runtime llm config comes from the live template instead of stale state", %{agent: agent} do
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
    assert llm["model"] == "template-model"
    assert llm["protocol"] == "responses"
    assert llm["api_key_env"] == "TEMPLATE_KEY"
  end

  defp commit_state_events!(agent_id, events) do
    {:ok, owned} = Agent.claim(agent_id, "runtime-config-test", SalixAgent.State, steal: true)
    {:ok, owned} = Agent.commit(owned, events)
    :ok = Agent.release(owned)
  end
end
