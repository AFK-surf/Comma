defmodule SalixWeb.RuntimeProxyTest do
  use ExUnit.Case, async: false

  alias SalixAgent.ExternalAgentRuntime
  alias SalixEnv.Registry
  alias SalixStore.RuntimeIds
  alias SalixWeb.RuntimeProxy

  defmodule FakeIMProvider do
    @behaviour SalixAgent.Tools.ImRouter

    @impl true
    def list_connects(agent_id),
      do: {:ok, [%{"connect_id" => "internal", "provider" => "internal", "agent_id" => agent_id}]}

    @impl true
    def provider_manual(provider), do: {:ok, %{"provider" => provider}}

    @impl true
    def call_api(agent_id, provider, api, args) do
      {:ok, %{"agent_id" => agent_id, "provider" => provider, "api" => api, "args" => args}}
    end
  end

  defmodule SlowIMProvider do
    @behaviour SalixAgent.Tools.ImRouter

    @impl true
    def list_connects(agent_id) do
      %{counter: counter, owner: owner} =
        Application.fetch_env!(:salix_web, :runtime_proxy_test_slow_im)

      invocation = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)

      if invocation > 1 do
        send(owner, {:slow_im_call_started, self(), System.monotonic_time(:millisecond)})

        receive do
          :release -> :ok
        end
      end

      FakeIMProvider.list_connects(agent_id)
    end

    @impl true
    defdelegate provider_manual(provider), to: FakeIMProvider

    @impl true
    defdelegate call_api(agent_id, provider, api, args), to: FakeIMProvider
  end

  defmodule FakeLLM do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _body, conn} = read_body(conn)

      resp = %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "MOCK SUMMARY"}}],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(resp))
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_store = Application.get_env(:salix_store, :s3_backend)
    prev_im = Application.get_env(:salix_agent, :im_provider_mod)
    prev_llm = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)
    start_supervised!(SalixAgent.LLM.Mock)
    Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_store)

      if prev_im,
        do: Application.put_env(:salix_agent, :im_provider_mod, prev_im),
        else: Application.delete_env(:salix_agent, :im_provider_mod)

      if prev_llm,
        do: Application.put_env(:salix_agent, :llm, prev_llm),
        else: Application.delete_env(:salix_agent, :llm)
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Runtime proxy"})
    Process.put(:test_tenant_id, tenant["tenant_id"])

    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Runtime"}, tenant_id())
    group_id = group["group_id"]

    env_id = connected_codex_device!(group_id)

    {:ok, agent} =
      SalixAgent.Control.create(%{"group_id" => group_id, "name" => "Runtime"}, tenant_id())

    {:ok, agent} =
      SalixAgent.Control.configure(agent["agent_id"], %{
        "runtime_config" => codex_runtime_config(env_id)
      })

    session_id = SalixStore.Ids.new_session_id()

    {:ok, :external} =
      ExternalAgentRuntime.stage_delivery(agent["agent_id"], %{
        source_message_id: "runtime-proxy-#{session_id}",
        payload: %{
          "session_id" => session_id,
          "role" => "user",
          "content" => "runtime proxy setup",
          "no_wake" => true
        }
      })

    {:ok, binding} =
      ExternalAgentRuntime.begin_session(
        agent["agent_id"],
        session_id,
        tenant_id(),
        codex_runtime_config(env_id)
      )

    {:ok,
     group_id: group_id,
     env_id: env_id,
     agent_id: agent["agent_id"],
     session_id: session_id,
     token: binding["runtime_capability"]["token"]}
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  test "GET /tools returns the token-bound session tool policy", %{
    env_id: env_id,
    group_id: group_id,
    token: token
  } do
    SalixAgent.TestSupport.stop_all_agents()

    {status, body} =
      proxy_json(env_id, token, "GET", "/tools", %{}, %{
        "tenant_id" => tenant_id(),
        "group_id" => group_id
      })

    assert status == 200
    names = Enum.map(body["tools"], & &1["name"])
    assert "im.connects_list" in names
    refute "agent.list" in names
  end

  test "POST /tool refuses tools outside the token-bound session policy",
       %{env_id: env_id, group_id: group_id, token: token} do
    {status, body} =
      proxy_json(env_id, token, "POST", "/tool/agent.list", %{}, %{
        "tenant_id" => tenant_id(),
        "group_id" => group_id
      })

    assert status == 404
    assert body == %{"error" => "not found"}
  end

  test "runtime capability is bound to the connector environment", %{
    agent_id: agent_id,
    group_id: group_id,
    session_id: session_id,
    token: token
  } do
    {status, body} =
      proxy_json("other-env", token, "GET", "/tools", %{}, %{
        "tenant_id" => tenant_id(),
        "group_id" => group_id
      })

    assert status == 401
    assert body == %{"error" => "unauthorized"}

    {tool_status, tool_body} =
      proxy_json("other-env", token, "POST", "/tool/im.connects_list", %{}, %{
        "tenant_id" => tenant_id(),
        "group_id" => group_id
      })

    assert tool_status == 401
    assert tool_body == %{"error" => "unauthorized"}

    assert {:ok, session} = ExternalAgentRuntime.get_session(agent_id, session_id)
    assert session["async_tool_calls"] == %{}
  end

  test "session capability follows the exact runtime onto its current connector run", %{
    env_id: first_env_id,
    group_id: group_id,
    token: token
  } do
    second_env_id = reconnect_codex_device!(group_id, first_env_id)

    {status, body} =
      proxy_json(second_env_id, token, "GET", "/tools", %{}, %{
        "tenant_id" => tenant_id(),
        "group_id" => group_id
      })

    assert status == 200
    assert Enum.any?(body["tools"], &(&1["name"] == "im.connects_list"))

    {old_status, old_body} =
      proxy_json(first_env_id, token, "GET", "/tools", %{}, %{
        "tenant_id" => tenant_id(),
        "group_id" => group_id
      })

    assert old_status == 401
    assert old_body == %{"error" => "unauthorized"}
  end

  test "runtime status events do not revoke the session capability", %{
    agent_id: agent_id,
    env_id: env_id,
    group_id: group_id,
    session_id: session_id,
    token: token
  } do
    assert {:ok, %{"session_id" => ^session_id}} =
             ExternalAgentRuntime.complete_session(agent_id, session_id)

    {tools_status, tools_body} =
      proxy_json(env_id, token, "GET", "/tools", %{}, %{
        "tenant_id" => tenant_id(),
        "group_id" => group_id
      })

    assert tools_status == 200
    assert Enum.any?(tools_body["tools"], &(&1["name"] == "im.connects_list"))

    {call_status, call_body} =
      proxy_json(env_id, token, "POST", "/tool/im.connects_list", %{}, %{
        "tenant_id" => tenant_id(),
        "group_id" => group_id
      })

    assert call_status == 200

    assert [%{"connect_id" => "internal", "provider" => "internal", "agent_id" => ^agent_id}] =
             call_body["connects"]
  end

  test "POST /tool hard-caps configured terminal wait and returns the typed running result on expiry",
       %{
         agent_id: agent_id,
         env_id: env_id,
         group_id: group_id,
         session_id: session_id,
         token: token
       } do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    previous_provider = Application.get_env(:salix_agent, :im_provider_mod)
    previous_wait = Application.get_env(:salix_web, :runtime_proxy_tool_terminal_wait_ms)

    Application.put_env(:salix_agent, :im_provider_mod, SlowIMProvider)

    Application.put_env(:salix_web, :runtime_proxy_test_slow_im, %{
      counter: counter,
      owner: self()
    })

    Application.put_env(:salix_web, :runtime_proxy_tool_terminal_wait_ms, 10_000)

    on_exit(fn ->
      Application.put_env(:salix_agent, :im_provider_mod, previous_provider)
      Application.delete_env(:salix_web, :runtime_proxy_test_slow_im)

      if is_nil(previous_wait),
        do: Application.delete_env(:salix_web, :runtime_proxy_tool_terminal_wait_ms),
        else: Application.put_env(:salix_web, :runtime_proxy_tool_terminal_wait_ms, previous_wait)
    end)

    {status, body} =
      proxy_json(env_id, token, "POST", "/tool/im.connects_list", %{}, %{
        "tenant_id" => tenant_id(),
        "group_id" => group_id
      })

    finished_at = System.monotonic_time(:millisecond)

    assert status == 200
    assert body["status"] == "running"
    assert is_binary(body["tool_call_id"])
    assert_receive {:slow_im_call_started, tool_pid, tool_started_at}, 500
    endpoint_wait_ms = finished_at - tool_started_at
    assert endpoint_wait_ms >= 2_500
    assert endpoint_wait_ms < 3_900
    send(tool_pid, :release)

    assert eventually(fn ->
             case ExternalAgentRuntime.get_async_tool_call(
                    agent_id,
                    session_id,
                    body["tool_call_id"]
                  ) do
               {:ok, %{"status" => "completed"}} -> true
               _other -> false
             end
           end)
  end

  test "POST /llm/chat is rejected for a capability without the llm scope (403)", %{
    env_id: env_id,
    group_id: group_id,
    token: token
  } do
    {status, body} =
      proxy_json(
        env_id,
        token,
        "POST",
        "/llm/chat",
        %{"messages" => [%{"role" => "user", "content" => "hi"}]},
        %{"tenant_id" => tenant_id(), "group_id" => group_id}
      )

    assert status == 403
    assert body == %{"error" => "llm not permitted for this capability"}
  end

  test "POST /llm/chat with an LLM capability returns a completion (200)", %{
    agent_id: agent_id,
    env_id: env_id,
    group_id: group_id
  } do
    port = start_bandit_retry!(fn p -> {Bandit, plug: FakeLLM, port: p} end)

    tmpl_id = "test-llm-#{System.unique_integer([:positive])}"

    {:ok, _} =
      SalixAgent.Templates.create(%{
        "template_id" => tmpl_id,
        "name" => "Test LLM",
        "model" => "test-model",
        "provider" => "openai",
        "max_tokens" => 2048,
        "provider_config" => %{
          "protocol" => "chat_completions",
          "base_url" => "http://127.0.0.1:#{port}",
          "api_key" => "test-key"
        }
      })

    {:ok, _} = SalixAgent.Control.configure(agent_id, %{"template_id" => tmpl_id})

    prev_skip = Application.get_env(:salix_web, :connector_llm_skip_metering)
    Application.put_env(:salix_web, :connector_llm_skip_metering, true)

    on_exit(fn ->
      if is_nil(prev_skip),
        do: Application.delete_env(:salix_web, :connector_llm_skip_metering),
        else: Application.put_env(:salix_web, :connector_llm_skip_metering, prev_skip)
    end)

    agent = %{"tenant_id" => tenant_id(), "group_id" => group_id, "agent_id" => agent_id}

    {:ok, cap} =
      ExternalAgentRuntime.mint_llm_capability(
        agent,
        SalixStore.Ids.new_session_id(),
        env_id
      )

    {status, body} =
      proxy_json(
        env_id,
        cap["token"],
        "POST",
        "/llm/chat",
        %{"messages" => [%{"role" => "user", "content" => "summarize"}]},
        %{"tenant_id" => tenant_id(), "group_id" => group_id}
      )

    assert status == 200
    assert get_in(body, ["choices", Access.at(0), "message", "content"]) == "MOCK SUMMARY"
  end

  defp proxy_json(env_id, token, method, path, body, meta) do
    params = %{
      "capability_token" => token,
      "method" => method,
      "route_path" => path,
      "body_base64" => body |> Jason.encode!() |> Base.encode64()
    }

    assert {:ok, %{"status" => status, "body_base64" => encoded}} =
             RuntimeProxy.handle(env_id, params, meta)

    assert {:ok, raw} = Base.decode64(encoded)
    assert {:ok, decoded} = Jason.decode(raw)
    {status, decoded}
  end

  defp connected_codex_device!(group_id) do
    transport_id = "env-runtime-proxy-#{System.unique_integer([:positive])}"
    stable_device_id = "device-" <> transport_id

    {:ok, ^transport_id, record} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => tenant_id(),
          "group_id" => group_id,
          "device_id" => stable_device_id,
          "connector_id" => "connector-" <> transport_id,
          "name" => "Runtime Proxy Device"
        },
        transport_id: transport_id
      )

    connector_run_id = record["connector_run_id"]

    {:ok, _record} =
      Registry.update_meta(connector_run_id, fn meta ->
        Map.put(meta, "agent_runtimes", [
          %{
            "kind" => "external",
            "provider" => "codex",
            "runtime_id" => "runtime-codex",
            "device_runtime_id" =>
              RuntimeIds.device_runtime_id(stable_device_id, "codex", "runtime-codex"),
            "command" => "/usr/local/bin/codex",
            "version" => "codex-test",
            "version_detected" => true,
            "auth_ready" => true,
            "native_server_startable" => true,
            "ready" => true,
            "readiness_checked_at" => System.system_time(:millisecond),
            "readiness_valid_until" => System.system_time(:millisecond) + 600_000
          }
        ])
      end)

    connector_run_id
  end

  defp reconnect_codex_device!(group_id, connector_run_id) do
    {:ok, _transport_id, device} = Registry.get_by_connector_run_id(connector_run_id)
    transport_id = "env-runtime-proxy-reconnect-#{System.unique_integer([:positive])}"

    {:ok, ^transport_id, reconnected} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => tenant_id(),
          "group_id" => group_id,
          "device_id" => device["device_id"],
          "connector_id" => device["connector_id"],
          "name" => "Runtime Proxy Device"
        },
        transport_id: transport_id
      )

    reconnected["connector_run_id"]
  end

  defp codex_runtime_config(env_id) do
    %{
      "kind" => "external",
      "provider" => "codex",
      "device_id" => device_id(env_id),
      "runtime_id" => "runtime-codex",
      "device_runtime_id" => device_runtime_id(env_id)
    }
  end

  defp device_id(connector_run_id) do
    {:ok, _transport_id, device} = Registry.get_by_connector_run_id(connector_run_id)
    device["device_id"]
  end

  defp device_runtime_id(env_id),
    do: RuntimeIds.device_runtime_id(device_id(env_id), "codex", "runtime-codex")

  defp start_bandit_retry!(spec_fun) do
    Enum.find_value(1..10, fn _ ->
      p = 40_000 + :erlang.phash2(make_ref(), 20_000)

      case ExUnit.Callbacks.start_supervised(spec_fun.(p), id: {:bandit_retry, p}) do
        {:ok, _pid} -> p
        {:error, _} -> nil
      end
    end) || raise "could not bind a test port after 10 attempts"
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
