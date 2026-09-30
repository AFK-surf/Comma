defmodule MCPRemoteOAuthE2E.MockState do
  @moduledoc false
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> initial() end, name: __MODULE__)

  def reset(base_url, run_id) do
    Agent.update(__MODULE__, fn _state ->
      initial()
      |> Map.put(:base_url, base_url)
      |> Map.put(:run_id, run_id)
    end)
  end

  def get(key), do: Agent.get(__MODULE__, &Map.get(&1, key))

  def put(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))

  def update(key, fun) do
    Agent.get_and_update(__MODULE__, fn state ->
      value = fun.(Map.get(state, key))
      {value, Map.put(state, key, value)}
    end)
  end

  def record_authorization(value), do: put(:last_authorization, value)
  def record_authorization_request(value), do: put(:last_authorization_request, value)
  def record_revocation(value), do: update(:revocations, &[value | List.wrap(&1)])

  defp initial do
    %{
      base_url: nil,
      run_id: nil,
      refresh_count: 0,
      static_refresh_should_fail: false,
      refresh_should_fail: false,
      reject_valid_bearer_once: false,
      last_authorization: nil,
      last_authorization_request: nil,
      registered_clients: [],
      revocations: []
    }
  end
end

defmodule MCPRemoteOAuthE2E.MockProvider do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    case {conn.method, conn.request_path} do
      {"GET", "/.well-known/oauth-protected-resource/mcp"} ->
        protected_resource(conn, "/mcp", "/dcr")

      {"GET", "/.well-known/oauth-protected-resource/static/mcp"} ->
        protected_resource(conn, "/static/mcp", "/static")

      {"GET", "/.well-known/oauth-protected-resource/static-basic/mcp"} ->
        protected_resource(conn, "/static-basic/mcp", "/static-basic")

      {"GET", "/.well-known/oauth-protected-resource/dcr-fail/mcp"} ->
        protected_resource(conn, "/dcr-fail/mcp", "/dcr-fail")

      {"GET", "/.well-known/oauth-protected-resource/mismatch/mcp"} ->
        protected_resource_mismatch(conn)

      {"GET", "/.well-known/oauth-protected-resource/issuer-mismatch/mcp"} ->
        protected_resource(conn, "/issuer-mismatch/mcp", "/issuer-mismatch")

      {"GET", "/.well-known/oauth-protected-resource/no-resource/mcp"} ->
        protected_resource_without_resource(conn, "/dcr")

      {"GET", "/challenge/metadata"} ->
        protected_resource(conn, "/challenge/mcp", "/dcr")

      {"GET", "/.well-known/oauth-authorization-server/dcr"} ->
        authorization_metadata(conn, "/dcr", true)

      {"GET", "/.well-known/openid-configuration/dcr"} ->
        authorization_metadata(conn, "/dcr", true)

      {"GET", "/.well-known/oauth-authorization-server/static"} ->
        authorization_metadata(conn, "/static", false)

      {"GET", "/.well-known/openid-configuration/static"} ->
        authorization_metadata(conn, "/static", false)

      {"GET", "/.well-known/oauth-authorization-server/static-basic"} ->
        authorization_metadata_with_methods(conn, "/static-basic", "/static-basic", false, [
          "client_secret_basic"
        ])

      {"GET", "/.well-known/openid-configuration/static-basic"} ->
        authorization_metadata_with_methods(conn, "/static-basic", "/static-basic", false, [
          "client_secret_basic"
        ])

      {"GET", "/.well-known/oauth-authorization-server/dcr-fail"} ->
        authorization_metadata_with_methods(conn, "/dcr-fail", "/dcr-fail", true, [
          "none",
          "client_secret_post"
        ])

      {"GET", "/.well-known/openid-configuration/dcr-fail"} ->
        authorization_metadata_with_methods(conn, "/dcr-fail", "/dcr-fail", true, [
          "none",
          "client_secret_post"
        ])

      {"GET", "/.well-known/oauth-authorization-server/issuer-mismatch"} ->
        authorization_metadata_with_issuer(
          conn,
          "/issuer-mismatch",
          "/issuer-mismatch-other",
          true
        )

      {"GET", "/.well-known/openid-configuration/issuer-mismatch"} ->
        authorization_metadata_with_issuer(
          conn,
          "/issuer-mismatch",
          "/issuer-mismatch-other",
          true
        )

      {"POST", "/dcr/register"} ->
        register_client(conn)

      {"POST", "/dcr-fail/register"} ->
        register_client_failure(conn)

      {"POST", "/issuer-mismatch/register"} ->
        register_client(conn)

      {"GET", "/dcr/authorize"} ->
        authorize(conn, "dcr-code")

      {"GET", "/issuer-mismatch/authorize"} ->
        authorize(conn, "dcr-code")

      {"GET", "/static/authorize"} ->
        authorize(conn, "static-code")

      {"GET", "/static-basic/authorize"} ->
        authorize(conn, "static-code")

      {"GET", "/dcr-fail/authorize"} ->
        authorize(conn, "static-code")

      {"POST", "/dcr/token"} ->
        token(conn, "dcr")

      {"POST", "/issuer-mismatch/token"} ->
        token(conn, "dcr")

      {"POST", "/static/token"} ->
        token(conn, "static", :post)

      {"POST", "/static-basic/token"} ->
        token(conn, "static", :basic)

      {"POST", "/dcr-fail/token"} ->
        token(conn, "static", :post)

      {"POST", "/dcr/revoke"} ->
        revoke(conn)

      {"POST", "/static/revoke"} ->
        revoke(conn)

      {"POST", "/static-basic/revoke"} ->
        revoke(conn)

      {"POST", "/dcr-fail/revoke"} ->
        revoke(conn)

      {"POST", "/mcp"} ->
        mcp(conn, "dcr")

      {"POST", "/static/mcp"} ->
        mcp(conn, "static")

      {"POST", "/static-basic/mcp"} ->
        mcp(conn, "static", "/static-basic/mcp")

      {"POST", "/dcr-fail/mcp"} ->
        mcp(conn, "static", "/dcr-fail/mcp")

      {"POST", "/mismatch/mcp"} ->
        mcp(conn, "dcr")

      {"POST", "/issuer-mismatch/mcp"} ->
        mcp_with_metadata(
          conn,
          "dcr",
          "/.well-known/oauth-protected-resource/issuer-mismatch/mcp"
        )

      {"POST", "/no-resource/mcp"} ->
        mcp_with_metadata(conn, "dcr", "/.well-known/oauth-protected-resource/no-resource/mcp")

      {"POST", "/challenge/mcp"} ->
        mcp_with_metadata(conn, "dcr", "/challenge/metadata")

      {"POST", "/second/mcp"} ->
        mcp(conn, "dcr")

      _ ->
        send_resp(conn, 404, "not found")
    end
  end

  defp protected_resource(conn, resource_path, issuer_path) do
    base = MCPRemoteOAuthE2E.MockState.get(:base_url)

    json(conn, %{
      "resource" => base <> resource_path,
      "authorization_servers" => [base <> issuer_path],
      "scopes_supported" => ["mcp.read"]
    })
  end

  defp protected_resource_mismatch(conn) do
    base = MCPRemoteOAuthE2E.MockState.get(:base_url)

    json(conn, %{
      "resource" => base <> "/other/mcp",
      "authorization_servers" => [base <> "/dcr"],
      "scopes_supported" => ["mcp.read"]
    })
  end

  defp protected_resource_without_resource(conn, issuer_path) do
    base = MCPRemoteOAuthE2E.MockState.get(:base_url)

    json(conn, %{
      "authorization_servers" => [base <> issuer_path],
      "scopes_supported" => ["mcp.read"]
    })
  end

  defp authorization_metadata(conn, issuer_path, dcr?) do
    authorization_metadata_with_issuer(conn, issuer_path, issuer_path, dcr?)
  end

  defp authorization_metadata_with_issuer(conn, endpoint_path, issuer_path, dcr?) do
    authorization_metadata_with_methods(conn, endpoint_path, issuer_path, dcr?, [
      "none",
      "client_secret_post"
    ])
  end

  defp authorization_metadata_with_methods(conn, endpoint_path, issuer_path, dcr?, methods) do
    base = MCPRemoteOAuthE2E.MockState.get(:base_url)

    metadata = %{
      "issuer" => base <> issuer_path,
      "authorization_endpoint" => base <> endpoint_path <> "/authorize",
      "token_endpoint" => base <> endpoint_path <> "/token",
      "revocation_endpoint" => base <> endpoint_path <> "/revoke",
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "token_endpoint_auth_methods_supported" => methods,
      "scopes_supported" => ["mcp.read"]
    }

    metadata =
      if dcr? do
        Map.put(metadata, "registration_endpoint", base <> endpoint_path <> "/register")
      else
        metadata
      end

    json(conn, metadata)
  end

  defp register_client(conn) do
    {:ok, body, conn} = read_body(conn)
    request = decode_json!(body)
    run_id = MCPRemoteOAuthE2E.MockState.get(:run_id)

    unless is_list(request["redirect_uris"]) and request["redirect_uris"] != [] do
      send_resp(conn, 400, "redirect_uris required")
    else
      client_id = "dcr-client-#{run_id}"
      MCPRemoteOAuthE2E.MockState.update(:registered_clients, &[client_id | &1])

      json(conn, %{
        "client_id" => client_id,
        "token_endpoint_auth_method" => "none",
        "registration_access_token" => "dcr-registration-secret-#{run_id}",
        "redirect_uris" => request["redirect_uris"]
      })
    end
  end

  defp register_client_failure(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{"error" => "registration_failed"}))
  end

  defp authorize(conn, code) do
    MCPRemoteOAuthE2E.MockState.record_authorization_request(conn.query_params)

    redirect_uri = conn.query_params["redirect_uri"]
    state = conn.query_params["state"]
    code_challenge = conn.query_params["code_challenge"]

    cond do
      blank?(redirect_uri) ->
        send_resp(conn, 400, "redirect_uri required")

      blank?(state) ->
        send_resp(conn, 400, "state required")

      blank?(code_challenge) ->
        send_resp(conn, 400, "pkce required")

      conn.query_params["code_challenge_method"] != "S256" ->
        send_resp(conn, 400, "S256 required")

      true ->
        redirect(conn, redirect_uri, %{"state" => state, "code" => code})
    end
  end

  defp token(conn, source, client_auth \\ :any) do
    {:ok, body, conn} = read_body(conn)
    form = URI.decode_query(body || "")

    case form["grant_type"] do
      "authorization_code" ->
        token_from_code(conn, source, form, client_auth)

      "refresh_token" ->
        refresh_token(conn, source, form, client_auth)

      _ ->
        send_resp(conn, 400, "unsupported grant")
    end
  end

  defp token_from_code(conn, "dcr", form, _client_auth) do
    cond do
      form["code"] != "dcr-code" -> send_resp(conn, 400, "bad code")
      blank?(form["code_verifier"]) -> send_resp(conn, 400, "code_verifier required")
      true -> token_json(conn, "mcp-access-token-dcr", "mcp-refresh-token-dcr")
    end
  end

  defp token_from_code(conn, "static", form, client_auth) do
    cond do
      form["code"] != "static-code" ->
        send_resp(conn, 400, "bad code")

      blank?(form["code_verifier"]) ->
        send_resp(conn, 400, "code_verifier required")

      not static_client_authenticated?(conn, form, client_auth) ->
        send_resp(conn, 400, "bad client auth")

      true ->
        token_json(conn, "mcp-access-token-static", "mcp-refresh-token-static")
    end
  end

  defp static_client_authenticated?(conn, form, :any),
    do: static_client_post_authenticated?(form) or static_client_basic_authenticated?(conn)

  defp static_client_authenticated?(_conn, form, :post),
    do: static_client_post_authenticated?(form)

  defp static_client_authenticated?(conn, _form, :basic),
    do: static_client_basic_authenticated?(conn)

  defp static_client_post_authenticated?(form) do
    form["client_id"] == "static-client" and form["client_secret"] == "static-secret"
  end

  defp static_client_basic_authenticated?(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> to_string()
    |> String.replace_prefix("Basic ", "")
    |> Base.decode64()
    |> case do
      {:ok, "static-client:static-secret"} -> true
      _ -> false
    end
  end

  defp refresh_token(conn, "static", form, client_auth) do
    cond do
      not static_client_authenticated?(conn, form, client_auth) ->
        send_resp(conn, 400, "bad client auth")

      MCPRemoteOAuthE2E.MockState.get(:static_refresh_should_fail) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{"error" => "invalid_grant"}))

      true ->
        token_json(conn, "mcp-refreshed-token-static", "mcp-refresh-token-static")
    end
  end

  defp refresh_token(conn, _source, _form, _client_auth) do
    if MCPRemoteOAuthE2E.MockState.get(:refresh_should_fail) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
    else
      count = MCPRemoteOAuthE2E.MockState.update(:refresh_count, &((&1 || 0) + 1))
      token_json(conn, "mcp-refreshed-token-#{count}", "mcp-refresh-token-dcr")
    end
  end

  defp token_json(conn, access_token, refresh_token) do
    json(conn, %{
      "access_token" => access_token,
      "refresh_token" => refresh_token,
      "token_type" => "Bearer",
      "scope" => "mcp.read",
      "expires_in" => 3600
    })
  end

  defp revoke(conn) do
    {:ok, body, conn} = read_body(conn)
    form = URI.decode_query(body || "")

    MCPRemoteOAuthE2E.MockState.record_revocation(%{
      "token" => form["token"],
      "token_type_hint" => form["token_type_hint"]
    })

    json(conn, %{"revoked" => true})
  end

  defp mcp(conn, source, metadata_path \\ nil) do
    auth =
      conn
      |> get_req_header("authorization")
      |> List.first()
      |> to_string()

    metadata_path = metadata_path || if(source == "static", do: "/static/mcp", else: "/mcp")

    if valid_bearer?(auth, source) do
      if MCPRemoteOAuthE2E.MockState.get(:reject_valid_bearer_once) do
        MCPRemoteOAuthE2E.MockState.put(:reject_valid_bearer_once, false)
        invalid_token_challenge(conn, metadata_path)
      else
        MCPRemoteOAuthE2E.MockState.record_authorization(auth)
        {:ok, body, conn} = read_body(conn)
        request = decode_json!(body)
        mcp_response(conn, request)
      end
    else
      authorization_required_challenge(conn, metadata_path)
    end
  end

  defp invalid_token_challenge(conn, metadata_path) do
    oauth_challenge(conn, metadata_path, ~s(, error="invalid_token"))
  end

  defp authorization_required_challenge(conn, metadata_path) do
    oauth_challenge(conn, metadata_path, "")
  end

  defp oauth_challenge(conn, metadata_path, extra) do
    base = MCPRemoteOAuthE2E.MockState.get(:base_url)

    conn
    |> put_resp_header(
      "www-authenticate",
      ~s(Bearer resource_metadata="#{base}/.well-known/oauth-protected-resource#{metadata_path}", scope="mcp.read"#{extra})
    )
    |> send_resp(401, "authorization required")
  end

  defp mcp_with_metadata(conn, source, metadata_path) do
    auth =
      conn
      |> get_req_header("authorization")
      |> List.first()
      |> to_string()

    if valid_bearer?(auth, source) do
      MCPRemoteOAuthE2E.MockState.record_authorization(auth)
      {:ok, body, conn} = read_body(conn)
      request = decode_json!(body)
      mcp_response(conn, request)
    else
      base = MCPRemoteOAuthE2E.MockState.get(:base_url)

      conn
      |> put_resp_header(
        "www-authenticate",
        ~s(Bearer resource_metadata="#{base}#{metadata_path}", scope="mcp.read")
      )
      |> send_resp(401, "authorization required")
    end
  end

  defp valid_bearer?("Bearer mcp-access-token-dcr", "dcr"), do: true
  defp valid_bearer?("Bearer mcp-access-token-static", "static"), do: true
  defp valid_bearer?("Bearer mcp-refreshed-token-static", "static"), do: true
  defp valid_bearer?("Bearer mcp-refreshed-token-" <> _, "dcr"), do: true
  defp valid_bearer?(_auth, _source), do: false

  defp mcp_response(conn, %{"id" => id, "method" => "initialize"}) do
    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "Remote OAuth Mock", "version" => "1.0.0"}
      }
    })
  end

  defp mcp_response(conn, %{"id" => id, "method" => "tools/list"}) do
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

  defp mcp_response(conn, %{"id" => id, "method" => "tools/call", "params" => params}) do
    marker = get_in(params, ["arguments", "marker"]) || "missing"

    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "content" => [%{"type" => "text", "text" => "MCP_REMOTE_OAUTH_E2E #{marker}"}]
      }
    })
  end

  defp mcp_response(conn, %{"method" => "notifications/initialized"}) do
    send_resp(conn, 202, "")
  end

  defp mcp_response(conn, %{"method" => _method}) do
    send_resp(conn, 202, "")
  end

  defp mcp_response(conn, %{"id" => id}) do
    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
  end

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  defp redirect(conn, redirect_uri, query) do
    location = redirect_uri <> redirect_joiner(redirect_uri) <> URI.encode_query(query)

    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
  end

  defp redirect_joiner(uri), do: if(URI.parse(uri).query in [nil, ""], do: "?", else: "&")

  defp decode_json!(""), do: %{}
  defp decode_json!(body), do: Jason.decode!(body)
  defp blank?(value), do: !is_binary(value) or String.trim(value) == ""
end

defmodule MCPRemoteOAuthE2E do
  @moduledoc false

  import Plug.Conn
  import Plug.Test

  @opts SalixWeb.Router.init([])
  @admin_token "test-token"
  @session_id SalixStore.Ids.new_session_id()

  def run do
    setup_runtime!()

    run_id = unique()
    {mock_pid, mock_base} = start_mock_provider!(run_id)

    try do
      tenant_key = create_tenant_key!()
      alias_name = "remote-oauth-#{run_id}"

      group_id = create_group!(tenant_key, run_id)
      agent_id = create_agent!(group_id)
      ensure_session!(tenant_key, agent_id, @session_id, run_id)

      binding = create_remote_binding!(tenant_key, group_id, alias_name, mock_base <> "/mcp")
      assert_runtime_requires_authorization!(tenant_key, group_id, binding["binding_id"])

      auth =
        start_authorization_with_agent!(tenant_key, group_id, agent_id, binding["binding_id"])

      complete_authorization!(auth["authorization_url"])

      bound = binding_with_oauth!(tenant_key, group_id, binding["binding_id"])
      oauth_binding_id = bound["remote_oauth_binding_id"]
      assert_remote_oauth_binding!(tenant_key, group_id, oauth_binding_id, true)

      operation_id = discovered_operation_id!(tenant_key, agent_id, alias_name)
      call_mcp_tool!(tenant_key, agent_id, operation_id, "initial")
      assert_last_authorization!("Bearer mcp-access-token-dcr")

      force_oauth_expired!(tenant_key, group_id, oauth_binding_id)
      call_mcp_tool!(tenant_key, agent_id, operation_id, "refresh")
      assert_refreshed!()

      set_oauth_enabled!(tenant_key, group_id, oauth_binding_id, false)
      assert_remote_oauth_binding!(tenant_key, group_id, oauth_binding_id, false)
      assert_disabled_call!(tenant_key, agent_id, operation_id)

      set_oauth_enabled!(tenant_key, group_id, oauth_binding_id, true)
      assert_remote_oauth_binding!(tenant_key, group_id, oauth_binding_id, true)
      call_mcp_tool!(tenant_key, agent_id, operation_id, "reenabled")

      MCPRemoteOAuthE2E.MockState.put(:refresh_should_fail, true)
      force_oauth_expired!(tenant_key, group_id, oauth_binding_id)

      assert_reauthorization_required!(
        tenant_key,
        agent_id,
        operation_id,
        group_id,
        oauth_binding_id
      )

      MCPRemoteOAuthE2E.MockState.put(:refresh_should_fail, false)

      oauth_binding_id =
        reauthorize_and_call!(tenant_key, group_id, agent_id, binding, operation_id)

      assert_revoked!("mcp-refreshed-token-1", "access_token")
      assert_revoked!("mcp-refresh-token-dcr", "refresh_token")

      assert_invalid_token_marks_reauthorization_required!(
        tenant_key,
        group_id,
        agent_id,
        operation_id,
        oauth_binding_id
      )

      assert_static_client_path!(tenant_key, group_id, agent_id, run_id, mock_base)
      assert_static_basic_client_path!(tenant_key, group_id, agent_id, run_id, mock_base)
      assert_dcr_fallback_static_client_path!(tenant_key, group_id, agent_id, run_id, mock_base)
      assert_challenge_metadata_url_path!(tenant_key, group_id, agent_id, run_id, mock_base)
      assert_no_resource_authorization_omits_resource!(tenant_key, group_id, run_id, mock_base)
      assert_resource_mismatch_rejected!(tenant_key, group_id, run_id, mock_base)
      assert_issuer_mismatch_rejected!(tenant_key, group_id, run_id, mock_base)
      assert_redirect_after_guard!(tenant_key, group_id, binding["binding_id"])
      assert_stale_callback_after_binding_target_change!(tenant_key, group_id, run_id, mock_base)
      assert_definition_change_clears_remote_oauth!(tenant_key, group_id, run_id, mock_base)
      assert_dcr_registration_reuse!(tenant_key, group_id, run_id, binding)
      assert_no_secret_leaks!(tenant_key, group_id, agent_id, binding["binding_id"], run_id)

      IO.puts("MCP_REMOTE_OAUTH_E2E: PASS run_id=#{run_id}")
    after
      if is_pid(mock_pid), do: Process.exit(mock_pid, :shutdown)
    end
  end

  defp setup_runtime! do
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_web, :api_token, @admin_token)
    Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    Application.put_env(:salix_mcp, :allow_private_http_targets, true)

    {:ok, _} = Application.ensure_all_started(:salix_web)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      {:ok, _} = SalixStore.S3.Fake.start_link([])
    end

    Salix.App.configure()

    assert!(
      Application.get_env(:salix_mcp, :credential_resolver_mod) == Salix.Bindings.MCPCredentials,
      "MCP credential resolver was not configured"
    )
  end

  defp start_mock_provider!(run_id) do
    {:ok, _} = ensure_mock_state_started()

    {:ok, pid} =
      Bandit.start_link(
        plug: MCPRemoteOAuthE2E.MockProvider,
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    Process.unlink(pid)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    base = "http://127.0.0.1:#{port}"
    MCPRemoteOAuthE2E.MockState.reset(base, run_id)
    {pid, base}
  end

  defp ensure_mock_state_started do
    case Process.whereis(MCPRemoteOAuthE2E.MockState) do
      nil -> MCPRemoteOAuthE2E.MockState.start_link([])
      _pid -> {:ok, MCPRemoteOAuthE2E.MockState}
    end
  end

  defp create_tenant_key! do
    tenant = req!(:post, "/v1/admin/tenants", %{"name" => "MCP Remote OAuth E2E"})
    key = req!(:post, "/v1/admin/tenants/#{tenant["tenant_id"]}/api-keys", %{"name" => "e2e"})
    Process.put(:tenant_id, tenant["tenant_id"])
    key["key"]
  end

  defp create_group!(tenant_key, run_id) do
    tenant_key
    |> treq!(:post, "/v1/runtime/agent-groups", %{
      "name" => "MCP Remote OAuth #{run_id}"
    })
    |> Map.fetch!("group_id")
  end

  defp create_agent!(group_id) do
    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "group_id" => group_id,
          "role" => "worker",
          "name" => "MCP Remote OAuth"
        },
        tenant_id()
      )

    agent["agent_id"]
  end

  defp ensure_session!(tenant_key, agent_id, session_id, run_id) do
    attrs = %{"name" => "MCP remote OAuth E2E #{run_id}", "hidden" => true}

    case SalixAgent.InternalSessionStore.prepare_create(agent_id, session_id, attrs) do
      {:ok, _} -> :ok
      {:error, :exists} -> :ok
      other -> raise("session prepare_create failed: #{inspect(other)}")
    end

    wait_for_session!(tenant_key, agent_id, session_id)
  end

  defp create_remote_binding!(tenant_key, group_id, alias_name, url) do
    definition =
      treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
        "name" => "Remote OAuth #{alias_name}",
        "url" => url,
        "transport" => "streamable-http",
        "headers_schema" => %{
          "Authorization" => %{
            "isRequired" => true,
            "isSecret" => true,
            "value" => "Bearer ${MCP_ACCESS_TOKEN}"
          }
        },
        "supports_server" => true
      })

    treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
      "mcp_id" => definition["mcp_id"],
      "alias" => alias_name,
      "target_ref" => first_target_ref!(definition),
      "placement" => "server"
    })
  end

  defp create_multi_remote_definition!(tenant_key, alias_name, mock_base) do
    treq!(tenant_key, :post, "/v1/runtime/mcp/definitions", %{
      "name" => "Remote OAuth #{alias_name}",
      "server_metadata" => %{
        "name" => "Remote OAuth #{alias_name}",
        "remotes" => [
          %{
            "target_ref" => "remote:primary",
            "transport" => "streamable-http",
            "url" => mock_base <> "/mcp"
          },
          %{
            "target_ref" => "remote:secondary",
            "transport" => "streamable-http",
            "url" => mock_base <> "/second/mcp"
          }
        ]
      },
      "supports_server" => true
    })
  end

  defp assert_runtime_requires_authorization!(tenant_key, group_id, binding_id) do
    conn =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding_id}/discover",
        %{}
      )

    assert!(conn["status"] == "missing_config", "expected missing_config: #{inspect(conn)}")

    assert!(
      get_in(conn, ["last_error", "missing"]) == ["MCP_ACCESS_TOKEN"],
      "runtime did not enforce the authorization placeholder"
    )
  end

  defp start_authorization_with_agent!(tenant_key, group_id, agent_id, binding_id) do
    args = %{"binding_id" => binding_id}

    result =
      session_tool_completed_result!(
        tenant_key,
        agent_id,
        "mcp_manager.authorize",
        args
      )

    assert!(result.error == false, "agent authorize failed: #{inspect(result)}")
    assert_no_mcp_management_requests!(tenant_key, group_id)

    auth = result.body["authorization"]
    assert!(is_binary(auth["authorization_url"]), "authorization_url missing: #{inspect(result)}")
    auth
  end

  defp start_authorization_with_api!(tenant_key, group_id, binding_id, params \\ %{}) do
    treq!(
      tenant_key,
      :post,
      "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding_id}/oauth/authorize",
      params
    )
  end

  defp complete_authorization!(authorization_url) do
    status = complete_authorization_status!(authorization_url)
    assert!(status in [200, 303], "callback failed: #{status}")
  end

  defp complete_authorization_status!(authorization_url) do
    provider = Req.get!(authorization_url, redirect: false, retry: false)
    assert!(provider.status == 302, "mock provider authorize failed: #{inspect(provider)}")

    callback_url = response_header!(provider, "location")
    uri = URI.parse(callback_url)
    path = uri.path <> if(uri.query, do: "?" <> uri.query, else: "")
    conn = public_req!(:get, path, %{})
    conn.status
  end

  defp binding_with_oauth!(tenant_key, group_id, binding_id) do
    binding =
      tenant_key
      |> treq!(:get, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{})
      |> Enum.find(&(&1["binding_id"] == binding_id))

    assert!(is_map(binding), "binding not found after auth")

    assert!(
      is_binary(binding["remote_oauth_binding_id"]),
      "missing remote_oauth_binding_id: #{inspect(binding)}"
    )

    assert!(
      get_in(binding, ["connection", "status"]) in ["running", "degraded"],
      "binding did not run: #{inspect(binding)}"
    )

    binding
  end

  defp discovered_operation_id!(tenant_key, agent_id, alias_name) do
    result = session_tool_result!(tenant_key, agent_id, "mcp.list", %{"kind" => "tools"})
    assert!(result.error == false, "mcp.list failed: #{inspect(result)}")

    operation_id =
      result.body["tools"]
      |> List.wrap()
      |> Enum.map(& &1["operation_id"])
      |> Enum.find(&String.starts_with?(to_string(&1), "mcp.#{alias_name}."))

    assert!(is_binary(operation_id), "operation id not found: #{inspect(result.body)}")
    operation_id
  end

  defp call_mcp_tool!(tenant_key, agent_id, operation_id, marker) do
    result = session_tool_result!(tenant_key, agent_id, operation_id, %{"marker" => marker})
    assert!(result.error == false, "MCP call failed: #{inspect(result)}")

    assert!(
      String.contains?(result.content, marker),
      "MCP call marker missing: #{inspect(result)}"
    )

    assert_no_token_text!(result.content)
    result
  end

  defp assert_disabled_call!(tenant_key, agent_id, operation_id) do
    result = session_tool_result!(tenant_key, agent_id, operation_id, %{"marker" => "disabled"})
    payload = decode_result_content(result)

    assert!(
      payload["status"] == "disabled",
      "disabled call did not return disabled: #{inspect(result)}"
    )

    assert_no_token_text!(result.content)
  end

  defp assert_reauthorization_required!(
         tenant_key,
         agent_id,
         operation_id,
         group_id,
         oauth_binding_id
       ) do
    result = session_tool_result!(tenant_key, agent_id, operation_id, %{"marker" => "reauth"})
    payload = decode_result_content(result)

    assert!(
      payload["status"] == "reauthorization_required",
      "refresh failure did not require reauthorization: #{inspect(result)}"
    )

    binding =
      tenant_key
      |> list_oauth_bindings!(group_id)
      |> Enum.find(&(&1["binding_id"] == oauth_binding_id))

    assert!(
      binding["status"] == "reauthorization_required",
      "OAuth binding status mismatch: #{inspect(binding)}"
    )

    assert_no_token_text!(result.content)
  end

  defp assert_invalid_token_marks_reauthorization_required!(
         tenant_key,
         group_id,
         agent_id,
         operation_id,
         oauth_binding_id
       ) do
    MCPRemoteOAuthE2E.MockState.put(:reject_valid_bearer_once, true)

    result =
      session_tool_result!(tenant_key, agent_id, operation_id, %{"marker" => "invalid-token"})

    payload = decode_result_content(result)

    assert!(
      payload["status"] == "reauthorization_required",
      "invalid_token challenge did not require reauthorization: #{inspect(result)}"
    )

    binding =
      tenant_key
      |> list_oauth_bindings!(group_id)
      |> Enum.find(&(&1["binding_id"] == oauth_binding_id))

    assert!(
      binding["status"] == "reauthorization_required",
      "invalid_token did not mark OAuth binding reauthorization_required: #{inspect(binding)}"
    )

    assert_no_token_text!(result.content)
  end

  defp reauthorize_and_call!(tenant_key, group_id, agent_id, binding, operation_id) do
    auth =
      start_authorization_with_agent!(tenant_key, group_id, agent_id, binding["binding_id"])

    complete_authorization!(auth["authorization_url"])

    rebound = binding_with_oauth!(tenant_key, group_id, binding["binding_id"])
    oauth_binding_id = rebound["remote_oauth_binding_id"]
    assert_remote_oauth_binding!(tenant_key, group_id, oauth_binding_id, true)

    call_mcp_tool!(tenant_key, agent_id, operation_id, "reauthorized")
    oauth_binding_id
  end

  defp assert_static_client_path!(tenant_key, group_id, agent_id, run_id, mock_base) do
    alias_name = "static-oauth-#{run_id}"
    binding = create_remote_binding!(tenant_key, group_id, alias_name, mock_base <> "/static/mcp")

    assert_agent_missing_static_client!(tenant_key, group_id, agent_id, binding["binding_id"])

    start =
      treq_conn(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/oauth/authorize",
        %{}
      )

    assert!(
      start.status == 412,
      "missing static client should return 412: #{start.status} #{start.resp_body}"
    )

    listed = treq!(tenant_key, :get, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{})
    current = Enum.find(listed, &(&1["binding_id"] == binding["binding_id"]))
    provider_key = get_in(current, ["connection", "last_error", "oauth", "provider_key"])

    assert!(
      is_binary(provider_key) and provider_key != "",
      "missing provider_key: #{inspect(current)}"
    )

    treq!(tenant_key, :put, "/v1/runtime/oauth/remote-mcp/provider-apps/#{provider_key}", %{
      "client_id" => "static-client",
      "client_secret" => "static-secret"
    })

    auth =
      treq!(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/oauth/authorize",
        %{}
      )

    complete_authorization!(auth["authorization_url"])

    bound = binding_with_oauth!(tenant_key, group_id, binding["binding_id"])
    oauth_binding_id = bound["remote_oauth_binding_id"]
    operation_id = discovered_operation_id!(tenant_key, agent_id, alias_name)
    call_mcp_tool!(tenant_key, agent_id, operation_id, "static")
    assert_last_authorization!("Bearer mcp-access-token-static")

    force_oauth_expired!(tenant_key, group_id, oauth_binding_id)
    call_mcp_tool!(tenant_key, agent_id, operation_id, "static-refresh")
    assert_last_authorization!("Bearer mcp-refreshed-token-static")

    MCPRemoteOAuthE2E.MockState.put(:static_refresh_should_fail, true)
    force_oauth_expired!(tenant_key, group_id, oauth_binding_id)

    assert_reauthorization_required!(
      tenant_key,
      agent_id,
      operation_id,
      group_id,
      oauth_binding_id
    )

    access_revokes_before = revocation_count("mcp-refreshed-token-static", "access_token")
    refresh_revokes_before = revocation_count("mcp-refresh-token-static", "refresh_token")

    MCPRemoteOAuthE2E.MockState.put(:static_refresh_should_fail, false)
    reauthorize_and_call!(tenant_key, group_id, agent_id, binding, operation_id)

    assert_revocation_count_increased!(
      "mcp-refreshed-token-static",
      "access_token",
      access_revokes_before
    )

    assert_revocation_count_increased!(
      "mcp-refresh-token-static",
      "refresh_token",
      refresh_revokes_before
    )
  end

  defp assert_static_basic_client_path!(tenant_key, group_id, agent_id, run_id, mock_base) do
    alias_name = "static-basic-oauth-#{run_id}"

    binding =
      create_remote_binding!(tenant_key, group_id, alias_name, mock_base <> "/static-basic/mcp")

    provider_key = missing_client_provider_key!(tenant_key, group_id, binding["binding_id"])

    treq!(tenant_key, :put, "/v1/runtime/oauth/remote-mcp/provider-apps/#{provider_key}", %{
      "client_id" => "static-client",
      "client_secret" => "static-secret",
      "token_endpoint_auth_method" => "client_secret_basic"
    })

    auth = start_authorization_with_api!(tenant_key, group_id, binding["binding_id"])
    complete_authorization!(auth["authorization_url"])

    bound = binding_with_oauth!(tenant_key, group_id, binding["binding_id"])
    oauth_binding_id = bound["remote_oauth_binding_id"]
    operation_id = discovered_operation_id!(tenant_key, agent_id, alias_name)
    call_mcp_tool!(tenant_key, agent_id, operation_id, "static-basic")
    assert_last_authorization!("Bearer mcp-access-token-static")

    force_oauth_expired!(tenant_key, group_id, oauth_binding_id)
    call_mcp_tool!(tenant_key, agent_id, operation_id, "static-basic-refresh")
    assert_last_authorization!("Bearer mcp-refreshed-token-static")

    MCPRemoteOAuthE2E.MockState.put(:static_refresh_should_fail, true)
    force_oauth_expired!(tenant_key, group_id, oauth_binding_id)

    assert_reauthorization_required!(
      tenant_key,
      agent_id,
      operation_id,
      group_id,
      oauth_binding_id
    )

    access_revokes_before = revocation_count("mcp-refreshed-token-static", "access_token")
    refresh_revokes_before = revocation_count("mcp-refresh-token-static", "refresh_token")

    MCPRemoteOAuthE2E.MockState.put(:static_refresh_should_fail, false)
    reauthorize_and_call!(tenant_key, group_id, agent_id, binding, operation_id)

    assert_revocation_count_increased!(
      "mcp-refreshed-token-static",
      "access_token",
      access_revokes_before
    )

    assert_revocation_count_increased!(
      "mcp-refresh-token-static",
      "refresh_token",
      refresh_revokes_before
    )
  end

  defp assert_dcr_fallback_static_client_path!(tenant_key, group_id, agent_id, run_id, mock_base) do
    alias_name = "dcr-fallback-oauth-#{run_id}"

    binding =
      create_remote_binding!(tenant_key, group_id, alias_name, mock_base <> "/dcr-fail/mcp")

    provider_key = missing_client_provider_key!(tenant_key, group_id, binding["binding_id"])

    treq!(tenant_key, :put, "/v1/runtime/oauth/remote-mcp/provider-apps/#{provider_key}", %{
      "client_id" => "static-client",
      "client_secret" => "static-secret",
      "token_endpoint_auth_method" => "client_secret_post"
    })

    auth = start_authorization_with_api!(tenant_key, group_id, binding["binding_id"])
    complete_authorization!(auth["authorization_url"])

    operation_id = discovered_operation_id!(tenant_key, agent_id, alias_name)
    call_mcp_tool!(tenant_key, agent_id, operation_id, "dcr-fallback")
    assert_last_authorization!("Bearer mcp-access-token-static")
  end

  defp missing_client_provider_key!(tenant_key, group_id, binding_id) do
    start =
      treq_conn(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding_id}/oauth/authorize",
        %{}
      )

    assert!(
      start.status == 412,
      "missing static client should return 412: #{start.status} #{start.resp_body}"
    )

    current =
      tenant_key
      |> treq!(:get, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{})
      |> Enum.find(&(&1["binding_id"] == binding_id))

    provider_key = get_in(current, ["connection", "last_error", "oauth", "provider_key"])

    assert!(
      is_binary(provider_key) and provider_key != "",
      "missing provider_key: #{inspect(current)}"
    )

    provider_key
  end

  defp assert_challenge_metadata_url_path!(tenant_key, group_id, agent_id, run_id, mock_base) do
    alias_name = "challenge-oauth-#{run_id}"

    binding =
      create_remote_binding!(tenant_key, group_id, alias_name, mock_base <> "/challenge/mcp")

    auth = start_authorization_with_api!(tenant_key, group_id, binding["binding_id"])
    complete_authorization!(auth["authorization_url"])

    operation_id = discovered_operation_id!(tenant_key, agent_id, alias_name)
    call_mcp_tool!(tenant_key, agent_id, operation_id, "challenge")
    assert_last_authorization!("Bearer mcp-access-token-dcr")
  end

  defp assert_no_resource_authorization_omits_resource!(tenant_key, group_id, run_id, mock_base) do
    alias_name = "no-resource-oauth-#{run_id}"

    binding =
      create_remote_binding!(tenant_key, group_id, alias_name, mock_base <> "/no-resource/mcp")

    auth = start_authorization_with_api!(tenant_key, group_id, binding["binding_id"])
    _ = Req.get!(auth["authorization_url"], redirect: false, retry: false)

    request = MCPRemoteOAuthE2E.MockState.get(:last_authorization_request) || %{}

    assert!(
      not Map.has_key?(request, "resource"),
      "authorization request should omit resource when metadata has no resource: #{inspect(request)}"
    )
  end

  defp assert_resource_mismatch_rejected!(tenant_key, group_id, run_id, mock_base) do
    alias_name = "mismatch-oauth-#{run_id}"

    binding =
      create_remote_binding!(tenant_key, group_id, alias_name, mock_base <> "/mismatch/mcp")

    conn =
      treq_conn(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/oauth/authorize",
        %{}
      )

    assert!(conn.status == 400, "resource mismatch should return 400: #{conn.status}")
    assert!(String.contains?(conn.resp_body, "resource"), "resource mismatch error unclear")
  end

  defp assert_issuer_mismatch_rejected!(tenant_key, group_id, run_id, mock_base) do
    alias_name = "issuer-mismatch-oauth-#{run_id}"

    binding =
      create_remote_binding!(
        tenant_key,
        group_id,
        alias_name,
        mock_base <> "/issuer-mismatch/mcp"
      )

    conn =
      treq_conn(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}/oauth/authorize",
        %{}
      )

    assert!(conn.status == 400, "issuer mismatch should return 400: #{conn.status}")
    assert!(String.contains?(conn.resp_body, "issuer"), "issuer mismatch error unclear")
  end

  defp assert_redirect_after_guard!(tenant_key, group_id, binding_id) do
    conn =
      treq_conn(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding_id}/oauth/authorize",
        %{"redirect_after" => "https://evil.example/oauth"}
      )

    assert!(conn.status == 400, "cross-site redirect_after should return 400: #{conn.status}")

    conn =
      treq_conn(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding_id}/oauth/authorize",
        %{"redirect_after" => "/%2f%2fevil.example/oauth"}
      )

    assert!(
      conn.status == 400,
      "encoded protocol-relative redirect_after should return 400: #{conn.status}"
    )

    conn =
      treq_conn(
        tenant_key,
        :post,
        "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding_id}/oauth/authorize",
        %{"redirect_after" => "/%5c%5cevil.example/oauth"}
      )

    assert!(
      conn.status == 400,
      "encoded backslash redirect_after should return 400: #{conn.status}"
    )
  end

  defp assert_stale_callback_after_binding_target_change!(tenant_key, group_id, run_id, mock_base) do
    alias_name = "stale-target-oauth-#{run_id}"
    definition = create_multi_remote_definition!(tenant_key, alias_name, mock_base)

    binding =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{
        "mcp_id" => definition["mcp_id"],
        "alias" => alias_name,
        "target_ref" => "remote:primary",
        "placement" => "server"
      })

    auth = start_authorization_with_api!(tenant_key, group_id, binding["binding_id"])

    treq!(
      tenant_key,
      :patch,
      "/v1/runtime/agent-groups/#{group_id}/mcp/bindings/#{binding["binding_id"]}",
      %{"target_ref" => "remote:secondary"}
    )

    status = complete_authorization_status!(auth["authorization_url"])
    assert!(status == 400, "stale callback after target change should fail: #{status}")

    current =
      tenant_key
      |> treq!(:get, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{})
      |> Enum.find(&(&1["binding_id"] == binding["binding_id"]))

    assert!(
      current["remote_oauth_binding_id"] in [nil, ""],
      "stale callback should not attach OAuth binding: #{inspect(current)}"
    )
  end

  defp assert_definition_change_clears_remote_oauth!(tenant_key, group_id, run_id, mock_base) do
    alias_name = "definition-update-oauth-#{run_id}"
    binding = create_remote_binding!(tenant_key, group_id, alias_name, mock_base <> "/mcp")

    auth = start_authorization_with_api!(tenant_key, group_id, binding["binding_id"])
    complete_authorization!(auth["authorization_url"])
    bound = binding_with_oauth!(tenant_key, group_id, binding["binding_id"])

    assert!(
      is_binary(bound["remote_oauth_binding_id"]),
      "definition update setup did not attach OAuth binding"
    )

    treq!(tenant_key, :patch, "/v1/runtime/mcp/definitions/#{bound["mcp_id"]}", %{
      "url" => mock_base <> "/challenge/mcp",
      "transport" => "streamable-http",
      "supports_server" => true
    })

    current =
      tenant_key
      |> treq!(:get, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{})
      |> Enum.find(&(&1["binding_id"] == binding["binding_id"]))

    assert!(
      current["remote_oauth_binding_id"] in [nil, ""],
      "definition update should clear stale remote OAuth binding: #{inspect(current)}"
    )

    assert!(
      get_in(current, ["connection", "status"]) == "configured",
      "definition update should require rediscovery: #{inspect(current)}"
    )

    assert_remote_oauth_binding_disabled!(tenant_key, group_id, bound["remote_oauth_binding_id"])

    pending_alias_name = "definition-pending-oauth-#{run_id}"

    pending_binding =
      create_remote_binding!(tenant_key, group_id, pending_alias_name, mock_base <> "/mcp")

    pending_auth =
      start_authorization_with_api!(tenant_key, group_id, pending_binding["binding_id"])

    treq!(tenant_key, :patch, "/v1/runtime/mcp/definitions/#{pending_binding["mcp_id"]}", %{
      "url" => mock_base <> "/challenge/mcp",
      "transport" => "streamable-http",
      "supports_server" => true
    })

    status = complete_authorization_status!(pending_auth["authorization_url"])

    assert!(
      status == 400,
      "stale callback after pending definition update should fail: #{status}"
    )

    pending_current =
      tenant_key
      |> treq!(:get, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{})
      |> Enum.find(&(&1["binding_id"] == pending_binding["binding_id"]))

    assert!(
      pending_current["remote_oauth_binding_id"] in [nil, ""],
      "pending definition update callback should not attach OAuth binding: #{inspect(pending_current)}"
    )

    assert!(
      get_in(pending_current, ["connection", "status"]) == "configured",
      "pending definition update should require rediscovery: #{inspect(pending_current)}"
    )
  end

  defp assert_dcr_registration_reuse!(tenant_key, group_id, run_id, source_binding) do
    before_count = length(MCPRemoteOAuthE2E.MockState.get(:registered_clients) || [])
    alias_name = "dcr-reuse-oauth-#{run_id}"
    reuse_group_id = create_group!(tenant_key, "#{run_id} reuse")

    binding =
      treq!(tenant_key, :post, "/v1/runtime/agent-groups/#{reuse_group_id}/mcp/bindings", %{
        "mcp_id" => source_binding["mcp_id"],
        "alias" => alias_name,
        "target_ref" => source_binding["target_ref"],
        "placement" => "server"
      })

    auth = start_authorization_with_api!(tenant_key, reuse_group_id, binding["binding_id"])
    complete_authorization!(auth["authorization_url"])

    after_count = length(MCPRemoteOAuthE2E.MockState.get(:registered_clients) || [])

    assert!(
      after_count == before_count,
      "same-tenant DCR client should be reused, before=#{before_count} after=#{after_count}"
    )
  end

  defp assert_agent_missing_static_client!(tenant_key, group_id, agent_id, binding_id) do
    args = %{"binding_id" => binding_id}

    result =
      session_tool_completed_result!(
        tenant_key,
        agent_id,
        "mcp_manager.authorize",
        args
      )

    assert_no_mcp_management_requests!(tenant_key, group_id)
    auth = result.body["authorization"]

    assert!(
      auth["status"] == "missing_oauth_client",
      "agent authorize should return missing_oauth_client: #{inspect(result)}"
    )
  end

  defp assert_remote_oauth_binding!(tenant_key, group_id, binding_id, expected_enabled) do
    binding =
      tenant_key
      |> list_oauth_bindings!(group_id)
      |> Enum.find(&(&1["binding_id"] == binding_id))

    assert!(is_map(binding), "OAuth binding not found: #{binding_id}")

    assert!(
      binding["provider_kind"] == "remote_mcp",
      "not remote_mcp binding: #{inspect(binding)}"
    )

    assert!(binding["enabled"] == expected_enabled, "enabled mismatch: #{inspect(binding)}")
    assert_no_token_text!(Jason.encode!(binding))
  end

  defp assert_remote_oauth_binding_disabled!(tenant_key, group_id, binding_id) do
    binding =
      tenant_key
      |> list_oauth_bindings!(group_id)
      |> Enum.find(&(&1["binding_id"] == binding_id))

    assert!(is_map(binding), "OAuth binding not found after invalidation: #{binding_id}")

    assert!(
      binding["enabled"] == false and binding["status"] == "disabled",
      "OAuth binding should be disabled after MCP target invalidation: #{inspect(binding)}"
    )

    assert_no_token_text!(Jason.encode!(binding))
  end

  defp set_oauth_enabled!(tenant_key, group_id, binding_id, enabled) do
    resp =
      treq!(
        tenant_key,
        :patch,
        "/v1/runtime/agent-groups/#{group_id}/oauth-connections/#{binding_id}",
        %{"enabled" => enabled}
      )

    assert!(resp["binding_id"] == binding_id, "patch OAuth binding failed: #{inspect(resp)}")
  end

  defp force_oauth_expired!(tenant_key, group_id, binding_id) do
    binding =
      tenant_key
      |> list_oauth_bindings!(group_id)
      |> Enum.find(&(&1["binding_id"] == binding_id))

    assert!(is_map(binding), "OAuth binding not found for expiry: #{binding_id}")
    conn_id = binding["connection_id"]

    assert!(
      is_binary(conn_id) and conn_id != "",
      "OAuth binding has no connection_id: #{inspect(binding)}"
    )

    {:ok, conn} = SalixStore.OAuth.get(conn_id)

    :ok =
      SalixStore.OAuth.put(
        conn_id,
        Map.put(conn, "expires_at", System.system_time(:millisecond) - 1)
      )
  end

  defp assert_no_secret_leaks!(tenant_key, group_id, agent_id, binding_id, run_id) do
    binding = treq!(tenant_key, :get, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{})
    oauth = list_oauth_bindings!(tenant_key, group_id)
    tools = session_tool_result!(tenant_key, agent_id, "mcp.list", %{})

    combined = Jason.encode!(%{"binding" => binding, "oauth" => oauth, "tools" => tools.body})

    assert_no_token_text!(combined)
    assert!(not String.contains?(combined, "static-secret"), "static client secret leaked")

    assert!(
      not String.contains?(combined, "dcr-registration-secret-#{run_id}"),
      "DCR registration secret leaked"
    )

    conn =
      tenant_key
      |> treq!(:get, "/v1/runtime/agent-groups/#{group_id}/mcp/bindings", %{})
      |> Enum.find(&(&1["binding_id"] == binding_id))

    assert_no_token_text!(Jason.encode!(conn))
  end

  defp assert_refreshed! do
    count = MCPRemoteOAuthE2E.MockState.get(:refresh_count)
    assert!(count >= 1, "refresh was not called")
  end

  defp assert_last_authorization!(expected) do
    actual = MCPRemoteOAuthE2E.MockState.get(:last_authorization)

    assert!(
      actual == expected,
      "authorization header mismatch: expected #{expected}, got #{inspect(actual)}"
    )
  end

  defp assert_revoked!(expected_token, expected_hint) do
    assert!(
      revocation_count(expected_token, expected_hint) > 0,
      "expected token revocation not recorded: #{inspect(%{token: expected_token, hint: expected_hint, revocations: MCPRemoteOAuthE2E.MockState.get(:revocations) || []})}"
    )
  end

  defp assert_revocation_count_increased!(expected_token, expected_hint, previous_count) do
    count = revocation_count(expected_token, expected_hint)

    assert!(
      count > previous_count,
      "expected token revocation count to increase: #{inspect(%{token: expected_token, hint: expected_hint, previous_count: previous_count, count: count, revocations: MCPRemoteOAuthE2E.MockState.get(:revocations) || []})}"
    )
  end

  defp revocation_count(expected_token, expected_hint) do
    revocations = MCPRemoteOAuthE2E.MockState.get(:revocations) || []

    Enum.count(revocations, fn revocation ->
      revocation["token"] == expected_token and revocation["token_type_hint"] == expected_hint
    end)
  end

  defp list_oauth_bindings!(tenant_key, group_id),
    do: treq!(tenant_key, :get, "/v1/runtime/agent-groups/#{group_id}/oauth-connections", %{})

  defp assert_no_mcp_management_requests!(tenant_key, group_id) do
    requests =
      treq!(tenant_key, :get, "/v1/runtime/agent-groups/#{group_id}/capability-requests", %{})
      |> Map.get("data", [])

    assert!(
      Enum.all?(requests, &(&1["request_type"] != "mcp_management")),
      "MCP setup created an unexpected capability request: #{inspect(requests)}"
    )
  end

  defp session_tool_completed_result!(tenant_key, agent_id, tool_name, attrs) do
    result = session_tool_result!(tenant_key, agent_id, tool_name, attrs)

    case result.body do
      %{"status" => "running", "tool_call_id" => tool_call_id}
      when is_binary(tool_call_id) and tool_call_id != "" ->
        completed = wait_for_tool_result!(tenant_key, agent_id, tool_call_id)
        %{completed | body: async_tool_payload(completed)}

      _ ->
        assert!(result.error == false, "#{tool_name} failed: #{inspect(result)}")
        result
    end
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

  defp wait_for_tool_result!(tenant_key, agent_id, tool_call_id, attempts \\ 50)

  defp wait_for_tool_result!(_tenant_key, _agent_id, tool_call_id, 0),
    do: raise("timed out waiting for tool result #{tool_call_id}")

  defp wait_for_tool_result!(tenant_key, agent_id, tool_call_id, attempts) do
    result =
      session_tool_result!(tenant_key, agent_id, "tool_call.get_result", %{
        "tool_call_id" => tool_call_id
      })

    record = async_result_record(result)

    case record["status"] do
      "running" ->
        Process.sleep(100)
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

      _ ->
        %{}
    end
  end

  defp async_tool_payload(%{body: body}) when is_map(body), do: body
  defp async_tool_payload(_result), do: %{}

  defp decode_result_content(result) do
    cond do
      is_map(result.body) and Map.has_key?(result.body, "status") ->
        result.body

      is_map(result.body["result"]) ->
        result.body["result"]

      is_binary(result.body["result"]) ->
        decode_json_or_empty(result.body["result"])

      is_binary(result.content) ->
        decode_json_or_empty(result.content)

      true ->
        %{}
    end
  end

  defp decode_json_or_empty(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  defp wait_for_session!(tenant_key, agent_id, session_id, attempts \\ 50)

  defp wait_for_session!(tenant_key, agent_id, session_id, attempts) when attempts > 0 do
    conn =
      treq_conn(tenant_key, :get, "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}", %{})

    if conn.status in 200..299 do
      :ok
    else
      Process.sleep(100)
      wait_for_session!(tenant_key, agent_id, session_id, attempts - 1)
    end
  end

  defp wait_for_session!(_tenant_key, agent_id, session_id, _attempts),
    do: raise("session #{session_id} was not created for #{agent_id}")

  defp req!(method, path, body) do
    conn =
      conn(method, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{@admin_token}")
      |> SalixWeb.Router.call(@opts)

    decode_ok!(conn)
  end

  defp public_req!(method, path, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> SalixWeb.Router.call(@opts)
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
    body =
      case Jason.decode(conn.resp_body || "{}") do
        {:ok, decoded} -> decoded
        {:error, _} -> conn.resp_body
      end

    assert!(conn.status in 200..299, "#{conn.status}: #{inspect(body)}")
    body
  end

  defp first_target_ref!(definition) do
    metadata = definition["server_metadata"] || %{}

    (List.wrap(metadata["remotes"]) ++ List.wrap(metadata["packages"]))
    |> Enum.map(& &1["target_ref"])
    |> Enum.find(&is_binary/1)
    |> case do
      nil -> raise("definition has no target_ref: #{inspect(definition)}")
      target -> target
    end
  end

  defp response_header!(resp, name) do
    case resp.headers[String.downcase(name)] do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> raise("response header #{name} missing in #{inspect(resp.headers)}")
    end
  end

  defp assert_no_token_text!(text) do
    text = to_string(text)

    for secret <- [
          "mcp-access-token-dcr",
          "mcp-refresh-token-dcr",
          "mcp-access-token-static",
          "mcp-refresh-token-static",
          "mcp-refreshed-token"
        ] do
      assert!(not String.contains?(text, secret), "secret leaked: #{secret} in #{text}")
    end
  end

  defp tenant_id, do: Process.get(:tenant_id) || raise("tenant_id missing")
  defp unique, do: System.unique_integer([:positive]) |> Integer.to_string()

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise(message)
  defp assert!(nil, message), do: raise(message)
  defp assert!(_truthy, _message), do: :ok
end

try do
  MCPRemoteOAuthE2E.run()
catch
  kind, reason ->
    IO.puts(:stderr, Exception.format(kind, reason, __STACKTRACE__))
    System.halt(1)
end
