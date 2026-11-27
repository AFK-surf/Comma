defmodule BillingApple.ServerAPI do
  @moduledoc "App Store Server API client. Requests sign an ES256 JWT with the In-App Purchase key."
  @behaviour BillingApple.API

  @hosts %{
    production: "https://api.storekit.itunes.apple.com",
    sandbox: "https://api.storekit-sandbox.itunes.apple.com"
  }
  # App Store Server API error code for an unknown transaction id.
  @transaction_not_found 4_040_010

  @impl true
  def get_transaction(environment, transaction_id, config) do
    with {:ok, body} <-
           get(environment, "/inApps/v1/transactions/#{segment(transaction_id)}", config) do
      case body do
        %{"signedTransactionInfo" => signed} when is_binary(signed) -> {:ok, signed}
        _ -> {:error, :apple_response_invalid}
      end
    end
  end

  @impl true
  def get_subscription_statuses(environment, transaction_id, config) do
    get(environment, "/inApps/v1/subscriptions/#{segment(transaction_id)}", config)
  end

  defp get(environment, path, config) do
    case Req.get(Map.fetch!(@hosts, environment) <> path,
           auth: {:bearer, token(config)},
           retry: false,
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: %{} = body}} ->
        {:ok, body}

      {:ok, %{status: 404, body: %{"errorCode" => @transaction_not_found}}} ->
        {:error, :not_found}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:apple_http_status, status}}

      {:error, reason} ->
        {:error, {:apple_unavailable, reason}}
    end
  end

  defp token(config) do
    now = SystemsClock.system_time(:second)
    jwk = JOSE.JWK.from_pem(config.private_key)

    {_, token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => "ES256", "kid" => config.key_id, "typ" => "JWT"}, %{
        "iss" => config.issuer_id,
        "iat" => now,
        "exp" => now + 1_200,
        "aud" => "appstoreconnect-v1",
        "bid" => config.bundle_id
      })
      |> JOSE.JWS.compact()

    token
  end

  defp segment(id) do
    if is_binary(id) and Regex.match?(~r/\A[0-9]{1,32}\z/, id),
      do: id,
      else: raise(ArgumentError, "invalid App Store transaction id")
  end
end
