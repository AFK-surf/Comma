defmodule MCPRuntimeE2E do
  @moduledoc false

  import Plug.Conn
  import Plug.Test

  @opts SalixWeb.Router.init([])
  @admin_token "test-token"
  @session_id SalixStore.Ids.new_session_id()

  defmodule MockOAuthCredentialResolver do
    @behaviour SalixMCP.Credentials

    @impl true
    def resolve(%{"oauth_binding_refs" => refs} = binding) when is_map(refs) do
      alias_name = to_string(binding["alias"] || "binding")

      refs =
        refs
        |> stringify()
        |> Map.new(fn {name, ref} ->
          env_name = to_string(ref["env_var"] || name)
          {env_name, "mock-oauth-token-#{alias_name}"}
        end)

      {:ok, refs}
    end

    def resolve(_binding), do: {:ok, %{}}

    defp stringify(value) when is_map(value),
      do: Map.new(value, fn {key, value} -> {to_string(key), stringify(value)} end)

    defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
    defp stringify(value), do: value
  end

  def run do
    setup_runtime!()

    run_id = unique()
    tenant_key = create_tenant_key!()
    alias_name = "context7-#{run_id}"
    device_alias = "mcp-device-#{run_id}"

    group =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups", %{
        "name" => "MCP #{run_id}"
      })

    group_id = group["group_id"]

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "group_id" => group_id,
          "role" => "worker",
          "name" => "MCP E2E"
        },
        tenant_id()
      )

    agent_id = agent["agent_id"]

    ensure_session!(tenant_key, agent_id, @session_id, run_id)
    assert_builtin_definitions!(tenant_key)
    assert_agent_autonomous_mcp_management!(tenant_key, group_id, agent_id, run_id)

    def_resp =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "Context7 #{run_id}",
        "url" => remote_url(),
        "transport" => "streamable-http",
        "supports_server" => true
      })

    mcp_id = def_resp["mcp_id"]
    assert_snowflake_id!(mcp_id, "mcp1", "created MCP definition id")
    target_ref = first_target_ref!(def_resp)

    bind_resp =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => mcp_id,
        "alias" => alias_name,
        "target_ref" => target_ref,
        "placement" => "server",
        "config_values" => config_values()
      })

    binding_id = bind_resp["binding_id"]
    assert_snowflake_id!(binding_id, "mpb1", "created MCP binding id")

    conn =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding_id}/discover",
        %{}
      )

    assert!(conn["status"] in ["running", "degraded"], "connection did not run: #{inspect(conn)}")
    assert_connection_metadata!(conn, "Context7 remote")

    tools = get_in(conn, ["discovered", "tools"]) || []
    assert!(tools != [], "no MCP tools discovered: #{inspect(conn)}")

    mcp_tools = mcp_operation_tools!(tenant_key, agent_id, alias_name)

    assert!(mcp_tools != [], "MCP tools were not listed with canonical operation ids")

    _help_payload = tool_help!(tenant_key, agent_id, List.first(mcp_tools)["operation_id"])

    bindings_result =
      session_tool_result!(tenant_key, agent_id, "mcp.list", %{})

    assert!(
      bindings_result.error == false,
      "mcp.list failed: #{inspect(bindings_result)}"
    )

    bindings_payload = bindings_result.body

    listed_operation_ids =
      bindings_payload["bindings"]
      |> List.wrap()
      |> Enum.flat_map(&(get_in(&1, ["connection", "discovered", "tools"]) || []))
      |> Enum.map(& &1["operation_id"])
      |> Enum.reject(&is_nil/1)

    assert!(
      Enum.any?(listed_operation_ids, &String.starts_with?(&1, "mcp.#{alias_name}.")),
      "mcp.list did not expose canonical MCP operation ids: #{inspect(bindings_payload)}"
    )

    call_tool =
      Enum.find(mcp_tools, &String.contains?(&1["operation_id"], "resolve")) ||
        Enum.find(mcp_tools, &String.contains?(&1["operation_id"], "library")) ||
        List.first(mcp_tools)

    call_result =
      session_tool_result!(
        tenant_key,
        agent_id,
        call_tool["operation_id"],
        call_params_from_help!(tenant_key, agent_id, call_tool)
      )

    assert!(call_result.error == false, "MCP call failed: #{inspect(call_result)}")

    assert_pat_remote_path!(tenant_key, group_id, agent_id, run_id)
    assert_oauth_ref_remote_path!(tenant_key, group_id, agent_id, run_id)

    disabled =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding_id}/disable",
        %{}
      )

    assert!(disabled["enabled"] == false, "disable did not persist: #{inspect(disabled)}")

    disabled_call =
      session_tool_result!(
        tenant_key,
        agent_id,
        call_tool["operation_id"],
        call_params(call_tool)
      )

    assert!(
      disabled_call.error == true or get_in(disabled_call.body, ["status"]) == "guidance",
      "disabled binding remained callable: #{inspect(disabled_call)}"
    )

    assert_secret_boundary!(tenant_key, group_id, run_id)
    assert_server_metadata_normalization!(tenant_key, group_id, run_id)
    assert_server_package_policy!(tenant_key, group_id, agent_id, run_id)
    assert_supabase_missing_config!(tenant_key, group_id, run_id)

    root = Path.join(System.tmp_dir!(), "mcp-runtime-e2e-#{run_id}")
    File.mkdir_p!(root)
    connector = start_connector!(tenant_key, group_id, device_alias, root)

    try do
      {device_runtime, connector_run_id} =
        run_e2e_step!("device waiting for connector runtime", fn ->
          wait_for_connector_device_runtime!(group_id, device_alias)
        end)

      Process.put(:device_mcp_connector_run_id, connector_run_id)

      run_e2e_step!("device github secret boundary", fn ->
        assert_github_secret_boundary!(tenant_key, group_id, device_runtime, run_id)
      end)

      run_e2e_step!("device root grant boundary", fn ->
        assert_device_root_grant_boundary!(tenant_key, group_id, device_runtime, run_id, root)
      end)

      run_e2e_step!("device discovery error secret boundary", fn ->
        assert_device_discovery_error_secret_boundary!(
          tenant_key,
          group_id,
          agent_id,
          device_runtime,
          run_id,
          root
        )
      end)

      run_e2e_step!("device package MCP", fn ->
        assert_device_package_mcp!(tenant_key, group_id, agent_id, device_runtime, run_id)
      end)

      run_e2e_step!("device tool error boundary", fn ->
        assert_device_tool_error_does_not_poison_connection!(
          tenant_key,
          group_id,
          agent_id,
          device_runtime,
          run_id,
          root
        )
      end)

      run_e2e_step!("device async MCP", fn ->
        assert_device_async_mcp!(tenant_key, group_id, agent_id, device_runtime, run_id, root)
      end)

      run_e2e_step!("device playwright MCP", fn ->
        assert_playwright_device_mcp!(tenant_key, group_id, agent_id, device_runtime, run_id)
      end)

      run_e2e_step!("device filesystem MCP", fn ->
        assert_filesystem_root_mcp!(tenant_key, group_id, agent_id, device_runtime, run_id, root)
      end)

      run_e2e_step!("device disconnect recovery", fn ->
        assert_device_disconnect_recovery!(
          tenant_key,
          group_id,
          agent_id,
          device_alias,
          connector,
          root
        )
      end)
    after
      stop_connector(connector)
      File.rm_rf(root)
    end

    IO.puts("MCP_RUNTIME_E2E: PASS run_id=#{run_id} binding_id=#{binding_id}")
  end

  defp run_e2e_step!(label, fun) do
    IO.puts("MCP_RUNTIME_E2E: #{label}")

    result = fun.()
    IO.puts("MCP_RUNTIME_E2E: #{label} done")
    result
  rescue
    e ->
      raise "MCP_RUNTIME_E2E step #{label} failed: #{Exception.message(e)}"
  catch
    kind, reason ->
      raise "MCP_RUNTIME_E2E step #{label} exited: #{inspect({kind, reason})}"
  end

  defp setup_runtime! do
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_web, :api_token, @admin_token)
    Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)

    {:ok, _} = Application.ensure_all_started(:salix_web)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      {:ok, _} = SalixStore.S3.Fake.start_link([])
    end

    {:ok, _count} = SalixMCP.Builtins.seed_builtin_definitions()
    Salix.App.configure()
  end

  defp create_tenant_key! do
    tenant = req!(:post, "/v1/admin/tenants", %{"name" => "MCP E2E"})
    Process.put(:tenant_id, tenant["tenant_id"])
    key = req!(:post, "/v1/admin/tenants/#{tenant["tenant_id"]}/api-keys", %{"name" => "e2e"})
    key["key"]
  end

  defp req!(method, path, body) do
    conn =
      conn(method, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{@admin_token}")
      |> SalixWeb.Router.call(@opts)

    decode_ok!(conn)
  end

  defp treq!(tenant_key, method, path, body),
    do: tenant_key |> treq_conn(method, path, body) |> decode_ok!()

  defp treq_conn(tenant_key, method, path, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{tenant_key}")
    |> SalixWeb.Router.call(@opts)
  end

  defp decode_ok!(conn) do
    body = Jason.decode!(conn.resp_body || "{}")
    assert!(conn.status in 200..299, "#{conn.status}: #{inspect(body)}")
    body
  end

  defp ensure_session!(tenant_key, agent_id, session_id, run_id) do
    attrs = %{
      "name" => "MCP runtime E2E #{run_id}",
      "hidden" => true,
      "created_at" => System.system_time(:second)
    }

    case SalixAgent.InternalSessionStore.prepare_create(agent_id, session_id, attrs) do
      {:ok, _} -> :ok
      {:error, :exists} -> :ok
      other -> raise("session prepare_create failed: #{inspect(other)}")
    end

    wait_for_session!(tenant_key, agent_id, session_id)
  end

  defp wait_for_session!(tenant_key, agent_id, session_id, attempts \\ 50)

  defp wait_for_session!(tenant_key, agent_id, session_id, attempts) when attempts > 0 do
    conn =
      treq_conn(tenant_key, :get, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}", %{})

    if conn.status in 200..299 do
      decode_ok!(conn)
    else
      Process.sleep(100)
      wait_for_session!(tenant_key, agent_id, session_id, attempts - 1)
    end
  end

  defp wait_for_session!(tenant_key, agent_id, session_id, _attempts) do
    conn =
      treq_conn(tenant_key, :get, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}", %{})

    raise(
      "session #{session_id} was not created for #{agent_id}: #{conn.status} #{conn.resp_body}"
    )
  end

  defp session_tool_result!(tenant_key, agent_id, tool_name, attrs) do
    conn =
      treq_conn(
        tenant_key,
        :post,
        "/v1/runtime/agents/#{agent_id}/sessions/#{@session_id}/tools/#{tool_name}",
        attrs
      )

    body =
      case Jason.decode(conn.resp_body || "{}") do
        {:ok, decoded} -> decoded
        {:error, _} -> %{"result" => conn.resp_body || ""}
      end

    content =
      cond do
        is_binary(body["result"]) -> body["result"]
        Map.has_key?(body, "result") -> Jason.encode!(body["result"])
        is_binary(body["error"]) -> body["error"]
        Map.has_key?(body, "error") -> Jason.encode!(body["error"])
        true -> Jason.encode!(body)
      end

    %{status: conn.status, error: conn.status >= 400, body: body, content: content}
  end

  defp mcp_operation_tools!(tenant_key, agent_id, alias_name) do
    result = session_tool_result!(tenant_key, agent_id, "mcp.list", %{"kind" => "tools"})
    assert!(result.error == false, "mcp.list failed: #{inspect(result)}")

    result.body["tools"]
    |> List.wrap()
    |> Enum.filter(fn tool ->
      assert!(
        not Map.has_key?(tool, "inputSchema") and not Map.has_key?(tool, "input_schema"),
        "mcp.list must not expose detailed tool schema; use help for schema: #{inspect(tool)}"
      )

      tool["operation_id"]
      |> to_string()
      |> String.starts_with?("mcp.#{alias_name}.")
    end)
  end

  defp tool_help!(tenant_key, agent_id, operation_id) do
    result =
      session_tool_result!(tenant_key, agent_id, "help", %{
        "tool" => operation_id
      })

    assert!(result.error == false, "help failed for #{operation_id}: #{inspect(result)}")

    assert!(
      is_map(result.body["input_schema"]),
      "help did not return input_schema: #{inspect(result.body)}"
    )

    result.body
  end

  defp call_params_from_help!(tenant_key, agent_id, %{"operation_id" => operation_id}) do
    tool_help!(tenant_key, agent_id, operation_id)
    |> call_params()
  end

  defp assert_connection_metadata!(conn, label) do
    assert!(
      is_binary(conn["protocol_version"]) and conn["protocol_version"] != "",
      "#{label} did not record negotiated protocol version: #{inspect(conn)}"
    )

    assert!(
      is_map(conn["capabilities"]),
      "#{label} did not record MCP capabilities: #{inspect(conn)}"
    )

    assert!(
      is_map(conn["server_info"]),
      "#{label} did not record MCP server info: #{inspect(conn)}"
    )
  end

  defp call_params(%{"inputSchema" => schema}) when is_map(schema),
    do: call_params(%{"input_schema" => schema})

  defp call_params(%{"input_schema" => %{"properties" => props, "required" => required}})
       when is_map(props) and is_list(required) do
    required
    |> Enum.map(&to_string/1)
    |> Map.new(fn key ->
      {key, if(String.contains?(String.downcase(key), "library"), do: "react", else: "react")}
    end)
  end

  defp call_params(_tool), do: %{"libraryName" => "react"}

  defp assert_builtin_definitions!(tenant_key) do
    definitions = treq!(tenant_key, :get, "/v1/runtime/mcp/definitions", %{})
    ids = Enum.map(definitions, & &1["mcp_id"])

    for expected <- [
          "mcp1_0000000000000000001",
          "mcp1_0000000000000000002",
          "mcp1_0000000000000000003"
        ] do
      assert!(expected in ids, "missing built-in MCP definition #{expected}: #{inspect(ids)}")
    end
  end

  defp assert_snowflake_id!(id, prefix, label) do
    assert!(
      is_binary(id) and Regex.match?(~r/^#{Regex.escape(prefix)}_[0-9]{19}$/, id),
      "#{label} must use #{prefix}_<19 digit snowflake>: #{inspect(id)}"
    )
  end

  defp assert_agent_autonomous_mcp_management!(tenant_key, group_id, agent_id, run_id) do
    definition_args = %{
      "name" => "Agent Managed Context7 #{run_id}",
      "url" => remote_url(),
      "transport" => "streamable-http",
      "supports_server" => true
    }

    definition_result =
      session_tool_completed_result!(
        tenant_key,
        agent_id,
        "mcp_manager.definition_create",
        definition_args
      )

    assert!(
      definition_result.error == false and is_map(definition_result.body["definition"]),
      "mcp_manager.definition_create did not execute directly: #{inspect(definition_result)}"
    )

    definition = definition_result.body["definition"]
    assert_snowflake_id!(definition["mcp_id"], "mcp1", "agent-created MCP definition id")

    binding_args = %{
      "mcp_id" => definition["mcp_id"],
      "alias" => "agent-managed-#{run_id}",
      "target_ref" => first_target_ref!(definition),
      "placement" => "server",
      "config_values" =>
        Map.put(config_values(), "E2E_SECRET_TOKEN", "autonomous-mcp-secret-#{run_id}")
    }

    binding_result =
      session_tool_completed_result!(
        tenant_key,
        agent_id,
        "mcp_manager.connect",
        binding_args
      )

    assert!(
      binding_result.error == false and is_map(binding_result.body["binding"]),
      "mcp_manager.connect did not execute directly: #{inspect(binding_result)}"
    )

    binding_id = binding_result.body["binding"]["binding_id"]
    assert_snowflake_id!(binding_id, "mpb1", "agent-created MCP binding id")

    update_args = %{
      "binding_id" => binding_id,
      "alias" => "agent-managed-renamed-#{run_id}"
    }

    update_result =
      session_tool_completed_result!(
        tenant_key,
        agent_id,
        "mcp_manager.update",
        update_args
      )

    assert!(
      update_result.error == false and
        get_in(update_result.body, ["binding", "alias"]) ==
          "agent-managed-renamed-#{run_id}",
      "mcp_manager.update did not execute directly: #{inspect(update_result)}"
    )

    disabled =
      session_tool_completed_result!(
        tenant_key,
        agent_id,
        "mcp_manager.set_enabled",
        %{"binding_id" => binding_id, "enabled" => false}
      )

    assert!(
      get_in(disabled.body, ["binding", "enabled"]) == false,
      "mcp_manager.set_enabled did not disable directly: #{inspect(disabled)}"
    )

    enabled =
      session_tool_completed_result!(
        tenant_key,
        agent_id,
        "mcp_manager.set_enabled",
        %{"binding_id" => binding_id, "enabled" => true}
      )

    assert!(
      get_in(enabled.body, ["binding", "enabled"]) == true,
      "mcp_manager.set_enabled did not enable directly: #{inspect(enabled)}"
    )

    requests =
      treq!(tenant_key, :get, "/v1/runtime/agent-groups/#{group_id}/capability-requests", %{})
      |> Map.get("data", [])

    assert!(
      Enum.all?(requests, &(&1["request_type"] != "mcp_management")),
      "autonomous MCP management created a capability request: #{inspect(requests)}"
    )

    assert!(
      not String.contains?(Jason.encode!(requests), "autonomous-mcp-secret"),
      "capability request projection leaked an MCP config secret: #{inspect(requests)}"
    )
  end

  defp assert_secret_boundary!(tenant_key, group_id, run_id) do
    secret = "mcp-secret-#{run_id}"
    alias_name = "secret-boundary-#{run_id}"

    definition =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "Secret Boundary #{run_id}",
        "url" => "https://mcp.context7.com/mcp",
        "headers" => %{"Authorization" => "Bearer ${MCP_E2E_TOKEN}"}
      })

    encoded_definition = Jason.encode!(definition)
    assert!(not String.contains?(encoded_definition, secret), "definition leaked secret value")

    raw_oauth_ref =
      treq_conn(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => "bad-oauth-ref-#{run_id}",
        "target_ref" => first_target_ref!(definition),
        "placement" => "server",
        "oauth_binding_refs" => %{
          "MCP_E2E_TOKEN" => %{
            "provider" => "github",
            "alias" => "default",
            "value" => secret
          }
        }
      })

    assert!(raw_oauth_ref.status == 400, "raw OAuth ref value should be rejected")

    assert!(
      not String.contains?(raw_oauth_ref.resp_body || "", secret),
      "raw OAuth ref rejection leaked secret"
    )

    raw_oauth_string =
      treq_conn(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => "bad-oauth-string-#{run_id}",
        "target_ref" => first_target_ref!(definition),
        "placement" => "server",
        "oauth_binding_refs" => %{"MCP_E2E_TOKEN" => secret}
      })

    assert!(raw_oauth_string.status == 400, "bare OAuth ref string should name provider/alias")

    assert!(
      not String.contains?(raw_oauth_string.resp_body || "", secret),
      "bare OAuth ref rejection leaked secret"
    )

    missing_oauth_target =
      treq_conn(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => "bad-oauth-target-#{run_id}",
        "target_ref" => first_target_ref!(definition),
        "placement" => "server",
        "oauth_binding_refs" => %{
          "MCP_E2E_TOKEN" => %{"credential" => "access_token"}
        }
      })

    assert!(
      missing_oauth_target.status == 400,
      "OAuth ref object without provider/alias or binding_id should be rejected: #{missing_oauth_target.status} #{missing_oauth_target.resp_body}"
    )

    binding =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => alias_name,
        "target_ref" => first_target_ref!(definition),
        "placement" => "server",
        "config_values" => %{"MCP_E2E_TOKEN" => secret}
      })

    assert!(binding["config_configured"] == true, "binding did not record configured secret")
    assert!(not String.contains?(Jason.encode!(binding), secret), "binding leaked secret value")

    listed =
      treq!(tenant_key, :get, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{})
      |> Jason.encode!()

    assert!(not String.contains?(listed, secret), "binding list leaked secret value")

    package_definition =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "Secret Args #{run_id}",
        "install_source" => %{
          "type" => "server_metadata",
          "url" => "https://mcp.context7.com/mcp?api_key=#{secret}"
        },
        "server_metadata" => %{
          "name" => "Secret Args #{run_id}",
          "api_key" => secret,
          "_meta" => %{"api_key" => secret},
          "packages" => [
            %{
              "targetRef" => "package:secret-args",
              "registryType" => "npm",
              "identifier" => "@upstash/context7-mcp",
              "command" => "npx",
              "api_key" => secret,
              "runtimeArguments" => [
                "-y",
                "@upstash/context7-mcp@latest",
                "--api-key",
                secret,
                "--token=#{secret}",
                "Authorization: Bearer #{secret}"
              ]
            }
          ]
        }
      })

    encoded_package_definition = Jason.encode!(package_definition)

    assert!(
      not String.contains?(encoded_package_definition, secret),
      "definition leaked secret-like metadata or args"
    )
  end

  defp assert_pat_remote_path!(tenant_key, group_id, agent_id, run_id) do
    secret = "pat-secret-#{run_id}"
    alias_name = "pat-remote-#{run_id}"

    definition =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "PAT Remote #{run_id}",
        "url" => remote_url(),
        "headers" => %{"X-Salix-MCP-E2E" => "${MCP_E2E_TOKEN}"},
        "supports_server" => true
      })

    binding =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => alias_name,
        "target_ref" => first_target_ref!(definition),
        "placement" => "server",
        "config_values" => %{"MCP_E2E_TOKEN" => secret}
      })

    assert!(
      binding["config_configured"] == true,
      "PAT remote binding did not record configured secret"
    )

    assert!(
      not String.contains?(Jason.encode!(binding), secret),
      "PAT remote binding leaked secret"
    )

    conn =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/discover",
        %{}
      )

    assert!(
      conn["status"] in ["running", "degraded"],
      "PAT remote discovery failed: #{inspect(conn)}"
    )

    assert_connection_metadata!(conn, "PAT remote")

    assert!(
      not String.contains?(Jason.encode!(conn), secret),
      "PAT remote connection leaked secret"
    )

    tools = mcp_operation_tools!(tenant_key, agent_id, alias_name)
    assert!(tools != [], "PAT remote MCP tools were not listed with canonical operation ids")

    help_result = tool_help!(tenant_key, agent_id, List.first(tools)["operation_id"])

    assert!(
      not String.contains?(Jason.encode!(help_result), secret),
      "PAT remote help leaked secret"
    )

    call_tool =
      Enum.find(tools, &String.contains?(&1["operation_id"], "resolve")) ||
        Enum.find(tools, &String.contains?(&1["operation_id"], "library")) ||
        List.first(tools)

    result =
      session_tool_result!(
        tenant_key,
        agent_id,
        call_tool["operation_id"],
        call_params_from_help!(tenant_key, agent_id, call_tool)
      )

    assert!(result.error == false, "PAT remote MCP call failed: #{inspect(result)}")
    assert!(not String.contains?(result.content, secret), "PAT remote MCP call leaked secret")
  end

  defp assert_oauth_ref_remote_path!(tenant_key, group_id, agent_id, run_id) do
    alias_name = "oauth-remote-#{run_id}"
    secret = "mock-oauth-token-#{alias_name}"
    original_resolver = Application.get_env(:salix_mcp, :credential_resolver_mod)

    Application.put_env(
      :salix_mcp,
      :credential_resolver_mod,
      __MODULE__.MockOAuthCredentialResolver
    )

    try do
      definition =
        treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
          "name" => "OAuth Remote #{run_id}",
          "url" => remote_url(),
          "headers" => %{"X-Salix-MCP-OAuth-E2E" => "${MCP_E2E_OAUTH}"},
          "supports_server" => true
        })

      binding =
        treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
          "mcp_id" => definition["mcp_id"],
          "alias" => alias_name,
          "target_ref" => first_target_ref!(definition),
          "placement" => "server",
          "oauth_binding_refs" => %{
            "MCP_E2E_OAUTH" => %{
              "provider" => "github",
              "alias" => "default",
              "credential" => "access_token"
            }
          }
        })

      assert!(
        is_map(binding["oauth_binding_refs"]) and
          is_map(binding["oauth_binding_refs"]["MCP_E2E_OAUTH"]),
        "OAuth remote binding did not expose structured OAuth ref projection"
      )

      assert!(
        not String.contains?(Jason.encode!(binding), secret),
        "OAuth remote binding leaked resolved token"
      )

      conn =
        treq!(
          tenant_key,
          :post,
          "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/discover",
          %{}
        )

      assert!(
        conn["status"] in ["running", "degraded"],
        "OAuth remote discovery failed through credential resolver: #{inspect(conn)}"
      )

      assert_connection_metadata!(conn, "OAuth remote")

      assert!(
        not String.contains?(Jason.encode!(conn), secret),
        "OAuth remote connection leaked resolved token"
      )

      tools = mcp_operation_tools!(tenant_key, agent_id, alias_name)
      assert!(tools != [], "OAuth remote MCP tools were not listed with canonical operation ids")

      help_result = tool_help!(tenant_key, agent_id, List.first(tools)["operation_id"])

      assert!(
        not String.contains?(Jason.encode!(help_result), secret),
        "OAuth remote help leaked resolved token"
      )

      call_tool =
        Enum.find(tools, &String.contains?(&1["operation_id"], "resolve")) ||
          Enum.find(tools, &String.contains?(&1["operation_id"], "library")) ||
          List.first(tools)

      result =
        session_tool_result!(
          tenant_key,
          agent_id,
          call_tool["operation_id"],
          call_params_from_help!(tenant_key, agent_id, call_tool)
        )

      assert!(
        result.error == false,
        "OAuth remote MCP call failed through credential resolver: #{inspect(result)}"
      )

      assert!(
        not String.contains?(result.content, secret),
        "OAuth remote MCP call leaked resolved token"
      )
    after
      restore_credential_resolver(original_resolver)
    end
  end

  defp assert_server_metadata_normalization!(tenant_key, group_id, run_id) do
    definition =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "Metadata Normalization #{run_id}",
        "server_metadata" => %{
          "name" => "Metadata Normalization #{run_id}",
          "packages" => [
            %{
              "targetRef" => "package:metadata-context7",
              "registryType" => "npm",
              "identifier" => "@upstash/context7-mcp",
              "version" => "latest",
              "transport" => %{"type" => "stdio"},
              "environmentVariables" => [
                %{"name" => "OPTIONAL_FLAG", "description" => "Optional test flag"}
              ]
            }
          ],
          "remotes" => [
            %{
              "targetRef" => "remote:metadata-api",
              "type" => "streamable-http",
              "url" => "https://mcp.supabase.com/mcp?project_ref={PROJECT_REF}",
              "variables" => [
                %{"name" => "PROJECT_REF", "description" => "Project ref", "isRequired" => true}
              ]
            }
          ]
        },
        "supports_server" => true
      })

    entry = (get_in(definition, ["server_metadata", "packages"]) || []) |> List.first()
    remote_entry = (get_in(definition, ["server_metadata", "remotes"]) || []) |> List.first()
    assert!(entry["target_ref"] == "package:metadata-context7", "targetRef was not normalized")
    assert!(entry["registry_type"] == "npm", "registryType was not normalized")
    assert!(entry["command"] == "npx", "npm command was not inferred: #{inspect(entry)}")

    assert!(
      remote_entry["target_ref"] == "remote:metadata-api",
      "remote targetRef was not normalized"
    )

    assert!(remote_entry["transport"] == "streamable-http", "remote type was not normalized")

    assert!(
      entry["runtime_arguments"] == ["-y", "@upstash/context7-mcp@latest"],
      "npm non-interactive runtime args were not inferred: #{inspect(entry)}"
    )

    assert!(
      is_map(get_in(entry, ["environment_variables_schema", "OPTIONAL_FLAG"])),
      "environmentVariables schema list was not normalized: #{inspect(entry)}"
    )

    assert!(
      is_map(get_in(remote_entry, ["variables_schema", "PROJECT_REF"])),
      "remote variables schema list was not normalized: #{inspect(remote_entry)}"
    )

    npx_snippet =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "NPX Snippet #{run_id}",
        "mcpServers" => %{
          "playwright" => %{"command" => "npx", "args" => ["@playwright/mcp@latest"]}
        },
        "supports_server" => false
      })

    npx_entry = npx_snippet |> get_in(["server_metadata", "packages"]) |> List.first()

    assert!(
      npx_entry["runtime_arguments"] == ["-y", "@playwright/mcp@latest"],
      "npx client config snippet was not made non-interactive: #{inspect(npx_entry)}"
    )

    mcpb =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "MCPB Metadata #{run_id}",
        "registry_type" => "mcpb",
        "identifier" => "context7-docs.mcpb",
        "supports_server" => false
      })

    binding =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => mcpb["mcp_id"],
        "alias" => "metadata-bundle-#{run_id}",
        "target_ref" => first_target_ref!(mcpb),
        "placement" => "server"
      })

    conn =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/discover",
        %{}
      )

    assert!(
      conn["status"] == "not_runnable",
      "mcpb without launcher should be not_runnable: #{inspect(conn)}"
    )

    assert!(
      String.contains?(to_string(get_in(conn, ["last_error", "reason"])), "no runnable command"),
      "mcpb not_runnable reason missing: #{inspect(conn)}"
    )
  end

  defp assert_supabase_missing_config!(tenant_key, group_id, run_id) do
    alias_name = "supabase-boundary-#{run_id}"

    definition =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "Supabase Boundary #{run_id}",
        "url" => "https://mcp.supabase.com/mcp?project_ref=${SUPABASE_PROJECT_REF}",
        "headers" => %{"Authorization" => "Bearer ${SUPABASE_ACCESS_TOKEN}"}
      })

    public_definition = Jason.encode!(definition)

    assert!(
      not String.contains?(public_definition, "supabase-secret"),
      "supabase definition leaked secret"
    )

    binding =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => alias_name,
        "target_ref" => first_target_ref!(definition),
        "placement" => "server"
      })

    conn =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/discover",
        %{}
      )

    assert!(
      conn["status"] == "missing_config",
      "supabase missing config status wrong: #{inspect(conn)}"
    )

    assert!(
      get_in(conn, ["last_error", "missing"]) != [],
      "supabase missing config did not report missing fields: #{inspect(conn)}"
    )
  end

  defp assert_github_secret_boundary!(tenant_key, group_id, device_runtime, run_id) do
    secret = "github-token-#{run_id}"
    alias_name = "github-boundary-#{run_id}"

    definition =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "GitHub Boundary #{run_id}",
        "mcpServers" => %{
          "github" => %{
            "command" => "docker",
            "args" => ["run", "-i", "--rm", "ghcr.io/github/github-mcp-server"],
            "env" => %{"GITHUB_PERSONAL_ACCESS_TOKEN" => "${GITHUB_PERSONAL_ACCESS_TOKEN}"}
          }
        },
        "supports_server" => false
      })

    wrong_group_device =
      treq_conn(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => "wrong-device-#{run_id}",
        "target_ref" => first_target_ref!(definition),
        "placement" => "device",
        "device_runtime_id" => "missing-device-runtime-#{run_id}",
        "config_values" => %{"GITHUB_PERSONAL_ACCESS_TOKEN" => secret}
      })

    assert!(
      wrong_group_device.status == 400,
      "device placement should reject unknown group device_runtime_id"
    )

    binding =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => alias_name,
        "target_ref" => first_target_ref!(definition),
        "placement" => "device",
        "device_runtime_id" => device_runtime["device_runtime_id"],
        "config_values" => %{"GITHUB_PERSONAL_ACCESS_TOKEN" => secret}
      })

    encoded = Jason.encode!(binding)
    assert!(binding["config_configured"] == true, "github token boundary config was not recorded")
    assert!(not String.contains?(encoded, secret), "github binding leaked secret")
  end

  defp assert_server_package_policy!(tenant_key, group_id, agent_id, run_id) do
    original_runner = Application.get_env(:salix_mcp, :server_process_runner)
    Application.delete_env(:salix_mcp, :server_process_runner)

    try do
      assert_server_package_policy_without_runner!(tenant_key, group_id, run_id)
    after
      restore_server_process_runner(original_runner)
    end

    assert_server_package_policy_with_runner!(tenant_key, group_id, agent_id, run_id)
  end

  defp assert_server_package_policy_without_runner!(tenant_key, group_id, run_id) do
    alias_name = "server-package-#{run_id}"

    trust_bypass =
      treq_conn(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "Server Package Trust Bypass #{run_id}",
        "identifier" => "@upstash/context7-mcp",
        "version" => "latest",
        "registry_type" => "npm",
        "supports_server" => true,
        "trust" => %{
          "source" => "system_builtin",
          "server_process_execution" => true
        }
      })

    assert!(
      trust_bypass.status == 400 and
        String.contains?(trust_bypass.resp_body || "", "system-controlled"),
      "tenant definition trust should be rejected: #{trust_bypass.status} #{trust_bypass.resp_body}"
    )

    definition =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "Server Package Policy #{run_id}",
        "identifier" => "@upstash/context7-mcp",
        "version" => "latest",
        "registry_type" => "npm",
        "supports_server" => true
      })

    update_trust_bypass =
      treq_conn(tenant_key, :patch, "/v1/runtime/mcp/definitions/#{definition["mcp_id"]}", %{
        "trust" => %{
          "source" => "system_builtin",
          "server_process_execution" => true
        }
      })

    assert!(
      update_trust_bypass.status == 400 and
        String.contains?(update_trust_bypass.resp_body || "", "system-controlled"),
      "tenant definition trust update should be rejected: #{update_trust_bypass.status} #{update_trust_bypass.resp_body}"
    )

    binding =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => alias_name,
        "target_ref" => first_target_ref!(definition),
        "placement" => "server"
      })

    conn =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/discover",
        %{}
      )

    assert!(
      conn["status"] == "not_runnable",
      "tenant server package should be not_runnable: #{inspect(conn)}"
    )

    assert!(
      String.contains?(
        to_string(get_in(conn, ["last_error", "reason"])),
        "trusted system definition"
      ),
      "server package policy reason missing: #{inspect(conn)}"
    )

    system_binding =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => "mcp1_0000000000000000001",
        "alias" => "system-server-context7-#{run_id}",
        "target_ref" => "package:context7-npm",
        "placement" => "server"
      })

    system_conn =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{system_binding["binding_id"]}/discover",
        %{}
      )

    assert!(
      system_conn["status"] == "not_runnable",
      "system server package without runner should be not_runnable: #{inspect(system_conn)}"
    )

    assert!(
      String.contains?(
        to_string(get_in(system_conn, ["last_error", "reason"])),
        "server process runner"
      ),
      "server runner policy reason missing: #{inspect(system_conn)}"
    )
  end

  defp assert_server_package_policy_with_runner!(tenant_key, group_id, agent_id, run_id) do
    alias_name = "system-server-runner-context7-#{run_id}"
    root = Path.join(System.tmp_dir!(), "mcp-server-runner-e2e-#{run_id}")
    runner_path = Path.join(root, "runner.sh")
    File.rm_rf(root)
    File.mkdir_p!(root)

    File.write!(runner_path, [
      "#!/bin/sh\n",
      "if [ -z \"$SALIX_MCP_WORKING_DIR\" ]; then\n",
      "  exit 42\n",
      "fi\n",
      "actual_dir=$(pwd -P)\n",
      "expected_dir=$(cd \"$SALIX_MCP_WORKING_DIR\" 2>/dev/null && pwd -P) || exit 44\n",
      "if [ \"$actual_dir\" != \"$expected_dir\" ]; then\n",
      "  exit 43\n",
      "fi\n",
      "exec \"$@\"\n"
    ])

    File.chmod!(runner_path, 0o755)
    original_runner = Application.get_env(:salix_mcp, :server_process_runner)

    Application.put_env(:salix_mcp, :server_process_runner, %{
      "command" => runner_path,
      "env" => %{"PATH" => System.get_env("PATH") || ""}
    })

    try do
      binding =
        treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
          "mcp_id" => "mcp1_0000000000000000001",
          "alias" => alias_name,
          "target_ref" => "package:context7-npm",
          "placement" => "server"
        })

      conn =
        treq!(
          tenant_key,
          :post,
          "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/discover",
          %{}
        )

      assert!(
        conn["status"] in ["running", "degraded"],
        "system server package with runner should run: #{inspect(conn)}"
      )

      assert_connection_metadata!(conn, "system server package runner")

      tools = mcp_operation_tools!(tenant_key, agent_id, alias_name)
      assert!(tools != [], "server runner MCP tools were not listed with canonical operation ids")

      call_tool =
        Enum.find(tools, &String.contains?(&1["operation_id"], "resolve")) ||
          Enum.find(tools, &String.contains?(&1["operation_id"], "library")) ||
          List.first(tools)

      result =
        session_tool_result!(
          tenant_key,
          agent_id,
          call_tool["operation_id"],
          call_params_from_help!(tenant_key, agent_id, call_tool)
        )

      assert!(result.error == false, "server runner MCP call failed: #{inspect(result)}")
    after
      restore_server_process_runner(original_runner)
      File.rm_rf(root)
    end
  end

  defp restore_credential_resolver(nil),
    do: Application.delete_env(:salix_mcp, :credential_resolver_mod)

  defp restore_credential_resolver(value),
    do: Application.put_env(:salix_mcp, :credential_resolver_mod, value)

  defp restore_server_process_runner(nil),
    do: Application.delete_env(:salix_mcp, :server_process_runner)

  defp restore_server_process_runner(value),
    do: Application.put_env(:salix_mcp, :server_process_runner, value)

  defp assert_device_package_mcp!(tenant_key, group_id, agent_id, device_runtime, run_id) do
    package = System.get_env("MCP_E2E_DEVICE_PACKAGE") || "@upstash/context7-mcp@latest"
    alias_name = "device-context7-#{run_id}"

    definition =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "Device Context7 #{run_id}",
        "mcpServers" => %{
          "context7" => %{"command" => "npx", "args" => ["-y", package]}
        },
        "supports_server" => false
      })

    binding =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => alias_name,
        "target_ref" => first_target_ref!(definition),
        "placement" => "device",
        "device_runtime_id" => device_runtime["device_runtime_id"]
      })

    conn =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/discover",
        %{}
      )

    assert!(
      conn["status"] in ["running", "degraded"],
      "device package connection did not run: #{inspect(conn)}"
    )

    assert_connection_metadata!(conn, "device package")

    assert!(
      get_in(conn, ["discovered", "tools"]) != [],
      "device package discovered no tools: #{inspect(conn)}"
    )

    tools = mcp_operation_tools!(tenant_key, agent_id, alias_name)

    assert!(tools != [], "device MCP tools were not listed with canonical operation ids")

    tool =
      Enum.find(tools, &String.contains?(&1["operation_id"], "resolve")) ||
        Enum.find(tools, &String.contains?(&1["operation_id"], "library")) ||
        List.first(tools)

    result =
      session_tool_result!(
        tenant_key,
        agent_id,
        tool["operation_id"],
        call_params_from_help!(tenant_key, agent_id, tool)
      )

    assert!(result.error == false, "device MCP call failed: #{inspect(result)}")

    Process.put(:device_mcp_tool, tool["operation_id"])
    Process.put(:device_mcp_params, call_params_from_help!(tenant_key, agent_id, tool))
    Process.put(:device_mcp_binding_id, binding["binding_id"])
  end

  defp assert_device_root_grant_boundary!(tenant_key, group_id, device_runtime, run_id, root) do
    package = System.get_env("MCP_E2E_DEVICE_PACKAGE") || "@upstash/context7-mcp@latest"
    allowed_dir = Path.join(root, "allowed")
    File.mkdir_p!(allowed_dir)

    definition =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "Device Root Boundary #{run_id}",
        "mcpServers" => %{
          "context7-root-boundary" => %{"command" => "npx", "args" => ["-y", package]}
        },
        "supports_server" => false
      })

    binding =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => "device-root-boundary-#{run_id}",
        "target_ref" => first_target_ref!(definition),
        "placement" => "device",
        "device_runtime_id" => device_runtime["device_runtime_id"],
        "root_grants" => ["allowed"],
        "config_values" => %{"working_dir" => "../outside"}
      })

    conn =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/discover",
        %{}
      )

    assert!(
      conn["status"] == "missing_root",
      "root grant boundary status wrong: #{inspect(conn)}"
    )

    assert!(
      String.contains?(to_string(get_in(conn, ["last_error", "reason"])), "root_grants"),
      "root grant boundary reason missing: #{inspect(conn)}"
    )
  end

  defp assert_device_discovery_error_secret_boundary!(
         tenant_key,
         group_id,
         agent_id,
         device_runtime,
         run_id,
         root
       ) do
    server_path = write_discovery_error_mcp_server!(root, run_id)
    alias_name = "discovery-error-#{run_id}"
    secret_prefix = "discovery-secret"
    secret = "#{secret_prefix}-long-#{run_id}"
    forbidden = [secret, "long-#{run_id}"]

    definition =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "Discovery Error Secret Boundary #{run_id}",
        "mcpServers" => %{
          "discovery-error" => %{
            "command" => "node",
            "args" => [server_path],
            "env" => %{"MCP_DISCOVERY_TOKEN" => "${MCP_DISCOVERY_TOKEN}"}
          }
        },
        "supports_server" => false
      })

    assert_no_secret!(definition, secret, "definition projection leaked discovery error secret")

    binding =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => alias_name,
        "target_ref" => first_target_ref!(definition),
        "placement" => "device",
        "device_runtime_id" => device_runtime["device_runtime_id"],
        "root_grants" => ["."],
        "config_values" => %{
          "MCP_DISCOVERY_TOKEN" => secret,
          "MCP_DISCOVERY_TOKEN_PREFIX" => secret_prefix
        }
      })

    assert_no_secret!(binding, forbidden, "binding projection leaked discovery error secret")

    conn =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/discover",
        %{}
      )

    assert!(
      conn["status"] == "degraded",
      "discovery error MCP should degrade while preserving successful discovery: #{inspect(conn)}"
    )

    assert_no_secret!(conn, forbidden, "discover response leaked discovery error secret")

    persisted =
      case SalixMCP.Store.read_connection(tenant_id(), group_id, binding["binding_id"]) do
        {:ok, connection} -> connection
        other -> raise("discovery error connection missing: #{inspect(other)}")
      end

    assert_no_secret!(persisted, forbidden, "persisted connection leaked discovery error secret")

    listed =
      treq!(tenant_key, :get, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{})
      |> Enum.find(&(&1["binding_id"] == binding["binding_id"]))

    assert!(listed != nil, "discovery error binding missing from binding list")
    assert_no_secret!(listed, forbidden, "binding list leaked discovery error secret")

    agent_list = session_tool_result!(tenant_key, agent_id, "mcp.list", %{})

    assert!(
      agent_list.error == false,
      "mcp.list failed during discovery error boundary check: #{inspect(agent_list)}"
    )

    agent_binding =
      agent_list.body["bindings"]
      |> List.wrap()
      |> Enum.find(&(&1["binding_id"] == binding["binding_id"]))

    assert!(agent_binding != nil, "agent mcp.list omitted discovery error binding")
    assert_no_secret!(agent_binding, forbidden, "agent mcp.list leaked discovery error secret")

    assert!(
      not Map.has_key?(get_in(agent_binding, ["connection"]) || %{}, "last_error"),
      "agent mcp.list should not expose raw connection last_error: #{inspect(agent_binding)}"
    )

    tools = mcp_operation_tools!(tenant_key, agent_id, alias_name)
    failing_tool = find_mcp_tool!(tools, ["safe_tool"])
    tool_error = call_mcp_tool(tenant_key, agent_id, failing_tool["operation_id"], %{})

    assert!(tool_error.error == true, "secret echo tool should fail structurally")
    assert_no_secret!(tool_error.body, forbidden, "tool error result leaked binding secret")

    resource_error =
      session_tool_result!(tenant_key, agent_id, "mcp.get", %{
        "kind" => "resource",
        "binding_id" => binding["binding_id"],
        "uri" => "memory://#{run_id}"
      })

    assert!(resource_error.error == true, "secret echo resource read should fail structurally")

    assert_no_secret!(
      resource_error.body,
      forbidden,
      "resource error result leaked binding secret"
    )

    resource_success =
      session_tool_result!(tenant_key, agent_id, "mcp.get", %{
        "kind" => "resource",
        "binding_id" => binding["binding_id"],
        "uri" => "memory://#{run_id}/success"
      })

    assert!(resource_success.error == false, "secret echo resource read should succeed")
    assert_no_secret!(resource_success.body, forbidden, "resource success leaked binding secret")

    prompt_success =
      session_tool_result!(tenant_key, agent_id, "mcp.get", %{
        "kind" => "prompt",
        "binding_id" => binding["binding_id"],
        "name" => "secret_prompt",
        "arguments" => %{}
      })

    assert!(prompt_success.error == false, "secret echo prompt get should succeed")
    assert_no_secret!(prompt_success.body, forbidden, "prompt success leaked binding secret")

    prompt_error =
      session_tool_result!(tenant_key, agent_id, "mcp.get", %{
        "kind" => "prompt",
        "binding_id" => binding["binding_id"],
        "name" => "missing_prompt",
        "arguments" => %{}
      })

    assert!(prompt_error.error == true, "secret echo prompt get should fail structurally")
    assert_no_secret!(prompt_error.body, forbidden, "prompt error result leaked binding secret")
  end

  defp assert_device_tool_error_does_not_poison_connection!(
         tenant_key,
         group_id,
         agent_id,
         device_runtime,
         run_id,
         root
       ) do
    server_path = write_error_mcp_server!(root, run_id)
    alias_name = "tool-error-#{run_id}"

    definition =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "Tool Error Boundary #{run_id}",
        "mcpServers" => %{
          "tool-error" => %{
            "command" => "node",
            "args" => [server_path]
          }
        },
        "supports_server" => false
      })

    binding =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => alias_name,
        "target_ref" => first_target_ref!(definition),
        "placement" => "device",
        "device_runtime_id" => device_runtime["device_runtime_id"],
        "root_grants" => ["."]
      })

    conn =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/discover",
        %{}
      )

    assert!(conn["status"] == "running", "tool-error MCP did not start cleanly: #{inspect(conn)}")
    tools = mcp_operation_tools!(tenant_key, agent_id, alias_name)
    failing_tool = find_mcp_tool!(tools, ["always_fails"])

    result =
      call_mcp_tool(tenant_key, agent_id, failing_tool["operation_id"], %{
        "reason" => "intentional boundary check #{run_id}"
      })

    assert!(
      result.error == true,
      "MCP JSON-RPC tool error should surface as tool failure: #{inspect(result)}"
    )

    assert!(
      String.contains?(result.content, "MCP_TOOL_ERROR_DOES_NOT_POISON_CONNECTION"),
      "MCP tool error did not preserve server error payload: #{inspect(result)}"
    )

    assert!(
      not String.contains?(result.content, "MCP_PARENT_ENV_SECRET"),
      "device MCP process inherited connector parent environment: #{inspect(result)}"
    )

    listed =
      treq!(tenant_key, :get, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{})
      |> Enum.find(&(&1["binding_id"] == binding["binding_id"]))

    assert!(listed != nil, "tool-error binding missing from binding list")

    assert!(
      get_in(listed, ["connection", "status"]) == "running",
      "MCP tool-level JSON-RPC error polluted connection status: #{inspect(listed)}"
    )
  end

  defp assert_device_async_mcp!(tenant_key, group_id, agent_id, device_runtime, run_id, root) do
    IO.puts("MCP_RUNTIME_E2E: async MCP writing test server")
    server_path = write_async_mcp_server!(root, run_id)
    alias_name = "async-progress-#{run_id}"

    IO.puts("MCP_RUNTIME_E2E: async MCP creating definition")

    definition =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "Async Progress #{run_id}",
        "mcpServers" => %{
          "async-progress" => %{
            "command" => "node",
            "args" => [server_path]
          }
        },
        "supports_server" => false
      })

    IO.puts("MCP_RUNTIME_E2E: async MCP creating binding")

    binding =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => alias_name,
        "target_ref" => first_target_ref!(definition),
        "placement" => "device",
        "device_runtime_id" => device_runtime["device_runtime_id"],
        "root_grants" => ["."]
      })

    IO.puts("MCP_RUNTIME_E2E: async MCP discovering")

    conn =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/discover",
        %{}
      )

    assert!(conn["status"] == "running", "async MCP did not start cleanly: #{inspect(conn)}")
    tools = mcp_operation_tools!(tenant_key, agent_id, alias_name)
    slow_tool = find_mcp_tool!(tools, ["slow_progress"])

    resource_list =
      session_tool_result!(tenant_key, agent_id, "mcp.list", %{
        "kind" => "resources",
        "binding_id" => binding["binding_id"]
      })

    assert!(
      resource_list.error == false and
        Enum.any?(
          List.wrap(resource_list.body["resources"]),
          &(&1["uri"] == "memory://#{run_id}")
        ),
      "mcp.list resources did not expose discovered resource: #{inspect(resource_list)}"
    )

    resource =
      session_tool_result!(tenant_key, agent_id, "mcp.get", %{
        "kind" => "resource",
        "binding_id" => binding["binding_id"],
        "uri" => "memory://#{run_id}"
      })

    assert!(
      resource.error == false and
        String.contains?(Jason.encode!(resource.body), "MCP_RESOURCE_OK_#{run_id}"),
      "mcp.get resource did not read through MCP gateway: #{inspect(resource)}"
    )

    prompt_list =
      session_tool_result!(tenant_key, agent_id, "mcp.list", %{
        "kind" => "prompts",
        "binding_alias" => alias_name
      })

    assert!(
      prompt_list.error == false and
        Enum.any?(List.wrap(prompt_list.body["prompts"]), &(&1["name"] == "handoff")),
      "mcp.list prompts did not expose discovered prompt: #{inspect(prompt_list)}"
    )

    prompt =
      session_tool_result!(tenant_key, agent_id, "mcp.get", %{
        "kind" => "prompt",
        "binding_alias" => alias_name,
        "name" => "handoff",
        "arguments" => %{"topic" => "MCP_PROMPT_OK_#{run_id}"}
      })

    assert!(
      prompt.error == false and
        String.contains?(Jason.encode!(prompt.body), "MCP_PROMPT_OK_#{run_id}"),
      "mcp.get prompt did not read through MCP gateway: #{inspect(prompt)}"
    )

    IO.puts("MCP_RUNTIME_E2E: async MCP calling slow tool")

    async =
      call_mcp_tool(tenant_key, agent_id, slow_tool["operation_id"], %{
        "duration_ms" => 15_000
      })

    assert!(async.status == 200, "async MCP call should return HTTP 200: #{inspect(async)}")
    assert!(async.error == false, "async MCP call should return async_running: #{inspect(async)}")

    assert!(
      async.body["status"] == "running",
      "async MCP call did not return running status: #{inspect(async)}"
    )

    tool_call_id = async.body["tool_call_id"]

    assert!(
      is_binary(tool_call_id) and tool_call_id != "",
      "async MCP response missing tool_call_id: #{inspect(async)}"
    )

    IO.puts("MCP_RUNTIME_E2E: async MCP waiting for progress")
    status = wait_for_tool_progress!(tenant_key, agent_id, tool_call_id)

    assert!(
      get_in(status, ["progress", "message"]) == "MCP_ASYNC_PROGRESS_#{run_id}",
      "async MCP progress payload was not preserved: #{inspect(status)}"
    )

    IO.puts("MCP_RUNTIME_E2E: async MCP cancelling")

    cancelled =
      session_tool_result!(tenant_key, agent_id, "tool_call.cancel", %{
        "tool_call_id" => tool_call_id,
        "reason" => "mcp async boundary #{run_id}"
      })

    assert!(
      cancelled.error == false,
      "tool_call.cancel failed for MCP async call: #{inspect(cancelled)}"
    )

    assert!(
      cancelled.body["status"] == "cancelled",
      "MCP async cancel did not return cancelled: #{inspect(cancelled)}"
    )

    IO.puts("MCP_RUNTIME_E2E: async MCP reading cancelled result")

    result =
      session_tool_result!(tenant_key, agent_id, "tool_call.get_result", %{
        "tool_call_id" => tool_call_id
      })

    assert!(
      result.error == false,
      "tool_call.get_result failed after MCP cancel: #{inspect(result)}"
    )

    assert!(
      result.body["status"] == "cancelled",
      "cancelled MCP async result was overwritten: #{inspect(result)}"
    )

    IO.puts("MCP_RUNTIME_E2E: async MCP verifying connection status")

    listed =
      treq!(tenant_key, :get, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{})
      |> Enum.find(&(&1["binding_id"] == binding["binding_id"]))

    assert!(
      get_in(listed, ["connection", "status"]) == "running",
      "MCP async cancel polluted connection status: #{inspect(listed)}"
    )
  end

  defp assert_playwright_device_mcp!(tenant_key, group_id, agent_id, device_runtime, run_id) do
    package = System.get_env("MCP_E2E_PLAYWRIGHT_PACKAGE") || "@playwright/mcp@latest"
    alias_name = "playwright-#{run_id}"

    definition =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "Playwright #{run_id}",
        "mcpServers" => %{
          "playwright" => %{"command" => "npx", "args" => ["-y", package, "--headless"]}
        },
        "supports_server" => false
      })

    binding =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => alias_name,
        "target_ref" => first_target_ref!(definition),
        "placement" => "device",
        "device_runtime_id" => device_runtime["device_runtime_id"]
      })

    conn =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/discover",
        %{}
      )

    assert!(
      conn["status"] in ["running", "degraded"],
      "playwright connection did not run: #{inspect(conn)}"
    )

    assert_connection_metadata!(conn, "playwright device")

    tools = mcp_operation_tools!(tenant_key, agent_id, alias_name)
    navigate_tool = find_mcp_tool!(tools, ["browser_navigate", "navigate"])
    snapshot_tool = find_mcp_tool!(tools, ["browser_snapshot", "snapshot"])
    click_tool = find_mcp_tool!(tools, ["browser_click", "click"])
    marker = "MCP_PLAYWRIGHT_OK_#{run_id}"

    html =
      URI.encode("""
      <!doctype html>
      <title>MCP Playwright #{run_id}</title>
      <button id="ping" onclick="document.body.dataset.clicked='yes';this.textContent='#{marker}'">Ping</button>
      """)

    navigate =
      call_mcp_tool_completed(tenant_key, agent_id, navigate_tool["operation_id"], %{
        "url" => "data:text/html,#{html}"
      })

    assert!(navigate.error == false, "playwright navigate failed: #{inspect(navigate)}")

    snapshot = call_mcp_tool_completed(tenant_key, agent_id, snapshot_tool["operation_id"], %{})
    assert!(snapshot.error == false, "playwright snapshot failed: #{inspect(snapshot)}")
    ref = playwright_ref!(snapshot.content, "Ping")

    click =
      call_mcp_tool_completed(tenant_key, agent_id, click_tool["operation_id"], %{
        "element" => "Ping button",
        "ref" => ref
      })

    assert!(click.error == false, "playwright click failed: #{inspect(click)}")

    clicked = call_mcp_tool_completed(tenant_key, agent_id, snapshot_tool["operation_id"], %{})

    assert!(
      String.contains?(clicked.content, marker),
      "playwright click marker missing: #{inspect(clicked)}"
    )
  end

  defp assert_filesystem_root_mcp!(
         tenant_key,
         group_id,
         agent_id,
         device_runtime,
         run_id,
         connector_root
       ) do
    package =
      System.get_env("MCP_E2E_FILESYSTEM_PACKAGE") || "@modelcontextprotocol/server-filesystem"

    alias_name = "filesystem-#{run_id}"
    root_name = "fs-root-#{run_id}"
    root = Path.join(connector_root, root_name)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "marker.txt"), "MCP_FS_MARKER_#{run_id}")
    File.write!(Path.join(connector_root, "outside.txt"), "MCP_FS_OUTSIDE_#{run_id}")

    definition =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "Filesystem #{run_id}",
        "mcpServers" => %{
          "filesystem" => %{"command" => "npx", "args" => ["-y", package, "."]}
        },
        "supports_server" => false
      })

    binding =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => alias_name,
        "target_ref" => first_target_ref!(definition),
        "placement" => "device",
        "device_runtime_id" => device_runtime["device_runtime_id"],
        "root_grants" => [root_name],
        "config_values" => %{"working_dir" => root_name}
      })

    conn =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/discover",
        %{}
      )

    assert!(
      conn["status"] in ["running", "degraded"],
      "filesystem connection did not run: #{inspect(conn)}"
    )

    assert_connection_metadata!(conn, "filesystem device")

    tools = mcp_operation_tools!(tenant_key, agent_id, alias_name)
    read_tool = find_mcp_tool!(tools, ["read_file", "read"])
    write_tool = find_mcp_tool!(tools, ["write_file", "write"])
    list_tool = find_mcp_tool!(tools, ["list_directory", "list"])

    listed =
      call_mcp_tool_completed(tenant_key, agent_id, list_tool["operation_id"], %{"path" => "."})

    assert!(listed.error == false, "filesystem list failed: #{inspect(listed)}")

    assert!(
      String.contains?(listed.content, "marker.txt"),
      "filesystem list marker missing: #{inspect(listed)}"
    )

    read =
      call_mcp_tool_completed(tenant_key, agent_id, read_tool["operation_id"], %{
        "path" => "marker.txt"
      })

    assert!(read.error == false, "filesystem read failed: #{inspect(read)}")

    assert!(
      String.contains?(read.content, "MCP_FS_MARKER_#{run_id}"),
      "filesystem read marker missing: #{inspect(read)}"
    )

    write =
      call_mcp_tool_completed(tenant_key, agent_id, write_tool["operation_id"], %{
        "path" => "written.txt",
        "content" => "MCP_FS_WRITE_OK_#{run_id}"
      })

    assert!(write.error == false, "filesystem write failed: #{inspect(write)}")

    written =
      call_mcp_tool_completed(tenant_key, agent_id, read_tool["operation_id"], %{
        "path" => "written.txt"
      })

    assert!(
      String.contains?(written.content, "MCP_FS_WRITE_OK_#{run_id}"),
      "filesystem write marker missing"
    )

    outside =
      call_mcp_tool_completed(tenant_key, agent_id, read_tool["operation_id"], %{
        "path" => "../outside.txt"
      })

    assert!(outside.error == true, "filesystem outside read should fail: #{inspect(outside)}")

    assert!(
      not String.contains?(outside.content || inspect(outside.body), "MCP_FS_OUTSIDE_#{run_id}"),
      "filesystem outside read leaked file content: #{inspect(outside)}"
    )
  end

  defp assert_device_disconnect_recovery!(
         tenant_key,
         group_id,
         agent_id,
         device_alias,
         connector,
         root
       ) do
    tool = Process.get(:device_mcp_tool)
    params = Process.get(:device_mcp_params) || %{}
    binding_id = Process.get(:device_mcp_binding_id)
    old_connector_run_id = Process.get(:device_mcp_connector_run_id)
    IO.puts("MCP_RUNTIME_E2E: disconnect recovery stopping connector")
    stop_connector(connector)
    Process.sleep(500)

    IO.puts("MCP_RUNTIME_E2E: disconnect recovery checking offline call")
    result = session_tool_result!(tenant_key, agent_id, tool, params)

    assert!(result.error == true, "offline device MCP call should fail structurally")

    assert!(
      String.contains?(result.content, "device_offline") or
        String.contains?(result.content, "disconnected"),
      "offline device MCP error did not identify device state: #{inspect(result)}"
    )

    IO.puts("MCP_RUNTIME_E2E: disconnect recovery starting connector")
    recovered = start_connector_with_token!(connector.token, device_alias, root)

    try do
      IO.puts("MCP_RUNTIME_E2E: disconnect recovery waiting for new connector runtime")

      _runtime =
        wait_for_connector_device_runtime_after!(group_id, device_alias, old_connector_run_id)

      IO.puts("MCP_RUNTIME_E2E: disconnect recovery refreshing discovery")

      conn =
        treq!(
          tenant_key,
          :post,
          "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding_id}/discover",
          %{}
        )

      assert!(
        conn["status"] in ["running", "degraded"],
        "recovered device discovery failed: #{inspect(conn)}"
      )

      IO.puts("MCP_RUNTIME_E2E: disconnect recovery calling recovered tool")
      recovered_call = call_mcp_tool_completed(tenant_key, agent_id, tool, params)

      assert!(
        recovered_call.error == false,
        "recovered device MCP call failed: #{inspect(recovered_call)}"
      )
    after
      IO.puts("MCP_RUNTIME_E2E: disconnect recovery stopping recovered connector")
      stop_connector(recovered)
    end
  end

  defp start_connector!(tenant_key, group_id, alias_name, root) do
    bin = System.fetch_env!("SALIX_CONNECT_BIN")

    token =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/connector-tokens", %{
        "name" => "MCP E2E Device",
        "alias" => alias_name,
        "expires_in_seconds" => 3600
      })["token"] || raise("connector token response did not include token")

    port = start_connector_process!(bin, token, alias_name, root)
    %{port: port, token: token}
  end

  defp start_connector_with_token!(token, alias_name, root) do
    bin = System.fetch_env!("SALIX_CONNECT_BIN")
    port = start_connector_process!(bin, token, alias_name, root)
    %{port: port, token: token}
  end

  defp start_connector_process!(bin, token, alias_name, root) do
    log_path = Path.join(System.tmp_dir!(), "salix-connect-#{alias_name}.log")
    File.rm(log_path)
    parent = self()

    args = [
      "--server",
      SalixWeb.Application.base_url(),
      "--connector-token",
      token,
      "--name",
      "MCP E2E Device",
      "--alias",
      alias_name,
      "--root",
      root,
      "--reconnect=false",
      "--system-info-interval",
      "0"
    ]

    owner =
      spawn(fn ->
        port =
          Port.open({:spawn_executable, bin}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            env: [
              {~c"SALIX_MCP_PARENT_SECRET", to_charlist("MCP_PARENT_ENV_SECRET_#{alias_name}")}
            ],
            args: args
          ])

        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, os_pid} -> os_pid
            _ -> nil
          end

        send(parent, {:mcp_connector_started, self(), os_pid, log_path})
        connector_port_loop(port, os_pid, log_path)
      end)

    receive do
      {:mcp_connector_started, ^owner, os_pid, ^log_path} ->
        %{owner: owner, os_pid: os_pid, log_path: log_path}
    after
      5_000 ->
        Process.exit(owner, :kill)
        raise("connector process did not start")
    end
  end

  defp wait_for_connector_device_runtime!(group_id, alias_name, attempts \\ 200)

  defp wait_for_connector_device_runtime!(group_id, alias_name, attempts) when attempts > 0 do
    case connector_device_runtime(group_id, alias_name) do
      {:ok, runtime, connector_run_id} ->
        {runtime, connector_run_id}

      :retry ->
        Process.sleep(250)
        wait_for_connector_device_runtime!(group_id, alias_name, attempts - 1)
    end
  end

  defp wait_for_connector_device_runtime!(group_id, alias_name, _attempts),
    do: raise("connector device runtime never connected group=#{group_id} alias=#{alias_name}")

  defp wait_for_connector_device_runtime_after!(
         group_id,
         alias_name,
         old_connector_run_id,
         attempts \\ 200
       )

  defp wait_for_connector_device_runtime_after!(
         group_id,
         alias_name,
         old_connector_run_id,
         attempts
       )
       when attempts > 0 do
    case connector_device_runtime(group_id, alias_name) do
      {:ok, runtime, connector_run_id} when connector_run_id != old_connector_run_id ->
        runtime

      _ ->
        Process.sleep(250)

        wait_for_connector_device_runtime_after!(
          group_id,
          alias_name,
          old_connector_run_id,
          attempts - 1
        )
    end
  end

  defp wait_for_connector_device_runtime_after!(
         group_id,
         alias_name,
         old_connector_run_id,
         _attempts
       ),
       do:
         raise(
           "connector device runtime did not reconnect group=#{group_id} alias=#{alias_name} old_run=#{old_connector_run_id}"
         )

  defp connector_device_runtime(group_id, alias_name) do
    with {:ok, envs} <- SalixEnv.Control.list_group_environments(group_id, tenant_id()),
         %{"connector_run_id" => connector_run_id} = env
         when is_binary(connector_run_id) and connector_run_id != "" <-
           Enum.find(envs, fn env ->
             env["alias"] == alias_name and env["status"] == "connected"
           end),
         %{"device_runtime_id" => device_runtime_id} = runtime
         when is_binary(device_runtime_id) and device_runtime_id != "" <-
           Enum.find(env["device_runtimes"] || [], &(&1["provider"] == "connector")) do
      {:ok, runtime, connector_run_id}
    else
      _ -> :retry
    end
  end

  defp connector_port_loop(port, os_pid, log_path) do
    receive do
      :stop_connector ->
        kill_os_pid(os_pid)
        connector_port_loop(port, os_pid, log_path)

      {^port, {:data, data}} ->
        File.write!(log_path, data, [:append])
        connector_port_loop(port, os_pid, log_path)

      {^port, {:exit_status, status}} ->
        File.write!(log_path, "\n[salix-connect exited status=#{status}]\n", [:append])

      {:EXIT, ^port, reason} ->
        File.write!(log_path, "\n[salix-connect port exit #{inspect(reason)}]\n", [:append])
    end
  end

  defp stop_connector(%{owner: owner, os_pid: os_pid}) when is_pid(owner) do
    ref = Process.monitor(owner)
    send(owner, :stop_connector)

    receive do
      {:DOWN, ^ref, :process, ^owner, _reason} -> :ok
    after
      1_000 ->
        kill_os_pid(os_pid)
        Process.exit(owner, :kill)
    end
  end

  defp stop_connector(%{port: port}), do: stop_connector(port)

  defp stop_connector(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> kill_os_pid(os_pid)
      _ -> :ok
    end
  end

  defp stop_connector(_port), do: :ok

  defp kill_os_pid(os_pid) when is_integer(os_pid),
    do: System.cmd("kill", [Integer.to_string(os_pid)])

  defp kill_os_pid(_os_pid), do: :ok

  defp first_target_ref!(definition) do
    metadata = definition["server_metadata"] || %{}

    (List.wrap(metadata["remotes"]) ++ List.wrap(metadata["packages"]))
    |> Enum.find_value(& &1["target_ref"])
    |> case do
      nil -> raise("definition has no target_ref: #{inspect(definition)}")
      target_ref -> target_ref
    end
  end

  defp find_mcp_tool!(tools, names) do
    Enum.find_value(names, fn candidate ->
      candidate = String.downcase(candidate)

      Enum.find(tools, fn tool ->
        tool_name = String.downcase(tool["operation_id"] || tool["name"] || "")
        String.contains?(tool_name, candidate)
      end)
    end) ||
      raise(
        "MCP tool not found for #{inspect(names)} in #{inspect(Enum.map(tools, &(&1["operation_id"] || &1["name"])))}"
      )
  end

  defp call_mcp_tool(tenant_key, agent_id, tool_name, params),
    do: session_tool_result!(tenant_key, agent_id, tool_name, params)

  defp session_tool_completed_result!(tenant_key, agent_id, tool_name, params) do
    result = session_tool_result!(tenant_key, agent_id, tool_name, params)

    case result.body do
      %{"status" => "running", "tool_call_id" => tool_call_id}
      when is_binary(tool_call_id) and tool_call_id != "" ->
        completed = wait_for_tool_result!(tenant_key, agent_id, tool_call_id)
        %{completed | body: async_tool_payload(completed)}

      _ ->
        result
    end
  end

  defp call_mcp_tool_completed(tenant_key, agent_id, tool_name, params) do
    result = call_mcp_tool(tenant_key, agent_id, tool_name, params)

    case result.body do
      %{"status" => "running", "tool_call_id" => tool_call_id}
      when is_binary(tool_call_id) and tool_call_id != "" ->
        wait_for_tool_result!(tenant_key, agent_id, tool_call_id)

      _ ->
        result
    end
  end

  defp wait_for_tool_result!(tenant_key, agent_id, tool_call_id),
    do: wait_for_tool_result!(tenant_key, agent_id, tool_call_id, async_tool_result_attempts())

  defp wait_for_tool_result!(tenant_key, agent_id, tool_call_id, attempts) when attempts > 0 do
    result =
      session_tool_result!(tenant_key, agent_id, "tool_call.get_result", %{
        "tool_call_id" => tool_call_id
      })

    record = async_result_record(result)

    case record["status"] do
      "running" ->
        Process.sleep(500)
        wait_for_tool_result!(tenant_key, agent_id, tool_call_id, attempts - 1)

      "completed" ->
        %{result | body: record, content: async_record_content(record), error: false}

      "failed" ->
        %{result | body: record, content: async_record_content(record), error: true}

      "cancelled" ->
        %{result | body: record, content: async_record_content(record), error: true}

      _ ->
        result
    end
  end

  defp wait_for_tool_result!(tenant_key, agent_id, tool_call_id, _attempts) do
    result =
      session_tool_result!(tenant_key, agent_id, "tool_call.get_result", %{
        "tool_call_id" => tool_call_id
      })

    raise("MCP async result did not complete for #{agent_id}/#{tool_call_id}: #{inspect(result)}")
  end

  defp async_tool_result_attempts, do: 120 * e2e_perf_factor()

  defp e2e_perf_factor do
    case Integer.parse(System.get_env("E2E_PERF_FACTOR", "1")) do
      {factor, ""} when factor > 0 -> factor
      _ -> 1
    end
  end

  defp async_result_record(%{body: %{"result" => encoded}}) when is_binary(encoded) do
    case Jason.decode(encoded) do
      {:ok, record} when is_map(record) -> record
      _ -> %{"status" => "completed", "result" => encoded}
    end
  end

  defp async_result_record(%{body: body}) when is_map(body), do: body

  defp async_result_record(%{content: content}) when is_binary(content),
    do: async_result_record(%{body: %{"result" => content}})

  defp async_result_record(_result), do: %{}

  defp async_record_content(%{"result" => result}) when is_binary(result), do: result
  defp async_record_content(%{"result" => result}), do: Jason.encode!(result)
  defp async_record_content(record), do: Jason.encode!(record)

  defp async_tool_payload(%{body: %{"result" => %{"content" => content}}})
       when is_binary(content),
       do: Jason.decode!(content)

  defp async_tool_payload(%{body: %{"result" => %{"output" => output}}}) when is_binary(output),
    do: Jason.decode!(output)

  defp async_tool_payload(%{content: content}) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"result" => %{"content" => result_content}}} when is_binary(result_content) ->
        Jason.decode!(result_content)

      {:ok, %{"result" => %{"output" => output}}} when is_binary(output) ->
        Jason.decode!(output)

      {:ok, payload} when is_map(payload) ->
        payload
    end
  end

  defp wait_for_tool_progress!(tenant_key, agent_id, tool_call_id, attempts \\ 30)

  defp wait_for_tool_progress!(tenant_key, agent_id, tool_call_id, attempts) when attempts > 0 do
    result =
      session_tool_result!(tenant_key, agent_id, "tool_call.get_status", %{
        "tool_call_id" => tool_call_id
      })

    progress = result.body["progress"]

    if result.error == false and is_map(progress) and map_size(progress) > 0 do
      result.body
    else
      Process.sleep(250)
      wait_for_tool_progress!(tenant_key, agent_id, tool_call_id, attempts - 1)
    end
  end

  defp wait_for_tool_progress!(tenant_key, agent_id, tool_call_id, _attempts) do
    result =
      session_tool_result!(tenant_key, agent_id, "tool_call.get_status", %{
        "tool_call_id" => tool_call_id
      })

    raise(
      "MCP async progress was not observed for #{agent_id}/#{tool_call_id}: #{inspect(result)}"
    )
  end

  defp write_async_mcp_server!(root, run_id) do
    path = Path.join(root, "mcp-async-progress-#{run_id}.js")

    File.write!(path, """
    const readline = require("node:readline");
    const rl = readline.createInterface({ input: process.stdin });
    const pending = new Map();

    function write(message) {
      process.stdout.write(JSON.stringify(message) + "\\n");
    }

    function send(id, result) {
      write({ jsonrpc: "2.0", id, result });
    }

    function fail(id, code, message, data) {
      write({ jsonrpc: "2.0", id, error: { code, message, data } });
    }

    function progress(id, value) {
      write({
        jsonrpc: "2.0",
        method: "notifications/progress",
        params: {
          progressToken: String(id),
          progress: value,
          total: 100,
          message: "MCP_ASYNC_PROGRESS_#{run_id}"
        }
      });
    }

    function clearPending(id) {
      const record = pending.get(String(id));
      if (!record) return;
      for (const timer of record.timers) clearTimeout(timer);
      pending.delete(String(id));
    }

    rl.on("line", (line) => {
      let msg;
      try {
        msg = JSON.parse(line);
      } catch (_err) {
        return;
      }

      if (msg.method === "notifications/cancelled") {
        const requestId = msg.params && msg.params.requestId;
        clearPending(requestId);
        return;
      }

      if (msg.id === undefined || msg.id === null) {
        return;
      }

      if (msg.method === "initialize") {
        send(msg.id, {
          protocolVersion: "2025-06-18",
          capabilities: { tools: {}, resources: {}, prompts: {} },
          serverInfo: { name: "salix-mcp-async-e2e", version: "1.0.0" }
        });
      } else if (msg.method === "tools/list") {
        send(msg.id, {
          tools: [
            {
              name: "slow_progress",
              description: "Runs long enough to exercise Salix async tool-call progress and cancellation.",
              inputSchema: {
                type: "object",
                properties: {
                  duration_ms: { type: "integer", description: "Total run duration in milliseconds." }
                },
                required: ["duration_ms"]
              }
            }
          ]
        });
      } else if (msg.method === "resources/list") {
        send(msg.id, {
          resources: [
            {
              uri: "memory://#{run_id}",
              name: "runtime-memory",
              description: "E2E MCP runtime resource"
            }
          ]
        });
      } else if (msg.method === "resources/read") {
        if (msg.params && msg.params.uri === "memory://#{run_id}") {
          send(msg.id, {
            contents: [
              {
                uri: "memory://#{run_id}",
                mimeType: "text/plain",
                text: "MCP_RESOURCE_OK_#{run_id}"
              }
            ]
          });
        } else {
          fail(msg.id, -32004, "resource not found", { uri: msg.params && msg.params.uri });
        }
      } else if (msg.method === "prompts/list") {
        send(msg.id, {
          prompts: [
            {
              name: "handoff",
              description: "E2E prompt handoff",
              arguments: [{ name: "topic", required: true }]
            }
          ]
        });
      } else if (msg.method === "prompts/get") {
        const topic = msg.params && msg.params.arguments && msg.params.arguments.topic;
        send(msg.id, {
          description: "E2E prompt handoff",
          messages: [
            {
              role: "user",
              content: { type: "text", text: String(topic || "") }
            }
          ]
        });
      } else if (msg.method === "tools/call" && msg.params && msg.params.name === "slow_progress") {
        const id = String(msg.id);
        const duration = Math.max(5000, Number(msg.params.arguments && msg.params.arguments.duration_ms) || 15000);
        const timers = [];
        pending.set(id, { timers });

        for (const [delay, value] of [[500, 10], [1000, 25], [1500, 50], [2000, 75]]) {
          timers.push(setTimeout(() => {
            if (pending.has(id)) progress(id, value);
          }, delay));
        }

        timers.push(setTimeout(() => {
          if (!pending.has(id)) return;
          pending.delete(id);
          send(id, { content: [{ type: "text", text: "MCP_ASYNC_COMPLETED_#{run_id}" }] });
        }, duration));
      } else {
        fail(msg.id, -32601, "method not found", { method: msg.method });
      }
    });
    """)

    path
  end

  defp write_error_mcp_server!(root, run_id) do
    path = Path.join(root, "mcp-tool-error-#{run_id}.js")

    File.write!(path, """
    const readline = require("node:readline");
    const rl = readline.createInterface({ input: process.stdin });

    function send(id, result) {
      process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
    }

    function fail(id, code, message, data) {
      process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message, data } }) + "\\n");
    }

    rl.on("line", (line) => {
      let msg;
      try {
        msg = JSON.parse(line);
      } catch (_err) {
        return;
      }
      if (msg.id === undefined || msg.id === null) {
        return;
      }

      if (msg.method === "initialize") {
        send(msg.id, {
          protocolVersion: "2025-06-18",
          capabilities: { tools: {} },
          serverInfo: { name: "salix-mcp-tool-error-e2e", version: "1.0.0" }
        });
      } else if (msg.method === "tools/list") {
        send(msg.id, {
          tools: [
            {
              name: "always_fails",
              description: "Always returns a JSON-RPC error so the client can distinguish tool failure from connection failure.",
              inputSchema: {
                type: "object",
                properties: { reason: { type: "string" } },
                required: ["reason"]
              }
            }
          ]
        });
      } else if (msg.method === "tools/call") {
        fail(msg.id, -32001, "intentional tool failure", {
          marker: "MCP_TOOL_ERROR_DOES_NOT_POISON_CONNECTION",
          parentSecret: process.env.SALIX_MCP_PARENT_SECRET || "",
          reason: msg.params && msg.params.arguments && msg.params.arguments.reason
        });
      } else {
        fail(msg.id, -32601, "method not found", { method: msg.method });
      }
    });
    """)

    path
  end

  defp write_discovery_error_mcp_server!(root, run_id) do
    path = Path.join(root, "mcp-discovery-error-#{run_id}.js")

    File.write!(path, """
    const readline = require("node:readline");
    const rl = readline.createInterface({ input: process.stdin });

    function send(id, result) {
      process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
    }

    function fail(id, code, message, data) {
      process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message, data } }) + "\\n");
    }

    rl.on("line", (line) => {
      let msg;
      try {
        msg = JSON.parse(line);
      } catch (_err) {
        return;
      }
      if (msg.id === undefined || msg.id === null) {
        return;
      }

      if (msg.method === "initialize") {
        send(msg.id, {
          protocolVersion: "2025-06-18",
          capabilities: { tools: {}, resources: {}, prompts: {} },
          serverInfo: { name: "salix-mcp-discovery-error-e2e", version: "1.0.0" }
        });
      } else if (msg.method === "tools/list") {
        send(msg.id, {
          tools: [
            {
              name: "safe_tool",
              description: "Discovered so the connection can remain degraded without leaking " + (process.env.MCP_DISCOVERY_TOKEN || ""),
              inputSchema: { type: "object", properties: {} }
            }
          ]
        });
      } else if (msg.method === "resources/list") {
        const secret = process.env.MCP_DISCOVERY_TOKEN || "";
        fail(msg.id, -32010, "discovery failed with token " + secret, {
          header: "Authorization: Bearer " + secret,
          stderr: "token=" + secret
        });
      } else if (msg.method === "resources/read") {
        const secret = process.env.MCP_DISCOVERY_TOKEN || "";
        if (msg.params && msg.params.uri === "memory://#{run_id}/success") {
          send(msg.id, {
            contents: [
              {
                uri: "memory://#{run_id}/success",
                mimeType: "text/plain",
                text: "MCP_RESOURCE_SECRET_BOUNDARY_OK_#{run_id} " + secret
              }
            ]
          });
        } else {
          fail(msg.id, -32012, "resource failed with token " + secret, {
            header: "Authorization: Bearer " + secret,
            stderr: "token=" + secret
          });
        }
      } else if (msg.method === "prompts/list") {
        const secret = process.env.MCP_DISCOVERY_TOKEN || "";
        send(msg.id, {
          prompts: [
            {
              name: "secret_prompt",
              description: "Prompt metadata includes " + secret
            }
          ]
        });
      } else if (msg.method === "prompts/get") {
        const secret = process.env.MCP_DISCOVERY_TOKEN || "";
        if (msg.params && msg.params.name === "secret_prompt") {
          send(msg.id, {
            description: "Prompt success includes " + secret,
            messages: [
              {
                role: "user",
                content: { type: "text", text: "MCP_PROMPT_SECRET_BOUNDARY_OK_#{run_id} " + secret }
              }
            ]
          });
        } else {
          fail(msg.id, -32013, "prompt failed with token " + secret, {
            header: "Authorization: Bearer " + secret,
            stderr: "token=" + secret
          });
        }
      } else if (msg.method === "tools/call") {
        const secret = process.env.MCP_DISCOVERY_TOKEN || "";
        fail(msg.id, -32011, "tool failed with token " + secret, {
          header: "Authorization: Bearer " + secret,
          stderr: "token=" + secret
        });
      } else {
        fail(msg.id, -32601, "method not found", { method: msg.method });
      }
    });
    """)

    path
  end

  defp playwright_ref!(content, label) do
    line =
      content
      |> to_string()
      |> String.split("\n")
      |> Enum.find(&(String.contains?(&1, label) and String.contains?(&1, "[ref=")))

    case Regex.run(~r/\[ref=([^\]]+)\]/, line || "") do
      [_, ref] -> ref
      _ -> raise("could not find Playwright ref for #{label}: #{content}")
    end
  end

  defp remote_url, do: System.get_env("MCP_E2E_REMOTE_URL") || "https://mcp.context7.com/mcp"

  defp config_values do
    case System.get_env("MCP_E2E_CONFIG_JSON") do
      nil -> %{}
      json -> Jason.decode!(json)
    end
  end

  defp tenant_id, do: Process.get(:tenant_id)

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise(message)

  defp assert_no_secret!(value, secrets, message) when is_list(secrets) do
    encoded = Jason.encode!(value)

    case Enum.find(secrets, &String.contains?(encoded, &1)) do
      nil -> :ok
      leaked -> raise(message <> " leaked=#{leaked}: " <> encoded)
    end
  end

  defp assert_no_secret!(value, secret, message),
    do: assert_no_secret!(value, [secret], message)

  defp unique do
    System.unique_integer([:positive])
    |> Integer.to_string(36)
    |> String.downcase()
  end
end

MCPRuntimeE2E.run()
