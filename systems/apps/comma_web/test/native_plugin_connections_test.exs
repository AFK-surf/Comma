defmodule CommaWeb.NativePluginConnectionsTest do
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
        "/slack-mcp" ->
          authorized = get_req_header(conn, "authorization") == ["Bearer xoxp-comma-local-token"]

          if probe = Application.get_env(:comma_web, :slack_mcp_probe),
            do: send(probe, {:slack_mcp_request, authorized})

          if gate = Application.get_env(:comma_web, :slack_mcp_gate) do
            send(gate, {:slack_mcp_blocked, self()})

            receive do
              :release -> :ok
            after
              5_000 -> :ok
            end

            send(gate, :slack_mcp_unblocked)
          end

          cond do
            Application.get_env(:comma_web, :slack_mcp_rejected, false) ->
              send_resp(conn, 400, "App not approved for Slack MCP server access.")

            authorized ->
              SalixWeb.LocalOAuthMock.mcp_resource(conn)

            true ->
              send_resp(conn, 401, "authorization required")
          end

        "/v1/local-oauth/github/token" ->
          if probe = Application.get_env(:comma_web, :oauth_token_probe) do
            send(probe, {:oauth_exchange, self()})

            receive do
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
    unless Process.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
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
      {:comma_web, :slack_mcp_gate}
    ]

    previous = Enum.map(keys, fn {app, key} -> {app, key, Application.get_env(app, key)} end)
    Application.put_env(:salix_web, :composio_settings_mod, LegacyComposio)
    Application.put_env(:salix_web, :composio_client_mod, LegacyComposio)

    bandit =
      start_supervised!({Bandit, plug: Provider, port: 0, ip: {127, 0, 0, 1}, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(bandit)
    base = "http://127.0.0.1:#{port}"
    Application.put_env(:salix_web, :public_base_url, base)
    Application.put_env(:salix_web, :local_oauth_mock, true)
    Application.put_env(:salix_mcp, :credential_resolver_mod, Salix.Bindings.MCPCredentials)
    # Only replace provider endpoints; authorization state and callbacks remain real.
    Application.put_env(:salix_store, :oauth_endpoint_overrides, %{
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
      "notion" => %{"token_url" => base <> "/notion/token"}
    })

    Application.put_env(:salix_mcp, :remote_target_overrides, %{
      "remote:notion" => base <> "/v1/local-oauth/mcp/resource",
      "remote:github" => base <> "/v1/local-oauth/mcp/resource",
      "remote:slack" => base <> "/slack-mcp"
    })

    Application.put_env(:salix_mcp, :private_http_target_allowlist, [
      base <> "/v1/local-oauth/mcp/resource",
      base <> "/slack-mcp"
    ])

    on_exit(fn ->
      # Background MCP refreshes must not outlive this test's sandbox and mocks.
      eventually(
        fn -> Task.Supervisor.children(SalixWeb.OAuthMCPRefreshSupervisor) == [] end,
        500
      )

      Enum.each(previous, fn
        {app, key, nil} -> Application.delete_env(app, key)
        {app, key, value} -> Application.put_env(app, key, value)
      end)

      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "native-#{System.unique_integer([:positive])}@comma.test"
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

  test "Slack requires managed OAuth and supplies the member token to MCP", %{
    user: user,
    workspace: w
  } do
    Application.put_env(:comma_web, :slack_mcp_probe, self())
    Application.put_env(:salix_web, :composio_settings_mod, UnconfiguredComposio)
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

  test "Slack MCP app rejection preserves the completed OAuth grant", %{user: user, workspace: w} do
    Application.put_env(:comma_web, :slack_mcp_rejected, true)
    assert {:ok, install} = PluginConnections.install(user, %{}, w["id"], "slack")

    assert {:page, 200, _} =
             SalixWeb.OAuthFlow.handle_callback("slack", %{
               "state" => provider_state(install),
               "code" => "test"
             })

    assert {:ok, %{"status" => "completed"}} =
             SalixStore.OAuth.AuthState.get(provider_state(install))

    assert {:ok, %{"plugin" => %{"installed" => true}}} = verify(user, w, "slack", install)

    binding = await_binding_status(w, "protocol_error")

    assert {:ok, %{"SLACK_USER_TOKEN" => "xoxp-comma-local-token"}} =
             Salix.Bindings.MCPCredentials.resolve(binding)
  end

  test "slow Slack MCP discovery does not delay the OAuth completion", %{
    user: user,
    workspace: w
  } do
    Application.put_env(:comma_web, :slack_mcp_gate, self())
    assert {:ok, install} = PluginConnections.install(user, %{}, w["id"], "slack")

    assert {:page, 200, _} =
             SalixWeb.OAuthFlow.handle_callback("slack", %{
               "state" => provider_state(install),
               "code" => "test"
             })

    # The callback returned while discovery is still blocked.
    refute_received :slack_mcp_unblocked
    assert_receive {:slack_mcp_blocked, mcp}, 5_000

    assert {:ok, %{"status" => "completed"}} =
             SalixStore.OAuth.AuthState.get(provider_state(install))

    assert {:ok, %{"plugin" => %{"installed" => true}}} = verify(user, w, "slack", install)

    Application.delete_env(:comma_web, :slack_mcp_gate)
    send(mcp, :release)
    assert await_binding_status(w, "running")["connection"]["tool_count"] > 0
  end

  test "GitHub callback preserves recommendation opt-out across discovery gap and supplies MCP bearer",
       %{
         user: user,
         workspace: w
       } do
    alias Comma.{Recommendations, Repo}
    alias Comma.Data.RecommendationProfile

    assert {:ok, _} = Recommendations.get(user, %{}, w["id"])
    assert {:ok, profile} = Recommendations.get_runtime_profile(w["id"], user["id"])

    old_source = %{
      "appId" => "github",
      "appName" => "GitHub",
      "connectionId" => "old-composio-github",
      "kind" => "composio",
      "toolkit" => "github",
      "label" => "GitHub",
      "enabled" => false
    }

    # Seed the pre-release shape, which has no retained preference yet.
    profile
    |> Ecto.Changeset.change(sources: [old_source], auto_enable_new_sources: true)
    |> Repo.update!()

    assert {:ok, []} = CommaWeb.RecommendationSources.discover(w)
    assert {:ok, gap} = Recommendations.reconcile_discovered_sources(profile.id, [])
    assert gap.sources == []

    assert {:ok, install} = PluginConnections.install(user, %{}, w["id"], "github")
    refute install["plugin"]["installed"]
    state = provider_state(install)
    SalixWeb.OAuthFlow.handle_callback("github", %{"state" => state, "code" => "test"})
    assert {:ok, completed} = verify(user, w, "github", install)
    assert completed["plugin"]["installed"]
    assert completed["authorization"] == nil
    binding = await_binding_status(w, "running")
    assert binding["connection"]["tool_count"] > 0

    assert {:ok, %{"GITHUB_ACCESS_TOKEN" => token}} =
             Salix.Bindings.MCPCredentials.resolve(binding)

    assert is_binary(token) and token != ""

    assert {:ok, [native]} = CommaWeb.RecommendationSources.discover(w)
    assert native["kind"] == "managed_oauth"
    assert {:ok, oauth_binding} = OAuthBindings.get(w["default_group_id"], native["connectionId"])
    assert {:ok, connection} = SalixStore.OAuth.get(oauth_binding["connection_id"])
    assert connection["comma_member"] == %{"user_id" => user["id"], "workspace_id" => w["id"]}
    assert {:ok, identity} = CommaWeb.RecommendationMemberIdentity.resolve(w, user["id"], native)
    assert identity["provider_user_id"] == connection["provider_account_id"]
    assert identity["connection_id"] == connection["connection_id"]
    assert {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [native])
    assert [%{"enabled" => false}] = Repo.get!(RecommendationProfile, profile.id).sources
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

  test "a Notion MCP grant names the MCPs it authorizes", %{user: user, workspace: w} do
    assert {:ok, first} = PluginConnections.install(user, %{}, w["id"], "notion")

    SalixWeb.OAuthFlow.handle_callback("notion", %{
      "state" => provider_state(first),
      "code" => "test"
    })

    assert {:ok, second} = verify(user, w, "notion", first)

    Salix.Control.RemoteMCPOAuth.handle_callback(%{
      "state" => provider_state(second),
      "code" => "test"
    })

    assert {:ok, %{"plugin" => %{"installed" => true, "mcps" => [_ | _] = mcps}}} =
             verify(user, w, "notion", second)

    assert {:ok, %{"sources" => sources}} =
             PluginConnections.personal_sources(user, %{}, w["id"], "notion")

    # Plugins places the grant beside these MCPs, not among personal sources.
    assert %{"state" => "ready", "mcpIds" => mcp_ids} =
             Enum.find(sources, &(&1["kind"] == "native_mcp_oauth"))

    assert mcp_ids == Enum.map(mcps, & &1["id"])
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

    Application.put_env(:comma_web, :oauth_token_probe, self())

    callback =
      Task.async(fn ->
        SalixWeb.OAuthFlow.handle_callback("github", %{
          "state" => provider_state(pending),
          "code" => "test"
        })
      end)

    assert_receive {:oauth_exchange, exchange}, 5_000

    assert {:ok, :ok} =
             PluginConnections.cancel_operation(
               user,
               %{},
               w["id"],
               "github",
               pending["authorization"]["state"]
             )

    send(exchange, :continue)
    assert {:page, 400, _} = Task.await(callback, 10_000)
    [after_cancel] = OAuthBindings.list(w["default_group_id"])
    assert after_cancel["connection_id"] == original["connection_id"]
  end

  test "failed remote MCP binding update cannot report safe cancellation after switching the OAuth binding",
       %{user: user, workspace: w} do
    assert {:ok, first} = PluginConnections.install(user, %{}, w["id"], "notion")

    SalixWeb.OAuthFlow.handle_callback("notion", %{
      "state" => provider_state(first),
      "code" => "test"
    })

    assert {:ok, second} = verify(user, w, "notion", first)

    Salix.Control.RemoteMCPOAuth.handle_callback(%{
      "state" => provider_state(second),
      "code" => "test"
    })

    assert {:ok, _} = verify(user, w, "notion", second)

    [original] =
      OAuthBindings.list(w["default_group_id"])
      |> Enum.filter(&(&1["provider_kind"] == "remote_mcp"))

    [mcp_binding] =
      SalixMCP.Store.list_group_bindings(w["salix_tenant_id"], w["default_group_id"])
      |> Enum.filter(&(&1["remote_oauth_binding_id"] == original["binding_id"]))

    assert {:ok, pending} =
             PluginConnections.reauthorize(user, %{}, w["id"], "notion", %{
               "connection_id" => "notion-native"
             })

    key =
      SalixStore.Keys.ctl_mcp_group_binding(
        w["salix_tenant_id"],
        w["default_group_id"],
        mcp_binding["binding_id"]
      )

    SalixStore.S3.Fake.set_fault({:fail, 503, :put, key})

    assert {:page, 400, _} =
             Salix.Control.RemoteMCPOAuth.handle_callback(%{
               "state" => provider_state(pending),
               "code" => "test"
             })

    assert {:ok, current} = OAuthBindings.get(w["default_group_id"], original["binding_id"])

    cancel =
      PluginConnections.cancel_operation(
        user,
        %{},
        w["id"],
        "notion",
        pending["authorization"]["state"]
      )

    if current["connection_id"] == original["connection_id"] do
      assert {:ok, :ok} = cancel
    else
      assert {:ok, _} = SalixStore.OAuth.get(current["connection_id"])

      assert {:ok, %{"authorization" => "Bearer " <> _}} =
               Salix.Control.RemoteMCPOAuth.resolve_headers(mcp_binding)

      assert {:error, {:conflict, _}} = cancel
    end

    assert {:ok, _} =
             PluginConnections.reauthorize(user, %{}, w["id"], "notion", %{
               "connection_id" => "notion-native"
             })
  end

  test "lost managed OAuth binding response keeps its committed credential and rejects cancellation",
       %{user: user, workspace: w} do
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

    key = SalixStore.Keys.ctl_oauth_group_binding(w["default_group_id"], original["binding_id"])
    SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, key})

    assert {:page, 400, _} =
             SalixWeb.OAuthFlow.handle_callback("github", %{
               "state" => provider_state(pending),
               "code" => "test"
             })

    assert {:ok, current} = OAuthBindings.get(w["default_group_id"], original["binding_id"])
    refute current["connection_id"] == original["connection_id"]
    assert {:ok, _} = SalixStore.OAuth.get(current["connection_id"])

    assert {:error, {:conflict, _}} =
             PluginConnections.cancel_operation(
               user,
               %{},
               w["id"],
               "github",
               pending["authorization"]["state"]
             )

    assert {:ok, _} =
             PluginConnections.reauthorize(user, %{}, w["id"], "github", %{
               "connection_id" => "github-managed"
             })
  end

  test "Comma phase write failure leaves a committed binding fenced until the attempt expires",
       %{user: user, workspace: w} do
    alias Comma.{Repo, Data.PluginInstallAttempt}

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

    Repo.query!("""
    CREATE FUNCTION comma_reject_oauth_phase_test() RETURNS trigger AS $$
    BEGIN
      IF NEW.operation_data->>'callback_phase' = 'committed' THEN
        RAISE EXCEPTION 'injected Comma phase write failure';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER comma_reject_oauth_phase_test
    BEFORE UPDATE ON comma_plugin_install_attempts
    FOR EACH ROW EXECUTE FUNCTION comma_reject_oauth_phase_test()
    """)

    assert {:page, 400, _} =
             SalixWeb.OAuthFlow.handle_callback("github", %{
               "state" => provider_state(pending),
               "code" => "test"
             })

    assert {:ok, current} = OAuthBindings.get(w["default_group_id"], original["binding_id"])
    refute current["connection_id"] == original["connection_id"]
    assert {:ok, _} = SalixStore.OAuth.get(current["connection_id"])

    assert {:error, {:conflict, _}} =
             PluginConnections.cancel_operation(
               user,
               %{},
               w["id"],
               "github",
               pending["authorization"]["state"]
             )

    assert {:error, {:conflict, _}} =
             PluginConnections.reauthorize(user, %{}, w["id"], "github", %{
               "connection_id" => "github-managed"
             })

    attempt =
      Repo.get_by!(PluginInstallAttempt, workspace_id: w["id"], plugin_id: "github")

    attempt
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:ok, _} =
             PluginConnections.reauthorize(user, %{}, w["id"], "github", %{
               "connection_id" => "github-managed"
             })
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

  test "native callback consumed before expiry cannot write after the Comma deadline", %{
    user: user,
    workspace: w
  } do
    alias Comma.Repo
    alias Comma.Data.PluginInstallAttempt

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

    Application.put_env(:comma_web, :oauth_token_probe, self())

    callback =
      Task.async(fn ->
        SalixWeb.OAuthFlow.handle_callback("github", %{
          "state" => provider_state(pending),
          "code" => "test"
        })
      end)

    assert_receive {:oauth_exchange, exchange}, 5_000

    attempt = Repo.get_by!(PluginInstallAttempt, workspace_id: w["id"], plugin_id: "github")

    attempt
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    send(exchange, :continue)
    assert {:page, 400, _} = Task.await(callback, 10_000)
    [after_expiry] = OAuthBindings.list(w["default_group_id"])
    assert after_expiry["connection_id"] == original["connection_id"]
  end

  test "a callback that claimed the binding write wins over cancellation", %{
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

    SalixStore.S3.Fake.set_fault({:pause, :put, {:prefix, "ctl/oauth/connections/"}})

    callback =
      Task.async(fn ->
        SalixWeb.OAuthFlow.handle_callback("github", %{
          "state" => provider_state(pending),
          "code" => "test"
        })
      end)

    assert eventually(&SalixStore.S3.Fake.paused?/0)

    cancel =
      Task.async(fn ->
        PluginConnections.cancel_operation(
          user,
          %{},
          w["id"],
          "github",
          pending["authorization"]["state"]
        )
      end)

    assert Task.yield(cancel, 100) == nil
    SalixStore.S3.Fake.release_pause()
    assert {:page, 200, _} = Task.await(callback, 10_000)
    assert {:error, {:conflict, _}} = Task.await(cancel, 10_000)
    [after_callback] = OAuthBindings.list(w["default_group_id"])
    refute after_callback["connection_id"] == original["connection_id"]
  end

  test "member native sources sync without Composio but preserve an existing Composio choice", %{
    user: user,
    workspace: w
  } do
    alias Comma.{Recommendations, Repo}
    alias Comma.Data.RecommendationProfile

    assert {:ok, install} = PluginConnections.install(user, %{}, w["id"], "github")

    SalixWeb.OAuthFlow.handle_callback("github", %{
      "state" => provider_state(install),
      "code" => "test"
    })

    assert {:ok, _} = verify(user, w, "github", install)
    assert {:ok, _} = Recommendations.get(user, %{}, w["id"])
    assert {:ok, profile} = Recommendations.get_runtime_profile(w["id"], user["id"])
    profile |> Ecto.Changeset.change(relevance_mode: "member") |> Repo.update!()
    Application.put_env(:salix_web, :composio_settings_mod, UnconfiguredComposio)

    assert :ok = CommaWeb.RecommendationRuntime.sync_sources(profile.id)
    synced = Repo.get!(RecommendationProfile, profile.id)
    assert [%{"appId" => "github", "kind" => "managed_oauth"}] = synced.sources

    old = %{
      "appId" => "slack",
      "appName" => "Slack",
      "connectionId" => "old-slack",
      "kind" => "composio",
      "toolkit" => "slack",
      "label" => "Slack",
      "enabled" => true
    }

    synced |> Ecto.Changeset.change(sources: [old]) |> Repo.update!()

    assert {:error, {:composio_source_discovery_failed, :not_configured}} =
             CommaWeb.RecommendationRuntime.sync_sources(profile.id)

    assert Repo.get!(RecommendationProfile, profile.id).sources == [old]
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

    assert eventually(fn -> match?([%{"connection" => %{"status" => ^status}}], list.()) end, 500)
    [binding] = list.()
    binding
  end

  defp eventually(predicate, remaining \\ 100)
  defp eventually(predicate, 0), do: predicate.()

  defp eventually(predicate, remaining) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      eventually(predicate, remaining - 1)
    end
  end
end
