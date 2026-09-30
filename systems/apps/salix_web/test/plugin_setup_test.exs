defmodule Salix.Control.PluginSetupTest do
  use ExUnit.Case, async: false

  alias Salix.Control.{OAuthBindings, Plugins, PluginSetup, RemoteMCPOAuth, Tenants}
  alias SalixMCP.Gateway
  alias SalixMCP.Store, as: MCPStore

  defmodule MockLinearMCP do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def base_url(pid), do: GenServer.call(pid, :base_url)
    def calls(pid), do: GenServer.call(pid, :calls)
    def clear_calls(pid), do: GenServer.call(pid, :clear_calls)

    def expect_authorization(pid, authorization),
      do: GenServer.call(pid, {:expect_authorization, authorization})

    @impl true
    def init(opts) do
      {:ok, bandit} =
        Bandit.start_link(
          plug: {__MODULE__.Plug, self()},
          port: 0,
          ip: {127, 0, 0, 1},
          startup_log: false
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

      {:ok,
       %{
         port: port,
         expected_authorization: Keyword.fetch!(opts, :expected_authorization),
         calls: []
       }}
    end

    @impl true
    def handle_call(:base_url, _from, state),
      do: {:reply, "http://127.0.0.1:#{state.port}", state}

    def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}
    def handle_call(:clear_calls, _from, state), do: {:reply, :ok, %{state | calls: []}}

    def handle_call({:expect_authorization, authorization}, _from, state),
      do: {:reply, :ok, %{state | expected_authorization: authorization}}

    def handle_call({:authorize, authorization, method}, _from, state) do
      authorized = authorization == state.expected_authorization
      call = %{method: method, authorized: authorized}
      {:reply, authorized, %{state | calls: [call | state.calls]}}
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

        if GenServer.call(owner, {:authorize, authorization, request["method"]}) do
          respond(conn, request)
        else
          send_resp(conn, 401, "authorization required")
        end
      end

      defp respond(conn, %{"id" => id, "method" => "initialize"}) do
        json(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "Linear Test MCP", "version" => "1.0.0"}
          }
        })
      end

      defp respond(conn, %{"id" => id, "method" => "tools/list"}) do
        json(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "tools" => [
              %{
                "name" => "echo",
                "description" => "Echo a marker.",
                "inputSchema" => %{
                  "type" => "object",
                  "properties" => %{"marker" => %{"type" => "string"}},
                  "required" => ["marker"]
                }
              }
            ]
          }
        })
      end

      defp respond(conn, %{"id" => id, "method" => "tools/call", "params" => params}) do
        marker = get_in(params, ["arguments", "marker"])

        json(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "content" => [%{"type" => "text", "text" => "LINEAR_PLUGIN_E2E #{marker}"}]
          }
        })
      end

      defp respond(conn, %{"method" => _method}), do: send_resp(conn, 202, "")

      defp json(conn, body) do
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))
      end
    end
  end

  setup do
    previous_store = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn ->
      if previous_store,
        do: Application.put_env(:salix_store, :s3_backend, previous_store),
        else: Application.delete_env(:salix_store, :s3_backend)
    end)

    assert {:ok, %{created: created}} = SalixMCP.Builtins.seed_builtin_definitions()
    assert created >= 8
    {:ok, tenant} = Tenants.create(%{"name" => "Linear Plugin Test"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Linear"}, tenant["tenant_id"])

    %{tenant_id: tenant["tenant_id"], group_id: group["group_id"]}
  end

  test "the product MCP catalog and fixed default-disabled Linear plugin are idempotent" do
    assert {:ok, %{created: 0, updated: 0, unchanged: unchanged}} =
             SalixMCP.Builtins.seed_builtin_definitions()

    assert unchanged >= 8

    assert {:ok, definition} =
             MCPStore.get_definition("mcp1_0000000000000000004", "")

    assert definition["supports_server"]
    assert get_in(definition, ["salix_metadata", "supported_placements"]) == ["server"]

    assert get_in(definition, ["server_metadata", "remotes"]) == [
             %{
               "target_ref" => "remote:linear",
               "transport" => "streamable-http",
               "url" => "https://mcp.linear.app/mcp",
               "headers_schema" => %{
                 "Authorization" => %{
                   "isRequired" => true,
                   "isSecret" => true,
                   "value" => "Bearer ${LINEAR_ACCESS_TOKEN}"
                 }
               }
             }
           ]

    remote_definitions = %{
      "mcp1_0000000000000000003" => {"remote:github", "https://api.githubcopilot.com/mcp/"},
      "mcp1_0000000000000000005" => {"remote:feishu", "https://mcp.feishu.cn/mcp"},
      "mcp1_0000000000000000006" =>
        {"remote:google-workspace", "https://workspacemcp.googleapis.com/mcp/v1"},
      "mcp1_0000000000000000007" => {"remote:notion", "https://mcp.notion.com/mcp"},
      "mcp1_0000000000000000008" => {"remote:slack", "https://mcp.slack.com/mcp"}
    }

    for {mcp_id, {target_ref, url}} <- remote_definitions do
      assert {:ok, product_definition} = MCPStore.get_definition(mcp_id, "")
      assert product_definition["supports_server"]
      assert "server" in get_in(product_definition, ["salix_metadata", "supported_placements"])

      assert [%{"target_ref" => ^target_ref, "url" => ^url}] =
               get_in(product_definition, ["server_metadata", "remotes"])
               |> Enum.map(&Map.take(&1, ~w(target_ref url)))
    end

    plugin = Enum.find(Plugins.system_plugins(), &(&1["plugin_id"] == "linear"))
    refute plugin["default_enabled"]
    assert plugin["setup"]["type"] == "integration"
    assert plugin["setup"]["default_connection"] == "linear-managed"

    assert Enum.map(plugin["setup"]["connections"], & &1["kind"]) ==
             ~w(native_mcp_oauth managed_oauth)

    assert hd(plugin["setup"]["connections"])["scopes"] == ~w(read write openid email)

    assert hd(plugin["setup"]["mcps"])["auth_refs"] ==
             ["linear-native", "linear-managed"]

    assert plugin["refs"]["tool_refs"] == ["mcp.linear.*"]
    assert plugin["refs"]["mcp_refs"] == [%{"mcp_id" => definition["mcp_id"]}]

    assert plugin["refs"]["oauth_requirements"] == [
             %{"provider" => "linear", "alias" => "linear", "scopes" => ~w(read write)}
           ]

    expected_mcps = %{
      "feishu" => {"mcp1_0000000000000000005", "remote:feishu"},
      "github" => {"mcp1_0000000000000000003", "remote:github"},
      "google" => {"mcp1_0000000000000000006", "remote:google-workspace"},
      "linear" => {"mcp1_0000000000000000004", "remote:linear"},
      "notion" => {"mcp1_0000000000000000007", "remote:notion"},
      "slack" => {"mcp1_0000000000000000008", "remote:slack"}
    }

    products =
      Plugins.system_plugins()
      |> Enum.filter(&(get_in(&1, ["setup", "type"]) == "integration"))

    assert Enum.map(products, & &1["plugin_id"]) |> Enum.sort() ==
             ~w(feishu github google linear notion slack)

    assert Map.new(products, &{&1["plugin_id"], get_in(&1, ["ui", "brand"])}) == %{
             "feishu" => "feishu",
             "github" => "github",
             "google" => "google",
             "linear" => "linear",
             "notion" => "notion",
             "slack" => "slack"
           }

    refute Enum.find(products, &(&1["plugin_id"] == "google"))["default_enabled"]

    assert get_in(
             Enum.find(products, &(&1["plugin_id"] == "google")),
             ["setup", "mcps", Access.at(0), "icon"]
           ) == "google"

    for product <- products do
      assert [mcp] = product["setup"]["mcps"]
      {mcp_id, target_ref} = Map.fetch!(expected_mcps, product["plugin_id"])
      assert mcp["mcp_id"] == mcp_id
      assert mcp["target_ref"] == target_ref
      assert mcp["placement"] == "server"
      assert is_list(mcp["auth_refs"])
      assert mcp["auth_refs"] != []
      assert product["refs"]["mcp_refs"] == [%{"mcp_id" => mcp_id}]

      for connection <- product["setup"]["connections"], connection["kind"] == "managed_oauth" do
        assert connection["alias"] == connection["provider"]
      end
    end

    external_im = Enum.find(Plugins.system_plugins(), &(&1["plugin_id"] == "external-im"))
    refute "im_api.slack.*" in external_im["refs"]["tool_refs"]
    refute "im_api.feishu.*" in external_im["refs"]["tool_refs"]
  end

  test "every product plugin resolves its MCP and connection dependencies", context do
    assert {:ok, definitions} = Plugins.list_definitions(context.tenant_id, context.group_id)

    for plugin_id <- ~w(feishu github google linear notion slack) do
      status = Enum.find(definitions, &(&1["plugin_id"] == plugin_id))["setup_status"]
      assert status["type"] == "integration"
      assert length(status["mcps"]) == 1
      assert status["connections"] != []
    end

    assert {:ok, %{"bindings" => [github], "connection" => %{"kind" => "managed_oauth"}}} =
             Plugins.prepare_group_setup(context.tenant_id, context.group_id, "github")

    assert github["alias"] == "github"
    assert get_in(github, ["oauth_binding_refs", "GITHUB_ACCESS_TOKEN", "provider"]) == "github"

    assert {:ok, %{"bindings" => [], "connection" => %{"kind" => "im_connect"}}} =
             Plugins.prepare_group_setup(context.tenant_id, context.group_id, "feishu")
  end

  test "managed MCP OAuth requires an active credential with every declared scope", context do
    github = Enum.find(Plugins.system_plugins(), &(&1["plugin_id"] == "github"))
    connection = hd(github["setup"]["connections"])
    required_scopes = connection["scopes"]

    assert {:ok, %{"bindings" => [binding]}} =
             Plugins.prepare_group_setup(context.tenant_id, context.group_id, "github")

    assert get_in(binding, ["oauth_binding_refs", "GITHUB_ACCESS_TOKEN", "scopes"]) ==
             Enum.sort(required_scopes)

    connection_id = "conn-github-mcp-scopes"

    assert :ok =
             SalixStore.OAuth.put(connection_id, %{
               "connection_id" => connection_id,
               "provider" => "github",
               "access_token" => "github-plugin-test-token",
               "scopes" => ["repo"],
               "status" => "active"
             })

    assert {:ok, _oauth_binding, nil} =
             OAuthBindings.put(
               context.tenant_id,
               context.group_id,
               "github",
               "github",
               connection_id
             )

    assert %{"connections" => connections, "mcps" => [mcp]} =
             plugin_status(context, "github")

    assert hd(connections)["state"] == "missing_scopes"
    assert mcp["state"] == "waiting_for_oauth"

    assert {:error, {:missing_oauth, "OAuth connection is missing required scopes"}} =
             Salix.Bindings.MCPCredentials.resolve(binding)

    assert :ok =
             SalixStore.OAuth.put(connection_id, %{
               "connection_id" => connection_id,
               "provider" => "github",
               "access_token" => "github-plugin-test-token",
               "scopes" => required_scopes,
               "status" => "active"
             })

    assert %{"connections" => connections, "mcps" => [mcp]} =
             plugin_status(context, "github")

    assert hd(connections)["state"] == "connected"
    assert mcp["state"] == "ready_on_use"

    assert {:ok, %{"GITHUB_ACCESS_TOKEN" => "github-plugin-test-token"}} =
             Salix.Bindings.MCPCredentials.resolve(binding)

    assert :ok =
             SalixStore.OAuth.put(connection_id, %{
               "connection_id" => connection_id,
               "provider" => "github",
               "access_token" => "github-plugin-test-token",
               "scopes" => required_scopes,
               "status" => "reauthorization_required"
             })

    assert %{"connections" => connections, "mcps" => [mcp]} =
             plugin_status(context, "github")

    assert hd(connections)["state"] == "reauthorization_required"
    assert mcp["state"] == "waiting_for_oauth"

    assert {:error, {:missing_oauth, "OAuth connection requires reauthorization"}} =
             Salix.Bindings.MCPCredentials.resolve(binding)
  end

  test "native MCP OAuth resolves an explicit challenge scope before metadata fallback" do
    metadata = %{"scopes_supported" => ["read", "write"]}

    assert RemoteMCPOAuth.authorization_scope(%{}, metadata) == "read write"

    assert RemoteMCPOAuth.authorization_scope(%{"scope" => "read"}, metadata) == "read"
  end

  defp plugin_status(context, plugin_id) do
    assert {:ok, definitions} = Plugins.list_definitions(context.tenant_id, context.group_id)
    Enum.find(definitions, &(&1["plugin_id"] == plugin_id))["setup_status"]
  end

  test "native MCP OAuth returns only to a configured Comma web origin" do
    [configured_base_url | _] =
      Application.fetch_env!(:salix_web, :oauth_return_base_urls)

    configured_uri = URI.parse(configured_base_url)

    configured_port =
      configured_uri.port || if(configured_uri.scheme == "https", do: 443, else: 80)

    plugin_path = "/orgs/example/projects/project/plugins/linear"

    assert RemoteMCPOAuth.redirect_after_allowed?(
             URI.to_string(%{configured_uri | path: plugin_path})
           )

    assert RemoteMCPOAuth.redirect_after_allowed?(plugin_path)

    refute RemoteMCPOAuth.redirect_after_allowed?(
             URI.to_string(%{configured_uri | path: plugin_path, port: configured_port + 1})
           )

    refute RemoteMCPOAuth.redirect_after_allowed?("https://example.test/plugins/linear")

    refute RemoteMCPOAuth.redirect_after_allowed?(
             URI.to_string(%{configured_uri | path: "/plugins/linear", userinfo: "attacker"})
           )
  end

  test "native setup is idempotent and resolves status without exposing tokens", context do
    assert {:ok, %{"bindings" => [binding], "connection" => connection}} =
             Plugins.prepare_group_setup(
               context.tenant_id,
               context.group_id,
               "linear",
               "linear-native"
             )

    assert connection["kind"] == "native_mcp_oauth"
    assert binding["alias"] == "linear"
    assert binding["placement"] == "server"
    assert binding["oauth_binding_refs"] == %{}

    assert {:ok, %{"bindings" => [same_binding]}} =
             Plugins.prepare_group_setup(
               context.tenant_id,
               context.group_id,
               "linear",
               "linear-native"
             )

    assert same_binding["binding_id"] == binding["binding_id"]
    assert same_binding["revision"] == binding["revision"]

    connection_id = "conn-linear-native-status"

    assert :ok =
             SalixStore.OAuth.put(connection_id, %{
               "connection_id" => connection_id,
               "tenant" => context.tenant_id,
               "provider" => "remote_mcp",
               "provider_kind" => "remote_mcp",
               "access_token" => "linear-native-status-token",
               "status" => "active"
             })

    assert {:ok, oauth_binding, nil} =
             OAuthBindings.put_remote_mcp(
               context.tenant_id,
               context.group_id,
               "mcp_linear_native_status",
               "linear",
               connection_id,
               %{"mcp_binding_id" => binding["binding_id"]}
             )

    assert {:ok, _binding} =
             MCPStore.set_remote_oauth_binding(
               context.tenant_id,
               context.group_id,
               binding["binding_id"],
               oauth_binding["binding_id"]
             )

    assert {:ok, definitions} = Plugins.list_definitions(context.tenant_id, context.group_id)
    status = Enum.find(definitions, &(&1["plugin_id"] == "linear"))["setup_status"]
    native = Enum.find(status["connections"], &(&1["id"] == "linear-native"))
    assert native["state"] == "connected"
    assert hd(status["mcps"])["state"] == "ready_on_use"
    refute inspect(status) =~ "token"
  end

  test "native MCP OAuth satisfies a declared authorization header at runtime", context do
    previous_private_targets = Application.get_env(:salix_mcp, :allow_private_http_targets)
    Application.put_env(:salix_mcp, :allow_private_http_targets, true)

    on_exit(fn ->
      if is_nil(previous_private_targets) do
        Application.delete_env(:salix_mcp, :allow_private_http_targets)
      else
        Application.put_env(:salix_mcp, :allow_private_http_targets, previous_private_targets)
      end
    end)

    mcp =
      start_supervised!({MockLinearMCP, expected_authorization: "Bearer linear-native-token"})

    assert {:ok, _definition, :updated} =
             MCPStore.upsert_system_definition(%{
               "mcp_id" => "mcp1_0000000000000000004",
               "tenant_id" => "",
               "name" => "Linear",
               "description" => "Linear native OAuth test MCP.",
               "server_metadata" => %{
                 "name" => "Linear",
                 "remotes" => [
                   %{
                     "target_ref" => "remote:linear",
                     "transport" => "streamable-http",
                     "url" => MockLinearMCP.base_url(mcp) <> "/mcp",
                     "headers_schema" => %{
                       "Authorization" => %{
                         "isRequired" => true,
                         "isSecret" => true,
                         "value" => "Bearer ${LINEAR_ACCESS_TOKEN}"
                       }
                     }
                   }
                 ]
               },
               "supports_server" => true,
               "recommended_placement" => "server",
               "supported_placements" => ["server"],
               "auth_requirements" => %{"linear" => ["oauth"]},
               "declared_capabilities" => %{"tools" => true},
               "environment_requirements" => %{"server" => ["public_network"]},
               "trust" => %{"source" => "system_builtin"},
               "created_by" => "system"
             })

    managed_connection_id = "conn-linear-managed-runtime"

    assert :ok =
             SalixStore.OAuth.put(managed_connection_id, %{
               "connection_id" => managed_connection_id,
               "tenant" => context.tenant_id,
               "provider" => "linear",
               "access_token" => "linear-managed-token",
               "scopes" => ~w(read write),
               "status" => "active"
             })

    assert {:ok, managed_oauth_binding, nil} =
             OAuthBindings.put(
               context.tenant_id,
               context.group_id,
               "linear",
               "linear",
               managed_connection_id
             )

    assert {:ok, %{"bindings" => [managed_binding]}} =
             Plugins.prepare_group_setup(
               context.tenant_id,
               context.group_id,
               "linear",
               "linear-managed"
             )

    assert get_in(managed_binding, ["oauth_binding_refs", "LINEAR_ACCESS_TOKEN", "provider"]) ==
             "linear"

    assert {:ok, %{"bindings" => [binding]}} =
             Plugins.prepare_group_setup(
               context.tenant_id,
               context.group_id,
               "linear",
               "linear-native"
             )

    assert binding["binding_id"] == managed_binding["binding_id"]

    assert get_in(binding, ["oauth_binding_refs", "LINEAR_ACCESS_TOKEN", "alias"]) ==
             "linear"

    connection_id = "conn-linear-native-runtime"

    assert :ok =
             SalixStore.OAuth.put(connection_id, %{
               "connection_id" => connection_id,
               "tenant" => context.tenant_id,
               "provider" => "remote_mcp",
               "provider_kind" => "remote_mcp",
               "access_token" => "linear-native-token",
               "status" => "active"
             })

    assert {:ok, oauth_binding, nil} =
             OAuthBindings.put_remote_mcp(
               context.tenant_id,
               context.group_id,
               "mcp_linear_native_runtime",
               "linear",
               connection_id,
               %{"mcp_binding_id" => binding["binding_id"]}
             )

    assert {:ok, _binding} =
             MCPStore.set_remote_oauth_binding(
               context.tenant_id,
               context.group_id,
               binding["binding_id"],
               oauth_binding["binding_id"]
             )

    assert :ok = MockLinearMCP.clear_calls(mcp)

    assert {:ok, result} =
             Gateway.call_tool(
               context.tenant_id,
               context.group_id,
               binding["binding_id"],
               "echo",
               %{"marker" => "native-plugin"}
             )

    assert result["content"] == "LINEAR_PLUGIN_E2E native-plugin"
    refute inspect(result) =~ "linear-native-token"
    assert Enum.all?(MockLinearMCP.calls(mcp), & &1.authorized)

    assert :ok = OAuthBindings.delete(context.group_id, managed_oauth_binding["binding_id"])

    assert {:ok, _connection} =
             Gateway.restart_binding(
               context.tenant_id,
               context.group_id,
               binding["binding_id"]
             )

    assert {:ok, native_only_result} =
             Gateway.call_tool(
               context.tenant_id,
               context.group_id,
               binding["binding_id"],
               "echo",
               %{"marker" => "native-only"}
             )

    assert native_only_result["content"] == "LINEAR_PLUGIN_E2E native-only"
    assert Enum.all?(MockLinearMCP.calls(mcp), & &1.authorized)

    assert {:ok, _managed_oauth_binding, nil} =
             OAuthBindings.put(
               context.tenant_id,
               context.group_id,
               "linear",
               "linear",
               managed_connection_id
             )

    assert :ok = OAuthBindings.delete(context.group_id, oauth_binding["binding_id"])
    assert :ok = MockLinearMCP.expect_authorization(mcp, "Bearer linear-managed-token")

    assert {:ok, _connection} =
             Gateway.restart_binding(
               context.tenant_id,
               context.group_id,
               binding["binding_id"]
             )

    assert {:ok, managed_fallback_result} =
             Gateway.call_tool(
               context.tenant_id,
               context.group_id,
               binding["binding_id"],
               "echo",
               %{"marker" => "managed-fallback"}
             )

    assert managed_fallback_result["content"] == "LINEAR_PLUGIN_E2E managed-fallback"
    assert Enum.all?(MockLinearMCP.calls(mcp), & &1.authorized)

    assert %{"connections" => connections, "mcps" => [mcp_status]} =
             plugin_status(context, "linear")

    assert Enum.find(connections, &(&1["id"] == "linear-native"))["state"] ==
             "not_connected"

    assert Enum.find(connections, &(&1["id"] == "linear-managed"))["state"] == "connected"
    assert mcp_status["state"] == "running"
  end

  test "native MCP OAuth disconnect clears the dependency and revokes its connection", context do
    assert {:ok, %{"bindings" => [mcp_binding]}} =
             Plugins.prepare_group_setup(
               context.tenant_id,
               context.group_id,
               "linear",
               "linear-native"
             )

    connection_id = "conn-linear-disconnect"

    assert :ok =
             SalixStore.OAuth.put(connection_id, %{
               "connection_id" => connection_id,
               "tenant" => context.tenant_id,
               "provider" => "remote_mcp",
               "provider_kind" => "remote_mcp",
               "access_token" => "linear-native-disconnect-token",
               "status" => "active"
             })

    assert {:ok, oauth_binding, nil} =
             OAuthBindings.put_remote_mcp(
               context.tenant_id,
               context.group_id,
               "mcp_linear_disconnect",
               "linear",
               connection_id,
               %{"mcp_binding_id" => mcp_binding["binding_id"]}
             )

    assert {:ok, _binding} =
             MCPStore.set_remote_oauth_binding(
               context.tenant_id,
               context.group_id,
               mcp_binding["binding_id"],
               oauth_binding["binding_id"]
             )

    assert :ok =
             RemoteMCPOAuth.disconnect(
               context.tenant_id,
               context.group_id,
               mcp_binding["binding_id"]
             )

    assert {:ok, disconnected} =
             MCPStore.get_binding(
               context.tenant_id,
               context.group_id,
               mcp_binding["binding_id"]
             )

    assert disconnected["remote_oauth_binding_id"] == ""
    assert {:error, :not_found} = OAuthBindings.get(context.group_id, oauth_binding["binding_id"])
    assert {:ok, revoked} = SalixStore.OAuth.get(connection_id)
    assert revoked["status"] == "revoked"
    refute Map.has_key?(revoked, "access_token")
  end

  test "setup rejects an unrelated binding that occupies the linear alias", context do
    assert {:ok, _binding} =
             MCPStore.create_binding(context.tenant_id, context.group_id, %{
               "mcp_id" => "mcp1_0000000000000000001",
               "alias" => "linear",
               "target_ref" => "remote:context7",
               "placement" => "server"
             })

    assert {:error, {:conflict, message}} =
             Plugins.prepare_group_setup(
               context.tenant_id,
               context.group_id,
               "linear",
               "linear-native"
             )

    assert message =~ "alias"
  end

  test "the coordinator is declaration-driven and limited to system plugins", context do
    setup = %{
      "owner_scope" => "system",
      "setup" => %{
        "type" => "integration",
        "default_connection" => "github-oauth",
        "connections" => [
          %{
            "id" => "github-oauth",
            "kind" => "managed_oauth",
            "provider" => "github",
            "alias" => "github",
            "credential_env_var" => "GITHUB_TOKEN",
            "scopes" => ["repo"]
          },
          %{"id" => "github-composio", "kind" => "composio", "toolkit" => "github"}
        ],
        "mcps" => [
          %{
            "mcp_id" => "mcp1_0000000000000000004",
            "alias" => "github-test",
            "target_ref" => "remote:linear",
            "placement" => "server",
            "auth_ref" => "github-oauth"
          }
        ]
      }
    }

    assert {:ok, %{"bindings" => [binding], "connection" => oauth}} =
             PluginSetup.prepare(context.tenant_id, context.group_id, setup)

    assert binding["alias"] == "github-test"
    assert get_in(binding, ["oauth_binding_refs", "GITHUB_TOKEN", "provider"]) == "github"
    assert oauth["scopes"] == ["repo"]

    assert {:error, {:bad_request, message}} =
             PluginSetup.prepare(
               context.tenant_id,
               context.group_id,
               Map.put(setup, "owner_scope", "group")
             )

    assert message =~ "system plugins"

    invalid = put_in(setup, ["setup", "connections", Access.at(0), "scopes"], "repo")

    assert {:error, {:bad_request, _message}} =
             PluginSetup.prepare(context.tenant_id, context.group_id, invalid)

    duplicate_refs =
      put_in(
        setup,
        ["setup", "mcps", Access.at(0), "auth_refs"],
        ["github-oauth", "github-oauth"]
      )

    assert {:error, {:bad_request, message}} =
             PluginSetup.prepare(context.tenant_id, context.group_id, duplicate_refs)

    assert message =~ "dependencies"

    missing_ref =
      put_in(setup, ["setup", "mcps", Access.at(0), "auth_refs"], ["missing-oauth"])

    assert {:error, {:bad_request, message}} =
             PluginSetup.prepare(context.tenant_id, context.group_id, missing_ref)

    assert message =~ "dependencies"

    composio_mcp =
      put_in(setup, ["setup", "mcps", Access.at(0), "auth_refs"], ["github-composio"])

    assert {:error, {:bad_request, message}} =
             PluginSetup.prepare(context.tenant_id, context.group_id, composio_mcp)

    assert message =~ "dependencies"
  end

  test "plugin enablement gates tools without mutating the managed binding", context do
    assert {:ok, disabled} =
             Plugins.runtime_projection(%{
               "tenant_id" => context.tenant_id,
               "group_id" => context.group_id
             })

    refute "linear" in disabled["enabled_plugin_ids"]
    refute "mcp.linear." in disabled["allowed_tool_prefixes"]

    assert {:ok, %{"bindings" => [binding]}} =
             Plugins.prepare_group_setup(
               context.tenant_id,
               context.group_id,
               "linear",
               "linear-native"
             )

    assert {:ok, _enablement} =
             Plugins.enable_group(context.tenant_id, context.group_id, "linear")

    assert {:ok, enabled} =
             Plugins.runtime_projection(%{
               "tenant_id" => context.tenant_id,
               "group_id" => context.group_id
             })

    assert "linear" in enabled["enabled_plugin_ids"]
    assert "mcp.linear." in enabled["allowed_tool_prefixes"]

    assert {:ok, _enablement} =
             Plugins.disable_group(context.tenant_id, context.group_id, "linear")

    assert {:ok, same_binding} =
             MCPStore.get_binding(context.tenant_id, context.group_id, binding["binding_id"])

    assert same_binding["binding_id"] == binding["binding_id"]
  end

  test "managed OAuth can drive first-use discovery and a tool call through a declared binding",
       context do
    previous_private_targets = Application.get_env(:salix_mcp, :allow_private_http_targets)
    Application.put_env(:salix_mcp, :allow_private_http_targets, true)

    on_exit(fn ->
      if is_nil(previous_private_targets) do
        Application.delete_env(:salix_mcp, :allow_private_http_targets)
      else
        Application.put_env(:salix_mcp, :allow_private_http_targets, previous_private_targets)
      end
    end)

    mcp =
      start_supervised!(
        {MockLinearMCP, expected_authorization: "Bearer linear-plugin-test-token"}
      )

    assert {:ok, _definition, :updated} =
             MCPStore.upsert_system_definition(%{
               "mcp_id" => "mcp1_0000000000000000004",
               "tenant_id" => "",
               "name" => "Linear",
               "description" => "Linear test MCP.",
               "server_metadata" => %{
                 "name" => "Linear",
                 "remotes" => [
                   %{
                     "target_ref" => "remote:linear",
                     "transport" => "streamable-http",
                     "url" => MockLinearMCP.base_url(mcp) <> "/mcp",
                     "headers_schema" => %{
                       "Authorization" => %{
                         "isRequired" => true,
                         "isSecret" => true,
                         "value" => "Bearer ${LINEAR_ACCESS_TOKEN}"
                       }
                     }
                   }
                 ]
               },
               "supports_server" => true,
               "recommended_placement" => "server",
               "supported_placements" => ["server"],
               "auth_requirements" => %{"linear" => ["oauth"]},
               "declared_capabilities" => %{"tools" => true},
               "environment_requirements" => %{"server" => ["public_network"]},
               "trust" => %{"source" => "system_builtin"},
               "created_by" => "system"
             })

    managed_setup = %{
      "owner_scope" => "system",
      "setup" => %{
        "type" => "integration",
        "default_connection" => "linear-managed",
        "connections" => [
          %{
            "id" => "linear-native",
            "kind" => "native_mcp_oauth",
            "scopes" => ~w(read write openid email)
          },
          %{
            "id" => "linear-managed",
            "kind" => "managed_oauth",
            "provider" => "linear",
            "alias" => "linear",
            "credential_env_var" => "LINEAR_ACCESS_TOKEN",
            "scopes" => ~w(read write)
          }
        ],
        "mcps" => [
          %{
            "mcp_id" => "mcp1_0000000000000000004",
            "alias" => "linear",
            "target_ref" => "remote:linear",
            "placement" => "server",
            "auth_refs" => ["linear-native", "linear-managed"]
          }
        ]
      }
    }

    assert {:ok, %{"bindings" => [binding]}} =
             PluginSetup.prepare(context.tenant_id, context.group_id, managed_setup)

    assert get_in(binding, ["connection", "status"]) == "missing_oauth"

    connection_id = "conn-linear-first-use"

    assert :ok =
             SalixStore.OAuth.put(connection_id, %{
               "connection_id" => connection_id,
               "tenant" => context.tenant_id,
               "provider" => "linear",
               "access_token" => "linear-plugin-test-token",
               "scopes" => ~w(read write),
               "status" => "active"
             })

    assert {:ok, _oauth_binding, nil} =
             OAuthBindings.put(
               context.tenant_id,
               context.group_id,
               "linear",
               "linear",
               connection_id
             )

    assert {:ok, result} =
             Gateway.call_tool(
               context.tenant_id,
               context.group_id,
               binding["binding_id"],
               "echo",
               %{"marker" => "managed-plugin"}
             )

    assert result["status"] == "completed"
    assert result["content"] == "LINEAR_PLUGIN_E2E managed-plugin"
    refute inspect(result) =~ "linear-plugin-test-token"

    assert {:ok, _running_binding, _definition, connection} =
             MCPStore.get_binding_with_definition(
               context.tenant_id,
               context.group_id,
               binding["binding_id"]
             )

    assert connection["status"] == "running"

    assert Enum.map(MockLinearMCP.calls(mcp), & &1.method) == [
             "initialize",
             "notifications/initialized",
             "tools/list",
             "tools/call"
           ]

    assert Enum.all?(MockLinearMCP.calls(mcp), & &1.authorized)
  end
end
