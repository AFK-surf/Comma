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

  test "the transcription tier names a model for declined audio at the same Profile", c do
    {:ok, _} =
      PlatformModels.put(%{
        "tiers" => %{
          "transcription" => %{
            "profile_id" => c.profile["id"],
            "model" => "gemini-3.7-flash",
            "fallback_model" => "gemini-3.6-flash"
          }
        }
      })

    assert {:ok, llm} = PlatformModels.llm("transcription")
    assert llm["model"] == "gemini-3.7-flash"
    assert llm["fallback_model"] == "gemini-3.6-flash"
    assert llm["base_url"] == "https://gateway.example.test/v1"
  end

  test "an entry needs a platform Profile and a model id" do
    assert {:error, :invalid_platform_models} =
             PlatformModels.put(%{"tiers" => %{"worker" => %{"model" => "gpt-6-sol"}}})

    assert {:error, :invalid_platform_models} =
             PlatformModels.put(%{"tiers" => %{"max" => %{"profile_id" => "p", "model" => "m"}}})
  end

  test "a model the platform route table returns runs at a platform key, seen only by name", c do
    routed = %{"kind" => "platform", "tier" => "worker", "model" => "gpt-6-sol"}

    assert {:ok, llm} = ModelChoice.resolve_llm(routed, c.tenant)
    llm = Map.new(llm, fn {key, value} -> {to_string(key), value} end)
    assert llm["base_url"] == "https://gateway.example.test/v1"
    assert llm["api_key"] == "sk-platform-0123456789"
    assert llm["model"] == "gpt-6-sol"
    assert llm["credential_scope"] == "platform"

    assert {:ok, public} = ModelChoice.public(routed, c.tenant)
    assert public["name"] == "Comma"
    assert public["provider"] == "comma"
    refute inspect(public) =~ "gpt-6-sol"

    # No platform key serves it: the Task's model is unavailable.
    assert {:error, :platform_model_unavailable} =
             PlatformModels.routed_record("gpt-unknown")
  end

  test "routed effort survives storage and reaches the provider without inheriting the tier", c do
    configure(c.profile)

    for effort <- ["low", "medium", nil] do
      choice = %{
        "kind" => "platform",
        "tier" => "worker",
        "model" => "gpt-6-sol",
        "reasoning_effort" => effort
      }

      policy = %{
        "mode" => "routes",
        "schema_version" => 2,
        "revision" => "effort",
        "entries" => [%{"key" => "code", "description" => "Write code", "model" => choice}]
      }

      assert {:ok, _} = PlatformModels.put_routing(PlatformModels.routing(), policy)
      assert %{"entries" => [%{"model" => stored}]} = PlatformModels.routing()
      assert {:ok, llm} = ModelChoice.resolve_llm(stored, c.tenant)
      llm = Map.new(llm, fn {key, value} -> {to_string(key), value} end)
      assert llm["model"] == "gpt-6-sol"
      assert llm["reasoning_effort"] == effort
      assert llm["credential_scope"] == "platform"
    end

    choice = %{"kind" => "platform", "tier" => "worker", "model" => "gpt-6-sol"}

    for invalid <- [
          Map.put(choice, "profile_id", "foreign"),
          Map.put(choice, "reasoning_effort", "unsupported")
        ] do
      assert {:error, {:model_choice, :invalid_model_configuration}} =
               ModelChoice.resolve_llm(invalid, c.tenant)
    end
  end

  test "the platform route table names models of the worker tier only", c do
    entry_model = fn model ->
      %{"key" => "hard", "description" => "Hard tasks", "model" => model}
    end

    table = fn model ->
      %{
        "mode" => "routes",
        "schema_version" => 2,
        "revision" => "r1",
        "entries" => [entry_model.(model)]
      }
    end

    routed = %{"kind" => "platform", "tier" => "worker", "model" => "gpt-6-sol"}
    worker = %{"profile_id" => c.profile["id"], "model" => "gpt-6-sol"}
    {:ok, _} = PlatformModels.put(%{"tiers" => %{"worker" => worker}})

    # A member's own model, a bare tier, another tier or a pinned Profile has
    # no place in the platform's table.
    for model <- [
          %{"kind" => "catalog", "model" => "gpt-6-sol"},
          %{"kind" => "platform", "tier" => "worker"},
          %{"kind" => "platform", "tier" => "router", "model" => "gpt-6-sol"}
        ] do
      assert {:error, :invalid_platform_routing} = PlatformModels.put_routing(nil, table.(model))
    end

    assert {:error, :invalid_platform_routing} =
             PlatformModels.put_routing(nil, Map.put(table.(routed), "profile_id", "p"))

    assert {:ok, saved} = PlatformModels.put_routing(nil, table.(routed))
    assert PlatformModels.routing() == saved

    # A stale editor does not overwrite the table.
    assert {:error, :conflict} = PlatformModels.put_routing(nil, table.(routed))

    # Saving the tiers keeps the table.
    {:ok, _} = PlatformModels.put(%{"name" => "Comma", "tiers" => %{"worker" => worker}})
    assert PlatformModels.routing() == saved
  end
end
