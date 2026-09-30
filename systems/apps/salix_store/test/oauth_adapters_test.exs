defmodule SalixStore.OAuthAdaptersTest do
  @moduledoc """
  OAuth provider adapters (port of willow's `internal/oauth/*.go`): registry
  resolution, authorization-URL shapes (state, PKCE challenge, scope encoding),
  and the GitHub / Google / Slack token lifecycles (exchange, refresh including
  invalid_grant → :reauthorization_required, revoke) driven through a
  Bandit/Plug mock provider via the `:oauth_endpoint_overrides` seam.
  """
  use ExUnit.Case, async: false

  alias SalixStore.OAuth.Adapters
  alias SalixStore.OAuth.Adapters.{GitHub, Google, Linear, Notion, Slack}

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
      p = 40_000 + :erlang.phash2(make_ref(), 20_000)

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

    prev = Application.get_env(:salix_store, :oauth_endpoint_overrides)

    Application.put_env(:salix_store, :oauth_endpoint_overrides, %{
      "github" => %{"token_url" => "#{base}/github/token", "api_url" => "#{base}/github/api"},
      "google" => %{
        "token_url" => "#{base}/google/token",
        "revoke_url" => "#{base}/google/revoke",
        "api_url" => "#{base}/google/userinfo"
      },
      "linear" => %{"token_url" => "#{base}/linear/token", "api_url" => "#{base}/linear/api"},
      "slack" => %{"token_url" => "#{base}/slack/token", "revoke_url" => "#{base}/slack/revoke"}
    })

    ExUnit.Callbacks.on_exit(fn ->
      if prev,
        do: Application.put_env(:salix_store, :oauth_endpoint_overrides, prev),
        else: Application.delete_env(:salix_store, :oauth_endpoint_overrides)
    end)

    base
  end

  defp query(url) do
    uri = URI.parse(url)
    {uri, URI.decode_query(uri.query)}
  end

  # ---- registry ----

  describe "Adapters registry" do
    test "resolves all five providers, normalizing case and whitespace" do
      assert {:ok, GitHub} = Adapters.for_provider("github")
      assert {:ok, GitHub} = Adapters.for_provider("  GitHub ")
      assert {:ok, Google} = Adapters.for_provider("google")
      assert {:ok, Linear} = Adapters.for_provider("linear")
      assert {:ok, Notion} = Adapters.for_provider("notion")
      assert {:ok, Slack} = Adapters.for_provider("slack")
    end

    test "unknown provider" do
      assert {:error, :unsupported_provider} = Adapters.for_provider("gitlab")
      assert {:error, :unsupported_provider} = Adapters.for_provider(nil)
    end

    test "supported/0 lists every provider" do
      assert Adapters.supported() == ["github", "google", "linear", "notion", "slack"]
    end

    test "default env vars match willow's listoauth map" do
      assert GitHub.default_env_var() == "GH_TOKEN"
      assert Google.default_env_var() == "GOOGLE_ACCESS_TOKEN"
      assert Linear.default_env_var() == "LINEAR_ACCESS_TOKEN"
      assert Notion.default_env_var() == "NOTION_TOKEN"
      assert Slack.default_env_var() == "SLACK_USER_TOKEN"
    end
  end

  # ---- authorization URLs (pure) ----

  describe "authorization_url" do
    test "github: scope space-joined, allow_signup=false, no PKCE" do
      req = %{
        "redirect_uri" => "https://app.example/cb",
        "state" => "st-1",
        "scopes" => ["repo", "read:org"],
        "code_challenge" => "ignored-by-github"
      }

      assert {:ok, url} = GitHub.authorization_url(@app, req)
      {uri, q} = query(url)
      assert uri.host == "github.com"
      assert uri.path == "/login/oauth/authorize"

      assert q == %{
               "client_id" => "cid",
               "redirect_uri" => "https://app.example/cb",
               "state" => "st-1",
               "scope" => "repo read:org",
               "allow_signup" => "false"
             }
    end

    test "github: scope omitted when no scopes requested" do
      req = %{
        "redirect_uri" => "https://app.example/cb",
        "state" => "s",
        "scopes" => [],
        "code_challenge" => nil
      }

      assert {:ok, url} = GitHub.authorization_url(@app, req)
      {_uri, q} = query(url)
      refute Map.has_key?(q, "scope")
    end

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

    test "google: no PKCE params when code_challenge is nil" do
      req = %{
        "redirect_uri" => "https://app.example/cb",
        "state" => "s",
        "scopes" => [],
        "code_challenge" => nil
      }

      assert {:ok, url} = Google.authorization_url(@app, req)
      {_uri, q} = query(url)
      refute Map.has_key?(q, "code_challenge")
      refute Map.has_key?(q, "code_challenge_method")
      assert q["scope"] == "openid email profile"
    end

    test "linear: comma-joined scopes, default read, PKCE" do
      req = %{
        "redirect_uri" => "https://app.example/cb",
        "state" => "s",
        "scopes" => [],
        "code_challenge" => "ch"
      }

      assert {:ok, url} = Linear.authorization_url(@app, req)
      {uri, q} = query(url)
      assert uri.host == "linear.app"
      assert q["scope"] == "read"
      assert q["prompt"] == "consent"
      assert q["response_type"] == "code"
      assert q["code_challenge"] == "ch"
      assert q["code_challenge_method"] == "S256"

      req2 = %{req | "scopes" => ["read", "write"]}
      assert {:ok, url2} = Linear.authorization_url(@app, req2)
      {_uri2, q2} = query(url2)
      assert q2["scope"] == "read,write"
    end

    test "notion: owner=user, no scope param" do
      req = %{
        "redirect_uri" => "https://app.example/cb",
        "state" => "ns",
        "scopes" => [],
        "code_challenge" => nil
      }

      assert {:ok, url} = Notion.authorization_url(@app, req)
      {uri, q} = query(url)
      assert uri.host == "api.notion.com"
      assert uri.path == "/v1/oauth/authorize"
      assert q["owner"] == "user"
      assert q["response_type"] == "code"
      assert q["state"] == "ns"
      refute Map.has_key?(q, "scope")
    end

    test "slack: scopes go to user_scope comma-joined; omitted when empty" do
      req = %{
        "redirect_uri" => "https://app.example/cb",
        "state" => "ss",
        "scopes" => ["chat:write", " channels:read ", ""],
        "code_challenge" => nil
      }

      assert {:ok, url} = Slack.authorization_url(@app, req)
      {uri, q} = query(url)
      assert uri.host == "slack.com"
      assert uri.path == "/oauth/v2/authorize"
      assert q["user_scope"] == "chat:write,channels:read"
      refute Map.has_key?(q, "scope")

      assert {:ok, url2} = Slack.authorization_url(@app, %{req | "scopes" => []})
      {_uri2, q2} = query(url2)
      refute Map.has_key?(q2, "user_scope")
    end

    test "missing client_id / redirect_uri" do
      req = %{
        "redirect_uri" => "https://app.example/cb",
        "state" => "s",
        "scopes" => [],
        "code_challenge" => nil
      }

      for mod <- [GitHub, Google, Linear, Notion, Slack] do
        assert {:error, msg} = mod.authorization_url(%{"client_id" => " "}, req)
        assert msg =~ "client_id is required"
        assert {:error, msg2} = mod.authorization_url(@app, %{req | "redirect_uri" => ""})
        assert msg2 =~ "redirect_uri is required"
      end
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

    test "exchange_code: provider error surfaces error_description" do
      MockProvider.stub("/github/token", %{
        "error" => "bad_verification_code",
        "error_description" => "The code passed is incorrect or expired."
      })

      assert {:error, "github token error: The code passed is incorrect or expired."} =
               GitHub.exchange_code(@app, @ctx, "bad")
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

      before_ms = System.system_time(:millisecond)
      assert {:ok, tokens} = GitHub.refresh(@app, conn)

      assert tokens["access_token"] == "ghu_new"
      assert tokens["refresh_token"] == "ghr_new"
      assert_in_delta tokens["expires_at"], before_ms + 28_800 * 1000, 5_000
      assert_in_delta tokens["refresh_expires_at"], before_ms + 15_897_600 * 1000, 5_000

      assert [%{params: params}] = MockProvider.requests("/github/token")
      assert params["grant_type"] == "refresh_token"
      assert params["refresh_token"] == "ghr_old"
    end

    test "refresh: classic OAuth App (no refresh token) returns the stored token without HTTP" do
      conn = %{
        "access_token" => "gho_classic",
        "refresh_token" => nil,
        "token_type" => "bearer",
        "scopes" => ["repo"]
      }

      assert {:ok, tokens} = GitHub.refresh(@app, conn)
      assert tokens["access_token"] == "gho_classic"
      assert tokens["refresh_token"] == nil
      assert tokens["expires_at"] == nil
      assert tokens["scopes"] == ["repo"]
      assert MockProvider.requests("/github/token") == []
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

    test "revoke is a documented no-op" do
      assert {:error, :revocation_not_supported} =
               GitHub.revoke(@app, %{"access_token" => "gho_x"})
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
      before_ms = System.system_time(:millisecond)

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

    test "refresh: invalid_grant → reauthorization_required" do
      MockProvider.stub("/google/token", %{
        "error" => "invalid_grant",
        "error_description" => "Token has been expired or revoked."
      })

      conn = %{"access_token" => "ya29.old", "refresh_token" => "1//dead", "scopes" => []}
      assert {:error, :reauthorization_required} = Google.refresh(@app, conn)
    end

    test "refresh: no refresh token is an error (not a passthrough)" do
      conn = %{"access_token" => "ya29.old", "refresh_token" => "", "scopes" => []}
      assert {:error, msg} = Google.refresh(@app, conn)
      assert msg =~ "no refresh token"
    end

    test "revoke: prefers refresh token; 200 and 400 both succeed; 500 fails" do
      MockProvider.stub("/google/revoke", %{})

      conn = %{"access_token" => "ya29.x", "refresh_token" => "1//r"}
      assert :ok = Google.revoke(@app, conn)
      assert [%{params: %{"token" => "1//r"}}] = MockProvider.requests("/google/revoke")

      # Already-revoked → 400 is success.
      MockProvider.stub("/google/revoke", %{"error" => "invalid_token"}, 400)
      assert :ok = Google.revoke(@app, conn)

      MockProvider.stub("/google/revoke", %{"error" => "boom"}, 500)
      assert {:error, "google token revocation: status 500"} = Google.revoke(@app, conn)

      # Nothing on file → no-op success.
      assert :ok = Google.revoke(@app, %{"access_token" => "", "refresh_token" => nil})
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

    test "exchange_code: ok:false surfaces the slack error" do
      MockProvider.stub("/slack/token", %{"ok" => false, "error" => "invalid_code"})
      assert {:error, "slack token error: invalid_code"} = Slack.exchange_code(@app, @ctx, "bad")
    end

    test "exchange_code: bot-only response (no authed_user token) errors" do
      MockProvider.stub("/slack/token", %{
        "ok" => true,
        "access_token" => "xoxb-bot",
        "authed_user" => %{"id" => "U9"}
      })

      assert {:error, msg} = Slack.exchange_code(@app, @ctx, "code")
      assert msg =~ "ensure user_scope was requested"
    end

    test "refresh: rotated token arrives at the top level" do
      MockProvider.stub("/slack/token", %{
        "ok" => true,
        "access_token" => "xoxp-rotated",
        "refresh_token" => "xoxe-2",
        "token_type" => "user",
        "scope" => "chat:write",
        "expires_in" => 43_200
      })

      conn = %{
        "access_token" => "xoxp-old",
        "refresh_token" => "xoxe-1",
        "token_type" => "user",
        "scopes" => []
      }

      before_ms = System.system_time(:millisecond)
      assert {:ok, tokens} = Slack.refresh(@app, conn)

      assert tokens["access_token"] == "xoxp-rotated"
      assert tokens["slack_user_token"] == "xoxp-rotated"
      assert tokens["refresh_token"] == "xoxe-2"
      assert tokens["scopes"] == ["chat:write"]
      assert_in_delta tokens["expires_at"], before_ms + 43_200 * 1000, 5_000

      assert [%{params: params}] = MockProvider.requests("/slack/token")
      assert params["grant_type"] == "refresh_token"
      assert params["refresh_token"] == "xoxe-1"
    end

    test "refresh: no rotation (no refresh token) returns the existing token without HTTP" do
      conn = %{
        "access_token" => "xoxp-stable",
        "refresh_token" => nil,
        "token_type" => "user",
        "scopes" => ["chat:write"]
      }

      assert {:ok, tokens} = Slack.refresh(@app, conn)
      assert tokens["access_token"] == "xoxp-stable"
      assert tokens["slack_user_token"] == "xoxp-stable"
      assert tokens["refresh_token"] == nil
      assert MockProvider.requests("/slack/token") == []
    end

    test "revoke: ok:true and already-invalid errors succeed; other errors fail" do
      conn = %{"access_token" => "xoxp-user-1"}

      MockProvider.stub("/slack/revoke", %{"ok" => true, "revoked" => true})
      assert :ok = Slack.revoke(@app, conn)
      assert [%{params: %{"token" => "xoxp-user-1"}}] = MockProvider.requests("/slack/revoke")

      MockProvider.stub("/slack/revoke", %{"ok" => false, "error" => "token_revoked"})
      assert :ok = Slack.revoke(@app, conn)

      MockProvider.stub("/slack/revoke", %{"ok" => false, "error" => "ratelimited"})
      assert {:error, "slack token revocation: ratelimited"} = Slack.revoke(@app, conn)

      assert :ok = Slack.revoke(@app, %{"access_token" => " "})
    end
  end

  # ---- credential values (pure) ----

  describe "credential values" do
    test "validate_credential_value accepts only access_token" do
      for mod <- [GitHub, Google, Linear, Notion, Slack] do
        assert :ok = mod.validate_credential_value("access_token", [])
        assert {:error, msg} = mod.validate_credential_value("refresh_token", [])
        assert msg =~ "unsupported credential value"
      end
    end

    test "resolve_credential_value returns the stored access token" do
      conn = %{"access_token" => "tok-1"}

      for mod <- [GitHub, Google, Linear, Notion] do
        assert {:ok, "tok-1"} = mod.resolve_credential_value(conn, "access_token")
        assert {:error, _} = mod.resolve_credential_value(conn, "id_token")
        assert {:error, msg} = mod.resolve_credential_value(nil, "access_token")
        assert msg =~ "connection is nil"
      end
    end

    test "slack resolves the xoxp user token, preferring the explicit extra" do
      assert {:ok, "xoxp-extra"} =
               Slack.resolve_credential_value(
                 %{"access_token" => "xoxp-primary", "slack_user_token" => "xoxp-extra"},
                 "access_token"
               )

      assert {:ok, "xoxp-primary"} =
               Slack.resolve_credential_value(%{"access_token" => "xoxp-primary"}, "access_token")

      assert {:error, _} = Slack.resolve_credential_value(%{"access_token" => "x"}, "bot_token")
      assert {:error, _} = Slack.resolve_credential_value(nil, "access_token")
    end
  end
end
