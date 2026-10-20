defmodule SalixWeb.LLMProxyTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.SalixMeet"]

  alias SalixWeb.LLMProxy

  defmodule MeteringFake do
    @behaviour SalixAgent.LLMMetering

    @impl true
    def before_llm_call(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :llm_proxy_test_pid),
        {:meter_before, fact}
      )

      if SystemsRuntime.get_env(:salix_web, :llm_proxy_block_before, false) do
        SystemsRuntime.Proc.send(
          SystemsRuntime.fetch_env!(:salix_web, :llm_proxy_test_pid),
          {:meter_before_blocked, SystemsRuntime.Proc.self()}
        )

        SystemsRuntime.Proc.receive do
          :release -> :ok
        end
      end

      SystemsRuntime.get_env(:salix_web, :llm_proxy_before_result, :ok)
    end

    @impl true
    def after_llm_call(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :llm_proxy_test_pid),
        {:meter_after, fact}
      )

      :ok
    end
  end

  defmodule SlowProvider do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :llm_proxy_test_pid),
        :slow_provider_request
      )

      SystemsClock.sleep(500)

      body = %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "late"}}],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      }

      conn
      |> Plug.Conn.put_resp_header("connection", "close")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end
  end

  defmodule ChunkingProvider do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :llm_proxy_test_pid),
        :chunking_provider_request
      )

      conn =
        conn
        |> Plug.Conn.put_resp_header("connection", "close")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce_while(1..30, conn, fn _idx, conn ->
        SystemsClock.sleep(10)

        case Plug.Conn.chunk(conn, " ") do
          {:ok, conn} -> {:cont, conn}
          {:error, _reason} -> {:halt, conn}
        end
      end)
    end
  end

  setup do
    previous_meter = SystemsRuntime.get_env(:salix_agent, :llm_metering_mod)
    previous_pid = SystemsRuntime.get_env(:salix_web, :llm_proxy_test_pid)
    previous_template = SystemsRuntime.get_env(:comma_core, :default_agent_template)
    previous_before_block = SystemsRuntime.get_env(:salix_web, :llm_proxy_block_before)
    previous_before_result = SystemsRuntime.get_env(:salix_web, :llm_proxy_before_result)

    SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, MeteringFake)
    SystemsRuntime.put_env(:salix_web, :llm_proxy_test_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      restore_env(:salix_agent, :llm_metering_mod, previous_meter)
      restore_env(:salix_web, :llm_proxy_test_pid, previous_pid)
      restore_env(:salix_web, :llm_proxy_block_before, previous_before_block)
      restore_env(:salix_web, :llm_proxy_before_result, previous_before_result)
      restore_env(:comma_core, :default_agent_template, previous_template)
    end)

    :ok
  end

  test "project Router resolves the platform model it follows and never falls back after loss" do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Platform Router"})

    {:ok, group} =
      Salix.Control.Groups.create(%{"name" => "Platform Router"}, tenant["tenant_id"])

    SalixAgent.TestSupport.configure_platform_tier!(
      "router",
      "https://router-model.example.test/v1",
      "gpt-router"
    )

    {:ok, agent} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "role" => "router"},
        tenant["tenant_id"]
      )

    {:ok, _} =
      Salix.Control.Groups.update(group["group_id"], %{"router_agent_id" => agent["agent_id"]})

    assert {:ok, resolved} = LLMProxy.resolve_project_router_llm(agent["agent_id"])
    assert resolved["model"] == "gpt-router"
    assert resolved["base_url"] == "https://router-model.example.test/v1"
    assert resolved["model_choice"] == %{"kind" => "platform", "tier" => "router"}

    SalixAgent.TestSupport.clear_platform_tier!("router")

    assert {:error, :project_router_model_unavailable} =
             LLMProxy.resolve_project_router_llm(agent["agent_id"])

    assert {:error, :platform_model_unconfigured} = LLMProxy.resolve_llm(agent["agent_id"])
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

    SalixAgent.TestSupport.configure_platform_tier!("router", "http://127.0.0.1:1", "gpt-test")

    {:ok, agent} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Router", "role" => "router"},
        tenant["tenant_id"]
      )

    {:ok, _} =
      Salix.Control.Groups.update(group["group_id"], %{"router_agent_id" => agent["agent_id"]})

    assert {:ok, resolved} = LLMProxy.resolve_project_router_llm(agent["agent_id"])
    assert resolved["model"] == "gpt-test"

    SystemsRuntime.put_env(:salix_web, :llm_proxy_before_result, {:error, :metering_failed})

    assert {:error, :metering_failed} =
             LLMProxy.complete(
               agent["agent_id"],
               resolved,
               %{"messages" => []},
               require_billing_owner: true
             )

    settle_receive({:meter_before, %{billing_account_id: "billing-test"}})
    refute_received {:meter_after, _}
  end

  test "metered provider raises, exits, and throws still finalize exactly once" do
    cases = [
      {fn -> raise "boom" end, {RuntimeError, "boom"}},
      {fn -> exit(:provider_exit) end, {:exit, :provider_exit}},
      {fn -> throw(:provider_throw) end, {:throw, :provider_throw}}
    ]

    for {call, expected_reason} <- cases do
      assert {:error, ^expected_reason} = LLMProxy.metered(%{entrypoint: "test"}, call)
      settle_receive({:meter_before, %{entrypoint: "test"}})
      settle_receive({:meter_after, %{entrypoint: "test", status: "error"} = after_fact})
      assert is_binary(after_fact.error)
      settle_refute_receive({:meter_after, _}, 10)
    end
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
