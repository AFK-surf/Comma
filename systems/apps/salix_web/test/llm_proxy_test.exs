defmodule SalixWeb.LLMProxyTest do
  use ExUnit.Case, async: false

  alias SalixWeb.LLMProxy

  defmodule MeteringFake do
    @behaviour SalixAgent.LLMMetering

    @impl true
    def before_llm_call(fact) do
      send(Application.fetch_env!(:salix_web, :llm_proxy_test_pid), {:meter_before, fact})

      if Application.get_env(:salix_web, :llm_proxy_block_before, false) do
        send(
          Application.fetch_env!(:salix_web, :llm_proxy_test_pid),
          {:meter_before_blocked, self()}
        )

        receive do
          :release -> :ok
        end
      end

      Application.get_env(:salix_web, :llm_proxy_before_result, :ok)
    end

    @impl true
    def after_llm_call(fact) do
      send(Application.fetch_env!(:salix_web, :llm_proxy_test_pid), {:meter_after, fact})
      :ok
    end
  end

  defmodule SlowProvider do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      send(Application.fetch_env!(:salix_web, :llm_proxy_test_pid), :slow_provider_request)
      Process.sleep(500)

      body = %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "late"}}],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end
  end

  defmodule ChunkingProvider do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      send(Application.fetch_env!(:salix_web, :llm_proxy_test_pid), :chunking_provider_request)

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce_while(1..30, conn, fn _idx, conn ->
        Process.sleep(10)

        case Plug.Conn.chunk(conn, " ") do
          {:ok, conn} -> {:cont, conn}
          {:error, _reason} -> {:halt, conn}
        end
      end)
    end
  end

  setup do
    previous_meter = Application.get_env(:salix_agent, :llm_metering_mod)
    previous_pid = Application.get_env(:salix_web, :llm_proxy_test_pid)
    previous_template = Application.get_env(:comma_core, :default_agent_template)
    previous_before_block = Application.get_env(:salix_web, :llm_proxy_block_before)
    previous_before_result = Application.get_env(:salix_web, :llm_proxy_before_result)

    Application.put_env(:salix_agent, :llm_metering_mod, MeteringFake)
    Application.put_env(:salix_web, :llm_proxy_test_pid, self())

    on_exit(fn ->
      restore_env(:salix_agent, :llm_metering_mod, previous_meter)
      restore_env(:salix_web, :llm_proxy_test_pid, previous_pid)
      restore_env(:salix_web, :llm_proxy_block_before, previous_before_block)
      restore_env(:salix_web, :llm_proxy_before_result, previous_before_result)
      restore_env(:comma_core, :default_agent_template, previous_template)
    end)

    :ok
  end

  test "project Router resolves its private template and never falls back after loss" do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Private Router"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Private Router"}, tenant["tenant_id"])

    {:ok, template} =
      SalixAgent.Templates.create_private(
        %{
          "name" => "Private Router",
          "model" => "gpt-private",
          "provider_config" => %{"api_key" => "own-router-key"}
        },
        tenant["tenant_id"]
      )

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "group_id" => group["group_id"],
          "role" => "router",
          "template_id" => template["template_id"]
        },
        tenant["tenant_id"]
      )

    {:ok, _} =
      Salix.Control.Groups.update(group["group_id"], %{"router_agent_id" => agent["agent_id"]})

    assert {:ok, resolved} = LLMProxy.resolve_project_router_llm(agent["agent_id"])
    assert resolved["api_key"] == "own-router-key"
    assert resolved["model"] == "gpt-private"

    SalixStore.S3.delete(
      SalixStore.Keys.ctl_private_template(tenant["tenant_id"], template["template_id"])
    )

    assert {:error, :project_router_template_unavailable} =
             LLMProxy.resolve_project_router_llm(agent["agent_id"])

    assert {:error, {:template_not_found, _}} = LLMProxy.resolve_llm(agent["agent_id"])
  end

  test "onboarding rejects a metering error with a real group billing owner" do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Onboarding metering"})

    {:ok, group} =
      Salix.Control.Groups.create(
        %{
          "name" => "Onboarding",
          "billing_owner" => %{
            "billing_account_id" => "billing-test",
            "product_owner_type" => "organization",
            "product_owner_id" => "org-test",
            "charge_policy" => "platform_paid"
          }
        },
        tenant["tenant_id"]
      )

    {:ok, agent} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Router", "role" => "router"},
        tenant["tenant_id"]
      )

    {:ok, _} =
      Salix.Control.Groups.update(group["group_id"], %{"router_agent_id" => agent["agent_id"]})

    {:ok, template} =
      SalixAgent.Templates.create(%{
        "name" => "Onboarding actual template",
        "model" => "gpt-test",
        "provider" => "anthropic",
        "provider_config" => %{"base_url" => "http://127.0.0.1:1", "protocol" => "anthropic"}
      })

    {:ok, _} =
      SalixAgent.Control.configure(agent["agent_id"], %{"template_id" => template["template_id"]})

    assert {:ok, resolved} = LLMProxy.resolve_project_router_llm(agent["agent_id"])
    assert resolved["template_id"] == template["template_id"]
    assert resolved["model"] == "gpt-test"

    Application.put_env(:salix_web, :llm_proxy_before_result, {:error, :metering_failed})

    assert {:error, :metering_failed} =
             LLMProxy.complete(
               agent["agent_id"],
               resolved,
               %{"messages" => []},
               require_billing_owner: true
             )

    assert_receive {:meter_before, %{billing_account_id: "billing-test", provider: "anthropic"}}
    refute_received {:meter_after, _}

    # Inject missing storage: the normal template API correctly refuses to
    # delete a referenced template, so it cannot create this failure fixture.
    SalixStore.S3.delete(SalixStore.Keys.ctl_template(template["template_id"]))

    assert {:error, :project_router_template_unavailable} =
             LLMProxy.resolve_project_router_llm(agent["agent_id"])
  end

  test "metered provider raises, exits, and throws still finalize exactly once" do
    cases = [
      {fn -> raise "boom" end, {RuntimeError, "boom"}},
      {fn -> exit(:provider_exit) end, {:exit, :provider_exit}},
      {fn -> throw(:provider_throw) end, {:throw, :provider_throw}}
    ]

    for {call, expected_reason} <- cases do
      assert {:error, ^expected_reason} = LLMProxy.metered(%{entrypoint: "test"}, call)
      assert_receive {:meter_before, %{entrypoint: "test"}}
      assert_receive {:meter_after, %{entrypoint: "test", status: "error"} = after_fact}
      assert is_binary(after_fact.error)
      refute_receive {:meter_after, _}, 10
    end
  end

  test "slow provider total timeout returns through metering and disables retries" do
    start_supervised!(
      {Bandit,
       plug: SlowProvider,
       port: 0,
       startup_log: false,
       thousand_island_options: [supervisor_options: [name: __MODULE__.SlowProviderServer]]}
    )

    {:ok, {_address, port}} = ThousandIsland.listener_info(__MODULE__.SlowProviderServer)

    llm = %{
      "model" => "slow-model",
      "base_url" => "http://127.0.0.1:#{port}",
      "api_key" => "test"
    }

    assert {:error, :provider_timeout} =
             LLMProxy.complete(
               "missing-agent-timeout-test",
               llm,
               %{
                 "messages" => [%{"role" => "user", "content" => "hello"}],
                 "max_tokens" => 10
               },
               provider_timeout_ms: 100,
               provider_retry: false
             )

    assert_receive :slow_provider_request
    assert_receive {:meter_before, %{model: "slow-model"}}
    assert_receive {:meter_after, %{model: "slow-model", status: "error"}}
    refute_receive :slow_provider_request, 150
    refute_receive {:meter_after, _}, 10
  end

  test "chunked responses cannot extend the total provider deadline or skip metering" do
    start_supervised!(
      {Bandit,
       plug: ChunkingProvider,
       port: 0,
       startup_log: false,
       thousand_island_options: [supervisor_options: [name: __MODULE__.ChunkingProviderServer]]}
    )

    {:ok, {_address, port}} = ThousandIsland.listener_info(__MODULE__.ChunkingProviderServer)

    llm = %{
      "model" => "chunking-model",
      "base_url" => "http://127.0.0.1:#{port}",
      "api_key" => "test"
    }

    assert {:error, :provider_timeout} =
             LLMProxy.complete(
               "missing-agent-chunking-timeout-test",
               llm,
               %{
                 "messages" => [%{"role" => "user", "content" => "hello"}],
                 "max_tokens" => 10
               },
               provider_timeout_ms: 100,
               provider_retry: false
             )

    assert_receive :chunking_provider_request
    assert_receive {:meter_before, %{model: "chunking-model"}}

    assert_receive {:meter_after, %{model: "chunking-model", status: "error", error: error}}

    assert error =~ "provider_timeout"
    refute_receive {:meter_after, _}, 10
  end

  test "an absolute provider deadline is rechecked after metering authorization" do
    start_supervised!(
      {Bandit,
       plug: SlowProvider,
       port: 0,
       startup_log: false,
       thousand_island_options: [
         supervisor_options: [name: __MODULE__.DeadlineProviderServer]
       ]}
    )

    {:ok, {_address, port}} = ThousandIsland.listener_info(__MODULE__.DeadlineProviderServer)
    Application.put_env(:salix_web, :llm_proxy_block_before, true)

    llm = %{
      "model" => "deadline-model",
      "base_url" => "http://127.0.0.1:#{port}",
      "api_key" => "test"
    }

    assert {:error, :provider_timeout} =
             LLMProxy.complete(
               "missing-agent-deadline-test",
               llm,
               %{
                 "messages" => [%{"role" => "user", "content" => "hello"}],
                 "max_tokens" => 10
               },
               provider_deadline_ms: System.monotonic_time(:millisecond) + 200,
               provider_retry: false
             )

    assert_receive {:meter_before, %{model: "deadline-model"}}
    assert_receive {:meter_before_blocked, preflight_worker}
    refute Process.alive?(preflight_worker)
    refute_receive {:meter_after, _}, 100
    refute_receive :slow_provider_request, 100
  end

  test "distinct receive deadlines do not create permanent Req Finch pools" do
    start_supervised!(
      {Bandit,
       plug: SlowProvider,
       port: 0,
       startup_log: false,
       thousand_island_options: [supervisor_options: [name: __MODULE__.PoolProviderServer]]}
    )

    {:ok, {_address, port}} = ThousandIsland.listener_info(__MODULE__.PoolProviderServer)
    pools_before = DynamicSupervisor.count_children(Req.FinchSupervisor).active

    llm = %{
      "model" => "pool-model",
      "base_url" => "http://127.0.0.1:#{port}",
      "api_key" => "test"
    }

    req = %{
      model: "pool-model",
      messages: [%{"role" => "user", "content" => "hello"}],
      max_tokens: 10
    }

    for timeout <- [7, 11, 17] do
      _result =
        SalixLlm.SiteProxy.complete(llm, req,
          receive_timeout: timeout,
          retry: false
        )
    end

    assert DynamicSupervisor.count_children(Req.FinchSupervisor).active == pools_before
  end

  test "default template fallback carries context_tokens" do
    Application.put_env(:comma_core, :default_agent_template, %{
      "model" => "fallback-model",
      "max_tokens" => 1_234,
      "context_tokens" => 32_768,
      "provider_config" => %{"base_url" => "https://example.invalid", "api_key" => "test"}
    })

    assert {:ok, llm} = LLMProxy.resolve_llm("missing-agent-context-test")
    assert llm["model"] == "fallback-model"
    assert llm["max_tokens"] == 1_234
    assert llm["context_tokens"] == 32_768
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
