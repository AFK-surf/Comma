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

        "/cn-mcp" ->
          conn = fetch_query_params(conn)

          credential =
            conn.query_params["key"] || Enum.join(get_req_header(conn, "authorization"))

          if probe = SystemsRuntime.get_env(:comma_web, :cn_mcp_probe),
            do: SystemsRuntime.Proc.send(probe, {:cn_mcp_request, credential})

          cond do
            credential in ["amap-user-key", "Bearer luckin-user-token"] ->
              SalixWeb.LocalOAuthMock.mcp_resource(conn)

            # AMap answers a wrong key with HTTP 200 and its own error body.
            conn.query_params["key"] ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(
                200,
                ~s({"status":"0","info":"INVALID_USER_KEY","infocode":"10001"})
              )

            true ->
              send_resp(conn, 401, "rejected")
          end

        # Baidu Maps connects with any key and rejects a wrong one only when a
        # tool runs, as a tool error.
        "/cn-mcp-lenient" ->
          conn = fetch_query_params(conn)
          {:ok, body, conn} = read_body(conn)
          request = Jason.decode!(body)

          refused? =
            request["method"] == "tools/call" and conn.query_params["ak"] == "baidu-http-401"

          result =
            case {request["method"], conn.query_params["ak"]} do
              {"initialize", _ak} ->
                %{
                  "protocolVersion" => "2025-06-18",
                  "capabilities" => %{"tools" => %{}},
                  "serverInfo" => %{"name" => "Baidu Maps test", "version" => "1"}
                }

              {"tools/list", _ak} ->
                %{"tools" => [%{"name" => "map_geocode", "inputSchema" => %{"type" => "object"}}]}

              {"tools/call", "baidu-user-key"} ->
                %{"content" => [%{"type" => "text", "text" => ~s({"lng":116.4,"lat":39.9})}]}

              {"tools/call", "baidu-rate-limited"} ->
                %{
                  "isError" => true,
                  "content" => [%{"type" => "text", "text" => "429 Too Many Requests"}]
                }

              {"tools/call", _ak} ->
                %{
                  "isError" => true,
                  "content" => [
                    %{"type" => "text", "text" => "Authentication failed: APP不存在，AK有误请检查再重试"}
                  ]
                }

              _other ->
                nil
            end

          cond do
            refused? ->
              send_resp(conn, 401, "unauthorized")

            result ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(
                200,
                Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
              )

            true ->
              send_resp(conn, 202, "")
          end

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

        # Lark's and Feishu's one-click app creation and the bot of the app it made.
        "/oauth/v1/app/registration" ->
          {:ok, body, conn} = read_body(conn)
          form = URI.decode_query(body)

          answer =
            case form["action"] do
              "init" ->
                %{"supported_auth_methods" => ["client_secret"]}

              "begin" ->
                %{"device_code" => "dc-lark", "user_code" => "ABCD-1234", "interval" => 5}

              "poll" ->
                case SystemsRuntime.get_env(:comma_web, :lark_confirmed, false) do
                  false ->
                    %{"error" => "authorization_pending"}

                  brand ->
                    brand = if brand == true, do: "lark", else: brand

                    %{
                      "client_id" => "cli_scanned",
                      "client_secret" => "scanned-secret",
                      "user_info" => %{"open_id" => "ou_member", "tenant_brand" => brand}
                    }
                end
            end

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(answer))

        # The member's own sign-in with the app their scan made.
        "/oauth/v1/device_authorization" ->
          {:ok, body, conn} = read_body(conn)
          form = URI.decode_query(body)
          true = form["client_id"] == "cli_scanned"
          true = "search:message" in String.split(form["scope"])

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "device_code" => "dc-member",
              "user_code" => "WXYZ-9876",
              "verification_uri_complete" => "https://accounts.example/verify?code=WXYZ-9876",
              "interval" => 5,
              "expires_in" => 240
            })
          )

        "/oauth/v3/token" ->
          {:ok, body, conn} = read_body(conn)

          %{"device_code" => "dc-member", "client_secret" => "scanned-secret"} =
            URI.decode_query(body)

          answer =
            cond do
              # Lark throttles with a 429 and its own JSON error, no OAuth error.
              SystemsRuntime.get_env(:comma_web, :lark_member_throttled, false) ->
                :throttled

              SystemsRuntime.get_env(:comma_web, :lark_member_confirmed, false) ->
                %{
                  "access_token" => "member-token",
                  "refresh_token" => "member-refresh",
                  "token_type" => "Bearer",
                  "expires_in" => 7200,
                  "refresh_token_expires_in" => 604_800,
                  "scope" => Enum.join(SalixIM.Provider.Lark.Registration.member_scopes(), " ")
                }

              true ->
                %{"error" => "authorization_pending"}
            end

          if answer == :throttled do
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(429, ~s({"code":99991400,"msg":"request trigger frequency limit"}))
          else
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(if(answer["error"], do: 400, else: 200), Jason.encode!(answer))
          end

        "/open-apis/authen/v2/oauth/token" ->
          {:ok, body, conn} = read_body(conn)

          %{
            "grant_type" => "refresh_token",
            "refresh_token" => "member-refresh",
            "client_id" => "cli_scanned",
            "client_secret" => "scanned-secret"
          } = Jason.decode!(body)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "code" => 0,
              "access_token" => "member-token-2",
              "refresh_token" => "member-refresh-2",
              "expires_in" => 7200
            })
          )

        "/open-apis/authen/v1/user_info" ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "code" => 0,
              "data" => %{
                "open_id" =>
                  SystemsRuntime.get_env(:comma_web, :lark_member_open_id, "ou_member"),
                "name" => "Ada",
                "tenant_key" => "tk"
              }
            })
          )

        "/open-apis/auth/v3/tenant_access_token/internal" ->
          # A test holds the first credential check to overlap two asks.
          with gate when not is_nil(gate) <-
                 SystemsRuntime.get_env(:comma_web, :lark_credential_gate),
               0 <- Agent.get_and_update(gate.count, &{&1, &1 + 1}) do
            send(gate.test, {:credential_check, self()})

            receive do
              :continue -> :ok
            end
          end

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{"code" => 0, "tenant_access_token" => "t", "expire" => 7200})
          )

        "/open-apis/bot/v3/info" ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "code" => 0,
              "bot" => %{"open_id" => "ou_bot", "app_name" => "Ada's Lark CLI"}
            })
          )

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
      {:comma_web, :x_mcp_probe},
      {:comma_web, :lark_confirmed},
      {:comma_web, :lark_member_confirmed},
      {:comma_web, :lark_member_open_id},
      {:comma_web, :lark_member_throttled},
      {:salix_im, :lark_registration_base_urls},
      {:salix_im, :lark_api_base_url},
      {:salix_im, :feishu_api_base_url},
      {:comma_web, :cn_mcp_probe}
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

    SystemsRuntime.put_env(:salix_im, :lark_registration_base_urls, %{
      "feishu" => base,
      "lark" => base
    })

    SystemsRuntime.put_env(:salix_im, :lark_api_base_url, base <> "/open-apis")
    SystemsRuntime.put_env(:salix_im, :feishu_api_base_url, base <> "/open-apis")
    SalixIM.Provider.Lark.API.reset_token_cache()
    SalixIM.Provider.Feishu.API.reset_token_cache()
    SystemsRuntime.put_env(:salix_mcp, :credential_resolver_mod, Salix.Bindings.MCPCredentials)

    lark_sign_in = %{
      "device_authorization_url" => base <> "/oauth/v1/device_authorization",
      "device_token_url" => base <> "/oauth/v3/token",
      "token_url" => base <> "/open-apis/authen/v2/oauth/token",
      "api_url" => base <> "/open-apis/authen/v1/user_info"
    }

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
      "lark" => lark_sign_in,
      "feishu" => lark_sign_in,
      "x" => %{
        "authorize_url" => base <> "/x/authorize",
        "token_url" => base <> "/x/token",
        "api_url" => base <> "/x/me"
      }
    })

    SystemsRuntime.put_env(:salix_mcp, :remote_target_overrides, %{
      "remote:notion" => base <> "/v1/local-oauth/mcp/resource",
      "remote:posthog" => base <> "/v1/local-oauth/mcp/resource",
      "remote:stripe" => base <> "/v1/local-oauth/mcp/resource",
      "remote:github" => base <> "/v1/local-oauth/mcp/resource",
      "remote:slack" => base <> "/slack-mcp",
      "remote:x" => base <> "/x-mcp",
      "remote:amap" => base <> "/cn-mcp?key={AMAP_MAPS_API_KEY}",
      "remote:luckin" => base <> "/cn-mcp",
      "remote:baidu-maps" => base <> "/cn-mcp-lenient?ak={BAIDU_MAP_API_KEY}",
      "remote:tencent-docs" => base <> "/v1/local-oauth/mcp/resource"
    })

    SystemsRuntime.put_env(:salix_mcp, :private_http_target_allowlist, [
      base <> "/v1/local-oauth/mcp/resource",
      base <> "/slack-mcp",
      base <> "/x-mcp",
      base <> "/cn-mcp",
      base <> "/cn-mcp?key=wrong-key",
      base <> "/cn-mcp?key=amap-user-key",
      base <> "/cn-mcp-lenient?ak=wrong-key",
      base <> "/cn-mcp-lenient?ak=baidu-rate-limited",
      base <> "/cn-mcp-lenient?ak=baidu-http-401",
      base <> "/cn-mcp-lenient?ak=baidu-user-key"
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

  test "Lark installs by a scan: the member's own bot, which the uninstall retires", %{
    user: user,
    workspace: w
  } do
    assert {:ok, plugins} = Comma.Plugins.list(user, %{}, w["id"])
    assert Enum.any?(plugins, &(&1["id"] == "lark"))

    # The first call begins the scan: the link to show, and the device code sealed.
    assert {:ok, begun} = PluginConnections.install(user, %{}, w["id"], "lark")
    refute begun["plugin"]["installed"]
    assert %{"state" => "waiting", "url" => url, "token" => token} = begun["registration"]
    assert url =~ "https://open.larksuite.com/page/cli?"
    assert url =~ "user_code=ABCD-1234"
    refute token =~ "dc-lark"

    # Not confirmed yet: asked again with the registration sealed again.
    assert {:ok, waiting} =
             PluginConnections.install(user, %{}, w["id"], "lark", %{"registration" => token})

    assert %{"state" => "waiting", "token" => next} = waiting["registration"]
    refute waiting["plugin"]["installed"]

    assert {:ok, %{"registration" => %{"state" => "expired"}}} =
             PluginConnections.install(user, %{}, w["id"], "lark", %{
               "registration" => next <> "x"
             })

    SystemsRuntime.put_env(:comma_web, :lark_confirmed, true)

    assert {:ok, installed} =
             PluginConnections.install(user, %{}, w["id"], "lark", %{"registration" => next})

    assert installed["plugin"]["installed"]
    refute Jason.encode!(installed) =~ "scanned-secret"

    # The same dialog then asks for the member's own sign-in with that app,
    # which their Routine reads with. Until it is confirmed, the plugin stays
    # installed and the sign-in shows as not connected.
    assert %{
             "state" => "waiting",
             "step" => "member",
             "url" => "https://accounts.example/verify?code=WXYZ-9876",
             "token" => member_token
           } = installed["registration"]

    refute member_token =~ "dc-member"

    member_source = fn ->
      {:ok, %{"sources" => sources}} =
        PluginConnections.personal_sources(user, %{}, w["id"], "lark")

      Enum.find(sources, &(&1["connectionId"] == "lark-member"))
    end

    assert %{"kind" => "managed_oauth", "state" => "needs_authorization"} = member_source.()

    assert {:ok, %{"registration" => %{"state" => "waiting", "step" => "member"}}} =
             PluginConnections.install(user, %{}, w["id"], "lark", %{
               "registration" => member_token
             })

    # Lark throttling the poll only slows it down; the sign-in goes on.
    SystemsRuntime.put_env(:comma_web, :lark_member_throttled, true)

    assert {:ok,
            %{"registration" => %{"state" => "waiting", "step" => "member", "slowDown" => true}}} =
             PluginConnections.install(user, %{}, w["id"], "lark", %{
               "registration" => member_token
             })

    SystemsRuntime.delete_env(:comma_web, :lark_member_throttled)

    assert {:ok, _} = Comma.Recommendations.get(user, %{}, w["id"])
    SystemsRuntime.put_env(:comma_web, :lark_member_confirmed, true)

    # The code reached someone else, who confirmed it: their sign-in is refused.
    SystemsRuntime.put_env(:comma_web, :lark_member_open_id, "ou_someone_else")

    assert {:ok, %{"registration" => %{"state" => "failed", "error" => "not_app_owner"}}} =
             PluginConnections.install(user, %{}, w["id"], "lark", %{
               "registration" => member_token
             })

    assert %{"state" => "needs_authorization"} = member_source.()
    SystemsRuntime.delete_env(:comma_web, :lark_member_open_id)

    assert {:ok, signed_in} =
             PluginConnections.install(user, %{}, w["id"], "lark", %{
               "registration" => member_token
             })

    refute Map.has_key?(signed_in, "registration")
    assert %{"state" => "ready"} = member_source.()

    # The Routine discovers the new source, as after an install.
    {:ok, profile} = Comma.Recommendations.get_runtime_profile(w["id"], user["id"])

    assert Enum.any?(Comma.Repo.all(Oban.Job), fn job ->
             job.worker == "Comma.Workers.RecommendationSourceSync" and
               job.args["profile_id"] == profile.id
           end)

    # The platform can refuse a grant that looks ready here (an admin took a
    # scope back): Reconnect still asks for a new sign-in.
    assert {:ok, %{"registration" => %{"state" => "waiting", "step" => "member"}}} =
             PluginConnections.reauthorize(user, %{}, w["id"], "lark", %{
               "connection_id" => "lark-member"
             })

    # The Routine finds it as the member's own Lark source.
    assert {:ok, [%{"appId" => "lark", "kind" => "managed_oauth", "appName" => "Lark"}]} =
             CommaWeb.RecommendationSources.discover(w, user["id"], "member")

    assert {:ok, []} = CommaWeb.RecommendationSources.discover(w, user["id"], "generic")

    # It refreshes with the member's own app, not a tenant Lark app.
    [binding] =
      w["default_group_id"]
      |> Salix.Control.OAuthBindings.list()
      |> Enum.filter(&(&1["provider"] == "lark"))

    # Its own alias, beside any Lark credential an Agent asks for, and only
    # for work done for the member.
    assert binding["alias"] == "lark-member"
    assert binding["owner"] == "comma_user|" <> user["id"]

    # The bot's own reads as a signed-in person (meetings, documents) never
    # use it.
    assert {:ok, []} = Salix.Bindings.IMLarkUserAccounts.list(w["default_group_id"])

    assert {:error, :not_found} =
             Salix.Bindings.IMLarkUserAccounts.access_token("any", "lark-member")

    {:ok, grant} = SalixStore.OAuth.get(binding["connection_id"])
    :ok = SalixStore.OAuth.put(binding["connection_id"], %{grant | "expires_at" => 1})

    assert {:ok, %{"TOKEN" => "member-token-2"}} =
             Salix.Bindings.MCPCredentials.resolve(%{
               "tenant_id" => w["salix_tenant_id"],
               "group_id" => w["default_group_id"],
               "oauth_binding_refs" => %{
                 "TOKEN" => %{
                   "binding_id" => binding["binding_id"],
                   "provider" => "lark",
                   "credential" => "access_token"
                 }
               }
             })

    assert {:ok, [connect]} =
             SalixIM.ProviderConnects.list_group_im_connects(w["default_group_id"], "lark")

    assert %{
             "app_id" => "cli_scanned",
             "events" => "socket",
             "owner_only" => true,
             "owner_open_id" => "ou_member"
           } = connect

    # Lark refuses the app a scope a connect needs since it was made: the
    # member sees which, and Reconnect scans again to update the same app.
    bot_sources = fn ->
      {:ok, %{"sources" => sources}} =
        PluginConnections.personal_sources(user, %{}, w["id"], "lark")

      Enum.filter(sources, &(&1["kind"] == "im_connect"))
    end

    assert bot_sources.() == []

    {:ok, stored} =
      SalixIM.ProviderConnects.get_active_connect_by_id(
        w["default_group_id"],
        connect["connect_id"],
        "lark"
      )

    :ok = SalixIM.ProviderConnects.note_missing_scope(stored, "im:message.group_msg")

    assert [source] = bot_sources.()

    assert %{
             "connectionId" => "lark-im",
             "kind" => "im_connect",
             "state" => "needs_reauthorization",
             "missingScopes" => ["im:message.group_msg"]
           } = source

    assert {:ok, rescan} =
             PluginConnections.reauthorize(user, %{}, w["id"], "lark", %{
               "connection_id" => "lark-im"
             })

    assert %{"state" => "waiting", "url" => url, "token" => token} = rescan["registration"]
    assert URI.decode_query(URI.parse(url).query)["clientID"] == "cli_scanned"

    assert {:ok, rescanned} =
             PluginConnections.reauthorize(user, %{}, w["id"], "lark", %{
               "connection_id" => "lark-im",
               "registration" => token
             })

    refute Map.has_key?(rescanned, "registration")

    assert {:ok, [%{"connect_id" => same, "missing_scopes" => []}]} =
             SalixIM.ProviderConnects.list_group_im_connects(w["default_group_id"], "lark")

    assert same == connect["connect_id"]
    assert bot_sources.() == []

    assert {:ok, removed} = PluginConnections.uninstall(user, %{}, w["id"], "lark")
    refute removed["installed"]

    # The member's sign-in goes with the bot.
    assert [] ==
             w["default_group_id"]
             |> Salix.Control.OAuthBindings.list()
             |> Enum.filter(&(&1["provider"] == "lark"))

    assert {:ok, []} =
             SalixIM.ProviderConnects.list_group_im_connects(w["default_group_id"], "lark")
  end

  test "overlapping asks of a Feishu scan keep the app the winner connected", %{
    user: user,
    workspace: w
  } do
    assert {:ok, begun} = PluginConnections.install(user, %{}, w["id"], "feishu")
    %{"token" => token} = begun["registration"]
    SystemsRuntime.put_env(:comma_web, :lark_confirmed, "feishu")

    {:ok, count} = Agent.start_link(fn -> 0 end)
    gate = %{count: count, test: SystemsRuntime.Proc.self()}
    SystemsRuntime.put_env(:comma_web, :lark_credential_gate, gate)
    on_exit(fn -> SystemsRuntime.delete_env(:comma_web, :lark_credential_gate) end)

    ask = %{"registration" => token}
    first = Task.async(fn -> PluginConnections.install(user, %{}, w["id"], "feishu", ask) end)

    held =
      receive do
        {:credential_check, held} -> held
      end

    assert {:ok, %{"plugin" => %{"installed" => true}}} =
             PluginConnections.install(user, %{}, w["id"], "feishu", ask)

    send(held, :continue)
    assert {:ok, %{"plugin" => %{"installed" => true}}} = Task.await(first, :infinity)

    assert :none = SalixIM.Ports.ProviderAppStore.get_feishu_tenant_app(w["salix_tenant_id"])

    assert {:ok, [_connect]} =
             SalixIM.ProviderConnects.list_group_im_connects(w["default_group_id"], "feishu")

    assert {:ok, _removed} = PluginConnections.uninstall(user, %{}, w["id"], "feishu")
  end

  test "a scan whose install failed after its bot connected finishes", %{
    user: user,
    workspace: w
  } do
    assert {:ok, begun} = PluginConnections.install(user, %{}, w["id"], "lark")
    %{"token" => token} = begun["registration"]
    SystemsRuntime.put_env(:comma_web, :lark_confirmed, true)

    # The bot is connected and the plugin is not installed.
    assert {:ok, connect} =
             SalixIM.ProviderConnects.finish_lark_registration(
               w["salix_tenant_id"],
               w["default_group_id"],
               "feishu",
               "dc-lark",
               owner: true
             )

    # The same scan asked again answers the same app and installs.
    assert {:ok, %{"plugin" => %{"installed" => true}}} =
             PluginConnections.install(user, %{}, w["id"], "lark", %{"registration" => token})

    assert {:ok, [same]} =
             SalixIM.ProviderConnects.list_group_im_connects(w["default_group_id"], "lark")

    assert same["connect_id"] == connect["connect_id"]
    assert {:ok, _removed} = PluginConnections.uninstall(user, %{}, w["id"], "lark")
  end

  test "adding Lark again installs a bot a scan already connected, without a new scan", %{
    user: user,
    workspace: w
  } do
    SystemsRuntime.put_env(:comma_web, :lark_confirmed, true)

    assert {:ok, _connect} =
             SalixIM.ProviderConnects.finish_lark_registration(
               w["salix_tenant_id"],
               w["default_group_id"],
               "feishu",
               "dc-lark",
               owner: true
             )

    assert {:ok, answer} = PluginConnections.install(user, %{}, w["id"], "lark")
    assert answer["plugin"]["installed"]
    # No scan for the bot: only the member's own sign-in is asked for.
    assert %{"step" => "member"} = answer["registration"]
    assert {:ok, _removed} = PluginConnections.uninstall(user, %{}, w["id"], "lark")
  end

  test "a Feishu account's scan of the Lark plugin fails and connects nothing", %{
    user: user,
    workspace: w
  } do
    assert {:ok, begun} = PluginConnections.install(user, %{}, w["id"], "lark")
    %{"token" => token} = begun["registration"]
    SystemsRuntime.put_env(:comma_web, :lark_confirmed, "feishu")

    assert {:ok, %{"registration" => %{"state" => "failed", "error" => error}}} =
             PluginConnections.install(user, %{}, w["id"], "lark", %{"registration" => token})

    assert error =~ "Feishu account"

    assert {:ok, []} =
             SalixIM.ProviderConnects.list_group_im_connects(w["default_group_id"], "lark")
  end

  test "Feishu installs by a scan: the member's own bot owns its app, beside the Workspace's Feishu app, and the uninstall retires it",
       %{user: user, workspace: w} do
    # The Workspace already has a Feishu app of its own; a scan makes another.
    assert {:ok, _app} =
             SalixIM.Ports.ProviderAppStore.put_feishu_tenant_app(w["salix_tenant_id"], %{
               "app_id" => "cli_workspace",
               "app_secret" => "workspace-secret"
             })

    assert {:ok, plugins} = Comma.Plugins.list(user, %{}, w["id"])
    # Listed with the services of mainland China.
    assert %{"name" => "飞书", "category" => "中国服务"} =
             Enum.find(plugins, &(&1["id"] == "feishu"))

    assert {:ok, begun} = PluginConnections.install(user, %{}, w["id"], "feishu")
    refute begun["plugin"]["installed"]
    assert %{"state" => "waiting", "url" => url, "token" => token} = begun["registration"]
    assert url =~ "https://open.feishu.cn/page/cli?"

    # A Lark account's app is not a Feishu bot.
    SystemsRuntime.put_env(:comma_web, :lark_confirmed, "lark")

    assert {:ok, %{"registration" => %{"state" => "failed", "error" => error}}} =
             PluginConnections.install(user, %{}, w["id"], "feishu", %{"registration" => token})

    assert error =~ "Lark account"

    SystemsRuntime.put_env(:comma_web, :lark_confirmed, "feishu")

    assert {:ok, installed} =
             PluginConnections.install(user, %{}, w["id"], "feishu", %{"registration" => token})

    assert installed["plugin"]["installed"]
    refute Jason.encode!(installed) =~ "scanned-secret"

    assert {:ok, %{"app_id" => "cli_workspace"}} =
             SalixIM.Ports.ProviderAppStore.get_feishu_tenant_app(w["salix_tenant_id"])

    assert {:ok, [connect]} =
             SalixIM.ProviderConnects.list_group_im_connects(w["default_group_id"], "feishu")

    assert %{
             "app_id" => "cli_scanned",
             "events" => "socket",
             "owner_only" => true,
             "owner_open_id" => "ou_member",
             "webhook_url" => ""
           } = connect

    # Its long connection opens with the app's own secret.
    assert {:ok, sockets} = SalixIM.ProviderConnects.list_socket_connects()

    assert Enum.any?(
             sockets,
             &(&1["connect_id"] == connect["connect_id"] and &1["app_secret"] == "scanned-secret")
           )

    assert {:ok, removed} = PluginConnections.uninstall(user, %{}, w["id"], "feishu")
    refute removed["installed"]

    assert {:ok, []} =
             SalixIM.ProviderConnects.list_group_im_connects(w["default_group_id"], "feishu")

    # The Workspace's own Feishu app is not the scan's to remove.
    assert {:ok, %{"app_id" => "cli_workspace"}} =
             SalixIM.Ports.ProviderAppStore.get_feishu_tenant_app(w["salix_tenant_id"])
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

  test "still.fail installs by showing the line a station connects with, a device of its own each time; uninstalling removes them",
       %{user: user, workspace: w} do
    group = w["default_group_id"]
    assert {:ok, first} = PluginConnections.install(user, %{}, w["id"], "stillfail")
    assert first["plugin"]["installed"]

    assert %{"key" => "STILLFAIL_CONNECT_LINE", "format" => "show", "value" => line} =
             first["configuration"]

    assert ["comma", server, "salix_conn_" <> _] = String.split(line, " ")
    assert server != ""

    assert {:ok, %{"connection" => %{"state" => "connected"}}} =
             PluginConnections.get(user, %{}, w["id"], "stillfail")

    # Asked again: another station's line, another device.
    assert {:ok, second} = PluginConnections.install(user, %{}, w["id"], "stillfail")
    refute second["configuration"]["value"] == line
    assert length(stillfail_devices(group)) == 2

    assert Enum.all?(stillfail_devices(group), &(&1["meta"]["owner_user_id"] == user["id"]))

    # What a station sent of its workspace's statistics goes with its device.
    [device | _] = stillfail_devices(group)

    {:ok, station} =
      SalixStore.StillfailStations.ensure(w["salix_tenant_id"], group, device["device_id"])

    assert {:ok, _} =
             SalixStore.StationStatsIndex.apply_page(station, device["device_id"], %{
               "epoch" => "e1",
               "reset" => true,
               "rows" => [
                 %{
                   "key" => "stillfail|usage|1",
                   "source" => "stillfail",
                   "kind" => "usage",
                   "rev" => 1,
                   "row" => %{"day" => "2026-11-01", "person" => "ann@x", "calls" => 1}
                 }
               ]
             })

    assert {:ok, [_]} =
             SalixStore.StationStats.usage(
               group,
               "2026-11-01",
               "2026-11-01",
               :person,
               "stillfail"
             )

    assert {:ok, removed} = PluginConnections.uninstall(user, %{}, w["id"], "stillfail")
    refute removed["installed"]
    assert stillfail_devices(group) == []

    assert {:ok, []} =
             SalixStore.StationStats.usage(
               group,
               "2026-11-01",
               "2026-11-01",
               :person,
               "stillfail"
             )
  end

  test "still.fail lists the stations it connected and disconnects one, the others and the plugin staying",
       %{user: user, workspace: w} do
    group = w["default_group_id"]
    assert {:ok, first} = PluginConnections.install(user, %{}, w["id"], "stillfail")
    assert first["plugin"]["stations"]
    assert {:ok, _} = PluginConnections.install(user, %{}, w["id"], "stillfail")

    assert {:ok, %{"stations" => [_, _] = stations}} =
             PluginConnections.stillfail_stations(user, %{}, w["id"], "stillfail")

    [gone, kept] = Enum.map(stations, & &1["id"])

    assert {:ok, %{"stations" => [%{"id" => ^kept}]}} =
             PluginConnections.disconnect_stillfail_station(user, %{}, w["id"], "stillfail", gone)

    assert Enum.map(stillfail_devices(group), & &1["device_id"]) == [kept]

    assert {:ok, %{"connection" => %{"state" => "connected"}}} =
             PluginConnections.get(user, %{}, w["id"], "stillfail")

    # Gone already, or another kind of device of the Group: not one of its stations.
    assert {:error, :not_found} =
             PluginConnections.disconnect_stillfail_station(user, %{}, w["id"], "stillfail", gone)
  end

  defp stillfail_devices(group) do
    {:ok, devices} = SalixEnv.Registry.list_by_group(group)
    Enum.filter(devices, &(get_in(&1, ["meta", "device_kind"]) == "stillfail"))
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

  test "Stripe installs after its MCP OAuth callback and binds Stripe's hosted MCP", %{
    user: user,
    workspace: w
  } do
    assert {:ok, started} = PluginConnections.install(user, %{}, w["id"], "stripe")
    refute started["plugin"]["installed"]
    assert started["authorization"]["authorizationUrl"] =~ "/mcp/authorize"

    Salix.Control.RemoteMCPOAuth.handle_callback(%{
      "state" => provider_state(started),
      "code" => "test"
    })

    assert {:ok, completed} = verify(user, w, "stripe", started)
    assert completed["plugin"]["installed"]
    refute completed["plugin"]["toolGroups"]

    assert [binding] =
             SalixMCP.Store.list_group_bindings(w["salix_tenant_id"], w["default_group_id"])

    assert binding["alias"] == "stripe"
    assert binding["target_ref"] == "remote:stripe"

    assert {:ok, _} = PluginConnections.uninstall(user, %{}, w["id"], "stripe")
    assert OAuthBindings.list(w["default_group_id"]) == []
  end

  for {plugin_id, key, value, seen} <- [
        {"amap", "AMAP_MAPS_API_KEY", "amap-user-key", "amap-user-key"},
        {"luckin", "LUCKIN_MCP_TOKEN", "luckin-user-token", "Bearer luckin-user-token"}
      ] do
    test "#{plugin_id} installs with the user's key and sends it only to its MCP", %{
      user: user,
      workspace: w
    } do
      SystemsRuntime.put_env(:comma_web, :cn_mcp_probe, SystemsRuntime.Proc.self())
      assert {:ok, prompt} = PluginConnections.install(user, %{}, w["id"], unquote(plugin_id))
      assert prompt["configuration"]["key"] == unquote(key)
      refute prompt["plugin"]["installed"]

      assert {:error, :plugin_credential_rejected} =
               PluginConnections.install(user, %{}, w["id"], unquote(plugin_id), %{
                 "config_values" => %{unquote(key) => "wrong-key"}
               })

      assert {:ok, plugins} = Comma.Plugins.list(user, %{}, w["id"])
      refute Enum.find(plugins, &(&1["id"] == unquote(plugin_id)))["installed"]

      assert {:ok, %{"connection" => %{"state" => "not_connected"}}} =
               PluginConnections.get(user, %{}, w["id"], unquote(plugin_id))

      assert {:ok, installed} =
               PluginConnections.install(user, %{}, w["id"], unquote(plugin_id), %{
                 "config_values" => %{unquote(key) => unquote(value)}
               })

      assert installed["plugin"]["installed"]
      assert_received {:cn_mcp_request, unquote(seen)}

      assert [binding] =
               SalixMCP.Store.list_group_bindings(w["salix_tenant_id"], w["default_group_id"])

      assert binding["alias"] == unquote(plugin_id)
      refute Jason.encode!([installed, binding]) =~ unquote(value)

      assert {:ok, %{"status" => "completed"}} =
               SalixMCP.Gateway.call_tool(
                 w["salix_tenant_id"],
                 w["default_group_id"],
                 binding["binding_id"],
                 "comma_local_search",
                 %{"query" => "coffee"}
               )

      assert {:ok, _} = PluginConnections.uninstall(user, %{}, w["id"], unquote(plugin_id))
      assert SalixMCP.Store.list_group_bindings(w["salix_tenant_id"], w["default_group_id"]) == []
    end
  end

  test "a key that connects but fails the service's own check is rejected, a rate limit is not",
       %{user: user, workspace: w} do
    install = fn key ->
      PluginConnections.install(user, %{}, w["id"], "baidu-maps", %{
        "config_values" => %{"BAIDU_MAP_API_KEY" => key}
      })
    end

    installed? = fn ->
      {:ok, plugins} = Comma.Plugins.list(user, %{}, w["id"])
      Enum.find(plugins, &(&1["id"] == "baidu-maps"))["installed"]
    end

    assert {:error, :plugin_credential_rejected} = install.("wrong-key")
    refute installed?.()

    assert {:ok, %{"connection" => %{"state" => "not_connected"}}} =
             PluginConnections.get(user, %{}, w["id"], "baidu-maps")

    assert {:error, :plugin_credential_rejected} = install.("baidu-http-401")
    refute installed?.()

    assert {:ok, %{"plugin" => %{"installed" => true}}} = install.("baidu-rate-limited")
    assert {:ok, _} = PluginConnections.uninstall(user, %{}, w["id"], "baidu-maps")

    assert {:ok, %{"plugin" => %{"installed" => true}}} = install.("baidu-user-key")
    assert installed?.()
  end

  test "Tencent Docs installs after its MCP OAuth callback", %{user: user, workspace: w} do
    assert {:ok, started} = PluginConnections.install(user, %{}, w["id"], "tencent-docs")
    refute started["plugin"]["installed"]
    assert started["authorization"]["authorizationUrl"] =~ "/mcp/authorize"

    Salix.Control.RemoteMCPOAuth.handle_callback(%{
      "state" => provider_state(started),
      "code" => "test"
    })

    assert {:ok, completed} = verify(user, w, "tencent-docs", started)
    assert completed["plugin"]["installed"]

    assert [binding] =
             SalixMCP.Store.list_group_bindings(w["salix_tenant_id"], w["default_group_id"])

    assert binding["target_ref"] == "remote:tencent-docs"
    assert {:ok, _} = PluginConnections.uninstall(user, %{}, w["id"], "tencent-docs")
    assert OAuthBindings.list(w["default_group_id"]) == []
  end

  test "PostHog installs after its MCP OAuth callback and binds PostHog's hosted MCP", %{
    user: user,
    workspace: w
  } do
    assert {:ok, started} = PluginConnections.install(user, %{}, w["id"], "posthog")
    refute started["plugin"]["installed"]
    assert started["authorization"]["authorizationUrl"] =~ "/mcp/authorize"

    Salix.Control.RemoteMCPOAuth.handle_callback(%{
      "state" => provider_state(started),
      "code" => "test"
    })

    assert {:ok, completed} = verify(user, w, "posthog", started)
    assert completed["plugin"]["installed"]
    assert completed["plugin"]["toolGroups"]

    assert [%{"provider_kind" => "remote_mcp"}] = OAuthBindings.list(w["default_group_id"])

    assert [binding] =
             SalixMCP.Store.list_group_bindings(w["salix_tenant_id"], w["default_group_id"])

    assert binding["alias"] == "posthog"
    assert binding["target_ref"] == "remote:posthog"

    assert {:ok, %{"groups" => groups}} =
             PluginConnections.tool_groups(user, %{}, w["id"], "posthog")

    # Every family PostHog's own installer offers is on, and only those.
    assert Enum.all?(groups, & &1["enabled"])
    all = Enum.map(groups, & &1["id"])
    assert "flags" in all
    refute "metrics" in all
    assert posthog_features(w, binding) == ["workspace" | all]

    assert {:ok, %{"groups" => groups}} =
             PluginConnections.set_tool_group(user, %{}, w["id"], "posthog", "flags", false)

    refute Enum.find(groups, &(&1["id"] == "flags"))["enabled"]
    assert posthog_features(w, binding) == ["workspace" | all -- ["flags"]]

    assert {:ok, %{"groups" => groups}} =
             PluginConnections.set_tool_group(user, %{}, w["id"], "posthog", "flags", true)

    # Every family on still names them, so families Comma does not offer stay off.
    assert Enum.all?(groups, & &1["enabled"])
    assert posthog_features(w, binding) == ["workspace" | all]

    assert {:error, :not_found} =
             PluginConnections.set_tool_group(user, %{}, w["id"], "posthog", "metrics", true)

    assert {:error, :not_found} =
             PluginConnections.set_tool_group(user, %{}, w["id"], "posthog", "workspace", false)

    assert {:ok, _} = PluginConnections.uninstall(user, %{}, w["id"], "posthog")
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

  # The PostHog tool families the binding's MCP URL asks for.
  defp posthog_features(w, binding) do
    {:ok, binding, definition, _connection} =
      SalixMCP.Store.get_binding_with_definition(
        w["salix_tenant_id"],
        w["default_group_id"],
        binding["binding_id"]
      )

    # Without its target ref the entry is resolved as stored, not as this test reroutes it.
    [entry] = definition["server_metadata"]["remotes"]
    entry = Map.delete(entry, "target_ref")
    assert {:ok, %{"url" => url}} = SalixMCP.Config.resolve_entry(entry, binding)
    assert "https://mcp.posthog.com/mcp?" <> query = url
    query |> URI.decode_query() |> Map.fetch!("features") |> String.split(",", trim: true)
  end

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
