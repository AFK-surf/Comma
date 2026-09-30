defmodule CommaWeb.TelegramOIDC.TransportTest do
  use ExUnit.Case, async: false

  alias CommaWeb.TelegramOIDC
  alias CommaWeb.TelegramOIDC.Oidcc, as: TelegramAdapter

  @provider CommaWeb.TelegramOIDC.Oidcc.Provider
  @client_id "telegram-client"
  @client_secret "telegram-client-secret"
  @nonce "telegram-login-nonce"
  @verifier "telegram-pkce-verifier-012345678901234567890123"
  @redirect_uri "https://comma.test/v1/comma/integrations/telegram/connect/callback"
  @reporter Module.concat(__MODULE__, Reporter)

  defmodule Provider do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, state) do
      snapshot = Agent.get(state, & &1)

      body =
        case {conn.method, conn.request_path} do
          {"GET", "/.well-known/openid-configuration"} ->
            %{
              "issuer" => snapshot.issuer,
              "authorization_endpoint" => snapshot.issuer <> "/auth",
              "token_endpoint" => snapshot.issuer <> "/token",
              "jwks_uri" => snapshot.issuer <> "/jwks",
              "scopes_supported" => ["openid", "profile", "telegram:bot_access"],
              "response_types_supported" => ["code"],
              "grant_types_supported" => ["authorization_code"],
              "subject_types_supported" => ["public"],
              "code_challenge_methods_supported" => ["S256"],
              "token_endpoint_auth_methods_supported" => ["client_secret_basic"],
              "id_token_signing_alg_values_supported" => ["RS256"]
            }

          {"GET", "/jwks"} ->
            %{"keys" => [snapshot.public_key]}

          {"POST", "/token"} ->
            {:ok, request_body, conn} = read_body(conn)

            send(snapshot.test_pid, {
              :token_request,
              get_req_header(conn, "authorization"),
              URI.decode_query(request_body)
            })

            %{
              "access_token" => "telegram-access-token",
              "token_type" => "Bearer",
              "expires_in" => 300,
              "id_token" => snapshot.id_token
            }
        end

      encoding = Map.get(snapshot.modes, conn.request_path, :gzip)
      json = Jason.encode!(body)

      {wire_body, gzip?} =
        case encoding do
          :plain -> {json, false}
          :gzip -> {:zlib.gzip(json), true}
          :invalid_json -> {:zlib.gzip("{broken-json"), true}
          :corrupt_gzip -> {<<31, 139, 8, 0, 0>>, true}
        end

      conn =
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header(
          "cache-control",
          Map.get(snapshot.cache_control, conn.request_path, "max-age=3600")
        )

      conn = if gzip?, do: put_resp_header(conn, "content-encoding", "gzip"), else: conn
      conn = send_resp(conn, 200, wire_body)
      send(snapshot.test_pid, {:provider_response, conn.request_path, encoding, wire_body})
      conn
    end
  end

  setup_all do
    for app <- [:req, :bandit, :oidcc] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    private_key = JOSE.JWK.generate_key({:rsa, 2_048})
    {_, public_key} = private_key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

    {:ok,
     private_key: private_key,
     public_key: Map.merge(public_key, %{"alg" => "RS256", "kid" => "telegram-key"})}
  end

  setup context do
    previous = Application.get_env(:comma_web, :telegram)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:comma_web, :telegram),
        else: Application.put_env(:comma_web, :telegram, previous)
    end)

    test_pid = self()

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             test_pid: test_pid,
             issuer: nil,
             public_key: context.public_key,
             id_token: nil,
             modes: %{},
             cache_control: %{}
           }
         end}
      )

    server =
      start_supervised!(
        {Bandit, plug: {Provider, state}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    issuer = "http://127.0.0.1:#{port}"
    claims = claims(issuer)
    id_token = sign(context.private_key, claims)
    Agent.update(state, &%{&1 | issuer: issuer, id_token: id_token})

    Application.put_env(:comma_web, :telegram,
      oidc_enabled: true,
      client_id: @client_id,
      client_secret: @client_secret,
      public_base_url: "https://comma.test",
      issuer: issuer
    )

    {:ok, state: state, issuer: issuer, claims: claims, server: server}
  end

  for encoding <- [:plain, :gzip] do
    test "exchanges and verifies signed tokens over #{encoding} discovery, JWKS and token HTTP",
         context do
      encoding = unquote(encoding)
      paths = ["/.well-known/openid-configuration", "/jwks", "/token"]
      Agent.update(context.state, &%{&1 | modes: Map.new(paths, fn path -> {path, encoding} end)})
      start_provider!()
      await_ready!()

      assert {:ok, verified} = exchange()
      assert verified["id"] == 42001
      assert verified["sub"] == "telegram-opaque-subject"

      for path <- paths do
        assert_receive {:provider_response, ^path, ^encoding, body}

        assert_wire_body(encoding, body)
      end

      assert_receive {:token_request, [authorization], params}
      assert authorization == "Basic " <> Base.encode64(@client_id <> ":" <> @client_secret)
      assert params["grant_type"] == "authorization_code"
      assert params["code"] == "telegram-authorization-code"
      assert params["code_verifier"] == @verifier
      assert params["redirect_uri"] == @redirect_uri
    end
  end

  for invalid <- [:nonce, :audience, :signature] do
    test "rejects invalid #{invalid} after successful gzip HTTP", context do
      {key, claims} =
        case unquote(invalid) do
          :nonce -> {context.private_key, Map.put(context.claims, "nonce", "wrong-nonce")}
          :audience -> {context.private_key, Map.put(context.claims, "aud", "another-client")}
          :signature -> {JOSE.JWK.generate_key({:rsa, 2_048}), context.claims}
        end

      Agent.update(context.state, &%{&1 | id_token: sign(key, claims)})
      start_provider!()
      await_ready!()
      assert {:error, :invalid_telegram_credential} = exchange()
      assert_receive {:provider_response, "/token", :gzip, <<31, 139, 8, _::binary>>}
    end
  end

  for path <- ["/.well-known/openid-configuration", "/jwks"],
      failure <- [:invalid_json, :corrupt_gzip] do
    @tag capture_log: true
    test "#{failure} at #{path} retries without crashing its owner and recovers", context do
      path = unquote(path)
      failure = unquote(failure)
      Agent.update(context.state, &%{&1 | modes: %{path => failure}})
      owner = start_provider!()

      assert_receive {:provider_response, ^path, ^failure, _}, 2_000
      assert_receive {:provider_response, ^path, ^failure, _}, 2_000
      assert Process.alive?(owner)
      assert Process.alive?(context.server)
      assert {:error, :telegram_provider_unavailable} = exchange()

      Agent.update(context.state, &%{&1 | modes: %{}})
      await_ready!()
      assert Process.alive?(owner)
      assert {:ok, %{"id" => 42001}} = exchange()
    end
  end

  for failure <- [:invalid_json, :corrupt_gzip] do
    @tag capture_log: true
    test "#{failure} in token HTTP returns provider unavailable and a later exchange succeeds",
         context do
      Agent.update(context.state, &%{&1 | modes: %{"/token" => unquote(failure)}})
      owner = start_provider!()
      await_ready!()
      assert {:error, :telegram_provider_unavailable} = exchange()
      assert Process.alive?(owner)

      Agent.update(context.state, &%{&1 | modes: %{}})
      assert {:ok, %{"id" => 42001}} = exchange()
    end
  end

  @tag capture_log: true
  test "a failed refresh after JWKS expiry restarts and recovers", context do
    Agent.update(context.state, &%{&1 | cache_control: %{"/jwks" => "max-age=1"}})
    owner = start_provider!(%{fallback_expiry: 1_000})
    await_ready!()
    worker = Process.whereis(@provider)
    ref = Process.monitor(worker)
    Agent.update(context.state, &%{&1 | modes: %{"/jwks" => :invalid_json}})

    assert_receive {:provider_response, "/jwks", :invalid_json, _}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    Agent.update(context.state, &%{&1 | modes: %{}})
    await_ready!()
    assert Process.whereis(@provider) != worker
    assert Process.alive?(owner)
    assert Process.alive?(context.server)
    assert {:ok, %{"id" => 42001}} = exchange()
  end

  @tag capture_log: true
  test "repeated worker crashes preserve the owner and HTTP sibling and recover", context do
    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: @reporter, metrics: CommaProduct.Telemetry.metrics(), start_async: false}
    )

    owner = start_provider!()
    await_ready!()

    for _ <- 1..4 do
      worker = Process.whereis(@provider)
      ref = Process.monitor(worker)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
      await_ready!()
      assert Process.whereis(@provider) != worker
      assert Process.alive?(owner)
      assert Process.alive?(context.server)
      assert {:ok, %{"id" => 42001}} = exchange()
    end

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~
             ~s(comma_product_operations_total{operation="telegram_oidc_restart",outcome="unavailable",provider="telegram"} 4)
  end

  test "stopping the owner also stops its linked SDK worker" do
    start_provider!()
    await_ready!()
    worker = Process.whereis(@provider)
    ref = Process.monitor(worker)
    stop_supervised!(CommaWeb.TelegramOIDC.ProviderOwner)
    assert_receive {:DOWN, ^ref, :process, ^worker, :shutdown}
    assert Process.whereis(@provider) == nil
  end

  defp start_provider!(configuration_opts \\ %{}) do
    [child] = TelegramOIDC.child_specs()
    spec = Supervisor.child_spec(child, [])
    {module, function, [opts]} = spec.start
    opts = Map.merge(opts, %{restart_delay_ms: 10, restart_jitter_ms: 0})
    opts = Map.update!(opts, :provider_configuration_opts, &Map.merge(&1, configuration_opts))
    start_supervised!(%{spec | start: {module, function, [opts]}})
  end

  defp assert_wire_body(:gzip, body) do
    assert <<31, 139, 8, _::binary>> = body
    assert is_map(body |> :zlib.gunzip() |> Jason.decode!())
  end

  defp assert_wire_body(:plain, body), do: assert(is_map(Jason.decode!(body)))

  defp await_ready!(attempts \\ 200)

  defp await_ready!(0), do: flunk("Telegram provider did not load discovery and JWKS")

  defp await_ready!(attempts) do
    jwks =
      try do
        :oidcc_provider_configuration_worker.get_jwks(@provider)
      rescue
        # The SDK's named ETS cache disappears during a provider restart.
        ArgumentError -> :undefined
      catch
        :exit, _ -> :undefined
      end

    case jwks do
      :undefined ->
        Process.sleep(10)
        await_ready!(attempts - 1)

      jwks ->
        assert %JOSE.JWK{} = JOSE.JWK.from_record(jwks)
    end
  end

  defp exchange do
    TelegramAdapter.exchange_authorization_code("telegram-authorization-code",
      client_id: @client_id,
      client_secret: @client_secret,
      nonce: @nonce,
      pkce_verifier: @verifier,
      redirect_uri: @redirect_uri
    )
  end

  defp claims(issuer) do
    now = System.system_time(:second)

    %{
      "iss" => issuer,
      "sub" => "telegram-opaque-subject",
      "id" => 42001,
      "aud" => @client_id,
      "exp" => now + 300,
      "iat" => now,
      "nonce" => @nonce
    }
  end

  defp sign(key, claims) do
    {_, token} =
      key
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "telegram-key"}, claims)
      |> JOSE.JWS.compact()

    token
  end
end
