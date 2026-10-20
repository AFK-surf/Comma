defmodule SalixWeb.RuntimeProxyTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.MeetingLLMCapability
  alias SalixWeb.RuntimeProxy

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
    prev_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, prev_store) end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Runtime proxy"})
    Process.put(:test_tenant_id, tenant["tenant_id"])

    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Runtime"}, tenant_id())
    group_id = group["group_id"]

    {:ok, agent} =
      SalixAgent.Control.create(%{"group_id" => group_id, "name" => "Runtime"}, tenant_id())

    env_id = "connector-run-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, capability} =
      MeetingLLMCapability.mint(
        %{"tenant_id" => tenant_id(), "group_id" => group_id, "agent_id" => agent["agent_id"]},
        SalixStore.Ids.new_session_id(),
        env_id
      )

    {:ok,
     group_id: group_id, env_id: env_id, agent_id: agent["agent_id"], token: capability["token"]}
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  test "meeting LLM capability is bound to the connector run that received it", %{
    group_id: group_id,
    token: token
  } do
    {status, body} =
      proxy_json(
        "other-env",
        token,
        "POST",
        "/llm/chat",
        %{"messages" => [%{"role" => "user", "content" => "hi"}]},
        %{"tenant_id" => tenant_id(), "group_id" => group_id}
      )

    assert status == 401
    assert body == %{"error" => "unauthorized"}
  end

  test "POST /llm/chat with an LLM capability returns a completion (200)", %{
    env_id: env_id,
    group_id: group_id,
    token: token
  } do
    port = start_bandit_retry!(fn p -> {Bandit, plug: FakeLLM, port: p} end)

    SalixAgent.TestSupport.configure_platform_tier!(
      "worker",
      "http://127.0.0.1:#{port}",
      "test-model",
      %{"max_tokens" => 2048}
    )

    prev_skip = SystemsRuntime.get_env(:salix_web, :connector_llm_skip_metering)
    SystemsRuntime.put_env(:salix_web, :connector_llm_skip_metering, true)

    on_exit(fn ->
      if is_nil(prev_skip),
        do: SystemsRuntime.delete_env(:salix_web, :connector_llm_skip_metering),
        else: SystemsRuntime.put_env(:salix_web, :connector_llm_skip_metering, prev_skip)
    end)

    {status, body} =
      proxy_json(
        env_id,
        token,
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

  defp start_bandit_retry!(spec_fun) do
    Enum.find_value(1..10, fn _ ->
      p = 40_000 + :erlang.phash2(SystemsRuntime.Proc.make_ref(), 20_000)

      case ExUnit.Callbacks.start_supervised(spec_fun.(p), id: {:bandit_retry, p}) do
        {:ok, _pid} -> p
        {:error, _} -> nil
      end
    end) || raise "could not bind a test port after 10 attempts"
  end
end
