defmodule Salix.Control.FastmailPluginTest do
  use SystemsClock.Case, async: false

  import ExUnit.CaptureLog

  alias Salix.Control.{Groups, Plugins, PluginSetup, Tenants}
  alias SalixMCP.{Config, Gateway}
  alias SalixMCP.Store, as: MCPStore

  # Fixture tool definitions for local mock testing only — not a claim about
  # Fastmail's live MCP tool names or schemas.
  @fixture_tools [
    %{
      "name" => "fixture_search_mail",
      "description" => "Search fixture mailbox messages.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Search query"}
        },
        "required" => ["query"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "name" => "fixture_read_message",
      "description" => "Read a fixture mailbox message by id.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string"}
        },
        "required" => ["id"]
      },
      "annotations" => %{"readOnlyHint" => true}
    }
  ]

  defmodule MockMCP do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def url(pid), do: GenServer.call(pid, :url)
    def calls(pid), do: GenServer.call(pid, :calls)
    def set_mode(pid, mode), do: GenServer.call(pid, {:set_mode, mode})

    @impl true
    def init(opts) do
      {:ok, listener} =
        Bandit.start_link(
          plug: {__MODULE__.Plug, SystemsRuntime.Proc.self()},
          port: 0,
          ip: {127, 0, 0, 1},
          startup_log: false
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

      {:ok,
       %{
         port: port,
         expected_token: Keyword.get(opts, :expected_token, "fastmail-fixture-token"),
         mode: Keyword.get(opts, :mode, :ok),
         tools: Keyword.fetch!(opts, :tools),
         calls: []
       }}
    end

    @impl true
    def handle_call(:url, _from, state),
      do: {:reply, "http://127.0.0.1:#{state.port}/mcp", state}

    def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

    def handle_call({:set_mode, mode}, _from, state),
      do: {:reply, :ok, %{state | mode: mode}}

    def handle_call({:request, authorization, method}, _from, state) do
      authorized = authorization == "Bearer " <> state.expected_token

      outcome =
        case state.mode do
          :expired -> :expired
          :unauthorized -> :unauthorized
          :rate_limited -> :rate_limited
          mode when authorized -> mode
          _ -> :unauthorized
        end

      call = %{method: method, authorization: authorization, authorized: authorized}
      {:reply, {outcome, state.tools}, %{state | calls: [call | state.calls]}}
    end

    defmodule Plug do
      @behaviour Elixir.Plug
      import Elixir.Plug.Conn

      @impl true
      def init(owner), do: owner

      @impl true
      def call(conn, owner) do
        {:ok, body, conn} = read_body(conn)
        request = Jason.decode!(body)
        authorization = conn |> get_req_header("authorization") |> List.first()
        token = extract_token(authorization)
        {outcome, tools} = GenServer.call(owner, {:request, authorization, request["method"]})

        case outcome do
          :ok ->
            respond(conn, request, tools, token)

          :tool_error ->
            respond_tool_error(conn, request, tools, token)

          :rpc_error ->
            respond_rpc_error(conn, request, tools, token)

          :unauthorized ->
            conn
            |> put_resp_header(
              "www-authenticate",
              ~s(Bearer error="invalid_token", error_description="rejected #{token}")
            )
            |> send_resp(401, "authorization required for #{token}")

          :expired ->
            conn
            |> put_resp_header(
              "www-authenticate",
              ~s(Bearer error="expired_token", error_description="expired #{token}")
            )
            |> send_resp(401, "token expired #{token}")

          :rate_limited ->
            conn
            |> put_resp_header("retry-after", "30")
            |> send_resp(429, "rate limited for #{token}")
        end
      end

      defp respond(conn, %{"id" => id, "method" => "initialize"}, _tools, _token) do
        json(conn, id, %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "Fixture Fastmail MCP", "version" => "1"}
        })
      end

      defp respond(conn, %{"id" => id, "method" => "tools/list"}, tools, _token) do
        json(conn, id, %{"tools" => tools})
      end

      defp respond(conn, %{"id" => id, "method" => "tools/call"}, _tools, token) do
        # Intentionally echo the received token to verify redaction.
        json(conn, id, %{
          "content" => [%{"type" => "text", "text" => "Fixture mail result #{token}"}]
        })
      end

      defp respond(conn, %{"method" => _}, _tools, _token), do: send_resp(conn, 202, "")

      defp respond_tool_error(conn, %{"id" => id, "method" => "tools/call"}, _tools, token) do
        json(conn, id, %{
          "isError" => true,
          "content" => [%{"type" => "text", "text" => "Upstream tool error echoing #{token}"}]
        })
      end

      defp respond_tool_error(conn, request, tools, token),
        do: respond(conn, request, tools, token)

      defp respond_rpc_error(conn, %{"id" => id, "method" => "tools/call"}, _tools, token) do
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => id,
            "error" => %{
              "code" => -32000,
              "message" => "Upstream RPC failure echoing #{token}"
            }
          })
        )
      end

      defp respond_rpc_error(conn, request, tools, token),
        do: respond(conn, request, tools, token)

      defp json(conn, id, result) do
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
      end

      defp extract_token("Bearer " <> token), do: token
      defp extract_token(other), do: to_string(other || "")
    end
  end

  setup do
    keys = [:s3_backend]
    previous = Map.new(keys, &{&1, SystemsRuntime.get_env(:salix_store, &1)})
    previous_private = SystemsRuntime.get_env(:salix_mcp, :allow_private_http_targets)
    previous_overrides = SystemsRuntime.get_env(:salix_mcp, :remote_target_overrides)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_mcp, :allow_private_http_targets, true)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore(:salix_store, key, value) end)
      restore(:salix_mcp, :allow_private_http_targets, previous_private)
      restore(:salix_mcp, :remote_target_overrides, previous_overrides)
    end)

    assert {:ok, _} = SalixMCP.Builtins.seed_builtin_definitions()
    {:ok, tenant} = Tenants.create(%{"name" => "Fastmail test"})
    {:ok, group} = Groups.create(%{"name" => "Mail"}, tenant["tenant_id"])
    %{tenant_id: tenant["tenant_id"], group_id: group["group_id"]}
  end

  test "dynamic discovery, bearer auth, tool call, enable/disable, and disconnect", context do
    token = "fastmail-fixture-token"
    mock = mock_server(expected_token: token)
    refute enabled?(context)

    assert :ok = configure(context, token)
    [binding] = fastmail_bindings(context)

    assert {:ok, stored, definition, connection} =
             MCPStore.get_binding_with_definition(
               context.tenant_id,
               context.group_id,
               binding["binding_id"]
             )

    assert connection["status"] == "running"

    discovered_tools = get_in(connection, ["discovered", "tools"]) || []

    for expected <- @fixture_tools do
      found = Enum.find(discovered_tools, &(&1["name"] == expected["name"]))
      assert found, "expected dynamically discovered tool #{expected["name"]}"
      assert found["description"] == expected["description"]
      assert found["inputSchema"] == expected["inputSchema"]
    end

    assert token in Config.redaction_values(definition, stored)
    refute inspect(MCPStore.public_binding(stored)) =~ token
    refute inspect(MCPStore.public_binding_with_connection(stored)) =~ token

    assert {:ok, result} =
             Gateway.call_tool(
               context.tenant_id,
               context.group_id,
               binding["binding_id"],
               "fixture_search_mail",
               %{"query" => "invoice"}
             )

    assert result["status"] == "completed"
    assert result["content"] =~ "Fixture mail result"
    refute inspect(result) =~ token

    calls = MockMCP.calls(mock)
    assert Enum.all?(calls, &(&1.authorization == "Bearer " <> token and &1.authorized))
    assert Enum.any?(calls, &(&1.method == "tools/list"))
    assert Enum.any?(calls, &(&1.method == "tools/call"))

    assert {:ok, _} = Plugins.enable_group(context.tenant_id, context.group_id, "fastmail")
    assert enabled?(context)
    assert {:ok, _} = Plugins.disable_group(context.tenant_id, context.group_id, "fastmail")
    refute enabled?(context)

    assert :ok =
             Plugins.disconnect_group_credentials(
               context.tenant_id,
               context.group_id,
               "fastmail",
               "fastmail-api-key"
             )

    assert fastmail_bindings(context) == []
    assert fastmail_connection_state(context) == "not_connected"
  end

  test "missing, blank, malformed, and wrong-key credentials fail before any remote call",
       context do
    mock = mock_server()

    invalid_payloads = [
      %{},
      %{"FASTMAIL_MCP_TOKEN" => ""},
      %{"FASTMAIL_MCP_TOKEN" => "   "},
      %{"JMAP_TOKEN" => "wrong-kind"},
      %{"FASTMAIL_MCP_TOKEN" => "has space"}
    ]

    for values <- invalid_payloads do
      assert {:error, {:bad_request, _}} =
               Plugins.configure_group_credentials(
                 context.tenant_id,
                 context.group_id,
                 "fastmail",
                 "fastmail-api-key",
                 values
               )
    end

    assert MockMCP.calls(mock) == []
    assert fastmail_bindings(context) == []
  end

  test "rejected and expired tokens fail setup and runtime calls without leaking the token",
       context do
    mock = mock_server(expected_token: "fastmail-valid-token")

    assert {:error, :plugin_credential_rejected} = configure(context, "revoked-fixture-token")
    refute enabled?(context)
    assert Enum.any?(MockMCP.calls(mock), &(not &1.authorized))

    MockMCP.set_mode(mock, :expired)
    assert {:error, :plugin_credential_rejected} = configure(context, "expired-fixture-token")
    refute enabled?(context)

    MockMCP.set_mode(mock, :ok)
    assert :ok = configure(context, "fastmail-valid-token")
    [binding] = fastmail_bindings(context)

    MockMCP.set_mode(mock, :unauthorized)

    assert {:ok, revoked_result} =
             Gateway.call_tool(
               context.tenant_id,
               context.group_id,
               binding["binding_id"],
               "fixture_search_mail",
               %{"query" => "after-revoke"}
             )

    assert revoked_result["status"] in ["auth_failed", "reauthorization_required"]
    refute inspect(revoked_result) =~ "fastmail-valid-token"

    MockMCP.set_mode(mock, :ok)

    assert {:ok, %{"status" => "running"}} =
             Gateway.refresh_binding(context.tenant_id, context.group_id, binding["binding_id"])

    MockMCP.set_mode(mock, :expired)

    assert {:ok, expired_result} =
             Gateway.call_tool(
               context.tenant_id,
               context.group_id,
               binding["binding_id"],
               "fixture_search_mail",
               %{"query" => "after-expire"}
             )

    assert expired_result["status"] in ["auth_failed", "reauthorization_required"]
    refute inspect(expired_result) =~ "fastmail-valid-token"
  end

  test "HTTP 429 rate limits are unavailable/protocol errors, never credential rejections",
       context do
    token = "fastmail-rate-limit-token"
    mock = mock_server(expected_token: token, mode: :rate_limited)

    assert {:error, :plugin_connection_unavailable} = configure(context, token)
    refute enabled?(context)

    MockMCP.set_mode(mock, :ok)
    assert :ok = configure(context, token)
    [binding] = fastmail_bindings(context)

    MockMCP.set_mode(mock, :rate_limited)

    assert {:ok, result} =
             Gateway.call_tool(
               context.tenant_id,
               context.group_id,
               binding["binding_id"],
               "fixture_search_mail",
               %{"query" => "throttled"}
             )

    assert result["status"] == "protocol_error"
    assert result["content"] =~ "MCP HTTP 429"
    refute result["status"] in ["auth_failed", "reauthorization_required"]
    refute inspect(result) =~ token
  end

  test "credentials, bindings, tool calls, and projections stay isolated across groups and tenants",
       context do
    mock_server(expected_token: "fastmail-isolated-token")
    assert :ok = configure(context, "fastmail-isolated-token")
    assert {:ok, _} = Plugins.enable_group(context.tenant_id, context.group_id, "fastmail")
    [binding] = fastmail_bindings(context)

    {:ok, other_group} = Groups.create(%{"name" => "Other mail"}, context.tenant_id)
    {:ok, other_tenant} = Tenants.create(%{"name" => "Other tenant"})
    {:ok, foreign_group} = Groups.create(%{"name" => "Foreign mail"}, other_tenant["tenant_id"])

    for {tenant_id, group_id} <- [
          {context.tenant_id, other_group["group_id"]},
          {other_tenant["tenant_id"], foreign_group["group_id"]}
        ] do
      assert {:error, :not_found} =
               MCPStore.get_binding(tenant_id, group_id, binding["binding_id"])

      assert MCPStore.list_group_bindings(tenant_id, group_id) == []

      assert {:error, :not_found} =
               Gateway.call_tool(
                 tenant_id,
                 group_id,
                 binding["binding_id"],
                 "fixture_search_mail",
                 %{"query" => "leak"}
               )

      refute enabled?(%{tenant_id: tenant_id, group_id: group_id})
    end
  end

  test "logs, projections, last_error, and tool responses redact the token across all failure paths",
       context do
    token = "fm1-super-secret-redaction-token-9981"
    mock = mock_server(expected_token: token)

    log =
      capture_log([level: :debug, metadata: :all], fn ->
        assert :ok = configure(context, token)
        [binding] = fastmail_bindings(context)

        assert {:ok, stored, definition, _connection} =
                 MCPStore.get_binding_with_definition(
                   context.tenant_id,
                   context.group_id,
                   binding["binding_id"]
                 )

        assert token in Config.redaction_values(definition, stored)
        refute inspect(MCPStore.public_binding(stored)) =~ token
        refute inspect(MCPStore.public_binding_with_connection(stored)) =~ token

        assert {:ok, ok_res} =
                 Gateway.call_tool(
                   context.tenant_id,
                   context.group_id,
                   binding["binding_id"],
                   "fixture_search_mail",
                   %{"query" => "ok"}
                 )

        assert ok_res["status"] == "completed"
        refute inspect(ok_res) =~ token

        MockMCP.set_mode(mock, :tool_error)

        assert {:ok, tool_err_res} =
                 Gateway.call_tool(
                   context.tenant_id,
                   context.group_id,
                   binding["binding_id"],
                   "fixture_search_mail",
                   %{"query" => "tool-error"}
                 )

        assert tool_err_res["status"] == "error"
        refute inspect(tool_err_res) =~ token

        MockMCP.set_mode(mock, :rpc_error)

        assert {:ok, rpc_err_res} =
                 Gateway.call_tool(
                   context.tenant_id,
                   context.group_id,
                   binding["binding_id"],
                   "fixture_search_mail",
                   %{"query" => "rpc-error"}
                 )

        assert rpc_err_res["status"] == "error"
        refute inspect(rpc_err_res) =~ token

        MockMCP.set_mode(mock, :unauthorized)

        assert {:ok, unauth_res} =
                 Gateway.call_tool(
                   context.tenant_id,
                   context.group_id,
                   binding["binding_id"],
                   "fixture_search_mail",
                   %{"query" => "unauth"}
                 )

        assert unauth_res["status"] in ["auth_failed", "reauthorization_required"]
        refute inspect(unauth_res) =~ token

        assert {:ok, stored_after_401, _def, conn_401} =
                 MCPStore.get_binding_with_definition(
                   context.tenant_id,
                   context.group_id,
                   binding["binding_id"]
                 )

        refute inspect(conn_401["last_error"]) =~ token
        refute inspect(MCPStore.public_binding_with_connection(stored_after_401)) =~ token

        MockMCP.set_mode(mock, :ok)

        assert {:ok, %{"status" => "running"}} =
                 Gateway.refresh_binding(
                   context.tenant_id,
                   context.group_id,
                   binding["binding_id"]
                 )

        MockMCP.set_mode(mock, :rate_limited)

        assert {:ok, rl_res} =
                 Gateway.call_tool(
                   context.tenant_id,
                   context.group_id,
                   binding["binding_id"],
                   "fixture_search_mail",
                   %{"query" => "429"}
                 )

        assert rl_res["status"] == "protocol_error"
        refute inspect(rl_res) =~ token

        assert {:ok, stored_after_429, _def, conn_429} =
                 MCPStore.get_binding_with_definition(
                   context.tenant_id,
                   context.group_id,
                   binding["binding_id"]
                 )

        refute inspect(conn_429["last_error"]) =~ token
        refute inspect(MCPStore.public_binding_with_connection(stored_after_429)) =~ token
      end)

    refute log =~ token
  end

  defp mock_server(opts \\ []) do
    mock = start_supervised!({MockMCP, Keyword.put_new(opts, :tools, @fixture_tools)})

    SystemsRuntime.put_env(:salix_mcp, :remote_target_overrides, %{
      "remote:fastmail" => MockMCP.url(mock)
    })

    mock
  end

  defp configure(context, token) do
    Plugins.configure_group_credentials(
      context.tenant_id,
      context.group_id,
      "fastmail",
      "fastmail-api-key",
      %{"FASTMAIL_MCP_TOKEN" => token}
    )
  end

  defp fastmail_bindings(context) do
    MCPStore.list_group_bindings(context.tenant_id, context.group_id)
    |> Enum.filter(&(&1["alias"] == "fastmail"))
  end

  defp fastmail_connection_state(context) do
    fastmail_def =
      Enum.find(SalixMCP.HostedServices.plugin_definitions(), &(&1["plugin_id"] == "fastmail"))

    [resolved] =
      PluginSetup.resolve_statuses([fastmail_def], context.tenant_id, context.group_id)

    resolved
    |> get_in(["setup_status", "connections"])
    |> List.first()
    |> Map.get("state")
  end

  defp enabled?(context) do
    assert {:ok, projection} =
             Plugins.runtime_projection(%{
               "tenant_id" => context.tenant_id,
               "group_id" => context.group_id
             })

    "mcp.fastmail." in projection["allowed_tool_prefixes"]
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
