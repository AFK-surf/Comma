defmodule SalixWeb.OAuthFlowTest do
  @moduledoc """
  End-to-end OAuth flow (willow `internal/api/oauth.go` parity): web-origin
  authorize → provider callback (consume → exchange → connection → binding →
  terminal auth-state outcome → completion page / 303), replay + expiry +
  mismatch failure paths, alias re-authorization orphan cleanup, binding
  deletion revocation, and provider-app secret hygiene. The provider is a
  real Bandit listener wired in through the `:oauth_endpoint_overrides` seam;
  storage is the Fake S3 backend.
  """
  use ExUnit.Case, async: false

  alias SalixStore.OAuth.AuthState
  alias SalixWeb.OAuthFlow

  defmodule MockProvider do
    @moduledoc """
    Minimal OAuth provider: any POST answers the token exchange with the
    currently-configured access token, any GET answers the account-metadata
    fetch, anything else 204s (revocation). Requests are recorded.
    """
    @behaviour Plug
    import Plug.Conn

    def state_child_spec do
      %{
        id: __MODULE__,
        start:
          {Agent, :start_link,
           [fn -> %{token: "gh-access", requests: []} end, [name: __MODULE__]]}
      }
    end

    def set_access_token(token), do: Agent.update(__MODULE__, &Map.put(&1, :token, token))

    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      Agent.update(
        __MODULE__,
        &Map.update!(&1, :requests, fn reqs ->
          [%{method: conn.method, path: conn.request_path} | reqs]
        end)
      )

      case conn.method do
        "POST" ->
          token = Agent.get(__MODULE__, & &1.token)

          json(conn, %{
            "access_token" => token,
            "token_type" => "bearer",
            "scope" => "repo"
          })

        "GET" ->
          json(conn, %{"id" => 12_345, "login" => "octocat", "name" => "Octo Cat"})

        _ ->
          send_resp(conn, 204, "")
      end
    end

    defp json(conn, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end

  setup do
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_overrides = Application.get_env(:salix_store, :oauth_endpoint_overrides)
    prev_api_token = Application.get_env(:salix_web, :api_token)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_web, :api_token, "test-token")
    start_supervised!(SalixStore.S3.Fake)

    start_supervised!(MockProvider.state_child_spec())

    bandit =
      start_supervised!(
        {Bandit,
         plug: MockProvider, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    mock_base = "http://127.0.0.1:#{port}"

    Application.put_env(:salix_store, :oauth_endpoint_overrides, %{
      "github" => %{
        "authorize_url" => mock_base <> "/login/oauth/authorize",
        "token_url" => mock_base <> "/login/oauth/access_token",
        "api_url" => mock_base,
        "revoke_url" => mock_base <> "/revoke"
      }
    })

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, prev_backend)

      # put_env(key, nil) stores a literal nil that shadows get_env defaults.
      if prev_overrides do
        Application.put_env(:salix_store, :oauth_endpoint_overrides, prev_overrides)
      else
        Application.delete_env(:salix_store, :oauth_endpoint_overrides)
      end

      if prev_api_token do
        Application.put_env(:salix_web, :api_token, prev_api_token)
      else
        Application.delete_env(:salix_web, :api_token)
      end
    end)

    tenant_resp = req(:post, "/v1/admin/tenants", json: %{name: "OAuth Tenant"})
    tenant_id = tenant_resp.body["tenant_id"]

    key_resp = req(:post, "/v1/admin/tenants/#{tenant_id}/api-keys", json: %{name: "test"})
    tenant_key = key_resp.body["key"]

    Process.put(:test_tenant_id, tenant_id)
    Process.put(:test_tenant_key, tenant_key)

    create_resp = treq(:post, "/v1/runtime/agent-groups", json: %{name: "OAuth"})
    group_id = create_resp.body["group_id"]

    {:ok, _} =
      Salix.Control.OAuthApps.put(tenant_id, "github", %{
        "client_id" => "gh-client",
        "client_secret" => "gh-secret"
      })

    {:ok, group: group_id, mock_base: mock_base, tenant_id: tenant_id}
  end

  defp tenant_id, do: Process.get(:test_tenant_id)
  defp tenant_key, do: Process.get(:test_tenant_key)

  defp req(method, path, opts \\ []) do
    req_as("test-token", method, path, opts)
  end

  # Tenant-scoped request: authorizes with the tenant API key (created in setup).
  defp treq(method, path, opts \\ []) do
    req_as(tenant_key(), method, path, opts)
  end

  defp req_as(token, method, path, opts) do
    headers = [{"authorization", "Bearer " <> token}]

    Req.request!([method: method, url: base() <> path, headers: headers, redirect: false] ++ opts)
  end

  defp base, do: SalixWeb.Application.base_url()

  defp authorize(group, params \\ %{"alias" => "work", "scopes" => ["repo"]}) do
    {:ok, %{"authorization_url" => url, "state" => state}} =
      OAuthFlow.start_authorization(tenant_id(), group, "github", params)

    {url, state}
  end

  defp callback(provider, query) do
    req(:get, "/v1/oauth/#{provider}/callback?" <> URI.encode_query(query))
  end

  test "authorize → callback: connection, binding, completed auth state, page",
       %{group: group, mock_base: mock_base} do
    {url, state} = authorize(group)

    # The authorize URL targets the (overridden) provider endpoint and
    # carries the tenant app + CSRF state.
    assert String.starts_with?(url, mock_base)
    query = URI.decode_query(URI.parse(url).query || "")
    assert query["client_id"] == "gh-client"
    assert query["state"] == state

    # Pending until the callback fires; no binding visible yet.
    assert {:ok, %{"status" => "pending", "origin" => "web"}} = AuthState.get(state)
    assert Salix.Control.OAuthBindings.list(group) == []

    resp = callback("github", %{"state" => state, "code" => "test-code"})
    assert resp.status == 200
    assert resp.headers["cache-control"] == ["no-store"]
    assert resp.body =~ "Successfully connected to GitHub"

    # Terminal outcome the agent-side completion tool polls for.
    {:ok, auth} = AuthState.get(state)
    assert auth["status"] == "completed"
    assert is_binary(auth["binding_id"])
    assert is_binary(auth["connection_id"])
    assert auth["provider_account_name"] == "octocat"

    # Binding joined with public connection metadata — never token values.
    assert [binding] = Salix.Control.OAuthBindings.list(group)
    assert binding["binding_id"] == auth["binding_id"]
    assert binding["provider"] == "github"
    assert binding["alias"] == "work"
    assert binding["provider_account_name"] == "octocat"
    assert binding["status"] == "active"
    refute Map.has_key?(binding, "access_token")
    refute Map.has_key?(binding, "refresh_token")

    # The stored connection record carries the exchanged tokens.
    {:ok, conn_rec} = SalixStore.OAuth.get(binding["connection_id"])
    assert conn_rec["access_token"] == "gh-access"
    assert conn_rec["status"] == "active"
    assert conn_rec["provider"] == "github"
    assert conn_rec["tenant"] == tenant_id()
    assert is_list(conn_rec["scopes"]) and conn_rec["scopes"] != []

    # PATCH rename: willow's response shape, alias cannot be blanked.
    patched =
      treq(
        :patch,
        "/v1/runtime/agent-groups/#{group}/oauth-connections/#{binding["binding_id"]}",
        json: %{alias: "renamed"}
      )

    assert patched.body == %{
             "binding_id" => binding["binding_id"],
             "alias" => "renamed",
             "provider" => "github"
           }

    assert treq(
             :patch,
             "/v1/runtime/agent-groups/#{group}/oauth-connections/#{binding["binding_id"]}",
             json: %{alias: "  "}
           ).status == 400
  end

  test "only trusted product context survives OAuth as member provenance", %{group: group} do
    member = %{"user_id" => "comma-user", "workspace_id" => "comma-workspace"}

    # Public request parameters cannot claim an authenticated product user.
    assert {:ok, untrusted} =
             OAuthFlow.start_authorization(tenant_id(), group, "github", %{
               "alias" => "untrusted",
               "comma_member" => member
             })

    assert callback("github", %{"state" => untrusted["state"], "code" => "code"}).status == 200
    {:ok, completed} = AuthState.get(untrusted["state"])
    {:ok, connection} = SalixStore.OAuth.get(completed["connection_id"])
    assert connection["comma_member"] == nil

    assert {:ok, trusted} =
             OAuthFlow.start_authorization(tenant_id(), group, "github", %{"alias" => "trusted"},
               comma_member: member
             )

    # Callback parameters must not replace the server-stored subject.
    assert callback("github", %{
             "state" => trusted["state"],
             "code" => "code",
             "comma_member" => "attacker"
           }).status == 200

    {:ok, completed} = AuthState.get(trusted["state"])
    {:ok, connection} = SalixStore.OAuth.get(completed["connection_id"])
    assert connection["comma_member"] == member
    refute Map.has_key?(hd(Salix.Control.OAuthBindings.list(group)), "comma_member")
  end

  test "callback replay loses: the state is consumed atomically", %{group: group} do
    {_url, state} = authorize(group)

    assert callback("github", %{"state" => state, "code" => "test-code"}).status == 200

    replay = callback("github", %{"state" => state, "code" => "test-code"})
    assert replay.status == 400
    assert replay.body =~ "authorization session expired"

    # The first outcome is untouched.
    assert {:ok, %{"status" => "completed"}} = AuthState.get(state)
  end

  test "web redirect_after: success 303s back, failure carries oauth_error", %{group: group} do
    {_url, state} =
      authorize(group, %{
        "alias" => "work",
        "scopes" => ["repo"],
        "redirect_after" => "https://app.example.test/done?tab=integrations"
      })

    resp = callback("github", %{"state" => state, "code" => "test-code"})
    assert resp.status == 303
    assert resp.headers["location"] == ["https://app.example.test/done?tab=integrations"]

    {_url, denied_state} =
      authorize(group, %{
        "alias" => "work2",
        "redirect_after" => "https://app.example.test/done"
      })

    denied = callback("github", %{"state" => denied_state, "error" => "access_denied"})
    assert denied.status == 303
    [location] = denied.headers["location"]
    assert String.starts_with?(location, "https://app.example.test/done?")
    assert URI.decode_query(URI.parse(location).query)["oauth_error"] =~ "access_denied"

    assert {:ok, %{"status" => "failed", "error" => error}} = AuthState.get(denied_state)
    assert error =~ "authorization denied"
  end

  test "failure paths: missing state, missing code, mismatch, expiry", %{group: group} do
    missing = req(:get, "/v1/oauth/github/callback")
    assert missing.status == 400
    assert missing.body =~ "missing state"

    {_url, no_code} = authorize(group, %{"alias" => "no-code"})
    resp = callback("github", %{"state" => no_code})
    assert resp.status == 400
    assert resp.body =~ "missing code"
    assert {:ok, %{"status" => "failed"}} = AuthState.get(no_code)

    # Provider mismatch: a github state arriving on the google callback.
    {_url, mismatched} = authorize(group, %{"alias" => "mismatch"})
    resp = callback("google", %{"state" => mismatched, "code" => "test-code"})
    assert resp.status == 400
    assert resp.body =~ "provider mismatch"

    assert {:ok, %{"status" => "failed", "error" => "provider mismatch"}} =
             AuthState.get(mismatched)

    # Expired state: the callback reports the session expired and the record
    # flips to a terminal status.
    now = System.system_time(:millisecond)
    stale_state = "expired-#{System.unique_integer([:positive])}"

    :ok =
      AuthState.create(%{
        "state" => stale_state,
        "tenant" => tenant_id(),
        "group_id" => group,
        "provider" => "github",
        "alias" => "stale",
        "scopes" => [],
        "code_verifier" => "v",
        "redirect_uri" => base() <> "/v1/oauth/github/callback",
        "origin" => "web",
        "expires_at" => now - 1000,
        "created_at" => now - 700_000
      })

    resp = callback("github", %{"state" => stale_state, "code" => "test-code"})
    assert resp.status == 400
    assert resp.body =~ "authorization session expired"
    assert {:ok, %{"status" => "expired"}} = AuthState.get(stale_state)

    # No binding materialized from any failure path.
    assert Salix.Control.OAuthBindings.list(group) == []
  end

  test "re-authorizing an alias repoints the binding and cleans up the orphan",
       %{group: group} do
    MockProvider.set_access_token("tok-a")
    {_url, first} = authorize(group, %{"alias" => "work"})
    assert callback("github", %{"state" => first, "code" => "c1"}).status == 200

    [binding] = Salix.Control.OAuthBindings.list(group)
    first_conn = binding["connection_id"]
    assert {:ok, %{"access_token" => "tok-a"}} = SalixStore.OAuth.get(first_conn)

    # Different token material → the orphaned connection is deleted.
    MockProvider.set_access_token("tok-b")
    {_url, second} = authorize(group, %{"alias" => "work"})
    assert callback("github", %{"state" => second, "code" => "c2"}).status == 200

    assert [rebound] = Salix.Control.OAuthBindings.list(group)
    assert rebound["binding_id"] == binding["binding_id"]
    assert rebound["connection_id"] != first_conn
    assert {:ok, %{"access_token" => "tok-b"}} = SalixStore.OAuth.get(rebound["connection_id"])
    assert SalixStore.OAuth.get(first_conn) == {:error, :not_found}
  end

  test "deleting the last binding removes the connection", %{group: group} do
    {_url, state} = authorize(group, %{"alias" => "work"})
    assert callback("github", %{"state" => state, "code" => "c"}).status == 200

    [binding] = Salix.Control.OAuthBindings.list(group)
    connection_id = binding["connection_id"]
    assert {:ok, _} = SalixStore.OAuth.get(connection_id)

    deleted =
      treq(
        :delete,
        "/v1/runtime/agent-groups/#{group}/oauth-connections/#{binding["binding_id"]}"
      )

    assert deleted.body["status"] == "deleted"
    assert Salix.Control.OAuthBindings.list(group) == []
    assert SalixStore.OAuth.get(connection_id) == {:error, :not_found}

    # Idempotence at the HTTP layer: the binding is gone → tenant-scoped 404.
    assert treq(
             :delete,
             "/v1/runtime/agent-groups/#{group}/oauth-connections/#{binding["binding_id"]}"
           ).status ==
             404
  end

  test "provider app reads never echo the stored secret" do
    put =
      treq(:put, "/v1/runtime/oauth/provider-apps/github", json: %{client_id: "gh-client"})

    assert put.status == 200
    assert put.body["client_secret_configured"] == true
    refute Map.has_key?(put.body, "client_secret")

    listed =
      Enum.find(
        treq(:get, "/v1/runtime/oauth/provider-apps").body,
        &(&1["provider"] == "github")
      )

    assert listed["client_id"] == "gh-client"
    assert listed["client_secret_configured"] == true
    refute Map.has_key?(listed, "client_secret")

    # The flow-side read returns the full credentials (pointer-merge kept the
    # secret through the client_id-only PUT above).
    assert {:ok, %{"client_id" => "gh-client", "client_secret" => "gh-secret"}} =
             Salix.Control.OAuthApps.get(tenant_id(), "github")
  end

  test "agent oauth context + bindings seam (SalixWeb.OAuthStore)", %{group: group} do
    {_url, state} = authorize(group, %{"alias" => "work"})
    assert callback("github", %{"state" => state, "code" => "c"}).status == 200

    assert {:ok, bindings} = SalixWeb.OAuthStore.bindings_for_group(group)
    assert [%{"alias" => "work", "provider" => "github", "binding_id" => binding_id}] = bindings

    # delete_binding seam (the agent's delete_oauth_credential tool path) removes
    # the binding; a missing binding is reported as not_found.
    assert :ok = SalixWeb.OAuthStore.delete_binding(tenant_id(), group, binding_id)
    assert {:ok, []} = SalixWeb.OAuthStore.bindings_for_group(group)

    assert {:error, :not_found} =
             SalixWeb.OAuthStore.delete_binding(tenant_id(), group, binding_id)

    assert {:ok, %{"client_id" => "gh-client"}} =
             SalixWeb.OAuthStore.provider_app(tenant_id(), "github")

    assert SalixWeb.OAuthStore.provider_app(tenant_id(), "google") == {:error, :not_configured}
    assert is_binary(SalixWeb.OAuthStore.public_base_url())

    tid = tenant_id()

    {:ok, agent} =
      SalixAgent.Control.create(%{"group_id" => group, "name" => "OAuth Agent"}, tid)

    agent_id = agent["agent_id"]

    assert {:ok, %{tenant: ^tid, group_id: ^group}} =
             SalixWeb.OAuthStore.agent_oauth_context(agent_id)

    assert SalixWeb.OAuthStore.agent_oauth_context("missing-agent") == {:error, :not_found}
  end
end
