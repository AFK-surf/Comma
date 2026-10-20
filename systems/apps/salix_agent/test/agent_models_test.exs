defmodule SalixAgent.AgentModelsTest do
  @moduledoc "agent.models: the catalog models a Group's usable Profiles serve."
  use SystemsClock.Case, async: false

  alias SalixAgent.{AccountPool, AgentManagement}
  alias SalixAgent.SubscriptionStore, as: Store
  alias SalixStore.{Ids, S3}

  setup do
    old_ports = SystemsRuntime.get_env(:salix_agent, :agent_management_ports)

    SystemsRuntime.put_env(
      :salix_agent,
      :agent_management_ports,
      AgentManagement.Ports.Standalone
    )

    start_supervised!(S3.Fake)
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{"role" => "router"})

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      if old_ports,
        do: SystemsRuntime.put_env(:salix_agent, :agent_management_ports, old_ports),
        else: SystemsRuntime.delete_env(:salix_agent, :agent_management_ports)
    end)

    %{tenant: tenant, ctx: %{agent_id: router["agent_id"], session_id: "s", tool_call_id: "t"}}
  end

  test "lists no model only a platform Profile serves", c do
    platform = AccountPool.platform_tenant()

    on_exit(fn ->
      Store.query("DELETE FROM subscription_accounts WHERE tenant_id=$1", [platform])
    end)

    {:ok, _} = key(platform, "anthropic", "sk-ant-platform-0123456789")

    {:ok, _} =
      key(platform, "custom", "sk-custom-platform-0123", %{
        "base_url" => "https://llm.example.test/v1",
        "protocol" => "chat_completions",
        "models" => ["platform-model"]
      })

    assert {:ok, %{"models" => []}} = AgentManagement.run(:models, %{"limit" => 100}, c.ctx)
  end

  test "lists only models a usable Profile serves, subscriptions first", %{tenant: tenant} = c do
    assert {:ok, %{"models" => [], "truncated" => false, "user" => user}} =
             AgentManagement.run(:models, %{}, c.ctx)

    # Standalone Salix has no product user.
    assert user == %{"locale" => nil, "timezone" => nil}

    subscription(tenant, "codex", "ok")
    # A subscription that is not signed in serves nothing.
    subscription(tenant, "claude", "login")
    {:ok, _} = key(tenant, "anthropic", "sk-ant-0123456789abcdefgh")
    {:ok, google} = key(tenant, "google", "AIza-0123456789abcdefgh")

    {:ok, _} =
      AccountPool.update(tenant, google["id"], %{
        "disabled" => true,
        "version" => google["version"]
      })

    {:ok, _} =
      key(tenant, "custom", "sk-custom-0123456789", %{
        "base_url" => "https://llm.example.test/v1",
        "protocol" => "chat_completions",
        "models" => ["team-model"]
      })

    assert {:ok, %{"models" => models, "truncated" => false}} =
             AgentManagement.run(:models, %{"limit" => 100}, c.ctx)

    by_id = Map.new(models, &{&1["id"], &1})

    assert %{
             "served_by" => "subscription",
             "subscription_plans" => ["codex"],
             "api_key_sources" => [],
             "requires_allow_paid" => false,
             "family" => family,
             "efforts" => efforts
           } = by_id["gpt-5.5"]

    assert is_binary(family) and "high" in efforts

    # Only the key serves Claude: the Claude subscription is not signed in.
    assert %{
             "served_by" => "api_key",
             "api_key_sources" => [%{"id" => "anthropic", "name" => anthropic}],
             "requires_allow_paid" => true
           } = by_id["claude-haiku-4-5"]

    assert is_binary(anthropic)

    assert %{"served_by" => "api_key", "vendor" => nil, "efforts" => []} = by_id["team-model"]

    # The disabled Google key serves nothing; no Profile reaches a gateway-only model.
    refute Enum.any?(models, &(&1["vendor"] == "google" and &1["served_by"] == "api_key"))
    refute Map.has_key?(by_id, "gpt-5.1-thinking")

    served = Enum.map(models, & &1["served_by"])
    assert served == Enum.sort_by(served, &if(&1 == "subscription", do: 0, else: 1))

    assert {:ok, %{"models" => [_one], "truncated" => true}} =
             AgentManagement.run(:models, %{"limit" => 1}, c.ctx)

    assert {:ok, %{"models" => haiku}} =
             AgentManagement.run(:models, %{"query" => "haiku"}, c.ctx)

    assert haiku != [] and Enum.all?(haiku, &(&1["id"] =~ "haiku"))
  end

  defmodule OneModelPorts do
    @moduledoc false
    def model_filter(_scope),
      do: {:ok, &Enum.filter(&1, fn model -> model["id"] == "gpt-5.5" end)}

    def user_context(_scope), do: {:ok, %{"locale" => nil, "timezone" => nil}}
  end

  test "the product's model filter applies before limit", %{tenant: tenant} = c do
    subscription(tenant, "codex", "ok")
    SystemsRuntime.put_env(:salix_agent, :agent_management_ports, OneModelPorts)

    assert {:ok, %{"models" => [%{"id" => "gpt-5.5"}], "truncated" => false}} =
             AgentManagement.run(:models, %{"limit" => 1}, c.ctx)
  end

  defmodule RaisingPorts do
    @moduledoc false
    def internal_worker(_scope, _model, _create), do: raise("port failure")
    def user_context(_scope), do: {:ok, %{"locale" => nil, "timezone" => nil}}
  end

  defp key(tenant, source, api_key, extra \\ %{}) do
    AccountPool.create(
      tenant,
      Map.merge(
        %{"credential_kind" => "provider_api_key", "source" => source, "api_key" => api_key},
        extra
      )
    )
  end

  defp subscription(tenant, provider, status) do
    id = Store.id()
    {:ok, cipher} = Store.seal(tenant, id, %{"access_token" => "subscription-token"})

    {:ok, record} =
      Store.create(tenant, %{
        "id" => id,
        "credential" => "subscription",
        "source" => provider,
        "email" => "member@example.com",
        "disabled" => false,
        "status" => status,
        "credentials" => cipher,
        "prepared" => true,
        "expires_at" => DateTime.to_iso8601(DateTime.add(SystemsClock.utc_now(), 3600))
      })

    record
  end
end
