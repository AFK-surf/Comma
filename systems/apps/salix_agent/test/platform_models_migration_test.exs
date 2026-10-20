defmodule SalixAgent.PlatformModelsMigrationTest do
  @moduledoc """
  The platform models migration: each role's platform default template
  becomes a platform Profile and its tier's internal model, the Router
  template's media becomes the media settings, and Agents pinned to a global
  template take the platform model of their role.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{AccountPool, MediaSettings, PlatformModels}
  alias SalixAgent.Migrations.PlatformModels, as: Migration
  alias SalixAgent.SubscriptionStore, as: Store
  alias SalixStore.{Keys, S3}

  setup do
    if SystemsRuntime.Proc.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)
    platform = AccountPool.platform_tenant()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Store.query("DELETE FROM subscription_accounts WHERE tenant_id=$1", [platform])
    end)

    :ok
  end

  # Records as earlier releases stored them: global templates, the platform
  # default pointers, and Agents that pin a template or hold a model choice.
  defp global_template(attrs) do
    id = "tmpl-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    template =
      Map.merge(%{"template_id" => id, "name" => "t-#{id}", "max_tokens" => 65_536}, attrs)

    {:ok, _} = S3.put(Keys.ctl_template(id), Jason.encode!(template))
    template
  end

  defp put_platform_defaults(defaults) do
    {:ok, _} = S3.put(Keys.ctl_system_agent_defaults(), Jason.encode!(defaults))
  end

  defp legacy_agent(role, fields) do
    agent_id = SalixAgent.TestSupport.new_agent_id()

    agent =
      Map.merge(
        %{
          "agent_id" => agent_id,
          "tenant_id" => SalixStore.Ids.tenant_id_from_agent!(agent_id),
          "group_id" => SalixStore.Ids.group_id_from_agent!(agent_id),
          "role" => role
        },
        fields
      )

    {:ok, _} = S3.put(Keys.ctl_agent(agent_id), Jason.encode!(agent))
    agent
  end

  defp stored(agent) do
    {:ok, %{body: body}} = S3.get(Keys.ctl_agent(agent["agent_id"]))
    Jason.decode!(body)
  end

  test "default templates become platform tiers and pinned Agents follow them" do
    image = %{
      "provider" => "openai",
      "model" => "gpt-image-2",
      "provider_config" => %{"base_url" => "https://images.example.test/v1"}
    }

    router_template =
      global_template(%{
        "model" => "gpt-6-sol",
        "provider" => "openai",
        "context_tokens" => 200_000,
        "supports_images" => true,
        "image_config" => image,
        "provider_config" => %{
          "base_url" => "https://gateway.example.test/v1/openai",
          "protocol" => "responses",
          "api_key" => "sk-gateway-0123456789",
          "reasoning_effort" => "high"
        }
      })

    # The same endpoint and key behind another model: one Profile serves both.
    worker_template =
      global_template(%{
        "model" => "gpt-6-luna",
        "provider" => "openai",
        "provider_config" => %{
          "base_url" => "https://gateway.example.test/v1/openai",
          "protocol" => "responses",
          "api_key" => "sk-gateway-0123456789"
        }
      })

    put_platform_defaults(%{
      "router_template_id" => router_template["template_id"],
      "worker_template_id" => worker_template["template_id"]
    })

    pinned_router =
      legacy_agent("router", %{"template_id" => worker_template["template_id"]})

    chosen_worker =
      legacy_agent("worker", %{
        "template_id" => worker_template["template_id"],
        "model" => %{"kind" => "catalog", "model" => "gpt-5.5"}
      })

    assert {:ok, %{tiers: tiers}} = Migration.run()
    assert Enum.sort(tiers) == ["router", "worker"]

    assert {:ok, %{"tiers" => %{"router" => router, "worker" => worker}}} = PlatformModels.get()

    assert %{
             "model" => "gpt-6-sol",
             "protocol" => "responses",
             "reasoning_effort" => "high",
             "context_tokens" => 200_000,
             "images" => true
           } = router

    assert worker["model"] == "gpt-6-luna"
    assert router["profile_id"] == worker["profile_id"]

    assert {:ok, %{"accounts" => [profile]}} = AccountPool.list(AccountPool.platform_tenant())
    assert profile["source"] == "custom"
    assert Enum.sort(profile["models"]) == ["gpt-6-luna", "gpt-6-sol"]

    # The tier serves with the template's key at its endpoint.
    assert {:ok, template} = PlatformModels.record("router")
    assert template["provider_config"]["api_key"] == "sk-gateway-0123456789"
    assert template["provider_config"]["base_url"] =~ "gateway.example.test"

    assert {:ok, %{"image_config" => ^image}} = MediaSettings.get()

    assert stored(pinned_router)["model"] == %{"kind" => "platform", "tier" => "router"}
    # The template stays for processes of the previous release.
    assert stored(pinned_router)["template_id"] == worker_template["template_id"]
    assert stored(chosen_worker)["model"]["kind"] == "catalog"

    # A second pass changes nothing and adds no Profile.
    assert {:ok, %{agents: 0}} = Migration.run()
    assert {:ok, %{"accounts" => [_one]}} = AccountPool.list(AccountPool.platform_tenant())
  end

  test "the meeting summary and transcription templates a deployment names become their tiers" do
    summary =
      global_template(%{
        "name" => "meeting summary model",
        "model" => "summary-model",
        "provider_config" => %{
          "base_url" => "https://summary.example.test/v1",
          "protocol" => "chat_completions",
          "api_key" => "sk-summary-0123456789"
        }
      })

    previous = SystemsRuntime.get_env(:salix_web, :meeting_summary_template)
    SystemsRuntime.put_env(:salix_web, :meeting_summary_template, summary["name"])
    on_exit(fn -> SystemsRuntime.put_env(:salix_web, :meeting_summary_template, previous) end)

    assert {:ok, _} = Migration.run()

    assert {:ok, %{"tiers" => %{"summary" => %{"model" => "summary-model"}} = tiers}} =
             PlatformModels.get()

    refute Map.has_key?(tiers, "transcription")
    assert {:ok, %{"model" => "summary-model"}} = PlatformModels.llm("summary")
  end

  test "a default template without a protocol becomes a Chat Completions tier" do
    router_template =
      global_template(%{
        "model" => "deepseek-flash",
        "provider" => "deepseek",
        "provider_config" => %{
          "base_url" => "https://api.deepseek.example.test/v1/",
          "api_key" => "sk-deepseek-0123456789"
        }
      })

    put_platform_defaults(%{"router_template_id" => router_template["template_id"]})

    assert {:ok, %{tiers: tiers}} = Migration.run()
    assert "router" in tiers
    assert {:ok, %{"tiers" => %{"router" => router}}} = PlatformModels.get()
    assert %{"model" => "deepseek-flash", "protocol" => "chat_completions"} = router
    assert {:ok, template} = PlatformModels.record("router")
    assert template["provider_config"]["api_key"] == "sk-deepseek-0123456789"
  end

  test "a default template without an endpoint leaves its tier on the template" do
    worker_template = global_template(%{"model" => "gpt-test"})

    put_platform_defaults(%{"worker_template_id" => worker_template["template_id"]})
    pinned = legacy_agent("worker", %{"template_id" => worker_template["template_id"]})

    assert {:ok, _} = Migration.run()
    refute PlatformModels.configured?("worker")
    assert stored(pinned)["model"] == nil
  end
end
