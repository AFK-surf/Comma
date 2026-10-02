defmodule Comma.Auth.GoogleAdapter.Oidcc do
  @moduledoc "Google ID-token validation backed by the OpenID-certified Oidcc library."

  @behaviour Comma.Auth.GoogleAdapter

  require Logger

  alias Oidcc.{ClientContext, Token}
  alias Oidcc.Token.Id
  alias __MODULE__.JwksRefreshGate

  @provider Comma.Auth.GoogleAdapter.Oidcc.Provider
  @token_exchange_timeout_ms 10_000

  @impl true
  def exchange_authorization_code(authorization_code, opts)
      when is_binary(authorization_code) and authorization_code != "" and is_list(opts) do
    client_id = Keyword.get(opts, :client_id)
    client_secret = Keyword.get(opts, :client_secret)
    nonce = Keyword.get(opts, :nonce)
    pkce_verifier = Keyword.get(opts, :pkce_verifier)
    redirect_uri = Keyword.get(opts, :redirect_uri)

    with true <-
           Enum.all?(
             [client_id, client_secret, nonce, pkce_verifier, redirect_uri],
             &nonempty?/1
           ),
         {:ok, %Token{id: %Id{claims: claims}}} <-
           Oidcc.retrieve_token(
             authorization_code,
             @provider,
             client_id,
             client_secret,
             %{
               nonce: nonce,
               pkce_verifier: pkce_verifier,
               preferred_auth_methods: [:client_secret_post],
               redirect_uri: redirect_uri,
               refresh_jwks: &refresh_jwks/2,
               request_opts: %{timeout: @token_exchange_timeout_ms}
             }
           ) do
      {:ok, claims}
    else
      false -> {:error, :invalid_google_credential}
      {:error, reason} -> normalize_exchange_error(reason)
      _other -> {:error, :invalid_google_credential}
    end
  rescue
    exception ->
      Logger.error(
        "Google authorization-code exchange raised unexpectedly",
        exception_module: inspect(exception.__struct__)
      )

      {:error, :google_provider_unavailable}
  catch
    :exit, _reason ->
      Logger.error("Google authorization-code exchange exited unexpectedly")
      {:error, :google_provider_unavailable}
  end

  def exchange_authorization_code(_authorization_code, _opts),
    do: {:error, :invalid_google_credential}

  @impl true
  def verify_id_token(credential, opts)
      when is_binary(credential) and credential != "" and is_list(opts) do
    client_id = Keyword.get(opts, :client_id)
    nonce = Keyword.get(opts, :nonce)

    with true <- nonempty?(client_id) and nonempty?(nonce),
         {:ok, client_context} <-
           ClientContext.from_configuration_worker(@provider, client_id, :unauthenticated),
         {:ok, claims} <-
           Token.validate_id_token(
             credential,
             client_context,
             id_token_validation_opts(nonce, Keyword.get(opts, :authorized_parties))
           ) do
      {:ok, claims}
    else
      {:error, :provider_not_ready} -> {:error, :google_provider_unavailable}
      {:error, _reason} -> {:error, :invalid_google_credential}
      false -> {:error, :invalid_google_credential}
    end
  rescue
    _exception -> {:error, :google_provider_unavailable}
  catch
    :exit, _reason -> {:error, :google_provider_unavailable}
  end

  def verify_id_token(_credential, _opts), do: {:error, :invalid_google_credential}

  defp id_token_validation_opts(nonce, authorized_parties)
       when is_list(authorized_parties) and authorized_parties != [] do
    nonce
    |> id_token_validation_opts(nil)
    |> Map.put(:validate_azp, authorized_parties)
  end

  defp id_token_validation_opts(nonce, _authorized_parties),
    do: %{nonce: nonce, refresh_jwks: &refresh_jwks/2}

  defp normalize_exchange_error({:http_error, status, %{"error" => error}})
       when status in 400..499 and error in ["invalid_client", "unauthorized_client"],
       do: {:error, :google_provider_unavailable}

  defp normalize_exchange_error({:http_error, status, _body}) when status in 400..499,
    do: {:error, :invalid_google_credential}

  defp normalize_exchange_error({:http_error, status, _body}) when status >= 500,
    do: {:error, :google_provider_unavailable}

  defp normalize_exchange_error(:provider_not_ready),
    do: {:error, :google_provider_unavailable}

  defp normalize_exchange_error(reason)
       when reason in [:timeout, :connect_timeout, :closed, :enetunreach, :econnrefused],
       do: {:error, :google_provider_unavailable}

  defp normalize_exchange_error(_reason), do: {:error, :invalid_google_credential}

  defp refresh_jwks(_current_jwks, kid) do
    case JwksRefreshGate.refresh(@provider, kid) do
      {:ok, %JOSE.JWK{} = jwks} -> {:ok, JOSE.JWK.to_record(jwks)}
      {:error, _reason} = error -> error
    end
  end

  defp nonempty?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty?(_value), do: false
end
