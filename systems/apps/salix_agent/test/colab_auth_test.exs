defmodule SalixAgent.Colab.AuthTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.Colab.Auth

  @client_id "test-colab-client-id"
  @colab_scope "https://www.googleapis.com/auth/colaboratory"

  setup do
    previous = SystemsRuntime.get_env(:salix_agent, :colab_oauth)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :colab_oauth, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :colab_oauth)
    end)

    :ok
  end

  defp configure_oauth(plug) do
    SystemsRuntime.put_env(:salix_agent, :colab_oauth,
      client_id: @client_id,
      client_secret: "test-secret",
      redirect_uri: "https://sdk.cloud.google.com/applicationdefaultauthcode.html",
      auth_uri: "https://accounts.google.com/o/oauth2/auth",
      token_uri: "https://oauth2.googleapis.com/token",
      userinfo_uri: "https://www.googleapis.com/oauth2/v2/userinfo",
      req_options: [plug: plug]
    )
  end

  defp build_id_token(claims) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    "#{header}.#{payload}.sig"
  end

  test "begin/1 generates PKCE S256 challenge, 24-byte state, and requests only 4 minimal scopes" do
    configure_oauth(fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

    assert {:ok, %{url: url, state: state, code_verifier: verifier}} =
             Auth.begin(login_hint: "gpu@example.com")

    assert byte_size(Base.url_decode64!(state, padding: false)) == 24
    assert byte_size(Base.url_decode64!(verifier, padding: false)) == 32

    uri = URI.parse(url)
    params = URI.decode_query(uri.query)

    assert params["client_id"] == @client_id
    assert params["response_type"] == "code"
    assert params["state"] == state
    assert params["access_type"] == "offline"
    assert params["prompt"] == "consent"
    assert params["token_usage"] == "remote"
    assert params["login_hint"] == "gpu@example.com"
    assert params["code_challenge_method"] == "S256"

    expected_challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    assert params["code_challenge"] == expected_challenge

    scopes = String.split(params["scope"], " ", trim: true)
    assert Enum.sort(scopes) == Enum.sort(Auth.scopes())
    assert @colab_scope in scopes
    refute Enum.any?(scopes, &String.contains?(&1, "cloud-platform"))
    refute Enum.any?(scopes, &String.contains?(&1, "drive"))
  end

  test "exchange_code/2 verifies colaboratory scope and extracts google_sub & email from id_token" do
    now = SystemsClock.system_time(:second)

    id_token =
      build_id_token(%{
        "iss" => "https://accounts.google.com",
        "aud" => @client_id,
        "exp" => now + 3600,
        "sub" => "sub-12345",
        "email" => "alice@gmail.com",
        "email_verified" => true
      })

    configure_oauth(fn conn ->
      assert conn.request_path == "/token"

      Req.Test.json(conn, %{
        "access_token" => "ya29.access",
        "refresh_token" => "1//refresh",
        "token_type" => "Bearer",
        "expires_in" => 3600,
        "scope" => "openid #{@colab_scope}",
        "id_token" => id_token
      })
    end)

    assert {:ok, creds} = Auth.exchange_code("auth-code", "verifier-123")
    assert creds["access_token"] == "ya29.access"
    assert creds["refresh_token"] == "1//refresh"
    assert creds["google_sub"] == "sub-12345"
    assert creds["email"] == "alice@gmail.com"
    assert is_binary(creds["expires_at"])
  end

  test "exchange_code/2 rejects response missing colaboratory scope" do
    configure_oauth(fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "ya29.access",
        "refresh_token" => "1//refresh",
        "expires_in" => 3600,
        "scope" => "openid https://www.googleapis.com/auth/userinfo.email"
      })
    end)

    assert {:error, :missing_colaboratory_scope} = Auth.exchange_code("auth-code", "verifier-123")
  end

  test "exchange_code/2 falls back to userinfo v2 when id_token is expired or missing, and fails closed without google_sub" do
    now = SystemsClock.system_time(:second)

    expired_id_token =
      build_id_token(%{
        "iss" => "https://accounts.google.com",
        "aud" => @client_id,
        "exp" => now - 10,
        "sub" => "stale-sub",
        "email" => "stale@gmail.com"
      })

    configure_oauth(fn conn ->
      case conn.request_path do
        "/token" ->
          Req.Test.json(conn, %{
            "access_token" => "ya29.access",
            "refresh_token" => "1//refresh",
            "expires_in" => 3600,
            "scope" => "openid #{@colab_scope}",
            "id_token" => expired_id_token
          })

        "/oauth2/v2/userinfo" ->
          Req.Test.json(conn, %{
            "id" => "userinfo-sub-999",
            "email" => "bob@gmail.com",
            "verified_email" => true
          })
      end
    end)

    assert {:ok, creds} = Auth.exchange_code("auth-code", "verifier-123")
    assert creds["google_sub"] == "userinfo-sub-999"
    assert creds["email"] == "bob@gmail.com"

    # When both id_token and userinfo lack google_sub, fail closed with :invalid_identity
    configure_oauth(fn conn ->
      case conn.request_path do
        "/token" ->
          Req.Test.json(conn, %{
            "access_token" => "ya29.access",
            "refresh_token" => "1//refresh",
            "expires_in" => 3600,
            "scope" => @colab_scope
          })

        "/oauth2/v2/userinfo" ->
          Req.Test.json(conn, %{"email" => "nosub@gmail.com"})
      end
    end)

    assert {:error, :invalid_identity} = Auth.exchange_code("auth-code", "verifier-123")
  end

  test "refresh_token/1 classifies invalid_grant, invalid_client, transient errors, and preserves refresh_token" do
    # 200 without new refresh_token preserves previous value
    configure_oauth(fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "ya29.new",
        "expires_in" => 1800,
        "token_type" => "Bearer"
      })
    end)

    assert {:ok, refreshed} = Auth.refresh_token("1//old-refresh")
    assert refreshed["access_token"] == "ya29.new"
    assert refreshed["refresh_token"] == "1//old-refresh"

    # 400 invalid_grant -> :invalid_grant
    configure_oauth(fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    assert {:error, :invalid_grant} = Auth.refresh_token("1//revoked")

    # 401 invalid_client -> :platform_unavailable
    configure_oauth(fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => "invalid_client"})
    end)

    assert {:error, :platform_unavailable} = Auth.refresh_token("1//ok")

    # 429 and 503 -> :token_refresh_failed
    for status <- [429, 503] do
      configure_oauth(fn conn ->
        conn
        |> Plug.Conn.put_status(status)
        |> Req.Test.json(%{"error" => "temporarily_unavailable"})
      end)

      assert {:error, :token_refresh_failed} = Auth.refresh_token("1//ok")
    end

    # Transport error -> :token_refresh_failed
    configure_oauth(fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, :token_refresh_failed} = Auth.refresh_token("1//ok")
  end

  test "parse_authorization_input/2 validates redirect URLs, code#state, query strings, and bare codes" do
    state = "expected-state-token-123"

    # Full redirect URL with matching state
    url =
      "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4%2F0AbcDef&state=#{state}"

    assert {:ok, %{code: "4/0AbcDef", state: ^state}} =
             Auth.parse_authorization_input(url, expected_state: state)

    # Full redirect URL with mismatched or missing state fails closed
    bad_state_url =
      "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4%2F0AbcDef&state=wrong"

    assert {:error, :state_mismatch} =
             Auth.parse_authorization_input(bad_state_url, expected_state: state)

    no_state_url =
      "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4%2F0AbcDef"

    assert {:error, :state_mismatch} =
             Auth.parse_authorization_input(no_state_url, expected_state: state)

    # Redirect URL with error=... is rejected
    err_url =
      "https://sdk.cloud.google.com/applicationdefaultauthcode.html?error=access_denied&state=#{state}"

    assert {:error, :oauth_error} =
             Auth.parse_authorization_input(err_url, expected_state: state)

    # code#state format
    assert {:ok, %{code: "4/0HashCode", state: ^state}} =
             Auth.parse_authorization_input("4/0HashCode##{state}", expected_state: state)

    assert {:error, :state_mismatch} =
             Auth.parse_authorization_input("4/0HashCode#wrong-state", expected_state: state)

    # Bare authorization code (from Google's copy button)
    assert {:ok, %{code: "4/0BareCode123", state: nil}} =
             Auth.parse_authorization_input("  4/0BareCode123  ", expected_state: state)

    # Empty or whitespace-containing bare input is rejected
    assert {:error, :invalid_code} = Auth.parse_authorization_input("   ", expected_state: state)

    assert {:error, :invalid_code} =
             Auth.parse_authorization_input("not a valid code", expected_state: state)
  end
end
