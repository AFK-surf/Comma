defmodule SalixAgent.PlatformModelsTest do
  @moduledoc """
  The platform model: an Agent that follows the platform default runs its
  role's internal model at a platform Profile, at the platform's cost, and
  members see only the platform model's name.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{AccountPool, AgentModel, ModelChoice, PlatformModels}
  alias SalixAgent.SubscriptionStore, as: Store

  setup do
    start_supervised!(SalixStore.S3.Fake)
    platform = AccountPool.platform_tenant()

    on_exit(fn ->
      Store.query("DELETE FROM subscription_accounts WHERE tenant_id=$1", [platform])
    end)

    {:ok, profile} =
      AccountPool.create(platform, %{
        "credential_kind" => "provider_api_key",
        "source" => "custom",
        "api_key" => "sk-platform-0123456789",
        "base_url" => "https://gateway.example.test/v1",
        "protocol" => "responses",
        "models" => ["gpt-6-sol"]
      })

    {:ok, tenant: SalixAgent.TestSupport.new_tenant_id(), profile: profile}
  end

  defp configure(profile) do
    {:ok, _} =
      PlatformModels.put(%{
        "tiers" => %{
          "worker" => %{
            "profile_id" => profile["id"],
            "model" => "gpt-6-sol",
            "reasoning_effort" => "high",
            "context_tokens" => 200_000,
            "max_tokens" => 65_536,
            "images" => true
          }
        }
      })
  end

  test "a following Worker runs its tier's internal model at the platform's cost", c do
    configure(c.profile)
    worker = %{"role" => "worker", "tenant_id" => c.tenant}

    assert {:ok, %{"kind" => "platform", "tier" => "worker"} = ref, :platform_default} =
             AgentModel.choice(worker)

    assert {:ok, llm} = ModelChoice.resolve_llm(ref, c.tenant)
    llm = Map.new(llm, fn {key, value} -> {to_string(key), value} end)
    assert llm["base_url"] == "https://gateway.example.test/v1"
    assert llm["api_key"] == "sk-platform-0123456789"
    assert llm["model"] == "gpt-6-sol"
    assert llm["credential_scope"] == "platform"
    assert llm["reasoning_effort"] == "high"
    assert llm["context_tokens"] == 200_000
    assert llm["supports_images"] == true

    # Members see the name only.
    assert {:ok, public} = ModelChoice.public(ref, c.tenant)
    assert public["name"] == "Comma"
    assert public["provider"] == "comma"
    refute inspect(public) =~ "gpt-6-sol"
    refute inspect(public) =~ "gateway.example.test"

    # The Router tier is not configured: a following Router has no model.
    assert {:error, :platform_model_unconfigured} =
             AgentModel.choice(%{"role" => "router"})
  end

  test "a member can choose the platform model of a tier, and nothing else of it", c do
    assert {:ok, %{"kind" => "platform", "tier" => "worker"}} =
             ModelChoice.choose(%{"kind" => "platform", "tier" => "worker"}, c.tenant)

    assert {:error, _} = ModelChoice.choose(%{"kind" => "platform", "tier" => "max"}, c.tenant)

    assert {:error, _} =
             ModelChoice.choose(
               %{"kind" => "platform", "tier" => "worker", "model" => "gpt-6-sol"},
               c.tenant
             )

    # Unconfigured or disabled, the tier serves nothing.
    assert {:error, :platform_model_unconfigured} = PlatformModels.record("worker")
    configure(c.profile)

    {:ok, _} =
      AccountPool.update(AccountPool.platform_tenant(), c.profile["id"], %{
        "disabled" => true,
        "version" => c.profile["version"]
      })

    assert {:error, :platform_model_unavailable} = PlatformModels.record("worker")
  end

  test "an LMHub tier carries the deployment's user agent; members cannot use LMHub", c do
    previous = SystemsRuntime.get_env(:salix_agent, :lmhub_user_agent)
    SystemsRuntime.put_env(:salix_agent, :lmhub_user_agent, "bridge-unbox-test/1.0.0")

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :lmhub_user_agent, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :lmhub_user_agent)
    end)

    attrs = %{
      "credential_kind" => "provider_api_key",
      "source" => "lmhub",
      "api_key" => "sk-lmhub-0123456789",
      "base_url" => "http://lmhub.lmhub.svc.cluster.local/v1",
      "protocol" => "anthropic"
    }

    assert {:error, :invalid_input} = AccountPool.create(c.tenant, attrs)
    assert {:ok, lmhub} = AccountPool.create(AccountPool.platform_tenant(), attrs)

    {:ok, _} =
      PlatformModels.put(%{
        "tiers" => %{"router" => %{"profile_id" => lmhub["id"], "model" => "claude-opus-4.6"}}
      })

    assert {:ok, record} = PlatformModels.record("router")
    config = record["provider_config"]
    assert config["default_headers"] == %{"user-agent" => "bridge-unbox-test/1.0.0"}
    assert config["protocol"] == "anthropic"
    assert config["base_url"] =~ "lmhub.lmhub.svc.cluster.local"
  end

  test "an entry needs a platform Profile and a model id" do
    assert {:error, :invalid_platform_models} =
             PlatformModels.put(%{"tiers" => %{"worker" => %{"model" => "gpt-6-sol"}}})

    assert {:error, :invalid_platform_models} =
             PlatformModels.put(%{"tiers" => %{"max" => %{"profile_id" => "p", "model" => "m"}}})
  end
end
