defmodule CommaWeb.NativePluginConnectionsTest do
  require SystemsRuntime.Proc

  use Comma.DataCase, async: false

  alias CommaWeb.PluginConnections
  alias Salix.Control.{OAuthApps, OAuthBindings}

  defmodule LegacyComposio do
    def get(_tenant), do: {:ok, %{}}

    def list_connected_accounts_all(_, _),
      do:
        {:ok,
         [
           %{
             "id" => "old-composio-github",
             "toolkit" => %{"slug" => "github"},
             "status" => "ACTIVE"
           }
         ]}
  end

  defmodule UnconfiguredComposio do
    def get(_tenant), do: {:error, :not_configured}
  end

  defmodule Provider do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      case conn.request_path do
        "/x-mcp" ->
          {:ok, body, conn} = read_body(conn)
          request = Jason.decode!(body)
          authorization = get_req_header(conn, "authorization")

          if probe = SystemsRuntime.get_env(:comma_web, :x_mcp_probe),
            do: SystemsRuntime.Proc.send(probe, {:x_mcp_request, authorization, request})

          if authorization in [
               ["Bearer x-reader-one"],
               ["Bearer x-reader-two"],
               ["Bearer x-oauth-user"]
             ] do
            result =
              case request["method"] do
                "initialize" ->
                  %{
                    "protocolVersion" => "2025-06-18",
                    "capabilities" => %{"tools" => %{}},
                    "serverInfo" => %{"name" => "X test", "version" => "1"}
                  }

                "tools/list" ->
                  %{
                    "tools" =>
                      Enum.map(
                        ~w(search_posts_all create_users_bookmark get_users_bookmarks unknown_read),
                        fn name ->
                          %{
                            "name" => name,
                            "inputSchema" => %{"type" => "object"},
                            "annotations" => %{"readOnlyHint" => true}
                          }
                        end
                      )
                  }

                "tools/call" ->
                  %{"content" => [%{"type" => "text", "text" => "X tool result"}]}

                _ ->
                  nil
              end

            if result do
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(
                200,
                Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
              )
            else
              send_resp(conn, 202, "")
            end
          else
            send_resp(conn, 401, "rejected " <> Enum.join(authorization))
          end

        "/x/token" ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "access_token" => "x-oauth-user",
              "token_type" => "bearer",
              "scope" =>
                "tweet.read tweet.write users.read media.write follows.read follows.write dm.read dm.write bookmark.read bookmark.write offline.access"
            })
          )

        "/x/me" ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{"data" => %{"id" => "user-1", "username" => "reader"}})
          )

        "/slack-mcp" ->
          authorized = get_req_header(conn, "authorization") == ["Bearer xoxp-comma-local-token"]

          if probe = SystemsRuntime.get_env(:comma_web, :slack_mcp_probe),
            do: SystemsRuntime.Proc.send(probe, {:slack_mcp_request, authorized})

          if gate = SystemsRuntime.get_env(:comma_web, :slack_mcp_gate) do
            SystemsRuntime.Proc.send(gate, {:slack_mcp_blocked, SystemsRuntime.Proc.self()})

            SystemsRuntime.Proc.receive do
              :release -> :ok
            after
              5_000 -> :ok
            end

            SystemsRuntime.Proc.send(gate, :slack_mcp_unblocked)
          end

          cond do
            SystemsRuntime.get_env(:comma_web, :slack_mcp_rejected, false) ->
              send_resp(conn, 400, "App not approved for Slack MCP server access.")

            authorized ->
              SalixWeb.LocalOAuthMock.mcp_resource(conn)

            true ->
              send_resp(conn, 401, "authorization required")
          end

        "/v1/local-oauth/github/token" ->
          if probe = SystemsRuntime.get_env(:comma_web, :oauth_token_probe) do
            SystemsRuntime.Proc.send(probe, {:oauth_exchange, SystemsRuntime.Proc.self()})

            SystemsRuntime.Proc.receive do
              :continue -> :ok
            after
              5_000 -> raise "OAuth callback probe timed out"
            end
          end

          SalixWeb.LocalOAuthMock.call(conn, [])

        "/notion/token" ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              access_token: "notion-api-test",
              workspace_id: "workspace",
              workspace_name: "Test"
            })
          )

        _ ->
          SalixWeb.LocalOAuthMock.call(conn, [])
      end
    end
  end

  setup do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)

    keys = [
      {:salix_web, :local_oauth_mock},
      {:salix_web, :public_base_url},
      {:salix_web, :composio_settings_mod},
      {:salix_web, :composio_client_mod},
      {:salix_store, :oauth_endpoint_overrides},
      {:salix_mcp, :remote_target_overrides},
      {:salix_mcp, :private_http_target_allowlist},
      {:salix_mcp, :credential_resolver_mod},
      {:comma_web, :oauth_token_probe},
      {:comma_web, :slack_mcp_probe},
      {:comma_web, :slack_mcp_rejected},
      {:comma_web, :slack_mcp_gate},
      {:comma_web, :x_mcp_probe}
    ]

    previous = Enum.map(keys, fn {app, key} -> {app, key, SystemsRuntime.get_env(app, key)} end)
    SystemsRuntime.put_env(:salix_web, :composio_settings_mod, LegacyComposio)
    SystemsRuntime.put_env(:salix_web, :composio_client_mod, LegacyComposio)

    bandit =
      start_supervised!({Bandit, plug: Provider, port: 0, ip: {127, 0, 0, 1}, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(bandit)
    base = "http://127.0.0.1:#{port}"
    SystemsRuntime.put_env(:salix_web, :public_base_url, base)
    SystemsRuntime.put_env(:salix_web, :local_oauth_mock, true)
    SystemsRuntime.put_env(:salix_mcp, :credential_resolver_mod, Salix.Bindings.MCPCredentials)
    # Only replace provider endpoints; authorization state and callbacks remain real.
    SystemsRuntime.put_env(:salix_store, :oauth_endpoint_overrides, %{
      "github" => %{
        "authorize_url" => base <> "/v1/local-oauth/github/authorize",
        "token_url" => base <> "/v1/local-oauth/github/token",
        "api_url" => base <> "/v1/local-oauth/github"
      },
      "slack" => %{
        "authorize_url" => base <> "/v1/local-oauth/slack/authorize",
        "token_url" => base <> "/v1/local-oauth/slack/token",
        "revoke_url" => base <> "/v1/local-oauth/slack/revoke"
      },
      "notion" => %{"token_url" => base <> "/notion/token"},
      "x" => %{
        "authorize_url" => base <> "/x/authorize",
        "token_url" => base <> "/x/token",
        "api_url" => base <> "/x/me"
      }
    })

    SystemsRuntime.put_env(:salix_mcp, :remote_target_overrides, %{
      "remote:notion" => base <> "/v1/local-oauth/mcp/resource",
      "remote:github" => base <> "/v1/local-oauth/mcp/resource",
      "remote:slack" => base <> "/slack-mcp",
      "remote:x" => base <> "/x-mcp"
    })

    SystemsRuntime.put_env(:salix_mcp, :private_http_target_allowlist, [
      base <> "/v1/local-oauth/mcp/resource",
      base <> "/slack-mcp",
      base <> "/x-mcp"
    ])

    on_exit(fn ->
      # Background MCP refreshes must not outlive this test's sandbox and mocks.
      eventually(
        fn ->
          SystemsRuntime.TaskSupervisor.children(SalixWeb.OAuthMCPRefreshSupervisor) == []
        end,
        3000
      )

      Enum.each(previous, fn
        {app, key, nil} -> SystemsRuntime.delete_env(app, key)
        {app, key, value} -> SystemsRuntime.put_env(app, key, value)
      end)

      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "native-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user)
    {:ok, _} = SalixMCP.Builtins.seed_builtin_definitions()

    {:ok, _} =
      OAuthApps.put(workspace["salix_tenant_id"], "notion", %{
        "client_id" => "test",
        "client_secret" => "test"
      })

    %{user: user, workspace: workspace}
  end

  test "Lark is not open for installation in Comma", %{user: user, workspace: w} do
    assert {:ok, plugins} = Comma.Plugins.list(user, %{}, w["id"])
    assert Enum.any?(plugins, &(&1["id"] == "notion"))
    refute Enum.any?(plugins, &(&1["id"] == "lark"))
    assert {:error, :not_found} = Comma.Plugins.install(user, %{}, w["id"], "lark")
  end

  test "X installs with a workspace token, reads through MCP, rotates, and disconnects", %{
    user: user,
    workspace: w
  } do
    SystemsRuntime.put_env(:comma_web, :x_mcp_probe, SystemsRuntime.Proc.self())
    assert {:ok, prompt} = PluginConnections.install(user, %{}, w["id"], "x-twitter")
    assert prompt["configuration"]["key"] == "X_BEARER_TOKEN"
    refute prompt["plugin"]["installed"]
    assert prompt["authorization"] == nil
    refute_received {:x_mcp_request, _, _}

    assert {:ok, installed} =
             PluginConnections.install(user, %{}, w["id"], "x-twitter", %{
               "config_values" => %{"X_BEARER_TOKEN" => "x-reader-one"}
             })

    assert installed["plugin"]["installed"]
    refute Jason.encode!(installed) =~ "x-reader-one"
    assert_received {:x_mcp_request, ["Bearer x-reader-one"], %{"method" => "initialize"}}
    assert {:ok, status} = PluginConnections.get(user, %{}, w["id"], "x-twitter")
    assert status["connection"]["state"] == "connected"

    [binding] = SalixMCP.Store.list_group_bindings(w["salix_tenant_id"], w["default_group_id"])
    assert binding["placement"] == "server"

    assert get_in(binding, ["connection", "discovered", "tools"]) |> Enum.map(& &1["name"]) == [
             "search_posts_all"
           ]

    refute Jason.encode!(binding) =~ "x-reader-one"

    assert {:ok, %{"status" => "completed"}} =
             SalixMCP.Gateway.call_tool(
               w["salix_tenant_id"],
               w["default_group_id"],
               binding["binding_id"],
               "search_posts_all",
               %{"query" => "comma", "max_results" => 10}
             )

    assert_received {:x_mcp_request, ["Bearer x-reader-one"], %{"method" => "tools/call"}}

    # Even misleading remote readOnlyHint annotations cannot admit writes or unknown tools.
    for tool <- ~w(create_users_bookmark get_users_bookmarks unknown_read) do
      assert {:error, :mcp_tool_not_allowed} =
               SalixMCP.Gateway.call_tool(
                 w["salix_tenant_id"],
                 w["default_group_id"],
                 binding["binding_id"],
                 tool,
                 %{}
               )
    end

    refute_received {:x_mcp_request, _, %{"method" => "tools/call"}}

    assert {:ok, _} =
             PluginConnections.install(user, %{}, w["id"], "x-twitter", %{
               "config_values" => %{"X_BEARER_TOKEN" => "x-reader-two"}
             })

    assert_received {:x_mcp_request, ["Bearer x-reader-two"], %{"method" => "initialize"}}
    assert {:ok, removed} = PluginConnections.uninstall(user, %{}, w["id"], "x-twitter")
    refute removed["installed"]

    assert {:error, :not_found} =
             SalixMCP.Store.get_binding(
               w["salix_tenant_id"],
               w["default_group_id"],
               binding["binding_id"]
             )

    assert {:error, :not_found} =
             SalixMCP.Gateway.call_tool(
               w["salix_tenant_id"],
               w["default_group_id"],
               binding["binding_id"],
               "search_posts_all",
               %{}
             )
  end

  test "X rejects invalid credentials and another user cannot configure its connection", %{
    user: user,
    workspace: w
  } do
    SystemsRuntime.put_env(:comma_web, :x_mcp_probe, SystemsRuntime.Proc.self())

    assert {:error, {:bad_request, _}} =
             PluginConnections.install(user, %{}, w["id"], "x-twitter", %{
               "config_values" => %{"X_BEARER_TOKEN" => "Bearer accidental-prefix"}
             })

    refute_received {:x_mcp_request, _, _}

    assert {:error, :plugin_credential_rejected} =
             PluginConnections.install(user, %{}, w["id"], "x-twitter", %{
               "config_values" => %{"X_BEARER_TOKEN" => "rejected-secret"}
             })

    assert {:ok, plugins} = Comma.Plugins.list(user, %{}, w["id"])
    refute Enum.find(plugins, &(&1["id"] == "x-twitter"))["installed"]
    bindings = SalixMCP.Store.list_group_bindings(w["salix_tenant_id"], w["default_group_id"])
    refute Jason.encode!(bindings) =~ "rejected-secret"

    {:ok, other} =
      Comma.Accounts.create_user(%{
        "email" => "x-other-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    assert {:error, :forbidden} =
             PluginConnections.install(other, %{}, w["id"], "x-twitter", %{
               "config_values" => %{"X_BEARER_TOKEN" => "x-reader-two"}
             })

    refute_received {:x_mcp_request, ["Bearer x-reader-two"], _}
  end

  test "Salix X prefers newly connected OAuth and only falls back after disconnect", %{
    workspace: w
  } do
    SystemsRuntime.put_env(:comma_web, :x_mcp_probe, SystemsRuntime.Proc.self())
    w = CommaWeb.TestWorkers.with_default_worker!(w)
    agent_id = w["default_worker_agent_id"]

    assert :ok =
             Salix.Control.Plugins.configure_group_credentials(
               w["salix_tenant_id"],
               w["default_group_id"],
               "x-twitter",
               "x-api-key",
               %{"X_BEARER_TOKEN" => "x-reader-one"}
             )

    call = fn ->
      SalixMCP.Provider.call_tool(
        agent_id,
        "x",
        "search_posts_all",
        %{"query" => "comma", "max_results" => 10},
        %{}
      )
    end

    write = fn ->
      SalixMCP.Provider.call_tool(
        agent_id,
        "x",
        "create_users_bookmark",
        %{"id" => "user-1", "tweet_id" => "post-1"},
        %{}
      )
    end

    assert {:error, missing_tool} = write.()
    assert missing_tool =~ "not found"
    {oauth, connection} = connect_x_oauth_callback(w)
    assert eventually(fn -> x_tool_discovered?(w, "create_users_bookmark") end)
    assert {:ok, %{"status" => "completed"}} = call.()
    assert_received {:x_mcp_request, ["Bearer x-oauth-user"], %{"method" => "tools/call"}}
    refute_received {:x_mcp_request, ["Bearer x-reader-one"], %{"method" => "tools/call"}}

    assert {:ok, %{"status" => "completed"}} = write.()

    assert_received {:x_mcp_request, ["Bearer x-oauth-user"],
                     %{"method" => "tools/call", "params" => %{"name" => "create_users_bookmark"}}}

    # Old read grants still read and the connection reports the missing scopes.
    :ok =
      SalixStore.OAuth.put(
        connection["connection_id"],
        Map.put(connection, "scopes", ~w(tweet.read users.read offline.access))
      )

    assert {:ok, %{"status" => "completed"}} = call.()
    assert_received {:x_mcp_request, ["Bearer x-oauth-user"], %{"method" => "tools/call"}}
    assert shared_x_oauth_state(w) == "missing_scopes"
    :ok = SalixStore.OAuth.put(connection["connection_id"], connection)

    # OAuth discovery came from the callback, without a manual MCP refresh.
    assert x_tool_discovered?(w, "create_users_bookmark")

    assert :ok =
             SalixStore.OAuth.put(
               connection["connection_id"],
               Map.put(connection, "status", "revoked")
             )

    assert {:ok, result} = call.()
    refute result["status"] == "completed"
    assert {:ok, result} = write.()
    refute result["status"] == "completed"
    refute_received {:x_mcp_request, _, %{"method" => "tools/call"}}
    assert shared_x_oauth_state(w) == "reauthorization_required"

    assert :ok = OAuthBindings.delete(w["default_group_id"], oauth["binding_id"])

    assert eventually(fn ->
             x_tool_discovered?(w, "search_posts_all") and
               not x_tool_discovered?(w, "create_users_bookmark")
           end)

    assert {:error, missing_tool} = write.()
    assert missing_tool =~ "not found"
    refute_received {:x_mcp_request, _, %{"method" => "tools/call"}}
    assert {:ok, %{"status" => "completed"}} = call.()
    assert_received {:x_mcp_request, ["Bearer x-reader-one"], %{"method" => "tools/call"}}

    {oauth, _} = connect_x_oauth(w)
    assert eventually(fn -> x_tool_discovered?(w, "create_users_bookmark") end)

    assert :ok =
             Salix.Control.Plugins.disconnect_group_credentials(
               w["salix_tenant_id"],
               w["default_group_id"],
               "x-twitter",
               "x-api-key"
             )

    assert {:ok, _} = OAuthBindings.get(w["default_group_id"], oauth["binding_id"])
    assert {:ok, %{"status" => "completed"}} = call.()
    assert_received {:x_mcp_request, ["Bearer x-oauth-user"], %{"method" => "tools/call"}}

    # With no fallback token, failed discovery can retain schemas but never grants access.
    assert :ok = OAuthBindings.delete(w["default_group_id"], oauth["binding_id"])

    assert eventually(fn ->
             case SalixMCP.Store.list_group_bindings(w["salix_tenant_id"], w["default_group_id"]) do
               [binding] -> get_in(binding, ["connection", "status"]) == "missing_config"
               _ -> false
             end
           end)

    assert x_tool_discovered?(w, "create_users_bookmark")
    assert {:ok, denied} = write.()
    refute denied["status"] == "completed"
    refute_received {:x_mcp_request, _, %{"method" => "tools/call"}}
  end

  defp x_tool_discovered?(workspace, name) do
    case SalixMCP.Store.list_group_bindings(
           workspace["salix_tenant_id"],
           workspace["default_group_id"]
         ) do
      [binding] ->
        Enum.any?(
          get_in(binding, ["connection", "discovered", "tools"]) || [],
          &(&1["name"] == name)
        )

      _ ->
        false
    end
  end

  defp connect_x_oauth_callback(workspace) do
    {:ok, _} =
      OAuthApps.put(workspace["salix_tenant_id"], "x", %{
        "client_id" => "x-test-client",
        "client_secret" => "x-test-secret"
      })

    {:ok, authorization} =
      SalixWeb.OAuthFlow.start_authorization(
        workspace["salix_tenant_id"],
        workspace["default_group_id"],
        "x",
        %{"alias" => "x"}
      )

    assert {:page, 200, _} =
             SalixWeb.OAuthFlow.handle_callback("x", %{
               "state" => authorization["state"],
               "code" => "test-code"
             })

    {:ok, oauth} = OAuthBindings.select_provider_record(workspace["default_group_id"], "x", "x")
    {:ok, connection} = SalixStore.OAuth.get(oauth["connection_id"])
    {oauth, connection}
  end

  defp shared_x_oauth_state(workspace) do
    {:ok, definitions} =
      Salix.Control.Plugins.list_definitions(
        workspace["salix_tenant_id"],
        workspace["default_group_id"]
      )

    definitions
    |> Enum.find(&(&1["plugin_id"] == "x-twitter"))
    |> get_in(["setup_status", "connections"])
    |> Enum.find(&(&1["id"] == "x-managed"))
    |> Map.fetch!("state")
  end

  defp connect_x_oauth(workspace, alias_name \\ "x") do
    id = "x-oauth-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    connection = %{
      "connection_id" => id,
      "provider" => "x",
      "access_token" => "x-oauth-user",
      "scopes" =>
        ~w(tweet.read tweet.write users.read media.write follows.read follows.write dm.read dm.write bookmark.read bookmark.write offline.access),
      "status" => "active"
    }

    :ok = SalixStore.OAuth.put(id, connection)

    {:ok, oauth, _} =
      OAuthBindings.put(
        workspace["salix_tenant_id"],
        workspace["default_group_id"],
        "x",
        alias_name,
        id
      )

    {oauth, connection}
  end

  test "Slack requires managed OAuth and supplies the member token to MCP", %{
    user: user,
    workspace: w
  } do
    SystemsRuntime.put_env(:comma_web, :slack_mcp_probe, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_web, :composio_settings_mod, UnconfiguredComposio)
    assert {:ok, status} = PluginConnections.get(user, %{}, w["id"], "slack")
    assert status["connection"]["id"] == "slack-managed"
    assert status["connection"]["state"] == "not_connected"
    assert {:ok, _} = Comma.Recommendations.get(user, %{}, w["id"])
    assert {:ok, profile} = Comma.Recommendations.get_runtime_profile(w["id"], user["id"])

    old_source = %{
      "appId" => "slack",
      "appName" => "Slack",
      "connectionId" => "old-slack",
      "kind" => "composio",
      "toolkit" => "slack",
      "label" => "Slack",
      "enabled" => false
    }

    profile
    |> Ecto.Changeset.change(sources: [old_source], auto_enable_new_sources: true)
    |> Comma.Repo.update!()

    assert {:ok, install} = PluginConnections.install(user, %{}, w["id"], "slack")
    refute install["plugin"]["installed"]
    url = install["authorization"]["authorizationUrl"]
    assert URI.parse(url).path == "/v1/local-oauth/slack/authorize"
    scopes = URI.decode_query(URI.parse(url).query)["user_scope"] |> String.split(",")
    assert "channels:history" in scopes
    assert "search:read" in scopes
    assert "search:read.public" in scopes
    refute_received {:slack_mcp_request, _}

    SalixWeb.OAuthFlow.handle_callback("slack", %{
      "state" => provider_state(install),
      "code" => "test"
    })

    assert {:ok, completed} = verify(user, w, "slack", install)
    assert completed["plugin"]["installed"]
    binding = await_binding_status(w, "running")
    assert binding["connection"]["tool_count"] > 0
    assert_received {:slack_mcp_request, true}

    assert {:ok, %{"SLACK_USER_TOKEN" => "xoxp-comma-local-token"}} =
             Salix.Bindings.MCPCredentials.resolve(binding)

    assert {:ok, %{"status" => "completed"}} =
             SalixMCP.Gateway.call_tool(
               w["salix_tenant_id"],
               w["default_group_id"],
               binding["binding_id"],
               "comma_local_search",
               %{"query" => "slack oauth reuse", "source" => "slack"}
             )

    refute_received {:slack_mcp_request, false}

    assert {:ok, [source]} = CommaWeb.RecommendationSources.discover(w)
    assert source["kind"] == "managed_oauth"

    assert {:ok, [^source]} =
             CommaWeb.RecommendationSources.discover(w, user["id"], "member", [old_source])

    assert {:ok, migrated} =
             Comma.Recommendations.reconcile_discovered_sources(profile.id, [source])

    assert [%{"kind" => "managed_oauth", "enabled" => false}] = migrated.sources
    assert {:ok, identity} = CommaWeb.RecommendationMemberIdentity.resolve(w, user["id"], source)
    assert identity["provider_user_id"] == "UCOMMALOCAL"
    assert identity["provider_workspace_id"] == "TCOMMALOCAL"

    assert {:ok, %{"sources" => [%{"state" => "ready", "kind" => "managed_oauth"}]}} =
             PluginConnections.personal_sources(user, %{}, w["id"], "slack")

    # A grant made before the plugin required search:read keeps working for
    # MCP, but only a reconnect can widen it for Routine.
    oauth =
      w["default_group_id"]
      |> Salix.Control.OAuthBindings.list()
      |> Enum.find(&(&1["provider"] == "slack"))

    {:ok, stored} = SalixStore.OAuth.get(oauth["connection_id"])
    older = Map.update!(stored, "scopes", &List.delete(&1, "search:read"))
    :ok = SalixStore.OAuth.put(oauth["connection_id"], older)

    assert {:ok, %{"sources" => [%{"state" => "needs_reauthorization"}]}} =
             PluginConnections.personal_sources(user, %{}, w["id"], "slack")

    # A grant the provider revoked also asks for a reconnect, not a first connect.
    :ok =
      SalixStore.OAuth.put(
        oauth["connection_id"],
        Map.put(stored, "status", "reauthorization_required")
      )

    assert {:ok, %{"sources" => [%{"state" => "needs_reauthorization"}]}} =
             PluginConnections.personal_sources(user, %{}, w["id"], "slack")

    :ok = SalixStore.OAuth.put(oauth["connection_id"], stored)

    assert {:ok, reconnect} =
             PluginConnections.reauthorize(user, %{}, w["id"], "slack", %{
               "connection_id" => "slack-managed"
             })

    SalixWeb.OAuthFlow.handle_callback("slack", %{
      "state" => provider_state(reconnect),
      "code" => "test"
    })

    assert {:ok, _} =
             PluginConnections.reauthorize(user, %{}, w["id"], "slack", %{
               "verify_only" => true,
               "authorization_state" => reconnect["authorization"]["state"]
             })

    assert {:ok, _} = PluginConnections.uninstall(user, %{}, w["id"], "slack")
    assert {:error, _} = Salix.Bindings.MCPCredentials.resolve(binding)
  end

  test "Notion resumes its second authorization and installs only after both callbacks", %{
    user: user,
    workspace: w
  } do
    assert {:ok, first} = PluginConnections.install(user, %{}, w["id"], "notion")
    assert first["authorization"]["authorizationUrl"] =~ "api.notion.com"

    SalixWeb.OAuthFlow.handle_callback("notion", %{
      "state" => provider_state(first),
      "code" => "test"
    })

    assert {:ok, second} = verify(user, w, "notion", first)
    refute second["plugin"]["installed"]
    assert second["authorization"]["authorizationUrl"] =~ "/mcp/authorize"
    assert {:ok, stale} = verify(user, w, "notion", first)
    assert stale["authorization"] == nil

    SalixStore.OAuth.AuthState.record_failure(provider_state(second), "cancelled")
    assert {:ok, cancelled} = verify(user, w, "notion", second)
    refute cancelled["plugin"]["installed"]
    assert [%{"provider" => "notion"}] = OAuthBindings.list(w["default_group_id"])

    assert {:ok, resumed} = PluginConnections.install(user, %{}, w["id"], "notion")
    assert resumed["authorization"]["authorizationUrl"] =~ "/mcp/authorize"

    Salix.Control.RemoteMCPOAuth.handle_callback(%{
      "state" => provider_state(resumed),
      "code" => "test"
    })

    assert {:ok, completed} = verify(user, w, "notion", resumed)
    assert completed["plugin"]["installed"]
    assert length(OAuthBindings.list(w["default_group_id"])) == 2

    [old_mcp] =
      OAuthBindings.list(w["default_group_id"])
      |> Enum.filter(&(&1["provider_kind"] == "remote_mcp"))

    assert {:ok, pending_mcp} =
             PluginConnections.reauthorize(user, %{}, w["id"], "notion", %{
               "connection_id" => "notion-native"
             })

    assert {:ok, :ok} =
             PluginConnections.cancel_operation(
               user,
               %{},
               w["id"],
               "notion",
               pending_mcp["authorization"]["state"]
             )

    Salix.Control.RemoteMCPOAuth.handle_callback(%{
      "state" => provider_state(pending_mcp),
      "code" => "test"
    })

    [after_cancel] =
      OAuthBindings.list(w["default_group_id"])
      |> Enum.filter(&(&1["provider_kind"] == "remote_mcp"))

    assert after_cancel["connection_id"] == old_mcp["connection_id"]

    assert {:ok, _} = PluginConnections.uninstall(user, %{}, w["id"], "notion")
    assert OAuthBindings.list(w["default_group_id"]) == []
  end

  test "cancelled native reauthorization cannot replace the original binding after callback entry",
       %{
         user: user,
         workspace: w
       } do
    assert {:ok, install} = PluginConnections.install(user, %{}, w["id"], "github")

    SalixWeb.OAuthFlow.handle_callback("github", %{
      "state" => provider_state(install),
      "code" => "test"
    })

    assert {:ok, _} = verify(user, w, "github", install)
    [original] = OAuthBindings.list(w["default_group_id"])

    assert {:ok, pending} =
             PluginConnections.reauthorize(user, %{}, w["id"], "github", %{
               "connection_id" => "github-managed"
             })

    SystemsRuntime.put_env(:comma_web, :oauth_token_probe, SystemsRuntime.Proc.self())

    callback =
      SystemsRuntime.Task.async(fn ->
        SalixWeb.OAuthFlow.handle_callback("github", %{
          "state" => provider_state(pending),
          "code" => "test"
        })
      end)

    assert_receive {:oauth_exchange, exchange}

    assert {:ok, :ok} =
             PluginConnections.cancel_operation(
               user,
               %{},
               w["id"],
               "github",
               pending["authorization"]["state"]
             )

    SystemsRuntime.Proc.send(exchange, :continue)
    assert {:page, 400, _} = SystemsRuntime.Task.await(callback, :infinity)
    [after_cancel] = OAuthBindings.list(w["default_group_id"])
    assert after_cancel["connection_id"] == original["connection_id"]
  end

  test "older native reauthorization callback cannot replace a newer authorization", %{
    user: user,
    workspace: w
  } do
    assert {:ok, install} = PluginConnections.install(user, %{}, w["id"], "github")

    SalixWeb.OAuthFlow.handle_callback("github", %{
      "state" => provider_state(install),
      "code" => "test"
    })

    assert {:ok, _} = verify(user, w, "github", install)

    assert {:ok, older} =
             PluginConnections.reauthorize(user, %{}, w["id"], "github", %{
               "connection_id" => "github-managed"
             })

    assert {:ok, newer} =
             PluginConnections.reauthorize(user, %{}, w["id"], "github", %{
               "connection_id" => "github-managed"
             })

    assert {:page, 200, _} =
             SalixWeb.OAuthFlow.handle_callback("github", %{
               "state" => provider_state(newer),
               "code" => "test"
             })

    [after_newer] = OAuthBindings.list(w["default_group_id"])

    assert {:page, 400, _} =
             SalixWeb.OAuthFlow.handle_callback("github", %{
               "state" => provider_state(older),
               "code" => "test"
             })

    [after_older] = OAuthBindings.list(w["default_group_id"])
    assert after_older["connection_id"] == after_newer["connection_id"]
  end

  defp provider_state(install),
    do:
      install["authorization"]["authorizationUrl"]
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

  defp verify(user, w, plugin, install),
    do:
      PluginConnections.install(user, %{}, w["id"], plugin, %{
        "verify_only" => true,
        "authorization_state" => install["authorization"]["state"]
      })

  defp await_binding_status(w, status) do
    list = fn ->
      SalixMCP.Store.list_group_bindings(w["salix_tenant_id"], w["default_group_id"])
    end

    assert eventually(
             fn -> match?([%{"connection" => %{"status" => ^status}}], list.()) end,
             3000
           )

    [binding] = list.()
    binding
  end

  defp eventually(predicate, remaining \\ 3000)
  defp eventually(predicate, 0), do: predicate.()

  defp eventually(predicate, remaining) do
    if predicate.() do
      true
    else
      SystemsRuntime.Proc.sleep(10)
      eventually(predicate, remaining - 1)
    end
  end
end
