defmodule SalixAgent.TemplatePinChoicesTest do
  @moduledoc """
  Routers and Workers that still pin a template are given the model choice it
  stands for (`SalixAgent.Migrations.TemplatePinChoices`): the subscription
  pool's model as a catalog choice, an own endpoint as a Custom Profile of the
  Tenant (one per template), anything else the platform model of the role.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.Migrations.TemplatePinChoices
  alias SalixAgent.SubscriptionStore, as: Store
  alias SalixStore.{Ids, Keys, S3}

  setup do
    if SystemsRuntime.Proc.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)
    on_exit(fn -> SalixAgent.TestSupport.stop_all_agents() end)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    agent = SalixAgent.TestSupport.create_control_agent!(agent_id, %{role: "worker"})
    tenant = agent["tenant_id"]

    on_exit(fn ->
      Store.query("DELETE FROM subscription_accounts WHERE tenant_id=$1", [tenant])
    end)

    {:ok, agent: agent, tenant: tenant}
  end

  test "pinned templates become model choices; a second pass changes nothing", %{
    agent: global_agent,
    tenant: tenant
  } do
    pool =
      private_template!(tenant, "Pool", %{
        "account_pool" => "codex",
        "protocol" => "responses",
        "reasoning_effort" => "high"
      })

    own =
      private_template!(tenant, "Own endpoint", %{
        "base_url" => "https://llm.example.test/v1",
        "api_key" => "sk-own-0123456789",
        "protocol" => "chat_completions"
      })

    pin_template!(global_agent, global_template!())
    pool_agent = pin(global_agent, tenant, pool)
    own_agent = pin(global_agent, tenant, own)
    own_router = pin(global_agent, tenant, own, "router")

    assert {:ok, %{catalog: 1, profile: 2, platform: 1}} = TemplatePinChoices.run()

    assert stored(pool_agent)["model"] == %{
             "kind" => "catalog",
             "model" => "gpt-5.5",
             "reasoning_effort" => "high",
             "allow_paid" => false
           }

    # One Profile holds the endpoint for both Agents that pinned it; choosing
    # an API key is choosing to pay for it.
    assert %{
             "kind" => "catalog",
             "model" => "gpt-5.5",
             "profile_id" => profile,
             "allow_paid" => true
           } =
             stored(own_agent)["model"]

    assert stored(own_router)["model"]["profile_id"] == profile

    assert {:ok, %{rows: [[name, models, endpoints]]}} =
             Store.query(
               "SELECT value->>'name', value->'models', value->'endpoints' FROM subscription_accounts WHERE tenant_id=$1 AND id=$2",
               [tenant, profile]
             )

    assert {name, models} == {"Own endpoint", ["gpt-5.5"]}
    assert endpoints["chat_completions"] =~ "llm.example.test"

    # A global template follows the platform model of the role.
    assert stored(global_agent)["model"] == %{"kind" => "platform", "tier" => "worker"}

    # The template stays for processes of the previous release.
    assert stored(pool_agent)["template_id"] == pool

    assert {:ok, %{catalog: 0, profile: 0, platform: 0}} = TemplatePinChoices.run()

    assert {:ok, %{rows: [[1]]}} =
             Store.query(
               "SELECT count(*)::int FROM subscription_accounts WHERE tenant_id=$1 AND value->>'source'='custom'",
               [tenant]
             )
  end

  defp pin(agent, tenant, template_id, role \\ "worker") do
    pinned =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, agent["group_id"], %{
        "role" => role
      })

    pin_template!(pinned, template_id)
    pinned
  end

  # Records of an earlier release name the template they pin.
  defp pin_template!(agent, template_id) do
    key = Keys.ctl_agent(agent["agent_id"])
    {:ok, %{body: body}} = S3.get(key)
    record = body |> Jason.decode!() |> Map.put("template_id", template_id)
    {:ok, _} = S3.put(key, Jason.encode!(record))
  end

  # Template records as earlier releases stored them.
  defp private_template!(tenant, name, provider_config) do
    id = Ids.new_private_template_id()

    put_template!(Keys.ctl_private_template(tenant, id), %{
      "template_id" => id,
      "tenant_id" => tenant,
      "name" => name,
      "model" => "gpt-5.5",
      "provider_config" => provider_config
    })
  end

  defp global_template! do
    id = "global-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    put_template!(Keys.ctl_template(id), %{"template_id" => id, "name" => id, "model" => "mock"})
  end

  defp put_template!(key, template) do
    {:ok, _} = S3.put(key, Jason.encode!(template))
    template["template_id"]
  end

  defp stored(agent) do
    {:ok, %{body: body}} = S3.get(Keys.ctl_agent(agent["agent_id"]))
    Jason.decode!(body)
  end
end
