defmodule AlertRouter.Web.GCPPushAuth do
  @moduledoc "Authentication boundary for Cloud Pub/Sub push requests."

  @callback authorize(Plug.Conn.t()) :: :ok | {:error, :unauthorized | :unavailable}
end

defmodule AlertRouter.Web.GCPPushAuth.DenyAll do
  @moduledoc "Fail-closed authenticator used until an environment is explicitly configured."

  @behaviour AlertRouter.Web.GCPPushAuth

  @impl true
  def authorize(_conn), do: {:error, :unavailable}
end

defmodule AlertRouter.Web.GCPPushAuth.TokenVerifier do
  @moduledoc false

  @callback verify(binary(), binary()) ::
              {:ok, map()} | {:error, :provider_not_ready | term()}
end

defmodule AlertRouter.Web.GCPPushAuth.OidccTokenVerifier do
  @moduledoc false

  @behaviour AlertRouter.Web.GCPPushAuth.TokenVerifier

  alias Oidcc.{ClientContext, Token}

  @provider AlertRouter.GCPOIDCProvider

  @impl true
  def verify(bearer, audience) do
    with {:ok, context} <-
           ClientContext.from_configuration_worker(@provider, audience, :unauthenticated) do
      validate_id_token(bearer, context)
    end
  end

  @doc false
  def validate_id_token(bearer, context) do
    Token.validate_id_token(bearer, context, %{nonce: :any, validate_azp: :any})
  end
end

defmodule AlertRouter.Web.GCPPushAuth.OIDC do
  @moduledoc """
  Validates Google-signed Pub/Sub OIDC tokens with Oidcc, then pins the token
  to the configured push audience and service-account email.
  """

  @behaviour AlertRouter.Web.GCPPushAuth

  @impl true
  def authorize(conn), do: authorize(conn, :gcp_push)

  def authorize(conn, config_key) when config_key in [:gcp_push, :runtime_storage_push] do
    config = Application.get_env(:alert_router, config_key, [])
    audience = config[:audience]
    expected_email = config[:service_account_email]

    verifier =
      config[:token_verifier] || AlertRouter.Web.GCPPushAuth.OidccTokenVerifier

    with true <- non_empty?(audience) and non_empty?(expected_email),
         {:ok, bearer} <- bearer(conn),
         {:ok, claims} <- verifier.verify(bearer, audience),
         true <- audience_matches?(claims["aud"], audience),
         true <- claims["email_verified"] == true,
         true <- secure_equal(claims["email"], expected_email) do
      :ok
    else
      {:error, :provider_not_ready} -> {:error, :unavailable}
      {:error, _reason} -> {:error, :unauthorized}
      false -> {:error, :unauthorized}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _ -> {:error, :unauthorized}
    end
  end

  defp secure_equal(left, right) when is_binary(left) and is_binary(right),
    do: byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)

  defp secure_equal(_left, _right), do: false

  defp audience_matches?(claim, expected) when is_binary(claim),
    do: secure_equal(claim, expected)

  defp audience_matches?(claims, expected) when is_list(claims),
    do: Enum.any?(claims, &secure_equal(&1, expected))

  defp audience_matches?(_claim, _expected), do: false

  defp non_empty?(value), do: is_binary(value) and String.trim(value) != ""
end
