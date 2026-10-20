defmodule SalixStore.OAuthAdaptersTest do
  @moduledoc """
  OAuth provider adapters (port of willow's `internal/oauth/*.go`): registry
  resolution, authorization-URL shapes (state, PKCE challenge, scope encoding),
  and the GitHub / Google / Slack token lifecycles (exchange, refresh including
  invalid_grant → :reauthorization_required, revoke) driven through a
  Bandit/Plug mock provider via the `:oauth_endpoint_overrides` seam.
  """
  use SystemsClock.Case, async: false

  alias SalixStore.OAuth.Adapters
  alias SalixStore.OAuth.Adapters.{Feishu, GitHub, Google, Lark, Linear, Notion, Slack, X}

  @app %{"client_id" => "cid", "client_secret" => "sec"}
  @ctx %{"redirect_uri" => "https://app.example/cb", "code_verifier" => nil, "scopes" => []}

  # ---- mock provider server ----

  defmodule MockProvider do
    @moduledoc "Plug impersonating provider token/api endpoints; canned responses keyed by path."
    use Agent
    import Plug.Conn

    def start_link(_opts \\ []),
      do: Agent.start_link(fn -> %{responses: %{}, requests: []} end, name: __MODULE__)

    def stub(path, body, status \\ 200),
      do: Agent.update(__MODULE__, fn st -> put_in(st, [:responses, path], {status, body}) end)

    def requests(path),
      do: Agent.get(__MODULE__, & &1.requests) |> Enum.filter(&(&1.path == path))

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      params = decode_params(conn, raw)

      Agent.update(__MODULE__, fn st ->
        req = %{
          path: conn.request_path,
          method: conn.method,
          params: params,
          headers: conn.req_headers
        }

        %{st | requests: st.requests ++ [req]}
      end)

      {status, body} =
        Agent.get(__MODULE__, fn st -> st.responses[conn.request_path] end) ||
          {404, %{"error" => "no stub for #{conn.request_path}"}}

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end

    defp decode_params(conn, raw) do
      ct = List.first(get_req_header(conn, "content-type")) || ""

      cond do
        String.contains?(ct, "json") and raw != "" -> Jason.decode!(raw)
        raw == "" -> %{}
        true -> URI.decode_query(raw)
      end
    end
  end

  # Bind Bandit on a random port, retrying on collisions across suites.
  defp start_bandit_retry! do
    Enum.find_value(1..10, fn _ ->
      p = 40_000 + :erlang.phash2(SystemsRuntime.Proc.make_ref(), 20_000)

      case ExUnit.Callbacks.start_supervised(
             {Bandit, plug: MockProvider, port: p, ip: {127, 0, 0, 1}},
             id: {:bandit_retry, p}
           ) do
        {:ok, _pid} -> p
        {:error, _} -> nil
      end
    end) || raise "could not bind a test port after 10 attempts"
  end

  defp start_mock! do
    start_supervised!(MockProvider)
    port = start_bandit_retry!()
    base = "http://127.0.0.1:#{port}"

    prev = SystemsRuntime.get_env(:salix_store, :oauth_endpoint_overrides)

    SystemsRuntime.put_env(:salix_store, :oauth_endpoint_overrides, %{
      "github" => %{"token_url" => "#{base}/github/token", "api_url" => "#{base}/github/api"},
      "google" => %{
        "token_url" => "#{base}/google/token",
        "revoke_url" => "#{base}/google/revoke",
        "api_url" => "#{base}/google/userinfo"
      },
      "feishu" => %{
        "token_url" => "#{base}/feishu/token",
        "api_url" => "#{base}/feishu/user_info"
      },
      "lark" => %{"token_url" => "#{base}/lark/token", "api_url" => "#{base}/lark/user_info"},
      "linear" => %{"token_url" => "#{base}/linear/token", "api_url" => "#{base}/linear/api"},
      "slack" => %{"token_url" => "#{base}/slack/token", "revoke_url" => "#{base}/slack/revoke"},
      "x" => %{
        "token_url" => "#{base}/x/token",
        "revoke_url" => "#{base}/x/revoke",
        "api_url" => "#{base}/x/me"
      }
    })

    ExUnit.Callbacks.on_exit(fn ->
      if prev,
        do: SystemsRuntime.put_env(:salix_store, :oauth_endpoint_overrides, prev),
        else: SystemsRuntime.delete_env(:salix_store, :oauth_endpoint_overrides)
    end)

    base
  end

  defp query(url) do
    uri = URI.parse(url)
    {uri, URI.decode_query(uri.query)}
  end

  # ---- registry ----

  describe "Adapters registry" do
  end

  describe "Lark user sign-in" do
    test "authorization asks for the meeting, notes, Minutes and document reads with PKCE" do
      req = %{
        "redirect_uri" => "https://app.example/cb",
        "state" => "state",
        "code_challenge" => "challenge"
      }

      assert {:ok, url} = Lark.authorization_url(@app, req)
      {uri, params} = query(url)
      assert uri.host == "accounts.larksuite.com"
      assert params["client_id"] == "cid"
      assert params["state"] == "state"
      assert params["code_challenge_method"] == "S256"
      scopes = String.split(params["scope"], " ")
      assert "vc:meeting.search:read" in scopes
      assert "vc:note:read" in scopes
      assert "offline_access" in scopes
      assert {:error, _} = Lark.authorization_url(@app, Map.delete(req, "code_challenge"))
    end

    test "exchange names the person by open_id; refresh rotates the refresh token" do
      start_mock!()

      MockProvider.stub("/lark/token", %{
        "code" => 0,
        "access_token" => "u-access",
        "refresh_token" => "ur-refresh",
        "expires_in" => 7200,
        "refresh_token_expires_in" => 604_800,
        "scope" => "vc:note:read offline_access",
        "token_type" => "Bearer"
      })

      MockProvider.stub("/lark/user_info", %{
        "code" => 0,
        "data" => %{"open_id" => "ou_ray", "name" => "Ray Zhang"}
      })

      assert {:ok, %{"tokens" => tokens, "account" => account}} =
               Lark.exchange_code(@app, Map.put(@ctx, "code_verifier", "verifier"), "code")

      assert account["provider_account_id"] == "ou_ray"
      assert account["provider_account_name"] == "Ray Zhang"
      assert tokens["refresh_expires_at"] > tokens["expires_at"]
      [exchange] = MockProvider.requests("/lark/token")
      assert exchange.params["grant_type"] == "authorization_code"
      assert exchange.params["code_verifier"] == "verifier"
      assert exchange.params["client_id"] == "cid"
      [identity] = MockProvider.requests("/lark/user_info")
      assert {"authorization", "Bearer u-access"} in identity.headers

      MockProvider.stub("/lark/token", %{
        "code" => 0,
        "access_token" => "u-refreshed",
        "refresh_token" => "ur-rotated",
        "expires_in" => 7200
      })

      assert {:ok, refreshed} = Lark.refresh(@app, tokens)
      assert refreshed["access_token"] == "u-refreshed"
      assert refreshed["refresh_token"] == "ur-rotated"
      assert refreshed["scopes"] == tokens["scopes"]
      assert {:error, :revocation_not_supported} = Lark.revoke(@app, refreshed)
    end

    test "a refused refresh token needs a new sign-in" do
      start_mock!()

      MockProvider.stub(
        "/lark/token",
        %{"code" => 20_037, "error" => "invalid_grant", "error_description" => "expired"},
        400
      )

      assert {:error, :reauthorization_required} =
               Lark.refresh(@app, %{"refresh_token" => "ur-old"})
    end
  end

  describe "Feishu user sign-in" do
    test "authorization goes to Feishu and asks for the meeting, notes, Minutes and document reads" do
      req = %{
        "redirect_uri" => "https://app.example/cb",
        "state" => "state",
        "code_challenge" => "challenge"
      }

      assert {:ok, url} = Feishu.authorization_url(@app, req)
      {uri, params} = query(url)
      assert uri.host == "accounts.feishu.cn"
      assert params["client_id"] == "cid"
      assert params["code_challenge_method"] == "S256"
      scopes = String.split(params["scope"], " ")
      assert "vc:meeting.search:read" in scopes
      assert "minutes:minutes:readonly" in scopes
      assert "offline_access" in scopes
      assert {:error, _} = Feishu.authorization_url(@app, Map.delete(req, "code_challenge"))
    end

    test "exchange names the person by open_id and keeps the tenant; refresh rotates" do
      start_mock!()

      MockProvider.stub("/feishu/token", %{
        "code" => 0,
        "access_token" => "u-access",
        "refresh_token" => "ur-refresh",
        "expires_in" => 7200,
        "refresh_token_expires_in" => 604_800,
        "scope" => "vc:note:read offline_access",
        "token_type" => "Bearer"
      })

      MockProvider.stub("/feishu/user_info", %{
        "code" => 0,
        "data" => %{"open_id" => "ou_ray", "name" => "张瑞", "tenant_key" => "tk_acme"}
      })

      assert {:ok, %{"tokens" => tokens, "account" => account}} =
               Feishu.exchange_code(@app, Map.put(@ctx, "code_verifier", "verifier"), "code")

      assert account["provider_account_id"] == "ou_ray"
      assert account["provider_account_name"] == "张瑞"
      assert account["metadata"]["tenant_key"] == "tk_acme"
      [exchange] = MockProvider.requests("/feishu/token")
      assert exchange.params["grant_type"] == "authorization_code"
      assert exchange.params["code_verifier"] == "verifier"
      [identity] = MockProvider.requests("/feishu/user_info")
      assert {"authorization", "Bearer u-access"} in identity.headers

      MockProvider.stub("/feishu/token", %{
        "code" => 0,
        "access_token" => "u-refreshed",
        "refresh_token" => "ur-rotated",
        "expires_in" => 7200
      })

      assert {:ok, refreshed} = Feishu.refresh(@app, tokens)
      assert refreshed["access_token"] == "u-refreshed"
      assert refreshed["refresh_token"] == "ur-rotated"
      assert {:error, :revocation_not_supported} = Feishu.revoke(@app, refreshed)

      MockProvider.stub(
        "/feishu/token",
        %{"code" => 20_037, "error" => "invalid_grant", "error_description" => "expired"},
        400
      )

      assert {:error, :reauthorization_required} =
               Feishu.refresh(@app, %{"refresh_token" => "ur-old"})
    end
  end

  describe "X confidential OAuth" do
    test "authorization binds the state, callback and S256 challenge with read and write scopes" do
      req = %{
        "redirect_uri" => "https://app.example/cb",
        "state" => "state",
        "code_challenge" => "challenge"
      }

      assert {:ok, url} = X.authorization_url(@app, req)
      {uri, params} = query(url)
      assert uri.host == "x.com"
      assert params["state"] == "state"
      assert params["redirect_uri"] == req["redirect_uri"]
      assert params["code_challenge"] == "challenge"
      assert params["code_challenge_method"] == "S256"

      assert params["scope"] ==
               "tweet.read tweet.write users.read media.write follows.read follows.write dm.read dm.write bookmark.read bookmark.write offline.access"

      assert {:error, _} = X.authorization_url(@app, Map.delete(req, "code_challenge"))
    end

    test "exchange, refresh and revoke use the app secret only in HTTP Basic auth" do
      start_mock!()

      MockProvider.stub("/x/token", %{
        "access_token" => "access",
        "refresh_token" => "refresh",
        "scope" => "tweet.read users.read offline.access",
        "expires_in" => 7200
      })

      MockProvider.stub("/x/me", %{"data" => %{"id" => "user-1", "username" => "reader"}})

      assert {:ok, %{"tokens" => tokens, "account" => account}} =
               X.exchange_code(@app, Map.put(@ctx, "code_verifier", "verifier"), "code")

      assert account["provider_account_id"] == "user-1"
      assert tokens["expires_at"] > SystemsClock.system_time(:millisecond)
      [exchange] = MockProvider.requests("/x/token")
      assert exchange.params["code_verifier"] == "verifier"
      assert exchange.params["redirect_uri"] == @ctx["redirect_uri"]
      assert {"authorization", "Basic " <> Base.encode64("cid:sec")} in exchange.headers
      refute Map.has_key?(exchange.params, "client_secret")
      [identity] = MockProvider.requests("/x/me")
      assert {"authorization", "Bearer access"} in identity.headers

      MockProvider.stub("/x/token", %{
        "access_token" => "refreshed",
        "refresh_token" => "rotated",
        "expires_in" => 7200
      })

      assert {:ok, refreshed} = X.refresh(@app, tokens)
      assert refreshed["refresh_token"] == "rotated"
      assert refreshed["scopes"] == tokens["scopes"]
      MockProvider.stub("/x/revoke", %{"revoked" => true})
      assert :ok = X.revoke(@app, refreshed)
      [revoke] = MockProvider.requests("/x/revoke")
      assert revoke.params["token"] == "refreshed"
      assert {"authorization", "Basic " <> Base.encode64("cid:sec")} in revoke.headers
    end

    test "expired grants require authorization and provider error bodies are not exposed" do
      start_mock!()

      MockProvider.stub(
        "/x/token",
        %{"error" => "invalid_grant", "error_description" => "secret-echo"},
        400
      )

      assert {:error, :reauthorization_required} =
               X.refresh(@app, %{"refresh_token" => "refresh"})

      MockProvider.stub(
        "/x/token",
        %{"error" => "invalid_client", "error_description" => "secret-echo"},
        401
      )

      assert {:error, "x oauth: provider returned HTTP 401"} =
               X.refresh(@app, %{"refresh_token" => "refresh"})
    end
  end

  # ---- authorization URLs (pure) ----

  describe "authorization_url" do
    test "google: openid minimum merged in front, offline access, PKCE challenge" do
      req = %{
        "redirect_uri" => "https://app.example/cb",
        "state" => "st-2",
        "scopes" => ["https://www.googleapis.com/auth/drive.readonly", "email"],
        "code_challenge" => "chal-s256"
      }

      assert {:ok, url} = Google.authorization_url(@app, req)
      {uri, q} = query(url)
      assert uri.host == "accounts.google.com"

      assert q["scope"] == "openid email profile https://www.googleapis.com/auth/drive.readonly"
      assert q["response_type"] == "code"
      assert q["access_type"] == "offline"
      assert q["include_granted_scopes"] == "true"
      assert q["prompt"] == "consent"
      assert q["state"] == "st-2"
      assert q["code_challenge"] == "chal-s256"
      assert q["code_challenge_method"] == "S256"
    end
  end

  # ---- github lifecycle over HTTP ----

  describe "github http" do
    setup do
      {:ok, base: start_mock!()}
    end

    test "exchange_code: form body, comma scopes, user metadata fetch" do
      MockProvider.stub("/github/token", %{
        "access_token" => "gho_abc",
        "token_type" => "bearer",
        "scope" => "repo,gist"
      })

      MockProvider.stub("/github/api/user", %{
        "id" => 123,
        "login" => "octo",
        "name" => "Octo Cat"
      })

      assert {:ok, %{"tokens" => tokens, "account" => account}} =
               GitHub.exchange_code(@app, @ctx, "code-1")

      assert tokens["access_token"] == "gho_abc"
      assert tokens["refresh_token"] == nil
      assert tokens["token_type"] == "bearer"
      assert tokens["scopes"] == ["repo", "gist"]
      assert tokens["expires_at"] == nil
      assert tokens["refresh_expires_at"] == nil

      assert account["provider_account_id"] == "123"
      assert account["provider_account_name"] == "octo"
      assert account["metadata"]["login"] == "octo"
      assert account["metadata"]["user_id"] == 123
      assert account["metadata"]["name"] == "Octo Cat"

      assert [%{params: params}] = MockProvider.requests("/github/token")

      assert params == %{
               "client_id" => "cid",
               "client_secret" => "sec",
               "code" => "code-1",
               "redirect_uri" => "https://app.example/cb"
             }

      assert [%{headers: headers}] = MockProvider.requests("/github/api/user")
      assert {"authorization", "Bearer gho_abc"} in headers
    end

    test "refresh: GitHub App rotation with refresh_token_expires_in" do
      MockProvider.stub("/github/token", %{
        "access_token" => "ghu_new",
        "token_type" => "bearer",
        "scope" => "",
        "expires_in" => 28_800,
        "refresh_token" => "ghr_new",
        "refresh_token_expires_in" => 15_897_600
      })

      conn = %{
        "access_token" => "ghu_old",
        "refresh_token" => "ghr_old",
        "token_type" => "bearer",
        "scopes" => []
      }

      before_ms = SystemsClock.system_time(:millisecond)
      assert {:ok, tokens} = GitHub.refresh(@app, conn)

      assert tokens["access_token"] == "ghu_new"
      assert tokens["refresh_token"] == "ghr_new"
      assert_in_delta tokens["expires_at"], before_ms + 28_800 * 1000, 5_000
      assert_in_delta tokens["refresh_expires_at"], before_ms + 15_897_600 * 1000, 5_000

      assert [%{params: params}] = MockProvider.requests("/github/token")
      assert params["grant_type"] == "refresh_token"
      assert params["refresh_token"] == "ghr_old"
    end

    test "refresh: expired refresh token classifies as reauthorization_required" do
      MockProvider.stub("/github/token", %{
        "error" => "bad_refresh_token",
        "error_description" => "The refresh token passed is expired_token."
      })

      conn = %{
        "access_token" => "ghu_old",
        "refresh_token" => "ghr_old",
        "token_type" => "bearer",
        "scopes" => []
      }

      assert {:error, :reauthorization_required} = GitHub.refresh(@app, conn)
    end
  end

  # ---- google lifecycle over HTTP ----

  describe "google http" do
    setup do
      {:ok, base: start_mock!()}
    end

    test "exchange_code: PKCE verifier in form, space scopes, ms expiry, userinfo account" do
      MockProvider.stub("/google/token", %{
        "access_token" => "ya29.x",
        "refresh_token" => "1//refresh",
        "token_type" => "Bearer",
        "expires_in" => 3599,
        "scope" => "openid email profile"
      })

      MockProvider.stub("/google/userinfo", %{
        "sub" => "108",
        "email" => "ada@example.com",
        "email_verified" => true,
        "name" => "Ada",
        "picture" => "https://pic",
        "hd" => "example.com"
      })

      ctx = %{@ctx | "code_verifier" => "ver-123"}
      before_ms = SystemsClock.system_time(:millisecond)

      assert {:ok, %{"tokens" => tokens, "account" => account}} =
               Google.exchange_code(@app, ctx, "code-g")

      assert tokens["access_token"] == "ya29.x"
      assert tokens["refresh_token"] == "1//refresh"
      assert tokens["scopes"] == ["openid", "email", "profile"]
      assert_in_delta tokens["expires_at"], before_ms + 3599 * 1000, 5_000

      assert account["provider_account_id"] == "108"
      assert account["provider_account_name"] == "ada@example.com"
      assert account["metadata"]["email_verified"] == true
      assert account["metadata"]["hosted_domain"] == "example.com"

      assert [%{params: params}] = MockProvider.requests("/google/token")
      assert params["grant_type"] == "authorization_code"
      assert params["code"] == "code-g"
      assert params["code_verifier"] == "ver-123"
    end

    test "refresh: keeps the existing refresh_token and scopes when the response omits them" do
      MockProvider.stub("/google/token", %{
        "access_token" => "ya29.new",
        "token_type" => "Bearer",
        "expires_in" => 3600
      })

      conn = %{
        "access_token" => "ya29.old",
        "refresh_token" => "1//keep",
        "token_type" => "Bearer",
        "scopes" => ["openid", "email"]
      }

      assert {:ok, tokens} = Google.refresh(@app, conn)
      assert tokens["access_token"] == "ya29.new"
      assert tokens["refresh_token"] == "1//keep"
      assert tokens["scopes"] == ["openid", "email"]
    end
  end

  describe "linear http" do
    setup do
      {:ok, base: start_mock!()}
    end

    test "exchange and refresh preserve space-delimited provider grants" do
      MockProvider.stub("/linear/token", %{
        "access_token" => "linear-access",
        "refresh_token" => "linear-refresh",
        "scope" => "read write"
      })

      MockProvider.stub("/linear/api", %{
        "data" => %{"viewer" => %{"id" => "user-1"}, "organization" => %{"id" => "org-1"}}
      })

      assert {:ok, %{"tokens" => tokens}} = Linear.exchange_code(@app, @ctx, "code")
      assert tokens["scopes"] == ["read", "write"]
      assert {:ok, refreshed} = Linear.refresh(@app, tokens)
      assert refreshed["scopes"] == ["read", "write"]

      MockProvider.stub("/linear/token", %{"access_token" => "next", "scope" => "read,write"})
      assert {:ok, refreshed} = Linear.refresh(@app, tokens)
      assert refreshed["scopes"] == ["read", "write"]
    end
  end

  # ---- slack lifecycle over HTTP ----

  describe "slack http" do
    setup do
      {:ok, base: start_mock!()}
    end

    test "exchange_code: lifts the authed_user xoxp token; team in account name" do
      MockProvider.stub("/slack/token", %{
        "ok" => true,
        "app_id" => "A1",
        "team" => %{"id" => "T1", "name" => "Acme"},
        "enterprise" => %{"id" => "E1", "name" => "AcmeCorp"},
        "authed_user" => %{
          "id" => "U1",
          "scope" => "chat:write,channels:read",
          "access_token" => "xoxp-user-1",
          "token_type" => "user"
        }
      })

      assert {:ok, %{"tokens" => tokens, "account" => account}} =
               Slack.exchange_code(@app, @ctx, "code-s")

      assert tokens["access_token"] == "xoxp-user-1"
      assert tokens["slack_user_token"] == "xoxp-user-1"
      assert tokens["refresh_token"] == nil
      assert tokens["token_type"] == "user"
      assert tokens["scopes"] == ["chat:write", "channels:read"]
      assert tokens["expires_at"] == nil

      assert account["provider_account_id"] == "U1"
      assert account["provider_account_name"] == "U1 · Acme"
      assert account["metadata"]["team_id"] == "T1"
      assert account["metadata"]["app_id"] == "A1"
      assert account["metadata"]["enterprise_id"] == "E1"

      assert [%{params: params}] = MockProvider.requests("/slack/token")
      assert params["client_id"] == "cid"
      assert params["code"] == "code-s"
    end
  end

  # ---- credential values (pure) ----

  describe "credential values" do
    test "resolve_credential_value returns the stored access token" do
      conn = %{"access_token" => "tok-1"}

      for mod <- [GitHub, Google, Linear, Notion] do
        assert {:ok, "tok-1"} = mod.resolve_credential_value(conn, "access_token")
        assert {:error, _} = mod.resolve_credential_value(conn, "id_token")
        assert {:error, msg} = mod.resolve_credential_value(nil, "access_token")
        assert msg =~ "connection is nil"
      end
    end
  end
end
