# E2E validation for group OAuth credential availability.
#
# Run through Deno:
#   deno test --allow-all e2e/tests/oauth_dynamic_visibility_test.ts

defmodule OAuthDynamicVisibilityE2E.MockProvider do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    case {conn.method, conn.request_path} do
      {"GET", "/login/oauth/authorize"} ->
        authorize(conn)

      {"POST", "/login/oauth/access_token"} ->
        json(conn, %{
          "access_token" => "gh-e2e-token",
          "token_type" => "bearer",
          "scope" => "repo"
        })

      {"GET", "/user"} ->
        json(conn, %{"id" => 37_200, "login" => "octocat-e2e", "name" => "Octo E2E"})

      _ ->
        send_resp(conn, 404, "not found")
    end
  end

  defp authorize(conn) do
    redirect_uri = conn.query_params["redirect_uri"]
    state = conn.query_params["state"]

    cond do
      blank?(redirect_uri) ->
        send_resp(conn, 400, "redirect_uri required")

      blank?(state) ->
        send_resp(conn, 400, "state required")

      true ->
        location =
          redirect_uri <>
            redirect_joiner(redirect_uri) <>
            URI.encode_query(%{"state" => state, "code" => "mock-code"})

        conn
        |> put_resp_header("location", location)
        |> send_resp(302, "")
    end
  end

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  defp redirect_joiner(uri) do
    if URI.parse(uri).query in [nil, ""], do: "?", else: "&"
  end

  defp blank?(value), do: !is_binary(value) or String.trim(value) == ""
end

defmodule OAuthDynamicVisibilityE2E do
  @moduledoc false

  alias Salix.Control.{Groups, Tenants}

  @provider "github"
  @env_alias "oauth-e2e"
  @tool_result_timeout_ms 30_000

  def run do
    Process.put(:oauth_dynamic_visibility_session_id, SalixStore.Ids.new_session_id())
    bin = required_env!("SALIX_CONNECT_BIN")
    {mock_pid, mock_base} = start_mock_provider!()
    root = tmp_dir!("oauth-dynamic-e2e-") |> realpath!()

    Application.put_env(:salix_store, :oauth_endpoint_overrides, %{
      @provider => %{
        "authorize_url" => mock_base <> "/login/oauth/authorize",
        "token_url" => mock_base <> "/login/oauth/access_token",
        "api_url" => mock_base
      }
    })

    try do
      tenant_id = create_tenant!()
      Process.put(:oauth_dynamic_visibility_tenant_id, tenant_id)
      tenant_key = create_tenant_api_key!(tenant_id)
      group_id = create_group!(tenant_id)
      agent_id = create_agent!(tenant_id, group_id)
      ensure_session!(agent_id)

      token = mint_connector_token!(group_id, tenant_key)
      connector = start_connector!(bin, token, root)

      try do
        target = wait_for_env!(agent_id)
        configure_provider_app!(tenant_key)
        binding = authorize_binding!(tenant_key, group_id, "default")
        assert_enabled_binding!(tenant_key, group_id, binding["binding_id"], true)
        assert_oauth_list!(agent_id, "default", true)
        assert_exec_credential!(agent_id, target, "default", "OAUTH_ENABLED_OK")

        set_binding_enabled!(tenant_key, group_id, binding["binding_id"], false)
        assert_enabled_binding!(tenant_key, group_id, binding["binding_id"], false)
        assert_oauth_list!(agent_id, "default", false)
        assert_disabled_exec_rejected!(agent_id, target, "default")

        set_binding_enabled!(tenant_key, group_id, binding["binding_id"], true)
        assert_enabled_binding!(tenant_key, group_id, binding["binding_id"], true)
        assert_exec_credential!(agent_id, target, "default", "OAUTH_REENABLED_OK")

        IO.puts("OAUTH_DYNAMIC_VISIBILITY_E2E: PASS")
      after
        if is_port(connector), do: Port.close(connector)
      end
    after
      File.rm_rf(root)
      if is_pid(mock_pid), do: Process.exit(mock_pid, :shutdown)
    end
  end

  defp start_mock_provider! do
    {:ok, pid} =
      Bandit.start_link(
        plug: OAuthDynamicVisibilityE2E.MockProvider,
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    Process.unlink(pid)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {pid, "http://127.0.0.1:#{port}"}
  end

  defp create_tenant! do
    case Tenants.create(%{"name" => "OAuth E2E"}) do
      {:ok, %{"tenant_id" => tenant_id}} -> tenant_id
      {:error, reason} -> raise("tenant create failed: #{inspect(reason)}")
    end
  end

  defp create_tenant_api_key!(tenant_id) do
    case Tenants.create_api_key(tenant_id, %{"name" => "oauth-dynamic-e2e"}) do
      {:ok, %{"key" => key}} -> key
      {:error, reason} -> raise("tenant api key create failed: #{inspect(reason)}")
    end
  end

  defp create_group!(tenant_id) do
    case Groups.create(%{"name" => "OAuth Dynamic E2E"}, tenant_id) do
      {:ok, %{"group_id" => group_id}} -> group_id
      {:error, reason} -> raise("group create failed: #{inspect(reason)}")
    end
  end

  defp create_agent!(tenant_id, group_id) do
    case SalixAgent.Control.create(
           %{
             "group_id" => group_id,
             "name" => "oauth-dynamic-e2e",
             "role" => "worker",
             "runtime_config" => %{"kind" => "internal"}
           },
           tenant_id
         ) do
      {:ok, %{"agent_id" => agent_id}} -> agent_id
      {:error, reason} -> raise("agent create failed: #{inspect(reason)}")
    end
  end

  defp ensure_session!(agent_id) do
    case SalixAgent.deliver(
           agent_id,
           %{
             "session_id" => session_id!(),
             "role" => "user",
             "content" => "oauth dynamic visibility e2e setup"
           },
           source_message_id: "oauth-dynamic-e2e-setup-#{agent_id}",
           no_wake: true
         ) do
      {:ok, _status} -> :ok
      {:error, reason} -> raise("session setup failed: #{inspect(reason)}")
    end
  end

  defp mint_connector_token!(group_id, tenant_key) do
    resp =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/connector-tokens",
        json: %{"name" => "OAuth E2E", "alias" => @env_alias, "expires_in_seconds" => 3600}
      )

    assert_status!(resp, 201, "connector token")
    resp.body["token"] || raise("connector token response did not include token")
  end

  defp start_connector!(bin, token, root) do
    args = [
      "--server",
      SalixWeb.Application.base_url(),
      "--connector-token",
      token,
      "--name",
      "OAuth E2E",
      "--alias",
      @env_alias,
      "--root",
      root,
      "--reconnect=false"
    ]

    Port.open({:spawn_executable, bin}, [
      :binary,
      :exit_status,
      {:args, args},
      {:env, [{~c"SALIX_API_TOKEN", false}, {~c"SALIX_CONNECTOR_TOKEN", false}]}
    ])
  end

  defp wait_for_env!(agent_id, attempts \\ 200)

  defp wait_for_env!(_agent_id, 0), do: raise("timed out waiting for #{@env_alias}")

  defp wait_for_env!(agent_id, attempts) do
    case SalixWeb.EnvDispatch.list_envs(agent_id) do
      {:ok, envs} ->
        case Enum.find(envs, &(&1["alias"] == @env_alias)) do
          %{
            "device_id" => device_id,
            "environment_id" => environment_id,
            "status" => "connected"
          }
          when is_binary(device_id) and device_id != "" and
                 is_binary(environment_id) and environment_id != "" ->
            %{device_id: device_id, environment_id: environment_id}

          _ ->
            Process.sleep(50)
            wait_for_env!(agent_id, attempts - 1)
        end

      {:error, _reason} ->
        Process.sleep(50)
        wait_for_env!(agent_id, attempts - 1)
    end
  end

  defp configure_provider_app!(tenant_key) do
    resp =
      treq!(tenant_key, :put, "/v1/runtime/oauth/provider-apps/#{@provider}",
        json: %{client_id: "gh-e2e-client", client_secret: "gh-e2e-secret"}
      )

    assert_status!(resp, 200, "provider app")
  end

  defp authorize_binding!(tenant_key, group_id, alias_name) do
    start =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/oauth/#{@provider}/authorize",
        json: %{"alias" => alias_name, "scopes" => ["repo"]}
      )

    assert_status!(start, 200, "oauth authorize start")

    auth_url = start.body["authorization_url"] || raise("authorization_url missing")
    provider = Req.get!(auth_url, redirect: false, retry: false)
    assert_status!(provider, 302, "mock provider authorize")

    callback_url = response_header!(provider, "location")
    callback = Req.get!(callback_url, redirect: false, retry: false)

    unless callback.status in [200, 303] do
      raise("oauth callback failed: #{callback.status} #{inspect(callback.body)}")
    end

    [binding] =
      tenant_key
      |> list_bindings!(group_id)
      |> Enum.filter(&(&1["provider"] == @provider and &1["alias"] == alias_name))

    binding
  end

  defp set_binding_enabled!(tenant_key, group_id, binding_id, enabled) do
    resp =
      treq!(
        tenant_key,
        :patch,
        "/v1/runtime/agent-groups/#{group_id}/oauth-connections/#{binding_id}",
        json: %{"enabled" => enabled}
      )

    assert_status!(resp, 200, "set binding enabled=#{enabled}")
  end

  defp assert_enabled_binding!(tenant_key, group_id, binding_id, expected) do
    binding =
      tenant_key
      |> list_bindings!(group_id)
      |> Enum.find(&(&1["binding_id"] == binding_id))

    unless is_map(binding) do
      raise("binding #{binding_id} not found")
    end

    unless binding["enabled"] == expected do
      raise("binding enabled mismatch: expected #{expected}, got #{inspect(binding)}")
    end
  end

  defp assert_oauth_list!(agent_id, alias_name, expected_enabled) do
    result = execute_tool!(agent_id, "oauth.list_credentials", %{})
    body = Jason.decode!(result.content)

    credential =
      body["credentials"]
      |> Enum.find(&(&1["provider"] == @provider and &1["alias"] == alias_name))

    unless is_map(credential) do
      raise("credential #{@provider}/#{alias_name} not listed: #{result.content}")
    end

    unless credential["enabled"] == expected_enabled do
      raise(
        "credential enabled mismatch: expected #{expected_enabled}, got #{inspect(credential)}"
      )
    end

    if expected_enabled and not is_binary(credential["usage"]) do
      raise("enabled credential missing usage hint: #{inspect(credential)}")
    end

    if not expected_enabled and Map.has_key?(credential, "usage") do
      raise("disabled credential must not include usage hint: #{inspect(credential)}")
    end
  end

  defp assert_exec_credential!(agent_id, target, alias_name, marker) do
    result =
      execute_tool!(agent_id, "env.exec", %{
        "device_id" => target.device_id,
        "environment" => target.environment_id,
        "description" => "oauth env check",
        "command" => "[ -n \"$GH_TOKEN\" ] && printf #{marker}",
        "credential_env" => [
          %{
            "env_var" => "GH_TOKEN",
            "provider" => @provider,
            "alias" => alias_name,
            "value" => "access_token"
          }
        ]
      })

    decoded = Jason.decode!(result.content)

    unless decoded["exit_code"] == 0 and decoded["stdout"] == marker do
      raise("env.exec did not observe injected credential: #{inspect(decoded)}")
    end

    if result.content =~ "gh-e2e-token" do
      raise("env.exec result leaked token")
    end
  end

  defp assert_disabled_exec_rejected!(agent_id, target, alias_name) do
    result =
      execute_tool!(agent_id, "env.exec", %{
        "device_id" => target.device_id,
        "environment" => target.environment_id,
        "description" => "disabled oauth",
        "command" => "[ -n \"$GH_TOKEN\" ] && printf SHOULD_NOT_RUN",
        "credential_env" => [
          %{
            "env_var" => "GH_TOKEN",
            "provider" => @provider,
            "alias" => alias_name,
            "value" => "access_token"
          }
        ]
      })

    unless result.error == true and result.content =~ "is disabled" do
      raise("disabled credential was not rejected correctly: #{inspect(result)}")
    end
  end

  defp execute_tool!(agent_id, tool_name, attrs) do
    case SalixAgent.Runtime.execute_session_tool(
           agent_id,
           session_id!(),
           tool_name,
           attrs,
           Process.get(:oauth_dynamic_visibility_tenant_id) ||
             raise("OAuth E2E tenant identity is unavailable")
         ) do
      {:ok, result} -> await_tool_result!(agent_id, tool_name, result)
      {:error, reason} -> raise("#{tool_name} failed: #{inspect(reason)}")
    end
  end

  defp await_tool_result!(agent_id, tool_name, result) do
    if tool_running?(result) do
      tool_call_id =
        result[:id] || result["id"] || result[:tool_call_id] || result["tool_call_id"]

      unless is_binary(tool_call_id) and tool_call_id != "" do
        raise("#{tool_name} returned a running result without tool_call_id: #{inspect(result)}")
      end

      deadline = System.monotonic_time(:millisecond) + @tool_result_timeout_ms
      poll_tool_result!(agent_id, tool_name, tool_call_id, deadline)
    else
      result
    end
  end

  defp poll_tool_result!(agent_id, tool_name, tool_call_id, deadline) do
    case SalixAgent.Runtime.get_async_tool_call(agent_id, session_id!(), tool_call_id) do
      {:ok, %{"status" => status} = record} when status in ["completed", "failed"] ->
        stored = record["result"] || %{}

        %{
          content: stored["content"] || record["error_message"] || "",
          error: status == "failed" or stored["error"] in [true, "true", 1]
        }

      {:ok, %{"status" => "cancelled"} = record} ->
        %{
          content: record["cancel_reason"] || "session tool was cancelled",
          error: true
        }

      {:ok, _running} ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise("#{tool_name} timed out waiting for async tool call #{tool_call_id}")
        end

        Process.sleep(10)
        poll_tool_result!(agent_id, tool_name, tool_call_id, deadline)

      {:error, reason} ->
        raise("#{tool_name} async result #{tool_call_id} failed: #{inspect(reason)}")
    end
  end

  defp tool_running?(result),
    do:
      (result[:status] || result["status"]) in [
        "async_running",
        :async_running,
        "running",
        :running
      ]

  defp session_id! do
    Process.get(:oauth_dynamic_visibility_session_id) ||
      raise("OAuth E2E session identity is unavailable")
  end

  defp list_bindings!(tenant_key, group_id) do
    resp = treq!(tenant_key, :get, "/v1/runtime/agent-groups/#{group_id}/oauth-connections")
    assert_status!(resp, 200, "list bindings")
    resp.body
  end

  defp treq!(tenant_key, method, path, opts \\ []) do
    Req.request!(
      [
        method: method,
        url: SalixWeb.Application.base_url() <> path,
        headers: [{"authorization", "Bearer " <> tenant_key}],
        redirect: false,
        retry: false
      ] ++ opts
    )
  end

  defp response_header!(resp, name) do
    case resp.headers[String.downcase(name)] do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> raise("response header #{name} missing in #{inspect(resp.headers)}")
    end
  end

  defp assert_status!(resp, expected, label) do
    unless resp.status == expected do
      raise("#{label} expected status #{expected}, got #{resp.status}: #{inspect(resp.body)}")
    end
  end

  defp tmp_dir!(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        prefix <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp realpath!(path) do
    case System.cmd("pwd", ["-P"], cd: path, stderr_to_stdout: true) do
      {realpath, 0} -> String.trim(realpath)
      {output, code} -> raise("failed to resolve #{path}: #{String.trim(output)} code=#{code}")
    end
  end

  defp required_env!(name), do: System.get_env(name) || raise("#{name} is required")
end

try do
  OAuthDynamicVisibilityE2E.run()
catch
  kind, reason ->
    IO.puts(:stderr, Exception.format(kind, reason, __STACKTRACE__))
    System.halt(1)
end
