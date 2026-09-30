defmodule AlertRouter.TestOIDCTokenVerifier do
  @moduledoc false

  @behaviour AlertRouter.Web.GCPPushAuth.TokenVerifier

  @email "alert-router-push@test.iam.gserviceaccount.com"

  @impl true
  def verify("valid", audience) do
    {:ok, %{"aud" => audience, "email" => @email, "email_verified" => true}}
  end

  def verify("audience-list", audience) do
    {:ok, %{"aud" => ["another-audience", audience], "email" => @email, "email_verified" => true}}
  end

  def verify("wrong-audience", _audience) do
    {:ok, %{"aud" => "https://wrong.example", "email" => @email, "email_verified" => true}}
  end

  def verify("wrong-email", audience) do
    {:ok,
     %{
       "aud" => audience,
       "email" => "other@test.iam.gserviceaccount.com",
       "email_verified" => true
     }}
  end

  def verify("unverified-email", audience) do
    {:ok, %{"aud" => audience, "email" => @email, "email_verified" => false}}
  end

  def verify("provider-not-ready", _audience), do: {:error, :provider_not_ready}
  def verify("invalid", _audience), do: {:error, :invalid_token}
  def verify("raise", _audience), do: raise("verifier failure")
end

defmodule AlertRouter.GCPPushAuthTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AlertRouter.Web.GCPPushAuth.{OIDC, OidccTokenVerifier}

  @audience "https://alert-router.test/v1/events/gcp"
  @email "alert-router-push@test.iam.gserviceaccount.com"

  setup do
    previous = Application.fetch_env!(:alert_router, :gcp_push)

    Application.put_env(
      :alert_router,
      :gcp_push,
      previous
      |> Keyword.put(:audience, @audience)
      |> Keyword.put(:service_account_email, @email)
      |> Keyword.put(:token_verifier, AlertRouter.TestOIDCTokenVerifier)
    )

    on_exit(fn -> Application.put_env(:alert_router, :gcp_push, previous) end)
  end

  test "accepts only a verified token pinned to audience and service-account email" do
    assert :ok = authorize("valid")
    assert :ok = authorize("audience-list")
  end

  test "rejects wrong audience, email, verification state, malformed bearer, and invalid token" do
    assert {:error, :unauthorized} = authorize("wrong-audience")
    assert {:error, :unauthorized} = authorize("wrong-email")
    assert {:error, :unauthorized} = authorize("unverified-email")
    assert {:error, :unauthorized} = authorize("invalid")
    assert {:error, :unauthorized} = OIDC.authorize(conn(:post, "/v1/events/gcp"))

    duplicate_header_conn =
      conn(:post, "/v1/events/gcp")
      |> put_req_header("authorization", "Bearer valid")
      |> prepend_req_headers([{"authorization", "Bearer valid"}])

    assert {:error, :unauthorized} = OIDC.authorize(duplicate_header_conn)
  end

  test "fails unavailable when verification infrastructure is not ready or crashes" do
    assert {:error, :unavailable} = authorize("provider-not-ready")
    assert {:error, :unavailable} = authorize("raise")
  end

  test "fails closed when the expected identity is not configured" do
    config = Application.fetch_env!(:alert_router, :gcp_push)
    Application.put_env(:alert_router, :gcp_push, Keyword.put(config, :audience, nil))

    assert {:error, :unauthorized} = authorize("valid")
  end

  test "accepts the real Pub/Sub claim shape where azp differs from the push audience" do
    issuer = "https://accounts.google.com"
    private_key = JOSE.JWK.generate_key({:rsa, 2_048})
    {_, public_key} = private_key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

    public_key =
      Map.merge(public_key, %{"alg" => "RS256", "kid" => "gcp-push-test", "use" => "sig"})

    configuration = %Oidcc.ProviderConfiguration{
      issuer: issuer,
      authorization_endpoint: issuer <> "/auth",
      response_types_supported: ["id_token"],
      subject_types_supported: [:public],
      id_token_signing_alg_values_supported: ["RS256"]
    }

    context =
      Oidcc.ClientContext.from_manual(
        configuration,
        JOSE.JWK.from_map(%{"keys" => [public_key]}),
        @audience,
        :unauthenticated
      )

    now = System.system_time(:second)

    claims = %{
      "iss" => issuer,
      "sub" => "pubsub-push",
      "aud" => @audience,
      "azp" => "113774264463038321964",
      "exp" => now + 300,
      "iat" => now,
      "email" => @email,
      "email_verified" => true
    }

    {_, bearer} =
      private_key
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "gcp-push-test", "typ" => "JWT"}, claims)
      |> JOSE.JWS.compact()

    assert {:ok, ^claims} = OidccTokenVerifier.validate_id_token(bearer, context)
  end

  defp authorize(token) do
    conn(:post, "/v1/events/gcp")
    |> put_req_header("authorization", "Bearer #{token}")
    |> OIDC.authorize()
  end
end
